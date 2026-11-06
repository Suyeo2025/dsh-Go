import ActivityKit
import Flutter
import UIKit

/// `dsh/live_activity`: the 「鲸游」Live Activity (app/lib/live/live_activity_channel.dart is the only
/// caller; contract: plan/ios-wave2-design.md «la-native › 通道契约»).
///
/// Dart → native: status, start, update, end, list, endAll, takePendingTokens.
/// Native → Dart (main thread): onPushToken, onPushToStartToken, onActivityState, onDecision.
///
/// Dates in the `state` maps are Unix seconds. A token Dart doesn't take (no handler yet, an error)
/// is kept in UserDefaults `dshgo.la.pendingTokens` for takePendingTokens. Everything ActivityKit
/// lives in WhaleWakeActivityStore (iOS 16.2+); below that `status.supported` is false and every
/// call answers `unsupported`.
final class LiveActivityChannel: NSObject {
  static let shared = LiveActivityChannel()

  static let pendingTokensKey = "dshgo.la.pendingTokens"
  private static let idShape = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:-]{1,128}$")

  private var channel: FlutterMethodChannel?
  private var storeBox: AnyObject?

  @available(iOS 16.2, *)
  private var store: WhaleWakeActivityStore? { storeBox as? WhaleWakeActivityStore }

  /// At launch, before the engine: the intents' hooks, the Activities still on screen, the
  /// push-to-start token stream (a cold start by an Allow tap has no Flutter yet).
  func prepare() {
    guard #available(iOS 16.2, *), LiveActivityChannel.supported else { return }
    let store = WhaleWakeActivityStore { [weak self] method, args in self?.send(method, args) }
    storeBox = store
    store.adoptExisting()
    WhaleWakeIntentHost.decide = { sessionId, eventId, decision in
      await LiveActivityDecision.decide(sessionId: sessionId, eventId: eventId, decision: decision, store: store)
    }
    WhaleWakeIntentHost.open = { url in _ = LinksChannel.shared.take(url) }
    #if targetEnvironment(simulator)
      if let demo = UserDefaults.standard.string(forKey: "DSHGOLADemo") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { store.demo(demo) }
      }
    #endif
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/live_activity", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  /// iOS 16.2+ on an iPhone (iPadOS shows no Live Activities).
  static var supported: Bool {
    guard #available(iOS 16.2, *) else { return false }
    return UIDevice.current.userInterfaceIdiom == .phone
  }

  static func validId(_ s: String?) -> String? {
    guard let s, idShape.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { return nil }
    return s
  }

  // MARK: Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "takePendingTokens" {
      result(takePendingTokens())
      return
    }
    guard #available(iOS 16.2, *), let store else {
      switch call.method {
      case "status": result(["supported": false, "enabled": false, "pushToStart": false, "frequentUpdates": false])
      case "list": result([])
      case "start", "update": result(FlutterError(code: "unsupported", message: "Live Activities need iOS 16.2 on an iPhone", details: nil))
      case "end", "endAll": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
      return
    }
    Task { @MainActor in
      do {
        switch call.method {
        case "status": result(store.status())
        case "start": result(try await store.start(args))
        case "update":
          try await store.update(args)
          result(nil)
        case "end":
          await store.end(args)
          result(nil)
        case "list": result(store.list())
        case "endAll":
          await store.endAll(dismissal: args["dismissal"] as? String)
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch let e as LiveActivityError {
        result(FlutterError(code: e.code, message: e.message, details: nil))
      } catch {
        result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  // MARK: Native → Dart

  private func send(_ method: String, _ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let channel = self.channel else {
        self?.stash(method, args)
        return
      }
      channel.invokeMethod(method, arguments: args) { [weak self] reply in
        if reply is FlutterError || (reply as AnyObject) === FlutterMethodNotImplemented {
          self?.stash(method, args)
        }
      }
    }
  }

  /// Only tokens are kept: states and decisions are read again through `list` / the host.
  private func stash(_ method: String, _ args: [String: Any]) {
    let defaults = UserDefaults.standard
    var kept = defaults.dictionary(forKey: Self.pendingTokensKey) ?? [:]
    switch method {
    case "onPushToken":
      guard let session = args["sessionId"] as? String, let token = args["token"] as? String else { return }
      var activities = kept["activities"] as? [String: String] ?? [:]
      activities[session] = token
      kept["activities"] = activities
    case "onPushToStartToken":
      guard let token = args["token"] as? String else { return }
      kept["pushToStart"] = token
    default:
      return
    }
    defaults.set(kept, forKey: Self.pendingTokensKey)
  }

  private func takePendingTokens() -> [String: Any] {
    let defaults = UserDefaults.standard
    let kept = defaults.dictionary(forKey: Self.pendingTokensKey) ?? [:]
    defaults.removeObject(forKey: Self.pendingTokensKey)
    let activities = (kept["activities"] as? [String: String] ?? [:]).map { ["sessionId": $0.key, "token": $0.value] }
    var out: [String: Any] = ["activities": activities]
    out["pushToStart"] = kept["pushToStart"] as? String ?? NSNull()
    return out
  }
}

/// An error for Dart: `code` is the contract's (`unsupported`, `disabled`, `failed`, `not-found`).
struct LiveActivityError: Error {
  let code: String
  let message: String

  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

// MARK: - ActivityKit

@available(iOS 16.2, *)
@MainActor
final class WhaleWakeActivityStore {
  typealias Emit = (String, [String: Any]) -> Void
  private let emit: Emit
  private var watched = Set<String>()

  nonisolated init(emit: @escaping Emit) { self.emit = emit }

  /// stale-date of every local update: five minutes (contract revision: not tied to the approval).
  static let staleAfter: TimeInterval = 300

  func status() -> [String: Any] {
    let info = ActivityAuthorizationInfo()
    var pushToStart = false
    if #available(iOS 17.2, *) { pushToStart = true }
    return [
      "supported": LiveActivityChannel.supported, "enabled": info.areActivitiesEnabled,
      "pushToStart": pushToStart, "frequentUpdates": info.frequentPushesEnabled,
    ]
  }

  /// The Activities the system kept (App relaunched, push-started ones), and every new one.
  nonisolated func adoptExisting() {
    Task { @MainActor in
      for a in Activity<WhaleWakeAttributes>.activities { watch(a) }
      for await a in Activity<WhaleWakeAttributes>.activityUpdates { watch(a) }
    }
    if #available(iOS 17.2, *) {
      Task { @MainActor in
        for await data in Activity<WhaleWakeAttributes>.pushToStartTokenUpdates {
          emit("onPushToStartToken", ["token": Self.hex(data)])
        }
      }
    }
  }

  func activity(_ sessionId: String) -> Activity<WhaleWakeAttributes>? {
    let all = Activity<WhaleWakeAttributes>.activities.filter { $0.attributes.sessionId == sessionId }
    return all.first { $0.activityState == .active } ?? all.first { $0.activityState == .stale }
  }

  func start(_ args: [String: Any]) async throws -> [String: Any] {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      throw LiveActivityError("disabled", "Live Activities are off in Settings")
    }
    guard let session = LiveActivityChannel.validId(args["sessionId"] as? String) else {
      throw LiveActivityError("failed", "bad sessionId")
    }
    if let existing = activity(session) { return ["activityId": existing.id] }
    let attributes = WhaleWakeAttributes(
      sessionId: session, title: String((args["title"] as? String ?? "").prefix(24)),
      hostId: args["hostId"] as? String ?? "", lang: args["lang"] as? String ?? "zh")
    let state = try Self.state(args["state"])
    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter), relevanceScore: state.relevance)
    let activity: Activity<WhaleWakeAttributes>
    do {
      activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
    } catch {
      // No push token (simulator, push not provisioned): still a local Activity.
      NSLog("DSH Go: Live Activity with push failed (%@); starting it without", error.localizedDescription)
      do {
        activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
      } catch {
        throw LiveActivityError("failed", error.localizedDescription)
      }
    }
    watch(activity)
    return ["activityId": activity.id]
  }

  func update(_ args: [String: Any]) async throws {
    guard let session = args["sessionId"] as? String, let activity = activity(session) else {
      throw LiveActivityError("not-found", "no Live Activity for this conversation")
    }
    let state = try Self.state(args["state"])
    var alert: AlertConfiguration?
    if let a = args["alert"] as? [String: Any], let title = a["title"] as? String, let body = a["body"] as? String {
      alert = AlertConfiguration(
        title: LocalizedStringResource(String.LocalizationValue(title)),
        body: LocalizedStringResource(String.LocalizationValue(body)), sound: .default)
    }
    await activity.update(
      ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter), relevanceScore: state.relevance),
      alertConfiguration: alert)
  }

  func end(_ args: [String: Any]) async {
    guard let session = args["sessionId"] as? String else { return }
    let policy = Self.dismissal(args["dismissal"] as? String)
    for activity in Activity<WhaleWakeAttributes>.activities where activity.attributes.sessionId == session {
      var state = (try? Self.state(args["state"])) ?? activity.content.state
      state.ended = true
      await activity.end(ActivityContent(state: state, staleDate: nil, relevanceScore: state.relevance), dismissalPolicy: policy)
    }
  }

  func endAll(dismissal: String?) async {
    let policy = Self.dismissal(dismissal)
    for activity in Activity<WhaleWakeAttributes>.activities {
      var state = activity.content.state
      state.ended = true
      await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
    }
  }

  func list() -> [[String: Any]] {
    Activity<WhaleWakeAttributes>.activities.map {
      ["sessionId": $0.attributes.sessionId, "activityId": $0.id, "state": Self.name($0.activityState) ?? "ended"]
    }
  }

  /// After an Allow / Deny the bridge took: nothing pending any more, the turn goes on.
  func clearPending(sessionId: String, eventId: String) async {
    guard let activity = activity(sessionId) else { return }
    var state = activity.content.state
    guard state.pending?.eventId == eventId else { return }
    state.pending = nil
    if state.phase == .approval || state.phase == .question { state.phase = .running }
    state.updatedAt = Date()
    await activity.update(
      ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter), relevanceScore: state.relevance))
  }

  func pendingRisk(sessionId: String, eventId: String) -> String? {
    guard let p = activity(sessionId)?.content.state.pending, p.eventId == eventId else { return nil }
    return p.risk
  }

  func decided(_ args: [String: Any]) { emit("onDecision", args) }

  // MARK: Streams

  private func watch(_ activity: Activity<WhaleWakeAttributes>) {
    guard watched.insert(activity.id).inserted else { return }
    let session = activity.attributes.sessionId
    Task { @MainActor [weak self] in
      for await data in activity.pushTokenUpdates {
        self?.emit("onPushToken", ["sessionId": session, "token": Self.hex(data)])
      }
    }
    Task { @MainActor [weak self] in
      for await state in activity.activityStateUpdates {
        if let name = Self.name(state) { self?.emit("onActivityState", ["sessionId": session, "state": name]) }
        if state == .ended || state == .dismissed { self?.watched.remove(activity.id) }
      }
    }
  }

  // MARK: Helpers

  static func state(_ raw: Any?) throws -> WhaleWakeAttributes.ContentState {
    do {
      var state = try WhaleWakeAttributes.ContentState(channelMap: raw)
      if state.updatedAt == nil { state.updatedAt = Date() }
      return state
    } catch {
      throw LiveActivityError("failed", "bad state: \(error)")
    }
  }

  static func dismissal(_ raw: String?) -> ActivityUIDismissalPolicy {
    switch raw {
    case "immediate": return .immediate
    case "after4s": return .after(Date().addingTimeInterval(4))
    case "after15m": return .after(Date().addingTimeInterval(15 * 60))
    default: return .default
    }
  }

  static func name(_ state: ActivityState) -> String? {
    switch state {
    case .active: return "active"
    case .ended: return "ended"
    case .dismissed: return "dismissed"
    case .stale: return "stale"
    @unknown default: return nil
    }
  }

  static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  // MARK: Simulator-only demo (`-DSHGOLADemo <sample>`, tooling/ios/la-sim-mac.zsh). Not `#if DEBUG`:
  // the Runner target's Debug config sets no DEBUG condition; a simulator build never reaches a phone.

  #if targetEnvironment(simulator)
    func demo(_ name: String) {
      Task { @MainActor in
        await endAll(dismissal: "immediate")
        let lang = UserDefaults.standard.string(forKey: "DSHGOLADemoLang") ?? "zh"
        guard let state = WhaleWakeSamples.state(name, lang: lang) else { return }
        let stale = name == "stale"
        let content = ActivityContent(
          state: state, staleDate: Date().addingTimeInterval(stale ? 2 : Self.staleAfter), relevanceScore: state.relevance)
        var line: String
        do {
          let a = try Activity.request(attributes: WhaleWakeSamples.attributes(lang: lang), content: content, pushType: nil)
          line = "DSHGO_LA_DEMO started \(name) \(a.id) enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)"
        } catch {
          line = "DSHGO_LA_DEMO failed \(name): \(error)"
        }
        NSLog("%@", line)
        Self.demoLog(line)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        Self.demoLog("DSHGO_LA_DEMO after 3s: \(Activity<WhaleWakeAttributes>.activities.map { "\($0.attributes.sessionId)=\(Self.name($0.activityState) ?? "?")" })")
      }
    }

    /// Documents/la-demo.log (tooling/ios/la-sim-mac.zsh reads it from the app container).
    static func demoLog(_ line: String) {
      guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
      let url = dir.appendingPathComponent("la-demo.log")
      let data = Data((line + "\n").utf8)
      if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
      } else {
        try? data.write(to: url)
      }
    }
  #endif
}
