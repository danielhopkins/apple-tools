# lab/ — a semantic index over the apple-tools readers

**Experimental, and as of 26.822.1 it SHIPS.** `make dist` builds `vec`
universal and packages it as `index/` alongside `index.py`, the Core ML weights
and this document. `make test` still does not run anything here.

🛑 **Only the parts that need no PyTorch ship.** `daemon.py`, `embed_oss.py` and
`coreml/coreml_embed.py` stay in the repo as the reference the Swift port is
measured against, and are deliberately left out of the tarball. A shipped
install has no `uv` dependency and nothing to download.

🛑 **Installing builds no index and reads nothing.** The first `apple-index
refresh` asks for consent and records it, and `apple-index forget` deletes
everything. Read [SECURITY.md](SECURITY.md) before running it on real data:
the index is not encrypted, and that is a recorded decision rather than an
oversight.

## Why it exists

Today an agent answering "find that thing about the budget" runs six commands
and merges the output by hand. The user does not know which app holds the
answer, so every source gets queried. This is an experiment in replacing that
fan-out with one query.

## What it borrows from Apple, and what it cannot

Apple's semantic index is not readable from here. `util/check-spotlight`
measures that: the CoreSpotlight index is per app bundle, a CLI has no bundle,
and both query APIs return **0 items and no error**.

The *design* is readable. macOS 27 ships
`_CoreSpotlight_FoundationModels.framework`, and its `.swiftinterface` spells
out Apple's search tool in public types. Five ideas came from there:

1. **One flat record for every app.** `CSSearchableItem` plus an attribute set.
   Here that is the `record` table.
2. **Content domains map app fields onto shared roles.** Apple's
   `Communications` domain has `authors`, `recipients`, `sent`, `received`,
   `topic`; its `Calendar` domain has `organizer`, `attendees`, `location`,
   `date`. Here every adapter emits the same `people[]` with a `role`.
3. **Matching is hybrid, and each half is a switch.** Apple's `GuidanceProfile`
   carries `textMatch`, `similarityMatch`, `numericMatch`, `dates`, `people`,
   `contentType`, and `CSUserQuery.disableSemanticSearch` has existed since
   macOS 15. Here FTS5 and the vector scan run separately and fuse.
4. **Results carry a score.** Apple's `ScoredSearchableItem`.
5. **Resolving "me" is an injected dependency.** Apple's `ContactResolver`.
   Not built yet. See "Not done".

Apple's embedding model, its ranker and Private Cloud Compute stay out of
reach.

## Layout

```
index.py          the driver: ingest, chunk, FTS5, fusion, output. Stdlib only.
photos.py         the Photos reader: tagged faces with their Contacts id,
                  coordinates, and Apple's stored reverse geocode. Stdlib only.
emoji-versions    fetches unicode.org's own data files and writes the table
                  below. 🛑 GENERATED, never hand-written. `--check` says stale.
emoji-versions.txt which emoji arrived in which Emoji version, and the date
                  that version was published. 1,906 emoji, 16 versions.
vec/              Swift: the embedding model and the dot products.
Makefile          build, demo, clean
index.db          created by `./index.py init`. Not committed.
```

**The two halves split on one line.** `vec` owns the `vector` table and nothing
else. Python owns the rest of the schema. They meet only through `chunk.cid`.

`vec` exists because the system `python3` has no numpy, so scoring 290k vectors
in Python would be far too slow. It uses Accelerate.

## The boundary with apple-tools

`index.py` calls the installed `apple` CLI as a subprocess and reads `--json`.
It shares no code with `swift/` or `notes/`. Three consequences:

1. The main tool needs no change.
2. The readers stay the single source of truth.
3. **The index stores ids. It never replaces the reader.** A hit gives you a
   `uid` and a `native_id`; read the record back with `apple <tool> export`.
   A stale body in the index must never become the answer.

## Running it

```
make build                                  # build vec
./index.py init
./index.py ingest --source notes --limit 40
./index.py embed
./index.py search "where can I take the kids to play outside"
```

`make demo` runs exactly that.

Sources: `notes`, `mail`, `messages`, `calendar`, `contacts`, `maps`,
`photos`, `reminders`, `files`. Pass several with `--source notes,calendar`.
🛑 `SOURCES` in `index.py` is the one list; this line is a copy and a review
caught it already stale.

### `files` — the one source whose contents are a decision

Every other source reads a store at a known path. This one reads whatever
folders you name, so it is the only one that has to be configured.

```
apple-index files                        # what is configured
apple-index files add ~/notes            # and --name, --exclude a,b
apple-index files remove ~/notes
apple-index files --json                 # what the app's window reads
```

The AppleTools window edits the same list, in the `files` row of the Sources
panel.

- 🛑 **ROOTS ARE CONFIGURED, NEVER GUESSED.** A guessed path that happens to
  exist on one machine is how a tool ends up indexing somebody's Downloads.
- **An Obsidian vault is recognised**, and `.obsidian` is skipped along with
  `.git`, `node_modules`, `__pycache__` and any `Attachments` folder. On this
  vault those hold 959 MB of binaries next to 5.6 MB of text.
- Extensions read: `.md`, `.markdown`, `.txt`. A file over 2 MB is skipped, so
  one runaway export cannot become 40% of the index.
