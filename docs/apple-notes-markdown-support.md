# What the Notes Markdown write path supports

🛑 **This file is generated. Do not edit it.**

```
./notes/capability-report            # rewrite this file
./notes/capability-report --check    # fail if anything moved
```

Run it after every macOS update. Apple's Markdown interpreter is
undocumented and it moves; `--check` is the alarm.

| | |
|---|---|
| measured on | macOS 27.0 (26A5406e) |
| cases | 26 |
| constructs Apple keeps | 21 |

Two independent columns. **store** is what Apple did with the Markdown,
which is the API surface. **round trip** is what `apple notes export`
gives back. A construct can survive the write and be lost on the read.

## inline

| markdown | store | round trip | |
|---|---|---|---|
| `**bolded**` | plain + bold | `**bolded**` | ✅ |
| `*italicked*` | plain + italic | `_italicked_` | ✅ |
| `_underscored_` | plain + italic | `_underscored_` | ✅ |
| `***bothmarks***` | plain + bold+italic | `**_bothmarks_**` | ✅ |
| `~~strucked~~` | plain + strikethrough | `~~strucked~~` | ✅ |
| `[anchored](https://example.com/x)` | plain + link | `[anchored](https://example.com/x)` | ✅ |
| `https://example.com/bare` | plain + link | `https://example.com/bare` | ✅ |
| `[**boldlinked**](https://example.com/b)` | plain + link | `[boldlinked](https://example.com/b)` | ✅ |
| `==highlighted==` | plain | `— lost —` | ⚠️ |
| ``codeword`` | plain | `— lost —` | ⚠️ |
| `escaped 2 \* 3` | plain | `escaped 2 \* 3` | ✅ |
| `emojied 🎢 tail` | plain | `emojied 🎢 tail` | ✅ |

- **italic (star)** — `*x*` and `_x_` both store weight 2, so the reader emits `_x_`
- **bold italic** — 🛑 `font_weight` 3 means BOTH; reading bold as `== 1` drops it
- **bare URL** — the text is the URL, so the reader emits it bare, not `[url](url)`
- **bold inside a link** — 🛑 Apple DROPS the bold inside link text; the link survives
- **highlight** — 🛑 Apple has no `==` syntax; the text stays, the highlight does not
- **inline code** — 🛑 the text stays and the monospace style is not applied
- **escaped asterisk** — a literal `*` survives, and the reader re-escapes it
- **emoji** — ⚠️ an astral char is 2 UTF-16 units; run offsets must account for it

## block

| markdown | store | round trip | |
|---|---|---|---|
| `## headingtwo` | heading + bold | `## **headingtwo**` | ✅ |
| `### headingthree` | subheading + bold | `### **headingthree**` | ✅ |
| `# headingone` | title + bold | `# **headingone**` | ✅ |
| `- bulletone ⏎ - bullettwo` | dashed list | `- bulletone ⏎ - bullettwo` | ✅ |
| `1. numberone ⏎ 2. numbertwo` | numbered list | `1. numberone ⏎ 1. numbertwo` | ✅ |
| `- [ ] taskopen` | checklist, done=0 | `- [ ] taskopen` | ✅ |
| `- [x] taskdone` | checklist, done=1 | `- [x] taskdone` | ✅ |
| `- [X] taskupper` | dashed list | `- [X] taskupper` | ✅ |
| `* [x] taskstar` | bullet | `- [x] taskstar` | ✅ |
| `> quoted line` | plain | `— lost —` | ⚠️ |
| `- outerone ⏎   - innerone` | dashed list | `— lost —` | ⚠️ |
| ```` ⏎ fencedcode ⏎ ```` | monospace | `— lost —` | ⚠️ |
| `---` | attachment: dividerline | `---` | ✅ |

- **heading 2** — Notes makes a heading bold, and the reader reports both
- **heading 1** — 🛑 `#` becomes the TITLE style (0), not a heading (1). A title paragraph mid-note is a real thing and the reader ignored it
- **numbered list** — ⚠️ the reader always emits `1.`; the rendering is unchanged
- **checked task** — 🛑 this DOES work; an earlier conclusion that it did not was wrong
- **uppercase task** — 🛑 only lowercase `x` makes a checklist
- **star bullet task** — 🛑 a `*` bullet is not read as a checklist
- **blockquote** — 🛑 Notes has no blockquote; the `>` is consumed
- **nested bullet** — indent level is stored; the reader's expectation is unverified
- **code fence** — the fence markers are consumed; style is reported by the report

## table

| markdown | store | round trip | |
|---|---|---|---|
| `\| ColA \| ColB \| ⏎ \| --- \| --- \| ⏎ \| cellone \| **cellbold** \|` | attachment: table | `\| cellone \| **cellbold** \|` | ✅ |

- **pipe table** — a real `com.apple.notes.table`; the cells live in its own blob

## 🛑 A pipe table destroys the last item of the list above it

That item becomes a plain paragraph. It is not about the checked
state, and not about checklists — plain bullets lose their last item
too. One paragraph between the list and the table prevents it.

| sequence | first item | last item |
|---|---|---|
| checklist, no table after | checklist | checklist |
| checklist, then a table | checklist | plain |
| plain bullets, then a table | dashed list | plain |
| checklist, paragraph, table | checklist | checklist |

⚠️ This is what made `- [x]` look unsupported. A probe that
"proved" it had a table on the next line.

