import AddressBook  // deprecated, but the only thing that removes iCloud group members
import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import Contacts
import Foundation
import TCCResponsibility

private let store = CNContactStore()
private let settingsPath = "System Settings → Privacy & Security → Contacts"

// MARK: - Access

/// Takes ownership of this process's TCC identity, unless Contacts already
/// works.
///
/// Without this, macOS attributes the request to whichever terminal launched
/// us, so the grant lands on Terminal.app or Ghostty and the tool is denied
/// under any terminal that has not itself been granted — with no dialog and no
/// entry in System Settings to fix. Re-executing disclaimed keys the grant to
/// this binary instead, so it works from every terminal.
///
/// Skipped when access already works, which keeps an existing terminal-keyed
/// grant functioning untouched and costs nothing at startup. Does not return
/// when it re-executes.
func claimOwnTCCIdentity() {
    TCCResponsibility.claimOwnIdentity(
        unless: CNContactStore.authorizationStatus(for: .contacts) == .authorized)
}

/// Prompts for (or confirms) Contacts access. Called inside each command so
/// `--help` works without a grant.
func requireContactsAccess() throws {
    claimOwnTCCIdentity()

    // macOS only shows a dialog while the status is notDetermined; once it is
    // anything else the request returns silently, so report the real state
    // instead of asking for a grant that will never be offered.
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized:
        return
    case .denied:
        throw ValidationError(
            "contacts access was denied. macOS will not prompt again — re-enable it in:\n"
            + settingsPath)
    case .restricted:
        throw ValidationError(
            "contacts access is restricted by a device policy or parental controls.")
    case .notDetermined:
        break
    @unknown default:
        break
    }

    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var failure: Error?
    store.requestAccess(for: .contacts) { ok, error in
        granted = ok
        failure = error
        semaphore.signal()
    }
    semaphore.wait()

    guard granted else {
        let detail = failure.map { ": \($0.localizedDescription)" } ?? ""
        throw ValidationError("contacts access was not granted\(detail)\nGrant it in \(settingsPath).")
    }
}

// MARK: - Keys

/// Everything the tool reads. CNContactNoteKey is deliberately absent — it
/// needs an Apple-granted entitlement, and requesting it makes the whole fetch
/// throw. Notes come from NoteStore instead.
private let readKeys: [CNKeyDescriptor] = [
    CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey,
    CNContactFamilyNameKey, CNContactNamePrefixKey, CNContactNameSuffixKey,
    CNContactNicknameKey, CNContactOrganizationNameKey, CNContactDepartmentNameKey,
    CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
    CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactBirthdayKey,
    CNContactDatesKey, CNContactRelationsKey,
] as [CNKeyDescriptor]

// MARK: - Output

struct EmailInfo: Encodable { let label: String?; let address: String }
struct PhoneInfo: Encodable { let label: String?; let number: String }

struct AddressInfo: Encodable {
    let label: String?
    let street: String?
    let city: String?
    let state: String?
    let zip: String?
    let country: String?
}

struct UrlInfo: Encodable { let label: String?; let url: String }
struct RelationInfo: Encodable { let label: String?; let name: String }
struct DateInfo: Encodable { let label: String?; let date: String }

/// Key names match the previous Python implementation so existing callers,
/// docs and skills keep working.
struct ContactInfo: Encodable {
    let id: String
    let name: String
    let first_name: String?
    let middle_name: String?
    let last_name: String?
    let prefix: String?
    let suffix: String?
    let nickname: String?
    let company: String?
    let department: String?
    let job_title: String?
    let birthday: String?
    let emails: [EmailInfo]?
    let phones: [PhoneInfo]?
    let addresses: [AddressInfo]?
    let urls: [UrlInfo]?
    let relations: [RelationInfo]?
    let dates: [DateInfo]?
    let groups: [String]?
    let note: String?
    let contact_url: String?
    /// Which account this contact lives in. Only `get` fills this in: finding it
    /// means scanning each container, which is fine for one contact and far too
    /// slow for `list`. It matters because group membership cannot cross accounts.
    let container: String?
}

private func blankToNil(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return value
}

private func info(
    _ contact: CNContact, notes: [String: String], groups: [String] = [],
    container: String? = nil
) -> ContactInfo {
    let emails = contact.emailAddresses.map {
        EmailInfo(label: Labels.decode($0.label), address: $0.value as String)
    }
    let phones = contact.phoneNumbers.map {
        PhoneInfo(label: Labels.decode($0.label), number: $0.value.stringValue)
    }
    let addresses = contact.postalAddresses.map { entry -> AddressInfo in
        let value = entry.value
        return AddressInfo(
            label: Labels.decode(entry.label),
            street: blankToNil(value.street),
            city: blankToNil(value.city),
            state: blankToNil(value.state),
            zip: blankToNil(value.postalCode),
            country: blankToNil(value.country))
    }
    let urls = contact.urlAddresses.map {
        UrlInfo(label: Labels.decode($0.label), url: $0.value as String)
    }
    let relations = contact.contactRelations.map {
        RelationInfo(label: Labels.decode($0.label), name: $0.value.name)
    }
    let dates = contact.dates.compactMap { entry -> DateInfo? in
        guard let formatted = ContactDate.format(entry.value as DateComponents) else { return nil }
        return DateInfo(label: Labels.decode(entry.label), date: formatted)
    }

    // Fall back through the fields that can stand in for a display name, the
    // same order the Python tool used.
    var name = [contact.givenName, contact.familyName]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    if name.isEmpty { name = contact.organizationName }
    if name.isEmpty { name = contact.nickname }
    if name.isEmpty, let first = emails.first { name = first.address }
    if name.isEmpty, let first = phones.first { name = first.number }
    if name.isEmpty { name = "<unnamed>" }

    let birthday = ContactDate.format(contact.birthday)

    return ContactInfo(
        id: contact.identifier,
        name: name,
        first_name: blankToNil(contact.givenName),
        middle_name: blankToNil(contact.middleName),
        last_name: blankToNil(contact.familyName),
        prefix: blankToNil(contact.namePrefix),
        suffix: blankToNil(contact.nameSuffix),
        nickname: blankToNil(contact.nickname),
        company: blankToNil(contact.organizationName),
        department: blankToNil(contact.departmentName),
        job_title: blankToNil(contact.jobTitle),
        birthday: birthday,
        emails: emails.isEmpty ? nil : emails,
        phones: phones.isEmpty ? nil : phones,
        addresses: addresses.isEmpty ? nil : addresses,
        urls: urls.isEmpty ? nil : urls,
        relations: relations.isEmpty ? nil : relations,
        dates: dates.isEmpty ? nil : dates,
        groups: groups.isEmpty ? nil : groups,
        note: notes[contact.identifier],
        contact_url: "addressbook://\(contact.identifier)",
        container: container)
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let string = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("error: failed to encode JSON\n".utf8))
        exit(1)
    }
    print(string)
}

