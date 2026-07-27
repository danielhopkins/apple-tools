import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import Contacts
import Foundation

private let store = CNContactStore()
private let settingsPath = "System Settings → Privacy & Security → Contacts"

// MARK: - Access

/// Prompts for (or confirms) Contacts access. Called inside each command so
/// `--help` works without a grant.
func requireContactsAccess() throws {
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
}

private func blankToNil(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return value
}

private func info(
    _ contact: CNContact, notes: [String: String], groups: [String] = []
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
        contact_url: "addressbook://\(contact.identifier)")
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
          """,
        version: appleToolsVersion,
        subcommands: [Search.self, Get.self, List.self, Add.self, Edit.self, Delete.self,
                      Groups.self, Status.self],
        defaultSubcommand: Search.self)

    static func plainText(_ contacts: [ContactInfo]) -> String { plain(contacts) }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report Contacts permission state without requesting it")

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() {
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
        output.emit([info(match, notes: NoteStore.allNotes(), groups: groupNames(for: id))])
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
    private func split(_ input: String) -> (label: String?, value: String) {
        guard let separator = input.firstIndex(of: ":") else { return (nil, input) }
        let label = String(input[input.startIndex..<separator])
        let value = String(input[input.index(after: separator)...])
        return (label.isEmpty ? nil : label, value)
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

        if !email.isEmpty {
            contact.emailAddresses = email.map { raw in
                let (label, value) = split(raw)
                return CNLabeledValue(label: label.flatMap(Labels.email), value: value as NSString)
            }
        }
        if !phone.isEmpty {
            contact.phoneNumbers = phone.map { raw in
                let (label, value) = split(raw)
                return CNLabeledValue(
                    label: label.flatMap(Labels.phone), value: CNPhoneNumber(stringValue: value))
            }
        }
        if !url.isEmpty {
            contact.urlAddresses = url.map { raw in
                let (label, value) = split(raw)
                return CNLabeledValue(label: label.flatMap(Labels.url), value: value as NSString)
            }
        }
        if !relation.isEmpty {
            contact.contactRelations = relation.map { raw in
                let (label, value) = split(raw)
                return CNLabeledValue(
                    label: label.map(Labels.relation),
                    value: CNContactRelation(name: value))
            }
        }

        // --anniversary is sugar for a labelled date, so merge the two inputs.
        var dateEntries = date
        if let anniversary { dateEntries.append("anniversary:\(anniversary)") }
        if !dateEntries.isEmpty {
            contact.dates = dateEntries.compactMap { raw in
                let (label, value) = split(raw)
                guard let components = ContactDate.parse(value) else { return nil }
                return CNLabeledValue(
                    label: label.map(Labels.date),
                    value: components as NSDateComponents)
            }
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
        request.add(draft, toContainerWithIdentifier: container)
        try store.execute(request)

        if json {
            // Re-read so the output reflects what the store actually saved.
            let saved = try contact(withId: draft.identifier)
            printJSON(info(saved, notes: NoteStore.allNotes()))
        } else {
            print("Created '\(displayName(draft))' (id: \(draft.identifier))")
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
        try store.execute(request)

        let refreshed = try contact(withId: id)
        if json {
            printJSON(info(refreshed, notes: NoteStore.allNotes()))
        } else {
            print("Updated '\(displayName(refreshed))'")
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
        let infos = groups.map { group -> GroupInfo in
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
            let members = (try? store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
            return GroupInfo(id: group.identifier, name: group.name, count: members.count)
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
        request.add(group, toContainerWithIdentifier: container)
        try store.execute(request)

        if json {
            printJSON(GroupInfo(id: group.identifier, name: group.name, count: 0))
        } else {
            print("Created group '\(name)' (id: \(group.identifier))")
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

    func run() throws {
        try requireContactsAccess()
        let target = try resolveGroup(group)
        let member = try contact(withId: contactId)

        let request = CNSaveRequest()
        request.addMember(member, to: target)
        try store.execute(request)
        print("Added '\(displayName(member))' to '\(target.name)'")
    }
}

struct GroupRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove a contact from a group (the contact is kept)")

    @Argument(help: "Group id or name")
    var group: String

    @Argument(help: "Contact id, from `search --json`")
    var contactId: String

    func run() throws {
        try requireContactsAccess()
        let target = try resolveGroup(group)
        let member = try contact(withId: contactId)

        let request = CNSaveRequest()
        request.removeMember(member, from: target)
        try store.execute(request)
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

// ArgumentParser has no coloured help, so generate it, style it, and print
// it here rather than letting .main() emit the plain version.
if let help = HelpColor.requested(root: AppleContacts.self, arguments: CommandLine.arguments) {
    print(help)
    exit(0)
}

AppleContacts.main()
