import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import Foundation
import PhoneLibrary

func warn(_ message: String) {
  FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

// MARK: - Rendering

enum Output {
  static let compactDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()

  static let isoDate: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func json(_ value: Any) throws {
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
  }

  /// `contactsResolved` false means the address book could not be read, so
  /// nothing here can speak to whether a caller is saved. The `known` key is
  /// then **omitted entirely** rather than emitted as `false` — following the
  /// same rule as an unlabelled contact email, and for a stronger reason: a
  /// hardcoded `false` would be a confident wrong answer that a consumer has no
  /// way to tell from a real one.
  static func encode(_ call: Call, contactsResolved: Bool) -> [String: Any] {
    var payload: [String: Any] = [
      "id": call.id,
      "status": call.status.rawValue,
      "kind": call.kind.rawValue,
      "handle": call.handle,
      "number": call.displayHandle,
      "duration": Int(call.duration.rounded()),
      "connected": call.connected,
      "blocked": call.isBlocked,
      "is_read": call.isRead,
      // Kept so a caller can see a type this tool did not recognise rather than
      // trusting `kind: unknown`.
      "call_type": call.rawCallType,
    ]
    if contactsResolved {
      payload["known"] = call.isKnown
    } else {
      payload["contacts_unavailable"] = true
    }
    if let date = call.date { payload["date"] = isoDate.string(from: date) }
    if let name = call.contactName { payload["name"] = name }
    if let id = call.contactID { payload["contact_id"] = id }
    if let stored = call.storedName { payload["stored_name"] = stored }
    if let location = call.location { payload["location"] = location }
    if let provider = call.serviceProvider { payload["service_provider"] = provider }
    if let category = call.junkCategory { payload["junk_category"] = category }
    if call.junkConfidence != 0 { payload["junk_confidence"] = call.junkConfidence }
    if let extensionName = call.blockedByExtension {
      payload["blocked_by_extension"] = extensionName
    }
    if let device = call.originatingDevice { payload["originating_device"] = device }
    if call.wasEmergency { payload["emergency"] = true }
    return payload
  }

  static func encode(_ item: BlockedItem) -> [String: Any] {
    var payload: [String: Any] = ["value": item.value, "kind": item.kind.rawValue]
    if item.kind == .phone { payload["number"] = PhoneNumber.display(item.value) }
    if let code = item.countryCode { payload["country_code"] = code }
    return payload
  }

  /// `1h 04m`, `4m 51s`, `12s`, or `—` when the call never connected.
  static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    guard total > 0 else { return "—" }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
    if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
    return "\(secs)s"
  }

  /// Longer form for totals, where "3h 20m" beats "200m".
  static func talkTime(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    guard total > 0 else { return "none" }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(total % 60)s" }
    return "\(total)s"
  }

  static func marker(for call: Call) -> String {
    switch call.status {
    case .outgoing: return Style.dim("→")
    case .incoming: return Style.success("←")
    case .missed: return Style.warning("✗")
    }
  }

  /// One call per line: direction, who, when, how long.
  static func line(_ call: Call, contactsResolved: Bool = true) {
    let when = call.date.map { compactDate.string(from: $0) } ?? "unknown date"
    let who = call.isKnown ? Style.title(call.who) : Style.title(call.displayHandle)

    var tags: [String] = []
    if call.kind != .phone { tags.append(Style.dim(call.kind.rawValue)) }
    // "unknown" means "not in your address book". With the address book
    // unreadable we did not check, so the tag is omitted rather than applied to
    // everything — the warning on stderr is what explains the missing names.
    if !call.isKnown && contactsResolved { tags.append(Style.dim("unknown")) }
    if call.isBlocked { tags.append(Style.warning("blocked")) }
    if call.status == .outgoing && !call.connected { tags.append(Style.dim("no answer")) }
    if call.wasEmergency { tags.append(Style.warning("emergency")) }

    print("\(marker(for: call))  \(who)  \(Style.time(when))  \(Style.dim(duration(call.duration)))")

    var detail: [String] = []
    // Show the number under a resolved name — the name alone is not enough to
    // act on, and the next step is usually to dial or block it.
    if call.isKnown { detail.append(Style.identifier(call.displayHandle)) }
    if let location = call.location { detail.append(Style.dim(location)) }
    detail.append(contentsOf: tags)
    if !detail.isEmpty { print("    \(detail.joined(separator: "  "))") }
  }
}

