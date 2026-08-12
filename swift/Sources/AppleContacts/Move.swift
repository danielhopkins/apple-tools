import AddressBook
import AppleToolsStyle
import ArgumentParser
import Contacts
import Foundation
import ObjCExceptions

// MARK: - Why moving a contact needs private API

/// 🛑 **`CNSaveRequest` has no move, and its whole mutation surface is add /
/// update / delete for contacts and groups plus add / remove member.** A
/// contact's container is fixed at `add(_:toContainerWithIdentifier:)` and
/// `update(_:)` cannot change it. So the obvious implementation — copy into the
/// target container, delete the original — is the only one the public API
/// allows, and it is lossy twice over: the copy gets a **new identifier**,
/// breaking every stored reference and its group memberships, and it **drops
/// the note**, since notes cannot be written without an entitlement no CLI can
/// hold.
///
/// The legacy AddressBook framework can do it properly.
/// `importPeople:intoAccount:createNewUIDs:` with `createNewUIDs: false` copies
/// the record into another account **keeping its unique id**, and
/// `recordForUniqueId:inAccount:` then names the source copy exactly, so it can
/// be removed without touching the one just created. Both stores hold the same
/// `UUID:ABPerson` in between, which is why every step here is account-scoped
/// rather than id-scoped.
///
/// Verified on this machine, both directions, with the id preserved:
///
///     _local → cardDAV   id 2573D4D1-…:ABPerson unchanged, all fields intact,
///                        gone from the root store afterwards
///     cardDAV → _local   likewise
///
/// and the point of the exercise confirmed: a contact moved into the group's
/// account can then be added to that group, which is the dead end `groups add`
/// used to report and could not fix.
///
/// Every symbol used here is private and resolved at runtime, so a macOS that
/// drops them gives a clean refusal rather than a crash — the same rule
/// `apple calendar`'s invitee writes follow.
enum AccountAPI {
    private static let bookClass: AnyClass? = NSClassFromString("ABAddressBook")
    private static let recordClass: AnyClass? = NSClassFromString("ABRecord")

    private static let accountsSelector = NSSelectorFromString("accounts")
    private static let identifierSelector = NSSelectorFromString("identifier")
    private static let accountSelector = NSSelectorFromString("account")
    private static let importSelector = NSSelectorFromString(
        "importPeople:intoAccount:createNewUIDs:")
    private static let recordInAccountSelector = NSSelectorFromString("recordForUniqueId:inAccount:")
    private static let removeSelector = NSSelectorFromString("removeRecord:error:")

    private typealias ImportFn = @convention(c) (
        AnyObject, Selector, AnyObject, AnyObject, Bool
    ) -> AnyObject?
    private typealias RecordFn = @convention(c) (
        AnyObject, Selector, NSString, AnyObject
    ) -> AnyObject?
    private typealias RemoveFn = @convention(c) (
        AnyObject, Selector, AnyObject, UnsafeMutablePointer<Unmanaged<NSError>?>?
    ) -> Bool

    /// `class_getInstanceMethod`, never `class_getMethodImplementation`: the
    /// latter hands back `_objc_msgForward` for a selector that does not exist,
    /// turning "this macOS dropped the API" into a crash at call time.
    private static func imp(_ cls: AnyClass?, _ selector: Selector) -> IMP? {
        guard let cls, let method = class_getInstanceMethod(cls, selector) else { return nil }
        return method_getImplementation(method)
    }

    static var isAvailable: Bool {
        imp(bookClass, importSelector) != nil
            && imp(bookClass, recordInAccountSelector) != nil
            && imp(bookClass, removeSelector) != nil
            && imp(recordClass, accountSelector) != nil
    }

    static let unavailableMessage = """
        this build of macOS no longer exposes the private AddressBook calls that moving a \
        contact between accounts needs (ABAddressBook.importPeople:intoAccount:createNewUIDs: / \
        recordForUniqueId:inAccount:). There is no public API for this — CNSaveRequest cannot \
        change a contact's container — so move the card in Contacts.app instead by dragging it \
        onto the account in the sidebar.
        """

