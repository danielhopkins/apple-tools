# Moving a contact between accounts

Reading which account a contact is in is public API. Changing it is not.

This is the record of how `apple contacts move` works, what was ruled out
first, and the two things that make it dangerous enough to be worth writing
down.

## The problem

A contact can only join a group in its own account. `CNSaveRequest` cannot span
two containers: adding a contact from account A to a group in account B fails
with Core Data's `NSPersistentStoreIncompleteSaveError`
(`NSCocoaErrorDomain 134040`, "one or more of the stores returned an error"),
which names neither store.

`apple contacts groups add` has detected and explained that since 26.727. What
it could not do was fix it — and the fix is not obscure, because Contacts.app
does it by dragging the card onto an account in the sidebar.

## What the public API can do: nothing

`CNSaveRequest`'s entire mutation surface is:

```
add(_:toContainerWithIdentifier:)   delete(_:)      update(_:)
addGroup(_:toContainerWithIdentifier:)  deleteGroup(_:)  updateGroup(_:)
addMember(_:to:)                    removeMember(_:from:)
```

The container is fixed at `add`, and `update(_:)` cannot change it. There is no
move, and no `CNMutableContact` property that names a container.

So the only public implementation is copy-then-delete, and it is lossy twice:

- the copy gets a **new identifier**, breaking every stored reference to the
  old one and every group membership keyed to it
- it **drops the note**, because writing a note needs
  `com.apple.developer.contacts.notes`, which Apple grants only to signed apps
  on request

Shipping that under the word "move" would be its own trap. It was not shipped.

## 🛑 The private call that looks right and lies

`ABRecord` has `-nts_MoveIntoAddressBook:account:error:`. It is exactly the
right shape, it takes the destination account, and against a real contact it:

```
move returned: true  err: nil
save: true
```

and moved nothing. The record was still in the source store on disk afterwards,
by direct SQLite inspection of both databases.

Disassembly explains it without excusing it — for a record that already has a
`databaseImpl`, it computes a destination store URL and hands the work to a
class method whose result it returns, and that result was `YES` for a no-op.
The guard it *does* implement is the opposite case: a record already in a
persistent book fails with `"Record is already a member of a persistent address
book: %@ %@"`.

This is the third API in this repo to report success for a write that never
happened, after `EKEventStore.save` and `CNSaveRequest.removeMember`. It is why
`move` re-reads the container from a fresh store and exits non-zero on a
mismatch rather than reporting its own request back.

## What actually works

`ABAddressBook` has `-importPeople:intoAccount:createNewUIDs:`. With
`createNewUIDs: NO` it copies the record into another account **keeping its
unique id**:

```
importPeople -> (2573D4D1-85F5-4F9B-BACD-02D98984A405:ABPerson)
```

Afterwards both stores hold that same `UUID:ABPerson`. So the second half —
removing the original — cannot be done by id alone. `ABAddressBook` has
`-recordForUniqueId:inAccount:`, which scopes the lookup to one account, and
`ABRecord` has `-account`, so the record can be checked again immediately before
it is deleted.

🛑 **That check is the difference between a move and a data loss.** Between the
import and the removal the contact exists twice under one identifier. Any lookup
that resolved to the *new* copy and deleted it would destroy the contact
outright while reporting a successful move.

Verified on this machine, both directions, id preserved and all fields intact:

| | result |
|---|---|
| `_local` → cardDAV | id unchanged, gone from the root store |
| cardDAV → `_local` | id unchanged, gone from the source store |
| then `groups add` in the new account | succeeds — the point of the exercise |

The container id and the AddressBook account id are the same string with
`:ABAccount` appended (`A65452E9-…:ABAccount` ↔ `A65452E9-…`, `_local:ABAccount`
↔ `_local`), which is the whole mapping between the two frameworks.

⚠️ **AddressBook lists more accounts than `containers` does** —
`_directoryServices` and `_acceptedIntroductions` ("Other Known"), neither of
which accepts a contact. Destinations are resolved through `CNContainer` for
that reason; the AddressBook account list is only ever used to look up one a
container already named.

## 🛑 A note makes the move raise, not fail

`importPeople:` → `importContact:replaceValues:` → `importNoteFromContact:`,
which faults the note attribute, which needs the entitlement. Core Data does not
return that failure. It **throws**:

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'Unhandled error (NSCocoaErrorDomain, 134092) occurred during
    faulting and was thrown'
  6  -[ABCDContact(MergingInternalAdditions) importNoteFromContact:replaceValues:]
  7  -[ABCDContact(MergingInternalAdditions) importContact:replaceValues:]
  8  __56-[ABAddressBook importPeople:intoAccount:createNewUIDs:]_block_invoke
```

Swift cannot catch an `NSException` — it unwinds straight past Swift frames and
terminates the process. In a two-step import-then-delete, dying partway through
is precisely how a contact ends up existing twice.

So there are two defences, in this order:

1. **Refuse up front.** `NoteStore` is consulted before anything is written and
   a note-bearing contact is refused, naming the note and pointing at
   Contacts.app.
2. **Guard the call anyway.** The private calls run inside
   `AppleToolsRunCatchingExceptions` (`Sources/ObjCExceptions`), which converts a
   raised exception into an error carrying the exception name and the underlying
   `NSError` — the only place the 134092 code survives. A note that the SQLite
   reader could not see, because another device wrote it and it has not synced,
   lands here instead of killing the process.

⚠️ **The up-front check only started working once `NoteStore` stopped using
`immutable=1`.** A note planted seconds earlier was invisible to it, so the
refusal never fired and the move fell through to the exception guard. Contacts
leaves a large write-ahead log, and `immutable=1` does not replay it — stale in
both directions, with no error. `apple phone` hit the same trap resolving caller
names. `NoteStore` now opens plain read-only first and falls back to
`immutable=1`, which also means `get --json` reports a fresher note than it used
to.

## What a move costs

**Group membership, always.** A group belongs to one account, so a contact
leaves every group in the account it came from. There is no way around it and
nothing clever to do about it — re-adding to same-named groups in the
destination would be guessing.

It is reported instead: `--dry-run` lists the groups the move will empty before
anything is written, and the result carries `groups_left` either way.

**Nothing else.** The identifier, every field, and the note (on a contact that
has one, which cannot be moved anyway) are unaffected.

## Failure handling

The import and the removal are separate saves, so a failure between them would
leave a duplicate. If the removal fails, the import is rolled back — resolved by
account, same as the forward path.

If the rollback cannot name the copy precisely, **nothing is deleted** and the
duplicate is reported. Leaving two copies is recoverable in Contacts.app;
deleting both is not.

## Not covered

- **The "me" card** is not treated specially. Moving it has not been tested.
- **Linked contacts**: `move` operates on the container-backed record the
  identifier resolves to, not on every card macOS has linked to it. A person
  whose card is linked across accounts will still have the other records where
  they were.
- Only `local` ↔ `cardDAV` was exercised, because those are the two containers
  on this machine. An Exchange container should behave the same way — it is the
  same `ABAccount` machinery — but that is an expectation, not a measurement.
