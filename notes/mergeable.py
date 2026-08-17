"""Reader for Apple Notes' ZMERGEABLEDATA1 blobs.

A note's *body* lives in ZICNOTEDATA.ZDATA and is handled by notestore.py. Rich
embedded objects — tables, and since call recording landed, audio recordings and
their transcripts — instead hang off the note's *attachment* rows in
ZICCLOUDSYNCINGOBJECT.ZMERGEABLEDATA1, in a different and much larger format.

The blob is a MergeableDataObjectData: one flat array of entries plus three
lookup tables (key names, type names, UUIDs). Objects address each other by
index into the entry array, so reading anything means walking a graph rather
than a tree.

🛑 **Every index in here is 0-based**, unlike the 1-based tables documented for
older Notes formats. The tell is that a 1-based reading makes the root
ICTTAudioRecording reference *itself* as its own first field, which parses fine
and yields infinite recursion rather than an error.

🛑 **ObjectID field 3 is a fixed64 double**, and it is the only place a
timestamp appears. Reading ObjectID as {uint, string, index} — which is all the
table format needs — silently drops every time value and leaves a transcript
whose segments cannot be ordered.

A call recording decodes to:

    ICTTAudioRecording            one per recording
      .topLineSummary             the line Notes shows as "Preview"
      .summary                    longer summary, often absent
      .callLocalSpeakerHandle     your number
      .callRemoteSpeakerHandle    the other party
      .fragments -> Fragment      audio fragments, each with a transcript
    ICTTTranscriptSegment         ONE PER WORD, with speaker/text/timestamp

⚠️ **Segments are per-word, not per-utterance**, and they are stored in CRDT
insertion order, which is not reading order. Sort by `timestamp`; do not trust
the order they appear in the blob.
"""

import gzip
import sqlite3

from notestore import (Message, NO_MARKS, escape_markdown, looks_like_uri,
                       markdown_link, mark_transition, marks_of)

# Type names that wrap a single scalar, and the keys they carry it under.
_SCALAR_STRING = ("com.apple.CRDT.NSString", "com.apple.CRDT.NSUUID")
_SCALAR_NUMBER = ("com.apple.CRDT.NSNumber", "com.apple.CRDT.NSDate")

AUDIO_RECORDING = "com.apple.notes.ICTTAudioRecording"
FRAGMENT = "com.apple.notes.ICTTAudioRecording.Fragment"
TRANSCRIPT_SEGMENT = "com.apple.notes.ICTTTranscriptSegment"
TABLE = "com.apple.notes.ICTable"
NSUUID = "com.apple.CRDT.NSUUID"

TABLE_UTI = "com.apple.notes.table"

# Apple epoch (2001-01-01) to Unix epoch, seconds.
APPLE_EPOCH = 978307200