- 🛑 **ADDING A FOLDER DOES NOT INDEX IT, AND REMOVING ONE DOES NOT UNINDEX IT.**
  `ingest` only ever adds, so the records from a removed folder survive until
  `apple-index ingest --source files --full`.
- 🛑 **`stats` reports this source by TOP-LEVEL FOLDER, alone among the
  sources.** Its `container` is a whole relative path rather than a flat name,
  so the raw listing was 49 rows here, most of them a subfolder of another row,
  ordered by size — an answer to "which folder is biggest", which is nobody's
  question. `top_level_containers` folds them; 49 became 12. ⚠️ **The cut
  applies after the fold**, so the SQL `LIMIT` is dropped for this source:
  folding a truncated list reports a folder short by whatever fell past the cut,
  and a wrong number is worse than a missing row.
- 🛑 **`files.json` lives in `~/Library/Application Support/apple-tools`, not
  beside the index.** It followed `dirname(DEFAULT_DB)` until 26.827.0, which is
  inside the encrypted vault whenever the app has it mounted — so a folder added
  from the app disappeared with the volume and `apple-index forget` destroyed
  the configuration with the index. A copy still at the old path is moved on
  sight. ⚠️ An explicit `APPLE_INDEX_DB` still wins, because `lab/bench` relies
  on that to keep its own configuration away from the real one.

## Who you talk to

`people` answers three questions the search side cannot: who is in this data,
who is in it together, and when was each of them around. It is what the app's
window draws as a web, an emoji list and a timeline.

```
apple-index people --top 80 | jq '.people[0]'
```

It reads every indexed record with a person on it — mail, messages and
calendar — and adds two things the index does not hold: `apple contacts list`,
to turn a handle into a name, and `apple phone recents`, because call history
is not an indexed source. About 3.6 seconds on a 239k-chunk index.

🛑 **IT IS COMPUTED ONCE A DAY AND STORED**, in a `people_cache` table beside
the index. Reading the stored copy is **80 ms against 3.6 s**, so opening the
window costs nothing.

```
apple-index people                  # the stored report
apple-index people --refresh        # recompute now
apple-index people --ensure         # refresh it if it is a day old; print one line
apple-index people --max-age -1     # accept a stored report of any age
```

- **The daily policy lives here, not in the app.** The app runs
  `people --ensure` at the end of every indexing cycle, which costs 80 ms when
  the stored report is fresh. ⚠️ A second copy of "daily" in Swift is how two
  schedules drift.
- 🛑 **A ruling does not wait for the clock.** `--me`, `--not-a-person` and
  `--is-a-person` each force the recompute they imply. Marking Mint and seeing
  nothing change for a day is indistinguishable from the flag not working.
- **Every reading says `cached` and `computed`**, and the window prints the
  age. ⚠️ A reader that cannot tell a stored answer from a fresh one cannot
  tell a stale one either.
- 🛑 **It travels with the index and dies with it.** Rebuilding throws it away,
  which is right: it is an answer about the index, not a setting the user
  typed. Their rulings live outside it, in `people.json`, for the opposite
  reason.

🛑 **Deciding which handles are the USER is the whole problem**, and getting it
wrong deletes a real person from their own graph or puts the user in it.
**49 handles here**, from six rules, each one added because the one before it
was not enough:

1. **The accounts Mail knows.** Certain, and incomplete. Three.
2. **One inferred address**: the top recipient no account claims, and only when
   it is on 30% of mail *and* three times the runner-up. Here that is 54.2%
   against 10.3%. ⚠️ A plain threshold does not work — a spouse is on 24.0% of
   calendar events and a colleague on 23.0%.
3. **Every handle on the card that claims one of those.** A card holds the
   addresses Mail has forgotten.
4. **Every address signing itself with a name the card answers to.** 🛑 THE
   FORMAL NAME IS NOT ON THE CARD: it reads "Dan Hopkins", and old addresses
   sign themselves "Daniel Hopkins". So the family name must match exactly and
   the given name must be a **stem** of the card's, or the card's of it, at
   three characters or more. 21 here — former employers, a university, a
   machine hostname, two dead photo services. ⚠️ A relative with the same name
   would be taken too, which is why every one is reported.
5. **The user's own local part at somebody else's service.** 15 here: two
   Send-to-Kindle endpoints, a plus-address at a former employer, Google Wave.
   ⚠️ Six characters at least, and the next character must be a separator —
   without the length guard the local part `dan` claims `dan@` everywhere.
6. **Anything the user declares**: `apple-index people --me <handle>`. For an
   alias on their own domain, which no rule can safely infer — a domain rule
   was measured and rejected here, because it took three real colleagues at
   `copta.org` and `theinevitable.co` along with the two aliases it wanted.

Everything inferred is reported — `me.detected`, `me.by_name`, `me.by_address`,
`me.declared` — and the window prints it, because a wrong guess is otherwise
invisible.

⚠️ **A bounce path is not a person either.** VERP encodes the recipient in the
sender, so a newsletter bounce arrives from
`bounces+3371362-2618-danielhopkins=gmail.com@mailer.example`. 18 here, one day
each, all of them appearing in a search for the user's own family name. They are
excluded with reason `bounce`, and it cannot be a false positive: the address
literally contains the user's, with `@` written as `=`.

🛑 **THE SAME PERSON, WRITTEN THREE WAYS.** Three separate rules fold them:

1. **A directory writes the name backwards.** "Leopold, Robin" and "Robin
   Leopold" are one person; so are "Lee, Ming-Ming" and "Ming-Ming Lee". 208
   such pairs here. The fix is to **sort the words** before comparing, which is
   safe only because a **card must claim the name** — seven companies here sign
   themselves "Support", sorting makes all seven agree, and not one has a card.
2. **Several addresses, no card at all.** Work, personal, a role address at the
   same charity, the one at the employer they left. `John Giffin` appeared five
   times, `Xin Zheng` three, `Staci Ruddy` three. 154 groups covering 379 rows,
   and every one of the fourteen largest is plainly one person. ⚠️ **Two words
   at least** — a single word is not a name. ⚠️ **It can be wrong**: two
   strangers sharing a full name with no cards are folded. Nothing here does,
   and the alternative is paid on every screen. A contact card beats it.
3. **A name change**, below.

⚠️ **A merge chain has to resolve.** b folds into a, then a into c, and an edge
pointing at b must end up at c or it points at nobody.

🛑 **A NAME CHANGE IS TWO PEOPLE, and no address matching finds them.**
Measured here: one card reads "Stephanie Hopkins" and holds six handles, and an
old address signing itself "Steph Anderson" carried 568 more encounters from
2006 to 2012 — ending in the month the other row begins.

The fix is on the card, not in the code: `apple contacts edit <id>
--previous-family-name Anderson`. A card then claims four names, and any of
them can pull an un-carded address in:

    given + family        Stephanie Hopkins
    given + previous      Stephanie Anderson
    nickname + family     Steph Hopkins
    nickname + previous   Steph Anderson    ← the one that matched

⚠️ **The previous family name alone is not the name that arrives.** Mail signed
itself with the nickname, so both halves have to be crossed. ⚠️ A name that two
cards answer to still merges nothing.

Three more rules worth knowing at the call site:

- 🛑 **A BUSINESS IS NOT SOMEBODY YOU TALK TO.** Five rules keep them out, and
  every exclusion is reported in `excluded` with its reason rather than dropped
  silently — each rule can be wrong about somebody, and a person who has
  quietly vanished from their own social graph is what nobody would notice.
  Measured here, 734 of 9,301: 619 `no-reply`, 67 `short-code`, 22 `list`,
  16 `calendar-feed`, 10 `company`.
  - **`company`** — the card's "Company" tick box, which is the only reliable
    answer: a company card carries emails, phones and an address exactly like
    anyone else. ⚠️ It is often left off, so a card naming an organisation with
    **no personal name** counts too; none of the cards that rule catches
    carries a first name or a nickname, so it cannot take a person with it.
  - **`short-code`** — 🛑 a three-to-six digit number is an SMS short code and
    cannot be a person. PayPal, Venmo, Chase and United Airlines all arrive
    this way, each with a real contact card.
  - **`no-reply`** — a local part no person reads. ⚠️ Conservative on purpose:
    `office@`, `info@` and `contact@` are **not** on the list, because a small
    charity's office address really is answered by one person.
  - **`calendar-feed`** — 🛑 Google puts system addresses in the organiser and
    attendee fields: `unknownorganizer@calendar.google.com` for an event whose
    owner it cannot name, and `…@group.calendar.google.com` for a subscribed
    calendar or a meeting room. Three ranked inside the top sixty, one above
    real people.
  - 🛑 **`never-answered`** — **40 emails and not one reply, ever.** This is
    the only rule that reads the RELATIONSHIP rather than the address, and it
    is the one that catches a sender whose From line and address look exactly
    like a person's: `id@proxyvote.com` signing "NORTHWESTERN MUTUAL",
    `community_at_boulderreportinglab_org…`, `sharon@culinaryschoolrockies.com`.
    Measured: every real correspondent in the top sixty has written back at
    least twice, and the five transactional senders that survived every other
    rule have exactly **zero**. ⚠️ **One reply spares them**, however lopsided —
    Dean Mathena at 178 in, 2 out, is kept. ⚠️ **Mail only**: a text or a call
    is two-way by its nature, so a handle with either is never judged this way.
  - **`bulk-mail`** — 12 to 39 emails, never answered, a newsletter footer
    (`unsubscribe`, `view in your browser`, `do not reply`) on **half** of
    them, and the address does not carry their own name. ⚠️ Below forty,
    volume alone is wrong: two of the school's teachers wrote 16 and 19 times
    and were never answered, and they are people.
    - 🛑 **THE NAME GUARD TURNS ON THE DOMAIN.** `nancy.s@…school.com` carries
      "nancy", which the domain does not — a person. `chase@emailinfo.chase.com`
      carries "chase", which the domain does too — a brand writing from its own
      name. Without that clause the guard spared Chase, NYT, Northwestern
      Mutual and AT&T. ⚠️ Four characters at least: "ent" is a substring of
      "estatements".
  - **`list`** — see below.

  ⚠️ **The body scan reads the CANDIDATES' mail, not all of it.** Testing all
  40,557 bodies for a newsletter footer costs 17 seconds; testing only the few
  hundred belonging to somebody never written back to costs almost nothing. The
  first version scanned everything and tripled the command.

  **Two escape hatches, and the code is neither.** A business with a contact
  card is fixed by ticking "Company" on it, or
  `apple contacts edit <id> --company-card`. A business with **no card** — Mint
  ranked 17th here on 244 days and has none — is fixed with:

  ```
  apple-index people --not-a-person team@mint.com
  apple-index people --is-a-person  someone@example.com   # and back again
  ```

  🛑 **A ruling beats every rule, in both directions**, and that second
  direction is the one that matters: a business left in the list is visible,
  and a person taken out of it is not.

  🛑 **Rulings live in `~/Library/Application Support/apple-tools/people.json`,
  NOT beside the index.** `dirname(DEFAULT_DB)` follows the encrypted vault, so
  a file written there is unreadable whenever AppleTools is not running and is
  **destroyed by `apple-index forget`**. A ruling the user typed has to outlive
  the index it is about. **`files.json` moved for the same reason in
  26.827.0**, and a copy still at the old path is moved on sight the next time
  `apple-index files` runs.