private func plain(_ contacts: [ContactInfo]) -> String {
    var lines: [String] = []
    for contact in contacts {
        var header = Style.title(contact.name)
        if let company = contact.company, company != contact.name {
            header += Style.dim(" (\(company))")
        }
        lines.append(header)
        for email in contact.emails ?? [] {
            lines.append("  " + Style.label("email") + "  \(email.address)"
                + (email.label.map { Style.dim("  [\($0)]") } ?? ""))
        }
        for phone in contact.phones ?? [] {
            lines.append("  " + Style.label("phone") + "  \(phone.number)"
                + (phone.label.map { Style.dim("  [\($0)]") } ?? ""))
        }
        for address in contact.addresses ?? [] {
            let parts = [address.street, address.city, address.state, address.zip].compactMap { $0 }
            if !parts.isEmpty {
                lines.append("  " + Style.label("addr") + "   \(parts.joined(separator: ", "))")
            }
        }
        for url in contact.urls ?? [] {
            lines.append("  url    \(url.url)")
        }
        if let birthday = contact.birthday {
            lines.append("  bday   \(birthday)")
        }
        for date in contact.dates ?? [] {
            lines.append("  date   \(date.date)" + (date.label.map { "  [\($0)]" } ?? ""))
        }
        for relation in contact.relations ?? [] {
            lines.append("  rel    \(relation.name)" + (relation.label.map { "  [\($0)]" } ?? ""))
        }
        if let groups = contact.groups, !groups.isEmpty {
            lines.append("  groups \(groups.joined(separator: ", "))")
        }
        if let note = contact.note {
            lines.append("  note   \(note.replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("")
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
}

// MARK: - Fetching

private func allContacts() throws -> [CNContact] {
    var results: [CNContact] = []
    let request = CNContactFetchRequest(keysToFetch: readKeys)
    request.sortOrder = .familyName
    try store.enumerateContacts(with: request) { contact, _ in
        results.append(contact)
    }
    return results
}

private func contact(withId id: String) throws -> CNContact {
    do {
        return try store.unifiedContact(withIdentifier: id, keysToFetch: readKeys)
    } catch {
        throw ValidationError("no contact with id '\(id)'")
    }
}

/// The contact as its container actually stores it, rather than the unified merge.
///
/// 🛑 **Group membership must not be given a unified contact.** `unifiedContact`
/// returns a synthetic merge of every linked record, and `CNSaveRequest`'s
/// `addMember` needs a contact backed by a real container record — hand it the
/// merge and the save fails with nothing but
/// `"Save operation could not be completed."`.
///
/// This is why the failure looked intermittent and unrelated to the group. A
/// freshly created contact is usually unlinked, so its unified form is
/// indistinguishable from its backing record and the add works. Once macOS links
/// it to another record, the unified contact's `identifier` can be some *other*
/// linked record's id, and the membership save is rejected — permanently, and
/// through delete-and-recreate, because the linking happens again.
///
/// `unifyResults = false` is the whole point: it returns the one record whose
/// identifier was asked for. Falls back to the unified fetch when nothing
/// matches, so a caller is never worse off than before.
private func containerContact(withId id: String) throws -> CNContact {
    let request = CNContactFetchRequest(keysToFetch: readKeys)
    request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
    request.unifyResults = false

    var found: CNContact?
    do {
        try store.enumerateContacts(with: request) { candidate, stop in
            found = candidate
            stop.pointee = true
        }
    } catch {
        // Enumeration itself failed; the unified path still has a chance.
        found = nil
    }
    if let found { return found }
    return try contact(withId: id)
}

// MARK: - Containers

/// Which account a contact or group physically lives in.
///
/// This matters far more than it looks. A `CNSaveRequest` **cannot span two
/// containers**: adding a contact from account A to a group in account B fails
/// with Core Data's `NSPersistentStoreIncompleteSaveError` (134040) and no
/// indication of which stores disagreed. Nothing in the Contacts API surfaces a
/// contact's container, so the mismatch is invisible at the call site — which is
/// why `apple contacts add` followed by `groups add` could fail forever while
/// the same group accepted contacts that happened to already live in it.
struct ContainerInfo: Encodable {
    let id: String
    let name: String
    let type: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isDefault = "default"
    }
}

private func containerTypeName(_ type: CNContainerType) -> String {
    switch type {
    case .local: return "local"
    case .exchange: return "exchange"
    case .cardDAV: return "cardDAV"
    case .unassigned: return "unassigned"
    @unknown default: return "unknown"
    }
}

private func allContainers() -> [CNContainer] {
    (try? store.containers(matching: nil)) ?? []
}

private func containerInfos() -> [ContainerInfo] {
    let defaultId = store.defaultContainerIdentifier()
    return allContainers().map {
        ContainerInfo(
            id: $0.identifier,
            // A local container's name is empty; "On My Mac" is what Contacts.app
            // shows, and a blank column would read as a bug.
            name: $0.name.isEmpty ? "On My Mac" : $0.name,
            type: containerTypeName($0.type),
            isDefault: $0.identifier == defaultId)
    }
}

/// The container a contact lives in, or nil if it cannot be determined.
///
/// Matches on both the identifier given and the container-backed record it
/// resolves to. A unified identifier appears in no container's own enumeration —
/// only its backing records do — so comparing the caller's id alone reported
/// `container: null` for exactly the linked contacts that need it most.
private func containerId(forContact id: String) -> String? {
    var wanted: Set<String> = [id]
    if let backing = try? containerContact(withId: id) {
        wanted.insert(backing.identifier)
    }

    return allContainers().first { container in
        let predicate = CNContact.predicateForContactsInContainer(
            withIdentifier: container.identifier)
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        request.predicate = predicate
        request.unifyResults = false
        var hit = false
        try? store.enumerateContacts(with: request) { candidate, stop in
            if wanted.contains(candidate.identifier) {
                hit = true
                stop.pointee = true
            }
        }
        return hit
    }?.identifier
}

/// The container a group lives in, or nil if it cannot be determined.
private func containerId(forGroup id: String) -> String? {
    allContainers().first { container in
        let groups = (try? store.groups(
            matching: CNGroup.predicateForGroupsInContainer(
                withIdentifier: container.identifier))) ?? []
        return groups.contains { $0.identifier == id }
    }?.identifier
}

/// Turn a `--container` value into a real container identifier.
///
/// Accepts an identifier or a name, case-insensitively, so `--container "On My
/// Mac"` works as well as `_local:ABAccount`.
///
/// ⚠️ An unrecognised value used to be **silently ignored**: `CNSaveRequest`'s
/// `add(_:toContainerWithIdentifier:)` treats an unknown identifier as nil and
/// files the record in the default container instead, with no error. So
/// `--container "___probe___"` reported success and put the contact somewhere
/// else entirely — which is exactly the kind of quiet wrong answer that makes a
/// later cross-container failure impossible to explain.
private func resolveContainer(_ reference: String) throws -> String {
    let containers = containerInfos()
    if let exact = containers.first(where: { $0.id == reference }) { return exact.id }

    let byName = containers.filter { $0.name.lowercased() == reference.lowercased() }
    if byName.count == 1 { return byName[0].id }
    if byName.count > 1 {
        throw ValidationError(
            "several containers are named '\(reference)'; use the id from "
            + "`apple contacts containers --json`")
    }
    throw ValidationError(
        "no container '\(reference)'. Available: "
        + containers.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))
}

/// Human-readable "name (type)" for a container id, for error messages.
private func describeContainer(_ id: String?) -> String {
    guard let id else { return "unknown" }
    guard let match = containerInfos().first(where: { $0.id == id }) else { return id }
    return "\(match.name) (\(match.type))"
}

/// What actually went wrong in a `CNSaveRequest`.
///
/// `CNError`'s `localizedDescription` is the useless
/// `"Save operation could not be completed."` for every failure mode. Everything
/// diagnostic lives in `userInfo` — which key paths were rejected, and any
/// underlying error — so a save failure reports all of it rather than making the
/// next person reverse-engineer it from behaviour.
private func saveFailureDetail(_ error: Error) -> String {
    let nsError = error as NSError
    var parts = ["\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"]

    if let keyPaths = nsError.userInfo[CNErrorUserInfoKeyPathsKey] as? [Any], !keyPaths.isEmpty {
        parts.append("key paths: \(keyPaths.map { "\($0)" }.joined(separator: ", "))")
    }
    if let ids = nsError.userInfo[CNErrorUserInfoAffectedRecordIdentifiersKey] as? [Any],
        !ids.isEmpty
    {
        parts.append("affected ids: \(ids.map { "\($0)" }.joined(separator: ", "))")
    }
    if let validation = nsError.userInfo[CNErrorUserInfoValidationErrorsKey] as? [Error],
        !validation.isEmpty
    {
        parts.append(
            "validation: "
            + validation.map { ($0 as NSError).localizedDescription }.joined(separator: " | "))
    }
    // Core Data's own keys, which is where the useful detail actually is for a
    // save that spans stores: NSPersistentStoreIncompleteSaveError (134040) says
    // "stores/objects that failed will be in userInfo", and none of the CNError
    // keys above are populated for it. Omitting these is why the first version
    // of this printed a domain and code and nothing else.
    if let stores = nsError.userInfo[NSAffectedStoresErrorKey] as? [Any], !stores.isEmpty {
        parts.append("affected stores: \(stores.count)")
    }
    if let objects = nsError.userInfo[NSAffectedObjectsErrorKey] as? [Any], !objects.isEmpty {
        parts.append("affected objects: \(objects.count)")
    }
    if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [NSError], !detailed.isEmpty {
        parts.append(
            "detailed: "
            + detailed.prefix(5)
                .map { "\($0.localizedDescription) (\($0.domain) \($0.code))" }
                .joined(separator: " | "))
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        parts.append(
            "underlying: \(underlying.localizedDescription) "
            + "(\(underlying.domain) \(underlying.code))")
    }
    return parts.joined(separator: "; ")
}

/// A failure that happened while doing the work, not while parsing arguments.
///
/// `ValidationError` makes ArgumentParser print the usage block, which is right
/// for a bad flag and wrong for a save that failed — usage tells the caller
/// nothing about a Core Data error and buries the message. Conforming to
/// `LocalizedError` instead prints just the message and exits non-zero.
struct RuntimeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Whether a contact is currently in a group.
/// Whether a contact is currently in a group.
///
/// Reads through a fresh store: this is used to confirm a write that has just
/// happened, and a reused store would be the obvious thing to blame if the
/// answer were ever stale.
private func isMember(_ contactId: String, of groupId: String) -> Bool {
    memberIdentifiers(of: groupId).contains(contactId)
}

/// Every identifier by which a group's members can legitimately be named.
///
/// 🛑 Unified and container-backed identifiers are **different strings for the
/// same person**, and a membership check that mixes them silently answers "no".
/// This bit for real: `groups add` fetches its contact non-unified (it must —
/// `addMember` rejects a unified contact), so it holds a backing-record id like
/// `D065726A-…:ABPerson`, while a `unifiedContacts` fetch of the same group
/// returns `BD00169D-…`. Comparing across the two made a *successful* add report
/// "the save reported success but X is not in the group" — a false alarm that
/// makes the command unusable for any contact macOS has linked.
///
/// So both spellings go into the set: the unified fetch for unified ids, and a
/// non-unified enumeration for backing ids.
private func memberIdentifiers(of groupId: String) -> Set<String> {
    let predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupId)
    let keys = [CNContactIdentifierKey as CNKeyDescriptor]
    // A fresh store: this confirms a write that has just happened, and a reused
    // one would be the obvious thing to blame if the answer were ever stale.
    let freshStore = CNContactStore()

    var identifiers = Set(
        ((try? freshStore.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? [])
            .map(\.identifier))

    let request = CNContactFetchRequest(keysToFetch: keys)
    request.predicate = predicate
    request.unifyResults = false
    try? freshStore.enumerateContacts(with: request) { contact, _ in
        identifiers.insert(contact.identifier)
    }
    return identifiers
}

/// Remove a contact from a group through the legacy AddressBook framework.
///
/// Only needed for CardDAV-backed groups — see `GroupRemove.run()`. AddressBook
/// predates Contacts, is deprecated, and is still the only thing here that
/// removes a member from an iCloud group. It addresses records by the same
/// `UUID:ABPerson` / `UUID:ABGroup` identifiers Contacts hands out, so no
/// translation is needed, and it needs no permission beyond the Contacts access
/// this process already holds.
///
/// Being deprecated, it may eventually stop working. That is why it is a
/// fallback rather than the primary path, and why the caller confirms the
/// membership afterwards instead of trusting the return values.
private func removeMemberViaAddressBook(contactId: String, groupId: String) throws {
    try membershipViaAddressBook(contactId: contactId, groupId: groupId, what: "removal") {
        $0.removeMember($1)
    }
}

/// Add a contact to a group through the legacy AddressBook framework.
///
/// The counterpart to `removeMemberViaAddressBook`, needed for a different
/// reason: `CNSaveRequest.addMember` faults the contact, and a contact carrying
/// a note cannot be faulted without the notes entitlement — see
/// `notePropertyFaultCode`. So membership in either direction was impossible for
/// the same 8% of contacts that could not be edited.
private func addMemberViaAddressBook(contactId: String, groupId: String) throws {
    try membershipViaAddressBook(contactId: contactId, groupId: groupId, what: "addition") {
        $0.addMember($1)
    }
}

private func membershipViaAddressBook(
    contactId: String, groupId: String, what: String,
    change: (ABGroup, ABPerson) -> Bool
) throws {
    guard let book = ABAddressBook.shared() else {
        throw ValidationError(
            "could not open the AddressBook store to apply the group \(what).")
    }
    guard let group = book.record(forUniqueId: groupId) as? ABGroup else {
        throw ValidationError("no group with id '\(groupId)' in the AddressBook store.")
    }
    guard let person = book.record(forUniqueId: contactId) as? ABPerson else {
        throw ValidationError("no contact with id '\(contactId)' in the AddressBook store.")
    }

    let changed = change(group, person)
    // The note wall costs the first save and no more — see `editViaAddressBook`
    // for the measurement — so one retry is the difference between working and
    // not for a contact that has a note.
    var saved = book.save()
    if !saved { saved = book.save() }
    guard changed, saved else {
        throw ValidationError(
            "the AddressBook store refused the \(what) "
            + "(changed: \(changed), save: \(saved)).")
    }
}

// MARK: - The note entitlement wall

/// Core Data's code for the wall a note puts in front of *every* save.
///
/// 🛑 **A contact that has a note cannot be written through `CNContactStore` at
/// all**, whatever field is being changed. The save faults the whole record,
/// faulting reads the note attribute, and reading that needs
/// `com.apple.developer.contacts.notes` — the entitlement Apple grants only to
/// signed apps on request, which no command-line tool can hold. So an
/// unrelated, unentitled `--company` edit is collateral damage.
///
/// It surfaces as a bare `NSCocoaErrorDomain 134092` with an empty `userInfo`
/// and a raw `CoreData: error: Unhandled error occurred during faulting` on
/// stderr, naming neither the contact nor the note. 52 of 669 contacts here
/// carry one, so this was ~8% of a real address book the tool could not edit.
private let notePropertyFaultCode = 134092

/// Is this the note wall, at any depth?
///
/// AddressBook wraps it in an `ABAddressBookErrorDomain` error of its own, and
/// Contacts reports it directly, so the whole `NSUnderlyingErrorKey` chain has
/// to be walked rather than just the outermost code.
private func isNotePropertyFault(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    while let nsError = current {
        if nsError.domain == NSCocoaErrorDomain, nsError.code == notePropertyFaultCode {
            return true
        }
        current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

/// Apply an edit through the legacy AddressBook framework instead of Contacts.
///
/// The way past `notePropertyFaultCode`. AddressBook writes the same records
/// under the same `UUID:ABPerson` identifiers, needs no permission beyond the
/// Contacts access this process already holds, and — unlike `CNContactStore` —
/// is not blocked from saving a record that has a note, as long as it is not
/// the note itself being written. It is already the fallback that removes
/// members from iCloud groups, so nothing new is being taken on.
///
/// ⚠️ **The first save fails and the second one works.** Faulting the record
/// trips the note wall once; afterwards the fault is settled and the pending
/// changes commit. Measured on a contact whose note was set outside this tool:
/// save 1 → `ABAddressBookErrorDomain 0` wrapping 134092, save 2 → OK, value
/// present in the store. So a single failure here means nothing, which is
/// precisely why the caller re-reads the contact instead of trusting a return
/// value from either framework.
private func editViaAddressBook(id: String, fields: ContactFields) throws {
    guard let book = ABAddressBook.shared() else {
        throw RuntimeError("could not open the AddressBook store.")
    }
    guard let person = book.record(forUniqueId: id) as? ABPerson else {
        throw RuntimeError("no contact with id '\(id)' in the AddressBook store.")
    }
    guard fields.apply(to: person) else {
        throw RuntimeError("the AddressBook store refused one of the values.")
    }

    var lastFailure: Error?
    // Two is all the note fault costs; the third is margin, not a busy-wait.
    for _ in 1...3 {
        do {
            try book.saveAndReturnError()
            return
        } catch {
            lastFailure = error
        }
    }
    throw RuntimeError(
        "the AddressBook store refused the save: "
        + (lastFailure.map(saveFailureDetail) ?? "no error reported"))
}

// MARK: - Confirming a write

/// Read the contact back and check it really holds what was asked for.
///
/// Every bug in this family wrote something *other* than the input and still
/// exited 0 — a URL scheme eaten as a label, a custom label dropped on the
/// floor. For a tool that mutates an address book with no undo, that failure
/// mode is worse than an error, so the record is compared against the request
/// afterwards, the same rule `groups add` and `groups remove` already follow.
///
/// A **subset** check, deliberately: `get` returns the unified contact, which
/// merges every linked card, so a saved record can legitimately carry values
/// this edit never mentioned. What must never happen is one of ours going
/// missing.
private func confirmWritten(_ fields: ContactFields, on saved: CNContact, name: String) throws {
    var missing: [String] = []

    func check(
        _ flag: String,
        wanted: [(label: String?, value: String)],
        stored: [(label: String?, value: String)]
    ) {
        // A unit separator, so a label ending in a colon cannot forge a match.
        let have = Set(stored.map { "\($0.label ?? "")\u{1f}\($0.value)" })
        for want in wanted where !have.contains("\(want.label ?? "")\u{1f}\(want.value)") {
            let label = Labels.decode(want.label).map { "\($0):" } ?? ""
            missing.append("--\(flag) \(label)\(want.value)")
        }
    }

    check(
        "email", wanted: fields.emails,
        stored: saved.emailAddresses.map { ($0.label, $0.value as String) })
    check(
        "url", wanted: fields.urls,
        stored: saved.urlAddresses.map { ($0.label, $0.value as String) })
    check(
        "relation", wanted: fields.relations,
        stored: saved.contactRelations.map { ($0.label, $0.value.name) })
    check(
        "date",
        wanted: fields.dates.map { ($0.label, ContactDate.format($0.value) ?? "") },
        stored: saved.dates.map { ($0.label, ContactDate.format($0.value as DateComponents) ?? "") })
    // Digits, not punctuation. How a number is formatted is the store's
    // business — `search` already compares them this way — and this check exists
    // to catch a value that went missing, not one that was tidied.
    func digits(_ value: String) -> String { value.filter(\.isNumber) }
    check(
        "phone", wanted: fields.phones.map { ($0.label, digits($0.value)) },
        stored: saved.phoneNumbers.map { ($0.label, digits($0.value.stringValue)) })

    guard missing.isEmpty else {
        throw RuntimeError(
            """
            the save reported success but '\(name)' does not hold what was asked for. \
            Missing:
            \(missing.map { "  \($0)" }.joined(separator: "\n"))
            Check the contact before trusting anything else this command reported.
            """)
    }
}

/// Matches names, company, nickname, emails and phone numbers — the same
/// surface the SQLite implementation searched.
private func matches(_ contact: CNContact, _ needle: String) -> Bool {
    let haystacks = [
        contact.givenName, contact.middleName, contact.familyName, contact.nickname,
        contact.organizationName, contact.departmentName, contact.jobTitle,
        "\(contact.givenName) \(contact.familyName)",
    ]
    if haystacks.contains(where: { $0.lowercased().contains(needle) }) { return true }
    if contact.emailAddresses.contains(where: { ($0.value as String).lowercased().contains(needle) }) {
        return true
    }
    // Compare digits so "7203783797" finds "+1 (720) 378-3797".
    let digits = needle.filter(\.isNumber)
    if !digits.isEmpty,
       contact.phoneNumbers.contains(where: { $0.value.stringValue.filter(\.isNumber).contains(digits) }) {
        return true
    }
    return false
}

// MARK: - Shared output options

struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Output as JSON (the default)")
    var json = false

    @Flag(name: .long, help: "Output as human-readable text")
    var plain = false

    func emit(_ contacts: [ContactInfo]) {
        if self.plain {
            print(contacts.isEmpty ? "No contacts found" : AppleContacts.plainText(contacts))
        } else {
            printJSON(contacts)
        }
    }

    /// Emit a single contact as a JSON *object*.
    ///
    /// `search` and `list` return arrays; `add` and `edit` return one object.
    /// `get` used to return an array of one, so anything consuming this tool
    /// had to handle both shapes for what is obviously a single record.
    func emitOne(_ contact: ContactInfo) {
        if self.plain {
            print(AppleContacts.plainText([contact]))
        } else {
            printJSON(contact)
        }
    }
}

// MARK: - Commands

struct AppleContacts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-contacts",
        abstract: "Read and write macOS Contacts",
        discussion: """
          Examples:
            apple-contacts status                          # permission state
            apple-contacts search "smith"                  # JSON by default
            apple-contacts search "smith" --plain
            apple-contacts add --first Ada --last Lovelace --email "work:ada@x.com"
            apple-contacts edit <id> --relation "daughter:Margot Hopkins"
            apple-contacts edit <id> --birthday 1980-04-12 --date "death:2020-05-01"
            apple-contacts groups                          # groups + counts
            apple-contacts groups add "Family" <contact-id>
            apple-contacts export <id> -o card.vcf         # vCard
            apple-contacts export --group "Family" -o family.vcf
          """,
        version: appleToolsVersion,
        subcommands: [Search.self, Get.self, List.self, Add.self, Edit.self, Delete.self,
                      Export.self, Groups.self, Containers.self, Status.self],
        defaultSubcommand: Search.self)

    static func plainText(_ contacts: [ContactInfo]) -> String { plain(contacts) }
}

