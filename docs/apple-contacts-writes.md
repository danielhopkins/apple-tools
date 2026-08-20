# Writing contacts: the walls, the fallbacks, and what lies

Everything here was measured against a real address book (669 contacts, 52 of
them carrying a note). `CLAUDE.md` keeps the operative rules; this file keeps
the evidence and the history, so a future reader does not re-derive it.

## The note wall

🛑 **A note blocks *every* `CNContactStore` write to that contact, not just the
note.** The save faults the whole record, faulting reads the note attribute, and
reading it needs `com.apple.developer.contacts.notes` — an entitlement Apple
grants only to signed apps on request, which no CLI can hold. So an unrelated
`--company` change is collateral damage.

It fails as a bare `NSCocoaErrorDomain 134092` with an **empty `userInfo`**,
naming neither the contact nor the note, plus a raw `CoreData: error: Unhandled
error occurred during faulting` on stderr. **52 of 669 contacts here carry a
note**, so this was ~8% of a real address book that could not be edited or added
to a group at all.

`edit`, `groups add`, `link` and `unlink` catch it and rewrite through the
**legacy `AddressBook` framework**, which writes the same records under the same
`UUID:ABPerson` identifiers and needs no permission beyond the Contacts access
the tool already has.

- 🛑 **`link` and `unlink` were left out of this until 26.818.2**, and they are
  the commands most likely to meet a note: relations are what you write when you
  are filling in a family. `writeRelations` is their shared writer and had no
  fallback, so every link touching one of the 52 note-bearing contacts failed
  with the bare 134092. ⚠️ `link` writes its **first** argument first, so the
  failure left **neither** card written rather than half of a pair. Pinned by
  three tests in `tests/test_contacts_write.py::NoteBearingContacts`, all three
  of which fail against the code before the fix.
- ⚠️ **AddressBook's first save always fails and the second one works.**
  Faulting trips the wall once; afterwards the pending changes commit. So a lone
  failure means nothing there, and the write is confirmed by re-reading rather
  than by any return value.
- The fallback writes `kABBirthdayComponentsProperty` and
  `kABOtherDateComponentsProperty`, not the plain `NSDate` ones, because those
  cannot express a year-less `--MM-DD`.
- The note itself still cannot be written by either path, and is left untouched.
- The raw CoreData dump is suppressed (`com.apple.CoreData.Logging.stderr`, in
  the in-memory registration domain) since the tool explains the failure itself.

⚠️ **The AddressBook fallback is the NORMAL path for a death, not the
exception.** All four cards recorded as deceased on this store carry a note — an
obituary link, or the marker — so `--died` reaches the legacy framework far more
often than it reaches Contacts. Both paths are pinned by live tests.

## Diagnosing a `CNSaveRequest` failure

⚠️ **A `CNSaveRequest` failure says only "Save operation could not be
completed."** That is `CNError`'s entire `localizedDescription` for every failure
mode. Everything diagnostic is in `userInfo` — `CNErrorUserInfoKeyPathsKey`,
`CNErrorUserInfoAffectedRecordIdentifiersKey`,
`CNErrorUserInfoValidationErrorsKey`, `NSUnderlyingErrorKey` — so the group
commands print all of it. If you add a new write path, do the same; the generic
string alone costs hours.

## Groups

