"""The Markdown capability matrix, as data.

🛑 **This file is the single source of truth for "what works".** The unittest
suite asserts it, and `notes/capability-report` renders it into
`docs/apple-notes-markdown-support.md`. Nothing about Apple's Markdown support
should be written down anywhere else by hand — three wrong conclusions came out
of hand-probing before this existed.

Each Case measures **two different things**, and they fail independently:

  `store`      what APPLE did with the Markdown — the paragraph style and run
               attributes it wrote. This is the API surface. When a macOS
               update changes it, these are the assertions that move.

  `roundtrip`  what OUR reader gives back when it re-renders that note. A
               construct can survive the write and still be lost on the read,
               which is exactly what happened to italic and strikethrough.

⚠️ **`roundtrip=None` means "not expected to survive"**, not "not checked". The
report prints it as a known loss.
"""

# Paragraph style_type values Notes uses (see notestore.proto).
PLAIN, TITLE, HEADING, SUBHEADING, MONO = -1, 0, 1, 2, 4
BULLET, DASHED, NUMBERED, CHECKLIST = 100, 101, 102, 103

STYLE_NAMES = {
    PLAIN: "plain", TITLE: "title", HEADING: "heading",
    SUBHEADING: "subheading", MONO: "monospace", BULLET: "bullet",
    DASHED: "dashed list", NUMBERED: "numbered list", CHECKLIST: "checklist",
}


class Case:
    """One Markdown construct, and what it becomes.

    `probe` is the word whose AttributeRun gets inspected. It must be unique
    across the whole matrix, because every case shares one note.
    """

    def __init__(self, group, name, md, probe, *, style=PLAIN, attrs=None,
                 checked=None, roundtrip=..., note="", attachment_uti=None):
        self.group = group
        self.name = name
        self.md = md
        self.probe = probe
        self.style = style
        self.attrs = attrs or {}
        self.checked = checked
        # A table and a divider are attachments, not text. There is no run to
        # probe by word, so these are matched on the attachment's UTI instead.
        self.attachment_uti = attachment_uti
        # `...` means "expect the input back unchanged"; None means "lost".
        self.roundtrip = md if roundtrip is ... else roundtrip
        self.note = note

    @property
    def supported(self):
        return self.roundtrip is not None

    def __repr__(self):
        return "<Case %s/%s>" % (self.group, self.name)


