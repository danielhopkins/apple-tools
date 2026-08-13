# Call recordings, voice memos, and their transcripts

`apple notes transcript` and `apple notes summary` read audio recordings stored
on a note. This is the record of where that data actually lives and what it took
to decode, because none of it is where you would first look.

## Where a recording lives

An iPhone call recording syncs to the Mac as an ordinary note. On this store it
landed in the **default `Notes` folder**, not in a dedicated "Call Recordings"
folder — do not go looking for the folder, look for the attachment.

🛑 **The transcript is not in the note body.** `apple notes export` on a
recording returns four lines:

```
# Call Recording

[attachment: Call Recording]
```

The body holds a single attachment placeholder and nothing else. `ZSNIPPET` is
NULL, and the note's `ZMODIFICATIONDATE1` **never moves** when a transcript
arrives. Anything watching the body, the snippet, or the modification date to
detect transcription will wait forever.

⚠️ **`ZNEEDSTRANSCRIPTION`, `ZTEMPORARYTRANSCRIPTDATA` and `ZSUMMARY` are all
NULL** on a note whose transcript is complete and visible in Notes.app. They are
staging columns, not storage. On the store here, **zero rows** carry transcript
data in any of them.

Everything — audio metadata, transcript, speaker handles and Apple's summary —
is in **`ZICCLOUDSYNCINGOBJECT.ZMERGEABLEDATA1`** on the attachment row.

## Two attachment rows per recording

A recording is a **parent** row and a **child** row:

| | parent | child |
|---|---|---|
| `ZTYPEUTI` | `com.apple.m4a-audio` | `public.mpeg-4-audio` |
| carries | `ZMERGEABLEDATA1` (the transcript) | `ZFILESIZE`, `ZDURATION` |
| media file | `Call Recording.m4a` | `moments_<ts>-audio.MOV` |

Reading only the parent loses duration and size; reading only the child loses
the transcript. `mergeable.py` joins them via `ZPARENTATTACHMENT`.

The audio itself is on disk under
`~/Library/Group Containers/group.com.apple.notes/Accounts/<uuid>/Media/<media-uuid>/<generation>/`,
already decoded — no MIME parsing, unlike mail attachments.

## The blob format

`ZMERGEABLEDATA1` is the same machinery Notes uses for tables, and the repo's
`notestore.proto` already described most of it. The root is a
`MergeableDataObjectData`: one flat array of entries plus three lookup tables
(key names, type names, UUIDs). Objects address each other by index into the
entry array, so reading anything means walking a graph.

Three things had to be discovered to make it decode:

🛑 **Every index is 0-based.** Both the lookup tables and `ObjectID.object_index`.
The published schemas this file came from are 1-based, and a 1-based reading here
does not error — it makes the root `ICTTAudioRecording` reference *itself* as its
own first field and recurse until the depth guard stops it.

🛑 **`ObjectID` field 3 is a fixed64 double.** It is absent from every published
version of the schema, because tables never use it. It is the only place a
timestamp appears. Without it every segment has a null timestamp and the
transcript cannot be ordered at all.

🛑 **`callRecordingStartTime` is UNIX epoch, not Apple epoch** — the only date in
this repo that is. Every `ZDATE`/`ZCREATIONDATE` column beside it is Apple epoch.
Converting this one the same way puts the call in **2057** while still looking
like a plausible date.

Scalars are wrapped: a value reached through `RegisterLatest` (field 1, contents
in field 2) resolves to a `com.apple.CRDT.NSString` / `NSNumber` / `NSDate`
custom_map carrying one payload key. A `RegisterLatest` with **no** field 2 is a
genuine "no value" — that is what an absent `summary` looks like — not an error.

## The object model

```
com.apple.notes.ICTTAudioRecording          one per recording
  topLineSummary          the line Notes.app labels "Preview"
  summary                 longer summary; frequently absent
  callLocalSpeakerHandle  your number       call recordings only
  callRemoteSpeakerHandle the other party   call recordings only
  callRecordingStartTime  🛑 UNIX epoch
  fragments               -> Fragment

com.apple.notes.ICTTAudioRecording.Fragment
  transcript              -> CRDT text object; its Note body is one U+FFFC
                             per segment and holds no words

com.apple.notes.ICTTTranscriptSegment       ⚠️ ONE PER WORD
  speaker, text, timestamp, duration
```