🛑 **A contact can only join a group in its own account, and nothing in the API
says which account anything is in.** One `CNSaveRequest` cannot span two
containers: adding a contact from account A to a group in account B fails with
Core Data's `NSPersistentStoreIncompleteSaveError` (**`NSCocoaErrorDomain
134040`**, "one or more of the stores returned an error"), which names neither
store. The contact is simply in the wrong account, permanently — retrying,
waiting for sync, and deleting-and-recreating all change nothing. `groups add`
detects this before saving and names both sides, then points at `contacts move`.

🛑 **`groups remove` depends on which account the group lives in.**
`CNSaveRequest.removeMember` saves without error and changes *nothing* for a
**CardDAV-backed (iCloud) group**, while working correctly for a **local ("On My
Mac") group**. Same code, same objects — only the container differs, and nothing
at the call site distinguishes them:

| Container | Type | Member removed |
|-----------|------|----------------|
| `On My Mac` | local | yes |
| an iCloud account | cardDAV | **no, silently** |

So `groups remove` tries `CNSaveRequest` first and, when the membership
survives, falls back to the **legacy `AddressBook` framework**, which removes
iCloud members correctly. Because that is deprecated API that could eventually
stop working, the command re-reads the membership afterwards and fails loudly if
the contact is still in the group rather than trusting either call's return
value.

🛑 **Group membership must never be handed a *unified* contact.** This is what
made `groups add` fail for freshly created contacts with nothing but `Save
operation could not be completed.`. `unifiedContact(withIdentifier:)` returns a
synthetic merge of every linked record, and `CNSaveRequest.addMember` needs the
**container-backed** record — so both `groups add` and `groups remove` fetch with
`unifyResults = false`.

It presents as intermittent, which is the trap: a brand-new contact is usually
unlinked, so its unified form is indistinguishable from its backing record and
the add works. Once macOS links it to another card, the unified contact's
`identifier` can belong to a *different* linked record, the save is refused, and
it stays refused — through delete-and-recreate, because the linking happens
again. So "it worked the first time" is not evidence the path is sound.

🛑 **A contact has two identifiers, and mixing them silently answers "no".** The
unified id (`BD00169D-…`) and the container-backed id (`D065726A-…:ABPerson`)
name the same person. Any membership *check* has to accept both spellings —
comparing a backing id against a `unifiedContacts` fetch of the group made a
**successful** add report *"the save reported success but X is not in the
group"*, and made `container` come back null for exactly the linked contacts
that need it. `memberIdentifiers(of:)` unions a unified fetch with a non-unified
enumeration for this reason.

⚠️ **`add` can return an identifier the store does not use.** Creating a contact
with an explicit `--container` handed back a bare `BD00169D-…` while the record
in the store was `D065726A-…:ABPerson`. Both resolve through `get`, so the id is
usable — but never build a comparison on the assumption that they match.

⚠️ **An unrecognised `--container` used to be silently ignored.**
`add(_:toContainerWithIdentifier:)` treats an unknown identifier as nil and files
the record in the default container, reporting success. It is now a hard error
listing the valid containers.

## `--url`: where the label ends and the scheme begins

🛑 **An allowlist of schemes was the wrong shape and lost data silently.** Until
26.820.2 a prefix counted as a scheme only when the rest began `//`, or when the
prefix was one of eight hard-coded words. Every other scheme legitimately written
**without** `//` fell through, became a label, and the URL was stored with its
scheme stripped — exit 0, no warning. Measured:

| input | stored before |
|---|---|
| `webcal:cal.example.com/f.ics` | label `webcal`, url `cal.example.com/f.ics` |
| `ftps:files.example.com` | label `ftps` |
| `matrix:r/x` | label `matrix` |
| `https:lower.example.com` | label `https` |

⚠️ **It was never a case problem**, though it looked like one — the allowlist
already lowercased, so `MAILTO:` worked and `https:` failed. The missing `//` was
the whole cause.

`--url` now asks what follows the colon instead of consulting a list:

1. A **built-in label** wins outright, so `work:example.com` stays a label.
2. Otherwise a prefix matching the RFC 3986 scheme grammar is a scheme when the
   rest starts `//`, **or** the rest is one unbroken token carrying no scheme of
   its own.
3. Anything else is a label.

🛑 Rule 2's second half is what keeps `LinkedIn:https://x.com` a label: the rest
already has a scheme, so the prefix cannot be one too.

⚠️ **`LinkedIn:example.com` is genuinely ambiguous** — a valid scheme grammar
followed by a bare host, indistinguishable from `matrix:r/x`. It is read as a URL
and a note on stderr says how to force the other reading. The note fires only for
a scheme nobody would recognise, and **once**: `urls` is recomputed by validate,
apply and the read-back check, so warning inside the parser printed three times.

🛑 **The fuller rule is `--url` only.** `split` runs for every labelled flag, and
`--relation "father:Robert"` must give the label `father` — `father` matches the
scheme grammar and `Robert` is one unbroken token. The shared splitter keeps just
the conservative test, including the eight-word list, because `--email
"mailto:a@x.com"` and `--phone "tel:+1555…"` are supported inputs. A first
attempt moved the whole test into the URL path and broke both.

