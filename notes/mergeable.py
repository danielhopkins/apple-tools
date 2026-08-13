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

import sqlite3

from notestore import Message

# Type names that wrap a single scalar, and the keys they carry it under.
_SCALAR_STRING = ("com.apple.CRDT.NSString", "com.apple.CRDT.NSUUID")
_SCALAR_NUMBER = ("com.apple.CRDT.NSNumber", "com.apple.CRDT.NSDate")

AUDIO_RECORDING = "com.apple.notes.ICTTAudioRecording"
FRAGMENT = "com.apple.notes.ICTTAudioRecording.Fragment"
TRANSCRIPT_SEGMENT = "com.apple.notes.ICTTTranscriptSegment"

# Apple epoch (2001-01-01) to Unix epoch, seconds.
APPLE_EPOCH = 978307200


class MergeableData:
    """The object graph in one ZMERGEABLEDATA1 blob."""

    def __init__(self, blob):
        root = Message(blob)
        self.entries = [Message(v) for v in root._fields.get(3, [])]
        self.keys = [v.decode("utf-8", "replace") for v in root._fields.get(4, [])]
        self.types = [v.decode("utf-8", "replace") for v in root._fields.get(5, [])]

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
