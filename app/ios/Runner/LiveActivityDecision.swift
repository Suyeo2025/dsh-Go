import CryptoKit
import Foundation
import LocalAuthentication
import UIKit

/// The pairing with the push bridge, as app/lib/push/push_state.dart keeps it: the JSON under
/// SharedPreferences `push_bridge_v1` (UserDefaults `flutter.push_bridge_v1`: `bridge`, `pin`) and
/// the device token in the Keychain (flutter_secure_storage: service `flutter_secure_storage_service`,
/// account `push.bridge.deviceToken`). Read, never written or logged.
struct BridgeCredentials: Equatable {
  let bridge: URL
  /// Lowercase hex SHA-256 of the bridge's (self-signed) certificate, pinned mode only.
  let pin: String?
  let token: String

  static let defaultsKey = "flutter.push_bridge_v1"
  static let keychainService = "flutter_secure_storage_service"
  static let keychainAccount = "push.bridge.deviceToken"

  static func parse(pairingJSON: String?, token: String?) -> BridgeCredentials? {
    guard let token, !token.isEmpty, let json = pairingJSON?.data(using: .utf8),
      let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let raw = obj["bridge"] as? String, let url = URL(string: raw), url.scheme == "https" || url.scheme == "http",
      url.host != nil
    else { return nil }
    let pin = (obj["pin"] as? String)?.lowercased()
    return BridgeCredentials(bridge: url, pin: pin?.isEmpty == false ? pin : nil, token: token)
  }

  static func load() -> BridgeCredentials? {
    parse(pairingJSON: UserDefaults.standard.string(forKey: defaultsKey), token: keychainToken())
  }

  private static func keychainToken() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// `POST <bridge>/v1/approvals/<eventId>/decision`.
  func decisionURL(eventId: String) -> URL? { url("approvals", eventId, "decision") }

  /// v2: `POST <bridge>/v1/questions/<eventId>/answer`.
  func answerURL(eventId: String) -> URL? { url("questions", eventId, "answer") }

  /// v2: `POST <bridge>/v1/sessions/<sessionId>/cancel`.
  func cancelURL(sessionId: String) -> URL? { url("sessions", sessionId, "cancel") }

  private func url(_ kind: String, _ id: String, _ action: String) -> URL? {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    guard !id.isEmpty, let id = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    let base = bridge.absoluteString.hasSuffix("/") ? String(bridge.absoluteString.dropLast()) : bridge.absoluteString
    return URL(string: "\(base)/v1/\(kind)/\(id)/\(action)")
  }
}

/// Allow / Deny from the Live Activity, in the App's process (WhaleWakeIntentHost.decide).
@available(iOS 16.2, *)
enum LiveActivityDecision {
  static func decide(sessionId: String, eventId: String, decision: WhaleWakeDecision, store: WhaleWakeActivityStore) async
    -> WhaleWakeOutcome
  {
    let protected = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    let credentials = BridgeCredentials.load()
    let risk = await store.pendingRisk(sessionId: sessionId, eventId: eventId)
    func report(_ result: String) async {
      await store.decided(["sessionId": sessionId, "eventId": eventId, "decision": decision.rawValue, "result": result])
    }
    switch WhaleWakeGate.route(
      protectedDataAvailable: protected, decision: decision, risk: risk, hasCredentials: credentials != nil)
    {
    case .openApp:
      await report(protected ? "failed" : "locked")
      return .openApp
    case .authenticateThenSend:
      guard await authenticate(sessionId: sessionId) else { return .abandoned }
    case .send:
      break
    }
    guard let credentials, await post(credentials, eventId: eventId, decision: decision) else {
      await report("failed")
      return .openApp
    }
    await store.clearPending(sessionId: sessionId, eventId: eventId)
    await report("ok")
    return .decided
  }

  private static func authenticate(sessionId: String) async -> Bool {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
    let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    let reason = zh ? "确认允许这条高风险命令" : "Confirm allowing this high-risk command"
    return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
  }