class MergeableData:
    """The object graph in one ZMERGEABLEDATA1 blob.

    🛑 **Two blob shapes live in this column, and only one is the shape the
    audio code was written against.** A recording blob is a bare, uncompressed
    MergeableDataObjectData: entries at field 3 of the root. A *table* blob is
    **gzipped**, and once unzipped it carries two more wrapper levels —
    MergableDataProto.mergable_data_object.mergeable_data_object_data — so its
    entries sit at root.2.3. All 76 table blobs on the development store are
    gzipped; all 3 audio blobs are raw.

    Handing a table blob to the raw reading yields **zero entries and no
    error**, which reads as "this table is empty" rather than as a parse
    failure. Both shapes are sniffed here so no caller has to know.
    """

    def __init__(self, blob):
        if blob[:2] == b"\x1f\x8b":
            blob = gzip.decompress(blob)
        root = Message(blob)
        # Descend the MergableDataProto wrapper only when the root is not
        # already the object data. An audio blob carries BOTH field 2 and
        # field 3, so keying off "field 3 is missing" is what keeps the two
        # apart; sniffing on field 2 alone would misread every recording.
        if not root._fields.get(3) and root._fields.get(2):
            inner = Message(root._fields[2][0])
            if inner._fields.get(3):
                root = Message(inner._fields[3][0])
        self.entries = [Message(v) for v in root._fields.get(3, [])]
        self.keys = [v.decode("utf-8", "replace") for v in root._fields.get(4, [])]
        self.types = [v.decode("utf-8", "replace") for v in root._fields.get(5, [])]
        self.uuids = list(root._fields.get(6, []))
        self._uuid_entry = None

    # -- lookup tables (0-based; see module docstring) ----------------------- #

    def key_name(self, index):
        if 0 <= index < len(self.keys):
            return self.keys[index]
        return "?key%d" % index

    def type_name(self, index):
        if 0 <= index < len(self.types):
            return self.types[index]
        return "?type%d" % index

    # -- values -------------------------------------------------------------- #

    def _object_id(self, message):
        """ObjectID: 1=int, 2=uint, 3=double, 4=string, 6=index into entries.

        ⚠️ Field 1 is where an NSNumber's `integerValue` lands — callType and
        callRecording both read 0 rather than None only because of it. It is
        checked last so it can never shadow a real reference.
        """
        if message.has(4):
            return message.string(4)
        if message.has(3):
            return message.float64(3)
        if message.has(6):
            return ("ref", message.varint(6))
        if message.has(2):
            return message.varint(2)
        if message.has(1):
            return message.int32(1)
        return None

    def _resolve(self, value, depth):
        if isinstance(value, tuple) and value and value[0] == "ref":
            return self.entry(value[1], depth + 1)
        return value

    def entry(self, index, depth=0):
        """Decode entry `index` to a Python value."""
        if not (0 <= index < len(self.entries)) or depth > 12:
            return None
        e = self.entries[index]

        custom_map = e.message(13)
        if custom_map is not None:
            return self._custom_map(custom_map, depth)

        # RegisterLatest (1) holds the live value as an ObjectID in field 2.
        # ⚠️ A RegisterLatest with no field 2 is a real "no value" — the summary
        # slot of a recording Notes only produced a topLineSummary for looks
        # exactly like this — so it returns None rather than being an error.
        register = e.message(1)
        if register is not None:
            inner = register.message(2)
            if inner is not None:
                return self._resolve(self._object_id(inner), depth)
            return None

        # Note (10) — a CRDT text object. Summaries land here as plain text;
        # the transcript's own Note is 2,228 U+FFFC placeholders, one per
        # segment, and carries no words of its own.
        note = e.message(10)
        if note is not None:
            return note.string(2)
        return None

    def _custom_map(self, custom_map, depth=0):
        type_name = self.type_name(custom_map.varint(1)) if custom_map.has(1) \
            else self.type_name(0)
        out = {}
        for entry in custom_map.messages(3):
            value = entry.message(2)
            if value is None:
                continue
            name = self.key_name(entry.varint(1))
            out[name] = self._resolve(self._object_id(value), depth)

        # CRDT scalar wrappers carry exactly one payload; hand back the scalar
        # rather than a one-key dict the caller would have to unwrap.
        if type_name in _SCALAR_STRING:
            return out.get("self")
        if type_name in _SCALAR_NUMBER:
            for key in ("doubleValue", "integerValue"):
                if out.get(key) is not None:
                    return out[key]
            return None

        out["__type__"] = type_name
        return out

    def objects(self, type_name):
        """Every entry whose custom_map declares this type."""
        found = []
        for index, e in enumerate(self.entries):
            custom_map = e.message(13)
            if custom_map is None or not custom_map.has(1):
                continue
            if self.type_name(custom_map.varint(1)) == type_name:
                found.append(self._custom_map(custom_map))
        return found

    # -- table support -------------------------------------------------------- #
    #
    # These read raw ObjectIDs rather than going through `_custom_map`, which
    # unwraps a CRDT scalar and would hand back the *value* where the table
    # format needs the *reference*. `_custom_map` also returns None for an
    # NSUUID here, because it looks for the scalar under `self` and a table's
    # NSUUID carries it under `UUIDIndex`.

    def _raw_map(self, index):
        """entry -> (type name, {key name: raw ObjectID}), or (None, {})."""
        if not (0 <= index < len(self.entries)):
            return None, {}
        custom_map = self.entries[index].message(13)
        if custom_map is None:
            return None, {}
        type_name = self.type_name(custom_map.varint(1)) if custom_map.has(1) \
            else self.type_name(0)
        out = {}
        for entry in custom_map.messages(3):
            value = entry.message(2)
            if value is not None:
                out[self.key_name(entry.varint(1))] = self._object_id(value)
        return type_name, out

    def _raw_dictionary(self, index):
        """entry -> [(key ObjectID, value ObjectID)] with nothing resolved."""
        if not (0 <= index < len(self.entries)):
            return []
        dictionary = self.entries[index].message(6)
        if dictionary is None:
            return []
        pairs = []
        for element in dictionary.messages(1):
            key, value = element.message(1), element.message(2)
            if key is not None and value is not None:
                pairs.append((self._object_id(key), self._object_id(value)))
        return pairs

    def uuid_at(self, index):
        """The UUID bytes an NSUUID entry names, or None.

        ⚠️ The scalar sits under `UUIDIndex` and is an **index into the blob's
        UUID table**, not the bytes themselves.
        """
        type_name, fields = self._raw_map(index)
        if type_name != NSUUID:
            return None
        i = fields.get("UUIDIndex")
        if not isinstance(i, int):
            return None
        return self.uuids[i] if 0 <= i < len(self.uuids) else None

    def entry_for_uuid(self, uuid_bytes):
        """The NSUUID entry index holding these bytes. Built once, then cached."""
        if self._uuid_entry is None:
            self._uuid_entry = {}
            for index in range(len(self.entries)):
                found = self.uuid_at(index)
                if found is not None:
                    self._uuid_entry.setdefault(found, index)
        return self._uuid_entry.get(uuid_bytes)

    def ordered_cell_uuids(self, index):
        """An OrderedSet -> the cell-key UUIDs it names, in display order.

        🛑 **Three structures, and dropping any one of them gives a wrong
        table rather than an error.**

          - `ordering.array.attachment`  the *ordering* UUIDs, in display order
          - `ordering.contents`          ordering UUID -> **cell** UUID
          - `elements`                   which ordering UUIDs are still live

        The two UUID spaces are disjoint: on the development store the
        ordering side used UUID-table indices 9-16 while the cells used 3-8.
        Skipping `contents` therefore produces a table of the right size whose
        every cell is empty, which looks like an empty table in the note.

        ⚠️ `contents` also keeps **deleted** rows and columns. One real table
        here lists three columns there and only one in `elements`. Reading
        `contents` alone invents columns the user cannot see in Notes.app.
        """
        ordered_set = self.entries[index].message(16) \
            if 0 <= index < len(self.entries) else None
        if ordered_set is None:
            return []
        ordering = ordered_set.message(1)
        if ordering is None:
            return []

        alias = {}
        contents = ordering.message(2)
        if contents is not None:
            for element in contents.messages(1):
                key, value = element.message(1), element.message(2)
                if key is not None and value is not None:
                    alias[self._object_id(key)] = self._object_id(value)

        live = set()
        elements = ordered_set.message(2)
        if elements is not None:
            for element in elements.messages(1):
                key = element.message(1)
                if key is not None:
                    live.add(self._object_id(key))

        array = ordering.message(1)
        if array is None:
            return []
        placed = []
        for attachment in array.messages(2):
            if attachment.has(1) and attachment.has(2):
                placed.append((attachment.varint(1), attachment._fields[2][0]))
        placed.sort(key=lambda pair: pair[0])

        out = []
        for _position, uuid_bytes in placed:
            entry = self.entry_for_uuid(uuid_bytes)
            if entry is None:
                continue
            ref = ("ref", entry)
            if live and ref not in live:
                continue
            cell = alias.get(ref)
            if isinstance(cell, tuple) and cell and cell[0] == "ref":
                out.append(self.uuid_at(cell[1]))
        return out

    def cell_text(self, ref, labels=None, seen=None, links=None):
        """The text of one table cell, with **bold** and ==highlight== markers.

        The note body and a table cell carry the same AttributeRun attributes,
        so they must render the same way. Reading only `note_text` here made
        `export` report a bold cell as plain while reporting a bold paragraph
        as bold — one command giving two answers for one attribute. Measured on
        the development store: 330 of 1,723 non-empty cells are bold.

        🛑 **A run's `length` counts UTF-16 code units**, the same trap the note
        body has. The text is sliced as UTF-16 for that reason; slicing by code
        point walks one short per emoji and puts the markers mid-word.

        ⚠️ A cell holding a note link, a hashtag or a mention is a bare U+FFFC
        whose attribute run carries the attachment identifier. Without
        `labels` such a cell reads as `attachment` rather than as a link.

        🛑 **Such an attachment row has a NULL ZNOTE**, so it is not reachable
        from the note it visibly belongs to. Every identifier the cells use is
        recorded in `seen` for the caller to look up separately.
        """
        labels = labels or {}
        if not (isinstance(ref, tuple) and ref and ref[0] == "ref"):
            return ""
        index = ref[1]
        if not (0 <= index < len(self.entries)):
            return ""
        note = self.entries[index].message(10)
        if note is None:
            return ""
        body = note.string(2) or ""
        runs = note.messages(5)
        if not body or not runs:
            # ⚠️ Still escape. A cell can carry text with no attribute run at
            # all, and returning it raw let a literal `*` through as a marker.
            return escape_markdown(body)

        raw = body.encode("utf-16-le")
        pieces, offset = [], 0
        for run in runs:
            length = run.int32(1)
            chunk = raw[offset * 2:(offset + length) * 2].decode("utf-16-le", "replace")
            offset += length

            # ⚠️ Escape the source text BEFORE substituting the attachment,
            # so a rendered link's own brackets are never escaped.
            chunk = escape_markdown(chunk)

            info = run.message(12)
            if info is not None:
                identifier = info.string(1)
                if seen is not None and identifier:
                    seen.add(identifier)
                chunk = chunk.replace("￼", inline_attachment_markdown(
                    identifier, info.string(2), labels, links))

            pieces.append((chunk, marks_of(run)))

        # Anything past the last run keeps whatever the runs did not describe.
        tail = raw[offset * 2:].decode("utf-16-le", "replace")
        if tail:
            pieces.append((tail, NO_MARKS))

        return _wrap_runs(pieces)