⚠️ **The value is trimmed now.** `--url "Note: https://x"` stored a leading
space, and the URL stopped resolving.

## Postal addresses

🛑 **Three parse bugs were found by probing real addresses, and every one was
silent.** They are pinned by tests in `swift/Tests/ContactsTests/`:

| input | wrong result | why |
|---|---|---|
| `…, Cupertino, CA` | `country=CA` | a state abbreviation has no digits either |
| `SW1A 2AA` | `state=SW1A;zip=2AA` | a UK postcode is one token pair, not two fields |
| `ON M5H 2N2` | `state=ON M5H;zip=2N2` | a Canadian postcode is two tokens after a province |

🛑 **A typo'd key is an error, not a dropped field.** `citty=Chicago` used to
fall through to the free-text parser and land as a *street* reading
`citty=Chicago`, with exit 0 — the same silent-drop failure the label encoders
were fixed for. Anything of the form `word=` now goes to the structured parser,
where an unknown key is refused naming the valid ones.

🛑 **Never probe this parser by running `add`.** Seventeen contacts were created
in the user's real iCloud to see how strings parsed, and they synced to every
device before being deleted. `PostalAddress` lives in its own `ContactsLibrary`
target so every such question is answered offline.

Labels are the four generic ones — `home`, `work`, `school`, `other`. There is no
address-specific constant in the SDK, unlike email's `icloud`.

## Deaths

🛑 **Apple defines no death field anywhere.** Measured across all three layers a
contact can be written through:

| Layer | Date labels it defines | Death? |
|---|---|---|
| `CNContact` | `CNLabelDateAnniversary`, and nothing else | none |
| legacy `AddressBook` | `kABAnniversaryLabel`, and nothing else | none |
| `AddressBook-v22.abcddb` | `ZABCDCONTACTDATE.ZLABEL`, free text | no column |

So a custom label on `dates` is the only route. `DeathDate` in `ContactsLibrary`
is the one place that decides how it is spelled: **`death`** for a full date,
**`death-year`** when only the year is known.

🛑 **A labelled date REQUIRES a month and a day; only the year is optional** —
the exact inverse of what "died in 2020" needs. Measured against a real store,
with fixtures deleted afterwards:

| Written | Result |
|---|---|
| `2020` | refused — `CNErrorDomain 302`, key paths `dates.value.month`, `dates.value.day` |
| `2020-04` | refused — `CNErrorDomain 302`, key path `dates.value.day` |
| `--04-30` | accepted |
| `2020-04-30` | accepted |

`--birthday 2020` fails the same way, so the rule belongs to Contacts and not to
one key path.

🛑 **A year-only death therefore stores a day it never had.** The card holds
`2020-01-01`; `died` says `2020`. Nothing else can carry that fact — `CNContact`
has no free-text field but the note, and the note needs an entitlement no CLI can
hold. So the *label* is the disclosure.

🛑 **`2020-04` is refused rather than padded.** Contacts rejects it anyway, and
inventing a day would record a month as though it were exact — with no label left
to disclose it.

⚠️ **Matching a label ignores case, writing never does.** A card written by hand
may say `Death`, and a person who died is not a thing to miss over one letter.
🛑 The **whole** label must match: a prefix test would make `death-year` match
`death` and report its placeholder day as real.

## Relations

🛑 **A relation stores a NAME, not a reference.** Contacts.app renders one as a
tappable link, which reads as though it holds the other card's id. It does not.
Measured: all 54 relation rows here carry a `ZUNIQUEID`, all 54 values are
distinct, and **none** matches any `ZABCDRECORD.ZUNIQUEID` — that column is the
relation row's own sync id. Three consequences:

- **Renaming a contact silently breaks every link to it.** Nothing updates.
- **A relation can name nobody.** Two do on this store, and that is not corruption.
- **A relation can name several people**, when two cards share a name.

**`relations` reports both directions**, and the reverse half is the one people
want. `related_from` is a scan of every card for anyone naming this contact —
Contacts has no reverse index, so there is no cheaper way. 1.1s over 679
contacts. On this store Dan lists three brothers and **none of them lists him
back**; only his parents do.