CASES = [
    # -- inline marks ------------------------------------------------------ #
    Case("inline", "bold", "**bolded**", "bolded", attrs={"bold": True}),
    Case("inline", "italic (star)", "*italicked*", "italicked",
         attrs={"italic": True}, roundtrip="_italicked_",
         note="`*x*` and `_x_` both store weight 2, so the reader emits `_x_`"),
    Case("inline", "italic (underscore)", "_underscored_", "underscored",
         attrs={"italic": True}, roundtrip="_underscored_"),
    Case("inline", "bold italic", "***bothmarks***", "bothmarks",
         attrs={"bold": True, "italic": True}, roundtrip="**_bothmarks_**",
         note="🛑 `font_weight` 3 means BOTH; reading bold as `== 1` drops it"),
    Case("inline", "strikethrough", "~~strucked~~", "strucked",
         attrs={"strikethrough": 1}),
    Case("inline", "inline link", "[anchored](https://example.com/x)",
         "anchored", attrs={"link": "https://example.com/x"}),
    Case("inline", "bare URL", "https://example.com/bare", "https://example.com/bare",
         attrs={"link": "https://example.com/bare"},
         note="the text is the URL, so the reader emits it bare, not `[url](url)`"),
    Case("inline", "bold inside a link",
         "[**boldlinked**](https://example.com/b)", "boldlinked",
         attrs={"bold": False, "link": "https://example.com/b"},
         roundtrip="[boldlinked](https://example.com/b)",
         note="🛑 Apple DROPS the bold inside link text; the link survives"),
    Case("inline", "highlight", "==highlighted==", "highlighted",
         attrs={"highlight": False}, roundtrip=None,
         note="🛑 Apple has no `==` syntax; the text stays, the highlight does not"),
    Case("inline", "inline code", "`codeword`", "codeword", style=PLAIN,
         roundtrip=None,
         note="🛑 the text stays and the monospace style is not applied"),
    Case("inline", "escaped asterisk", r"escaped 2 \* 3", "escaped",
         roundtrip=r"escaped 2 \* 3",
         note="a literal `*` survives, and the reader re-escapes it"),
    Case("inline", "emoji", "emojied 🎢 tail", "emojied",
         roundtrip="emojied 🎢 tail",
         note="⚠️ an astral char is 2 UTF-16 units; run offsets must account for it"),

    # -- paragraph styles -------------------------------------------------- #
    Case("block", "heading 2", "## headingtwo", "headingtwo", style=HEADING,
         roundtrip="## **headingtwo**",
         note="Notes makes a heading bold, and the reader reports both"),
    Case("block", "heading 3", "### headingthree", "headingthree",
         style=SUBHEADING, roundtrip="### **headingthree**"),
    Case("block", "heading 1", "# headingone", "headingone", style=TITLE,
         roundtrip="# **headingone**",
         note="🛑 `#` becomes the TITLE style (0), not a heading (1). A title "
              "paragraph mid-note is a real thing and the reader ignored it"),
    Case("block", "bullet list", "- bulletone\n- bullettwo", "bulletone",
         style=DASHED, roundtrip="- bulletone\n- bullettwo"),
    Case("block", "numbered list", "1. numberone\n2. numbertwo", "numberone",
         style=NUMBERED, roundtrip="1. numberone\n1. numbertwo",
         note="⚠️ the reader always emits `1.`; the rendering is unchanged"),
    Case("block", "unchecked task", "- [ ] taskopen", "taskopen",
         style=CHECKLIST, checked=0, roundtrip="- [ ] taskopen"),
    Case("block", "checked task", "- [x] taskdone", "taskdone",
         style=CHECKLIST, checked=1, roundtrip="- [x] taskdone",
         note="🛑 this DOES work; an earlier conclusion that it did not was wrong"),
    Case("block", "uppercase task", "- [X] taskupper", "[X] taskupper",
         style=DASHED, roundtrip="- [X] taskupper",
         note="🛑 only lowercase `x` makes a checklist"),
    Case("block", "star bullet task", "* [x] taskstar", "[x] taskstar",
         style=BULLET, roundtrip="- [x] taskstar",
         note="🛑 a `*` bullet is not read as a checklist"),
    Case("block", "blockquote", "> quoted line", "quoted", style=PLAIN,
         roundtrip=None, note="🛑 Notes has no blockquote; the `>` is consumed"),
    Case("block", "nested bullet", "- outerone\n  - innerone", "innerone",
         style=DASHED, roundtrip=None,
         note="indent level is stored; the reader's expectation is unverified"),
    Case("block", "code fence", "```\nfencedcode\n```", "fencedcode",
         style=MONO, roundtrip=None,
         note="the fence markers are consumed; style is reported by the report"),

    # -- block constructs -------------------------------------------------- #
    Case("table", "pipe table",
         "| ColA | ColB |\n| --- | --- |\n| cellone | **cellbold** |",
         "cellone", attachment_uti="com.apple.notes.table",
         roundtrip="| cellone | **cellbold** |",
         note="a real `com.apple.notes.table`; the cells live in its own blob"),
    Case("block", "divider", "---", "---",
         attachment_uti="com.apple.notes.inlinetextattachment.dividerline",
         roundtrip="---"),
]


# 🛑 A pipe table destroys the LAST item of the list directly above it, so every
# case is separated by a spacer paragraph. Without it the matrix measures the
# bug rather than the construct.
SPACER = "spacer"


def probe_body(title):
    """One note carrying every case, each isolated by a spacer paragraph."""
    parts = [title, ""]
    for case in CASES:
        parts.append(case.md)
        parts.append("")
        parts.append(SPACER)
        parts.append("")
    return "\n".join(parts)


# 🛑 The list-before-table bug, as its own fixture. It is not part of the matrix
# because it is a property of the *sequence*, not of any one construct.
TABLE_EATS_BODY = """%s

A no table after

- [x] aaone
- [x] aatwo

B table after

- [x] bbone
- [x] bbtwo

| X | Y |
| --- | --- |
| 1 | 2 |

C plain bullets then table

- ccone
- cctwo

| X | Y |
| --- | --- |
| 1 | 2 |

D paragraph between

- [x] ddone
- [x] ddtwo

spacer

| X | Y |
| --- | --- |
| 1 | 2 |
"""
