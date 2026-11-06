// 「鲸游」Live Activity: ContentState wire format, copy, the Allow / Deny gate, bridge credentials,
// and rendered boards of every state (XCTAttachment PNGs; tooling/ios/la-sim-mac.zsh exports them
// to logs/live-activity/). The rendered boards compose the island regions the way the system lays
// them out, approximately: the system's own island chrome and region sizes are not available here.

import SwiftUI
import XCTest

@testable import Runner

@available(iOS 17.0, *)
final class WhaleWakeTests: XCTestCase {
  typealias State = WhaleWakeAttributes.ContentState

  /// contract.md §2, `event: update` content-state (before the approvalExpiresAt revision).
  let contractUpdate = """
    {"phase":"approval","startedAt":1762399200,"expectedEndAt":1762400400,"progress":null,"step":14,
     "toolLabel":"运行 Bash","tokens":34000,
     "pending":{"eventId":"ev_01J","kind":"approval","text":"git push --force origin main","risk":"high","askedAt":1762400000},
     "others":[{"sessionId":"s_02","title":"iOS 推送桥","startedAt":1762398900}],
     "othersCount":1,"othersPending":0,"summary":null,"breachTick":0}
    """

  let contractEnd = """
    {"phase":"done","startedAt":1762399200,"expectedEndAt":1762400900,"progress":1,"step":14,"toolLabel":"",
     "tokens":34000,"pending":null,"others":[],"othersCount":0,"othersPending":0,"summary":"14 步 · 12:34","breachTick":1}
    """

  func decode(_ json: String, _ decoder: JSONDecoder = JSONDecoder()) throws -> State {
    try decoder.decode(State.self, from: Data(json.utf8))
  }

  // MARK: Wire format

  func testDecodesContractPayloads() throws {
    let s = try decode(contractUpdate)
    XCTAssertEqual(s.phase, .approval)
    XCTAssertEqual(s.startedAt.timeIntervalSince1970, 1_762_399_200)
    XCTAssertNil(s.progress)
    XCTAssertEqual(s.pending?.risk, "high")
    XCTAssertEqual(s.pending?.askedAt.timeIntervalSince1970, 1_762_400_000)
    // Missing approvalExpiresAt: askedAt + 120 s; missing expired: false.
    XCTAssertEqual(s.pending?.approvalExpiresAt.timeIntervalSince1970, 1_762_400_120)
    XCTAssertEqual(s.pending?.expired, false)
    XCTAssertEqual(s.others.first?.title, "iOS 推送桥")

    let e = try decode(contractEnd)
    XCTAssertEqual(e.phase, .done)
    XCTAssertEqual(e.progress, 1)
    XCTAssertNil(e.pending)
    XCTAssertEqual(e.summary, "14 步 · 12:34")
    XCTAssertEqual(e.breachTick, 1)
  }

  /// Unix seconds whatever the decoder's date strategy (ActivityKit decodes pushes itself).
  func testDatesAreUnixSecondsUnderAnyStrategy() throws {
    let secs = JSONDecoder()
    secs.dateDecodingStrategy = .secondsSince1970
    let iso = JSONDecoder()
    iso.dateDecodingStrategy = .iso8601
    for d in [JSONDecoder(), secs, iso] {
      XCTAssertEqual(try decode(contractUpdate, d).startedAt.timeIntervalSince1970, 1_762_399_200)
    }
  }

  func testRoundTripAndIntegerDates() throws {
    let s = try decode(contractUpdate)
    let data = try JSONEncoder().encode(s)
    let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(obj["startedAt"] as? Int, 1_762_399_200)
    XCTAssertEqual((obj["pending"] as? [String: Any])?["approvalExpiresAt"] as? Int, 1_762_400_120)
    XCTAssertEqual(try JSONDecoder().decode(State.self, from: data), s)
  }

