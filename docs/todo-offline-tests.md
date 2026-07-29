# TODO: get the Notes suite off live Notes.app

**Problem.** A full run takes **~5.5 minutes** and cannot run in CI, because
almost every test drives live Notes.app and writes to the user's real iCloud.
That makes the suite something you avoid running, which is the opposite of what
a suite pinning this much fragile behaviour should be.

**The number is lopsided**, and that is the whole argument:

| | tests | time | needs Notes.app? |
|---|---|---|---|
| `test_locked_notes` | 9 | **3.1s** | no |
| everything else | 42 | ~337s | yes |

**8 seconds per live test against 0.3 for an offline one** — roughly 25×. The
cost is not compute, it is waiting: each live test creates a note through
AppleScript, waits for it to propagate into SQLite, asserts, then deletes it.
The waiting is not incidental — propagation lag is precisely what several of
these tests exist to pin.

## The pattern already works

`tests/test_locked_notes.py` is the proof. It copies `NoteStore.sqlite` to a
temp directory, flips `ZISPASSWORDPROTECTED` on a throwaway row, and runs the
real CLI against that copy. Nine tests, 3.1 seconds, no Notes.app, no iCloud, no
`RUN_LIVE_NOTES_TESTS` gate, and it works whether or not the machine happens to
own a locked note.

## What can move

- [ ] **`tests/test_rendering.py`** (7 tests) — these look like pure functions
      over decoded protobuf (`apply_formatting`, `format_as_markdown`). If so
      they need no live Notes at all and the gate is pure ceremony. **Check
      first**; if true this is nearly free.
- [ ] **`tests/test_reading.py`** (3) — partly. The SQLite-side assertions can
      run against a copied store; the "matches AppleScript" one cannot, by
      definition.
- [ ] **A fixture corpus.** The bigger win, and the one
      [`prior-art.md`](prior-art.md) points at: check in gzipped protobuf note
      bodies named for what they exercise, the way
      `apple_cloud_notes_parser/spec/data/exported_blobs/` does
      (`block_quotes`, `color_formatting`, `list_indents`, `right_to_left_table`,
      `text_decorations`, `wide_characters`…). That would let the whole
      rendering half run in CI, where today none of it can, and would cover
      cases we have no way to create through AppleScript.
- [ ] **Per-macOS-version `NoteStore.sqlite` fixtures**, as
      `RhetTbull/apple-notes-parser` ships (Monterey → Tahoe, one test module
      per version). The only way to catch a schema change before a user does.

## What cannot move

The attachment and editing tests are testing *what AppleScript does* — the
double-insert, the body-write destruction, the checklist flattening. Verifying
that requires doing it, against the real app. They stay live and stay gated.

Realistic outcome: ~10 tests move, 5.5 min → ~4. The real prize is not the
minute saved but that the rendering half becomes CI-able and stops depending on
the contents of one person's Notes.

## Related

Two things already fixed that were making it worse than it needed to be — do
not re-introduce them:

- `run-tests` takes an exclusive lock. Two concurrent runs sweep each other's
  notes and fail in ways that look like real bugs.
- Fixtures carry per-call nonces. Byte-identical fixtures made "did *my* file
  land on disk?" assertions match another test's copy.

Both are documented at their call sites in
`tests/test_attachment_roundtrip.py` and `notes/run-tests`.
