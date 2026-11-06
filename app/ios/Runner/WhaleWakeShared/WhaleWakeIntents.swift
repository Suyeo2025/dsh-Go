// Allow / Deny on the 「鲸游」Live Activity (behavior.md «交互与安全», plan/ios-wave2-design.md
// la-native §C). Compiled into both targets: the widget extension draws Button(intent:), the App
// runs perform() (LiveActivityIntent runs in the App's process). The work itself (Keychain, bridge
// request, Activity update) lives in the App (Runner/LiveActivityDecision.swift), reached through
// WhaleWakeIntentHost, which the App sets at launch; in the extension it stays nil and every path
// ends in "open the App".
//
// Never allows on its own: one intent is one person's tap for one pending eventId; no "allow all".
// The system asks for an unlock before perform() (authenticationPolicy); perform() still refuses
// without protected data; a high-risk command asks for Face ID / the passcode again.

import AppIntents
import Foundation

enum WhaleWakeDecision: String {
  case allow, deny

  /// The bridge's word (`POST /v1/approvals/<eventId>/decision {decision}`).
  var wire: String { self == .allow ? "allow" : "reject" }
}

/// How one tap ended.
enum WhaleWakeOutcome: Equatable {
  /// The bridge took the decision.
  case decided
  /// The App has to take over (locked, no pairing, the bridge refused or didn't answer).
  case openApp
  /// The person cancelled Face ID: nothing happens.
  case abandoned
}

/// What to do with a tap, before anything is sent.
enum WhaleWakeGate {
  enum Step: Equatable {
    case openApp
    /// Allow on a high-risk command: authenticate the owner first.
    case authenticateThenSend
    case send
  }

  static func route(protectedDataAvailable: Bool, decision: WhaleWakeDecision, risk: String?, hasCredentials: Bool) -> Step {
    guard protectedDataAvailable, hasCredentials else { return .openApp }
    return decision == .allow && risk == "high" ? .authenticateThenSend : .send
  }
}

/// Set by the App at launch (LiveActivityChannel.attach); nil in the widget extension.
enum WhaleWakeIntentHost {
  static var decide: ((_ sessionId: String, _ eventId: String, _ decision: WhaleWakeDecision) async -> WhaleWakeOutcome)?
  /// Opens a dshgo:// link inside the App (LinksChannel), once it is in the foreground.
  static var open: ((URL) -> Void)?

  @available(iOS 17.0, *)
  static func run<I: AppIntent>(_ intent: I, sessionId: String, eventId: String, decision: WhaleWakeDecision) async throws {
    let outcome = await decide?(sessionId, eventId, decision) ?? .openApp
    guard outcome == .openApp else { return }
    let url = WhaleWakeAttributes.sessionURL(sessionId, eventId: eventId)
    if #available(iOS 26.0, *) {
      // Into the App, at the approval card (the tap is the person's; nothing was decided).
      try await intent.continueInForeground(nil, alwaysConfirm: false)
      await MainActor.run { open?(url) }
    }
    // Older systems can't bring the App forward from here: the Activity stays as it was and its
    // banner (widgetURL) opens the card.
  }
}

@available(iOS 17.0, *)
struct ApproveIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Allow"
  static let description = IntentDescription("Allows the command a DSH conversation is waiting on.")
  static let isDiscoverable = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Session") var sessionId: String
  @Parameter(title: "Event") var eventId: String

  init() {}

  init(sessionId: String, eventId: String) {
    self.sessionId = sessionId
    self.eventId = eventId
  }

  func perform() async throws -> some IntentResult {
    try await WhaleWakeIntentHost.run(self, sessionId: sessionId, eventId: eventId, decision: .allow)
    return .result()
  }
}

@available(iOS 17.0, *)
struct DenyIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Deny"
  static let description = IntentDescription("Denies the command a DSH conversation is waiting on.")
  static let isDiscoverable = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Session") var sessionId: String
  @Parameter(title: "Event") var eventId: String

  init() {}

  init(sessionId: String, eventId: String) {
    self.sessionId = sessionId
    self.eventId = eventId
  }

  func perform() async throws -> some IntentResult {
    try await WhaleWakeIntentHost.run(self, sessionId: sessionId, eventId: eventId, decision: .deny)
    return .result()
  }
}

@available(iOS 26.0, *)
extension ApproveIntent {
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

@available(iOS 26.0, *)
extension DenyIntent {
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}