🛑 **A gendered label inverts to the NEUTRAL term, and that is not a guess.**
`father` gives the other card `child`, `brother` gives `sibling`, `grandmother`
gives `grandchild`. An earlier version refused these, reasoning that the other
side is "son or daughter" and Contacts records no gender. That was wrong: `child`
is exactly the term for "son or daughter", the SDK defines it, and writing it
states nothing untrue.

⚠️ **`husband` and `wife` are NOT symmetric.** If B is A's husband, A is B's wife
*or* husband, so both invert to `spouse`.

⚠️ **The inverse generalises; it does not round-trip.** `father` → `child`, and
`child` → `parent`, not back to `father`. Correct — the child's card never
recorded the parent's gender.

🛑 **`ParentsSibling` and `SiblingsChild` are the SDK's neutral terms for
aunt/uncle and nephew/niece.** An earlier version refused all four, claiming no
such term existed. That came from searching for an obvious English word instead
of reading the generated list.

**Seven labels are genuinely refused**, each checked against the label list
rather than assumed: `stepbrother`/`stepsister` (no `Stepsibling`),
`grandaunt`/`granduncle` and `grandnephew`/`grandniece` (no neutral either way),
and `teacher` (the SDK defines no `Student`). ⚠️ The remaining ~150 labels are
specific kinship paths — `AuntFathersElderBrothersWife` and the like —
deliberately unmapped. They refuse cleanly and `--inverse` still works.
`RelationCoverageTests` audits the table against the generated vocabulary.

🛑 **Relation labels are stored in two spellings, and both are live here.** One
card holds `_$!<Father>!$_` and another a plain `Sibling`, and `Labels.decode`
passes an unrecognised bare word through unchanged, capitals and all. Comparing
raw labels misses real matches: `link` reported "would add" for a relation the
contact already had, and a second run would have written a duplicate. Compare
through `sameRelationLabel`, never on the raw string.

🛑 **`--name-only` is how you name somebody who has no card**, and it is opt-in.
Falling back to a plain name whenever the second argument fails to resolve would
turn a typo in a real contact's name into a dangling relation, **silently**.
`--inverse` is refused with it, since there is no card to write onto.

🛑 **`unlink` used to confirm nothing.** Every other write here re-reads a fresh
store, because `CNSaveRequest` reporting success is not evidence — `groups
remove` saves without error and changes nothing at all on an iCloud group. A
removal had the same exposure and no guard until 26.818.3.

🛑 **`unlink --relation L` matches the other card on L's INVERSE.** Filtering both
sides on the same label removed `parent` from one card and left `child` on the
other, while reporting that it had removed both. When the inverse cannot be
inferred, the other card is **left alone** and the command says so.

## Notes on the note field

⚠️ **`--note` is not writable, by construction.** Reading a note works, but
writing needs `com.apple.developer.contacts.notes`, which Apple grants only to
signed apps on request. Notes are read straight from the AddressBook SQLite store
instead. Note edits must happen in Contacts.app.

**`export` includes notes**, unlike a plain Contacts-framework export — read from
the AddressBook store and spliced in as a folded, escaped `NOTE` property. So it
needs Full Disk Access for that one field, and without it everything else still
exports. Verified by round-tripping a real 514-character note byte-for-byte.

**`marked_without_date` is the second half of `deceased`.** Some address books
mark a death with a dagger (`†`) in the note. That marker is **never the record
and never makes anyone deceased** — it is reported only because the tool cannot
write a note, so it can never resolve such a card itself.

## Reading the AddressBook store

🛑 **Never open the AddressBook stores with `immutable=1`.** Contacts leaves a 3 MB
write-ahead log, and `immutable=1` does not replay it — so a contact added minutes
ago is invisible. The handle count also moved 1367 → 1365 once the log was
replayed, because it carries deletions too: the immutable snapshot was stale in
*both* directions. Plain read-only open first, `immutable=1` only as a fallback.

`Notes.swift` in `AppleContacts` did exactly this until 26.812.8, and the latency
was not theoretical: it could not see a note written seconds earlier, so `contacts
move`'s "this contact has a note" refusal never fired. Fixed the same way, which
also means `get --json` now reports a fresher note. `apple phone` hit the same trap
in its caller resolver — see
[`apple-phone-store.md`](apple-phone-store.md).
