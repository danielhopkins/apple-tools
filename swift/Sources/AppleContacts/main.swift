import AddressBook  // deprecated, but the only thing that removes iCloud group members
import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import Contacts
import ContactsLibrary
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
    /// True when the card records a death. Absent otherwise, never `false` —
    /// the same rule every optional key here follows.
    let deceased: Bool?
    /// What is KNOWN about when they died: `2020-04-30`, `2020`, or `--04-30`.
    ///
    /// 🛑 **Never the stored value.** A year-only death has to occupy a real
    /// month and day, because Contacts refuses a date without them, so the card
    /// holds `2020-01-01` and this key says `2020`. Read `died`, not `dates`.
    let died: String?
    /// `date`, `year`, or `day-only`. Says how much of `died` is real.
    let died_precision: String?
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

    // 🛑 Read the death off the DECODED labels. A card written by hand can say
    // `Death`, and a person who died is not a thing to miss over one letter.
    let death = DeathDate.read(
        contact.dates.map { (Labels.decode($0.label), $0.value as DateComponents) })

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
        deceased: death == nil ? nil : true,
        died: death?.died,
        died_precision: death?.precision.rawValue,
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

func printJSON<T: Encodable>(_ value: T) {
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
func containerContact(withId id: String) throws -> CNContact {
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
func containerId(forContact id: String) -> String? {
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
func resolveContainer(_ reference: String) throws -> String {
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
func describeContainer(_ id: String?) -> String {
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
let notePropertyFaultCode = 134092

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
/// is not blocked from saving a record that has a note. It is already the
/// fallback that removes members from iCloud groups, so nothing new is being
/// taken on.
///
/// 🛑 **This gets past the wall; it does not get through it.** An earlier
/// version of this comment guessed that AddressBook could write the note too,
/// "as long as it is not the note itself being written". Measured on 683 real
/// contacts: `ABPerson.value(forProperty: kABNoteProperty)` read **zero** of
/// the 52 notes and raised `NSCocoaErrorDomain 134092` on every one. `ABPerson`
/// is a shim over the same Core Data store and hits the same entitlement. The
/// note is written through Contacts.app instead — see `NoteWriter`.
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
        "email", wanted: fields.allEmails,
        stored: saved.emailAddresses.map { ($0.label, $0.value as String) })
    check(
        "url", wanted: fields.allUrls,
        stored: saved.urlAddresses.map { ($0.label, $0.value as String) })
    check(
        "relation", wanted: fields.relations,
        stored: saved.contactRelations.map { ($0.label, $0.value.name) })
    // 🛑 Compare every field, not just the street. A parse that put the city in
    // the street would otherwise write a wrong address and report success.
    check(
        "address",
        wanted: fields.allAddresses.map { ($0.label, PostalAddress.describe($0.value)) },
        stored: saved.postalAddresses.map { ($0.label, PostalAddress.describe($0.value)) })
    check(
        "date",
        wanted: fields.dates.map { ($0.label, ContactDate.format($0.value) ?? "") },
        stored: saved.dates.map { ($0.label, ContactDate.format($0.value as DateComponents) ?? "") })
    // Digits, not punctuation. How a number is formatted is the store's
    // business — `search` already compares them this way — and this check exists
    // to catch a value that went missing, not one that was tidied.
    func digits(_ value: String) -> String { value.filter(\.isNumber) }
    check(
        "phone", wanted: fields.allPhones.map { ($0.label, digits($0.value)) },
        stored: saved.phoneNumbers.map { ($0.label, digits($0.value.stringValue)) })

    // 🛑 `--died` is checked on what the card MEANS, not on what it stores. A
    // year-only death is written as `2020-01-01`, so a raw comparison against
    // the input `2020` would fail on every correct write. Comparing the read-back
    // instead also catches the real failure this guards: a card that came back
    // holding `death` where `death-year` was asked for, which would report a
    // placeholder day as a real one.
    if let died = fields.died, let wanted = try? DeathDate.parse(died) {
        let stored = DeathDate.read(
            saved.dates.map { (Labels.decode($0.label), $0.value as DateComponents) })
        if stored?.died != wanted.known || stored?.precision != wanted.precision {
            var reads = "no death date"
            if let stored { reads = stored.died + " [" + stored.precision.rawValue + "]" }
            missing.append("--died \(wanted.known)  (the card reads \(reads))")
        }
    }

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
            apple-contacts move <id> --to "iCloud" --dry-run
            apple-contacts export <id> -o card.vcf         # vCard
            apple-contacts export --group "Family" -o family.vcf
          """,
        version: appleToolsVersion,
        subcommands: [Search.self, Get.self, List.self, Add.self, Edit.self, Move.self,
                      Delete.self, Export.self, Groups.self,
                      Relations.self, Link.self, Unlink.self, Deceased.self,
                      Containers.self, Status.self],
        defaultSubcommand: Search.self)

    static func plainText(_ contacts: [ContactInfo]) -> String { plain(contacts) }
}

struct DeceasedEntry: Encodable {
    let id: String
    let name: String
    let died: String
    let died_precision: String
    let contact_url: String
}

struct MarkedEntry: Encodable {
    let id: String
    let name: String
    let contact_url: String
}

struct DeceasedReport: Encodable {
    let count: Int
    let deceased: [DeceasedEntry]
    /// Cards whose note carries a dagger but which record no death date.
    ///
    /// ⚠️ Always present, `[]` when empty. `apple calendar invitees` learned this
    /// the hard way: a key omitted when empty makes a careful reader conclude the
    /// field was dropped from the build, rather than that the answer is none.
    let marked_without_date: [MarkedEntry]
}

struct Deceased: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List everyone recorded as having died",
        discussion: """
          Reads the death date off each card. Apple defines no death field, so
          the record is a labelled date: `death` for a full date, `death-year`
          when only the year is known. Write one with `--died` on `add` or
          `edit`.

          🛑 `died` reports what is KNOWN, never what is stored. Contacts refuses
          a date with no month or day, so a year-only death occupies a real day
          it never had — `2020-01-01` on the card, `2020` in this listing. Read
          `died`, never the raw `dates` array.

          Sorted most recent first. A death with no year sorts last, because
          nothing places it in time.

          `marked_without_date` lists cards whose note carries a dagger and which
          record no death date. That marker is never the record and never makes
          anyone deceased. Resolve one with `edit --died`: it writes the date,
          and leaves the marker that is already there alone.
          """)

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let notes = NoteStore.allNotes()

        var found: [DeceasedEntry] = []
        var marked: [MarkedEntry] = []

        for contact in try allContacts() {
            let name = displayName(contact)
            let url = "addressbook://\(contact.identifier)"
            let record = DeathDate.read(
                contact.dates.map { (Labels.decode($0.label), $0.value as DateComponents) })

            if let record {
                found.append(DeceasedEntry(
                    id: contact.identifier, name: name,
                    died: record.died, died_precision: record.precision.rawValue,
                    contact_url: url))
            } else if DeathDate.noteMarksDeath(notes[contact.identifier]) {
                marked.append(MarkedEntry(id: contact.identifier, name: name, contact_url: url))
            }
        }

        // ⚠️ A year-less date has no year to sort on, so it goes last rather
        // than sorting as though it happened in year zero. `--04-30` would sort
        // before every real date otherwise, since `-` precedes every digit.
        found.sort { left, right in
            let leftUndated = left.died.hasPrefix("--")
            let rightUndated = right.died.hasPrefix("--")
            if leftUndated != rightUndated { return rightUndated }
            if left.died != right.died { return left.died > right.died }
            return left.name < right.name
        }
        marked.sort { $0.name < $1.name }

        let report = DeceasedReport(
            count: found.count, deceased: found, marked_without_date: marked)

        if json {
            printJSON(report)
            return
        }

        if found.isEmpty && marked.isEmpty {
            print("No contact records a death date.")
            return
        }

        if !found.isEmpty {
            let width = found.map(\.name.count).max() ?? 0
            for entry in found {
                let note = entry.died_precision == "year" ? "  (year only)"
                    : entry.died_precision == "day-only" ? "  (year unknown)" : ""
                print("\(entry.name.padding(toLength: max(width, 4), withPad: " ", startingAt: 0))"
                      + "  \(entry.died)\(note)")
            }
        }

        if !marked.isEmpty {
            if !found.isEmpty { print("") }
            print("Marked in the note, but no death date recorded:")
            for entry in marked { print("  \(entry.name)") }
            print("")
            print("Add one with:  apple contacts edit <id> --died YYYY-MM-DD")
            print("...or just the year:  --died YYYY")
        }
    }
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

        // ⚠️ **Two grants, for two different jobs.** Contacts covers everything
        // except the note; writing a note goes through Contacts.app and needs
        // Automation. So `usable` stays keyed to the Contacts grant alone — a
        // missing Automation grant costs one field, not the tool.
        let (automation, automationOK, automationAdvice) = NoteWriter.automationState()

        if json {
            var payload: [String: Any] = [
                "status": name, "usable": usable,
                "automation": automation, "note_writes": automationOK,
            ]
            if let advice { payload["advice"] = advice }
            if let automationAdvice { payload["automation_advice"] = automationAdvice }
            let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        } else {
            print("Contacts access: \(name)\(usable ? "" : "  (cannot read contacts)")")
            if let advice { print(advice) }
            print("Note writes (Automation → Contacts): \(automation)")
            if let automationAdvice { print(automationAdvice) }
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
        help: """
          Postal address, optionally labelled:           'home:124 Gregory St, Chicago, IL 60601'. Or exactly:           'home:street=124 Gregory St;city=Chicago;state=IL;zip=60601'.           Repeat to set several; replaces existing.
          """)
    var address: [String] = []

    // 🛑 **`--email`/`--phone`/`--url`/`--address` REPLACE the whole field.**
    // Passing one value deletes every other value in that field, silently, and
    // the command prints "Updated '<name>'" either way. The name reads as
    // additive: `edit --url X` looks like "set the URL", not "delete every URL
    // then set X".
    //
    // ⚠️ **Agents are the caller this hurts most.** An agent told to "add the
    // school website" has no reason to read the card first. A peer session
    // nearly destroyed a real contact's URLs that way; the card happened to
    // hold exactly one, so the replace was indistinguishable from an update.
    //
    // The read-modify-write workaround is worse than it looks: it makes the
    // caller reconstruct every existing label exactly, so one typo turns a
    // correction into a second silent loss.
    @Option(name: .long, help: "Email to ADD, keeping existing ones. Repeat for several.")
    var addEmail: [String] = []

    @Option(name: .long, help: "Phone to ADD, keeping existing ones. Repeat for several.")
    var addPhone: [String] = []

    @Option(name: .long, help: "URL to ADD, keeping existing ones. Repeat for several.")
    var addUrl: [String] = []

    @Option(name: .long, help: "Postal address to ADD, keeping existing ones. Repeat for several.")
    var addAddress: [String] = []

    // 🛑 **Without these there was no way to delete ONE value.** The only route
    // was the plain flag: read the card, then re-pass every value except the one
    // to drop. That makes the caller reconstruct each remaining label exactly,
    // so a single typo turns a deletion into a silent loss of something else.
    //
    // ⚠️ Matching mirrors `unlink`: the VALUE identifies the entry, and a label
    // prefix narrows it. Removing something that is not there is an ERROR, not a
    // no-op — a typo must not read as done. That is deliberately the opposite of
    // `--add-*`, where re-adding an existing value already achieves the intent.
    @Option(name: .long, help: "Email to REMOVE, by address. 'work:a@b.com' narrows to that label.")
    var removeEmail: [String] = []

    @Option(name: .long, help: "Phone to REMOVE, by number. Compared on digits.")
    var removePhone: [String] = []

    @Option(name: .long, help: "URL to REMOVE, by value. 'blog:https://…' narrows to that label.")
    var removeUrl: [String] = []

    @Option(name: .long, help: "Postal address to REMOVE, by value.")
    var removeAddress: [String] = []

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

    @Option(
        name: .long,
        help: """
          Death date as YYYY-MM-DD, YYYY (year only), or --MM-DD (year unknown).           Merges: other dates are kept. A --MM-DD value needs '=', as           --died=--04-30.
          """)
    var died: String?

    @Flag(
        name: .long,
        help: "Remove every labelled date. The birthday is a separate field and is kept.")
    var clearDates = false

    // 🛑 **The note is the one field that does NOT go through the Contacts
    // framework.** `CNContactNoteKey` needs an entitlement no CLI can hold, and
    // the legacy AddressBook framework hits the same wall — measured, 0 notes
    // readable across 683 contacts. So a note change is collected here and
    // applied separately, through Contacts.app. See `NoteWriter`.
    @Option(
        name: .long,
        help: "Note text. REPLACES the whole note; use --append-note to keep what is there.")
    var note: String?

    @Option(name: .long, help: "Text to add to the end of the note, on its own line.")
    var appendNote: String?

    @Flag(name: .long, help: "Delete the note.")
    var clearNote = false

    // ⚠️ **`--died` marks the note by default**, because on this address book
    // recording a death and marking the card are one act, done by hand four
    // times before the tool could do either. `--no-mark` is the opt-out, and it
    // is also the escape hatch when Automation → Contacts is unavailable: the
    // date is the record and must not become unwritable because a second grant
    // is missing.
    @Flag(name: .long, help: "With --died, do not add the «†» marker to the note.")
    var noMark = false

    var isEmpty: Bool {
        first == nil && middle == nil && last == nil && namePrefix == nil
            && nameSuffix == nil && nickname == nil && company == nil
            && department == nil && jobTitle == nil && birthday == nil
            && anniversary == nil && died == nil && !clearDates
            && email.isEmpty && phone.isEmpty
            && addEmail.isEmpty && addPhone.isEmpty
            && addUrl.isEmpty && addAddress.isEmpty
            && removeEmail.isEmpty && removePhone.isEmpty
            && removeUrl.isEmpty && removeAddress.isEmpty
            && url.isEmpty && relation.isEmpty && date.isEmpty
            && address.isEmpty
    }

    /// What the caller asked to do to the note, if anything.
    ///
    /// 🛑 **Deliberately NOT part of `isEmpty`.** `isEmpty` means "no
    /// Contacts-framework field changed", and the callers use it to decide
    /// whether to run a `CNSaveRequest` at all. A note-only edit must skip that
    /// save entirely: it would change nothing, and on a contact that already
    /// carries a note it would trip the note wall and fall through to the
    /// AddressBook path for no reason.
    var noteRequest: NoteWriter.Request? {
        let change: NoteWriter.Change? = {
            if clearNote { return .clear }
            if let note { return .set(note) }
            if let appendNote { return .append(appendNote) }
            return nil
        }()
        let mark = died != nil && !noMark
        guard change != nil || mark else { return nil }
        return NoteWriter.Request(change: change, markDeceased: mark)
    }

    var hasNoteChange: Bool { noteRequest != nil }

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
    /// 🛑 **Only the CONSERVATIVE scheme test belongs here.** This runs for
    /// every labelled flag, and most of them are not URLs. `--relation
    /// "father:Robert"` must give the label `father`: `father` matches the
    /// scheme grammar and `Robert` is one unbroken token, so the fuller rule
    /// `splitURL` uses would read it as a scheme and destroy the relation.
    ///
    /// ⚠️ The short allowlist stays because `--email "mailto:a@x.com"` and
    /// `--phone "tel:+1555…"` are supported inputs, pinned by a test. A first
    /// attempt at this fix moved the whole scheme test into `splitURL` and broke
    /// both.
    private func split(_ input: String) -> (label: String?, value: String) {
        guard let separator = input.firstIndex(of: ":") else {
            return (nil, input.trimmingCharacters(in: .whitespaces))
        }
        let label = String(input[input.startIndex..<separator])
            .trimmingCharacters(in: .whitespaces)
        // ⚠️ Trimmed. `--url "Note: https://x"` stored a value with a leading
        // space, and the URL then failed to resolve.
        let value = String(input[input.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)

        let looksLikeScheme = Self.isURIScheme(label)
            && (value.hasPrefix("//") || Self.schemesWithoutSlashes.contains(label.lowercased()))
        if looksLikeScheme { return (nil, input.trimmingCharacters(in: .whitespaces)) }

        return (label.isEmpty ? nil : label, value)
    }

    /// Schemes whose value does not begin `//`, so the `//` test alone cannot
    /// recognise them. ⚠️ Kept short on purpose: every entry is a word that can
    /// no longer be a label on ANY flag, not just `--url`.
    private static let schemesWithoutSlashes: Set<String> = [
        "mailto", "tel", "sms", "callto", "facetime", "facetime-audio", "skype", "xmpp",
    ]

    /// The same split, for a value that may itself be a URL carrying a scheme.
    ///
    /// 🛑 **The first colon is not always a label separator.** A bare
    /// `https://example.com` has one, and cutting there stored `//example.com`
    /// under a label of `https`. `--url` is documented as *optionally*
    /// labelled, so a bare URL is a supported input and has to survive.
    ///
    /// 🛑 **An allowlist of schemes was the wrong shape and lost data
    /// silently.** The old rule took the prefix as a scheme only when the rest
    /// began `//`, or when the prefix was one of eight hard-coded words. Every
    /// other scheme legitimately written without `//` fell through and was
    /// stored as a label, with the scheme stripped off the URL and a zero exit
    /// code. Measured on 26.820.1:
    ///
    /// | input | stored |
    /// |---|---|
    /// | `webcal:cal.example.com/f.ics` | label `webcal`, url `cal.example.com/f.ics` |
    /// | `ftps:files.example.com` | label `ftps` |
    /// | `matrix:r/x` | label `matrix` |
    /// | `https:lower.example.com` | label `https` |
    ///
    /// ⚠️ **It was never a case problem**, though it looked like one. The
    /// allowlist already lowercased, so `MAILTO:` worked and `https:` failed —
    /// the missing `//` was the whole cause.
    ///
    /// The rule now asks what follows the colon instead of consulting a list:
    ///
    /// 1. A **known label** wins outright, so `work:example.com` stays a label.
    /// 2. Otherwise a prefix matching the RFC 3986 scheme grammar is a scheme
    ///    when the rest starts `//`, **or** the rest is one unbroken token that
    ///    carries no scheme of its own.
    /// 3. Anything else is a label.
    ///
    /// 🛑 Step 2's second half is what keeps `LinkedIn:https://x.com` a label:
    /// the rest already has a scheme, so the prefix cannot be one too.
    ///
    /// ⚠️ **`LinkedIn:example.com` stays genuinely ambiguous** — a valid scheme
    /// grammar followed by a bare host. It is read as a URL and warned about,
    /// because no rule can distinguish it from `matrix:r/x`.
    private func splitURL(_ input: String) -> (label: String?, value: String) {
        let (label, value) = split(input)
        guard let label, !value.isEmpty else { return (label, value) }

        if Labels.isKnownURLLabel(label) { return (label, value) }
        guard Self.isURIScheme(label) else { return (label, value) }

        if value.hasPrefix("//") { return (nil, input) }

        let unbroken = !value.contains(where: \.isWhitespace)
        guard unbroken, !Self.carriesOwnScheme(value) else { return (label, value) }

        return (nil, input)
    }

    /// The `--url` inputs read as a scheme where a label was also plausible.
    ///
    /// ⚠️ **Reported from `validate()`, not from the parser.** `urls` is a
    /// computed property and every caller re-runs it — validate, apply, and the
    /// read-back check — so warning inside the split printed the same line three
    /// times for one flag.
    var ambiguousURLs: [(input: String, label: String)] {
        url.compactMap { raw in
            let (label, value) = split(raw)
            guard let label, !value.isEmpty,
                  !Labels.isKnownURLLabel(label),
                  Self.isURIScheme(label),
                  !value.hasPrefix("//"),
                  !value.contains(where: \.isWhitespace),
                  !Self.carriesOwnScheme(value),
                  !Self.wellKnownSchemes.contains(label.lowercased())
            else { return nil }
            return (raw, label)
        }
    }

    /// Does this text begin with its own `scheme:`?
    private static func carriesOwnScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        return isURIScheme(String(text[text.startIndex..<colon]))
    }

    /// Schemes common enough that reading one as a scheme needs no comment.
    /// ⚠️ Not an allowlist — an unlisted scheme still parses as a scheme. This
    /// only decides whether to mention it, which is why being wrong here costs
    /// a line of stderr rather than a mangled URL.
    private static let wellKnownSchemes: Set<String> = [
        "http", "https", "mailto", "tel", "sms", "callto", "facetime",
        "facetime-audio", "skype", "xmpp", "webcal", "ftp", "ftps", "file",
        "irc", "news", "nntp", "sip", "sips", "ssh", "data", "im",
    ]

    /// RFC 3986 §3.1: `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`.
    private static func isURIScheme(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }

    func validate() throws {
        // ⚠️ Refused rather than resolved, the same rule `--email` /
        // `--add-email` and `--clear-dates` / `--date` already follow. "Replace
        // the note, then append to it" and "append to what was just set" are
        // different, and one reading silently loses text the caller wrote.
        if note != nil && appendNote != nil {
            throw ValidationError(
                "--note and --append-note do the same job two ways. --note replaces the "
                + "whole note; --append-note keeps it and adds a line. Pass one.")
        }
        if clearNote && (note != nil || appendNote != nil) {
            throw ValidationError(
                "--clear-note deletes the note, so it cannot be combined with "
                + "--note or --append-note.")
        }
        // "Empty the note" and "put the marker in the note" cannot both be
        // meant. Refused rather than resolved, since either reading throws away
        // half of what was asked for.
        if clearNote && died != nil && !noMark {
            throw ValidationError(
                "--clear-note empties the note, but --died puts the «†» marker in it. "
                + "Add --no-mark to record the date without the marker, or drop --clear-note.")
        }
        if noMark && died == nil {
            throw ValidationError("--no-mark only means anything alongside --died.")
        }
        if let birthday, ContactDate.parse(birthday) == nil {
            throw ValidationError("could not parse --birthday '\(birthday)'; use YYYY-MM-DD or --MM-DD")
        }
        if let anniversary, ContactDate.parse(anniversary) == nil {
            throw ValidationError(
                "could not parse --anniversary '\(anniversary)'; use YYYY-MM-DD or --MM-DD")
        }
        // ⚠️ Refused rather than resolved. `--clear-dates --date x:y` reads as
        // "clear, then set", which is just `--date x:y` — and reading it the
        // other way round would silently drop the value. `--died` IS allowed
        // alongside, because "clear the dates and record the death" means only
        // one thing.
        if clearDates && (!date.isEmpty || anniversary != nil) {
            throw ValidationError(
                "--clear-dates cannot be combined with --date or --anniversary. "
                + "--date already replaces the whole set; use it alone to set one.")
        }
        // ⚠️ **Refused rather than resolved.** `--email X --add-email Y` could
        // mean "replace with X, then add Y" or "add Y to a list already set to
        // X", and those differ. `apple reminders` refuses `--tag` alongside
        // `--add-tag` for the same reason.
        for (replace, other, name, style) in [
            (!email.isEmpty, !addEmail.isEmpty, "email", "add"),
            (!phone.isEmpty, !addPhone.isEmpty, "phone", "add"),
            (!url.isEmpty, !addUrl.isEmpty, "url", "add"),
            (!address.isEmpty, !addAddress.isEmpty, "address", "add"),
            (!email.isEmpty, !removeEmail.isEmpty, "email", "remove"),
            (!phone.isEmpty, !removePhone.isEmpty, "phone", "remove"),
            (!url.isEmpty, !removeUrl.isEmpty, "url", "remove"),
            (!address.isEmpty, !removeAddress.isEmpty, "address", "remove"),
        ] where replace && other {
            throw ValidationError(
                "--\(name) and --\(style)-\(name) cannot be combined. "
                + "--\(name) replaces every \(name) on the contact; "
                + "--\(style)-\(name) works from the existing ones. Use one or the other.")
        }

        // ⚠️ A note, not a refusal. The reading is defensible either way, and
        // refusing would break a URL whose scheme simply is not well known.
        for case let (input, label) in ambiguousURLs {
            let value = split(input).value
            FileHandle.standardError.write(Data("""
                note: read '\(input)' as a URL whose scheme is '\(label)', not as a label.
                      For a label, give the value its own scheme: \
                --url "\(label):https://\(value)"

                """.utf8))
        }
        // 🛑 Validated BEFORE any Apple Event, like every other field here.
        if let died {
            do { _ = try DeathDate.parse(died) }
            catch let error as DeathDate.ParseError {
                throw ValidationError("--died \(error.description)")
            }
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
        // 🛑 Parse every address BEFORE any Apple Event. A bad one must fail
        // here, not halfway through a save, and not silently as an address
        // with fields missing. The free-text parse is a guess, so it is echoed.
        for entry in address + addAddress {
            let (_, value) = split(entry)
            guard !value.isEmpty else {
                throw ValidationError("--address \(entry) has no address after the colon")
            }
            let parsed: CNMutablePostalAddress
            do {
                parsed = try PostalAddress.parse(value)
            } catch let error as PostalAddress.ParseError {
                throw ValidationError("--address \(entry): \(error.description)")
            }
            if !PostalAddress.isStructured(value) {
                // ⚠️ Always show what the heuristic decided. It knows one
                // shape, `street, city, STATE ZIP, country`, and nothing
                // about any other country. Showing the split is the only way
                // a wrong one is visible before it is written.
                FileHandle.standardError.write(Data("""
                    note: read '\(value)' as \(PostalAddress.describe(parsed))
                          Use street=…;city=…;state=…;zip=… if that is wrong.

                    """.utf8))
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
    /// A unit separator, so a label ending in a colon cannot forge a match.
    /// The same key shape `confirmWritten` uses.
    static func key(_ label: String?, _ value: String) -> String {
        "\(label ?? "")\u{1f}\(value)"
    }

    /// Checks that need the contact as it stands, run before anything is written.
    ///
    /// 🛑 **A removal matching nothing is an error, not a no-op.** A silent
    /// no-op lets `--remove-email a@x.con` read as done while the address is
    /// still on the card. This is deliberately the opposite of `--add-*`, where
    /// re-adding a value already present achieves the intent.
    ///
    /// ⚠️ **A plain flag that discards values says so, naming them.** It still
    /// replaces — the behaviour is unchanged and callers depending on it are
    /// safe. The loss is simply no longer invisible.
    func preflight(against existing: CNContact) throws {
        // 🛑 **The pre-flight must accept exactly what `apply` removes.** An
        // address matches on its street OR its full structured form, so a check
        // that knew only one form refused `--remove-address "work:1 Main St"`
        // for an address `apply` would have removed. Every entry therefore
        // carries every string it can be named by.
        func checkRemovals(
            _ raw: [String], _ flag: String,
            _ stored: [(label: String?, names: [String], shown: String)],
            url: Bool = false, normalise: @escaping (String) -> String = { $0 }
        ) throws {
            for removal in removals(raw, url: url)
            where !stored.contains(where: { entry in
                entry.names.contains {
                    matches(removal, label: entry.label, value: $0, normalise: normalise)
                }
            }) {
                let present = stored.isEmpty
                    ? "the contact has no \(flag)s at all"
                    : "it has: " + stored.map {
                        (Labels.decode($0.label).map { "\($0):" } ?? "") + $0.shown
                    }.joined(separator: ", ")
                throw ValidationError(
                    "--remove-\(flag) '\(removal.raw)' matches nothing on "
                    + "'\(displayName(existing))'. \(present)")
            }
        }

        let storedEmails = existing.emailAddresses.map { ($0.label, $0.value as String) }
        let storedPhones = existing.phoneNumbers.map { ($0.label, $0.value.stringValue) }
        let storedUrls = existing.urlAddresses.map { ($0.label, $0.value as String) }
        let storedAddresses = existing.postalAddresses.map {
            ($0.label, PostalAddress.describe($0.value))
        }

        func simple(_ entries: [(String?, String)]) -> [(String?, [String], String)] {
            entries.map { ($0.0, [$0.1], $0.1) }
        }
        try checkRemovals(removeEmail, "email", simple(storedEmails))
        try checkRemovals(removePhone, "phone", simple(storedPhones),
                          normalise: { $0.filter(\.isNumber) })
        try checkRemovals(removeUrl, "url", simple(storedUrls), url: true)
        // ⚠️ An address is nameable by its street or by its full structured
        // form. `shown` is the street, because the structured form is unreadable
        // in an error message.
        try checkRemovals(removeAddress, "address", existing.postalAddresses.map {
            ($0.label, [PostalAddress.describe($0.value), $0.value.street], $0.value.street)
        })

        func warnReplacing(_ asked: Bool, _ flag: String,
                           _ stored: [(label: String?, value: String)]) {
            guard asked, !stored.isEmpty else { return }
            let listed = stored.map {
                Labels.decode($0.label) ?? $0.value
            }.joined(separator: ", ")
            FileHandle.standardError.write(Data("""
                warning: --\(flag) replaces every \(flag) on this contact. \
                Discarding \(stored.count) (\(listed)).
                         Use --add-\(flag) to keep them, or --remove-\(flag) to \
                drop just one.

                """.utf8))
        }
        warnReplacing(!email.isEmpty, "email", storedEmails)
        warnReplacing(!phone.isEmpty, "phone", storedPhones)
        warnReplacing(!url.isEmpty, "url", storedUrls)
        warnReplacing(!address.isEmpty, "address", storedAddresses)

        // ⚠️ A note is free text, so nothing about the new value hints at how
        // much of the old one it destroys. The longest note on a real store is
        // 514 characters, and 11 of the 52 span several lines — losing one to a
        // flag that reads like "set the note" is exactly the `--url` mistake.
        if note != nil, let existing = NoteStore.allNotes()[existing.identifier],
           !existing.isEmpty {
            let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).count
            FileHandle.standardError.write(Data("""
                warning: --note replaces the whole note on this contact. \
                Discarding \(existing.count) characters over \(lines) line\(lines == 1 ? "" : "s").
                         Use --append-note to keep it. `export` writes it to a vCard first.

                """.utf8))
        }
    }

    /// A removal request: the value to drop, and a label if one narrows it.
    struct Removal {
        let label: String?
        let value: String
        let raw: String
    }

    /// Does this stored entry match the removal?
    ///
    /// ⚠️ The VALUE identifies the entry. A label only narrows, matching how
    /// `unlink --relation` works. `--remove-url https://b` drops it under any
    /// label; `--remove-url "blog:https://b"` drops only the labelled one.
    func matches(
        _ removal: Removal, label: String?, value: String,
        normalise: (String) -> String = { $0 }
    ) -> Bool {
        guard normalise(value) == normalise(removal.value) else { return false }
        guard let wanted = removal.label else { return true }
        return Labels.decode(label)?.lowercased() == Labels.decode(wanted)?.lowercased()
    }

    /// Parse a `--remove-*` value into a label and a value.
    ///
    /// ⚠️ `splitURL` for URLs, so `--remove-url https://b` is not read as the
    /// label `https`.
    func removals(_ raw: [String], url: Bool = false) -> [Removal] {
        raw.map { entry in
            let (label, value) = url ? splitURL(entry) : split(entry)
            return Removal(label: label, value: value, raw: entry)
        }
    }

    /// The entries not already present, comparing label AND value.
    ///
    /// ⚠️ **Re-adding an existing value is a silent no-op, not a duplicate
    /// row.** Same shape `link` and `groups add` use. A caller running the same
    /// `--add-email` twice must not end up with the address twice.
    ///
    /// ⚠️ Only an exact label+value match counts. The same address under a
    /// different label is a different entry and is added.
    static func newOnly(
        _ wanted: [(label: String?, value: String)],
        notIn existing: [(label: String?, value: String)],
        normalise: (String) -> String = { $0 }
    ) -> [(label: String?, value: String)] {
        var seen = Set(existing.map { key($0.label, normalise($0.value)) })
        return wanted.filter { entry in
            seen.insert(key(entry.label, normalise(entry.value))).inserted
        }
    }

    /// The date list this edit should write, with the death date merged in.
    ///
    /// 🛑 **`--died` merges; `--date` replaces.** That difference is the whole
    /// reason `--died` exists as its own flag. Getting a death onto a card with
    /// `--date` alone means re-passing every other date the card holds, and
    /// forgetting one deletes it silently — the same trap `link` exists to avoid
    /// for relations.
    ///
    /// The rule when both are given: `--date` establishes the set, then `--died`
    /// is merged into it. So the death date is always present afterwards,
    /// whatever else was asked for.
    ///
    /// ⚠️ Existing labels are carried through **raw**, never decoded and
    /// re-encoded. Decoding is lossless for every label this tool writes, but a
    /// round trip is a chance to be wrong about one, and there is no reason to
    /// take it for entries this edit never mentioned.
    ///
    /// Returns nil when neither flag was given, meaning "leave the dates alone".
    func mergedDates(existing: [(label: String?, value: DateComponents)])
        -> [(label: String?, value: DateComponents)]?
    {
        guard !dates.isEmpty || died != nil || clearDates else { return nil }
        // ⚠️ `--clear-dates` starts from nothing, so a `--died` given alongside
        // is the only entry that survives.
        var result: [(label: String?, value: DateComponents)]
        if clearDates { result = [] } else { result = dates.isEmpty ? existing : dates }
        guard let died, let written = try? DeathDate.parse(died) else { return result }
        // Drop any death already recorded, so `--died` restates rather than
        // stacking a second one. This is also what moves a card from `death` to
        // `death-year`, or back, when the precision changes.
        result.removeAll { DeathDate.isDeathLabel(Labels.decode($0.label)) }
        result.append((written.label, written.components))
        return result
    }

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

        // ⚠️ Removal runs BEFORE the append, so `--remove-x A --add-x A` ends
        // with A present. Doing it the other way round would delete what was
        // just added, which nobody means.
        if !removeEmail.isEmpty {
            let wanted = removals(removeEmail)
            contact.emailAddresses = contact.emailAddresses.filter { entry in
                !wanted.contains { matches($0, label: entry.label, value: entry.value as String) }
            }
        }
        if !removePhone.isEmpty {
            let wanted = removals(removePhone)
            contact.phoneNumbers = contact.phoneNumbers.filter { entry in
                !wanted.contains {
                    matches($0, label: entry.label, value: entry.value.stringValue,
                            normalise: { $0.filter(\.isNumber) })
                }
            }
        }
        if !removeUrl.isEmpty {
            let wanted = removals(removeUrl, url: true)
            contact.urlAddresses = contact.urlAddresses.filter { entry in
                !wanted.contains { matches($0, label: entry.label, value: entry.value as String) }
            }
        }
        if !removeAddress.isEmpty {
            let wanted = removals(removeAddress)
            contact.postalAddresses = contact.postalAddresses.filter { entry in
                !wanted.contains {
                    matches($0, label: entry.label,
                            value: PostalAddress.describe(entry.value))
                        || matches($0, label: entry.label, value: entry.value.street)
                }
            }
        }

        if !emails.isEmpty {
            contact.emailAddresses = emails.map {
                CNLabeledValue(label: $0.label, value: $0.value as NSString)
            }
        } else if !addedEmails.isEmpty {
            contact.emailAddresses += Self.newOnly(
                addedEmails, notIn: contact.emailAddresses.map { ($0.label, $0.value as String) }
            ).map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        }

        if !phones.isEmpty {
            contact.phoneNumbers = phones.map {
                CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value))
            }
        } else if !addedPhones.isEmpty {
            // ⚠️ Compared on digits, matching the post-write check. How a
            // number is punctuated is the store's business, and `+1 555 0100`
            // must not be added again next to `+15550100`.
            contact.phoneNumbers += Self.newOnly(
                addedPhones,
                notIn: contact.phoneNumbers.map { ($0.label, $0.value.stringValue) },
                normalise: { $0.filter(\.isNumber) }
            ).map { CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value)) }
        }

        if !urls.isEmpty {
            contact.urlAddresses = urls.map {
                CNLabeledValue(label: $0.label, value: $0.value as NSString)
            }
        } else if !addedUrls.isEmpty {
            contact.urlAddresses += Self.newOnly(
                addedUrls, notIn: contact.urlAddresses.map { ($0.label, $0.value as String) }
            ).map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        }

        if !addresses.isEmpty {
            contact.postalAddresses = addresses.map {
                CNLabeledValue(label: $0.label, value: $0.value)
            }
        } else if !addedAddresses.isEmpty {
            let existing = contact.postalAddresses.map {
                ($0.label, PostalAddress.describe($0.value))
            }
            let wanted = addedAddresses.map { ($0.label, PostalAddress.describe($0.value)) }
            let keep = Set(Self.newOnly(wanted, notIn: existing).map { Self.key($0.label, $0.value) })
            contact.postalAddresses += addedAddresses
                .filter { keep.contains(Self.key($0.label, PostalAddress.describe($0.value))) }
                .map { CNLabeledValue(label: $0.label, value: $0.value) }
        }
        if !relations.isEmpty {
            contact.contactRelations = relations.map {
                CNLabeledValue(label: $0.label, value: CNContactRelation(name: $0.value))
            }
        }
        let existingDates = contact.dates.map { ($0.label, $0.value as DateComponents) }
        if let merged = mergedDates(existing: existingDates) {
            contact.dates = merged.map {
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

        // ⚠️ The fallback writes the whole multivalue at once, so an append
        // has to read the existing entries back first — the same shape
        // `mergedDates` needs, and for the same reason.
        func merge(
            _ replace: [(label: String?, value: String)],
            _ add: [(label: String?, value: String)],
            _ property: String
        ) {
            if !replace.isEmpty {
                setMulti(replace.map { ($0.label, $0.value as NSString) }, property)
            } else if !add.isEmpty {
                let existing = Self.existingStrings(of: person, property: property)
                let merged = existing + Self.newOnly(add, notIn: existing)
                setMulti(merged.map { ($0.label, $0.value as NSString) }, property)
            }
        }
        merge(emails, addedEmails, kABEmailProperty)
        merge(phones, addedPhones, kABPhoneProperty)
        merge(urls, addedUrls, kABURLsProperty)
        if !addresses.isEmpty {
            // ⚠️ AddressBook stores an address as a dictionary of its own keys,
            // not as a CNPostalAddress. The spellings differ from the SDK's.
            setMulti(addresses.map { entry -> (String?, NSDictionary) in
                var fields: [String: String] = [:]
                if !entry.value.street.isEmpty { fields[kABAddressStreetKey as String] = entry.value.street }
                if !entry.value.city.isEmpty { fields[kABAddressCityKey as String] = entry.value.city }
                if !entry.value.state.isEmpty { fields[kABAddressStateKey as String] = entry.value.state }
                if !entry.value.postalCode.isEmpty { fields[kABAddressZIPKey as String] = entry.value.postalCode }
                if !entry.value.country.isEmpty { fields[kABAddressCountryKey as String] = entry.value.country }
                return (entry.label, fields as NSDictionary)
            }, kABAddressProperty)
        }
        if !relations.isEmpty {
            setMulti(relations.map { ($0.label, $0.value as NSString) }, kABRelatedNamesProperty)
        }
        // ⚠️ **This path is the normal one for a death, not the exception.** All
        // four cards recorded as deceased on the store this was built against
        // carry a note, and a note blocks every `CNContactStore` write to the
        // card. So `--died` reaches AddressBook far more often than it reaches
        // Contacts, and the merge has to work identically here.
        if let merged = mergedDates(existing: existingDates(of: person)) {
            setMulti(
                merged.map { ($0.label, $0.value as NSDateComponents) },
                kABOtherDateComponentsProperty)
        }
        return ok
    }

    /// The labelled strings AddressBook already holds under one property.
    static func existingStrings(
        of person: ABPerson, property: String
    ) -> [(label: String?, value: String)] {
        guard let multi = person.value(forProperty: property) as? ABMultiValue else { return [] }
        var out: [(label: String?, value: String)] = []
        for index in 0..<multi.count() {
            guard let value = multi.value(at: index) as? String else { continue }
            let label = multi.label(at: index)
            out.append((label?.isEmpty == true ? nil : label, value))
        }
        return out
    }

    /// The labelled dates AddressBook already holds for this record.
    ///
    /// Needed because `--died` merges, and the AddressBook fallback writes the
    /// whole multivalue at once — so the existing entries have to be read back
    /// before anything is written, or the merge would delete them.
    private func existingDates(of person: ABPerson) -> [(label: String?, value: DateComponents)] {
        guard let multi = person.value(forProperty: kABOtherDateComponentsProperty)
                as? ABMultiValue else { return [] }
        var out: [(label: String?, value: DateComponents)] = []
        for index in 0..<multi.count() {
            guard let components = multi.value(at: index) as? NSDateComponents else { continue }
            // AddressBook stores an unlabelled value as the empty string, which
            // Contacts reads back as no label at all.
            let label = multi.label(at: index)
            out.append((label?.isEmpty == true ? nil : label, components as DateComponents))
        }
        return out
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
    var urls: [(label: String?, value: String)] {
        url.map { raw in
            let (label, value) = splitURL(raw)
            return (label.map(Labels.url), value)
        }
    }
    var relations: [(label: String?, value: String)] { parse(relation, Labels.relation) }

    // The append-only counterparts. Parsed identically, so a label behaves the
    // same whichever flag carried it.
    var addedEmails: [(label: String?, value: String)] { parse(addEmail, Labels.email) }
    var addedPhones: [(label: String?, value: String)] { parse(addPhone, Labels.phone) }
    var addedUrls: [(label: String?, value: String)] {
        addUrl.map { raw in
            let (label, value) = splitURL(raw)
            return (label.map(Labels.url), value)
        }
    }

    /// Everything this edit intends the contact to end up holding, replacing and
    /// appending alike.
    ///
    /// 🛑 The post-write check reads these, not the raw flags. A value added
    /// with `--add-email` has to be confirmed as hard as one set with `--email`.
    var allEmails: [(label: String?, value: String)] { emails + addedEmails }
    var allPhones: [(label: String?, value: String)] { phones + addedPhones }
    var allUrls: [(label: String?, value: String)] { urls + addedUrls }

    /// ⚠️ Parsed here rather than in `apply`, so a bad address is caught by
    /// `validate()` before any Apple Event and before the AddressBook fallback
    /// can see it. Both write paths and the post-write check then read the same
    /// values, which is the rule `parse` was written for.
    var addresses: [(label: String?, value: CNMutablePostalAddress)] {
        parse(address, Labels.address).compactMap { entry in
            (try? PostalAddress.parse(entry.value)).map { (entry.label, $0) }
        }
    }

    var addedAddresses: [(label: String?, value: CNMutablePostalAddress)] {
        parse(addAddress, Labels.address).compactMap { entry in
            (try? PostalAddress.parse(entry.value)).map { (entry.label, $0) }
        }
    }
    var allAddresses: [(label: String?, value: CNMutablePostalAddress)] {
        addresses + addedAddresses
    }

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

        guard !fields.isEmpty || fields.hasNoteChange else {
            throw ValidationError("nothing to create; pass at least one field, e.g. --first / --last")
        }
        // A note has nowhere to go until the record exists, and a card with
        // nothing but a note is not a contact anyone can find again.
        if fields.isEmpty {
            throw ValidationError(
                "a note needs a contact to sit on; pass a name too, e.g. --first / --last")
        }
        if fields.clearNote {
            throw ValidationError("--clear-note has nothing to clear on a new contact.")
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

        // 🛑 **A note is a SECOND write, through a different application, and
        // the contact already exists by the time it can fail.** So read a
        // failure here as "created, but the note did not land" — never as
        // "nothing happened". `apple reminders` reports a failed tag the same
        // way, for the same reason.
        if let request = fields.noteRequest {
            let backing = (try? containerContact(withId: draft.identifier))?.identifier
                ?? draft.identifier
            // A brand-new contact has no note, so what it should end up holding
            // is fully determined here — no read of the store is involved.
            let wanted = request.applied(to: nil)
            do {
                let written = try NoteWriter.apply(request, toContactId: backing)
                guard written == wanted else {
                    throw RuntimeError(
                        "Contacts.app saved \(written.count) characters where "
                        + "\(wanted.count) were asked for.")
                }
            } catch {
                throw RuntimeError(
                    """
                    Created '\(displayName(draft))' (id: \(draft.identifier)), but the note \
                    did not land: \(error.localizedDescription)
                    The contact exists. Add the note with `apple-contacts edit \
                    \(draft.identifier) --note ...`.
                    """)
            }
        }

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

        guard !fields.isEmpty || fields.hasNoteChange else {
            throw ValidationError(
                "nothing to change; pass at least one field, e.g. --company or --email")
        }

        let existing = try contact(withId: id)
        // 🛑 Before any write. A removal that matches nothing is a typo, and a
        // replace that discards values should say what it is about to destroy.
        try fields.preflight(against: existing)

        // A note-only edit skips the Contacts save entirely. Running it would
        // change nothing, and on a contact that already carries a note it would
        // trip the note wall and take the AddressBook fallback for no reason.
        if !fields.isEmpty {
            try saveFields(on: existing)
        }

        // 🛑 **After the fields, never before.** The note write launches
        // Contacts.app, which then holds the same records open; doing it first
        // made the ordinary save race a live editor. This order also means a
        // failed note write leaves the field changes in place, which is what the
        // error says.
        if let request = fields.noteRequest {
            try writeNote(request, on: existing)
        }

        let refreshed = try contact(withId: id)
        try confirmWritten(fields, on: refreshed, name: displayName(refreshed))
        if json {
            printJSON(info(refreshed, notes: NoteStore.allNotes()))
        } else {
            print("Updated '\(displayName(refreshed))'")
        }
    }

    /// Apply the note change through Contacts.app, then confirm it landed.
    ///
    /// ⚠️ **Confirmed twice, from two different readers.** Contacts.app returns
    /// what it wrote, and `NoteStore` re-reads the AddressBook SQLite store.
    /// Measured on both a local and an iCloud contact: the store is current the
    /// instant the write returns, five writes out of five with no delay. That
    /// only holds because `NoteStore` stopped opening with `immutable=1` in
    /// 26.812.8 — before that fix it could not see a note written seconds
    /// earlier, and this check would have been a coin flip.
    private func writeNote(_ request: NoteWriter.Request, on existing: CNContact) throws {
        // The container-backed id, not whatever was passed: AppleScript
        // addresses the AddressBook record, which has none under a unified
        // identifier. Same rule `editViaAddressBook` follows.
        let backing = (try? containerContact(withId: id))?.identifier ?? id
        let wanted = request.applied(to: NoteStore.allNotes()[existing.identifier])

        let written = try NoteWriter.apply(request, toContactId: backing)
        guard written == wanted else {
            throw RuntimeError(
                "Contacts.app saved a different note than asked for on "
                + "'\(displayName(existing))': wanted \(wanted.count) characters, "
                + "it holds \(written.count).")
        }

        let stored = NoteStore.allNotes()[existing.identifier] ?? ""
        guard stored == wanted else {
            throw RuntimeError(
                """
                Contacts.app reported the note write on '\(displayName(existing))', but the \
                AddressBook store holds \(stored.count) characters where \(wanted.count) were \
                asked for. The write may not have committed. Check the contact in Contacts.app.
                """)
        }
    }

    /// The ordinary field save, with the note wall's AddressBook fallback.
    private func saveFields(on existing: CNContact) throws {
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
func groupNames(for contactId: String) -> [String] {
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
        // store and no amount of waiting changes that. It is no longer a dead
        // end, though — `apple contacts move` relocates the record between
        // accounts keeping its id, which is what this message points at. It is
        // deliberately not done automatically: a move drops every group
        // membership in the account being left, and that is the caller's call.
        let memberContainer = containerId(forContact: member.identifier)
        let groupContainer = containerId(forGroup: target.identifier)
        if let memberContainer, let groupContainer, memberContainer != groupContainer {
            throw RuntimeError(
                """
                cannot add '\(displayName(member))' to '\(target.name)': they are in different \
                accounts, and one save cannot span two.
                  contact: \(describeContainer(memberContainer))
                  group:   \(describeContainer(groupContainer))
                Move the contact into the group's account, then retry:
                  apple contacts move \(member.identifier) --to "\(groupContainer)" --dry-run
                ⚠️ a move drops every group membership in the account it leaves, so run the \
                dry-run first. Alternatively create the contact in the right account to begin \
                with: apple contacts add --container "\(groupContainer)" …
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

func displayName(_ contact: CNContact) -> String {
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

// MARK: - Relations between contacts

/// 🛑 **A relation stores a NAME, not a reference.** Measured on this store: all
/// 54 relation rows carry a `ZUNIQUEID`, all 54 are distinct, and none matches
/// any contact record — that column is the relation row's own sync id.
///
/// So "who is this person connected to" is a name lookup done at read time, and
/// it can return nothing or several people. Both are normal, not corruption.

/// One relation, with whoever the name resolves to.
struct RelationLink: Encodable {
    let label: String?
    let name: String
    /// The contact this name matches, when exactly one does.
    let contactId: String?
    /// How many contacts the name matched. `0` and `2+` are both real answers.
    let matches: Int

    enum CodingKeys: String, CodingKey {
        case label, name, matches
        case contactId = "contact_id"
    }
}

struct ReverseLink: Encodable {
    let label: String?
    /// The contact who names this person.
    let contactId: String
    let name: String

    /// ⚠️ snake_case, matching `RelationLink` and every other id key here.
    /// The synthesized encoder emits `contactId`, which reads as a different
    /// field to anything parsing the output.
    enum CodingKeys: String, CodingKey {
        case label, name
        case contactId = "contact_id"
    }
}

struct RelationReport: Encodable {
    let id: String
    let name: String
    let relations: [RelationLink]
    /// ⚠️ Contacts has no reverse index, so this is a scan of every card. It is
    /// the half people actually want — "who thinks I am their father" — and it
    /// cannot be answered any other way.
    let relatedFrom: [ReverseLink]

    enum CodingKeys: String, CodingKey {
        case id, name, relations
        case relatedFrom = "related_from"
    }
}

/// Contacts whose display name matches `name` exactly, ignoring case.
///
/// ⚠️ Exact, not partial. A relation names a whole person, and a partial match
/// would link `Dan` to `Danielle`.
private func contactsNamed(_ name: String, in everyone: [CNContact]) -> [CNContact] {
    let needle = name.lowercased().trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return [] }
    return everyone.filter { displayName($0).lowercased() == needle }
}

struct Relations: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show who a contact is connected to",
        discussion: """
          Resolves each relation's name against the address book, and also scans
          for anyone who names this contact.

          🛑 A relation stores a NAME, not a link. Renaming a contact silently
          breaks every relation pointing at it, a relation can match nobody, and
          it can match several people. `matches` reports which.
          """)

    @Argument(help: "Contact id, from `search --json`")
    var id: String

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let subject = try contact(withId: id)
        let everyone = try allContacts()
        let subjectName = displayName(subject)

        let relations = subject.contactRelations.map { entry -> RelationLink in
            let matched = contactsNamed(entry.value.name, in: everyone)
            return RelationLink(
                label: Labels.decode(entry.label),
                name: entry.value.name,
                contactId: matched.count == 1 ? matched[0].identifier : nil,
                matches: matched.count)
        }

        // The reverse half. No index exists, so this is a full scan.
        var reverse: [ReverseLink] = []
        for other in everyone where other.identifier != subject.identifier {
            for entry in other.contactRelations
            where entry.value.name.lowercased() == subjectName.lowercased() {
                reverse.append(ReverseLink(
                    label: Labels.decode(entry.label),
                    contactId: other.identifier,
                    name: displayName(other)))
            }
        }

        let report = RelationReport(
            id: subject.identifier, name: subjectName,
            relations: relations, relatedFrom: reverse)

        if json {
            printJSON(report)
            return
        }

        print(subjectName)
        if relations.isEmpty {
            print("  (no relations)")
        }
        for link in relations {
            let label = link.label.map { "\($0): " } ?? ""
            switch link.matches {
            case 1:
                print("  \(label)\(link.name)  [\(link.contactId ?? "")]")
            case 0:
                print("  \(label)\(link.name)  (no contact with that name)")
            default:
                print("  \(label)\(link.name)  (\(link.matches) contacts share that name)")
            }
        }
        if !reverse.isEmpty {
            print("Named by:")
            for link in reverse {
                let label = link.label.map { "\($0): " } ?? ""
                print("  \(link.name) \(label.isEmpty ? "" : "(\(label.dropLast(2)))")  [\(link.contactId)]")
            }
        }
    }
}

/// Resolves a contact from an id or a name, refusing ambiguity.
///
/// ⚠️ **An ambiguous name is an error listing the candidates, never a guess.**
/// Same rule `apple messages` applies to a chat and `apple maps` to a guide.
/// Writing a relation onto the wrong card is a mistake nobody notices for
/// months.
private func resolveOne(_ reference: String, verb: String) throws -> CNContact {
    if let found = try? contact(withId: reference) { return found }

    let everyone = try allContacts()
    let exact = contactsNamed(reference, in: everyone)
    let candidates = exact.isEmpty
        ? everyone.filter { matches($0, reference.lowercased()) }
        : exact

    switch candidates.count {
    case 1:
        return candidates[0]
    case 0:
        throw ValidationError("no contact matches '\(reference)'")
    default:
        let listed = candidates.prefix(10)
            .map { "  \(displayName($0))  [\($0.identifier)]" }
            .joined(separator: "\n")
        throw ValidationError("""
            '\(reference)' matches \(candidates.count) contacts; refusing to \
            \(verb) without knowing which.
            \(listed)
            Pass the id.
            """)
    }
}

/// Compares two relation labels the way a human means them.
///
/// 🛑 **Raw labels are stored in two spellings and both are live.** This store
/// holds `_$!<Father>!$_` on one card and a plain `Sibling` on another, and
/// `Labels.decode` passes an unrecognised bare word through unchanged, capital
/// letters and all. So comparing raw labels — or comparing an encoded label
/// against a stored one — misses real matches.
///
/// Measured: `link Dan Mark --relation father` reported "would add" for a
/// relation Dan already had, because `_$!<Father>!$_` != `Father`. A second run
/// would have written a duplicate.
private func sameRelationLabel(_ raw: String?, _ plain: String) -> Bool {
    let stored = Labels.decode(raw) ?? raw ?? ""
    return RelationGraph.normalize(stored) == RelationGraph.normalize(plain)
}

struct RelationChange: Encodable {
    let contactId: String
    let name: String
    let label: String
    let other: String
    let changed: Bool

    enum CodingKeys: String, CodingKey {
        case name, label, other, changed
        case contactId = "contact_id"
    }
}

/// Writes one contact's relation list, appending rather than replacing.
///
/// 🛑 **`--relation` replaces the whole set**, which is right for `edit` and
/// wrong for adding one link. Getting a relation onto a card with `edit` means
/// reading every existing relation and re-passing it, and forgetting one
/// deletes it silently. That is the whole reason `link` exists.
///
/// ⚠️ Writes the **container-backed** record, not the unified merge — the same
/// rule group membership follows, and for the same reason.
private func writeRelations(
    _ relations: [CNLabeledValue<CNContactRelation>], on subject: CNContact
) throws {
    let backing = (try? containerContact(withId: subject.identifier)) ?? subject
    guard let mutable = backing.mutableCopy() as? CNMutableContact else {
        throw RuntimeError("could not open '\(displayName(subject))' for writing")
    }
    mutable.contactRelations = relations
    let request = CNSaveRequest()
    request.update(mutable)
    do {
        try store.execute(request)
    } catch where isNotePropertyFault(error) {
        // 🛑 **A note on the card blocks every `CNContactStore` write to it**,
        // relations included — the save faults the whole record and faulting
        // reads the note. `edit` and `groups add` already route around this
        // through the legacy AddressBook framework; `link` and `unlink` did
        // not, so 52 of the 669 contacts here could not be linked at all and
        // the only signal was a bare `NSCocoaErrorDomain 134092`.
        //
        // ⚠️ `link` writes two cards. It writes the first card first, so a
        // failure here left BOTH sides unwritten rather than half-written.
        try writeRelationsViaAddressBook(id: backing.identifier, relations: relations)
    }
}

/// The same relation write, expressed against the legacy AddressBook record.
///
/// Reached only when `CNContactStore` refuses the save because the contact
/// carries a note — see `editViaAddressBook`, which this mirrors. AddressBook
/// stores a relation under `kABRelatedNamesProperty` with the identical
/// `_$!<Father>!$_` label spellings, so nothing is translated.
///
/// ⚠️ **The first save fails and the second one works**, exactly as it does for
/// an edit: faulting trips the note wall once and the pending changes then
/// commit. A lone failure here means nothing, which is why `link` re-reads the
/// contact afterwards instead of trusting any return value.
private func writeRelationsViaAddressBook(
    id: String, relations: [CNLabeledValue<CNContactRelation>]
) throws {
    guard let book = ABAddressBook.shared() else {
        throw RuntimeError("could not open the AddressBook store.")
    }
    guard let person = book.record(forUniqueId: id) as? ABPerson else {
        throw RuntimeError("no contact with id '\(id)' in the AddressBook store.")
    }

    let multi = ABMutableMultiValue()
    for entry in relations {
        // AddressBook has no nil label; the empty string is what it stores for
        // an unlabelled value, and Contacts reads that back as no label.
        _ = multi.add(entry.value.name as NSString, withLabel: entry.label ?? "")
    }
    guard person.setValue(multi, forProperty: kABRelatedNamesProperty) else {
        throw RuntimeError("the AddressBook store refused the relation list.")
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

struct Link: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Link two contacts to each other",
        discussion: """
          Appends a relation, unlike `edit --relation`, which replaces the whole
          set. Both contacts may be named by id or by name; an ambiguous name is
          refused listing the candidates.

          `link A B --relation manager` reads "B is A's manager", so the label
          describes the SECOND contact.

          By default the inverse is written onto the other card too, so the link
          reads correctly from both sides: that example also gives B an
          `assistant` relation naming A. --no-inverse writes one side only.

          🛑 The inverse is only inferred where it is unambiguous. `spouse` and
          `friend` are symmetric; `parent` inverts to `child`. `father` does NOT
          invert, because the other side is son or daughter and Contacts does
          not record gender — pass --inverse to say which.

          Examples:
            apple-contacts link "Dan Hopkins" "Ross Hopkins" --as brother --inverse brother
            apple-contacts link <id> <id> --as spouse
            apple-contacts link <id> <id> --as father --inverse son
          """)

    @Argument(help: "The contact whose card names the other (id or name)")
    var subject: String

    @Argument(help: "The contact being named (id or name)")
    var other: String

    @Option(
        name: .long,
        help: """
          How B relates to A: `link A B --relation manager` means B is A's           manager. e.g. brother, spouse, parent, manager.
          """)
    var relation: String

    @Option(name: .long, help: "The label for the other card. Inferred when unambiguous.")
    var inverse: String?

    @Flag(name: .long, help: "Write only one side")
    var noInverse = false

    @Flag(
        name: .long,
        help: """
          Take the second argument as a plain name, for somebody who has no \
          contact card. One side only, since there is no card to write back to.
          """)
    var nameOnly = false

    @Flag(name: .long, help: "Show what would change without writing")
    var dryRun = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let first = try resolveOne(subject, verb: "link")

        // 🛑 **A relation stores a NAME, not a reference**, so a card can name
        // somebody who has no card of their own — a spouse who died before the
        // address book existed, a relative nobody has contact details for. Two
        // such relations already exist on this store, and they are not
        // corruption.
        //
        // Before this flag the only route was `edit --relation`, which
        // **replaces the whole set**: adding one meant reading every existing
        // relation and re-passing it, and forgetting one deleted it silently.
        // That is the exact trap `link` was built to close, and it stayed open
        // for the one case where the other party is not a contact.
        //
        // 🛑 **It is opt-in, and that is deliberate.** Falling back to a plain
        // name whenever the second argument fails to resolve would turn a typo
        // in a real contact's name into a dangling relation, silently — the
        // opposite of the rule every other name lookup here follows, where an
        // unmatched or ambiguous name is refused rather than guessed.
        if nameOnly {
            guard inverse == nil else {
                throw ValidationError(
                    "--inverse cannot be used with --name-only: there is no card "
                    + "to write the other side onto.")
            }
            let plain = other.trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else {
                throw ValidationError("--name-only needs a name to record")
            }
            try linkToName(first, name: plain)
            return
        }

        let second = try resolveOne(other, verb: "link")

        guard first.identifier != second.identifier else {
            throw ValidationError("a contact cannot be linked to itself")
        }

        let firstName = displayName(first)
        let secondName = displayName(second)

        // Decide the inverse before writing anything, so a refusal costs nothing.
        var inverseLabel: String?
        if !noInverse {
            if let explicit = inverse {
                inverseLabel = explicit
            } else if let inferred = RelationGraph.inverse(of: relation) {
                inverseLabel = inferred
            } else {
                let suggestions = RelationGraph.inverseSuggestions(for: relation)
                let hint = suggestions.isEmpty
                    ? "Pass --inverse LABEL, or --no-inverse to write one side only."
                    : "Pass --inverse "
                        + suggestions.joined(separator: "/")
                        + ", or --no-inverse to write one side only."
                throw ValidationError(
                    RelationGraph.ambiguityReason(for: relation) + ".\n" + hint)
            }
        }

        func plan(on person: CNContact, label: String, naming name: String)
            -> (relations: [CNLabeledValue<CNContactRelation>], changed: Bool)
        {
            let encoded = Labels.relation(label)
            var existing = person.contactRelations
            // ⚠️ Re-linking is a reported no-op, not an error and not a
            // duplicate row. Same shape `groups add` uses.
            let already = existing.contains {
                sameRelationLabel($0.label, label)
                    && $0.value.name.lowercased() == name.lowercased()
            }
            if !already {
                existing.append(CNLabeledValue(
                    label: encoded, value: CNContactRelation(name: name)))
            }
            return (existing, !already)
        }

        var changes: [RelationChange] = []
        let forward = plan(on: first, label: relation, naming: secondName)
        changes.append(RelationChange(
            contactId: first.identifier, name: firstName,
            label: relation, other: secondName, changed: forward.changed))

        var back: (relations: [CNLabeledValue<CNContactRelation>], changed: Bool)?
        if let inverseLabel {
            back = plan(on: second, label: inverseLabel, naming: firstName)
            changes.append(RelationChange(
                contactId: second.identifier, name: secondName,
                label: inverseLabel, other: firstName, changed: back!.changed))
        }

        if dryRun {
            if json { printJSON(changes) } else { report(changes, dryRun: true) }
            return
        }

        if forward.changed { try writeRelations(forward.relations, on: first) }
        if let back, back.changed { try writeRelations(back.relations, on: second) }

        // 🛑 Confirm through a fresh store. `CNSaveRequest` reporting success is
        // not evidence the change persisted — `groups remove` saves without
        // error and changes nothing at all on an iCloud group.
        try confirmLinked(changes)

        if json { printJSON(changes) } else { report(changes, dryRun: false) }
    }

    /// Record a relation naming somebody with no contact card.
    ///
    /// One card only, by construction. ⚠️ Nothing can confirm the other side,
    /// because there is no other side — so the read-back check covers the
    /// subject alone, which is all this write touches.
    private func linkToName(_ subject: CNContact, name: String) throws {
        let subjectName = displayName(subject)
        let encoded = Labels.relation(relation)
        var existing = subject.contactRelations
        let already = existing.contains {
            sameRelationLabel($0.label, relation)
                && $0.value.name.lowercased() == name.lowercased()
        }
        if !already {
            existing.append(CNLabeledValue(
                label: encoded, value: CNContactRelation(name: name)))
        }

        let change = RelationChange(
            contactId: subject.identifier, name: subjectName,
            label: relation, other: name, changed: !already)

        if dryRun {
            if json { printJSON([change]) } else { report([change], dryRun: true) }
            return
        }
        if !already { try writeRelations(existing, on: subject) }
        try confirmLinked([change])

        if json {
            printJSON([change])
        } else {
            report([change], dryRun: false)
            // ⚠️ Say it plainly. A relation that resolves to nobody looks like a
            // failure the next time anyone reads the card, and it is not.
            print("Note: no contact is named '\(name)'. "
                  + "The relation records the name only.")
        }
    }

    private func report(_ changes: [RelationChange], dryRun: Bool) {
        for change in changes {
            let verb = change.changed ? (dryRun ? "would add" : "added") : "already had"
            print("\(change.name): \(verb) \(change.label) -> \(change.other)")
        }
        if dryRun { print("Nothing was written.") }
    }
}

