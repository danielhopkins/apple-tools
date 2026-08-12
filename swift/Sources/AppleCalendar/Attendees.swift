import AppleToolsStyle
import EventKit
import Foundation
import ObjectiveC

// MARK: - Why writing invitees needs private API

/// 🛑 **EventKit exposes attendees for reading only, and there is no public way
/// to add one.** `EKCalendarItem.attendees` is a get-only `[EKParticipant]?`,
/// and `EKParticipant` has no public initializer — so nothing in the framework
/// lets you name a person you want to invite. Calendar.app's scripting
/// dictionary is no help either: its `attendee` class declares `display name`,
/// `email` and `participation status` all `access="r"`, so `make new attendee`
/// cannot be given an address.
///
/// The write path is therefore `EKAttendee.attendeeWithName:emailAddress:` plus
/// `EKCalendarItem.addAttendee:` / `removeAttendee:` — all private, all resolved
/// at runtime here so their disappearance is a clean refusal rather than a
/// crash. `AttendeeAPI.isAvailable` is checked before any invitee write.
///
/// Verified end to end against a live Google account (see
/// `docs/apple-calendar-invitees.md`): the attendee survives `save`, syncs to
/// the server, and the server sends a real invitation — a Google
/// "Invitation: …" mail landed in the invitee's inbox 40s after the save.

enum AttendeeAPI {
  private static let attendeeClass: AnyClass? = NSClassFromString("EKAttendee")
  private static let makeSelector = NSSelectorFromString("attendeeWithName:emailAddress:")
  private static let addSelector = NSSelectorFromString("addAttendee:")
  private static let removeSelector = NSSelectorFromString("removeAttendee:")

  private typealias MakeFn = @convention(c) (AnyClass, Selector, NSString, NSString) -> AnyObject?
  private typealias MutateFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void

  private static func classMethod(_ cls: AnyClass, _ selector: Selector) -> IMP? {
    guard let meta = object_getClass(cls),
      let method = class_getInstanceMethod(meta, selector)
    else { return nil }
    return method_getImplementation(method)
  }

  private static func instanceMethod(_ cls: AnyClass, _ selector: Selector) -> IMP? {
    // class_getInstanceMethod, not class_getMethodImplementation: the latter
    // hands back _objc_msgForward for a selector that does not exist, which
    // would turn "this macOS dropped the API" into a crash at call time.
    guard let method = class_getInstanceMethod(cls, selector) else { return nil }
    return method_getImplementation(method)
  }

  /// Whether every private symbol the write path needs is present. False on a
  /// macOS that has moved them; the invitee commands refuse rather than guess.
  static var isAvailable: Bool {
    guard let attendeeClass, classMethod(attendeeClass, makeSelector) != nil else { return false }
    return instanceMethod(EKCalendarItem.self, addSelector) != nil
      && instanceMethod(EKCalendarItem.self, removeSelector) != nil
  }

  static let unavailableMessage = """
    this build of macOS no longer exposes the private EventKit calls that adding \
    an invitee needs (EKAttendee.attendeeWithName:emailAddress: / \
    EKCalendarItem.addAttendee:). There is no public API for writing attendees, \
    so invite the person in Calendar.app instead. Reading invitees still works.
    """

  /// Builds an `EKAttendee`. `name` is what calendar clients show before the
  /// server has its own idea; the address is what actually identifies them.
  static func make(name: String?, email: String) -> AnyObject? {
    guard let attendeeClass, let imp = classMethod(attendeeClass, makeSelector) else { return nil }
    let display = (name?.isEmpty == false) ? name! : email
    return unsafeBitCast(imp, to: MakeFn.self)(
      attendeeClass, makeSelector, display as NSString, email as NSString)
  }

  static func add(_ attendee: AnyObject, to item: EKCalendarItem) {
    guard let imp = instanceMethod(EKCalendarItem.self, addSelector) else { return }
    unsafeBitCast(imp, to: MutateFn.self)(item, addSelector, attendee)
  }

  static func remove(_ attendee: EKParticipant, from item: EKCalendarItem) {
    guard let imp = instanceMethod(EKCalendarItem.self, removeSelector) else { return }
    unsafeBitCast(imp, to: MutateFn.self)(item, removeSelector, attendee)
  }
}

// MARK: - Addresses

/// ⚠️ **Match invitees on the email address, never on the name or the role.**
/// The server rewrites both: an attendee saved as `Dan Hopkins` with role
/// `unknown` came back from Google as `dan@boulderhopkins.com` with role
/// `required`. The address is the only field that survives a round trip
/// unchanged.
enum AttendeeAddress {
  /// Pulls the bare address out of an `EKParticipant`. Its `url` is a `mailto:`
  /// for a person, but can be something else entirely for a room or resource.
  static func of(_ participant: EKParticipant) -> String? {
    let absolute = participant.url.absoluteString
    // `mailto:a@b.com` — take everything after the scheme rather than reading
    // `host`, which drops the local part.
    guard absolute.lowercased().hasPrefix("mailto:") else { return nil }
    let address = String(absolute.dropFirst("mailto:".count))
    guard !address.isEmpty else { return nil }
    return address.removingPercentEncoding ?? address
  }

  static func matches(_ participant: EKParticipant, _ email: String) -> Bool {
    guard let address = of(participant) else { return false }
    return address.compare(email, options: .caseInsensitive) == .orderedSame
  }

