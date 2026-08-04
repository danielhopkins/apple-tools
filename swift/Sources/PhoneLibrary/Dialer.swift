import Foundation

/// Placing a call, which means handing a URL to Phone.app.
///
/// There is no API here and there is no way to avoid the prompt. Phone.app's
/// binary carries `shouldRestrictDialRequest:performSynchronously:`,
/// `showAudioCallPrompt`, `hideCallPrompts` and
/// `"Has 'no prompt' entitlement? %s"`, and the entitlement in question is
/// `com.apple.FaceTime.NoPrompt` — which Phone.app holds and which is only
/// grantable to an Apple-signed `platform-application`. So a confirmation panel
/// always appears for us.
///
/// That is treated as a feature rather than worked around. Every other
/// irreversible write in this repo needs an explicit `--confirm`; dialing gets a
/// human gate from the OS that `mail send` never had, so the CLI does not add a
/// second one. What it must not do is *click* that panel — auto-confirming would
/// turn one command into a real, billable, outward-facing phone call with no
/// human in the loop.
public enum Dialer {
  public enum DialError: Error, LocalizedError {
    case emptyNumber
    case unroutable(String)
    /// An Apple ID handed to `tel:`, which cannot route one.
    case needsFaceTime(String)
    case launchFailed(String)

    public var errorDescription: String? {
      switch self {
      case .emptyNumber:
        return "No number to dial."
      case .unroutable(let handle):
        return
          "'\(handle)' does not look like a phone number or an Apple ID. Pass digits, an E.164 "
          + "number, or an email address for FaceTime."
      case .needsFaceTime(let handle):
        return
          "'\(handle)' is an Apple ID, and a phone call cannot route one. Retry with "
          + "--facetime-audio."
      case .launchFailed(let message):
        return "Could not hand the call to Phone.app: \(message)"
      }
    }
  }

  public enum Service: String, Sendable {
    case phone
    case facetimeAudio = "facetime-audio"

    var scheme: String {
      switch self {
      case .phone: return "tel"
      case .facetimeAudio: return "facetime-audio"
      }
    }
  }

  /// The URL that would be opened, without opening it. Separated so `--dry-run`
  /// and the tests can check the routing without placing a call.
  public static func url(for handle: String, service: Service = .phone) throws -> URL {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw DialError.emptyNumber }

    let target = PhoneNumber.dialable(trimmed)
    if PhoneNumber.isEmail(trimmed) {
      // An email is only meaningful to FaceTime; tel: cannot route it.
      guard service == .facetimeAudio else {
        throw DialError.needsFaceTime(trimmed)
      }
    } else {
      // Three digits is the shortest real target (a short code such as 611).
      // Below that it is a typo, and dialing a typo is not recoverable.
      guard PhoneNumber.digits(target).count >= 3 else { throw DialError.unroutable(trimmed) }
    }

    guard
      let encoded = target.addingPercentEncoding(
        withAllowedCharacters: CharacterSet(charactersIn: "+@.-_").union(.alphanumerics)),
      let url = URL(string: "\(service.scheme):\(encoded)")
    else {
      throw DialError.unroutable(trimmed)
    }
    return url
  }

  /// Hand the URL to LaunchServices. Phone.app will open and ask the user to
  /// confirm; this returns as soon as the hand-off succeeds, not when the call
  /// connects.
  public static func dial(_ handle: String, service: Service = .phone) throws -> URL {
    let url = try url(for: handle, service: service)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = Pipe()

    do {
      try process.run()
    } catch {
      throw DialError.launchFailed(error.localizedDescription)
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let message =
        String(
          decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw DialError.launchFailed(message.isEmpty ? "open exited \(process.terminationStatus)" : message)
    }
    return url
  }
}