extension Unlink {
    /// Remove a relation naming somebody with no contact card.
    ///
    /// One card only. ⚠️ Matching is on the name as stored, case-insensitively,
    /// and on the label when `--relation` is given — the same rule the two-card
    /// path uses for its own side.
    fileprivate func unlinkName(_ subject: CNContact, name: String) throws {
        let subjectName = displayName(subject)
        var gone: [String] = []
        let kept = subject.contactRelations.filter { entry in
            let sameName = entry.value.name.lowercased() == name.lowercased()
            let sameLabel = relation.map { sameRelationLabel(entry.label, $0) } ?? true
            if sameName && sameLabel {
                gone.append(Labels.decode(entry.label) ?? "(unlabelled)")
                return false
            }
            return true
        }

        guard !gone.isEmpty else {
            let what = relation.map { "'\($0)' relation" } ?? "relation"
            throw ValidationError(
                "'\(subjectName)' has no \(what) naming '\(name)'")
        }

        let changes = gone.map {
            RelationChange(contactId: subject.identifier, name: subjectName,
                           label: $0, other: name, changed: true)
        }
        if dryRun {
            if json { printJSON(changes) } else {
                for c in changes { print("\(c.name): would remove \(c.label) -> \(c.other)") }
                print("Nothing was written.")
            }
            return
        }
        try writeRelations(kept, on: subject)
        try confirmUnlinked(changes)
        if json { printJSON(changes) } else {
            for c in changes { print("\(c.name): removed \(c.label) -> \(c.other)") }
        }
    }
}

