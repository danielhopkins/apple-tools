import EventKit
import Foundation
import ReminderKitBridge

/// Reminders tags, which EventKit cannot see at all.
///
/// The mechanics and the reasoning are in `ReminderKitBridge.h`; this is the
/// Swift-shaped face of it. Two things worth knowing at the call site:
///
///   * **Reads are best-effort.** A store with no tags, and a system where the
///     private API has gone away, both come back as "no tags" rather than as an
///     error — a listing should not fail because tags are unavailable.
///   * **Writes are not.** They throw, because silently not tagging something
///     the user asked to tag is the failure mode this whole file exists to
///     avoid.
enum ReminderTags {
    /// Whether tags can be read or written on this system. False means macOS
    /// changed the private API; everything else still works.
    static var isAvailable: Bool { AppleToolsReminderKitAvailable() }

    /// Tags for each identifier that has any, keyed by
    /// `calendarItemExternalIdentifier`. Identifiers with no tags are absent.
    ///
    /// Never throws: on any failure this returns `[:]`, which reads as "no
    /// tags". Use `isAvailable` when the difference matters.
    static func read(for externalIds: [String]) -> [String: [String]] {
        guard !externalIds.isEmpty else { return [:] }
        guard let tags = AppleToolsReadReminderTags(externalIds, nil) else { return [:] }
        return tags
    }

    /// Tags for one reminder.
    static func read(for externalId: String) -> [String] {
        read(for: [externalId])[externalId] ?? []
    }

    /// Apply a tag change and return what the reminder carries afterwards, as
    /// read back from a fresh store.
    ///
    /// `replaceAll` makes `add` the complete new set. Otherwise `add` and
    /// `remove` are applied to whatever is already there.
    static func apply(
        externalId: String,
        add: [String] = [],
        remove: [String] = [],
        replaceAll: Bool = false) throws -> [String]
    {
        var error: NSError?
        let result = AppleToolsApplyReminderTags(externalId, add, remove, replaceAll, &error)
        guard let result else {
            throw error ?? NSError(
                domain: AppleToolsReminderKitErrorDomain,
                code: AppleToolsReminderKitError.unavailable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "the tag change failed"])
        }
        return result
    }

    /// Tag a reminder that was just created, retrying briefly while it becomes
    /// visible.
    ///
    /// ⚠️ EventKit and ReminderKit are two views of the same daemon, and a
    /// reminder saved through the first is not guaranteed to be resolvable
    /// through the second on the very next call. Rather than tag the wrong
    /// thing or fail a legitimate `add`, this retries the *lookup* — and only
    /// the lookup — for a short window. Any other error is raised immediately.
    static func applyToNewReminder(externalId: String, tags: [String]) throws -> [String] {
        let deadline = Date().addingTimeInterval(2.0)
        while true {
            do {
                return try apply(externalId: externalId, add: tags, replaceAll: true)
            } catch let error as NSError
                where error.domain == AppleToolsReminderKitErrorDomain
                    && error.code == AppleToolsReminderKitError.notFound.rawValue
                    && Date() < deadline
            {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Reject a tag Reminders would silently rewrite, before anything is
    /// written.
    ///
    /// 🛑 **A tag containing a space is not refused by the API — it is silently
    /// stripped.** Measured: adding `two words` stored a tag named `twowords`,
    /// with `canonicalName` `twowords`, and the save reported success.
    /// `REMReminderHashtagContextChangeItem` even has
    /// `nameWithDisallowedCharactersReplaced:` for the purpose. Accepting the
    /// flag and storing something the user did not type is exactly the silent
    /// corruption this tool refuses elsewhere, so it is a hard error naming the
    /// substitute.
    ///
    /// A leading `#` is punctuation Reminders.app adds when it *renders* a tag,
    /// not part of the name; storing it would produce a tag shown as `##PTA`.
    static func validate(_ tag: String) throws {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw TagError("a tag cannot be empty")
        }
        if trimmed.hasPrefix("#") {
            throw TagError(
                "write the tag without a leading '#': --tag \(trimmed.dropFirst())")
        }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            let collapsed = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
            throw TagError(
                "'\(trimmed)' is not a usable tag: Reminders removes the spaces without saying "
                + "so and would store it as '\(collapsed)'. Reminders tags are single words — "
                + "pass '\(collapsed)', a hyphenated form, or one --tag per tag.")
        }
    }
}

/// A tag the store cannot represent. Named to stay clear of
/// `ArgumentParser.ValidationError`, which is in scope throughout this module.
struct TagError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Tags for the reminders about to be printed.
///
/// Tags live in a different store from the `EKReminder`s being formatted, and
/// reading them costs an XPC round trip — so a listing resolves them **once**
/// for the whole batch and parks them here, rather than having the encoder ask
/// per reminder. `EKReminder.encode(to:)` and the plain formatter both read
/// from this and print nothing when it is empty, so a build where the private
/// API has gone away simply omits tags instead of failing.
enum TagCache {
    private(set) static var byExternalId: [String: [String]] = [:]

    /// Resolve tags for `reminders` in one batch. Cheap and silent when there
    /// is nothing to find.
    static func populate(for reminders: [EKReminder]) {
        let ids = reminders.compactMap { $0.calendarItemExternalIdentifier }
        guard !ids.isEmpty else { return }
        byExternalId = ReminderTags.read(for: ids)
    }

    /// Record tags already known for one reminder, so a write path can print
    /// its result without a second lookup.
    static func set(_ tags: [String], for externalId: String?) {
        guard let externalId else { return }
        byExternalId[externalId] = tags
    }

    static func tags(for externalId: String?) -> [String] {
        guard let externalId else { return [] }
        return byExternalId[externalId] ?? []
    }

    /// Keep only the reminders carrying **every** tag in `required`.
    ///
    /// An AND, matching what a multi-term query means in `apple mail` and
    /// `apple messages` — `--tag PTA --tag urgent` is "both", not "either".
    /// Comparison is case-insensitive, the same rule the store uses.
    ///
    /// Call after `populate`; with an empty filter this is the identity.
    static func filter<T>(
        _ items: [T],
        by required: [String],
        externalId: (T) -> String?) -> [T]
    {
        guard !required.isEmpty else { return items }
        let wanted = Set(required.map { $0.lowercased() })
        return items.filter { item in
            let present = Set(tags(for: externalId(item)).map { $0.lowercased() })
            return wanted.isSubset(of: present)
        }
    }
}