- 🛑 **A mailing list is not a person, and the display name gives it away.**
  `notifications@github.com` arrives under the name of whoever triggered it —
  51 names, the commonest 23% of them. A real correspondent of twenty years
  signs three ways and the commonest is 75%. So the test is *dominance*, not a
  count of spellings, which put both in the same bucket. Only applied to an
  address with no contact card; reported as `counts.bulk`.
- ⚠️ **An edge is co-occurrence on one record**, and it is quadratic. One
  calendar event here carries 97 attendees, which alone is 4,656 edges saying
  nothing but "these people were on one invitation". Records with more than 12
  people count toward each person's total and draw no edges.
- 🛑 **THE UNIT IS A DAY.** The first version counted indexed records and
  called the sum "encounters". Three things were wrong with it, and the number
  it produced — 9,059 for a spouse — was the symptom:

  1. **A record is a different size in every source.** One mail record is one
     email; one messages record is a block of ten texts; one calendar record is
     one event. Measured: 3,024 message blocks for one person held 30,395
     actual texts.
  2. **Being on the same list is not talking.** 3,118 of the 5,751 emails
     naming her — 54% — were written by a third party to both of them. A school
     newsletter to forty parents counted as an encounter with each one.
  3. **A count of items rewards whoever writes in bursts.** Forty texts in one
     evening is one conversation.

  A day is the same unit in every source and cannot be inflated by volume.
  Measured here: that spouse comes out at 2,321 days across twenty years, and a
  committee colleague at 288. Both survive a sanity check; 9,059 did not.

  Read `days`. `channels` carries item counts in each channel's own unit —
  emails, texts, events, calls — and `channel_days` the same thing in days.
  🛑 **Never add `channels` together.** `same_list` counts the mail a third
  party sent you both, and is never in `days`. `alone` counts the items with
  nobody else on them, per channel — 🛑 per channel for the same reason, since
  a single `alone` figure came out at 17,201 for one person, which is texts
  wearing a number that reads like emails.

  **Verified against the raw store, not the index.** Reading the `To`/`Cc`/`From`
  headers of all 41,225 `.emlx` files directly gives, for that spouse:

  | | raw headers | `people` |
  |---|---|---|
  | messages carrying her address | 5,927 | — |
  | one of us wrote to the other | 2,625 | 2,598 |
  | a third party wrote to us both | 3,136 | 3,153 |
  | just the two of us | 1,336 | 1,351 |

  Within 1% on every line. ⚠️ **1,980 of the 5,927 are `Cc`**, which is what
  made the first version's "6,000 emails together" both true and wrong. The
  year curve is the other confirmation: direct mail peaks at 310 in 2011 and
  falls to 42 by 2022, because the conversation moved to texting in 2012.
  ⚠️ **An edge is still co-occurrence**, shared lists included. "Who turns up
  alongside whom" and "who do I talk to" are different questions.
- 🛑 **A DAY THAT HAS NOT HAPPENED IS NOT A DAY OF CONTACT.** The calendar
  adapter fetches a **year ahead**: 1,008 of the 12,014 events here are in the
  future, the furthest on 2027-08-25. A recurring swimming lesson therefore
  gave its organiser contact every week until next August. Three things went
  wrong at once and only the third was visible — the day count was inflated,
  `last` read 2027, and the timeline's axis ran a year past today, squashing
  twenty years of real history into less width than it had. Future records are
  counted in `upcoming` instead, per person, because "you have something with
  them next week" is true and worth keeping. It is just not contact.
- **`directory` is everyone, and everyone carries a month series.** The window
  draws a few dozen people; "who is this person" is a fair question about any
  of them, and so is "show me both Meyers" — one of whom is in 300th place.
  4,725 here against 80 drawn. 🛑 **One shared `months_axis`**, with each
  person's series a list of `[position, days]` into it: repeating "2014-07"
  nine thousand times is most of what a month series costs. The whole document
  is 3.1 MB for 16,806 month rows. ⚠️ 3,849 more people are left out entirely:
  they never exchanged anything with the user and appear only in somebody
  else's `same_list`.

## Your emoji

Emoji come only from what the user **sent**: a `me:` line in a messages block,
and a non-quoted line of mail from one of their own addresses. 🛑 Counting
everything measures what other people type at *them* — 😂 at 200 becomes 😂 at
1,499, and the two answers look alike.