⚠️ **Segments are per-word and stored in CRDT insertion order**, which is not
reading order. The first words in the blob are `' Yeah.'`, `' much'`, `' pulled'`
— scattered from all over the call. **Sort on `timestamp`.** No CRDT tree
reconstruction is needed, which is the one piece of luck in this format: the
timestamps make the ordering free.

## Two tokenizations, and the trap between them

🛑 **Words are tokenized differently depending on the source, and a naive join
silently corrupts one of them.**

| source | segment text | join needs |
|---|---|---|
| call recording | `'Hi,'`, `' this'`, `' is'` — **leading space** | plain concatenation |
| imported audio | `'Thank'`, `'you'`, `'much.\n\n'` — **bare, trailing newline** | inserted space |

Concatenating the second kind directly produces `Thankyousomuch.` — which is
still plausible-looking prose, and is exactly the kind of thing that survives
review. `Recording.turns()` inserts the separator neither side supplied.

⚠️ **A single-speaker recording has no speaker changes**, so grouping on speaker
alone collapses a 2,189-word speech into one turn. Turns also break on a
paragraph-ending `\n\n`.

⚠️ **Only call recordings have speaker handles.** A voice memo or imported file
transcribes with `speaker` NULL on every segment. Labelling those "Unknown"
reads as a failed contact lookup rather than "one unnamed voice", so they get no
label at all.

## Verified on this store

100 notes carry mergeable data. By attachment type:

| `ZTYPEUTI` | count | transcript |
|---|---|---|
| `com.apple.notes.table` | 76 | n/a |
| `com.apple.drawing.2` | 52 | n/a |
| `com.apple.notes.gallery` | 6 | n/a |
| `public.mp3` | 2 | yes |
| `com.apple.m4a-audio` | 1 | yes |

All three audio attachments decoded; the other 134 skip cleanly rather than
being reported as empty recordings. No crashes across all 100.

On the call recording: **2,228 segments, 178 turns**, last timestamp 892.28s
against an 893.04s recording — full coverage, with per-word speaker attribution
that renders genuine interruptions rather than errors.

## A recording is not a call

🛑 **The recorded audio is a subset of the call, and nothing in the note says
how much.** Recording is started by hand, at any point, and stops when it is
stopped. Measured against CallHistory for the one call here:

| | |
|---|---|
| call started | 15:59:38, **outgoing**, 1745s (29m05s) |
| recording started | 16:13:49 — **14 minutes in** |
| recording length | 893s (14m53s), ending with the call |
| first transcribed word | **1:33 into the recording** — the rest was hold |

So three separate things get conflated if you are not careful: call length,
recording length, and speech length. `recordings` prints the **recording**
length and says so.

⚠️ **Hold time and IVR produce no segments at all.** A recording can open with
minutes of silence that is simply absent from the transcript rather than marked.
The first segment's `timestamp` is the only indication, and it is not zero.

⚠️ **This also defeats the obvious join to CallHistory.** Neither start time nor
duration matches — the recording starts mid-call and is shorter. Matching
requires interval containment (recording start falls within
`[call start, call start + duration]`), and even that is ambiguous when
somebody rings the same number repeatedly, as happened here: four calls to
`8009220204` inside 30 minutes.

## Direction is not in the note

⚠️ **`callType` is reported raw and nothing derives a direction from it.** It
reads `0` on the one call available, and one sample cannot say whether `0` means
incoming or outgoing. `callRecording` reads `2`, also unmapped.

The note data records *who the two parties were*, not who dialled. CallHistory
knows (`apple phone recents` reported this call as `outgoing`), but joining the
two stores is unreliable for the reasons above, so `recordings` labels its
columns **YOU** and **OTHER PARTY** rather than FROM and TO.

## Known gaps

- ⚠️ **One call recording was available to test against**, and it had a single
  fragment. The multi-fragment path is implemented but unexercised.
- `callType` and `callRecording` resolve to `None` — they are `NSNumber`s whose
  payload is under neither `doubleValue` nor `integerValue`. Nothing needs them
  yet.
- Whether transcription happens at all is an **on-device Apple Intelligence**
  decision. A device without it, or an unsupported language, records audio only,
  and the store then holds a recording with zero segments. Both commands report
  that as an answer rather than as a decode failure.