/// What to say when the address book cannot be read. Call history still reads
/// fine in that case — only names are missing — so this is a warning, not a
/// failure, and the commands that would give a *wrong* answer refuse separately.
let contactsUnreadableAdvice =
  "could not read the Contacts store, so callers cannot be named. Reading it needs Full Disk "
  + "Access for this terminal (System Settings → Privacy & Security → Full Disk Access)."

/// Opening the store is the same everywhere and the failure is almost always the
/// same missing grant, so the advice lives in one place.
func openStore(resolveContacts: Bool = true) throws -> CallStore {
  let store = try CallStore(resolveContacts: resolveContacts)
  if store.isStale {
    warn(
      "note: read the database without replaying its write-ahead log, so the most recent "
        + "calls may be missing.")
  }
  // Only the unreadable case warns. A Mac with no address book at all is not a
  // problem to report — every caller really is unknown there, and saying
  // "grant Full Disk Access" would send the user after a permission that is
  // already fine.
  if resolveContacts && store.contactAvailability == .unreadable {
    warn("warning: \(contactsUnreadableAdvice)")
  }
  return store
}

/// Refuse a filter whose answer would be silently wrong without contact names.
///
/// `--unknown` means "callers not in my address book". With an unreadable
/// address book every caller qualifies, so the command would return the whole
/// store and look like a complete, alarming answer. An empty address book is
/// different: there, everyone genuinely is unknown, and the filter is honest.
func requireContactResolution(_ store: CallStore, for flag: String) throws {
  guard store.contactAvailability == .unreadable else { return }
  throw ValidationError(
    "\(flag) needs contact names to mean anything, and \(contactsUnreadableAdvice)\n"
      + "Without it every caller would match, which is not the same as an answer.")
}

/// Shared by `recents` and `stats` so the two cannot drift on what a filter means.
struct FilterOptions: ParsableArguments {
  @Option(name: .long, help: "Only calls from the last N days")
  var since: Int?

  @Option(name: .long, help: "Only calls older than N days")
  var before: Int?

  @Flag(name: .long, help: "Only calls you missed")
  var missed = false

  @Flag(name: .long, help: "Only calls you received")
  var incoming = false

  @Flag(name: .long, help: "Only calls you placed")
  var outgoing = false

  @Flag(name: .long, help: "Only callers who are not in Contacts")
  var unknown = false

  @Flag(name: .long, help: "Only callers on your blocked list")
  var blockedOnly = false

  @Option(name: .long, help: "Restrict to phone, facetime-audio, or facetime-video")
  var kind: String?

  @Option(name: .long, help: "Restrict to one number or Apple ID")
  var handle: String?

  func build() throws -> RecentsRequest {
    let picked = [missed, incoming, outgoing].filter { $0 }.count
    guard picked <= 1 else {
      throw ValidationError("--missed, --incoming and --outgoing are mutually exclusive.")
    }

    var request = RecentsRequest()
    request.sinceDays = since
    request.beforeDays = before
    request.missedOnly = missed
    request.incomingOnly = incoming
    request.outgoingOnly = outgoing
    request.unknownOnly = unknown
    request.blockedOnly = blockedOnly
    request.handle = handle

    if let kind {
      guard let parsed = CallKind(rawValue: kind), parsed != .unknown else {
        throw ValidationError(
          "Unknown --kind '\(kind)'. Use phone, facetime-audio, or facetime-video.")
      }
      request.kind = parsed
    }
    return request
  }
}

// MARK: - Commands