`emoji.top` ranks them, `emoji.by_year` names the most-used one of each year and
`emoji.rarest` the least-used. ⚠️ **`rarest` is always something really sent,
once** — an emoji never sent belongs to no year at all. 🛑 **Ties break on the
emoji itself.** Most years have dozens used exactly once, and `min` over a dict
alone picked a different one on every run over identical data.

### How long you take to pick up a new emoji

`emoji.adoption` subtracts two dates. Measured on this store: **median 3.6
years, 11 of the 168 emoji released since 2020 used, 0 sent early.**

```
apple-index people | jq '.emoji.adoption | {used, released, median_lag_days}'
```

🛑 **BOTH DATES COME FROM unicode.org AND NEITHER IS TYPED IN.** A remembered
release date makes a wrong lag with nothing on screen to show it is wrong,
which is the same class of error as a mis-decoded table cell.

```
cd lab && ./emoji-versions            # rewrite emoji-versions.txt
          ./emoji-versions --check    # exit 1 if a new Emoji version shipped
```

- **Which version an emoji belongs to** is the `E<version>` field of
  `emoji-test.txt`. **When that version was published** is the `# Date:` header
  of *that version's own* data file. ⚠️ Not every version publishes the same
  files — Emoji 1.0 to 3.0 predate `emoji-test.txt` and 13.0 onward dropped
  `emoji-data.txt` — so the generator tries each in turn.
- ⚠️ **E0.6 and E0.7 predate the emoji spec entirely.** They are Unicode 6.0 and
  7.0, which have no directory under `Public/emoji` at all, and are dated from
  the UCD ReadMe instead. 2010-10-05 and 2014-06-12.
- ⚠️ **Skin-tone variants are not new emoji.** 👍🏽 arrived with the modifier, not
  with 👍, and counting the five tones separately would multiply every
  person-shaped emoji by five for no answer anybody wants. 1,906 base emoji
  across 16 versions.
- ⚠️ **A VENDOR SHIPS THE GLYPH LATER THAN UNICODE PUBLISHES IT**, often by a
  month or two, and nothing here knows when this keyboard got it. **A lag is an
  upper bound**, not an exact figure.
- 🛑 **A NEGATIVE LAG IS REPORTED, NEVER CLAMPED.** It means a record is dated
  before the emoji existed, which is a wrong date — clamping to zero hides the
  only sign of it. Counted as `early`, and left out of the median.
- 🛑 **`emoji-versions.txt` is declared in `index.py`'s `SIBLING_DATA`**, the
  same one declaration `make dist`, `app/stage.sh` and `apple-index selfcheck`
  all read. ⚠️ A missing copy degrades **quietly** — no adoption block,
  everything else unaffected — which is exactly why the build has to refuse it:
  an install short of the file looks like a user who has never sent a new emoji.

## Photos: who you were with, and where you have been

The Photos library answers the two questions no other source here can, and it
is read for those two things alone. Full measurements in
[`../docs/apple-photos-store.md`](../docs/apple-photos-store.md).

### The people

Every other channel needs an address or a phone number, so it can only see
somebody who **sends** things. Children do not send email.

Measured against this exact ranking, before and after:

| | days before | days after | rank before | rank after |
|---|---|---|---|---|
| the user's child | 18 | **1,394** | unranked | **3** |

She is in 9,416 photographs across 1,378 days, three times more than anyone
else in the library. Before photos she sat in the directory below **Merry
Maids**, a cleaning service, at 57 days. Fifteen more people entered the
directory who appear in no other source at all; every one is a child or close
family.

- 🛑 **The join is by Contacts id, not by name.** `ZPERSON.ZPERSONURI` holds
  `UUID:ABPerson`. ⚠️ It survives a name change, which nothing else here does.
- 🛑 **Emma is a dog.** `ZDETECTIONTYPE` separates people (1) from dogs (3) and
  cats (4). Without the filter she ranks fourth by tagged days. `osxphotos`
  does not expose this field.
- ⚠️ **It measures who was PHOTOGRAPHED, not who was there.** The user appears
  on 661 days and was present for all 1,378 of his daughter's.
- 🛑 **A shared-library photo is not proof you were there.** Those days are
  marked `alongside` and counted like a mailing list.

⚠️ **OPEN QUESTION.** `days` is one unit for every channel, so somebody you
email daily outranks somebody you are physically with. Whether "who you talk
to" and "who you are with" are one ranking or two is not decided.

### The places

```
./index.py places --limit 20
```

🛑 **TWO SOURCES, TWO UNITS, NEVER ADDED.** `maps` records an **arrival** with
a start time. `photos` records that a camera was somewhere on a **day**. 98 of
the 1,487 places here have both. Each row carries `visits` and `photo_days`
side by side, and nothing sums them — the same correction `people` made once by
adding emails to texts.

Photos reaches back to 2005 and holds 27,603 located pictures; the Maps store
holds 450 arrivals. ⚠️ Neither alone is "everywhere you have been".

### What is not indexed

The pictures, the OCR and Apple's scene labels. 36,341 photos carry **5,349
characters** of title and description between them. The OCR covers 5.9% and
the store keeps it as a bag of lowercased words with the order destroyed.

Measured: `eval.py` scores **MRR 0.538** with photos in the index and **0.538**
with every photo record deleted. The source costs nothing and gains nothing on
those 34 cases, which is the honest result — they are questions about mail and
notes.

