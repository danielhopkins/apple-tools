import AppleToolsSearch
import Foundation

/// How a call went. Derived rather than stored: the database records
/// `ZORIGINATED` and `ZANSWERED` as separate flags and leaves the combination
/// to the reader.
///
/// `ZANSWERED` means "answered by me", so it is always 0 on an outgoing call —
/// treating it as "connected" would report every call you placed as missed.
/// Whether a call actually connected is `duration > 0`.
public enum CallStatus: String, Sendable {
  case outgoing
  case incoming
  case missed
}

/// What kind of call. `ZCALLTYPE` and `ZSERVICE_PROVIDER` agree on a real store,
/// so the type is the primary signal and the provider disambiguates.
public enum CallKind: String, Sendable {
  case phone
  case facetimeAudio = "facetime-audio"
  case facetimeVideo = "facetime-video"
  case unknown
}

public struct Call: Sendable {
  public let id: Int64
  public let date: Date?
  public let duration: TimeInterval
  public let status: CallStatus
  public let kind: CallKind
  /// The raw handle exactly as stored, unnormalised.
  public let handle: String
  /// Punctuated for display; the raw handle when we cannot be sure of the format.
  public let displayHandle: String
  /// Resolved from Contacts, nil when this caller is not in the address book.
  public let contactName: String?
  public let contactID: String?
  /// A name the store itself carried. Almost always absent — 1 of 289 rows on a
  /// real store — but when present it is worth showing.
  public let storedName: String?
  public let location: String?
  public let serviceProvider: String?
  public let rawCallType: Int64
  public let isRead: Bool
  public let isBlocked: Bool
  public let junkConfidence: Int64
  public let junkCategory: String?
  public let blockedByExtension: String?
  public let originatingDevice: String?
  public let wasEmergency: Bool

  /// True when the call reached the other end. Distinguishes an outgoing call
  /// that rang out from one that was picked up, which `status` alone cannot.
  public var connected: Bool { duration > 0 }

  /// Whether this caller is in Contacts. The whole point of `--unknown`.
  public var isKnown: Bool { contactName != nil }

  /// Best available label for who this was.
  public var who: String { contactName ?? storedName ?? displayHandle }
}

public struct RecentsRequest: Sendable {
  public var limit: Int?
  public var sinceDays: Int?
  public var beforeDays: Int?
  public var missedOnly = false
  public var incomingOnly = false
  public var outgoingOnly = false
  public var unknownOnly = false
  public var blockedOnly = false
  public var kind: CallKind?
  /// Free-text filter, matched the same way mail and messages match.
  public var query: String?
  /// Restrict to one handle (number or email), compared on `matchKey`.
  public var handle: String?

  public init() {}
}

public struct CallStatistics: Sendable {
  public let total: Int
  public let outgoing: Int
  public let incoming: Int
  public let missed: Int
  public let talkTime: TimeInterval
  public let longest: Call?
  public let unknownCallers: Int
  public let byKind: [(kind: CallKind, count: Int)]
  /// Most frequent counterparties, busiest first.
  public let topCallers: [(who: String, count: Int, talkTime: TimeInterval)]
  public let firstCall: Date?
  public let lastCall: Date?
}

public final class CallStore {
  private let database: CallHistoryDatabase
  private let contacts: ContactDirectory
  private let blockList: BlockList

  public var isStale: Bool { database.isStale }
  public var databasePath: URL { database.databasePath }
  public var contactsAvailable: Bool { contacts.isAvailable }
  public var contactAvailability: ContactAvailability { contacts.availability }
  public var contactNumbersIndexed: Int { contacts.count }
  public var blocked: BlockList { blockList }

  /// Handles for contacts matching a name. Empty when resolution is unavailable,
  /// which the caller must distinguish via `contactAvailability` rather than
  /// reporting as "no such contact".
  public func contactsNamed(_ query: String, email: Bool = false) -> [ContactNumber] {
    contacts.findByName(query, email: email)
  }

  /// `resolveContacts: false` skips loading the address book, for the rare
  /// caller that wants raw handles or is running without that access.
  public init(resolveContacts: Bool = true) throws {
    database = try CallHistoryDatabase.open()
    contacts = resolveContacts ? ContactDirectory.load() : .empty
    blockList = BlockList.load()
  }

