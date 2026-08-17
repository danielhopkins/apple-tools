"""Minimal protobuf reader for Apple Notes' NoteStore blobs.

Apple stores note bodies as gzipped protobuf in ZICNOTEDATA.ZDATA. We only ever
read a handful of fields, so rather than depend on the `protobuf` package (and
the generated bindings, and a virtualenv to hold them) this decodes the wire
format directly with the standard library.

Field numbers come from notestore.proto, which stays alongside this file as the
authoritative schema reference.
"""

import re
import struct

# Wire types (https://protobuf.dev/programming-guides/encoding/)
VARINT = 0
FIXED64 = 1
LENGTH_DELIMITED = 2
FIXED32 = 5


def _read_varint(buf, pos):
    """Return (value, next_pos). Varints are 7 bits per byte, little-endian."""
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated varint")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


class Message:
    """A parsed protobuf message, addressed by field number.

    Fields are kept as a list per number so repeated fields work, and so
    presence (`has`) is distinguishable from a zero value — which matters
    because the caller's rendering depends on HasField semantics.
    """

    __slots__ = ("_fields",)

    def __init__(self, data=b""):
        self._fields = {}
        pos = 0
        end = len(data)
        while pos < end:
            key, pos = _read_varint(data, pos)
            field_number = key >> 3
            wire_type = key & 0x07

            if wire_type == VARINT:
                value, pos = _read_varint(data, pos)
            elif wire_type == LENGTH_DELIMITED:
                length, pos = _read_varint(data, pos)
                if pos + length > end:
                    raise ValueError("truncated length-delimited field")
                value = data[pos:pos + length]
                pos += length
            elif wire_type == FIXED32:
                value = data[pos:pos + 4]
                pos += 4
            elif wire_type == FIXED64:
                value = data[pos:pos + 8]
                pos += 8
            else:
                # Groups (3, 4) are deprecated and absent from this schema.
                raise ValueError(f"unsupported wire type {wire_type}")

            self._fields.setdefault(field_number, []).append(value)

    def has(self, number):
        return number in self._fields

    def _first(self, number, default=None):
        values = self._fields.get(number)
        return values[0] if values else default

    def varint(self, number, default=0):
        value = self._first(number)
        return default if value is None else value

    def int32(self, number, default=0):
        """Signed variant. proto2 encodes negative int32 as a 10-byte varint,
        so anything above the signed range is really a negative number."""
        value = self._first(number)
        if value is None:
            return default
        return value - (1 << 64) if value >= 1 << 63 else value

    def string(self, number, default=None):
        value = self._first(number)
        if value is None:
            return default
        return value.decode("utf-8", errors="replace")

    def float32(self, number, default=0.0):
        value = self._first(number)
        if value is None or len(value) != 4:
            return default
        return struct.unpack("<f", value)[0]

    def float64(self, number, default=None):
        """FIXED64 read as a double. ObjectID.double_value uses this, and it is
        where every call-recording timestamp lives — see mergeable.py."""
        value = self._first(number)
        if value is None or len(value) != 8:
            return default
        return struct.unpack("<d", value)[0]

    def message(self, number):
        """Sub-message, or None when the field is absent."""
        value = self._first(number)
        return None if value is None else Message(value)

    def messages(self, number):
        """All occurrences of a repeated sub-message field."""
        return [Message(value) for value in self._fields.get(number, [])]


class Color:
    """Color as stored on an AttributeRun (fields 1-4, all floats)."""

    __slots__ = ("red", "green", "blue", "alpha")

    def __init__(self, message):
        self.red = message.float32(1)
        self.green = message.float32(2)
        self.blue = message.float32(3)
        self.alpha = message.float32(4)


def is_highlight_color(color):
    """Is this the yellow background Notes uses for a highlight?

    Lives here rather than in the CLI because the note body and a table cell
    both need it, and they are read by two different modules. Typical values:
    red~1.0, green~0.95, blue~0.55, alpha~1.0.
    """
    if color is None:
        return False
    return (
        color.red > 0.9
        and color.green > 0.8
        and color.blue < 0.7
        and color.alpha > 0.5
    )


# 🛑 Schemes Notes generates by itself. `x-apple-data-detectors` is Notes
# recognising a date or an address in text the user typed; `x-coredata` is an
# internal row reference. Neither is a link the user made, and rendering one as
# Markdown invents a link that was never there. One of each on the development
# store.
SYNTHETIC_LINK_SCHEMES = ("x-apple-data-detectors", "x-coredata")

_URI = re.compile(r"^[a-z][a-z0-9+.\-]*:", re.IGNORECASE)


def looks_like_uri(value):
    """Does this string start with a URI scheme?

    ⚠️ An inline attachment's token is NOT always a URI. A note link carries
    `applenotes:note/<uuid>`, but a hashtag carries a bare word (`TRIPS`) and a
    mention carries an account id. Only the ones that parse as a URI may be
    turned into a link.
    """
    return bool(value) and bool(_URI.match(value))


def usable_link(url):
    """The URL if it is a link the user made, else None."""
    if not url or not looks_like_uri(url):
        return None
    if url.split(":", 1)[0].lower() in SYNTHETIC_LINK_SCHEMES:
        return None
    return url


def run_link(run):
    """The URL on this AttributeRun, or None when it is not a real link."""
    return usable_link(run.string(9))


def markdown_link(text, url):
    """`[text](url)`, keeping any surrounding space outside the brackets.

    ⚠️ **A pasted link has the URL as its own text**, and `[url](url)` is
    noise. 88 of 297 body links on the development store are this shape, so the
    bare URL is emitted instead.
    """
    core = text.strip()
    if not url or not core:
        return text
    if core == url.strip():
        return text
    lead = text[:len(text) - len(text.lstrip())]
    trail = text[len(text.rstrip()):]
    return "%s[%s](%s)%s" % (lead, core, url, trail)