## Geography

Two commands ask where things happened, rather than what they say.

```
./index.py near "Costco" --radius 2 --past
./index.py nearby --since 8 --past --radius 0.3
```

`near` lists everything within a radius of a place. `nearby` groups records
that sit close to each other. The value is the join across sources: a maps
visit says the user went to Stem Ciders on 16 August, and the calendar says
"Chad bday dinner" was that evening. Neither tool alone puts those together.

🛑 **Only a record that already carries a coordinate can be placed, and nothing
geocodes a location string after the fact.** Not this index, not EventKit, not
Calendar.app. That is why `apple calendar --at` exists: it resolves the place
at WRITE time, because nothing can do it later.

| Source | Records | Placeable |
|---|---|---|
| maps places | 197 | 197 |
| maps visits | 450 | 450 |
| calendar events | 11,379 | **617 (5%)** |
| mail, messages, notes, contacts | 47,852 | 0 |

⚠️ **So "nothing near X" means "nothing indexed with a coordinate is near X".**
It is never evidence the user was not there. Both commands print the gap, and
`--json` carries `placed_records` and `total_records`.

🛑 **A maps VISIT is deliberately not chunked, and this was measured.** Its
title and body are copied from the place it is a visit to, so 37 arrivals at
one gym become 37 identical chunks. Adding maps to the index sent the eval case
"Frequent Flyers address" from rank 1 to a miss, because the top ten filled
with visits that do not carry the address the question asks for. The place
record answers every text question; a visit carries a date and a coordinate,
which `near` and `nearby` read off the record directly.

🛑 **`near` collapsed nothing, so `--limit` hid the real neighbours.** A field
tester computed the separations independently and asked for
`near "Ocean First" --radius 1`. It returned 50 rows, every one of them true,
and **dropped two places 0.585 km and 0.705 km away** — because 50 occurrences
of one weekly class sit at 0.000 km and filled every slot. **The output looked
correct.** `near` now collapses on (tool, title) BEFORE applying the limit and
prints `(xN)`.

🛑 **A count on a collapsed line counts occurrences, not records.** A maps
**place** row summarises other rows, so counting it inflates every visit tally
by exactly one. The Elks Lodge printed `(x5)` from 4 visits plus 1 place record
and read as five trips. `near` and `nearby` now exclude it and label the number:
`(4 visits)` for maps, `(x105)` for a recurring event. Verified against
`apple maps places`: Ocean First 30, Deli Zone 2, Elks Lodge 4.

🛑 **A counting question needs both sources, and they disagree.** "How many
times did we go to the Elks Lodge this summer" gets **4** from maps arrivals and
**7** from calendar events at that address. Only two dates appear in both. A
calendar event is a plan, not an attendance record; Visited Places is a
heuristic that misses arrivals. Report the range and name both sources.

⚠️ **A shared street address is not a shared coordinate.** "Village Shopping
Center Boulder" and "Epic Mountain Gear" both read `2525 Arapahoe Avenue`, and
Apple pins them **110 m apart**. A test written from the addresses expected them
inside `--radius 0.1` and they are not. Trust the coordinate, never the address
string.

⚠️ **A visit has a start time and NOTHING ELSE.** There is no end time in the
store, so this index cannot say how long the user stayed anywhere.

⚠️ **This is Maps' "Visited Places", not Significant Locations.** Significant
Locations belongs to `routined` under `/var/db/locationd/`, which no
unprivileged process can read. Never report one as the other.

## Measurements

All on macOS 27.0 (26A5416b), M-series, 14 cores.

**Checking for new data is nearly free.**

| Store | Watermark query | Time |
|---|---|---|
| `chat.db` | `MAX(ROWID)` → 104,239 | 0.01s |
| `Envelope Index` | `MAX(ROWID)` → 113,011 over 41,827 messages | 0.02s |
| `NoteStore.sqlite` | `MAX(ZMODIFICATIONDATE1)` | 0.08s |

So a full "did anything change" sweep costs about 0.1s. **A daemon is not
needed to start.** `search` can catch up first, and a poll every five minutes
costs nothing.

**Embedding is the expensive half, and the rate depends on chunk length.**

| Input | Rate |
|---|---|
| a 180-word paragraph | 24.5 ms/chunk, **41 chunks/sec** |
| real note chunks (143 of them) | 13.9 ms/chunk, **71.9 chunks/sec** |

Both numbers are single-threaded. **Parallel scaling is not measured.** The
process already ran at 125% CPU, so eight workers will not give eight times the
rate. At 41 chunks/sec a 290k-chunk first build takes about two hours.

**Storage.** Vectors are int8: L2-normalised, scaled by 127. That is 512 bytes
per chunk. Each row records which model produced it, because two models do not
share a vector space and scoring across both returns confident nonsense.

## The model

**`intfloat/e5-small-v2`**, adopted after measuring six candidates. MRR 0.786,
661 MB resident, 9 minutes to index the corpus. The full comparison, the
prefixes each model needs, and the two wrong turns are in
[MODELS.md](MODELS.md).

## 🛑 The model: I picked the wrong one, and retrieval hid it

The first version used `NLContextualEmbedding` with mean-pooled token vectors.
It retrieved badly, and nothing showed that until a real question exposed it:
*"what is the HOA code for the bathroom door?"*. Six phrasings all missed the
note. A SQL `LIKE` found it in one try.