  /// Parses `a@b.com` or `Name <a@b.com>` into its two halves.
  static func parse(_ spec: String) -> (name: String?, email: String)? {
    let trimmed = spec.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") {
      let email = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        .trimmingCharacters(in: .whitespaces)
      var name = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespaces)
      // "Hopkins, Dan" <a@b.com> — strip the quotes people paste from Mail.
      if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
        name = String(name.dropFirst().dropLast())
      }
      guard isPlausible(email) else { return nil }
      return (name.isEmpty ? nil : name, email)
    }

    guard isPlausible(trimmed) else { return nil }
    return (nil, trimmed)
  }

  /// Deliberately shallow: enough to catch a fat-fingered argument, not an
  /// attempt at RFC 5322. A wrong-but-well-formed address is the server's
  /// problem, and it will bounce it.
  private static func isPlausible(_ email: String) -> Bool {
    guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return false }
    let domain = email[email.index(after: at)...]
    return !domain.isEmpty && domain.contains(".") && !domain.contains("@")
      && !email.contains(" ")
  }
}

// MARK: - Reporting

struct AttendeeInfo: Encodable {
  let name: String?
  let email: String?
  let status: String
  let role: String
  let type: String
  let isOrganizer: Bool
  let isMe: Bool

  enum CodingKeys: String, CodingKey {
    case name, email, status, role, type
    case isOrganizer = "organizer"
    case isMe = "is_me"
  }
}

extension EKParticipantStatus {
  var label: String {
    switch self {
    case .unknown: return "unknown"
    case .pending: return "pending"
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "tentative"
    case .delegated: return "delegated"
    case .completed: return "completed"
    case .inProcess: return "in-progress"
    @unknown default: return "unknown"
    }
  }
}

extension EKParticipantRole {
  var label: String {
    switch self {
    case .unknown: return "unknown"
    case .required: return "required"
    case .optional: return "optional"
    case .chair: return "chair"
    case .nonParticipant: return "non-participant"
    @unknown default: return "unknown"
    }
  }
}

extension EKParticipantType {
  var label: String {
    switch self {
    case .unknown: return "unknown"
    case .person: return "person"
    case .room: return "room"
    case .resource: return "resource"
    case .group: return "group"
    @unknown default: return "unknown"
    }
  }
}

enum Attendees {
  static func list(_ event: EKEvent) -> [AttendeeInfo]? {
    guard let participants = event.attendees, !participants.isEmpty else { return nil }
    let organizerAddress = event.organizer.flatMap(AttendeeAddress.of)
    return participants.map { participant in
      let email = AttendeeAddress.of(participant)
      return AttendeeInfo(
        name: participant.name,
        email: email,
        status: participant.participantStatus.label,
        role: participant.participantRole.label,
        type: participant.participantType.label,
        isOrganizer: email != nil && email == organizerAddress,
        isMe: participant.isCurrentUser)
    }
  }

  static func organizer(_ event: EKEvent) -> AttendeeInfo? {
    guard let organizer = event.organizer else { return nil }
    return AttendeeInfo(
      name: organizer.name,
      email: AttendeeAddress.of(organizer),
      status: organizer.participantStatus.label,
      role: organizer.participantRole.label,
      type: organizer.participantType.label,
      isOrganizer: true,
      isMe: organizer.isCurrentUser)
  }

  /// The current user's own response, which is the field people actually want
  /// when they ask "have I accepted this?".
  static func myStatus(_ event: EKEvent) -> String? {
    guard let me = event.attendees?.first(where: { $0.isCurrentUser }) else { return nil }
    return me.participantStatus.label
  }

  /// Whether this event will accept an attendee change at all.
  ///
  /// ⚠️ Only the organizer may change an invitee list. For an event someone else
  /// created, a local edit appears to succeed and is then reverted by the
  /// server, which is worse than a refusal — so refuse up front.
  static func modificationRefusal(_ event: EKEvent) -> String? {
    if event.calendar?.allowsContentModifications == false {
      return "calendar '\(event.calendar?.title ?? "?")' is read-only."
    }
    if let organizer = event.organizer, !organizer.isCurrentUser {
      let who = organizer.name ?? AttendeeAddress.of(organizer) ?? "someone else"
      return """
        '\(event.title ?? "this event")' is organized by \(who), and only the organizer can \
        change who is invited. A local change here would be reverted by the server. \
        Ask them to invite the person, or reply to the invitation in Calendar.app.
        """
    }
    // Private, so guard the call rather than trusting the key to exist.
    let selector = NSSelectorFromString("allowsAttendeesModifications")
    if event.responds(to: selector),
      let allowed = event.value(forKey: "allowsAttendeesModifications") as? Bool, !allowed
    {
      return "this event does not allow its invitee list to be changed."
    }
    return nil
  }

  /// One line per invitee for the human output.
  static func describe(_ attendee: AttendeeInfo) -> String {
    let who = [attendee.name, attendee.email.map { "<\($0)>" }]
      .compactMap { $0 }
      .joined(separator: " ")
    var tags: [String] = [attendee.status]
    if attendee.isOrganizer { tags.append("organizer") }
    if attendee.isMe { tags.append("you") }
    if attendee.type != "person" && attendee.type != "unknown" { tags.append(attendee.type) }
    return "  \(who.isEmpty ? "<unnamed>" : who)  \(Style.dim("[\(tags.joined(separator: ", "))]"))"
  }
}