struct Containers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "containers",
        abstract: "List the accounts contacts and groups can live in",
        discussion: """
          A container is an account: iCloud, an Exchange account, or the local
          "On My Mac" store. Which one a contact is in matters because a single
          save cannot span two of them — adding a contact to a group in a
          different container fails, so `groups add` reports the mismatch by name.

          The `default` container is where `add` puts a new contact when no
          --container is given.
          """)

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let containers = containerInfos()

        if json {
            printJSON(containers)
            return
        }
        guard !containers.isEmpty else {
            print("No containers found.")
            return
        }
        for container in containers {
            let marker = container.isDefault ? Style.success(" (default)") : ""
            print("\(Style.title(container.name))\(marker)")
            print("    \(Style.dim(container.type))  \(Style.identifier(container.id))")
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report Contacts permission state without requesting it")

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() {
        // Re-exec too, so this reports the identity the other commands actually
        // use. Disclaiming never prompts on its own.
        claimOwnTCCIdentity()

        let status = CNContactStore.authorizationStatus(for: .contacts)
        let (name, usable, advice): (String, Bool, String?) = {
            switch status {
            case .authorized:    return ("authorized", true, nil)
            case .denied:        return ("denied", false, "Re-enable in \(settingsPath).")
            case .restricted:    return ("restricted", false, "Blocked by device policy.")
            case .notDetermined: return ("notDetermined", false,
                "Run any command from a terminal to trigger the permission prompt.")
            @unknown default:    return ("unknown", false, nil)
            }
        }()

        if json {
            var payload: [String: Any] = ["status": name, "usable": usable]
            if let advice { payload["advice"] = advice }
            let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        } else {
            print("Contacts access: \(name)\(usable ? "" : "  (cannot read contacts)")")
            if let advice { print(advice) }
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search by name, company, email, or phone")

    @Argument(help: "Search term (substring match)")
    var term: String

    @Option(name: .long, help: "Max results")
    var limit: Int = 25

    @OptionGroup var output: OutputOptions

    func run() throws {
        try requireContactsAccess()
        let needle = term.lowercased()
        let notes = NoteStore.allNotes()
        let found = try allContacts()
            .filter { matches($0, needle) }
            .prefix(limit)
            .map { info($0, notes: notes) }
        output.emit(Array(found))
    }
}

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch one contact by id")

    @Argument(help: "Contact id, from `search --json`")
    var id: String

    @OptionGroup var output: OutputOptions

    func run() throws {
        try requireContactsAccess()
        let match = try contact(withId: id)
        output.emitOne(
            info(
                match, notes: NoteStore.allNotes(), groups: groupNames(for: id),
                container: containerId(forContact: match.identifier)))
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List all contacts")

    @Option(name: .long, help: "Max results")
    var limit: Int = 100

    @OptionGroup var output: OutputOptions

    func run() throws {
        try requireContactsAccess()
        let notes = NoteStore.allNotes()
        let found = try allContacts().prefix(limit).map { info($0, notes: notes) }
        output.emit(Array(found))
    }
}

// MARK: - Writes

/// Fields shared by `add` and `edit`. On `edit`, only the flags actually passed
/// are applied; multi-value flags replace the whole set for that field.
struct ContactFields: ParsableArguments {
    @Option(name: .long, help: "First name")
    var first: String?

    @Option(name: .long, help: "Middle name")
    var middle: String?

    @Option(name: .long, help: "Last name")
    var last: String?

    @Option(name: .long, help: "Name prefix (Dr, Ms, ...)")
    var namePrefix: String?

    @Option(name: .long, help: "Name suffix (Jr, PhD, ...)")
    var nameSuffix: String?

    @Option(name: .long, help: "Nickname")
    var nickname: String?

    @Option(name: .long, help: "Company / organization")
    var company: String?

    @Option(name: .long, help: "Department")
    var department: String?

    @Option(name: .long, help: "Job title")
    var jobTitle: String?

    @Option(name: .long, help: "Birthday as YYYY-MM-DD, or --MM-DD for no year")
    var birthday: String?

    @Option(
        name: .long,
        help: "Email, optionally labelled: 'work:a@b.com'. Repeat to set several; replaces existing.")
    var email: [String] = []

    @Option(
        name: .long,
        help: "Phone, optionally labelled: 'mobile:+15551234567'. Repeat to set several; replaces existing.")
    var phone: [String] = []

    @Option(
        name: .long,
        help: "URL, optionally labelled: 'work:https://example.com'. Repeat to set several; replaces existing.")
    var url: [String] = []

    @Option(
        name: .long,
        help: "Relation as LABEL:NAME, e.g. 'father:Robert Hopkins'. Repeat to set several; replaces existing.")
    var relation: [String] = []

    @Option(name: .long, help: "Anniversary as YYYY-MM-DD or --MM-DD (shorthand for --date anniversary:...)")
    var anniversary: String?

    @Option(
        name: .long,
        help: "Dated event as LABEL:DATE, e.g. 'death:2020-05-01'. Repeat to set several; replaces existing.")
    var date: [String] = []

    @Option(name: .long, help: "Not supported — see the error text for why")
    var note: String?

    var isEmpty: Bool {
        first == nil && middle == nil && last == nil && namePrefix == nil
            && nameSuffix == nil && nickname == nil && company == nil
            && department == nil && jobTitle == nil && birthday == nil
            && anniversary == nil && email.isEmpty && phone.isEmpty
            && url.isEmpty && relation.isEmpty && date.isEmpty
    }

    /// Splits "father:Robert Hopkins" on the FIRST colon only, so values that
    /// contain colons (URLs, times) survive intact.
    ///
    /// 🛑 **The first colon is not always a label separator.** A bare
    /// `https://example.com` has one too, and cutting there stored
    /// `//example.com` under a label of `https` — which then failed label
    /// lookup, was dropped, and left a mangled URL written with a zero exit
    /// code. `--url` is documented as *optionally* labelled, so a bare URL is a
    /// supported input and has to survive.
    ///
    /// So a prefix that parses as a URI scheme is treated as part of the value:
    /// either because what follows starts with `//` (`https:`, `ftp:`), or
    /// because it is one of the schemes that never does (`mailto:`, `tel:`).
    /// The cost is that those words cannot be used as labels, which is a trade
    /// nobody will notice.
    private func split(_ input: String) -> (label: String?, value: String) {
        guard let separator = input.firstIndex(of: ":") else { return (nil, input) }
        let label = String(input[input.startIndex..<separator])
        let value = String(input[input.index(after: separator)...])
        let looksLikeScheme = Self.isURIScheme(label)
            && (value.hasPrefix("//") || Self.schemesWithoutSlashes.contains(label.lowercased()))
        if looksLikeScheme { return (nil, input) }
        return (label.isEmpty ? nil : label, value)
    }

    /// Schemes whose value does not begin `//`, so the `//` test alone cannot
    /// recognise them. Kept deliberately short: every entry is a word that can
    /// no longer be used as a label.
    private static let schemesWithoutSlashes: Set<String> = [
        "mailto", "tel", "sms", "callto", "facetime", "facetime-audio", "skype", "xmpp",
    ]

    /// RFC 3986 §3.1: `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`.
    private static func isURIScheme(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }

    func validate() throws {
        if note != nil {
            throw ValidationError("""
                --note is not supported. Reading a contact note works, but writing one \
                needs the com.apple.developer.contacts.notes entitlement, which Apple \
                grants only to signed apps by request — a command-line tool cannot hold \
                it. Edit the note in Contacts.app.
                """)
        }
        if let birthday, ContactDate.parse(birthday) == nil {
            throw ValidationError("could not parse --birthday '\(birthday)'; use YYYY-MM-DD or --MM-DD")
        }
        if let anniversary, ContactDate.parse(anniversary) == nil {
            throw ValidationError(
                "could not parse --anniversary '\(anniversary)'; use YYYY-MM-DD or --MM-DD")
        }
        for entry in date {
            let (label, value) = split(entry)
            guard label != nil else {
                throw ValidationError("--date needs a label, e.g. --date death:2020-05-01")
            }
            guard ContactDate.parse(value) != nil else {
                throw ValidationError("could not parse date '\(value)' in --date \(entry); use YYYY-MM-DD or --MM-DD")
            }
        }
        for entry in relation {
            let (label, value) = split(entry)
            guard let label else {
                throw ValidationError("--relation needs a label, e.g. --relation father:\"Robert Hopkins\"")
            }
            guard !value.isEmpty else {
                throw ValidationError("--relation \(entry) has no name after the colon")
            }
            // Unknown labels are still allowed — Contacts supports custom ones —
            // but a typo like "fathr" is much more likely, so say something.
            if !Labels.isKnownRelation(label) {
                let hint = Labels.nearestRelations(to: label)
                let suffix = hint.isEmpty ? "" : " Did you mean: \(hint.joined(separator: ", "))?"
                FileHandle.standardError.write(Data(
                    "note: '\(label)' is not a standard relation, storing it as a custom label.\(suffix)\n".utf8))
            }
        }
    }

    /// Applies the flags that were actually supplied onto a mutable contact.
    func apply(to contact: CNMutableContact) {
        if let first { contact.givenName = first }
        if let middle { contact.middleName = middle }
        if let last { contact.familyName = last }
        if let namePrefix { contact.namePrefix = namePrefix }
        if let nameSuffix { contact.nameSuffix = nameSuffix }
        if let nickname { contact.nickname = nickname }
        if let company { contact.organizationName = company }
        if let department { contact.departmentName = department }
        if let jobTitle { contact.jobTitle = jobTitle }
        if let birthday { contact.birthday = ContactDate.parse(birthday) }

        if !emails.isEmpty {
            contact.emailAddresses = emails.map {
                CNLabeledValue(label: $0.label, value: $0.value as NSString)
            }
        }
        if !phones.isEmpty {
            contact.phoneNumbers = phones.map {
                CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value))
            }
        }
        if !urls.isEmpty {
            contact.urlAddresses = urls.map {
                CNLabeledValue(label: $0.label, value: $0.value as NSString)
            }
        }
        if !relations.isEmpty {
            contact.contactRelations = relations.map {
                CNLabeledValue(label: $0.label, value: CNContactRelation(name: $0.value))
            }
        }
        if !dates.isEmpty {
            contact.dates = dates.map {
                CNLabeledValue(label: $0.label, value: $0.value as NSDateComponents)
            }
        }
    }

    /// The same edit, expressed against the legacy AddressBook record.
    ///
    /// Only reached when `CNContactStore` refuses the save because the contact
    /// carries a note — see `editViaAddressBook`. AddressBook uses the identical
    /// `_$!<Home>!$_` label spellings, so nothing is translated but the property
    /// names and the multi-value wrappers.
    ///
    /// Returns false if AddressBook rejected any of the writes, before the save
    /// is even attempted.
    func apply(to person: ABPerson) -> Bool {
        var ok = true
        func set(_ value: Any?, _ property: String) {
            ok = person.setValue(value, forProperty: property) && ok
        }
        func setMulti(_ entries: [(label: String?, value: Any)], _ property: String) {
            let multi = ABMutableMultiValue()
            for entry in entries {
                // AddressBook has no nil label; the empty string is what it
                // stores for an unlabelled value, and Contacts reads it back
                // as no label at all.
                _ = multi.add(entry.value, withLabel: entry.label ?? "")
            }
            set(multi, property)
        }

        if let first { set(first as NSString, kABFirstNameProperty) }
        if let middle { set(middle as NSString, kABMiddleNameProperty) }
        if let last { set(last as NSString, kABLastNameProperty) }
        if let namePrefix { set(namePrefix as NSString, kABTitleProperty) }
        if let nameSuffix { set(nameSuffix as NSString, kABSuffixProperty) }
        if let nickname { set(nickname as NSString, kABNicknameProperty) }
        if let company { set(company as NSString, kABOrganizationProperty) }
        if let department { set(department as NSString, kABDepartmentProperty) }
        if let jobTitle { set(jobTitle as NSString, kABJobTitleProperty) }
        // The *Components* property, not kABBirthdayProperty: the latter is an
        // NSDate and cannot express the year-less `--MM-DD` birthday Contacts
        // supports and this tool accepts.
        if let birthday, let components = ContactDate.parse(birthday) {
            set(components as NSDateComponents, kABBirthdayComponentsProperty)
        }

        if !emails.isEmpty {
            setMulti(emails.map { ($0.label, $0.value as NSString) }, kABEmailProperty)
        }
        if !phones.isEmpty {
            setMulti(phones.map { ($0.label, $0.value as NSString) }, kABPhoneProperty)
        }
        if !urls.isEmpty {
            setMulti(urls.map { ($0.label, $0.value as NSString) }, kABURLsProperty)
        }
        if !relations.isEmpty {
            setMulti(relations.map { ($0.label, $0.value as NSString) }, kABRelatedNamesProperty)
        }
        if !dates.isEmpty {
            setMulti(
                dates.map { ($0.label, $0.value as NSDateComponents) },
                kABOtherDateComponentsProperty)
        }
        return ok
    }

    // MARK: Parsed inputs

    /// `"work:a@b.com"` → (`_$!<Work>!$_`, `a@b.com`).
    ///
    /// One place turns a flag into the label and value the store will hold, so
    /// the Contacts path, the AddressBook fallback and the post-write check
    /// cannot disagree about what was asked for.
    private func parse(
        _ entries: [String], _ encode: (String) -> String
    ) -> [(label: String?, value: String)] {
        entries.map { raw in
            let (label, value) = split(raw)
            return (label.map(encode), value)
        }
    }

    var emails: [(label: String?, value: String)] { parse(email, Labels.email) }
    var phones: [(label: String?, value: String)] { parse(phone, Labels.phone) }
    var urls: [(label: String?, value: String)] { parse(url, Labels.url) }
    var relations: [(label: String?, value: String)] { parse(relation, Labels.relation) }

    /// `--anniversary` is sugar for a labelled date, so the two inputs merge.
    var dates: [(label: String?, value: DateComponents)] {
        var entries = date
        if let anniversary { entries.append("anniversary:\(anniversary)") }
        // validate() has already rejected anything unparseable, so compactMap
        // drops nothing here.
        return parse(entries, Labels.date).compactMap { entry in
            ContactDate.parse(entry.value).map { (entry.label, $0) }
        }
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a contact",
        discussion: """
          Labels are friendly names: home, work, school, other; phones also take
          mobile, iphone, main, pager. Relations accept any of the 216 labels
          Contacts defines (father, mother, son, daughter, spouse, niece, ...).

          Examples:
            apple-contacts add --first Ada --last Lovelace
            apple-contacts add --first Ada --email "work:ada@x.com" \\
                               --phone "mobile:+15551234567"
            apple-contacts add --first Ada --company "Analytical Engines" \\
                               --birthday 1815-12-10 --relation "daughter:Anne"
          """)

    @OptionGroup var fields: ContactFields

    @Option(name: .long, help: "Container (account) to create in; defaults to the store's default")
    var container: String?

    @Flag(name: .long, help: "Output the created contact as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()

        guard !fields.isEmpty else {
            throw ValidationError("nothing to create; pass at least one field, e.g. --first / --last")
        }

        // Named to avoid shadowing the global contact(withId:) lookup.
        let draft = CNMutableContact()
        fields.apply(to: draft)

        let request = CNSaveRequest()
        // Resolved, not passed through: an unknown identifier is silently
        // treated as nil and the contact lands in the default container.
        let targetContainer = try container.map { try resolveContainer($0) }
        request.add(draft, toContainerWithIdentifier: targetContainer)
        do {
            try store.execute(request)
        } catch {
            // A new contact cannot carry a note, so there is no note wall to
            // fall back around here — only the generic save failure, which is
            // worth naming rather than leaving as CNError's one useless string.
            throw RuntimeError(
                "could not create '\(displayName(draft))': \(saveFailureDetail(error))")
        }

        // Which account it landed in, reported rather than left to be discovered
        // later by a failed `groups add`. A contact can only join groups in its
        // own container, and the default is not always the one you expect — the
        // whole cross-container trap starts with this being invisible.
        let landedIn = targetContainer ?? store.defaultContainerIdentifier()

        // Re-read so both the check and the output reflect what the store
        // actually saved, rather than the draft we hoped it would.
        let saved = try contact(withId: draft.identifier)
        try confirmWritten(fields, on: saved, name: displayName(saved))

        if json {
            printJSON(info(saved, notes: NoteStore.allNotes(), container: landedIn))
        } else {
            print("Created '\(displayName(draft))' (id: \(draft.identifier))")
            print("  in \(describeContainer(landedIn))")
        }
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit an existing contact",
        discussion: """
          Multi-value flags REPLACE rather than append: passing --email drops
          every existing address. Read the contact with `get` first and re-pass
          the ones to keep.

          Examples:
            apple-contacts edit <id> --company "New Co"
            apple-contacts edit <id> --email "work:new@x.com" --email "home:old@y.com"
            apple-contacts edit <id> --relation "father:Robert" --relation "son:Sam"
            apple-contacts edit <id> --anniversary --06-15
          """)

    @Argument(help: "Contact id, from `search --json`")
    var id: String

    @OptionGroup var fields: ContactFields

    @Flag(name: .long, help: "Output the updated contact as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()

        guard !fields.isEmpty else {
            throw ValidationError(
                "nothing to change; pass at least one field, e.g. --company or --email")
        }

        let existing = try contact(withId: id)
        guard let mutable = existing.mutableCopy() as? CNMutableContact else {
            throw ValidationError("could not prepare '\(id)' for editing")
        }
        fields.apply(to: mutable)

        let request = CNSaveRequest()
        request.update(mutable)
        do {
            try store.execute(request)
        } catch where isNotePropertyFault(error) {
            // Nothing here asked for the note; the save faults the whole record
            // and faulting is what reads it. AddressBook writes the same store
            // without hitting the entitlement, so use it rather than telling
            // the caller that 8% of their contacts are simply uneditable.
            //
            // The container-backed id, not whatever was passed: AddressBook has
            // no record under a unified identifier, and `add` can hand one back.
            let backing = (try? containerContact(withId: id))?.identifier ?? id
            do {
                try editViaAddressBook(id: backing, fields: fields)
            } catch {
                throw RuntimeError(
                    """
                    could not update '\(displayName(existing))'. Contacts refuses to save any \
                    change to a contact that carries a note, because the save reads the note and \
                    that needs the com.apple.developer.contacts.notes entitlement, which no \
                    command-line tool can hold. The AddressBook fallback did not work either: \
                    \(error.localizedDescription)
                    Edit this contact in Contacts.app.
                    """)
            }
        } catch {
            throw RuntimeError(
                "could not update '\(displayName(existing))': \(saveFailureDetail(error))")
        }

        let refreshed = try contact(withId: id)
        try confirmWritten(fields, on: refreshed, name: displayName(refreshed))
        if json {
            printJSON(info(refreshed, notes: NoteStore.allNotes()))
        } else {
            print("Updated '\(displayName(refreshed))'")
        }
    }
}