struct ApplePhone: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "apple-phone",
    abstract: "Read call history and place calls",
    discussion: """
      Reads the call history store directly, so it works with Phone.app closed
      and answers in milliseconds. Reading it needs Full Disk Access for this
      terminal, which also covers resolving callers against Contacts.

      Phone.app has no AppleScript dictionary and no Shortcuts actions, so
      reading this store is the only route to call history. Everything here is
      read-only except `dial`, which hands a tel: URL to Phone.app and lets you
      confirm it.

      The store is a mirror of the iPhone's recent calls, not its whole history.
      """,
    version: appleToolsVersion,
    subcommands: [Recents.self, Search.self, Blocked.self, Stats.self, Dial.self, Status.self],
    defaultSubcommand: Recents.self
  )
}

struct Recents: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List recent calls, newest first",
    discussion: """
      Callers are resolved against Contacts, because the call history store does
      not keep names. `--unknown` narrows to the callers you have not saved,
      which is the shortest path from "who called me yesterday" to adding them.
      """
  )

  @OptionGroup var filters: FilterOptions

  @Option(name: .long, help: "Maximum calls to list")
  var limit: Int = 30

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    var request = try filters.build()
    request.limit = limit

    let store = try openStore()
    if filters.unknown { try requireContactResolution(store, for: "--unknown") }
    let calls = try store.recents(request)

    if json {
      try Output.json(calls.map { Output.encode($0, contactsResolved: store.contactsAvailable) })
      return
    }
    if calls.isEmpty {
      print("No calls found.")
      return
    }
    for call in calls { Output.line(call, contactsResolved: store.contactsAvailable) }
  }
}

struct Search: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Find calls by name, number, or place",
    discussion: """
      A query is an AND of terms matched as substrings, the same rule
      `apple mail` and `apple messages` use, so `denver missed` means both.

      Numbers match on their digits regardless of punctuation, so 3035551212,
      303-555-1212 and (303) 555-1212 all find the same calls. Names come from
      Contacts, so searching for a person works even though the store itself
      holds only their number.
      """
  )

  @Argument(help: "Name, number, or location to search for")
  var query: String

  @OptionGroup var filters: FilterOptions

  @Option(name: .long, help: "Maximum results")
  var limit: Int = 50

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    var request = try filters.build()
    request.query = query
    request.limit = limit

    let store = try openStore()
    if filters.unknown { try requireContactResolution(store, for: "--unknown") }
    let calls = try store.recents(request)

    if json {
      try Output.json(calls.map { Output.encode($0, contactsResolved: store.contactsAvailable) })
      return
    }
    if calls.isEmpty {
      print("No calls matched '\(query)'.")
      // A name search cannot work without the address book, and "no matches" is
      // the same output as a genuine miss — so say which this was.
      if store.contactAvailability == .unreadable {
        warn("note: \(contactsUnreadableAdvice) A search by person's name cannot match.")
      }
      return
    }
    for call in calls { Output.line(call, contactsResolved: store.contactsAvailable) }
  }
}

struct Blocked: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List blocked callers (read-only)",
    discussion: """
      Read straight from the block list store. This cannot be written: the API
      that adds an entry is gated behind com.apple.private.communicationsfilter,
      an Apple-internal entitlement, and it fails silently rather than erroring —
      so a `block` command here would report success and change nothing.

      Block a caller in Phone.app or in System Settings; it syncs from the
      iPhone, which is also what actually filters incoming calls.
      """
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let list = BlockList.load()

    if json {
      var payload: [String: Any] = [
        "blocked": list.items.map(Output.encode),
        "count": list.items.count,
        "path": list.path,
        "writable": false,
      ]
      if let revision = list.revision { payload["revision"] = revision }
      if let date = list.revisionDate {
        payload["revision_date"] = Output.isoDate.string(from: date)
      }
      try Output.json(payload)
      return
    }

    guard !list.items.isEmpty else {
      if list.isAvailable {
        print("No blocked callers.")
      } else {
        print("No block list on this Mac — nothing has ever been blocked.")
      }
      return
    }

    for item in list.items {
      let shown = item.kind == .phone ? PhoneNumber.display(item.value) : item.value
      var line = "\(Style.title(shown))"
      if item.kind != .phone { line += "  \(Style.dim(item.kind.rawValue))" }
      print(line)
    }
    print("")
    var footer = "\(list.items.count) blocked"
    if let revision = list.revision { footer += ", revision \(revision)" }
    if let date = list.revisionDate {
      footer += ", last changed \(Output.compactDate.string(from: date))"
    }
    print(Style.dim(footer))
  }
}