  /// The channel map as la-dart sends it (IslandContent.toMap): explicit NSNull for empty values.
  func testChannelMapWithNulls() throws {
    let map: [String: Any] = [
      "phase": "running", "startedAt": 1_762_399_200, "expectedEndAt": 1_762_400_400, "progress": NSNull(),
      "step": 3, "toolLabel": "读取文件", "tokens": NSNull(), "pending": NSNull(), "others": [Any](),
      "othersCount": 0, "othersPending": 0, "summary": NSNull(), "breachTick": 0, "somethingNew": "ignored",
    ]
    let s = try State(channelMap: map)
    XCTAssertEqual(s.phase, .running)
    XCTAssertNil(s.progress)
    XCTAssertNil(s.tokens)
    XCTAssertNil(s.pending)
    XCTAssertEqual(s.toolLabel, "读取文件")
  }

  func testRevisedPendingFieldsAndOthersCap() throws {
    let map: [String: Any] = [
      "phase": "approval", "startedAt": 100, "expectedEndAt": 700, "step": 1, "toolLabel": "",
      "pending": [
        "eventId": "ev", "kind": "approval", "text": "rm -rf build", "risk": "normal", "askedAt": 200,
        "approvalExpiresAt": 320, "expired": true,
      ],
      "others": (0..<4).map { ["sessionId": "s\($0)", "title": "t", "startedAt": 50] },
      "othersCount": 4, "othersPending": 1, "breachTick": 0,
    ]
    let s = try State(channelMap: map)
    XCTAssertEqual(s.pending?.approvalExpiresAt.timeIntervalSince1970, 320)
    XCTAssertEqual(s.pending?.expired, true)
    XCTAssertEqual(s.others.count, 2)
    XCTAssertEqual(s.othersCount, 4)
  }

  func testEncodedSizeUnderActivityKitLimit() throws {
    let title = String(repeating: "长", count: 24)
    let s = State(
      phase: .approval, startedAt: Date(), expectedEndAt: Date(), progress: 0.5, step: 99_999,
      toolLabel: String(repeating: "工", count: 12), tokens: 999_999_999,
      pending: .init(eventId: String(repeating: "e", count: 128), kind: .approval, text: String(repeating: "命", count: 48), risk: "unknown", askedAt: Date()),
      others: [.init(sessionId: String(repeating: "s", count: 128), title: title, startedAt: Date()),
               .init(sessionId: String(repeating: "t", count: 128), title: title, startedAt: Date())],
      othersCount: 99, othersPending: 99, summary: String(repeating: "因", count: 48), breachTick: 9, updatedAt: Date(), ended: true)
    XCTAssertLessThan(s.encodedSize, 4096)
  }

  // MARK: Folding: expired and stale are separate

  func testExpiredAndStaleEachFoldTheButtons() throws {
    let now = Date()
    let fresh = try XCTUnwrap(WhaleWakeSamples.state("approval", now: now))
    XCTAssertFalse(WhaleWakeApprovalKeys.folded(fresh, isStale: false, now: now))
    // Stale data alone folds them.
    XCTAssertTrue(WhaleWakeApprovalKeys.folded(fresh, isStale: true, now: now))
    // expired alone (not stale) folds them.
    let expired = try XCTUnwrap(WhaleWakeSamples.state("approval-expired", now: now))
    XCTAssertTrue(expired.pending!.expired)
    XCTAssertTrue(WhaleWakeApprovalKeys.folded(expired, isStale: false, now: now))
    // Past approvalExpiresAt at the snapshot, even before the expired update arrives.
    XCTAssertTrue(WhaleWakeApprovalKeys.folded(fresh, isStale: false, now: now.addingTimeInterval(121)))
    let s = WhaleWakeStrings(lang: "zh")
    XCTAssertTrue(expired.subtitle(s, now: now).hasPrefix("仍在等你确认 · "))
    XCTAssertTrue(fresh.subtitle(s, now: now).hasPrefix("等你确认 · "))
  }

  // MARK: Copy

