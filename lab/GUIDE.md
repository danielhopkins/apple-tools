# apple-index — the operating guide

CLAUDE.md points here. This file holds the rules for using and changing `apple-index`: the `files` source, `people`, `whereabouts`, `places`, the photos source, the bench and the embedder. [`README.md`](README.md) holds the design and the history.

**Ships as of 26.822.1**, as `apple-index`. It answers the one thing the tools
above cannot: **searching when you do not know which app holds the answer.**
🛑 Only the PyTorch-free half ships; `make test` still runs nothing here.

```
apple-index search "the greenhouse budget"     # one query across every source
```

It builds one SQLite index over mail, messages, notes, calendar, contacts,
reminders, visited places, **the Photos library** and any folder you point it
at (an Obsidian vault is understood natively, and Word, PowerPoint and PDF are
read as well as markdown),
and searches it with FTS5 plus an `e5-small-v2` embedding. A query takes 70 to
300 ms against 239,000 chunks. Full detail in
[`lab/README.md`](README.md); the model comparison is in
[`lab/MODELS.md`](MODELS.md) and the per-source change signals in
[`lab/INCREMENTAL.md`](INCREMENTAL.md).

**`apple-index files` names the folders the `files` source reads**, and it is
the only source that has to be configured — every other one reads a store at a
known path.

```
apple-index files                        # what is configured
apple-index files add ~/notes            # and --name, --exclude a,b
apple-index files remove ~/notes
apple-index files --json                 # what the app's window reads
```

The AppleTools window edits the same list, in the `files` row of its Sources
panel. 🛑 **Adding a folder does not index it and removing one does not unindex
it** — `ingest` only ever adds, so a removed folder's records survive until
`apple-index ingest --source files --full`. 🛑 **`files.json` lives in
`~/Library/Application Support/apple-tools`**, not beside the index: it followed
`dirname(DEFAULT_DB)` until 26.827.0, which is inside the encrypted vault
whenever the app has it mounted, so a folder added from the app disappeared with
the volume and `apple-index forget` destroyed the configuration with the index.

**It reads `.md`, `.markdown`, `.txt`, `.docx`, `.pptx` and `.pdf`.** `kind`
names the format — `note` for markdown in a vault, `file` for text outside one,
and `pdf`/`docx`/`pptx` for the rest. ⚠️ **`search` has no `--kind` flag**; the
value is in `--json`, so filter with `jq`. On this machine the new formats add
5.07M characters to 9.42M of markdown.

- **Word and PowerPoint cost nothing.** A `.docx` is a zip of XML, so `zipfile`
  and `ElementTree` read it in process: 55 of 55 files, 0 failures, 0.19s.
- 🛑 **PDF NEEDS A BINARY, `lab/vec/…/doctext`, and every other route was
  measured and rejected.** `textutil` does not read PDF. `/usr/bin/python3` is
  **3.9.6** with no `Quartz`, and **MarkItDown needs 3.10**, so it cannot run
  in the ingest process at all — shipping it would mean a 318 MB venv in the
  formula and the app bundle. 🛑 **`mdimport -t -d3` IS PDFKit**: `mdimport -e`
  names its importer `com.apple.PDFKit.PDFImporter`, and its output is
  byte-identical at three times the cost. ⚠️ **A missing `doctext` is a warning,
  not a failure** — every other format still indexes, and the count of skipped
  PDFs is named on stderr.
- 🛑 **THE SIZE CAP COUNTS EXTRACTED TEXT, NOT FILE BYTES.** A PDF's bytes are
  mostly pictures: 30 of the 159 PDFs here and 7 of the 61 Office files exceed
  2 MB on disk while holding ordinary amounts of text.
- 🛑 **A SCAN CANNOT BE INDEXED.** 20 of the 159 PDFs here have no text layer
  and nothing on this Mac does OCR. They are reported on stderr rather than
  indexed as empty records that look indexed and can never match.
- 🛑 **`.xlsx` is deliberately absent.** Its shared-string table is labels and
  codes rather than prose, and 6 files here would add 1.22M characters of it.