struct Stats: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Summarise call activity"
  )

  @OptionGroup var filters: FilterOptions

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let request = try filters.build()
    let store = try openStore()
    if filters.unknown { try requireContactResolution(store, for: "--unknown") }
    let stats = try store.statistics(request)
    let resolved = store.contactsAvailable

    if json {
      var payload: [String: Any] = [
        "total": stats.total,
        "outgoing": stats.outgoing,
        "incoming": stats.incoming,
        "missed": stats.missed,
        "talk_time_seconds": Int(stats.talkTime.rounded()),
        "by_kind": stats.byKind.map { ["kind": $0.kind.rawValue, "count": $0.count] },
      ]
      // `top_callers` stays either way — without names its `who` is a number,
      // which is a different label for the same true fact. `unknown_callers` is
      // a count of who is *missing* from the address book, so it is meaningless
      // when the address book could not be read, and is omitted rather than
      // reported as "everyone".
      payload["top_callers"] = stats.topCallers.map {
        ["who": $0.who, "calls": $0.count, "talk_time_seconds": Int($0.talkTime.rounded())]
      }
      if resolved {
        payload["unknown_callers"] = stats.unknownCallers
      } else {
        payload["contacts_unavailable"] = true
      }
      if let first = stats.firstCall { payload["first_call"] = Output.isoDate.string(from: first) }
      if let last = stats.lastCall { payload["last_call"] = Output.isoDate.string(from: last) }
      if let longest = stats.longest {
        payload["longest_call"] = Output.encode(longest, contactsResolved: resolved)
      }
      try Output.json(payload)
      return
    }

    guard stats.total > 0 else {
      print("No calls in that range.")
      return
    }

    print(Style.heading("Calls"))
    print("  \(Style.label("total"))      \(stats.total)")
    print("  \(Style.label("outgoing"))   \(stats.outgoing)")
    print("  \(Style.label("incoming"))   \(stats.incoming)")
    print("  \(Style.label("missed"))     \(stats.missed)")
    print("  \(Style.label("talk time"))  \(Output.talkTime(stats.talkTime))")
    if resolved, stats.unknownCallers > 0 {
      print("  \(Style.label("unknown"))    \(stats.unknownCallers) callers not in Contacts")
    }
    if !resolved {
      print("  \(Style.warning("contacts"))   unreadable, so callers are shown as numbers")
    }
    if let first = stats.firstCall, let last = stats.lastCall {
      print(
        "  \(Style.label("range"))      \(Output.compactDate.string(from: first)) → "
          + "\(Output.compactDate.string(from: last))")
    }

    if stats.byKind.count > 1 {
      print("")
      print(Style.heading("By kind"))
      for entry in stats.byKind {
        print("  \(Style.label(entry.kind.rawValue))  \(entry.count)")
      }
    }

    if !stats.topCallers.isEmpty {
      print("")
      print(Style.heading("Most frequent"))
      for caller in stats.topCallers {
        print(
          "  \(Style.title(caller.who))  \(Style.dim("\(caller.count) calls"))  "
            + "\(Style.dim(Output.talkTime(caller.talkTime)))")
      }
    }

    if let longest = stats.longest {
      print("")
      print(
        "\(Style.heading("Longest")) \(longest.who) — \(Output.duration(longest.duration))")
    }
  }
}