/// Re-reads each card from a fresh store and fails loudly if it does not hold
/// what was asked for.
private func confirmLinked(_ changes: [RelationChange]) throws {
    let fresh = CNContactStore()
    var missing: [String] = []
    for change in changes {
        let contact = try? fresh.unifiedContact(
            withIdentifier: change.contactId, keysToFetch: readKeys)
        let holds = contact?.contactRelations.contains {
            sameRelationLabel($0.label, change.label)
                && $0.value.name.lowercased() == change.other.lowercased()
        } ?? false
        if !holds {
            missing.append("\(change.name): \(change.label) -> \(change.other)")
        }
    }
    guard missing.isEmpty else {
        throw RuntimeError("""
            the save reported success but the store does not hold:
            \(missing.map { "  \($0)" }.joined(separator: "\n"))
            """)
    }
}

/// The counterpart to `confirmLinked`: check the relation really went.
///
/// 🛑 **`unlink` did not confirm anything before this.** Every other write in
/// this tool re-reads a fresh store, because `CNSaveRequest` reporting success
/// is not evidence — `groups remove` saves without error and changes nothing at
/// all on an iCloud group. A removal had the same exposure and no guard.
private func confirmUnlinked(_ changes: [RelationChange]) throws {
    let fresh = CNContactStore()
    var survived: [String] = []
    for change in changes {
        let contact = try? fresh.unifiedContact(
            withIdentifier: change.contactId, keysToFetch: readKeys)
        let stillThere = contact?.contactRelations.contains {
            sameRelationLabel($0.label, change.label)
                && $0.value.name.lowercased() == change.other.lowercased()
        } ?? false
        if stillThere {
            survived.append("\(change.name): \(change.label) -> \(change.other)")
        }
    }
    guard survived.isEmpty else {
        throw RuntimeError("""
            the save reported success but the store still holds:
            \(survived.map { "  \($0)" }.joined(separator: "\n"))
            """)
    }
}