Measured directly, for the query "bathroom code":

| text | NLContextual (cosine) | NLEmbedding.sentence (distance, lower = closer) |
|---|---|---|
| the bathroom door code | 0.9461 | **0.4123** |
| Bathroom code | 0.9735 | 0.5466 |
| Bathroom code 3384 | 0.8173 | 0.8082 |
| Hub open house | 0.8977 | 1.0763 |
| Showroom appointment | 0.8955 | 1.1046 |
| Junkyard social | **0.9020** | 1.1674 |

🛑 **Under NLContextual, "Junkyard social" beat the literal answer.** The
sentence model ordered every candidate correctly.

⚠️ **Mean-centering the vectors did NOT fix it**, so this is not the usual
anisotropy problem. Apple documents `NLContextualEmbedding` as a **feature
layer** for training a model with CreateML. Pooling its token vectors and
comparing them by cosine is a use it was never built for.

The reasoning that chose it was "the sentence model is static, so a word gets
the same vector regardless of its sentence". That is a fact about the model's
design, not a measurement of retrieval quality, and it was the wrong basis for
the decision.

**The same weights now run as Core ML in Swift, with no PyTorch and no
virtualenv.** `vec` carries its own WordPiece tokenizer, and its vectors are
byte-identical to the Python path's on 19,999 of 20,000 chunks.

**The same weights now run as Core ML, with no PyTorch at all.** 878 chunks/sec
against 272.6, 0.999999 cosine parity, and no change in MRR. That is the path an
app can ship. Measurements, and the fp16 mask bug that only one backend showed,
are in [coreml/BAKEOFF.md](coreml/BAKEOFF.md). Select it with
`./index.py embed --model e5-small-coreml`.

`vec --model sentence|contextual` selects one. `sentence` is the default. The
sentence model is also **4× faster on short text**.

## Chunking

🛑 **A fixed-width window buries a short answer.** "Bathroom code 3384" sat one
line inside a 900-character window of unrelated HOA text. Mean-pooling that
diluted it until nothing found it.

Three changes took that chunk from 900 characters to **82**:

1. **Split on structure**, not width: headings and blank lines. Blocks are
   packed only while they share a heading and stay under 420 characters.
2. **Strip URLs.** 145 of the first 213 characters were an `applenotes://` link
   with a UUID in it. The signal was outnumbered 2 to 1 by a meaningless string.
3. **Drop repeated breadcrumbs.** A note whose first heading equals its title
   produced "X > X > Research".

⚠️ **Strip quoted reply text from mail.** 95,097 of 251,127 mail chunks carried
it, and a reply chain repeats the same paragraph once per level. One thread here
held the same sentence at five quote depths. Removing them cut mail 18%.

**`./index.py rechunk` rebuilds chunks from the bodies already stored**, so
changing the chunker costs 4.9 seconds rather than re-fetching 40,351 mail
bodies.

**The vector arm earns its place.** Query: *"where can I take the kids to play
outside"*. The lexical arm in `and` mode returns nothing useful. The vector arm
puts a note titled **"Park notes"** first, and that note contains no word from
the query.

## Findings from the first runs

Recorded here so nobody re-derives them.

- 🛑 **A recurring calendar event returns the same series id for every
  occurrence.** 30 events produced 4 uid collisions. The `occurrence` field is
  what separates them, so the uid is `calendar:<id>@<occurrence>`.
- ⚠️ **`apple mail search` can return the same `(id, account, mailbox)` twice.**
  Measured: 150 rows, 148 distinct, one Google DMARC message duplicated inside
  a single mailbox. This is Mail's index, not a bug in the reader. The `rev`
  check absorbs it, so no fix was applied.
- ⚠️ **A Message-ID alone is not unique across mailboxes**, so the mail uid
  carries the account and mailbox too.
- 🛑 **`apple mail search` with no `--limit` returns 20 rows, not everything.**
  The adapter passed no limit and meant "all". Combined with `--full` that
  deleted 128 indexed records and printed it as reconciliation. The adapter now
  asks for `1000000` explicitly.
- 🛑 **A source answering with a slice looks exactly like a source whose records
  were deleted.** `--full` now refuses to delete more than 20% of a tool's
  records and names the shortfall. `--force` overrides it. ⚠️ **That guard is
  not yet exercised by a test.**
- 🛑 **Changing a uid scheme silently doubles the index.** Old rows keep their
  old uid and nothing matches them. Ingest is not a migration. After any change
  to how a uid is built, delete `index.db` or run `ingest --full`.
- 🛑 **`subprocess.run(capture_output=True)` holds a child's progress output
  until the child exits.** `embed` looked silent for 60 minutes on a 223k-chunk
  run, and a log monitor watching for progress reported nothing. `cmd_embed`
  now lets stderr inherit, so it streams. Silence is not the same as stalled,
  and neither is visible from the outside.
- 🛑 **A WAL database cannot be opened with `SQLITE_OPEN_READONLY` when no
  `-shm` file exists.** A reader has to create that file, and a read-only
  handle cannot, so `vec search` failed with "unable to open database file".
  ⚠️ **It worked when driven through `index.py`**, because Python opened the
  database read-write first and left the `-shm` behind. So the bug was
  invisible from the normal path and only appeared when `vec` ran alone. It now
  opens read-write and sets `PRAGMA query_only = 1`.