  /// 2xx within 8 seconds.
  static func post(_ c: BridgeCredentials, eventId: String, decision: WhaleWakeDecision) async -> Bool {
    guard let url = c.decisionURL(eventId: eventId) else { return false }
    return (await send(c, url, ["decision": decision.wire]))?.ok == true
  }

  /// One bridge request: the HTTP status and the JSON body's `status`, or nil (no answer in 8 s).
  static func send(_ c: BridgeCredentials, _ url: URL, _ body: [String: Any]) async -> (ok: Bool, status: String?)? {
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.httpMethod = "POST"
    request.setValue("Bearer \(c.token)", forHTTPHeaderField: "authorization")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "idempotency-key")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 8
    let session = URLSession(configuration: config, delegate: PinningDelegate(pin: c.pin), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
      return nil
    }
    let status = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["status"] as? String
    return ((200..<300).contains(http.statusCode), status)
  }

  // MARK: v2

  /// What a bridge reply to an answer / cancel means for the Activity.
  static func settled(_ reply: (ok: Bool, status: String?)?, accept: Set<String>) -> Bool {
    guard let reply, reply.ok else { return false }
    // A 2xx without a status (an older bridge) counts as done.
    return reply.status.map(accept.contains) ?? true
  }

  /// One-tap answer (v2 §2.3 AnswerIntent).
  static func answer(sessionId: String, eventId: String, optionId: String, store: WhaleWakeActivityStore) async
    -> WhaleWakeOutcome
  {
    let protected = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    func report(_ result: String) async {
      await store.decided(["sessionId": sessionId, "eventId": eventId, "decision": "answer", "result": result])
    }
    guard protected else {
      await report("locked")
      return .openApp
    }
    guard let c = BridgeCredentials.load(), let url = c.answerURL(eventId: eventId),
      settled(await send(c, url, ["optionId": optionId]), accept: ["submitted", "already-settled"])
    else {
      await report("failed")
      return .openApp
    }
    await store.clearPending(sessionId: sessionId, eventId: eventId)
    await report("ok")
    return .decided
  }

  /// 「停止」 (v2 §2.3 StopIntent): the first tap arms, a second within five seconds stops.
  static func stop(sessionId: String, store: WhaleWakeActivityStore, now: Date = Date()) async -> WhaleWakeOutcome {
    let protected = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    let armed = await store.stopArmedUntil(sessionId: sessionId)
    func report(_ result: String) async {
      await store.decided(["sessionId": sessionId, "eventId": "", "decision": "stop", "result": result])
    }
    switch WhaleWakeStopGate.step(protectedDataAvailable: protected, armedUntil: armed, now: now) {
    case .openApp:
      await report("locked")
      return .openApp
    case .arm:
      let until = now.addingTimeInterval(WhaleWakeStopGate.window)
      await store.armStop(sessionId: sessionId, until: until)
      // Best effort: the key back to 「停止」 when the window passes (a tap after it re-arms anyway).
      Task {
        try? await Task.sleep(nanoseconds: UInt64((WhaleWakeStopGate.window + 0.3) * 1_000_000_000))
        await store.disarmStop(sessionId: sessionId, ifUntil: until)
      }
      return .decided
    case .send:
      guard let c = BridgeCredentials.load(), let url = c.cancelURL(sessionId: sessionId),
        settled(await send(c, url, [:]), accept: ["submitted", "not-running"])
      else {
        await report("failed")
        return .openApp
      }
      await store.stopping(sessionId: sessionId)
      await report("ok")
      return .decided
    }
  }
}

/// Pinned mode: the leaf certificate's SHA-256 must match (a self-signed bridge); otherwise the
/// system's trust evaluation.
final class PinningDelegate: NSObject, URLSessionDelegate {
  let pin: String?

  init(pin: String?) { self.pin = pin }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust, let pin
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
      PinningDelegate.fingerprint(SecCertificateCopyData(leaf) as Data) == pin
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  static func fingerprint(_ der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
  }
}