- ⚠️ **An Obsidian deep link drops the extension ONLY for a note.** Obsidian
  addresses markdown without it and everything else with it, so stripping
  `.pdf` yields a link that silently resolves to nothing.

🛑 **`doctext` REPORTS BROKEN-LOOKING TEXT AND NEVER DROPS IT, and that
restraint is the finding.** Every PDF extractor fails on a broken ToUnicode
map. One page of a real budget letter reading "To the Joint Budget Committee
and the General Assembly:" comes back as `To e o Be ommee e Geer emb` from
PDFKit, `To WKe -oLQW BXGJeW &ommLWWee…` from pypdf, and `(cid:42)(cid:50)…`
from MarkItDown. A detector was built for it and the measurement killed it:
the signal is the rate of English function words, and **a list scores zero
just as wreckage does**. Of 71 pages flagged across 159 real PDFs, the ones
read by hand were a plant list and a page headed CONTACT LIST holding the
HOA's insurer, animal control and the police. ⚠️ **Read `low_prose_pages` as
"a list, a table or another language"** far more often than as "broken". It is
a hint in the JSON, never a filter. `lab/test-doctext.py` pins the refusal.

🛑 **`stats` NESTS this source, alone among the sources.** It is the only one
with two levels: the folders the user configured and the folders inside them.
`stats` carries a `roots` array beside the flat `containers` one — per
configured folder, its records, chunks, a `kinds` count per format, and its own
top-level folders. The app's window draws `roots`.

- 🛑 **THE ROOT COMES OUT OF THE `uid`, NOT THE CONTAINER.** A container is a
  path relative to whichever root holds it, so two roots that each hold a
  `Reading` folder are one row and nothing says which is which. The uid is
  `files:<name>:<relative>` and carries both halves.
- 🛑 **That also settles what the container cannot.** A file directly in root
  `work` and a file in a SUBFOLDER named `work` inside it share the container
  `work`. In the uid they differ by one slash, so loose files get their own
  row, named `""`, shown as "files at the top level".
- ⚠️ **A root name with a colon would break the split**, so `files add` refuses
  one. Anything unparseable lands under `(unknown)`.
- ⚠️ **The two views disagree by design.** `containers` merges roots; `roots`
  keeps them apart. Read one or the other, never both.
- 🛑 **A folder removed from the config keeps its records**, so the window
  lists them under "Still in the index, no longer indexed" rather than letting
  them disappear while still costing index space.

⚠️ **`.pages`, `.numbers`, `.key`, `.doc`, `.rtf` and `.odt` are not read yet.**
`mdimport -t -d3` is the only route and it works — it read a `.numbers` file
here that nothing else can — but its `-o` output is an old-style ASCII dump
containing `{length = 0, bytes = 0x}`, which both `plutil` and `plistlib`
reject, so it costs a hand-written parser. 27 such files sit on this machine.

**`apple-index people` is the one command that is not a search.** It reports who
the user talks to, who turns up alongside whom, and which emoji they themselves
type — the data behind the app window's relationships and emoji panes.

```
apple-index people --top 80 | jq '.people[0]'      # always JSON, like `stats`
apple-index people --refresh                       # recompute rather than read
```

🛑 **It is computed once a day and stored** in the index (80 ms to read against
3.6 s to compute), so a stored answer may be up to a day old — every reading
carries `cached` and `computed`. A `--me` / `--not-a-person` ruling forces the
recompute it implies rather than waiting for the clock.

- 🛑 **Deciding which handles are the USER is the hard part**, and it takes six
  rules: the accounts Mail knows, one inferred address, every handle on the card
  claiming one of those, every address signing itself with a name the card
  answers to (🛑 by **stem** — the card says "Dan" and old addresses say
  "Daniel"), the user's own local part at another service, and anything they
  declare with `people --me <handle>`. 49 handles here. Everything inferred is
  reported in `me.detected`, `me.by_name`, `me.by_address` and `me.declared` —
  read it before trusting a ranking.
- ⚠️ **A bounce path carries the user's own address** (`bounces+…-me=gmail.com@…`)
  and reads as a person with their name. Excluded with reason `bounce`.
