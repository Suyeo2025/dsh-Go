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

/// 「停止」 (v2 contract §2.3): the first tap only arms it for five seconds; a second tap inside them
/// stops the turn. The time is judged here, on the Activity's own `stopArmedUntil`, whatever the
/// view still shows.
enum WhaleWakeStopGate {
  static let window: TimeInterval = 5

  enum Step: Equatable {
    /// Locked phone: into the App, nothing armed or sent.
    case openApp
    /// Not armed, or armed too long ago: arm again (local update only).
    case arm
    /// Armed and still inside the window: stop the turn.
    case send
  }

  static func step(protectedDataAvailable: Bool, armedUntil: Date?, now: Date) -> Step {
    guard protectedDataAvailable else { return .openApp }
    guard let until = armedUntil, now < until, until.timeIntervalSince(now) <= window + 1 else { return .arm }
    return .send
  }
}

/// Set by the App at launch (LiveActivityChannel.attach); nil in the widget extension.
enum WhaleWakeIntentHost {
  static var decide: ((_ sessionId: String, _ eventId: String, _ decision: WhaleWakeDecision) async -> WhaleWakeOutcome)?
  /// v2: one tap on a question's option (`optionId` = its index in the original list).
  static var answer: ((_ sessionId: String, _ eventId: String, _ optionId: String) async -> WhaleWakeOutcome)?
  /// v2: 「停止」 (arm, or stop when armed).
  static var stop: ((_ sessionId: String) async -> WhaleWakeOutcome)?
  /// Opens a dshgo:// link inside the App (LinksChannel), once it is in the foreground.
  static var open: ((URL) -> Void)?

  @available(iOS 17.0, *)
  static func run<I: AppIntent>(_ intent: I, sessionId: String, eventId: String, decision: WhaleWakeDecision) async throws {
    let outcome = await decide?(sessionId, eventId, decision) ?? .openApp
    try await openIfNeeded(intent, outcome, WhaleWakeAttributes.sessionURL(sessionId, eventId: eventId))
  }

  @available(iOS 17.0, *)
  static func openIfNeeded<I: AppIntent>(_ intent: I, _ outcome: WhaleWakeOutcome, _ url: URL) async throws {
    guard outcome == .openApp else { return }
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

/// One tap on a question's option (v2 C1). The answer the bridge sends is the original option at
/// `optionId`; the phone never sends label text.
@available(iOS 17.0, *)
struct AnswerIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Answer"
  static let description = IntentDescription("Answers the question a DSH conversation is waiting on with one of its options.")
  static let isDiscoverable = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Session") var sessionId: String
  @Parameter(title: "Event") var eventId: String
  @Parameter(title: "Option") var optionId: String

  init() {}

  init(sessionId: String, eventId: String, optionId: String) {
    self.sessionId = sessionId
    self.eventId = eventId
    self.optionId = optionId
  }

  func perform() async throws -> some IntentResult {
    let outcome = await WhaleWakeIntentHost.answer?(sessionId, eventId, optionId) ?? .openApp
    try await WhaleWakeIntentHost.openIfNeeded(self, outcome, WhaleWakeAttributes.sessionURL(sessionId, eventId: eventId))
    return .result()
  }
}

/// 「停止」 (v2 C2): two taps within five seconds stop the turn.
@available(iOS 17.0, *)
struct StopIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop"
  static let description = IntentDescription("Stops the turn a DSH conversation is running (tap twice).")
  static let isDiscoverable = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Session") var sessionId: String

  init() {}

  init(sessionId: String) { self.sessionId = sessionId }

  func perform() async throws -> some IntentResult {
    let outcome = await WhaleWakeIntentHost.stop?(sessionId) ?? .openApp
    try await WhaleWakeIntentHost.openIfNeeded(self, outcome, WhaleWakeAttributes.sessionURL(sessionId))
    return .result()
  }
}

@available(iOS 26.0, *)
extension AnswerIntent {
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

@available(iOS 26.0, *)
extension StopIntent {
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

@available(iOS 26.0, *)
extension ApproveIntent {
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}

@available(iOS 26.0, *)
extension DenyIntent {
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
}