INLINE_LINK_UTI = "com.apple.notes.inlinetextattachment.link"


def inline_attachment_markdown(identifier, uti, labels=None, links=None):
    """One inline text attachment — a note link, a hashtag, a mention — as text.

    ⚠️ **None of these is an attachment in any useful sense.** They are text
    Notes stores out of line: `#trips`, `@Dan`, an inline calculation result,
    and a link to another note. Rendering them as `[attachment: #trips]` was
    wrong for all 227 of them on the development store.

    🛑 **Only a `link` may become a Markdown link.** A hashtag's token is a
    bare word (`TRIPS`) and a mention's token is an account id, so both fail
    `looks_like_uri` and come back as their plain text.
    """
    label = (labels or {}).get(identifier)
    url = (links or {}).get(identifier)
    if uti == INLINE_LINK_UTI and label and looks_like_uri(url):
        return markdown_link(label, url)
    return label or "attachment"


def _wrap_runs(pieces):
    """[(text, bold, highlight, url)] -> Markdown, merging runs that match.

    Merging first matters: Notes splits a bold phrase into several runs, and
    wrapping each one gives `**a****b**`, which no Markdown parser reads as one
    bold phrase. A link is split the same way — 26 adjacent run pairs on the
    development store share one URL — and `[a](u)[b](u)` is two links.

    🛑 **Merge on the run's real style, never on a cleaned-up one.** Notes
    stores the space inside a bold phrase as its own bold run. Treating a
    whitespace-only run as unstyled — so that a marker always sits against a
    word — splits the phrase instead: `**Hyperspace** **Mountain**`. Nine cells
    on the development store came out that way. The markers are moved off the
    whitespace below, after the merge, where it costs nothing.

    The link goes innermost, so a bold link reads `**[text](url)**`.
    """
    merged = []
    for text, marks in pieces:
        if not text:
            continue
        if merged and merged[-1][1] == marks:
            merged[-1][0] += text
        else:
            merged.append([text, marks])

    out = []
    for text, marks in merged:
        core = text.strip()
        if not core:
            # All whitespace. Taking `lead` and `trail` from it would emit the
            # same spaces twice, since each is the whole string.
            out.append(text)
            continue
        # Keep surrounding spaces outside the markers: `** hi **` renders as
        # literal asterisks in most parsers.
        lead = text[:len(text) - len(text.lstrip())]
        trail = text[len(text.rstrip()):]
        # ⚠️ A pasted link is its own text; `[url](url)` is noise. Drop the link
        # mark rather than special-casing it inside the nesting.
        if marks[-1] and core == marks[-1].strip():
            marks = marks[:-1] + (None,)
        # Same nesting the note body uses, from the same table, so a bold cell
        # and a bold paragraph cannot drift apart.
        out.append(lead + mark_transition(NO_MARKS, marks) + core
                   + mark_transition(marks, NO_MARKS) + trail)
    return "".join(out)