    /// Every account the AddressBook store knows about.
    ///
    /// ⚠️ **More than `apple contacts containers` lists.** AddressBook reports
    /// `_directoryServices` and `_acceptedIntroductions` ("Other Known") too,
    /// neither of which accepts a contact. Targets are resolved through
    /// `CNContainer` for exactly that reason; this is only ever used to look up
    /// an account that a container already named.
    private static func accounts(_ book: ABAddressBook) -> [AnyObject] {
        guard let repository = book.value(forKey: "accountRepository") as AnyObject?,
            repository.responds(to: accountsSelector)
        else { return [] }
        return repository.perform(accountsSelector)?.takeUnretainedValue() as? [AnyObject] ?? []
    }

    private static func identifier(of account: AnyObject) -> String? {
        guard account.responds(to: identifierSelector) else { return nil }
        return account.perform(identifierSelector)?.takeUnretainedValue() as? String
    }

    /// The `ABAccount` matching a `CNContainer` identifier.
    ///
    /// A container id is the account id with `:ABAccount` appended
    /// (`A65452E9-…:ABAccount`, `_local:ABAccount`), so both spellings are
    /// tried rather than assuming the suffix is always there.
    static func account(_ book: ABAddressBook, forContainer containerId: String) -> AnyObject? {
        let bare = containerId.hasSuffix(":ABAccount")
            ? String(containerId.dropLast(":ABAccount".count))
            : containerId
        return accounts(book).first { identifier(of: $0) == bare || identifier(of: $0) == containerId }
    }

    /// The account a record currently belongs to.
    ///
    /// 🛑 This is the safety check that makes the delete step survivable. After
    /// the import, **both accounts hold a record with the same unique id**, so
    /// anything that resolves by id alone can hand back the copy that was just
    /// created. Deleting that one loses the contact outright.
    static func accountIdentifier(of record: ABRecord) -> String? {
        let object = record as AnyObject
        guard object.responds(to: accountSelector),
            let account = object.perform(accountSelector)?.takeUnretainedValue()
        else { return nil }
        return identifier(of: account as AnyObject)
    }

    /// Copy records into an account, keeping their unique ids.
    ///
    /// ⚠️ **Raises an Objective-C exception for a contact that has a note** —
    /// `importContact:replaceValues:` calls `importNoteFromContact:`, which
    /// faults the note and hits the entitlement wall, and Core Data throws
    /// rather than returning. The caller guards this with
    /// `AppleToolsRunCatchingExceptions`; `Move` also refuses up front when the
    /// contact has a note, so the guard is the backstop rather than the plan.
    static func importPeople(
        _ book: ABAddressBook, _ people: [ABRecord], into account: AnyObject
    ) -> Int {
        guard let implementation = imp(bookClass, importSelector) else { return 0 }
        let result = unsafeBitCast(implementation, to: ImportFn.self)(
            book, importSelector, people as NSArray, account, false)
        return (result as? NSArray)?.count ?? 0
    }

    static func record(
        _ book: ABAddressBook, uniqueId: String, in account: AnyObject
    ) -> ABRecord? {
        guard let implementation = imp(bookClass, recordInAccountSelector) else { return nil }
        return unsafeBitCast(implementation, to: RecordFn.self)(
            book, recordInAccountSelector, uniqueId as NSString, account) as? ABRecord
    }

    static func remove(_ book: ABAddressBook, _ record: ABRecord) throws {
        guard let implementation = imp(bookClass, removeSelector) else {
            throw RuntimeError("the AddressBook store cannot remove records on this macOS.")
        }
        var failure: Unmanaged<NSError>?
        let ok = unsafeBitCast(implementation, to: RemoveFn.self)(
            book, removeSelector, record, &failure)
        guard ok else {
            let detail = failure?.takeUnretainedValue().localizedDescription ?? "no error reported"
            throw RuntimeError("the AddressBook store refused the removal: \(detail)")
        }
    }

    /// Save, retrying once.
    ///
    /// ⚠️ The retry is not superstition: a record that carries a note fails its
    /// **first** save and succeeds on the second, because faulting trips the
    /// note wall once and the pending changes commit afterwards. Measured, and
    /// already relied on by `editViaAddressBook` and the group fallbacks.
    static func save(_ book: ABAddressBook) -> Bool {
        book.save() || book.save()
    }
}

