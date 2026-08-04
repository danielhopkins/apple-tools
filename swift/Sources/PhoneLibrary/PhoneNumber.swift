import Foundation

/// Normalising the handles that appear in call history.
///
/// `ZCALLRECORD.ZADDRESS` is **not normalised** — a single real store holds all
/// of these spellings at once:
///
///     8005551212      bare 10 digits
///     18005551212     11 digits, country code, no plus
///     +13035551212    E.164
///     name@example.com   a FaceTime call to an Apple ID
///
/// So every comparison has to go through a key rather than the raw string, and
/// the same key has to be used on both sides when joining against Contacts.
public enum PhoneNumber {

  /// Whether this handle is an email address (a FaceTime call) rather than a
  /// number. Anything with an `@` is treated as one; call history never puts an
  /// `@` in a telephone address.
  public static func isEmail(_ handle: String) -> Bool {
    handle.contains("@")
  }

  /// Just the digits. Drops `+`, spaces, parentheses, dashes and dots.
  public static func digits(_ handle: String) -> String {
    handle.filter(\.isNumber)
  }

  /// The key two handles are compared on.
  ///
  /// For anything with at least 10 digits this is the **trailing 10**, which is
  /// what makes `8005551212`, `18005551212` and `+18005551212` all match. Emails
  /// are lowercased and returned whole.
  ///
  /// ⚠️ Trailing-10 matching is a deliberate approximation, correct for NANP
  /// numbers and capable of colliding between countries in principle — two
  /// different numbers agreeing on their last 10 digits would resolve to the
  /// same contact. Nothing shorter works: the store mixes plus-prefixed and
  /// bare forms for the *same* number, so a strict comparison fails to match a
  /// contact against the very call it placed. Shorter handles (a local number,
  /// or a short code like `611`) key on all their digits, so those never
  /// collide with a full number.
  public static func matchKey(_ handle: String) -> String {
    if isEmail(handle) {
      return handle.lowercased().trimmingCharacters(in: .whitespaces)
    }
    let all = digits(handle)
    guard all.count > 10 else { return all }
    return String(all.suffix(10))
  }

  /// Human-readable form. NANP numbers get punctuation; everything else is
  /// returned as stored, because guessing at a format we do not know is worse
  /// than showing the real value.
  public static func display(_ handle: String) -> String {
    if isEmail(handle) { return handle }
    let all = digits(handle)
    let local: String
    if all.count == 11, all.hasPrefix("1") {
      local = String(all.dropFirst())
    } else if all.count == 10 {
      local = all
    } else {
      return handle
    }
    let area = local.prefix(3)
    let exchange = local.dropFirst(3).prefix(3)
    let line = local.suffix(4)
    return "(\(area)) \(exchange)-\(line)"
  }

  /// The form to hand to a `tel:` URL. E.164 when we can be confident, digits
  /// otherwise.
  ///
  /// A 10-digit number is assumed NANP and gets `+1`, because that is the only
  /// reading that makes it dialable, and an 11-digit number starting `1` gets a
  /// bare `+`. Anything else is passed through with its digits and any leading
  /// `+` preserved — we do not know its country and must not invent one.
  public static func dialable(_ handle: String) -> String {
    if isEmail(handle) { return handle }
    let all = digits(handle)
    if handle.hasPrefix("+") { return "+\(all)" }
    if all.count == 10 { return "+1\(all)" }
    if all.count == 11, all.hasPrefix("1") { return "+\(all)" }
    return all
  }
}