// MARK: - vCard

/// Escape a value for a vCard property, per RFC 6350 §3.4.
private func vCardEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: ",", with: "\\,")
        .replacingOccurrences(of: ";", with: "\\;")
}

/// Fold a vCard content line to 75 octets, continuing with a leading space.
///
/// Folding counts octets, not characters, so this splits on UTF-8 boundaries
/// rather than mid-sequence — an emoji or accented name in a note would
/// otherwise be cut in half and come back as mojibake.
private func vCardFolded(_ line: String) -> String {
    let bytes = Array(line.utf8)
    guard bytes.count > 75 else { return line }

    var lines: [String] = []
    var index = 0
    var limit = 75  // subsequent lines lose one octet to the leading space
    while index < bytes.count {
        var end = min(index + limit, bytes.count)
        // 0b10xxxxxx is a UTF-8 continuation byte; back up off one.
        while end > index, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        let chunk = String(decoding: bytes[index..<end], as: UTF8.self)
        lines.append(lines.isEmpty ? chunk : " " + chunk)
        index = end
        limit = 74
    }
    return lines.joined(separator: "\r\n")
}

/// Serialise contacts to vCard, restoring the note Contacts.framework won't give us.
///
/// `CNContactVCardSerialization` cannot see `CNContactNoteKey` without the
/// entitlement Apple only grants signed apps, so a straight serialisation drops
/// notes silently. They are read from the AddressBook SQLite store instead (the
/// same source `get` uses) and spliced in as a NOTE property, which keeps the
/// export lossless. Contacts are serialised one at a time so each note lands in
/// its own card.
private func vCardData(for contacts: [CNContact]) throws -> Data {
    let notes = NoteStore.allNotes()
    var output = Data()

    for contact in contacts {
        var card = try CNContactVCardSerialization.data(with: [contact])

        if let note = notes[contact.identifier], !note.isEmpty,
           var text = String(data: card, encoding: .utf8) {
            let property = vCardFolded("NOTE:" + vCardEscaped(note))
            // Insert before the card's terminator rather than appending, so the
            // property stays inside BEGIN/END.
            if let terminator = text.range(of: "END:VCARD", options: .backwards) {
                text.replaceSubrange(
                    terminator.lowerBound..<terminator.lowerBound,
                    with: property + "\r\n")
                card = Data(text.utf8)
            }
        }

        output.append(card)
    }
    return output
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export contacts as a vCard (.vcf)",
        discussion: """
          Writes vCard 3.0, the format Contacts.app and every other address book
          imports. Notes are included, which a plain Contacts-framework export
          cannot do — they are read from the AddressBook store directly, so they
          need Full Disk Access; without it everything else still exports.

          Examples:
            apple-contacts export <id>                        # vCard to stdout
            apple-contacts export <id> -o card.vcf            # to a file
            apple-contacts export <id> <id> -o cards.vcf      # several in one file
            apple-contacts export --group "Family" -o fam.vcf # a whole group
          """)

    @Argument(help: "Contact ids, from `search --json`")
    var ids: [String] = []

    @Option(name: .long, help: "Export every member of this group (id or name)")
    var group: String?

    @Option(name: .shortAndLong, help: "Write to this file instead of stdout")
    var output: String?

    func validate() throws {
        guard !ids.isEmpty || group != nil else {
            throw ValidationError("pass at least one contact id, or --group NAME")
        }
    }

    func run() throws {
        try requireContactsAccess()

        // vCard serialisation needs its own key set; the keys the rest of the
        // tool fetches are not enough and the serializer throws without them.
        let keys = [CNContactVCardSerialization.descriptorForRequiredKeys()]

        var contacts: [CNContact] = []
        if let group {
            let target = try resolveGroup(group)
            let predicate = CNContact.predicateForContactsInGroup(
                withIdentifier: target.identifier)
            contacts += (try? store.unifiedContacts(
                matching: predicate, keysToFetch: keys)) ?? []
        }
        for id in ids {
            do {
                contacts.append(try store.unifiedContact(withIdentifier: id, keysToFetch: keys))
            } catch {
                throw ValidationError("no contact with id '\(id)'")
            }
        }

        // A group and explicit ids can name the same person; don't emit twice.
        var seen = Set<String>()
        contacts = contacts.filter { seen.insert($0.identifier).inserted }

        guard !contacts.isEmpty else {
            throw ValidationError("nothing to export")
        }

        let data = try vCardData(for: contacts)

        if let output {
            try data.write(to: URL(fileURLWithPath: output))
            let plural = contacts.count == 1 ? "" : "s"
            FileHandle.standardError.write(Data(
                "Exported \(contacts.count) contact\(plural) to: \(output)\n".utf8))
        } else {
            FileHandle.standardOutput.write(data)
        }
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a contact")

    @Argument(help: "Contact id, from `search --json`")
    var id: String

    func run() throws {
        try requireContactsAccess()

        let existing = try contact(withId: id)
        guard let mutable = existing.mutableCopy() as? CNMutableContact else {
            throw ValidationError("could not prepare '\(id)' for deletion")
        }
        let name = displayName(existing)

        let request = CNSaveRequest()
        request.delete(mutable)
        try store.execute(request)

        print("Deleted '\(name)'")
    }
}

