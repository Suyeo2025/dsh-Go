// 「鲸游」Live Activity: ContentState wire format, copy, the Allow / Deny gate, bridge credentials,
// and rendered boards of every state (XCTAttachment PNGs; tooling/ios/la-sim-mac.zsh exports them
// to logs/live-activity/). The rendered boards compose the island regions the way the system lays
// them out, approximately: the system's own island chrome and region sizes are not available here.

import ActivityKit
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

  // MARK: v2 (plan/design/live-activity-v2-contract.md)

  /// Contract §1.4, the extreme payload.
  let v2Extreme = """
    {"v":2,"phase":"question","startedAt":1762399200,"expectedEndAt":1762400400,"progress":0.375,"step":14,
     "toolLabel":"思考中","tokens":34000,
     "pending":{"eventId":"ev_01J","kind":"question","text":"要把旧接口一起删掉吗？","risk":"unknown","askedAt":1762400000,
       "approvalExpiresAt":1762400120,"expired":false,
       "options":[{"id":"0","label":"删掉"},{"id":"1","label":"保留并标废弃"},{"id":"2","label":"先问我…"}]},
     "todos":[{"s":"done"},{"s":"done"},{"s":"done"},{"s":"active"},{"s":"todo"},{"s":"todo"},{"s":"todo"},{"s":"todo"}],
     "todoDone":3,"todoTotal":8,"todoLabel":"跑测试",
     "others":[],"othersCount":0,"othersPending":0,"summary":null,"summaryLine":null,"showStop":true,"breachTick":0}
    """

  func testV2ExtremePayloadDecodes() throws {
    let s = try decode(v2Extreme)
    XCTAssertEqual(s.v, 2)
    XCTAssertEqual(s.pending?.options?.map(\.id), ["0", "1", "2"])
    XCTAssertEqual(s.answerOptions.map(\.label), ["删掉", "保留并标废弃", "先问我…"])
    XCTAssertEqual(s.buoys.count, 8)
    XCTAssertEqual(s.buoys[3].s, .active)
    XCTAssertEqual(s.todoDone, 3)
    XCTAssertEqual(s.todoTotal, 8)
    XCTAssertEqual(s.todoLabel, "跑测试")
    XCTAssertNil(s.summaryLine)
    XCTAssertTrue(s.stopShown)
    XCTAssertNil(s.stopArmedUntil)
    XCTAssertTrue(s.hasAnswerRow(isStale: false))
    XCTAssertLessThan(s.encodedSize, 4096)
    // Round trip keeps every v2 key.
    XCTAssertEqual(try JSONDecoder().decode(State.self, from: JSONEncoder().encode(s)), s)
  }

  /// A v1 payload (no v2 key): nothing v2 shows, the v1 layout stays.
  func testV1PayloadDrawsV1() throws {
    for json in [contractUpdate, contractEnd] {
      let s = try decode(json)
      XCTAssertNil(s.v)
      XCTAssertNil(s.todos)
      XCTAssertNil(s.pending?.options)
      XCTAssertNil(s.summaryLine)
      XCTAssertFalse(s.stopShown)
      XCTAssertTrue(s.buoys.isEmpty)
      XCTAssertNil(s.laneCaption(WhaleWakeStrings(lang: "zh")))
      XCTAssertFalse(s.hasAnswerRow(isStale: false))
    }
    // A v1 question keeps 「去回答」 in the trailing spot (no row under it).
    var q = try decode(contractUpdate)
    q.phase = .question
    XCTAssertFalse(q.hasAnswerRow(isStale: false))
  }

  func testV2ChannelMapNullsAndCaps() throws {
    let map: [String: Any] = [
      "v": 2, "phase": "running", "startedAt": 100, "expectedEndAt": 700, "step": 2, "toolLabel": "", "progress": NSNull(),
      "pending": NSNull(), "others": [Any](), "othersCount": 0, "othersPending": 0, "breachTick": 0,
      "todos": (0..<11).map { ["s": $0 == 3 ? "active" : ($0 < 3 ? "done" : "weird")] },
      "todoDone": NSNull(), "todoTotal": NSNull(), "todoLabel": NSNull(), "summaryLine": NSNull(), "showStop": NSNull(),
      "stepStartedAt": 150,
    ]
    let s = try State(channelMap: map)
    XCTAssertEqual(s.buoys.count, 8)
    XCTAssertEqual(s.buoys[4].s, .todo)  // unknown state reads as todo
    XCTAssertNil(s.todoTotal)
    XCTAssertFalse(s.stopShown)
    XCTAssertEqual(s.stepStartedAt?.timeIntervalSince1970, 150)
    // Options: more than 3 are cut, an empty list is none.
    let q: [String: Any] = [
      "phase": "question", "startedAt": 100, "expectedEndAt": 700,
      "pending": ["eventId": "e", "kind": "question", "text": "?", "risk": "unknown", "askedAt": 200,
        "options": (0..<5).map { ["id": "\($0)", "label": "o\($0)"] }],
    ]
    XCTAssertEqual(try State(channelMap: q).answerOptions.count, 3)
    var empty = q
    empty["pending"] = ["eventId": "e", "kind": "question", "text": "?", "risk": "unknown", "askedAt": 200, "options": [Any]()]
    XCTAssertNil(try State(channelMap: empty).pending?.options)
  }

  func testOptionsHiddenWhenStaleOrExpiredOrNotAQuestion() throws {
    let now = Date()
    let q = try XCTUnwrap(WhaleWakeSamples.state("v2-question-options", now: now))
    XCTAssertEqual(q.answerOptions.count, 3)
    XCTAssertTrue(q.hasAnswerRow(isStale: false))
    XCTAssertFalse(q.hasAnswerRow(isStale: true))  // stale: 「去回答」 alone, back in the trailing spot
    var expired = q
    expired.pending = .init(eventId: "e", kind: .question, text: "?", risk: "unknown", askedAt: now, expired: true,
      options: q.pending?.options)
    XCTAssertTrue(expired.answerOptions.isEmpty)
    var approval = q
    approval.phase = .approval
    XCTAssertTrue(approval.answerOptions.isEmpty)
  }

  // MARK: Stop: the time check is the safety

  func testStopGate() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    typealias G = WhaleWakeStopGate
    // Locked: into the App, never armed, never sent.
    XCTAssertEqual(G.step(protectedDataAvailable: false, armedUntil: nil, now: now), .openApp)
    XCTAssertEqual(G.step(protectedDataAvailable: false, armedUntil: now.addingTimeInterval(3), now: now), .openApp)
    // First tap: arm.
    XCTAssertEqual(G.step(protectedDataAvailable: true, armedUntil: nil, now: now), .arm)
    // Second tap inside the window: stop.
    XCTAssertEqual(G.step(protectedDataAvailable: true, armedUntil: now.addingTimeInterval(4.9), now: now), .send)
    XCTAssertEqual(G.step(protectedDataAvailable: true, armedUntil: now.addingTimeInterval(0.1), now: now), .send)
    // At or after the end of the window (the view may still say 「再点一次」): arm again, don't stop.
    XCTAssertEqual(G.step(protectedDataAvailable: true, armedUntil: now, now: now), .arm)
    XCTAssertEqual(G.step(protectedDataAvailable: true, armedUntil: now.addingTimeInterval(-30), now: now), .arm)
    // An arming that reaches implausibly far ahead (not ours): arm again.
    XCTAssertEqual(G.step(protectedDataAvailable: true, armedUntil: now.addingTimeInterval(600), now: now), .arm)
  }

  func testStopArmedView() {
    let now = Date()
    let armed = WhaleWakeSamples.state("v2-running-stop-armed", now: now)!
    XCTAssertTrue(armed.stopArmed(now: now))
    XCTAssertFalse(armed.stopArmed(now: now.addingTimeInterval(5)))
    XCTAssertFalse(WhaleWakeSamples.state("v2-running-buoys", now: now)!.stopArmed(now: now))
    // Never on a finished turn, whatever showStop says.
    var done = WhaleWakeSamples.state("v2-done-summary", now: now)!
    done.showStop = true
    XCTAssertFalse(done.stopShown)
  }

  func testStopAndAnswerWithoutPairingOpenNothingRemote() async throws {
    let store = WhaleWakeActivityStore { _, _ in }
    // No Activity here: the first tap arms (a local update with nothing to update) and sends nothing.
    let first = await LiveActivityDecision.stop(sessionId: "session-x", store: store)
    XCTAssertEqual(first, .decided)
    // No pairing: an answer can't be sent; the App opens.
    let answer = await LiveActivityDecision.answer(sessionId: "session-x", eventId: "ev", optionId: "0", store: store)
    XCTAssertEqual(answer, .openApp)
  }

  func testBridgeReplies() throws {
    typealias D = LiveActivityDecision
    XCTAssertFalse(D.settled(nil, accept: ["submitted"]))
    XCTAssertTrue(D.settled((true, "submitted"), accept: ["submitted", "already-settled"]))
    XCTAssertTrue(D.settled((true, "already-settled"), accept: ["submitted", "already-settled"]))
    XCTAssertFalse(D.settled((true, "expired"), accept: ["submitted", "already-settled"]))
    XCTAssertFalse(D.settled((false, "submitted"), accept: ["submitted"]))
    XCTAssertTrue(D.settled((true, nil), accept: ["submitted"]))
    let c = try XCTUnwrap(BridgeCredentials.parse(pairingJSON: #"{"bridge":"https://b.example.com/"}"#, token: "t"))
    XCTAssertEqual(c.answerURL(eventId: "ev/1")?.absoluteString, "https://b.example.com/v1/questions/ev%2F1/answer")
    XCTAssertEqual(c.cancelURL(sessionId: "session-a")?.absoluteString, "https://b.example.com/v1/sessions/session-a/cancel")
    XCTAssertNil(c.cancelURL(sessionId: ""))
  }

  // MARK: Buoys, ring, copy

  func testBuoysRingAndCaption() throws {
    let zh = WhaleWakeStrings(lang: "zh"), en = WhaleWakeStrings(lang: "en")
    let b = try XCTUnwrap(WhaleWakeSamples.state("v2-running-buoys"))
    XCTAssertEqual(b.buoyWhaleFraction, 3.5 / 5, accuracy: 1e-9)  // on the active buoy
    XCTAssertEqual(b.ringFraction ?? -1, 0.6, accuracy: 1e-9)
    XCTAssertEqual(b.laneCaption(zh), "3/5 · 跑测试 · 运行 Bash")
    XCTAssertEqual(try XCTUnwrap(WhaleWakeSamples.state("v2-running-buoys", lang: "en")).laneCaption(en), "3/5 · Run tests · Run Bash")
    var none = b
    none.todos = [.init(.done), .init(.done), .init(.todo)]
    XCTAssertEqual(none.buoyWhaleFraction, 2.0 / 3, accuracy: 1e-9)  // just past the last done
    none.todos = [.init(.done), .init(.done)]
    XCTAssertEqual(none.buoyWhaleFraction, 1.5 / 2, accuracy: 1e-9)  // all done: on the last
    none.todos = [.init(.todo), .init(.todo)]
    XCTAssertEqual(none.buoyWhaleFraction, 0.25, accuracy: 1e-9)  // none yet: the first
    // No todos: the ring runs on the clock (nil here, the system draws it).
    XCTAssertNil(try XCTUnwrap(WhaleWakeSamples.state("running")).ringFraction)
    XCTAssertEqual(try XCTUnwrap(WhaleWakeSamples.state("done")).ringFraction, 1)
    XCTAssertEqual(zh.stopAgain, "再点一次停止")
    XCTAssertEqual(en.stopping, "Stopping")
    XCTAssertEqual(zh.todoLine(done: 3, total: 7, label: nil), "3/7")
    for n in WhaleWakeSamples.v2Names {
      XCTAssertNotNil(WhaleWakeSamples.state(n), n)
      XCTAssertLessThan(WhaleWakeSamples.state(n)!.encodedSize, 4096, n)
    }
  }

  @MainActor
  func testRenderBoardsV2() throws {
    let now = Date()
    for lang in ["zh", "en"] {
      let a = WhaleWakeSamples.attributes(lang: lang)
      var expanded: [AnyView] = []
      var lockDark: [AnyView] = []
      var lockLight: [AnyView] = []
      for name in WhaleWakeSamples.v2Names {
        let s = try XCTUnwrap(WhaleWakeSamples.state(name, lang: lang, now: now))
        expanded.append(AnyView(labelled(name, IslandExpanded(attributes: a, state: s, isStale: false))))
        lockDark.append(AnyView(labelled(name, LockOnWallpaper(attributes: a, state: s, isStale: false, dark: true))))
        lockLight.append(AnyView(labelled(name, LockOnWallpaper(attributes: a, state: s, isStale: false, dark: false))))
      }
      try attach("v2-expanded-\(lang)", grid(expanded, columns: 2))
      try attach("v2-lock-dark-\(lang)", grid(lockDark, columns: 2))
      try attach("v2-lock-light-\(lang)", grid(lockLight, columns: 2))
      // Minimal rings and the iOS 27 width-limited compact (landscape), over v1 and v2 states.
      var small: [AnyView] = []
      for name in ["running", "v2-running-buoys", "v2-running-many", "approval", "v2-question-options", "multi", "done", "failed"] {
        let s = try XCTUnwrap(WhaleWakeSamples.state(name, lang: lang, now: now))
        small.append(AnyView(labelled(name, HStack(spacing: 14) {
          IslandMinimal(state: s)
          IslandLimited(attributes: a, state: s)
        })))
      }
      try attach("v2-minimal-limited-\(lang)", grid(small, columns: 4))
    }
  }

  // MARK: v3 (plan/design/notify-v3-contract.md §2)

  /// A phase this build doesn't know (a newer bridge) draws as running; "background" is known.
  func testUnknownPhaseReadsAsRunning() throws {
    let base: [String: Any] = ["startedAt": 100, "expectedEndAt": 700, "step": 1, "toolLabel": ""]
    var future = base
    future["phase"] = "hibernating"
    XCTAssertEqual(try State(channelMap: future).phase, .running)
    var bg = base
    bg["phase"] = "background"
    XCTAssertEqual(try State(channelMap: bg).phase, .background)
    var missing = base
    missing["phase"] = NSNull()
    XCTAssertEqual(try State(channelMap: missing).phase, .running)
    // Same through ActivityKit's own decoding path (plain JSON).
    XCTAssertEqual(try decode(#"{"phase":"zzz","startedAt":1,"expectedEndAt":2}"#).phase, .running)
  }

  func testV3PayloadDecodes() throws {
    let json = """
      {"v":3,"phase":"background","startedAt":1762399200,"expectedEndAt":1762400400,"step":14,"toolLabel":"后台进行中",
       "others":[],"othersCount":0,"othersPending":0,"breachTick":0,"showStop":true,
       "calves":[{"s":"run","l":"审查员"},{"s":"err","l":"文档"},{"s":"weird","l":"x"},{"s":"done","l":"y"}],"calvesMore":2,
       "bubbles":{"run":2,"fail":1,"top":[{"l":"跑集成测试","since":1762400000},{"l":"build","since":1762400100},{"l":"z","since":1}]},
       "wf":{"name":"审查流水线","seg":[{"s":"done","f":1},{"s":"active","f":0.6},{"s":"todo","f":0}],"label":"审查"},
       "team":{"done":3,"total":7},"goal":{"round":3,"max":20},"pendingCount":2,
       "pending":{"eventId":"e","kind":"approval","text":"npm publish","risk":"normal","askedAt":1762400000,"from":"审查员"}}
      """
    let s = try decode(json)
    XCTAssertEqual(s.phase, .background)
    XCTAssertEqual(s.calves?.count, 3)
    XCTAssertEqual(s.calves?[2].s, .run)  // unknown calf state reads as run
    XCTAssertEqual(s.calvesMore, 2)
    XCTAssertEqual(s.bubbles?.top.count, 2)
    XCTAssertEqual(s.bubbles?.fail, 1)
    XCTAssertEqual(s.wf?.current.index, 2)
    XCTAssertEqual(s.wf?.current.of, 3)
    XCTAssertEqual(s.wf?.fraction ?? -1, 1.6 / 3, accuracy: 1e-9)
    XCTAssertEqual(s.laneSource, .workflow)  // wf wins over team
    XCTAssertEqual(s.goal?.round, 3)
    XCTAssertEqual(s.pending?.from, "审查员")
    XCTAssertEqual(s.moreWaiting, 1)
    XCTAssertTrue(s.stopShown)  // background keeps 「停止」
    XCTAssertEqual(s.relevance, 55)
    XCTAssertEqual(try JSONDecoder().decode(State.self, from: JSONEncoder().encode(s)), s)
    XCTAssertLessThan(s.encodedSize, 4096)
  }

  func testV1V2PayloadsHaveNoV3() throws {
    for json in [contractUpdate, contractEnd, v2Extreme] {
      let s = try decode(json)
      XCTAssertNil(s.calves)
      XCTAssertNil(s.bubbles)
      XCTAssertNil(s.wf)
      XCTAssertNil(s.team)
      XCTAssertNil(s.goal)
      XCTAssertNil(s.pendingCount)
      XCTAssertNil(s.pending?.from)
      XCTAssertEqual(s.moreWaiting, 0)
    }
    XCTAssertEqual(try decode(v2Extreme).laneSource, .todos)
    XCTAssertEqual(try decode(contractUpdate).laneSource, .clock)
  }

  func testLaneSourcePriorityAndTeamBuoys() throws {
    let team = try XCTUnwrap(WhaleWakeSamples.state("v3-team-goal"))
    XCTAssertEqual(team.laneSource, .team)
    XCTAssertEqual(team.laneBuoys.map(\.s), [.done, .done, .done, .active, .todo, .todo, .todo])
    XCTAssertEqual(team.ringFraction ?? -1, 3.0 / 7, accuracy: 1e-9)
    var big = team
    big.team = .init(done: 10, total: 20)
    XCTAssertEqual(big.laneBuoys.count, 8)
    XCTAssertEqual(big.laneBuoys.filter { $0.s == .done }.count, 4)
    // A team board beats todos; todos beat the clock.
    var both = team
    both.todos = [.init(.done), .init(.todo)]
    XCTAssertEqual(both.laneSource, .team)
    both.team = nil
    XCTAssertEqual(both.laneSource, .todos)
    // Empty containers are none.
    let s = State(phase: .running, startedAt: Date(), expectedEndAt: Date(), wf: .init(name: "x", seg: []), team: .init(done: 0, total: 0))
    XCTAssertEqual(s.laneSource, .clock)
  }

  func testV3Copy() throws {
    let zh = WhaleWakeStrings(lang: "zh"), en = WhaleWakeStrings(lang: "en")
    XCTAssertEqual(zh.background(jobs: 2, subagents: 0), "主线已回复 · 后台 2 个任务在跑")
    XCTAssertEqual(zh.background(jobs: 0, subagents: 3), "主线已回复 · 3 个子代理在跑")
    XCTAssertEqual(zh.background(jobs: 1, subagents: 2), "主线已回复 · 后台 1 个任务 · 2 个子代理")
    XCTAssertEqual(en.background(jobs: 2, subagents: 0), "Replied · 2 background tasks running")
    XCTAssertEqual(en.background(jobs: 1, subagents: 1), "Replied · 1 task · 1 subagent")
    XCTAssertEqual(zh.backgroundShort(2), "后台 2")
    XCTAssertEqual(en.backgroundShort(2), "2 bg")
    let bg = try XCTUnwrap(WhaleWakeSamples.state("v3-background"))
    XCTAssertEqual(bg.subtitle(zh), "主线已回复 · 后台 2 个任务在跑")
    let from = try XCTUnwrap(WhaleWakeSamples.state("v3-approval-from"))
    XCTAssertTrue(from.subtitle(zh).hasPrefix("子代理 · 审查员 等你确认"))
    XCTAssertEqual(from.bareSubtitle(zh), "子代理 · 审查员 等你确认")
    let wf = try XCTUnwrap(WhaleWakeSamples.state("v3-workflow"))
    XCTAssertEqual(wf.laneCaption(zh), "代码审查流水线 · 阶段 2/4 · 审查")
    XCTAssertEqual(try XCTUnwrap(WhaleWakeSamples.state("v3-team-goal")).laneCaption(zh), "任务板 3/7 · 第 3/20 轮")
    XCTAssertEqual(try XCTUnwrap(WhaleWakeSamples.state("v3-goal-clock")).laneCaption(zh), "正在运行 · 第 5 步 · 读取文件 · 第 4 轮")
    for n in WhaleWakeSamples.v3Names {
      XCTAssertNotNil(WhaleWakeSamples.state(n), n)
      XCTAssertLessThan(WhaleWakeSamples.state(n)!.encodedSize, 4096, n)
    }
  }

  @MainActor
  func testRenderBoardsV3() throws {
    let now = Date()
    for lang in ["zh", "en"] {
      let a = WhaleWakeSamples.attributes(lang: lang)
      var expanded: [AnyView] = []
      var lockDark: [AnyView] = []
      var lockLight: [AnyView] = []
      var small: [AnyView] = []
      for name in WhaleWakeSamples.v3Names {
        let s = try XCTUnwrap(WhaleWakeSamples.state(name, lang: lang, now: now))
        expanded.append(AnyView(labelled(name, IslandExpanded(attributes: a, state: s, isStale: false))))
        lockDark.append(AnyView(labelled(name, LockOnWallpaper(attributes: a, state: s, isStale: false, dark: true))))
        lockLight.append(AnyView(labelled(name, LockOnWallpaper(attributes: a, state: s, isStale: false, dark: false))))
        small.append(AnyView(labelled(name, HStack(spacing: 14) {
          IslandCompact(attributes: a, state: s, isStale: false)
          IslandMinimal(state: s)
        })))
      }
      try attach("v3-expanded-\(lang)", grid(expanded, columns: 2))
      try attach("v3-lock-dark-\(lang)", grid(lockDark, columns: 2))
      try attach("v3-lock-light-\(lang)", grid(lockLight, columns: 2))
      try attach("v3-compact-minimal-\(lang)", grid(small, columns: 2))
    }
  }

  // MARK: Sync (plan/design/sync-contract.md): finished cards nobody ends

  func testFinishedRetentionAndEffectiveStale() throws {
    let now = Date()
    let fresh = try XCTUnwrap(WhaleWakeSamples.state("sync-failed-fresh", now: now))
    XCTAssertFalse(fresh.expired(now: now))
    XCTAssertFalse(fresh.effectivelyStale(false, now: now))
    XCTAssertEqual(fresh.finishedUntil?.timeIntervalSince(fresh.madeAt), 15 * 60)
    // 15 minutes after a failure / 20 after done: out of date without any stale date.
    XCTAssertTrue(fresh.expired(now: fresh.madeAt.addingTimeInterval(15 * 60)))
    let failed = try XCTUnwrap(WhaleWakeSamples.state("sync-failed-stale", now: now))
    XCTAssertTrue(failed.expired(now: now))
    XCTAssertTrue(failed.effectivelyStale(false, now: now))
    let done = try XCTUnwrap(WhaleWakeSamples.state("sync-done-stale", now: now))
    XCTAssertTrue(done.expired(now: now))
    XCTAssertFalse(done.expired(now: done.madeAt.addingTimeInterval(19 * 60)))
    // Running / waiting never expire on their own (the system's stale date covers them).
    for n in ["running", "approval", "question", "v3-background"] {
      let s = try XCTUnwrap(WhaleWakeSamples.state(n, now: now))
      XCTAssertNil(s.finishedUntil, n)
      XCTAssertFalse(s.expired(now: now.addingTimeInterval(86_400)), n)
      XCTAssertTrue(s.effectivelyStale(true, now: now), n)
    }
    // An older payload without updatedAt: the later of its times.
    var old = failed
    old.updatedAt = nil
    XCTAssertEqual(old.madeAt, max(old.expectedEndAt, old.startedAt))
  }

  func testListSummaryShape() throws {
    let now = Date()
    let s = try XCTUnwrap(WhaleWakeSamples.state("sync-failed-stale", now: now))
    let m = WhaleWakeActivityStore.summary(
      sessionId: "s1", activityId: "a1", activityState: "active", state: s, staleDate: nil, pushToken: "ab", local: false,
      hostId: "h1", now: now)
    XCTAssertEqual(m["hostId"] as? String, "h1")
    XCTAssertEqual(m["phase"] as? String, "failed")
    XCTAssertEqual(m["updatedAt"] as? Int, Int(s.updatedAt!.timeIntervalSince1970))
    XCTAssertNil(m["staleDate"])  // absent, not null
    XCTAssertEqual(m["expired"] as? Bool, true)
    XCTAssertEqual(m["local"] as? Bool, false)
    XCTAssertEqual(m["pushToken"] as? String, "ab")
    var bare = s
    bare.updatedAt = nil
    let b = WhaleWakeActivityStore.summary(
      sessionId: "s1", activityId: "a1", activityState: "ended", state: bare, staleDate: now, pushToken: nil, local: true,
      hostId: "", now: now)
    XCTAssertNil(b["updatedAt"])
    XCTAssertNil(b["pushToken"])
    XCTAssertEqual(b["staleDate"] as? Int, Int(now.timeIntervalSince1970))
    XCTAssertFalse(b.values.contains { $0 is NSNull })
    XCTAssertTrue(WhaleWakeActivityStore.needsStaleDate(nil, until: now))
    XCTAssertTrue(WhaleWakeActivityStore.needsStaleDate(now.addingTimeInterval(300), until: now))
    XCTAssertFalse(WhaleWakeActivityStore.needsStaleDate(now.addingTimeInterval(0.5), until: now))
    XCTAssertFalse(WhaleWakeActivityStore.needsStaleDate(now.addingTimeInterval(-60), until: now))
  }

  /// Real ActivityKit (simulator): an Activity that ended and lingers on the lock screen is still
  /// in `activities` / `list`, and `end(activityId, immediate)` takes it away.
  @MainActor
  func testEndReachesEndedActivity() async throws {
    try XCTSkipUnless(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities off")
    let store = WhaleWakeActivityStore { _, _ in }
    let a = WhaleWakeAttributes(sessionId: "session-test-ended", title: "t", hostId: "h", lang: "zh")
    let s = try XCTUnwrap(WhaleWakeSamples.state("sync-failed-fresh"))
    let act = try Activity.request(attributes: a, content: ActivityContent(state: s, staleDate: nil), pushType: nil)
    defer { Task { await act.end(nil, dismissalPolicy: .immediate) } }
    await act.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(600)))
    try await Task.sleep(nanoseconds: 700_000_000)
    let listed = store.list().first { $0["activityId"] as? String == act.id }
    XCTAssertEqual(listed?["state"] as? String, "ended")
    XCTAssertEqual(listed?["phase"] as? String, "failed")
    await store.end(["activityId": act.id, "dismissal": "immediate"])
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let after = Activity<WhaleWakeAttributes>.activities.first { $0.id == act.id }
    XCTAssertTrue(after == nil || after?.activityState == .dismissed, "still \(String(describing: after?.activityState))")
  }

  /// The sweep: a failed card past its 15 minutes is ended; a fresh one gets updatedAt + 15 min as
  /// its stale date.
  @MainActor
  func testSweepEndsExpiredAndDatesFresh() async throws {
    try XCTSkipUnless(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities off")
    let store = WhaleWakeActivityStore { _, _ in }
    func start(_ id: String, _ name: String) throws -> Activity<WhaleWakeAttributes> {
      let s = try XCTUnwrap(WhaleWakeSamples.state(name))
      return try Activity.request(
        attributes: WhaleWakeAttributes(sessionId: id, title: "t", hostId: "h", lang: "zh"),
        content: ActivityContent(state: s, staleDate: nil), pushType: nil)
    }
    let old = try start("session-test-old", "sync-failed-stale")
    let fresh = try start("session-test-fresh", "sync-failed-fresh")
    defer {
      Task {
        await old.end(nil, dismissalPolicy: .immediate)
        await fresh.end(nil, dismissalPolicy: .immediate)
      }
    }
    await store.sweep()
    try await Task.sleep(nanoseconds: 700_000_000)
    XCTAssertNotEqual(old.activityState, .active)
    XCTAssertEqual(fresh.activityState, .active)
    let until = try XCTUnwrap(fresh.content.state.finishedUntil)
    XCTAssertEqual(try XCTUnwrap(fresh.content.staleDate).timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 1.5)
  }

  @MainActor
  func testRenderBoardsSync() throws {
    let now = Date()
    for lang in ["zh", "en"] {
      let a = WhaleWakeSamples.attributes(lang: lang)
      var expanded: [AnyView] = []
      var lockDark: [AnyView] = []
      var lockLight: [AnyView] = []
      var small: [AnyView] = []
      for name in WhaleWakeSamples.syncNames {
        let s = try XCTUnwrap(WhaleWakeSamples.state(name, lang: lang, now: now))
        // approval / question: the system's own stale flag (their data is 11 minutes old).
        let stale = s.effectivelyStale(name.hasSuffix("-stale") && s.finishedUntil == nil, now: now)
        let label = "\(name)\(stale ? " · stale" : "")"
        expanded.append(AnyView(labelled(label, IslandExpanded(attributes: a, state: s, isStale: stale))))
        lockDark.append(AnyView(labelled(label, LockOnWallpaper(attributes: a, state: s, isStale: stale, dark: true))))
        lockLight.append(AnyView(labelled(label, LockOnWallpaper(attributes: a, state: s, isStale: stale, dark: false))))
        small.append(AnyView(labelled(label, HStack(spacing: 14) {
          IslandCompact(attributes: a, state: s, isStale: stale)
          IslandMinimal(state: s)
        })))
      }
      try attach("sync-expanded-\(lang)", grid(expanded, columns: 2))
      try attach("sync-lock-dark-\(lang)", grid(lockDark, columns: 2))
      try attach("sync-lock-light-\(lang)", grid(lockLight, columns: 2))
      try attach("sync-compact-minimal-\(lang)", grid(small, columns: 2))
    }
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

/// iOS 27's width-limited island: the compact leading alone in a 28 pt circle, the trailing empty.
@available(iOS 17.0, *)
private struct IslandLimited: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState

  var body: some View {
    HStack(spacing: 6) {
      WhaleWakeCompactLeading(state: state)
      WhaleWakeCompactTrailing(attributes: attributes, state: state, isStale: false)
    }
    .padding(.horizontal, 6)
    .frame(height: 37)
    .background(Capsule().fill(.black))
    .environment(\.colorScheme, .dark)
    .environment(\.whaleWakeForceLimited, true)
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
