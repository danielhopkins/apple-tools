"""Minimal protobuf reader for Apple Notes' NoteStore blobs.

Apple stores note bodies as gzipped protobuf in ZICNOTEDATA.ZDATA. We only ever
read a handful of fields, so rather than depend on the `protobuf` package (and
the generated bindings, and a virtualenv to hold them) this decodes the wire
format directly with the standard library.

Field numbers come from notestore.proto, which stays alongside this file as the
authoritative schema reference.
"""

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


def parse_note_store(data):
    """Decode a NoteStoreProto blob down to its Note message.

    NoteStoreProto.document = 2 -> Document.note = 3
    Returns None if either level is missing.
    """
    document = Message(data).message(2)
    if document is None:
        return None
    return document.message(3)