// MARK: - Groups

/// Group names a contact belongs to. Contacts has no reverse lookup, so this
/// asks each group for its members — fine for one contact, avoid it in a loop.
private func groupNames(for contactId: String) -> [String] {
    guard let groups = try? store.groups(matching: nil) else { return [] }
    var names: [String] = []
    for group in groups {
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
        let members = (try? store.unifiedContacts(
            matching: predicate, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
        if members.contains(where: { $0.identifier == contactId }) {
            names.append(group.name)
        }
    }
    return names.sorted()
}

private func group(withId id: String) throws -> CNGroup {
    let matches = (try? store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id]))) ?? []
    guard let found = matches.first else {
        throw ValidationError("no group with id '\(id)'. Run `apple contacts groups` to list them.")
    }
    return found
}

/// Accepts a group identifier or an unambiguous name, since identifiers are
/// unreadable and names are what the user actually sees.
private func resolveGroup(_ reference: String) throws -> CNGroup {
    if let exact = try? group(withId: reference) { return exact }

    let all = (try? store.groups(matching: nil)) ?? []
    let byName = all.filter { $0.name.lowercased() == reference.lowercased() }
    if byName.count == 1 { return byName[0] }
    if byName.count > 1 {
        throw ValidationError(
            "several groups are named '\(reference)'; use the id from `apple contacts groups --json`")
    }
    throw ValidationError(
        "no group named '\(reference)'. Available: "
        + (all.isEmpty ? "(none)" : all.map { $0.name }.joined(separator: ", ")))
}