class Table:
    """One com.apple.notes.table, as a grid of strings."""

    def __init__(self, grid, attachment_ids=None):
        self.grid = grid
        # Identifiers of inline attachments found inside cells. Their rows have
        # a NULL ZNOTE, so a caller cannot find them from the note.
        self.attachment_ids = attachment_ids or set()

    @property
    def rows(self):
        return len(self.grid)

    @property
    def columns(self):
        return len(self.grid[0]) if self.grid else 0

    def markdown(self):
        """Render as a GitHub pipe table.

        ⚠️ **Notes has no header row and Markdown requires one**, so the first
        row is promoted. That is a real change of meaning for a table whose
        first row is data, and it is not reversible from the output alone.
        """
        if not self.grid:
            return ""

        def escape(cell):
            return " ".join((cell or "").split()).replace("|", "\\|")

        width = self.columns
        lines = []
        for position, row in enumerate(self.grid):
            cells = [escape(c) for c in row] + [""] * (width - len(row))
            lines.append("| " + " | ".join(cells) + " |")
            if position == 0:
                lines.append("|" + "|".join([" --- "] * width) + "|")
        return "\n".join(lines)


def table_from_blob(blob, labels=None, links=None):
    """Decode a com.apple.notes.table blob, or None if it holds no table."""
    if not blob:
        return None
    data = MergeableData(blob)
    root = None
    for index in range(len(data.entries)):
        type_name, fields = data._raw_map(index)
        if type_name == TABLE:
            root = fields
            break
    if root is None:
        return None

    def entry_of(name):
        ref = root.get(name)
        return ref[1] if isinstance(ref, tuple) and ref and ref[0] == "ref" else None

    rows_entry, columns_entry = entry_of("crRows"), entry_of("crColumns")
    cells_entry = entry_of("cellColumns")
    if rows_entry is None or columns_entry is None or cells_entry is None:
        return None

    rows = data.ordered_cell_uuids(rows_entry)
    columns = data.ordered_cell_uuids(columns_entry)

    # cellColumns: column UUID -> (row UUID -> cell text). Column-major, which
    # is why the grid is transposed here rather than read out directly.
    cells = {}
    seen = set()
    for column_key, column_ref in data._raw_dictionary(cells_entry):
        if not (isinstance(column_ref, tuple) and column_ref[0] == "ref"):
            continue
        column_uuid = data.uuid_at(column_key[1]) \
            if isinstance(column_key, tuple) and column_key[0] == "ref" else None
        inner = {}
        for row_key, value in data._raw_dictionary(column_ref[1]):
            row_uuid = data.uuid_at(row_key[1]) \
                if isinstance(row_key, tuple) and row_key[0] == "ref" else None
            inner[row_uuid] = data.cell_text(value, labels, seen, links)
        cells[column_uuid] = inner

    grid = [[cells.get(c, {}).get(r, "") for c in columns] for r in rows]
    return Table(grid, seen)