- 🛑 **`cmd_search` discarded the embedder's stderr on success**, so `--verbose`
  showed nothing and a failing vector arm would have looked like "no semantic
  matches". Fixed.
- 🛑 **`--tool` was a POST-FILTER, so it did not search one source.** It ran
  after fusion, over candidates ranked globally, so `--tool notes --limit 30`
  returned **4 rows** out of 681 notes. On an index that is 68% mail, one
  source's records barely survive a global ranking. The filter now runs inside
  **both** arms: the lexical arm joins `record` in SQL, and the vector arm
  masks the matrix before scoring. The same query now returns 30. ⚠️ The
  post-filter is still there as a backstop, because an OLDER daemon ignores the
  `tool` key and answers globally.
- 🛑 **Widening the candidate pool fixes nothing, and I predicted it would.** I
  told a field tester that three failing cases would be fixed by a deeper pool.
  Measured across pools of 60, 120, 200, 300 and 500: **hit@1, hit@3, hit@10
  and MRR are identical at every size.** The correct records already sat at
  global semantic ranks 16, 4 and 1. They lose at FUSION, not at retrieval
  depth. `--pool` exists now so the next person can re-measure this in one
  command instead of believing me.
- ⚠️ **A query with several correct answers cannot be anchored on one of
  them.** "what is the garage door code" was anchored on a 2026 message where
  the code is incidental. A field test retrieved a 2022 message that states the
  code plainly, at rank 1, and the eval scored it a MISS. This is the second
  time a wrong label made a correct answer look like a failure. The locator now
  accepts any of the 7 records that state it.
- 🛑 **`--min-chunk` fixes the case it was built for and loses overall.** A bare
  calendar title "Hair cut" scores 0.869 against "where do I get my hair cut",
  beating "Welcome Stranger Barber Shop" at 0.848 — and the calendar events
  carry no location, so they do not answer the question. Scaling short chunks
  down fixes that one case. Measured on 29 cases: MRR **0.586 -> 0.530** at 20,
  0.540 at 60, 0.459 at 100. Shipped at 0, with the sweep left in `eval.py`.
- 🛑 **A source that is 0.17% of the index gets buried, however well it
  matches.** `maps` is 394 chunks of 237,971. "where do I get my hair cut" puts
  the right barber shop at semantic rank **1 within maps** and **outside the
  global top 60**. `--tool maps` finds it instantly. Nothing else does.
- ⚠️ **A case was WITHDRAWN, not re-anchored**: "did I send anyone my home
  address". The address appears in dozens of messages, so the query has no
  single correct answer and MRR against it measures nothing. Deleting a bad
  case is better than averaging over it.
- **Embedding runs faster than the paragraph benchmark on real data**: 58 to 83
  chunks/sec across notes, mail, calendar and messages, against 41 on a
  180-word paragraph. Short chunks are cheap.

## Design choices worth arguing with

These are the experiment. Change them and see what happens.

- **Messages are indexed in blocks, not one per message.** One SMS is too short
  to embed well. `--message-block 10` sets the window. This is the single
  biggest open question in the ingest path.
- **The lexical arm defaults to `OR`, not `AND`.** `apple mail search` ANDs.
  Here fusion re-ranks afterwards, so the lexical arm should favour recall.
  `--fts-mode and` switches it back.
- **The title gets its own chunk**, and it is also prefixed onto every body
  chunk so a mid-body window keeps its subject.
- **Reciprocal Rank Fusion with k=60.** No weighting between the two arms yet.
- **bm25 column weights are 4.0 title, 1.0 body, 2.0 people.** Guessed, not
  measured.
- **Blocks pack to 420 characters and split on structure.** A block longer
  than 900 characters still gets a sliding window, because a wall of prose has
  no structure to split on.

## Not done

- **A people resolver.** Handles are phone numbers and emails, never names.
  Apple injects a `ContactResolver`. Until that exists here, "what did Sarah
  say" only works when the name appears in the text.
- **Watermarks.** `source_state` has the column and nothing writes it. Ingest
  re-reads everything and skips unchanged records by `rev` hash. That is
  correct but not cheap.
- **Deletion detection** only runs with `--full`, which does a full id-set
  sweep. There is no incremental path.
- **URLs.** Only mail and contacts emit one. `docs/todo-deep-links.md` is the
  prerequisite.
- **Chunk texts are not deduplicated.** 42,322 of 239,056 chunks (18%) are
  exact duplicates, mostly recurring calendar events: "Margot Daycare" appears
  460 times. Keying vectors by a content hash instead of a chunk id would save
  18% of the embed time and storage. This is the next improvement.
- ~~**No daemon.**~~ `vec daemon` shipped in 26.822.1 and **the app owns it as
  of 2026-08-23**. ⚠️ **The two-process rule this line used to state is retired.**
  It said a daemon must be two processes, because the disclaiming tools
  (calendar, contacts, reminders) lose Full Disk Access. Inside the app nothing
  disclaims: `APPLE_TOOLS_OWN_TCC_IDENTITY` makes them skip the re-exec and run
  under the app's identity, so **one process tree serves both halves**. See
  [`../app/README.md`](../app/README.md).
- **Mail bodies are opt-in** (`--with-bodies`) because they cost one subprocess
  per message.