- 🛑 **THE UNIT IS A DAY, and that is not decoration.** An earlier version
  summed indexed records and called it "encounters", which reported a spouse of
  twenty years at 9,059 of nothing in particular. A record is a different size
  in every source — one email, a block of TEN texts, one event — so the sum
  means nothing. Read `days`; `channels` carries the item counts, each in its
  own unit, and **must never be added together**.
- 🛑 **`last` IS THE MAXIMUM ACROSS EVERY CHANNEL, so it answers a question
  nobody asked.** "When did I last talk to my mother" returned the day she sent
  a text. Read **`channel_last`** for a channel's own most recent item, and
  **`channel_spoke_last`** for the last time it actually connected. Three
  readings of one question, all different: last contact 2026-08-25, last call
  of any kind 2026-08-17, **last call she picked up 2026-08-13**.
- 🛑 **A MISSED CALL IS NOT TALKING**, and it is not a rounding error: **183 of
  372 calls here never connected — 49%**, and 7 of the 11 with one person.
  `days` still counts them, deliberately — somebody reaching for you is
  contact — and **`channel_spoke_days`** is the narrower answer beside it, the
  way `alone` sits beside `channels`. ⚠️ An aggregate `spoke_days` is nearly
  useless (1,476 against 1,479): mail and messages exist because something was
  sent, so they are always "spoke" and they drown the one channel where it
  varies.
- 🛑 **PHONE HAS NO FIRST DATE, and never will.** `CallHistory.storedata` is a
  relay mirror of the iPhone — 372 calls over 141 days here — so the oldest
  call visible is the edge of the mirror, not when two people first spoke.
  Measured: 11 of 137 phone first-dates sat within a fortnight of that edge, a
  spouse of twenty years landed exactly ON it, and **109 people have no other
  channel at all**. Worse, it degrades silently as the window slides. So
  `WINDOWED_CHANNELS` omits it: **absent beats confidently wrong**. ⚠️ Phone is
  the only one — mail reaches 2004 here, photos 2004, messages 2017, calendar
  2016. Fixing this properly needs
  [`docs/todo-call-archive.md`](../docs/todo-call-archive.md).
- 🛑 **Being on the same list is not talking.** 53% of the emails naming that
  spouse were written by a third party to both of them, and a third of the
  total are `Cc`. Those are counted in `same_list`, never in `days`. A mail to
  more than 12 people is a list even when the user sent it.
- **`alone` is the number that answers "surely not"** — the items with nobody
  else on them, per channel. Three true answers to three different questions:
  5,927 messages carry her address, 2,625 are one of them writing to the
  other, 1,336 are just the two of them. Checked against the raw `.emlx`
  headers, not the index; every line agrees within 1%.
- ⚠️ **Emoji are only what the user SENT.** Counting the whole store measures
  what other people type at them, and the two answers look alike.
- **`emoji.rarest` is the least-used emoji of each year**, beside
  `emoji.by_year`'s most-used one. ⚠️ It is always something really sent, once —
  an emoji never sent belongs to no year at all. 🛑 **Ties break on the emoji
  itself**, because most years have dozens used exactly once and `min` over a
  dict alone picked a different one on every run.
- **`emoji.adoption` says how long the user takes to pick up a new emoji.**
  Measured here: **median 3.6 years, 11 of the 168 released since 2020 used.**
  🛑 **BOTH DATES COME FROM unicode.org AND NEITHER IS TYPED IN** — the release
  date is the `# Date:` header on that Emoji version's own data file, fetched by
  `lab/emoji-versions`; the first-use date is the earliest record in the index
  in which the user typed it.
  - ⚠️ **A vendor ships the glyph later than Unicode publishes it**, and nothing
    here knows when this keyboard got it. So a lag is an **upper bound**.
  - 🛑 **A negative lag is reported, never clamped.** It means a record is dated
    before the emoji existed, which is a wrong date — clamping to zero hides the
    only sign of it. Counted as `early`, and left out of the median. Zero here.
  - ⚠️ **A missing `emoji-versions.txt` degrades quietly by design** — no
    adoption block, everything else unaffected — which is exactly why
    `apple-index selfcheck` refuses a payload without it. An install short of it
    would otherwise look like a user who has never sent a new emoji.