class Segment:
    """One transcribed word, with who said it and when."""

    __slots__ = ("speaker", "text", "timestamp", "duration")

    def __init__(self, obj):
        self.speaker = obj.get("speaker")
        self.text = obj.get("text")
        self.timestamp = obj.get("timestamp")
        self.duration = obj.get("duration")

    @property
    def usable(self):
        return isinstance(self.timestamp, float) and isinstance(self.text, str)


class Recording:
    """An ICTTAudioRecording and its transcript.

    `with_segments=False` skips decoding the per-word transcript, which is the
    bulk of the work — 0.07s of a 0.11s decode on a 15-minute call, and it
    scales with call length. Listing many recordings does not need it.
    """

    def __init__(self, data, attachment, with_segments=True):
        record = (data.objects(AUDIO_RECORDING) or [{}])[0]
        self.attachment_id = attachment.get("pk")
        self.title = attachment.get("title")
        self.filename = attachment.get("filename")
        self.file_size = attachment.get("file_size")
        self.audio_duration = attachment.get("duration")
        self.created = attachment.get("created")

        self.note_id = attachment.get("note")
        self.note_title = attachment.get("note_title")
        self.summary = record.get("summary")
        self.top_line_summary = record.get("topLineSummary")
        self.local_handle = record.get("callLocalSpeakerHandle")
        self.remote_handle = record.get("callRemoteSpeakerHandle")

        # ⚠️ Reported raw, deliberately. callType is 0 on the one call available
        # to test against, and one sample cannot say whether 0 means incoming or
        # outgoing — so nothing here derives a direction from it. The note data
        # does not record who placed the call; CallHistory does (see
        # docs/apple-notes-transcripts.md).
        self.call_type = record.get("callType")
        self.call_recording = record.get("callRecording")
        # 🛑 callRecordingStartTime is UNIX epoch, not Apple epoch — the only
        # date in this repo that is. Every ZDATE/ZCREATIONDATE column beside it
        # is Apple epoch, so converting this one too puts the call in 2057 while
        # still looking like a plausible date.
        start = record.get("callRecordingStartTime")
        self.start_time = start if isinstance(start, float) else None

        if with_segments:
            self.segments = sorted(
                (s for s in (Segment(o) for o in data.objects(TRANSCRIPT_SEGMENT))
                 if s.usable),
                key=lambda s: s.timestamp,
            )
            self.segments_loaded = True
        else:
            self.segments = []
            self.segments_loaded = False

    @property
    def is_call(self):
        """A call recording carries speaker handles; a plain voice memo does not."""
        return bool(self.local_handle or self.remote_handle)

    def speaker_label(self, handle):
        """A display name, or None when the audio carries no speaker at all.

        ⚠️ Only call recordings have speaker handles. A voice memo or an
        imported audio file transcribes with `speaker` None on every segment,
        and labelling those "Unknown" reads as a failed lookup rather than as
        "this recording has one unnamed voice" — so they get no label.
        """
        if handle is None:
            return None
        if handle == self.local_handle:
            return "You"
        return handle

    def turns(self):
        """Group per-word segments into readable turns.

        🛑 Two tokenizations coexist and a naive join breaks one of them. Call
        recordings emit words with a LEADING space (' this', ' is'); imported
        audio emits them bare with a TRAILING newline at sentence ends
        ('Thank', 'you', 'much.\\n\\n'). Concatenating the second kind directly
        yields "Thankyousomuch." — still plausible-looking prose, which is how
        it would survive review.
        """
        out = []
        break_next = False
        for s in self.segments:
            same_speaker = out and out[-1]["speaker"] == s.speaker
            if same_speaker and not break_next:
                previous = out[-1]["text"]
                # Insert the separator neither side supplied.
                if previous and not previous[-1].isspace() \
                        and not s.text[:1].isspace():
                    out[-1]["text"] += " "
                out[-1]["text"] += s.text
                out[-1]["end"] = s.timestamp + (s.duration or 0.0)
            else:
                out.append({
                    "speaker": s.speaker,
                    "label": self.speaker_label(s.speaker),
                    "start": s.timestamp,
                    "end": s.timestamp + (s.duration or 0.0),
                    "text": s.text,
                })
            # A blank line ends a paragraph. Without this a single-speaker
            # recording collapses into one turn thousands of words long,
            # because the speaker never changes.
            break_next = s.text.endswith("\n\n")

        for turn in out:
            turn["text"] = " ".join(turn["text"].split())
        return out