  func testCopyFollowsLang() throws {
    let zh = WhaleWakeStrings(lang: "zh"), en = WhaleWakeStrings(lang: "en")
    let running = try XCTUnwrap(WhaleWakeSamples.state("running"))
    XCTAssertEqual(running.subtitle(zh), "正在运行 · 第 14 步 · 运行 Bash")
    XCTAssertEqual(try XCTUnwrap(WhaleWakeSamples.state("running", lang: "en")).subtitle(en), "Running · step 14 · Run Bash")
    XCTAssertEqual(zh.tokens(34_000), "3.4 万 tok")
    XCTAssertEqual(en.tokens(34_000), "34k tok")
    XCTAssertEqual(en.tokens(3_400), "3.4k tok")
    XCTAssertEqual(zh.tokens(800), "800 tok")
    XCTAssertEqual(zh.sessionsRunning(2), "2 个对话在跑")
    XCTAssertEqual(en.sessionsShort(2), "×2")
    XCTAssertEqual(try XCTUnwrap(WhaleWakeSamples.state("done")).subtitle(zh), "做完了 · 14 步 · 12:34")
    XCTAssertEqual(try XCTUnwrap(WhaleWakeSamples.state("failed")).subtitle(zh), "出错了 · 测试未通过")
    let approval = try XCTUnwrap(WhaleWakeSamples.state("approval"))
    XCTAssertEqual(approval.bareSubtitle(zh), "等你确认")
    XCTAssertEqual(WhaleWakeClock.format(754), "12:34")
    XCTAssertEqual(WhaleWakeClock.format(3723), "1:02:03")
  }

  func testFramesPerState() throws {
    func f(_ n: String, compact: Bool) throws -> String { try XCTUnwrap(WhaleWakeSamples.state(n)).frame(compact: compact) }
    XCTAssertEqual(try f("running", compact: true), "swim")
    XCTAssertEqual(try f("approval", compact: true), "approval")
    XCTAssertEqual(try f("question", compact: false), "question")
    XCTAssertEqual(try f("multi", compact: true), "multi")
    XCTAssertEqual(try f("failed", compact: false), "failed")
    // done: the closing snapshot lands; the update that reports it leaps.
    XCTAssertEqual(try f("done", compact: false), "done")
    var leap = try XCTUnwrap(WhaleWakeSamples.state("done"))
    leap.ended = nil
    XCTAssertEqual(leap.frame(compact: false), "breach")
    XCTAssertEqual(leap.frame(compact: true), "done")
    // Every frame name the views ask for exists in the extension's catalog.
    for n in WhaleWakeSamples.names {
      let s = try XCTUnwrap(WhaleWakeSamples.state(n))
      for name in ["compact-" + s.frame(compact: true), "lock-" + s.frame(compact: false), "lock-breach"] {
        XCTAssertNotNil(UIImage(named: name, in: WhaleWakeAssets.bundle, with: nil), name)
      }
    }
  }

  func testSessionURL() {
    XCTAssertEqual(WhaleWakeAttributes.sessionURL("session-abc").absoluteString, "dshgo://session/session-abc")
    XCTAssertEqual(
      WhaleWakeAttributes.sessionURL("session-abc", eventId: "ev_1").absoluteString, "dshgo://session/session-abc#event=ev_1")
  }

  // MARK: Allow / Deny

  func testGateNeverSendsLockedOrUnpaired() {
    XCTAssertEqual(WhaleWakeGate.route(protectedDataAvailable: false, decision: .allow, risk: "normal", hasCredentials: true), .openApp)
    XCTAssertEqual(WhaleWakeGate.route(protectedDataAvailable: false, decision: .deny, risk: nil, hasCredentials: true), .openApp)
    XCTAssertEqual(WhaleWakeGate.route(protectedDataAvailable: true, decision: .allow, risk: "normal", hasCredentials: false), .openApp)
    XCTAssertEqual(WhaleWakeGate.route(protectedDataAvailable: true, decision: .allow, risk: "high", hasCredentials: true), .authenticateThenSend)
    XCTAssertEqual(WhaleWakeGate.route(protectedDataAvailable: true, decision: .deny, risk: "high", hasCredentials: true), .send)
    XCTAssertEqual(WhaleWakeGate.route(protectedDataAvailable: true, decision: .allow, risk: "normal", hasCredentials: true), .send)
    XCTAssertEqual(WhaleWakeDecision.deny.wire, "reject")
  }