  private static let columns = """
    Z_PK, ZDATE, ZDURATION, ZORIGINATED, ZANSWERED, ZCALLTYPE, ZADDRESS, ZNAME,
    ZLOCATION, ZSERVICE_PROVIDER, ZREAD, ZJUNKCONFIDENCE, ZJUNKIDENTIFICATIONCATEGORY,
    ZBLOCKEDBYEXTENSIONNAME, ZORIGINATINGDEVICENAME, ZWASEMERGENCYCALL
    """

  /// Recent calls, newest first.
  ///
  /// Date bounds and the cheap flags are applied in SQL; anything needing a
  /// resolved contact name (`--unknown`, the text query) is applied afterwards,
  /// because the name does not exist in this database. That means `--limit`
  /// cannot be pushed into SQL when such a filter is present, or the limit would
  /// apply before the filter and silently return too few rows.
  public func recents(_ request: RecentsRequest) throws -> [Call] {
    var clauses: [String] = []
    var binds: [CallHistoryDatabase.Bind] = []

    // Bound as doubles, never as the text strftime() returns: ZDATE is a REAL
    // and SQLite will not compare across storage classes. A text bind here
    // matches zero rows and looks exactly like "no calls".
    if let since = request.sinceDays {
      let cutoff = Calendar.current.date(byAdding: .day, value: -since, to: Date()) ?? Date()
      clauses.append("ZDATE >= ?")
      binds.append(.double(CallHistoryEpoch.raw(from: cutoff)))
    }
    if let before = request.beforeDays {
      let cutoff = Calendar.current.date(byAdding: .day, value: -before, to: Date()) ?? Date()
      clauses.append("ZDATE <= ?")
      binds.append(.double(CallHistoryEpoch.raw(from: cutoff)))
    }
    if request.missedOnly {
      clauses.append("ZORIGINATED = 0 AND ZANSWERED = 0")
    } else if request.incomingOnly {
      // Answered, not merely inbound. Each filter selects exactly one `status`
      // value, so `--incoming` and `status: "incoming"` cannot disagree — and a
      // missed call is not one you took.
      clauses.append("ZORIGINATED = 0 AND ZANSWERED = 1")
    } else if request.outgoingOnly {
      clauses.append("ZORIGINATED = 1")
    }
    if let kind = request.kind {
      switch kind {
      case .phone: clauses.append("ZCALLTYPE = 1")
      case .facetimeAudio: clauses.append("ZCALLTYPE = 8")
      case .facetimeVideo: clauses.append("ZCALLTYPE = 16")
      case .unknown: break
      }
    }

    let needsPostFilter =
      request.unknownOnly || request.blockedOnly || request.query != nil || request.handle != nil
    var sql = "SELECT \(Self.columns) FROM ZCALLRECORD"
    if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
    sql += " ORDER BY ZDATE DESC"
    if let limit = request.limit, !needsPostFilter {
      sql += " LIMIT \(limit)"
    }

    var calls = try database.query(sql, binds).map(makeCall)

    if request.unknownOnly { calls = calls.filter { !$0.isKnown } }
    if request.blockedOnly { calls = calls.filter(\.isBlocked) }
    if let handle = request.handle {
      let key = PhoneNumber.matchKey(handle)
      calls = calls.filter { PhoneNumber.matchKey($0.handle) == key }
    }
    if let query = request.query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
      calls = calls.filter { matches($0, query: query) }
    }
    if let limit = request.limit, needsPostFilter, calls.count > limit {
      calls = Array(calls.prefix(limit))
    }
    return calls
  }

  /// Whether a call matches a free-text query.
  ///
  /// Uses the same AND-of-substring-terms rule as `apple mail` and
  /// `apple messages`, so a query means the same thing across all three tools.
  /// The number is matched on its digits as well as its punctuated form, so
  /// `3035551212`, `303-555-1212` and `(303) 555-1212` all find the same calls.
  private func matches(_ call: Call, query: String) -> Bool {
    let terms = parseSearchTerms(query).map { $0.lowercased() }
    guard !terms.isEmpty else { return true }

    let text = [call.contactName, call.storedName, call.handle, call.displayHandle, call.location]
      .compactMap { $0 }
      .joined(separator: " ")
      .lowercased()
    // Compared separately from the text, and built from the handle alone.
    // Concatenating every field's digits would invent adjacencies across field
    // boundaries and match numbers that appear nowhere in the record.
    let handleDigits = PhoneNumber.digits(call.handle)

    return terms.allSatisfy { term in
      if text.contains(term) { return true }
      // A term that is itself a number matches however either side is
      // punctuated. Three digits is the floor; below that almost any number
      // contains it.
      let termDigits = PhoneNumber.digits(term)
      return termDigits.count >= 3 && handleDigits.contains(termDigits)
    }
  }

  public func statistics(_ request: RecentsRequest) throws -> CallStatistics {
    let calls = try recents(request)

    var kindCounts: [CallKind: Int] = [:]
    var callerCounts: [String: (count: Int, talkTime: TimeInterval)] = [:]
    var talkTime: TimeInterval = 0
    var longest: Call?

    for call in calls {
      kindCounts[call.kind, default: 0] += 1
      talkTime += call.duration
      if call.duration > (longest?.duration ?? 0) { longest = call }
      let key = call.who
      let existing = callerCounts[key] ?? (0, 0)
      callerCounts[key] = (existing.count + 1, existing.talkTime + call.duration)
    }

    let dates = calls.compactMap(\.date)
    return CallStatistics(
      total: calls.count,
      outgoing: calls.filter { $0.status == .outgoing }.count,
      incoming: calls.filter { $0.status == .incoming }.count,
      missed: calls.filter { $0.status == .missed }.count,
      talkTime: talkTime,
      longest: longest,
      unknownCallers: Set(calls.filter { !$0.isKnown }.map { PhoneNumber.matchKey($0.handle) })
        .count,
      byKind: kindCounts.sorted { $0.value > $1.value }.map { (kind: $0.key, count: $0.value) },
      topCallers: callerCounts.sorted {
        $0.value.count > $1.value.count
          || ($0.value.count == $1.value.count && $0.key < $1.key)
      }
      .prefix(10)
      .map { (who: $0.key, count: $0.value.count, talkTime: $0.value.talkTime) },
      firstCall: dates.min(),
      lastCall: dates.max())
  }

  private func makeCall(_ row: [String: Any]) -> Call {
    func text(_ key: String) -> String? {
      guard let value = row[key] as? String else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    func int(_ key: String) -> Int64 { row[key] as? Int64 ?? 0 }

    let handle = text("ZADDRESS") ?? ""
    let originated = int("ZORIGINATED") == 1
    let answered = int("ZANSWERED") == 1
    let callType = int("ZCALLTYPE")
    let provider = text("ZSERVICE_PROVIDER")

    let status: CallStatus = originated ? .outgoing : (answered ? .incoming : .missed)

    let kind: CallKind
    switch callType {
    case 1: kind = .phone
    case 8: kind = .facetimeAudio
    case 16: kind = .facetimeVideo
    default:
      // Unrecognised type: fall back to the provider rather than mislabelling.
      // Anything non-Telephony is FaceTime of some flavour, and we do not know
      // which, so it stays `unknown` and `rawCallType` carries the real value.
      kind = provider == "com.apple.Telephony" ? .phone : .unknown
    }

    let match = contacts.lookup(handle)
    // ZDURATION is a FLOAT; a double read keeps sub-second calls from
    // truncating to zero and reading as "never connected".
    let duration = row["ZDURATION"] as? Double ?? 0

    return Call(
      id: int("Z_PK"),
      date: CallHistoryEpoch.date(from: row["ZDATE"] as? Double ?? 0),
      duration: duration,
      status: status,
      kind: kind,
      handle: handle,
      displayHandle: handle.isEmpty ? "unknown" : PhoneNumber.display(handle),
      contactName: match?.name,
      contactID: match?.contactID,
      storedName: text("ZNAME"),
      location: text("ZLOCATION"),
      serviceProvider: provider,
      rawCallType: callType,
      isRead: int("ZREAD") == 1,
      isBlocked: handle.isEmpty ? false : blockList.isBlocked(handle),
      junkConfidence: int("ZJUNKCONFIDENCE"),
      junkCategory: text("ZJUNKIDENTIFICATIONCATEGORY"),
      blockedByExtension: text("ZBLOCKEDBYEXTENSIONNAME"),
      originatingDevice: text("ZORIGINATINGDEVICENAME"),
      wasEmergency: int("ZWASEMERGENCYCALL") == 1)
  }
}