_ATTACHMENT_COLUMNS = """
    SELECT a.Z_PK, a.ZTITLE, a.ZTYPEUTI, a.ZMERGEABLEDATA1, a.ZCREATIONDATE,
           m.ZFILENAME,
           (SELECT c.ZFILESIZE FROM ZICCLOUDSYNCINGOBJECT c
             WHERE c.ZPARENTATTACHMENT = a.Z_PK AND c.ZFILESIZE IS NOT NULL
             LIMIT 1),
           (SELECT c.ZDURATION FROM ZICCLOUDSYNCINGOBJECT c
             WHERE c.ZPARENTATTACHMENT = a.Z_PK AND c.ZDURATION IS NOT NULL
             LIMIT 1),
           a.ZNOTE, n.ZTITLE1
      FROM ZICCLOUDSYNCINGOBJECT a
      LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.ZATTACHMENT1 = a.Z_PK
      LEFT JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = a.ZNOTE
"""


def _row_to_attachment(row):
    (pk, title, uti, blob, created, filename, size, duration,
     note, note_title) = row
    return {
        "pk": pk, "title": title, "uti": uti, "blob": blob,
        "filename": filename, "file_size": size, "duration": duration,
        "created": (created + APPLE_EPOCH) if created else None,
        "note": note, "note_title": note_title,
    }


