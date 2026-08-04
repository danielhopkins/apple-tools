import Foundation

/// The user's blocked-caller list, read from
/// `~/Library/Preferences/com.apple.cmfsyncagent.plist`.
///
/// 🛑 **This is read-only, and it cannot be made otherwise.**
///
/// `CommunicationsFilter.framework` exports exactly the C API you would want —
/// `CMFBlockListAddItemForAllServices`, `CMFBlockListRemoveItemFromAllServices`,
/// `CMFBlockListIsItemBlocked` — and `dlopen` reaches them from an unsigned
/// binary. `CreateCMFItemFromString("+1...")` even works, returning the same
/// dictionary shape this file parses.
///
/// They do not work, and they **fail silently**. Verified against a number that
/// was on the list in this very plist:
///
///     CMFBlockListIsItemBlocked(<blocked number>)  -> false
///     CMFBlockListGetBlockedStatusForItems([...])  -> {}   (empty)
///
/// `CMFSyncAgent` is running, and its binary contains
/// `"[WARN] Denying xpc connection, task does not have entitlement: %@"`
/// alongside `com.apple.private.communicationsfilter`. Phone.app holds that
/// entitlement and is a `platform-application`; a Developer ID signature cannot
/// claim a `com.apple.private.*` entitlement at all, so no CLI can ever hold
/// it. An `add` built on this API would report success and change nothing —
/// strictly worse than not offering it.
///
/// Writing the plist directly is also wrong: `cmfsyncagent` owns it, caches it
/// in memory, and versions it with a revision counter it syncs to the iPhone.
/// Note the two timestamps disagree on a real machine (revision stamped
/// 2025-06-12, file mtime 2026-05-08), which is the tell that this file is a
/// synced cache rather than the authority.
///
/// Blocking is also the iPhone's job, not the Mac's: an incoming call here is
/// relayed from the phone, and the phone is what filters. So even a working
/// local write would not stop the phone ringing.
public struct BlockedItem: Sendable {
  public enum Kind: String, Sendable {
    case phone
    case email
    case unknown
  }

  public let value: String
  public let countryCode: String?
  public let kind: Kind
  /// The key this can be compared against a call handle on.
  public var matchKey: String { PhoneNumber.matchKey(value) }
}

public struct BlockList: Sendable {
  public let items: [BlockedItem]
  /// The store's own revision counter and when it last changed, both straight
  /// from the plist. Surfaced because they are the only evidence of whether the
  /// list is current.
  public let revision: Int?
  public let revisionDate: Date?
  public let path: String
  public let isAvailable: Bool

  private let keys: Set<String>

  public func isBlocked(_ handle: String) -> Bool {
    keys.contains(PhoneNumber.matchKey(handle))
  }

  public static var empty: BlockList {
    BlockList(items: [], revision: nil, revisionDate: nil, path: "", isAvailable: false, keys: [])
  }

  public static func defaultPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
  {
    home.appendingPathComponent("Library/Preferences/com.apple.cmfsyncagent.plist")
  }

  public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> BlockList {
    let path =
      ProcessInfo.processInfo.environment["APPLE_PHONE_BLOCKLIST_PATH"].map {
        URL(fileURLWithPath: $0)
      } ?? defaultPath(home: home)

    guard let data = try? Data(contentsOf: path),
      let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let store = root["__kCMFBlockListStoreTopLevelKey"] as? [String: Any]
    else {
      // A machine that has never blocked anyone has no plist at all. That is
      // "empty", not "broken", so it is not an error — but `isAvailable` says
      // which so a caller need not guess.
      return BlockList(
        items: [], revision: nil, revisionDate: nil, path: path.path,
        isAvailable: FileManager.default.fileExists(atPath: path.path), keys: [])
    }

    let raw = store["__kCMFBlockListStoreArrayKey"] as? [[String: Any]] ?? []
    var items: [BlockedItem] = []
    for entry in raw {
      // The phone key is the one observed on a real store. The email key is
      // handled by shape rather than by name because no email entry existed
      // here to confirm its spelling, and guessing a constant we have not seen
      // would silently drop those rows.
      let phone = entry["__kCMFItemPhoneNumberUnformattedKey"] as? String
      let email =
        entry.first { key, value in
          key.contains("Email") && value is String
        }?.value as? String

      guard let value = phone ?? email, !value.isEmpty else { continue }
      let kind: BlockedItem.Kind
      if phone != nil {
        kind = .phone
      } else if email != nil {
        kind = .email
      } else {
        kind = .unknown
      }
      items.append(
        BlockedItem(
          value: value,
          countryCode: entry["__kCMFItemPhoneNumberCountryCodeKey"] as? String,
          kind: kind))
    }

    let revision = (store["__kCMFBlockListStoreRevisionKey"] as? NSNumber)?.intValue
    let revisionDate = store["__kCMFBlockListStoreRevisionTimestampKey"] as? Date

    return BlockList(
      items: items, revision: revision, revisionDate: revisionDate, path: path.path,
      isAvailable: true, keys: Set(items.map(\.matchKey)))
  }
}