# 🛑 Every character `str.splitlines()` treats as a line break while
# `str.split("\n")` does not. A renderer breaks the line at each of these, so a
# marker span crossing one is left unbalanced on both halves.
#
# Notes writes U+2028 for Shift-Return (254 here, 239 of them in plain
# paragraphs), and `\r` survives in pasted text — a bold run holding `'\r\n'`
# is what exposed this. The rest cost nothing to include and fail invisibly.
SOFT_LINE_BREAKS = "\r\v\f\x1c\x1d\x1e\x85  "


def _escapes(char, previous, following):
    """Should this source character be escaped, given its two neighbours?

    Escapes only what can be read as a marker this tool emits:
    `**bold**`, `==highlight==` and the backslash that does the escaping.

    ⚠️ **`=` is escaped only next to another `=`.** A lone `=` is never a
    marker, and `=` is common in URLs and in prose. Measured here: 1 `==` in
    the whole store against many single ones.

    ⚠️ **`_` is escaped only when it is not inside a word.** CommonMark ignores
    an intraword underscore, and 183 of the 196 here are intraword — escaping
    them all would turn every `snake_case` name into noise.

    🛑 **`[` and `]` are deliberately NOT escaped.** They only form a link next
    to a `](`, and **no note in the store contains that sequence**. Escaping 75
    bracket pairs to guard a case that does not occur costs readability for
    nothing. Re-measure before assuming it still holds.
    """
    if char in "\\*":
        return True
    if char in "=~":
        # Only a doubled `=` or `~` is a marker, and both are common alone.
        return previous == char or following == char
    if char == "_":
        return not (previous.isalnum() and following.isalnum())
    return False


def escape_markdown_char(char, previous="", following=""):
    """One source character, escaped if it could be read as a marker."""
    return "\\" + char if _escapes(char, previous, following) else char


def escape_markdown(text):
    """A whole source string, escaped the same way `escape_markdown_char` is.

    The two are kept in step by a test that runs both over the same string.
    """
    out = []
    for i, char in enumerate(text):
        out.append(escape_markdown_char(
            char, text[i - 1] if i else "", text[i + 1] if i + 1 < len(text) else ""))
    return "".join(out)


# `font_weight` is a small enum, not a weight. Measured by writing
# `**b**`, `*i*` and `***both***` through the Markdown write path and reading
# the store back:
#
#   0  normal      8274 runs here
#   1  bold        4612
#   2  italic       436
#   3  bold+italic   15
#
# 🛑 **3 carries bold as well**, and `run_is_bold` used to test `== 1`, so those
# 15 runs lost their bold silently.
BOLD_WEIGHTS = (1, 3)
ITALIC_WEIGHTS = (2, 3)


def run_is_bold(run):
    """Is this AttributeRun bold? Weights 1 and 3 both are."""
    return run.int32(5) in BOLD_WEIGHTS


def run_is_italic(run):
    """Is this AttributeRun italic? Weights 2 and 3 both are.

    ⚠️ Both `*text*` and `_text_` produce weight 2, so the two spellings are
    indistinguishable once stored. The reader emits `*text*`.
    """
    return run.int32(5) in ITALIC_WEIGHTS


def run_is_strikethrough(run):
    """Is this AttributeRun struck through? Field 7."""
    return bool(run.int32(7))


def run_is_highlight(run):
    """Is this AttributeRun highlighted? Reads the colour on field 10."""
    color = run.message(10)
    return is_highlight_color(Color(color)) if color is not None else False


# Inline marks, outermost first. Closing happens in reverse, so a bold italic
# link reads `***[text](url)***` rather than an interleaved, unparseable mix.
def _open_link(url):
    return "["


def _close_link(url):
    return "](%s)" % url


# 🛑 **Italic is `_`, not `*`, and that is load-bearing.** With `*` for italic,
# a bold-italic span followed by an italic one emits `***GCP****` — the closing
# `***` runs straight into the reopening `*`. Two real notes here do exactly
# that. `_` cannot collide with `**`, so `**_GCP_**` then `_…_` stays readable
# and unambiguous. Literal non-intraword `_` is already escaped, so the two
# rules agree.
MARKS = (
    ("bold", lambda v: "**", lambda v: "**"),
    ("italic", lambda v: "_", lambda v: "_"),
    ("highlight", lambda v: "==", lambda v: "=="),
    ("strikethrough", lambda v: "~~", lambda v: "~~"),
    ("link", _open_link, _close_link),
)


def marks_of(run):
    """The inline marks on this AttributeRun, in MARKS order."""
    return (run_is_bold(run), run_is_italic(run), run_is_highlight(run),
            run_is_strikethrough(run), run_link(run))


def mark_transition(old, new):
    """Markers to emit when the active marks change from `old` to `new`.

    Closes only what must close. A run of bold text whose italic ends part way
    through keeps one bold span, rather than splitting into `**a****b**`.
    """
    first = 0
    while first < len(MARKS) and old[first] == new[first]:
        first += 1
    if first == len(MARKS):
        return ""
    out = []
    for i in range(len(MARKS) - 1, first - 1, -1):
        if old[i]:
            out.append(MARKS[i][2](old[i]))
    for i in range(first, len(MARKS)):
        if new[i]:
            out.append(MARKS[i][1](new[i]))
    return "".join(out)


NO_MARKS = (False, False, False, False, None)


def parse_note_store(data):
    """Decode a NoteStoreProto blob down to its Note message.

    NoteStoreProto.document = 2 -> Document.note = 3
    Returns None if either level is missing.
    """
    document = Message(data).message(2)
    if document is None:
        return None
    return document.message(3)