struct GroupInfo: Encodable {
    let id: String
    let name: String
    let count: Int
    /// Which account the group lives in. A contact can only join a group in its
    /// own account, so this is the other half of diagnosing a failed `groups add`.
    let container: String?
}

/// The result of a membership change, for both `add` and `remove`.
///
/// Two separate facts, because exiting 0 does not mean anything happened:
/// `member` is the membership state *after* the call, confirmed by re-reading;
/// `changed` says whether this invocation is what changed it. Adding someone
/// already in the group, or removing someone who was never in it, is a no-op the
/// framework accepts silently — those come back `changed: false`.
struct GroupMembershipResult: Encodable {
    let group: String
    let contactId: String
    let member: Bool
    let changed: Bool

    enum CodingKeys: String, CodingKey {
        case group
        case contactId = "contact_id"
        case member
        case changed
    }
}

struct Groups: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "List and manage contact groups",
        subcommands: [GroupList.self, GroupCreate.self, GroupRename.self, GroupDelete.self,
                      GroupMembers.self, GroupAdd.self, GroupRemove.self],
        defaultSubcommand: GroupList.self)
}

struct GroupList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List all groups with member counts")

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let groups = (try? store.groups(matching: nil)) ?? []

        // One pass over the containers, not one per group: `containerId(forGroup:)`
        // would re-enumerate every container for every group.
        var containerByGroup: [String: String] = [:]
        for container in allContainers() {
            let inContainer = (try? store.groups(
                matching: CNGroup.predicateForGroupsInContainer(
                    withIdentifier: container.identifier))) ?? []
            for group in inContainer { containerByGroup[group.identifier] = container.identifier }
        }

        let infos = groups.map { group -> GroupInfo in
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
            let members = (try? store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
            return GroupInfo(
                id: group.identifier, name: group.name, count: members.count,
                container: containerByGroup[group.identifier])
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }

        if json {
            printJSON(infos)
        } else if infos.isEmpty {
            print("No groups")
        } else {
            for info in infos {
                print("\(info.name)  (\(info.count))")
            }
        }
    }
}