  /// Keychain or pairing missing: nothing to send with, the intent opens the App.
  func testCredentialsNeedPairingAndToken() throws {
    let json = #"{"bridge":"https://bridge.example.com:8443/","hostId":"h","deviceId":"d","pin":"ABCDEF"}"#
    XCTAssertNil(BridgeCredentials.parse(pairingJSON: json, token: nil))
    XCTAssertNil(BridgeCredentials.parse(pairingJSON: nil, token: "t"))
    XCTAssertNil(BridgeCredentials.parse(pairingJSON: #"{"bridge":"ftp://x"}"#, token: "t"))
    let c = try XCTUnwrap(BridgeCredentials.parse(pairingJSON: json, token: "t"))
    XCTAssertEqual(c.pin, "abcdef")
    XCTAssertEqual(
      c.decisionURL(eventId: "ev/1 x")?.absoluteString, "https://bridge.example.com:8443/v1/approvals/ev%2F1%20x/decision")
    // The test host has no pairing: the real load finds nothing.
    XCTAssertNil(BridgeCredentials.load())
  }

  func testDecisionWithoutPairingOpensTheApp() async throws {
    let store = WhaleWakeActivityStore { _, _ in }
    let outcome = await LiveActivityDecision.decide(sessionId: "session-x", eventId: "ev", decision: .allow, store: store)
    XCTAssertEqual(outcome, .openApp)
  }

  // MARK: Rendered boards

  @MainActor
  func testRenderBoards() throws {
    let now = Date()
    for lang in ["zh", "en"] {
      let a = WhaleWakeSamples.attributes(lang: lang)
      var compact: [AnyView] = []
      var expanded: [AnyView] = []
      var lockDark: [AnyView] = []
      var lockLight: [AnyView] = []
      for name in WhaleWakeSamples.names {
        let s = try XCTUnwrap(WhaleWakeSamples.state(name, lang: lang, now: now))
        let stale = name == "stale"
        compact.append(AnyView(labelled(name, IslandCompact(attributes: a, state: s, isStale: stale))))
        expanded.append(AnyView(labelled(name, IslandExpanded(attributes: a, state: s, isStale: stale))))
        lockDark.append(AnyView(labelled(name, LockOnWallpaper(attributes: a, state: s, isStale: stale, dark: true))))
        lockLight.append(AnyView(labelled(name, LockOnWallpaper(attributes: a, state: s, isStale: stale, dark: false))))
      }
      let minimal = HStack(spacing: 16) {
        ForEach(["running", "approval", "multi", "done"], id: \.self) { n in
          self.labelled(n, IslandMinimal(state: WhaleWakeSamples.state(n, lang: lang, now: now)!))
        }
      }
      try attach("compact-\(lang)", grid(compact, columns: 3).overlay(alignment: .bottomTrailing) { minimal.padding(16) })
      try attach("expanded-\(lang)", grid(expanded, columns: 2))
      try attach("lock-dark-\(lang)", grid(lockDark, columns: 2))
      try attach("lock-light-\(lang)", grid(lockLight, columns: 2))
    }
    // The revision: big whale only (60 pt lock-* frame) vs the design board's 34.67 pt expanded-* + icon.
    let a = WhaleWakeSamples.attributes()
    var pairs: [AnyView] = []
    for n in ["running", "approval", "question", "done"] {
      let s = WhaleWakeSamples.state(n, now: now)!
      pairs.append(AnyView(labelled("\(n) · 改前（34.67pt + 状态图标）", IslandExpanded(attributes: a, state: s, isStale: false, oldWhale: true))))
      pairs.append(AnyView(labelled("\(n) · 改后（60pt，鲸鱼即状态）", IslandExpanded(attributes: a, state: s, isStale: false))))
    }
    try attach("expanded-whale-compare", grid(pairs, columns: 2))
  }

  @MainActor
  private func attach(_ name: String, _ view: some View) throws {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light).environment(\.whaleWakeStaticLane, true))
    renderer.scale = 3
    let image = try XCTUnwrap(renderer.uiImage, name)
    let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
    attachment.name = "la-\(name).png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func labelled(_ label: String, _ view: some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(.gray)
      view
    }
  }

  private func grid(_ views: [AnyView], columns: Int) -> some View {
    let rows = stride(from: 0, to: views.count, by: columns).map { Array(views[$0..<min($0 + columns, views.count)]) }
    return VStack(alignment: .leading, spacing: 22) {
      ForEach(rows.indices, id: \.self) { r in
        HStack(alignment: .top, spacing: 22) {
          ForEach(rows[r].indices, id: \.self) { c in rows[r][c] }
        }
      }
    }
    .padding(24)
    .background(Color(hex: 0xF4F5F9))
  }
}

