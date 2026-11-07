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
/// is kept in UserDefaults `dshgo.la.pendingTokens` for takePendingTokens, which also returns every
/// live Activity's current token and the push-to-start token (a token Dart took but couldn't
/// register with the bridge is not lost).
///
/// Reconciling (plan/design/sync-contract.md): `list` gives each Activity's summary (phase, times,
/// stale date, its token, whether this App started it); `end` takes a sessionId or an activityId;
/// `endAll` can `keep` some sessions. Push-started Activities Dart never heard of are in all three.
/// Independently of Dart, a finished card gets a stale date (updatedAt + retention) and is ended once
/// past it, whenever the App sees it (launch, foreground, an update arriving). Everything ActivityKit
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
    WhaleWakeIntentHost.answer = { sessionId, eventId, optionId in
      await LiveActivityDecision.answer(sessionId: sessionId, eventId: eventId, optionId: optionId, store: store)
    }
    WhaleWakeIntentHost.stop = { sessionId in await LiveActivityDecision.stop(sessionId: sessionId, store: store) }
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

  /// A notification action the bridge took (NotifyActions): the Activity drops the request and
  /// Dart hears onDecision, as after the island's own buttons.
  @available(iOS 16.2, *)
  func settled(sessionId: String, eventId: String, decision: String) {
    guard let store, !sessionId.isEmpty else { return }
    Task { @MainActor in
      await store.clearPending(sessionId: sessionId, eventId: eventId)
      store.decided(["sessionId": sessionId, "eventId": eventId, "decision": decision, "result": "ok"])
    }
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
      let kept = takePendingTokens()
      guard #available(iOS 16.2, *), let store else {
        result(kept)
        return
      }
      Task { @MainActor in result(store.withLiveTokens(kept)) }
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
          await store.endAll(dismissal: args["dismissal"] as? String, keep: Set(args["keep"] as? [String] ?? []))
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
    var out: [String: Any] = [
      "supported": LiveActivityChannel.supported, "enabled": info.areActivitiesEnabled,
      "pushToStart": pushToStart, "frequentUpdates": info.frequentPushesEnabled,
    ]
    out["pushToStartToken"] = currentPushToStartToken() ?? NSNull()
    return out
  }

  private func currentPushToStartToken() -> String? {
    if #available(iOS 17.2, *) { return Activity<WhaleWakeAttributes>.pushToStartToken.map(Self.hex) }
    return nil
  }

  /// The stash plus what is live now: each running Activity's token (it wins over a stashed one)
  /// and the push-to-start token.
  func withLiveTokens(_ kept: [String: Any]) -> [String: Any] {
    var tokens: [String: String] = [:]
    for e in kept["activities"] as? [[String: String]] ?? [] {
      if let s = e["sessionId"], let t = e["token"] { tokens[s] = t }
    }
    for a in Activity<WhaleWakeAttributes>.activities where a.activityState == .active || a.activityState == .stale {
      if let t = a.pushToken { tokens[a.attributes.sessionId] = Self.hex(t) }
    }
    return [
      "activities": tokens.sorted { $0.key < $1.key }.map { ["sessionId": $0.key, "token": $0.value] },
      "pushToStart": (kept["pushToStart"] as? String) ?? currentPushToStartToken() ?? NSNull(),
    ]
  }

  /// The Activities the system kept (App relaunched, push-started ones), and every new one.
  nonisolated func adoptExisting() {
    Task { @MainActor in
      for a in Activity<WhaleWakeAttributes>.activities { watch(a) }
      await sweep()
      for await a in Activity<WhaleWakeAttributes>.activityUpdates {
        watch(a)
        await sweep()
      }
    }
    Task { @MainActor in
      for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
        await sweep()
      }
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
    Self.markLocal(activity.id)
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

  /// By sessionId (every Activity of it) or activityId (that one), or both.
  func end(_ args: [String: Any]) async {
    let session = args["sessionId"] as? String
    let id = args["activityId"] as? String
    guard session != nil || id != nil else { return }
    let policy = Self.dismissal(args["dismissal"] as? String)
    for activity in Activity<WhaleWakeAttributes>.activities
    where (session == nil || activity.attributes.sessionId == session) && (id == nil || activity.id == id) {
      var state = (try? Self.state(args["state"])) ?? activity.content.state
      state.ended = true
      await activity.end(ActivityContent(state: state, staleDate: nil, relevanceScore: state.relevance), dismissalPolicy: policy)
    }
  }

  /// Every Activity but those of the sessions in [keep].
  func endAll(dismissal: String?, keep: Set<String> = []) async {
    let policy = Self.dismissal(dismissal)
    for activity in Activity<WhaleWakeAttributes>.activities where !keep.contains(activity.attributes.sessionId) {
      var state = activity.content.state
      state.ended = true
      await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
    }
  }

  func list() -> [[String: Any]] {
    let local = Self.localIds()
    return Activity<WhaleWakeAttributes>.activities.map {
      Self.summary(
        sessionId: $0.attributes.sessionId, activityId: $0.id, activityState: Self.name($0.activityState) ?? "ended",
        state: $0.content.state, staleDate: $0.content.staleDate, pushToken: $0.pushToken.map(Self.hex),
        local: local.contains($0.id), hostId: $0.attributes.hostId)
    }
  }

  /// One `list` entry (sync-contract §5: sessionId, activityId, state, then hostId, phase,
  /// updatedAt, staleDate; extras for diagnostics). Dates in Unix seconds; an absent value is left
  /// out, not null.
  nonisolated static func summary(
    sessionId: String, activityId: String, activityState: String, state: WhaleWakeAttributes.ContentState, staleDate: Date?,
    pushToken: String?, local: Bool, hostId: String, now: Date = Date()
  ) -> [String: Any] {
    func secs(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }
    var out: [String: Any] = [
      "sessionId": sessionId, "activityId": activityId, "state": activityState, "hostId": hostId,
      "phase": state.phase.rawValue, "startedAt": secs(state.startedAt), "expired": state.expired(now: now),
      "ended": state.ended ?? false,
      // false: started by a push (or by an older build); Dart may never have heard of it.
      "local": local,
    ]
    if let d = state.updatedAt { out["updatedAt"] = secs(d) }
    if let d = staleDate { out["staleDate"] = secs(d) }
    if let d = state.finishedUntil { out["finishedUntil"] = secs(d) }
    if let e = state.pending?.eventId { out["pendingEventId"] = e }
    if let t = pushToken { out["pushToken"] = t }
    return out
  }

  // MARK: Finished cards nobody ends

  /// A finished card (done / failed) that is still up: a stale date of updatedAt + retention so the
  /// system greys it on its own, and ended at once when past it. Running / waiting ones and the
  /// ones already ended (they have their own dismissal) are left alone.
  func sweep(now: Date = Date()) async {
    for a in Activity<WhaleWakeAttributes>.activities where a.activityState == .active || a.activityState == .stale {
      var state = a.content.state
      guard let until = state.finishedUntil else { continue }
      if now >= until {
        state.ended = true
        await a.end(ActivityContent(state: state, staleDate: until, relevanceScore: 0), dismissalPolicy: .immediate)
      } else if Self.needsStaleDate(a.content.staleDate, until: until) {
        await a.update(ActivityContent(state: state, staleDate: until, relevanceScore: state.relevance))
      }
    }
  }

  /// No stale date, or one later than the retention allows (a second's slack: no update loop).
  nonisolated static func needsStaleDate(_ staleDate: Date?, until: Date) -> Bool {
    guard let staleDate else { return true }
    return staleDate.timeIntervalSince(until) > 1
  }

  // The Activities this App requested (UserDefaults; pruned to the ones that still exist).
  private static let localKey = "dshgo.la.localIds"

  static func localIds() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: localKey) ?? []) }

  static func markLocal(_ id: String) {
    let live = Set(Activity<WhaleWakeAttributes>.activities.map(\.id))
    UserDefaults.standard.set(Array(localIds().union([id]).intersection(live.union([id]))), forKey: localKey)
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

  // MARK: v2 stop

  func stopArmedUntil(sessionId: String) -> Date? { activity(sessionId)?.content.state.stopArmedUntil }

  /// First tap: 「再点一次停止」 until [until] (a local update; nothing sent).
  func armStop(sessionId: String, until: Date) async {
    await edit(sessionId) { $0.stopArmedUntil = until }
  }

  /// The window passed without a second tap (only if this arming is still the current one).
  func disarmStop(sessionId: String, ifUntil until: Date) async {
    guard let a = activity(sessionId), a.content.state.stopArmedUntil == until else { return }
    await edit(sessionId) { $0.stopArmedUntil = nil }
  }

  /// The bridge took the stop: no key any more, 「正在停止」 until the turn's end arrives.
  func stopping(sessionId: String) async {
    guard let a = activity(sessionId) else { return }
    let s = WhaleWakeStrings(lang: a.attributes.lang)
    await edit(sessionId) {
      $0.showStop = false
      $0.stopArmedUntil = nil
      $0.toolLabel = s.stopping
    }
  }

  private func edit(_ sessionId: String, _ change: (inout WhaleWakeAttributes.ContentState) -> Void) async {
    guard let activity = activity(sessionId) else { return }
    var state = activity.content.state
    change(&state)
    await activity.update(
      ActivityContent(
        state: state, staleDate: activity.content.staleDate ?? Date().addingTimeInterval(Self.staleAfter),
        relevanceScore: state.relevance))
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
      // A pushed update that finishes the turn: the stale date, at once.
      for await content in activity.contentUpdates where content.state.finishedUntil != nil {
        await self?.sweep()
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
    // v2: a finished turn stays on the lock screen for 20 minutes (gone from the island at once).
    case "after20m": return .after(Date().addingTimeInterval(20 * 60))
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