- 🛑 **A DAY THAT HAS NOT HAPPENED IS NOT CONTACT.** The calendar adapter
  fetches a year ahead, so 1,008 events here are in the future. They are
  counted in `upcoming`, never in `days`.
- **`directory` is everyone** (4,725 here), for looking one person up and for
  filtering the timeline. Month series are positions into one shared
  `months_axis`, so everybody can have one.
- 🛑 **A BUSINESS IS NOT SOMEBODY YOU TALK TO**, and five rules keep them out.
  Every exclusion is reported in `excluded` with its reason, never dropped
  silently: `company` (the card is marked as a business, or names one and no
  person), `never-answered` (🛑 **40 emails and not one reply** — the only rule that
  reads the relationship rather than the address, so it catches a sender whose
  name and address look like a person's; one reply spares them, and it never
  judges anyone who also texts or calls), `bulk-mail` (12+, never answered, a
  newsletter footer on half of them, and the address does not carry their own
  name), `short-code` (an SMS short code — a five-digit number cannot be a
  person), `no-reply` (an address a machine writes from), `calendar-feed` (a
  Google Calendar system address), `list` (many display names, none dominant).
- **Two escape hatches, and which one depends on whether a card exists.**
  With a card: `apple contacts edit <id> --company-card`, or the "Company" tick
  box. Without one — Mint ranked 17th here and has no card —
  `apple-index people --not-a-person team@mint.com`. 🛑 **`--is-a-person`
  rescues somebody the rules excluded wrongly, and it beats every rule.** That
  direction matters more: a business left in is visible, a person taken out is
  not. Rulings live in `~/Library/Application Support/apple-tools/people.json`.
- ⚠️ **`office@`, `info@` and `contact@` are deliberately NOT excluded.** A
  small charity's office address really is answered by one person, and two on
  this store are.
- 🛑 **The same person is written three ways, and three rules fold them**:
  words sorted, so "Leopold, Robin" meets "Robin Leopold" (208 pairs here);
  namesakes with no card folded together, two words minimum (154 groups, 265
  rows); and the name change below.
- 🛑 **A NAME CHANGE IS TWO PEOPLE unless the card records the old name.** Fill
  in `--previous-family-name` and the two rows become one. Measured: one card
  and one dead address held 8,491 and 568 encounters, meeting exactly where the
  other began.

**`apple-index whereabouts` is where the user WAS, day by day, from every
source that knows.** The question `search` cannot answer: "where did I go
this week" retrieves by words, and a visit record has none for "this week",
so `search --since` returned **0 hits** on a real index. This is a listing
over a window, not a search.

```
apple-index whereabouts --since 7                 # this week
apple-index whereabouts --from 2026-05-20 --to 2026-05-31 --json
```