struct Unlink: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a relation between two contacts",
        discussion: """
          Removes the relation naming the other contact, from both cards by
          default.

          --relation narrows it to one label, and the OTHER card is matched on
          that label's inverse: `--relation parent` removes `parent` from A and
          `child` from B. When the inverse cannot be inferred — the gendered
          labels — the other card is left alone and the command says so, rather
          than clearing a relation it had to guess at.
          """)

    @Argument(help: "The contact whose card names the other (id or name)")
    var subject: String

    @Argument(help: "The contact being named (id or name)")
    var other: String

    @Option(
        name: .long,
        help: "Only remove this label. The other card is matched on its inverse.")
    var relation: String?

    @Flag(name: .long, help: "Leave the other card alone")
    var noInverse = false

    @Flag(
        name: .long,
        help: """
          Take the second argument as a plain name, for a relation naming \
          somebody who has no contact card.
          """)
    var nameOnly = false

    @Flag(name: .long, help: "Show what would change without writing")
    var dryRun = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireContactsAccess()
        let first = try resolveOne(subject, verb: "unlink")

        // The counterpart to `link --name-only`. Without it a relation naming a
        // non-contact could be written and never removed, since `unlink` resolved
        // both arguments and refused an unmatched name.
        if nameOnly {
            let plain = other.trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else {
                throw ValidationError("--name-only needs a name to remove")
            }
            try unlinkName(first, name: plain)
            return
        }

        let second = try resolveOne(other, verb: "unlink")
        let firstName = displayName(first)
        let secondName = displayName(second)

        // 🛑 **The other card carries the INVERSE label, not the same one.**
        // Filtering both sides on `--relation parent` removed `parent` from one
        // card and left `child` on the other, while the command reported that it
        // had removed both. Measured on real fixtures.
        //
        // ⚠️ When the inverse cannot be inferred — the gendered labels — the
        // other card is left alone rather than cleared on a guess. Removing
        // "any relation naming this person" would take an unrelated one they
        // also carry.
        var otherLabel: String?
        var otherSkipped = false
        if let relation {
            if let inferred = RelationGraph.inverse(of: relation) {
                otherLabel = inferred
            } else if !noInverse {
                otherSkipped = true
            }
        }

        func plan(on person: CNContact, naming name: String, label: String?)
            -> (relations: [CNLabeledValue<CNContactRelation>], gone: [String])
        {
            var gone: [String] = []
            let kept = person.contactRelations.filter { entry in
                let sameName = entry.value.name.lowercased() == name.lowercased()
                let sameLabel = label.map { sameRelationLabel(entry.label, $0) } ?? true
                if sameName && sameLabel {
                    gone.append(Labels.decode(entry.label) ?? "(unlabelled)")
                    return false
                }
                return true
            }
            return (kept, gone)
        }

        var removed: [RelationChange] = []
        let forward = plan(on: first, naming: secondName, label: relation)
        for label in forward.gone {
            removed.append(RelationChange(
                contactId: first.identifier, name: firstName,
                label: label, other: secondName, changed: true))
        }

        var back: (relations: [CNLabeledValue<CNContactRelation>], gone: [String])?
        if !noInverse && !otherSkipped {
            back = plan(on: second, naming: firstName, label: otherLabel)
            for label in back!.gone {
                removed.append(RelationChange(
                    contactId: second.identifier, name: secondName,
                    label: label, other: firstName, changed: true))
            }
        }

        if otherSkipped, let relation {
            FileHandle.standardError.write(Data("""
                note: \(RelationGraph.ambiguityReason(for: relation)), so \
                '\(secondName)' was left alone.
                      Clear that side with: apple contacts unlink \
                <their id> <this id> --relation <label>

                """.utf8))
        }

        guard !removed.isEmpty else {
            let suffix = relation.map { " labelled \($0)" } ?? ""
            print("No relation between '\(firstName)' and '\(secondName)'\(suffix).")
            if json { printJSON([RelationChange]()) }
            return
        }

        if dryRun {
            if json { printJSON(removed) } else {
                for change in removed {
                    print("\(change.name): would remove \(change.label) -> \(change.other)")
                }
                print("Nothing was written.")
            }
            return
        }

        if !forward.gone.isEmpty { try writeRelations(forward.relations, on: first) }
        if let back, !back.gone.isEmpty { try writeRelations(back.relations, on: second) }
        try confirmUnlinked(removed)

        if json { printJSON(removed) } else {
            for change in removed {
                print("\(change.name): removed \(change.label) -> \(change.other)")
            }
        }
    }
}