def all_recordings(db_path, with_segments=False):
    """Every audio recording in the store, newest first.

    ⚠️ Filtered on the presence of mergeable data, not on ZTYPEUTI. Audio
    arrives as at least `com.apple.m4a-audio` (call recordings) and
    `public.mp3` (imported files), and a UTI allowlist would silently miss
    whatever Apple adds next. Non-audio mergeable data — tables, drawings,
    galleries, 134 of the 137 attachments on this store — is rejected by the
    decode instead, which cannot go stale.
    """
    conn = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        rows = conn.execute(
            _ATTACHMENT_COLUMNS + """
             WHERE a.ZMERGEABLEDATA1 IS NOT NULL AND a.ZNOTE IS NOT NULL
             ORDER BY a.ZCREATIONDATE DESC
            """
        ).fetchall()
    finally:
        conn.close()

    found = []
    for row in rows:
        attachment = _row_to_attachment(row)
        try:
            data = MergeableData(attachment["blob"])
        except (ValueError, IndexError):
            continue
        if not data.objects(AUDIO_RECORDING):
            continue
        found.append(Recording(data, attachment, with_segments=with_segments))
    return found


def _attachment_rows(db_path, note_pk):
    """Attachment rows for a note that carry mergeable data, plus the child row
    that holds the real file size and duration.

    ⚠️ A recording is TWO attachment rows: a parent carrying the transcript blob
    and a child (ZPARENTATTACHMENT) carrying the media. Reading only the parent
    loses duration and size; reading only the child loses the transcript.
    """
    conn = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        rows = conn.execute(
            _ATTACHMENT_COLUMNS + """
             WHERE a.ZNOTE = ? AND a.ZMERGEABLEDATA1 IS NOT NULL
             ORDER BY a.ZCREATIONDATE
            """,
            (note_pk,),
        ).fetchall()
    finally:
        conn.close()
    return [_row_to_attachment(row) for row in rows]


def recordings_for_note(db_path, note_pk):
    """Every audio recording attached to a note, transcript included.

    Returns [] for a note with no mergeable-data attachments, and skips
    attachments whose blob holds something else (a table, say) rather than
    treating them as empty recordings.
    """
    found = []
    for attachment in _attachment_rows(db_path, note_pk):
        try:
            data = MergeableData(attachment["blob"])
        except (ValueError, IndexError):
            # A blob we cannot parse is not a recording; a table would also land
            # here. Skip rather than fail the whole command.
            continue
        if not data.objects(AUDIO_RECORDING):
            continue
        found.append(Recording(data, attachment))
    return found