struct Dial: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Place a call by handing it to Phone.app",
    discussion: """
      Phone.app always asks you to confirm before it dials — skipping that prompt
      needs an Apple-internal entitlement no CLI can hold. That confirmation is
      the gate, so this command takes no --confirm of its own, and it will never
      click the panel for you.

      The number may be a contact name, in which case it is looked up in
      Contacts; an ambiguous name is an error rather than a guess.

      Use --dry-run to see the URL without placing anything.
      """
  )

  @Argument(help: "Number, contact name, or Apple ID to call")
  var target: String

  @Flag(name: .long, help: "Place a FaceTime Audio call instead of a phone call")
  var facetimeAudio = false

  @Flag(name: .long, help: "Print the URL that would be opened and stop")
  var dryRun = false

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let service: Dialer.Service = facetimeAudio ? .facetimeAudio : .phone

    // A bare name is the common case for someone you have saved, so resolve it
    // against the address book before treating the argument as a number.
    var handle = target
    var resolvedName: String?
    if PhoneNumber.digits(target).isEmpty && !PhoneNumber.isEmail(target) {
      let store = try openStore()

      // Dialing the wrong person is not recoverable, so an unresolvable name
      // must never fall through to "no such contact" when the real problem is
      // that the address book could not be read.
      switch store.contactAvailability {
      case .unreadable:
        throw ValidationError(
          "Cannot look up '\(target)' — \(contactsUnreadableAdvice)\n"
            + "Pass the number directly instead.")
      case .noAddressBook:
        throw ValidationError(
          "There is no address book on this Mac, so '\(target)' cannot be looked up. "
            + "Pass the number directly.")
      case .available:
        break
      }

      // A phone number is dialable by both services, so it is always preferred;
      // an Apple ID is only reachable over FaceTime.
      var entries = store.contactsNamed(target)
      if entries.isEmpty, facetimeAudio {
        entries = store.contactsNamed(target, email: true)
      }

      guard !entries.isEmpty else {
        throw ValidationError(
          "No number found for '\(target)'. Look it up with "
            + "`apple contacts search \"\(target)\"`, or pass the number.")
      }

      // Grouped by name, not by contact id. The same person routinely exists as
      // separate cards in more than one address book source — iCloud and "On My
      // Mac" — and grouping by id reported that as "more than one contact" while
      // listing a single name, which is not an answer anyone can act on.
      let names = Set(entries.map(\.name))
      guard names.count == 1 else {
        throw ValidationError(
          "'\(target)' matches more than one contact: \(names.sorted().joined(separator: ", ")). "
            + "Be more specific, or pass the number.")
      }

      // Duplicate cards mean duplicate numbers, so dedupe on the match key
      // before choosing. What is left is one person's set of distinct handles.
      var distinct: [ContactNumber] = []
      var seen = Set<String>()
      for entry in entries where seen.insert(PhoneNumber.matchKey(entry.value)).inserted {
        distinct.append(entry)
      }

      handle = try pick(from: distinct, store: store).value
      resolvedName = names.first
    }

    let url = try dryRun ? Dialer.url(for: handle, service: service) : Dialer.dial(handle, service: service)

    if json {
      var payload: [String: Any] = [
        "url": url.absoluteString,
        "handle": handle,
        "number": PhoneNumber.display(handle),
        "service": service.rawValue,
        "dialed": !dryRun,
        // A hand-off is not a connected call, and the difference matters.
        "requires_confirmation": true,
      ]
      if let resolvedName { payload["name"] = resolvedName }
      try Output.json(payload)
      return
    }

    let who =
      resolvedName.map { "\($0) (\(PhoneNumber.display(handle)))" }
      ?? PhoneNumber.display(handle)
    if dryRun {
      print("Would open \(Style.identifier(url.absoluteString)) — \(who)")
      return
    }
    print("Calling \(Style.title(who)) …")
    print(Style.dim("Phone.app will ask you to confirm before it dials."))
  }

  /// Which of a contact's numbers to call when they have more than one.
  ///
  /// The most recently used one wins: that is the number they actually answer,
  /// whereas a contact card's ordering reflects the order entries were added.
  /// Falls back to the card's own primary, then to that ordering.
  private func pick(from entries: [ContactNumber], store: CallStore) throws -> ContactNumber {
    guard entries.count > 1 else {
      guard let only = entries.first else {
        throw ValidationError("No number found for '\(target)'.")
      }
      return only
    }

    var byKey: [String: ContactNumber] = [:]
    for entry in entries {
      let key = PhoneNumber.matchKey(entry.value)
      if byKey[key] == nil { byKey[key] = entry }
    }
    let history = try store.recents(RecentsRequest())
    if let recent = history.lazy.compactMap({ byKey[PhoneNumber.matchKey($0.handle)] }).first {
      return recent
    }

    return entries.first(where: \.isPrimary)
      ?? entries.min(by: { $0.orderingIndex < $1.orderingIndex })
      ?? entries[0]
  }
}

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Report permission state without requesting it"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    var databasePath: String?
    var callCount: Int?
    var stale = false
    var readError: String?
    do {
      let database = try CallHistoryDatabase.open()
      databasePath = database.databasePath.path
      stale = database.isStale
      let rows = try database.query("SELECT COUNT(*) AS n FROM ZCALLRECORD")
      callCount = Int(rows.first?["n"] as? Int64 ?? 0)
    } catch {
      readError = error.localizedDescription
    }

    let readable = readError == nil
    let contacts = ContactDirectory.load()
    let blockList = BlockList.load()
    let phoneRunning = isPhoneRunning()

    let status: String
    let advice: String?
    if readable {
      status = "authorized"
      // Reads working while contact resolution does not is a real half-state,
      // and the only one worth advising about: no address book at all needs no
      // action from anyone.
      advice =
        contacts.availability == .unreadable
        ? "Call history reads fine, but the Contacts store does not, so callers cannot be "
          + "named. Both need Full Disk Access for this terminal."
        : nil
    } else {
      status = "denied"
      advice =
        "Grant Full Disk Access to this terminal in System Settings → Privacy & Security → "
        + "Full Disk Access, then run this again."
    }

    if json {
      var payload: [String: Any] = [
        "status": status,
        "usable": readable,
        "full_disk_access": readable,
        "contacts_resolution": contacts.isAvailable,
        // Three states, not two: `unreadable` is a grant problem, whereas
        // `noAddressBook` is a Mac with no contacts and needs no fixing.
        "contacts_state": contacts.availability.rawValue,
        "contact_numbers_indexed": contacts.count,
        "block_list_readable": blockList.isAvailable,
        "blocked_count": blockList.items.count,
        // No Automation key on purpose: Phone.app ships no scripting dictionary,
        // so there is nothing an Automation grant could unlock.
        "scriptable": false,
        "phone_app_running": phoneRunning,
      ]
      if let advice { payload["advice"] = advice }
      if let databasePath { payload["database"] = databasePath }
      if let callCount { payload["calls"] = callCount }
      if let readError { payload["error"] = readError }
      if stale { payload["stale"] = true }
      try Output.json(payload)
      if !readable { throw ExitCode(1) }
      return
    }

    if readable {
      print(Style.success("✓ Full Disk Access — can read the call history"))
      if let databasePath { print("  \(Style.dim(databasePath))") }
      if let callCount { print("  \(Style.dim("\(callCount) calls"))") }
      if stale { print("  \(Style.warning("write-ahead log not replayed; may be stale"))") }
    } else {
      print(Style.warning("✗ Full Disk Access — cannot read the call history"))
      if let readError { print("  \(readError)") }
    }

    switch contacts.availability {
    case .available:
      print(
        Style.success(
          "✓ Contacts resolution — \(contacts.count) numbers indexed from the address book"))
    case .unreadable:
      print(Style.warning("✗ Contacts resolution — the address book could not be opened"))
      print("  \(Style.dim("Calls still read; callers cannot be named, and --unknown refuses."))")
    case .noAddressBook:
      print(Style.dim("— Contacts resolution — no address book on this Mac, nothing to resolve"))
    }

    print(
      "\(Style.dim("Blocked callers:")) \(blockList.items.count) "
        + "\(Style.dim("(read-only — see `apple phone blocked --help`)"))")
    print("\(Style.dim("Phone.app running:")) \(phoneRunning ? "yes" : "no")")
    print(Style.dim("Phone.app is not scriptable; dialing goes through a tel: URL."))

    if let advice { print("\n\(advice)") }
    if !readable { throw ExitCode(1) }
  }

  /// Whether Phone.app is up. Checked by process list rather than by asking it,
  /// because it cannot be asked — and `status` must never launch anything.
  private func isPhoneRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "pgrep -f 'Phone.app/Contents/MacOS/Phone' >/dev/null"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }
}

ApplePhone.main()
