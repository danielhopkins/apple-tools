# TODO: get the Notes suite off live Notes.app

**Problem.** The suite cannot run in CI and writes to the user's real iCloud
data, because almost every test drives live Notes.app. Speed is a secondary
concern — see the correction below.

⚠️ **A number in an earlier draft of this file was wrong.** It claimed ~5.5
minutes per run and used that as the headline argument. Re-measured with
Notes.app idle:

| condition | full suite |
|---|---|
| Notes.app idle | **84s, 89s, 81s** |
| Notes.app busy (concurrent shortcut runs, probes) | 328s, 357s, 356s |

The 5.5-minute figure was measured while the same machine was hammering Notes
with Shortcuts calls and attachment probes. It was self-inflicted load, not the
suite's cost. **Propagation lag scales with how busy Notes.app is**, which is
worth knowing in its own right — but it means speed is a weak argument for this
work, and the honest case is narrower:

- **It cannot run in CI.** No Notes.app, no iCloud, no grant. So none of the
  rendering or reading behaviour is covered anywhere but one laptop.
- **It writes to real data.** Gated behind `RUN_LIVE_NOTES_TESTS=1` for exactly
  that reason, which also means it is rarely run.
- **It depends on one person's notes.** Several assertions would read
  differently on a store with different content.

The remaining speed gap is real but modest: 9 offline tests take 3.1s (0.34s
each) against ~42 live ones in ~81s (~1.9s each), so roughly 6× — not the 25×
the earlier draft claimed.

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

Realistic outcome: ~10 tests move and the suite drops by perhaps 20s. **The
time saved is not the point** — the prize is that the rendering half becomes
CI-able and stops depending on the contents of one person's Notes.

## Related

Two things already fixed that were making it worse than it needed to be — do
not re-introduce them:

- `run-tests` takes an exclusive lock. Two concurrent runs sweep each other's
  notes and fail in ways that look like real bugs.
- Fixtures carry per-call nonces. Byte-identical fixtures made "did *my* file
  land on disk?" assertions match another test's copy.

Both are documented at their call sites in
`tests/test_attachment_roundtrip.py` and `notes/run-tests`.