// MARK: - Reporting

struct MoveResult: Encodable {
    let contactId: String
    let name: String
    let from: String
    let to: String
    let moved: Bool
    let changed: Bool
    /// Groups the contact was in beforehand and is no longer in. A group belongs
    /// to one account, so a move always empties the contact out of every group
    /// in the account it left — reported rather than discovered later.
    let groupsLeft: [String]
    let dryRun: Bool

    enum CodingKeys: String, CodingKey {
        case contactId = "contact_id"
        case name, from, to, moved, changed
        case groupsLeft = "groups_left"
        case dryRun = "dry_run"
    }
}

// MARK: - The command

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a contact to a different account, keeping its id",
        discussion: """
          A contact can only join a group in its own account, so a contact filed
          in the wrong one is a dead end for `groups add`. This is the fix.

          The identifier is preserved, so anything holding it keeps working.
          What does not survive is group membership: a group belongs to one
          account, so the contact leaves every group in the account it came
          from. The groups it will leave are listed before the move, and
          --dry-run shows the whole plan without writing anything.

          ⚠️ A contact that carries a note cannot be moved. Copying the record
          copies the note, reading the note needs an entitlement no
          command-line tool can hold, and Core Data raises rather than returns
          there. Move those in Contacts.app.

          Examples:
            apple-contacts move <id> --to "🌈" --dry-run
            apple-contacts move <id> --to "On My Mac"
            apple-contacts containers            # the names --to accepts
          """)

    @Argument(help: "Contact id, from `search --json`")
    var id: String

    @Option(name: [.long, .customLong("container")],
            help: "Destination account, by name or id, from `containers`")
    var to: String

    @Flag(name: .long, help: "Show what would happen without writing anything")
    var dryRun = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()

        // The container-backed record, never the unified merge: AddressBook has
        // no record under a unified identifier, and `add` can hand one back.
        let contact = try containerContact(withId: id)
        let backingId = contact.identifier
        let name = displayName(contact)

        guard let sourceContainer = containerId(forContact: backingId) else {
            throw RuntimeError(
                """
                cannot tell which account '\(name)' is in, and the move has to remove the record \
                from that account by name — doing it by id alone would risk deleting the copy it \
                just created. Nothing was changed.
                """)
        }
        let targetContainer = try resolveContainer(to)

        if sourceContainer == targetContainer {
            let result = MoveResult(
                contactId: backingId, name: name, from: sourceContainer, to: targetContainer,
                moved: true, changed: false, groupsLeft: [], dryRun: dryRun)
            if json {
                printJSON(result)
            } else {
                print("'\(name)' is already in \(describeContainer(targetContainer)). Nothing to do.")
            }
            return
        }

        // 🛑 Refused rather than attempted. `importPeople:` copies the note,
        // copying it faults it, and faulting it needs the entitlement — at
        // which point Core Data throws an uncaught NSException mid-import. The
        // exception guard below would catch it, but a refusal that names the
        // reason is a better answer than a caught crash.
        let notes = NoteStore.allNotes()
        if let note = notes[backingId] ?? notes[bareId(backingId)], !note.isEmpty {
            throw RuntimeError(
                """
                cannot move '\(name)': it carries a note, and moving copies the record, which \
                reads the note. Reading a note needs the \
                com.apple.developer.contacts.notes entitlement, which Apple grants only to \
                signed apps on request and no command-line tool can hold — Core Data raises \
                rather than returns there, so this is refused instead of attempted.
                Move this contact in Contacts.app: drag the card onto \
                \(describeContainer(targetContainer)) in the sidebar.
                """)
        }

        guard AccountAPI.isAvailable else {
            throw RuntimeError(AccountAPI.unavailableMessage)
        }

        // Group membership is the one thing a move genuinely costs, so it is
        // computed and shown *before* the write rather than reported as a
        // surprise afterwards.
        let groups = groupNames(for: backingId)

        if dryRun {
            let result = MoveResult(
                contactId: backingId, name: name, from: sourceContainer, to: targetContainer,
                moved: false, changed: false, groupsLeft: groups, dryRun: true)
            if json {
                printJSON(result)
            } else {
                print("Would move '\(name)'")
                print("  from \(describeContainer(sourceContainer))")
                print("  to   \(describeContainer(targetContainer))")
                print("  id \(backingId) is kept")
                if groups.isEmpty {
                    print("  no group membership to lose")
                } else {
                    print(
                        Style.warning(
                            "  leaves \(groups.count) group(s): \(groups.joined(separator: ", "))"))
                }
                print("Nothing was changed. Re-run without --dry-run to do it.")
            }
            return
        }

        try performMove(
            backingId: backingId, name: name,
            from: sourceContainer, to: targetContainer)

        // 🛑 Confirmed against a fresh store, not trusted. The first thing tried
        // here — `ABRecord.nts_MoveIntoAddressBook:account:error:` — returned
        // YES, saved YES, and left the record exactly where it was. Every
        // private call in this file is capable of the same, so the answer comes
        // from re-reading the store.
        let landedIn = containerId(forContact: backingId)
        guard landedIn == targetContainer else {
            throw RuntimeError(
                """
                the move reported success but '\(name)' is in \(describeContainer(landedIn)), \
                not \(describeContainer(targetContainer)). Check the contact in Contacts.app \
                before trusting anything else this command reported.
                """)
        }

        let result = MoveResult(
            contactId: backingId, name: name, from: sourceContainer, to: targetContainer,
            moved: true, changed: true, groupsLeft: groups, dryRun: false)
        if json {
            printJSON(result)
        } else {
            print("Moved '\(name)' to \(describeContainer(targetContainer))")
            print("  id \(backingId) unchanged")
            if !groups.isEmpty {
                print(
                    Style.warning(
                        "  left \(groups.count) group(s): \(groups.joined(separator: ", "))"))
                print("  a group belongs to one account; re-add in the new account if needed")
            }
        }
    }

    /// Import into the target account, then remove the source copy.
    ///
    /// The two halves are separate saves on purpose. Between them the contact
    /// exists **twice, under one id**, so the removal is resolved by account and
    /// the record's own account is checked again before it is deleted. If the
    /// removal fails the import is rolled back, because a duplicate that looks
    /// like a successful move is the worst outcome available here.
    private func performMove(
        backingId: String, name: String, from sourceContainer: String, to targetContainer: String
    ) throws {
        guard let book = ABAddressBook.shared() else {
            throw RuntimeError("could not open the AddressBook store.")
        }
        guard let sourceAccount = AccountAPI.account(book, forContainer: sourceContainer),
            let targetAccount = AccountAPI.account(book, forContainer: targetContainer)
        else {
            throw RuntimeError(
                "the AddressBook store does not know an account matching "
                + "\(describeContainer(sourceContainer)) or "
                + "\(describeContainer(targetContainer)).")
        }
        guard let original = book.record(forUniqueId: backingId) else {
            throw RuntimeError("no contact with id '\(backingId)' in the AddressBook store.")
        }
        // Belt and braces: the container lookup already said where it lives, and
        // AddressBook is asked to agree before anything is written.
        if let actual = AccountAPI.accountIdentifier(of: original),
            AccountAPI.account(book, forContainer: sourceContainer)
                .flatMap({ $0.perform(NSSelectorFromString("identifier"))?
                    .takeUnretainedValue() as? String }) != actual
        {
            throw RuntimeError(
                "'\(name)' is in AddressBook account '\(actual)', which is not "
                + "\(describeContainer(sourceContainer)). Nothing was changed.")
        }

        var imported = 0
        var thrown: NSError?
        // The note wall raises rather than returns. `Move` refuses a
        // note-bearing contact before reaching here, so this catching it means
        // something unforeseen — but dying mid-import is how a contact ends up
        // existing twice, so it is guarded regardless.
        let completed = AppleToolsRunCatchingExceptions({
            imported = AccountAPI.importPeople(book, [original], into: targetAccount)
        }, &thrown)

        guard completed else {
            throw RuntimeError(
                """
                could not copy '\(name)' into \(describeContainer(targetContainer)): \
                \(describeException(thrown))
                Nothing was changed; the copy is made before anything is removed.
                """)
        }
        guard imported > 0 else {
            throw RuntimeError(
                "the AddressBook store imported no records for '\(name)'. Nothing was changed.")
        }
        guard AccountAPI.save(book) else {
            throw RuntimeError(
                "the AddressBook store refused to save the copy of '\(name)'. "
                + "Nothing was changed.")
        }

        // From here the contact exists in both accounts under one id. Resolve
        // the one to delete **by account**, and check its account again — a
        // lookup that fell back to the new copy would delete the contact
        // outright rather than moving it.
        guard let sourceCopy = AccountAPI.record(book, uniqueId: backingId, in: sourceAccount)
        else {
            throw RuntimeError(
                """
                copied '\(name)' into \(describeContainer(targetContainer)) but could not find \
                the original in \(describeContainer(sourceContainer)) to remove. \
                The contact may now exist twice — check it in Contacts.app.
                """)
        }

        do {
            try AccountAPI.remove(book, sourceCopy)
            guard AccountAPI.save(book) else {
                throw RuntimeError("the AddressBook store refused to save the removal.")
            }
        } catch {
            try rollBack(book, backingId: backingId, name: name, account: targetAccount,
                         targetContainer: targetContainer, cause: error)
        }
    }

    /// Undo the import after a failed removal, so a half-move does not present
    /// as a success with a duplicate behind it.
    ///
    /// The same account-scoped resolution as the forward path: the copy to
    /// delete is the one in the *target* account, and if it cannot be named
    /// precisely nothing is deleted and the duplicate is reported instead.
    /// Losing both copies would be far worse than leaving two.
    private func rollBack(
        _ book: ABAddressBook, backingId: String, name: String, account: AnyObject,
        targetContainer: String, cause: Error
    ) throws {
        guard let copy = AccountAPI.record(book, uniqueId: backingId, in: account) else {
            throw RuntimeError(
                """
                could not remove the original of '\(name)': \(cause.localizedDescription)
                The copy in \(describeContainer(targetContainer)) could not be found to undo \
                either, so check this contact in Contacts.app — it may exist twice.
                """)
        }
        do {
            try AccountAPI.remove(book, copy)
            guard AccountAPI.save(book) else {
                throw RuntimeError("the store refused to save the rollback.")
            }
        } catch {
            throw RuntimeError(
                """
                could not remove the original of '\(name)': \(cause.localizedDescription)
                Undoing the copy failed too: \(error.localizedDescription)
                '\(name)' now exists in both accounts under the same id — delete one in \
                Contacts.app.
                """)
        }
        throw RuntimeError(
            """
            could not remove the original of '\(name)': \(cause.localizedDescription)
            The copy was undone, so the contact is still in its original account and nothing \
            was lost.
            """)
    }
}

/// `UUID:ABPerson` → `UUID`, which is the other spelling `NoteStore` keys by.
private func bareId(_ identifier: String) -> String {
    String(identifier.split(separator: ":").first ?? Substring(identifier))
}

/// A caught `NSException`, named as precisely as it can be.
///
/// The note wall is worth calling out by name if it ever reaches here, because
/// the raw text is `NSInternalInconsistencyException` wrapping a bare Core Data
/// code and explains nothing on its own.
private func describeException(_ error: NSError?) -> String {
    guard let error else { return "an Objective-C exception was raised" }
    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    let hitTheNoteWall =
        underlying?.code == notePropertyFaultCode
        || error.localizedDescription.contains("\(notePropertyFaultCode)")
    if hitTheNoteWall {
        return """
            the record carries a note, and copying it reads the note, which needs the \
            com.apple.developer.contacts.notes entitlement no command-line tool can hold. \
            Move this contact in Contacts.app.
            """
    }
    let name = error.userInfo[AppleToolsObjCExceptionNameKey] as? String ?? "exception"
    return "\(name): \(error.localizedDescription)"
}