// MARK: - Boards (approximate system layout)

@available(iOS 17.0, *)
private struct IslandCompact: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool

  var body: some View {
    HStack(spacing: 0) {
      WhaleWakeCompactLeading(state: state).padding(.leading, 12)
      Spacer(minLength: 0)
      Circle().fill(Color(white: 0.06)).frame(width: 30, height: 30)  // the camera
      Spacer(minLength: 0)
      WhaleWakeCompactTrailing(attributes: attributes, state: state, isStale: isStale).padding(.trailing, 12)
    }
    .frame(width: 126 + 60, height: 37)
    .background(Capsule().fill(.black))
    .environment(\.colorScheme, .dark)
  }
}

@available(iOS 17.0, *)
private struct IslandMinimal: View {
  let state: WhaleWakeState

  var body: some View {
    WhaleWakeMinimal(state: state)
      .frame(width: 45, height: 37)
      .background(Capsule().fill(.black))
  }
}

@available(iOS 17.0, *)
private struct IslandExpanded: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool
  var oldWhale = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        if oldWhale {
          WhaleWakeFrame(name: "expanded-" + state.frame(compact: false), width: 104 / 3, height: 104 / 3)
        } else {
          WhaleWakeExpandedLeading(state: state)
        }
        WhaleWakeExpandedCenter(attributes: attributes, state: state, isStale: isStale).padding(.top, 6)
        if oldWhale && state.phase != .running {
          // The design board's second status icon, which the revision drops.
          WhaleWakeFrame(name: "compact-" + state.frame(compact: true), width: 24, height: 16).padding(.top, 8)
        }
        WhaleWakeExpandedTrailing(attributes: attributes, state: state, isStale: isStale).padding(.top, 6)
      }
      WhaleWakeExpandedBottom(attributes: attributes, state: state, isStale: isStale)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(width: 372, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.black))
    .environment(\.colorScheme, .dark)
  }
}

@available(iOS 17.0, *)
private struct LockOnWallpaper: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool
  let dark: Bool

  var body: some View {
    WhaleWakeLockView(attributes: attributes, state: state, isStale: isStale, drawsCard: true)
      .frame(width: 374)
      .environment(\.colorScheme, dark ? .dark : .light)
      .padding(14)
      .background(
        LinearGradient(
          colors: dark ? [Color(hex: 0x0B1830), Color(hex: 0x1D3557)] : [Color(hex: 0xC9D6F2), Color(hex: 0xEEF2FB)],
          startPoint: .top, endPoint: .bottom))
  }
}