🛑 **FOUR SOURCES, AND NONE OF THEM IS THE ANSWER.** `maps` is an arrival
Apple's detector was sure of; `dawarich` a stay a phone guessed, with a start
and an end; `photos` a camera on a day; `calendar` a PLAN. Each misses most
days. Agreement is the signal, and **agreement is counted in sources, never
in records** — three dawarich stays are one source three times. Every place
carries `claim`: `corroborated` (two sources), `single`, `planned` (calendar
alone — never a presence), `reported` (somebody else's camera alone).

- 🛑 **A photo from a shared camera is evidence THEY were there.** On the
  first real run a relative's photo in Rochester put the user 2,336 km from
  a Disneyland trip on the day they flew home. `ingest_photos` now writes
  `from a shared camera` into the body of a day whose every photo came from
  the iCloud Shared Library, so the flag survives without a tagged face;
  `whereabouts` reads it and such a day places nobody.
- **Home is the largest place in `merged_places`**, or `--home lat,lon`. A
  day is `away` when everything placing the user is over `--away-km` (50)
  from home; `unknown` when nothing places them; `home` otherwise.
- **A trip is a run of away days, and a day nothing places does not end
  it.** `days` is the span, `days_placed` how many any source saw. The
  centre is the place most distinct days put the user, then the one more
  sources agree on, then the farthest — so an airport passed through twice
  never names a trip.
- ⚠️ **The same event arrives once per calendar it is on.** Drawn once.
- **`belief` is a 0–1 score per place per day, and every weight behind it is
  printed.** It is a noisy-OR, `1 − Π(1 − w)`, over one weight per source:
  maps 0.85; the user's own camera 0.80, or 0.95 with the user IN the
  picture (their handles come from the stored `people` report); somebody
  else's camera 0.15; a calendar pin 0.20, or 0.45 when GPS puts the user
  there within 3 h; a dawarich stay up to 0.70 scaled by the server's own
  confidence and the stay's length (5 min at 42 ≈ 0.09, 6 h at 62 ≈ 0.43);
  a workout with a GPS route from the `health` plugin 0.90; plus 0.30 when
  two presence sources fall within 3 h of each other. 🛑
  **THE WEIGHTS ARE ASSUMPTIONS.** No source is ground truth, so what was
  measured is how often each is *confirmed* by another (maps by dawarich
  35%, dawarich by maps 28%, an own-camera day by dawarich 48%, a shared
  day by any GPS 11–14%, a calendar pin by maps 15%), which is agreement,
  not accuracy. Several stays at one place on one day are ONE source at its
  best; they never sum. Read `weights`, and repeat them when you report a
  belief. `claim` stays beside it and is the count of sources.
- ⚠️ **A dawarich stay's confidence rides in the record body**
  (`confidence 62`), written by the plugin from 26.914.2. Until the app
  ships that plugin, its refresh writes the old body and a manual ingest
  from the checkout writes the new one, and the two rewrite 6,000 records
  at each other every five minutes. Do not ingest dawarich by hand until the
  installed app carries the same plugin.
- Measured on six months here: 7 trips, from a one-day New York flight to
  five days at Disneyland with all three GPS-and-camera sources agreeing.
  `lab/test-whereabouts.py` pins every rule above.

**`apple-index places` is the map behind the app window's places pane** — everywhere
the user has been, from the two sources that know.

```
apple-index places --limit 20      # always JSON
```

🛑 **TWO SOURCES, TWO UNITS, NEVER ADDED.** `maps` records a genuine
**arrival**, with a start time, out of Maps' Visited Places. `photos` records
that a camera was somewhere on some **day**. 98 of the 1,487 places here have
both, and adding them makes a number with no unit — the same mistake `people`
made once by adding emails to texts. Each row carries `visits` and
`photo_days` side by side, named after what they count.

- ⚠️ **Neither is "everywhere you have been."** Maps holds 450 arrivals;
  Photos holds 27,603 located pictures across 21 years. Photos reaches much
  further back and misses everywhere no picture was taken. Say which one an
  answer came from.
- 🛑 **A merged row keeps the name of the source that actually knows the
  place.** Preferring the Maps name renamed this user's **home** — 1,647 photo
  days, the largest place in the library — after a charity's office 180 m away
  with two recorded visits.
- ⚠️ **`container` means something different in each adapter.** `maps` puts the
  place category there and `photos` puts a country; reading it as a country
  for both listed "Dining" and "Transportation" as countries, 65 of them where
  the honest answer is 8.
- 🛑 **A photo place carries city, COUNTY and state, because the metro name
  lives in the county.** Three photo days in Irving, The Colony and
  Grapevine said "Dallas" nowhere until `Dallas County` was kept from
  Apple's placemark (`_subAdministrativeArea`); only Irving is in it — The
  Colony is Denton County and DFW is Tarrant — and nothing here invents a
  "Dallas–Fort Worth" the placemark does not carry.
- 🛑 **`photo_days` is the user's OWN camera; `photo_days_shared` is
  somebody else's.** A day whose every photo came from the iCloud Shared
  Library is evidence that they were there. Six such photos in London,
  Ontario, drew this user a dot for a trip a relative took. **The app does
  not draw a place only such days know at all** — the legend says how many
  it left off — and those days size and anchor nothing. The CLI report
  still carries them, so the data is not lost, only kept off the map.
- ⚠️ **A photo's coordinate is where the CAMERA was, and a camera can be at
  35,000 feet.** Three Live Photos from a JFK→AMS window seat are tagged
  over Aroostook County, Maine, between one over Long Island and the next
  in Amsterdam. The dot is true and it is not a place the user went. The
  order of the photos on the day is what says so; nothing here infers it.
- **`<tool>_workouts` is a FIFTH unit** (health): workouts whose route
  started within 250 m of the place. Counted after the merge and by
  distance, not by grid cell — a ride's first GPS fix is in the driveway,
  one cell over from the house, and a cell-keyed count put 0 rides at a
  home 1,156 start from. The app shows it as `w`.
- 🛑 **The app's map draws the top 400 places by weight AND one dot per
  region.** The top 400 are almost all within an hour of home, so those
  same three Dallas days — weight 1, rank ~1,200 — drew nothing and the map
  said the user had never been to Texas. A place past the cap is drawn when
  no drawn place lies within 25 km of it. The pane also has a filter over
  name and address, and shows a plugin's stays in green beside `d` and `v`.

**The `photos` source is what put children in the people report.** Every other
channel needs an address or a number, so it can only see somebody who sends
things.

- 🛑 **A tagged face joins to Contacts BY ID.** `ZPERSON.ZPERSONURI` holds
  `UUID:ABPerson`, the exact identifier `apple contacts get` takes; 47 of the
  63 named people here carry one. ⚠️ **It survives a name change**, which
  nothing else here does: the library says "Keith Hopkins", the index says
  "Keith Van Norstrand", and the same id merges them with no
  `--previous-family-name` needed.
- 🛑 **Emma is a dog.** `ZDETECTEDFACE.ZDETECTIONTYPE` is 1 for a human face,
  3 for a dog and 4 for a cat. Seven pets are named here, and without the
  filter Emma ranks fourth by tagged days. **`osxphotos` does not expose this
  field**, which is one of three reasons it is not used.
- 🛑 **A FACE TAG IS APPLE'S GUESS, NOT GROUND TRUTH.** The clearest evidence
  is a photograph of somebody taken before they were born: one child here was
  born 2019-07-07 and carried 13 tagged photos from 2012 to 2017, one dated the
  exact day *another* child in the library was born. Apple's matcher confuses
  babies with babies. Measured across everyone with a full birthday on their
  card: **13 of 15,260 tags, 0.09%**, one person. A photo day dated before the
  person's birthday no longer counts them, and every dropped tag is **named on
  stderr**. ⚠️ Only a FULL birthday counts — a `--MM-DD` card cannot date
  anything, and this must never quietly delete real days.
- ⚠️ **It measures who was PHOTOGRAPHED, not who was there**, and the
  difference falls on whoever holds the camera. This user appears on 661 days
  and was present for all 1,378 of his daughter's. That costs nothing in the
  report, because the user is excluded from their own graph — but never read a
  photo day count as "days together" without saying whose camera it was.
- 🛑 **A photo from somebody else's camera is not proof you were there.** 7,460
  assets belong to the iCloud Shared Library. A day whose *every* photo came
  from a shared camera is marked `alongside` and counted like a mailing list:
  an edge in the web, never a day of contact.
- 🛑 **PHOTOS ONLY CARRIES A CONTACTS ID WHEN THE USER CONFIRMED ONE IN
  PHOTOS.APP.** 16 of the 63 named faces here have none, so they arrive as
  `photos:<name>` and read as strangers — even with a card sitting in Contacts.
  Measured: three of them had cards, one since 2017 with a birthday on it. A
  face whose ONLY channel is photos now adopts the card that shares its name,
  when exactly one card claims it and that card is not a business. ⚠️ **The
  name must agree in FULL.** A card named "Ryan Montgomery" does not link a
  face Photos spells "Ryan Mcgomery", and it should not. Fix the name in
  Photos.app.
- 🛑 **`merge_by_name` CANNOT DO THIS**, and the reason is not obvious: it
  builds its table of claimable names from people already in the report, so a
  card is only claimable once some mail or event already named that person. A
  child who has never sent anything has a card and no records.
- 🛑 **The user's own face lands on a card with nothing to match on** — the
  right name, no email, no phone — so no handle rule could claim it and the
  user was drawn **sixth** in his own list. Photos cannot settle it either:
  `ZISMECONFIDENCE` is empty on every row. The card is claimed by the same
  stem rule addresses use, only when it carries no handle of its own, and is
  reported in `me.by_card`.
- 🛑 **The pictures, the OCR and Apple's scene labels are deliberately NOT
  indexed.** 36,341 photos carry 5,349 characters of title and description
  between them. The OCR covers 5.9% and the store keeps it as a bag of
  lowercased words with the order destroyed. The scene labels are
  synonym-inflated to meaninglessness. Measured: `eval.py` scores **MRR 0.538
  with photos in the index and 0.538 with every photo record deleted.** Full
  record in [`docs/apple-photos-store.md`](../docs/apple-photos-store.md).

⚠️ **OPEN QUESTION, not settled.** `days` is the unit for every channel, so
somebody you email daily outranks somebody you are physically with. Photos put
15 people into the directory who appear in no other source — all children and
family — and they sit below the top forty for that reason. Whether "who you
talk to" and "who you are with" are one ranking or two has not been decided.

Four rules at the call site:

1. 🛑 **The index stores ids. Read the record back through the `apple` tool.**
   A hit gives `tool` and a native `id`; the indexed copy can lag and its
   snippets are truncated. `apple-index search … --json` then
   `apple notes export <id>`.
2. ⚠️ **A launchd agent cannot refresh the index; the APP can.** An agent has
   **no Full Disk Access**, measured twice — the Swift daemon's own probe
   reports `full_disk_access: false` under launchd — so it serves searches and
   cannot ingest. `apple-index refresh` from a terminal still works and costs
   ~8s. **`app/AppleTools.app` refreshes on its own**, every 5 minutes and on
   wake, because a child of the app inherits the app's Full Disk Access.
   Measured 2026-08-23; see [`app/README.md`](../app/README.md). The app also owns
   the search socket and unloads the agent when it starts, so **the two never
   both serve**.
3. 🛑 **The index holds the plaintext of every email** — ~105 MB of decoded
   bodies in one unencrypted file, protected by neither Full Disk Access nor
   the 0700 directories its sources sit behind. Never copy results anywhere
   that leaves the machine. The first ingest asks for consent; `apple-index
   forget` deletes the index, the logs and that consent. **Not encrypting it is
   a recorded decision**, not an oversight — see
   [`lab/SECURITY.md`](SECURITY.md).
4. **It is read-only.** It never writes to Notes, Mail, Calendar or Contacts.

Install with `brew install apple-tools`, or from a checkout with
`cd lab && make install install-agent install-skill`.

**Retrieval quality is measured against a PUBLIC corpus**, not only against this
machine's data. `lab/bench/` builds an index from **EnronQA** — 1,257 real Enron
emails and 1,254 question/answer pairs — in its own database, and scores it with
the same `eval.py`. Baseline for `e5-small-coreml`: **MRR 0.780**, two minutes.

```
cd lab && make bench            # fetch, build and score
```

- 🛑 **The 29 hand-written cases in `eval.py` cannot decide a model swap.** They
  separated e5-small from e5-base by 0.012 MRR, which is under one case in
  fourteen. Anything claiming a two-point gain needs the bigger set.
- ⚠️ **The bench does not replace them.** Every EnronQA case is a long
  `descriptive` question written by an LLM from the answer. No short keyword
  lookups, no calendar, no places, no cross-source fusion.
- 🛑 **It never touches the real index.** `APPLE_INDEX_DB` moves the database
  *and* `files.json`, and the builder refuses to run under the real index's
  directory.

**The embedder is Core ML, in Swift, with no PyTorch.** `e5-small-v2` converted
to three fixed shapes; 663 chunks/sec on this corpus, byte-identical vectors to
the PyTorch path on 19,999 of 20,000 chunks. The warm daemon is `vec daemon`:
110 MB idle against 661 MB, and 15 ms per search. Every measurement, and the
three tokenizer bugs the parity gate caught, are in
[`lab/coreml/BAKEOFF.md`](coreml/BAKEOFF.md).