struct GroupCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Create a group")

    @Argument(help: "Group name")
    var name: String

    @Option(name: .long, help: "Container (account) to create in")
    var container: String?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()

        let group = CNMutableGroup()
        group.name = name

        let request = CNSaveRequest()
        let targetContainer = try container.map { try resolveContainer($0) }
        request.add(group, toContainerWithIdentifier: targetContainer)
        try store.execute(request)

        if json {
            printJSON(
                GroupInfo(
                    id: group.identifier, name: group.name, count: 0,
                    container: containerId(forGroup: group.identifier)))
        } else {
            print("Created group '\(name)' (id: \(group.identifier))")
            print("  in \(describeContainer(targetContainer ?? store.defaultContainerIdentifier()))")
        }
    }
}

struct GroupRename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename", abstract: "Rename a group")

    @Argument(help: "Group id or name")
    var group: String

    @Argument(help: "New name")
    var name: String

    func run() throws {
        try requireContactsAccess()
        let existing = try resolveGroup(group)
        guard let mutable = existing.mutableCopy() as? CNMutableGroup else {
            throw ValidationError("could not prepare group '\(group)' for editing")
        }
        let previous = mutable.name
        mutable.name = name

        let request = CNSaveRequest()
        request.update(mutable)
        try store.execute(request)
        print("Renamed '\(previous)' to '\(name)'")
    }
}

struct GroupDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete", abstract: "Delete a group (its contacts are kept)")

    @Argument(help: "Group id or name")
    var group: String

    func run() throws {
        try requireContactsAccess()
        let existing = try resolveGroup(group)
        guard let mutable = existing.mutableCopy() as? CNMutableGroup else {
            throw ValidationError("could not prepare group '\(group)' for deletion")
        }
        let name = mutable.name

        let request = CNSaveRequest()
        request.delete(mutable)
        try store.execute(request)
        print("Deleted group '\(name)'. Its contacts were not deleted.")
    }
}

struct GroupMembers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "members", abstract: "List the contacts in a group")

    @Argument(help: "Group id or name")
    var group: String

    @OptionGroup var output: OutputOptions

    func run() throws {
        try requireContactsAccess()
        let target = try resolveGroup(group)
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: target.identifier)
        let members = (try? store.unifiedContacts(matching: predicate, keysToFetch: readKeys)) ?? []
        let notes = NoteStore.allNotes()
        output.emit(members.map { info($0, notes: notes) })
    }
}

struct GroupAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add a contact to a group")

    @Argument(help: "Group id or name")
    var group: String

    @Argument(help: "Contact id, from `search --json`")
    var contactId: String

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let target = try resolveGroup(group)
        // The container-backed record, never the unified merge — see
        // `containerContact` for why handing a unified contact to `addMember`
        // fails with a bare "Save operation could not be completed."
        let member = try containerContact(withId: contactId)

        // Adding someone who is already in the group is a no-op the framework
        // accepts silently. Say so rather than reporting an addition that did
        // not happen.
        if isMember(member.identifier, of: target.identifier) {
            if json {
                printJSON(
                    GroupMembershipResult(
                        group: target.name, contactId: member.identifier, member: true,
                        changed: false))
            } else {
                print("'\(displayName(member))' is already in '\(target.name)'. Nothing to do.")
            }
            return
        }

        // 🛑 A CNSaveRequest cannot span two containers. Adding a contact from
        // one account to a group in another fails with Core Data's
        // NSPersistentStoreIncompleteSaveError (134040) — "one or more of the
        // stores returned an error" — which names neither store and is
        // indistinguishable from any other save failure.
        //
        // This is permanent, not a sync race: the contact is simply in the wrong
        // store and no amount of waiting changes that. Nor is it fixable here.
        // There is no move API, and copying into the target container would mint
        // a new identifier and orphan every reference to the old one — too
        // destructive to do behind the caller's back. So the mismatch is detected
        // and named, which is the one thing that turns a dead end into a fix.
        let memberContainer = containerId(forContact: member.identifier)
        let groupContainer = containerId(forGroup: target.identifier)
        if let memberContainer, let groupContainer, memberContainer != groupContainer {
            throw RuntimeError(
                """
                cannot add '\(displayName(member))' to '\(target.name)': they are in different \
                accounts, and one save cannot span two.
                  contact: \(describeContainer(memberContainer))
                  group:   \(describeContainer(groupContainer))
                Create the contact in the group's account instead:
                  apple contacts add --container "\(groupContainer)" …
                or move it in Contacts.app, then retry.
                """)
        }

        let request = CNSaveRequest()
        request.addMember(member, to: target)
        do {
            try store.execute(request)
        } catch where isNotePropertyFault(error) {
            // `addMember` faults the contact, and a contact with a note cannot
            // be faulted without the notes entitlement. AddressBook can, and is
            // already how the other direction reaches iCloud groups.
            do {
                try addMemberViaAddressBook(
                    contactId: member.identifier, groupId: target.identifier)
            } catch {
                throw RuntimeError(
                    """
                    could not add '\(displayName(member))' to '\(target.name)'. Contacts refuses \
                    to save a membership change for a contact that carries a note, because the \
                    save reads the note and that needs the \
                    com.apple.developer.contacts.notes entitlement, which no command-line tool \
                    can hold. The AddressBook fallback did not work either: \
                    \(error.localizedDescription)
                    Add this contact to the group in Contacts.app.
                    """)
            }
        } catch {
            // A runtime failure, so RuntimeError rather than ValidationError:
            // the latter makes ArgumentParser print a usage block, which tells
            // the caller nothing about a Core Data error and buries the message.
            throw RuntimeError(
                "could not add '\(displayName(member))' to '\(target.name)': "
                + saveFailureDetail(error))
        }

        // This whole family of calls has a history of reporting success while
        // doing nothing, so confirm rather than trusting the exit code — the same
        // rule `groups remove` already follows.
        guard isMember(member.identifier, of: target.identifier) else {
            throw RuntimeError(
                "the save reported success but '\(displayName(member))' is not in "
                + "'\(target.name)'. Nothing was changed.")
        }

        if json {
            printJSON(
                GroupMembershipResult(
                    group: target.name, contactId: member.identifier, member: true,
                    changed: true))
        } else {
            print("Added '\(displayName(member))' to '\(target.name)'")
        }
    }
}

struct GroupRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove a contact from a group (the contact is kept)")

    @Argument(help: "Group id or name")
    var group: String

    @Argument(help: "Contact id, from `search --json`")
    var contactId: String

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let target = try resolveGroup(group)
        // Container-backed, for the same reason as `add`: a unified contact is
        // the wrong object to hand a membership change, and its `identifier` may
        // not even be the id that was asked for — which would make the
        // `isMember` checks below silently answer about a different record.
        let member = try containerContact(withId: contactId)

        // Removing someone who was never in the group would otherwise run the
        // whole fallback dance and then report "Removed", which is a no-op
        // dressed up as an action — the mirror of the bug `add` had.
        guard isMember(member.identifier, of: target.identifier) else {
            if json {
                printJSON(
                    GroupMembershipResult(
                        group: target.name, contactId: member.identifier, member: false,
                        changed: false))
            } else {
                print("'\(displayName(member))' is not in '\(target.name)'. Nothing to do.")
            }
            return
        }

        // The framework first — it works, but only for some containers.
        // `CNSaveRequest.removeMember` saves without error and changes nothing
        // for a CardDAV-backed (iCloud) group, while doing the right thing for
        // a local "On My Mac" one. Same code, same objects, different result
        // per container; nothing about the call site distinguishes them, so
        // just try it and check.
        let request = CNSaveRequest()
        request.removeMember(member, from: target)
        try? store.execute(request)

        // Only fall back if the modern call really didn't take.
        if isMember(member.identifier, of: target.identifier) {
            try removeMemberViaAddressBook(
                contactId: member.identifier, groupId: target.identifier)
        }

        // This operation has a history of reporting success while doing
        // nothing, so confirm it rather than trusting the exit code.
        guard !isMember(member.identifier, of: target.identifier) else {
            throw RuntimeError(
                "'\(displayName(member))' is still a member of '\(target.name)'. "
                + "Nothing was changed.")
        }
        if json {
            printJSON(
                GroupMembershipResult(
                    group: target.name, contactId: member.identifier, member: false,
                    changed: true))
            return
        }
        print("Removed '\(displayName(member))' from '\(target.name)'. The contact was not deleted.")
    }
}

private func displayName(_ contact: CNContact) -> String {
    let name = [contact.givenName, contact.familyName]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    if !name.isEmpty { return name }
    if !contact.organizationName.isEmpty { return contact.organizationName }
    return contact.identifier
}

// Core Data prints the note-entitlement fault to stderr itself, before anything
// here sees the error:
//
//   CoreData: error: Unhandled error occurred during faulting: Error
//   Domain=NSCocoaErrorDomain Code=134092 "(null)" ({ })
//
// It names neither the contact nor the note, so there is nothing a caller can
// do with it, and the commands now catch that failure and explain it. Keep the
// raw dump out of the output rather than printing both. The registration domain
// is in-memory, so this changes nothing on disk and no other process's logging.
UserDefaults.standard.register(defaults: ["com.apple.CoreData.Logging.stderr": 0])

// Claim the TCC identity before anything can write to stdout or stderr.
//
// The re-exec runs the whole command again in the child, so any output the
// parent has already produced appears twice. `validate()` runs before
// `requireContactsAccess()` and warns about unrecognised relation labels, which
// is exactly such a case — doing this here instead keeps the parent silent.
//
// Arguments that only print something never touch the store, so they skip the
// re-exec entirely and cost no extra process.
let infoOnlyArguments: Set<String> = [
    "-h", "--help", "help", "--version", "--generate-completion-script",
]
if !CommandLine.arguments.dropFirst().contains(where: { infoOnlyArguments.contains($0) }) {
    claimOwnTCCIdentity()
}

// ArgumentParser has no coloured help, so generate it, style it, and print
// it here rather than letting .main() emit the plain version.
if let help = HelpColor.requested(root: AppleContacts.self, arguments: CommandLine.arguments) {
    print(help)
    exit(0)
}

AppleContacts.main()
