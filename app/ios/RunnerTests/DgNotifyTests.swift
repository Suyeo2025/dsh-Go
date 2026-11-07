// Notifications (notify-v3 §4): the NSE's decryption against vectors sealed by the bridge's own
// src/push/e2ee.ts `seal` (fixed keys and nonce; /tmp generator in the la-native-v3 report), masking,
// and which notification actions may send what.

import UserNotifications
import XCTest

@testable import Runner

final class DgNotifyTests: XCTestCase {
  let devicePriv = "AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw"
  let devicePub = "u1D_noKldM-_gg6X9g-5wUPsdBXPUU-M_Zjv9Z4FlhQ"
  let vectors: [String: (c: String, t: String, k: String, eph: String, ct: String)] = [
    "approval": (c: "DW_APPROVAL", t: "session-child-1", k: "ev_demo_01", eph: "PFgIfCRDXzPqqJ_FKNWxDDGVPTU-47Ox5MklStmKgU0",
      ct: "AAECAwQFBgcICQoLePwOgmKniBmSFylPIxD90Lj0Ilh3KEAYa2-cFI2n8VSY2ba3tMS9wQlOgoEHPJCZVxbh4ARWCXqe9UKeLkfIMyIur8mnI3zQq7Z8MLyMvcwJ1vJRBciB3SGRLYoiqUb4lwQTwwXsr8X0mPah5aeXhbrfV4cSlNzpfqJDoTtAfPKFMFvCk95z5RLTYo31vF5CRxGNmEken8jy-Uvb7aVV1a-syrvv3UXOflhchFhYuHaWpQBQrj72qBl008z1Lr3mChLMhKY3VmcnBFb1Qgsoa89ZLLuVvOEGzPKIpgO5ODF2f7tIdtUm5aXV3ykH-jH97lhXuEZmAxr0qWkI7Q0"),
    "question": (c: "DW_QUESTION", t: "session-root-1", k: "ev_demo_02", eph: "PFgIfCRDXzPqqJ_FKNWxDDGVPTU-47Ox5MklStmKgU0",
      ct: "AAECAwQFBgcICQoLePwOgmKniBmSFylPIxD9wL3hI0NoJkIYa2-cFI2n8VSY2ba3tMS9wQlOgoEHP5CZVxbh4ARWCXqe9UKeLkfIMyIur8mnMnvWs_9gI7KC69cJ1dB-CcDGxTnSPIBz7Uam3AURklTs-4jomuWgpueX2_3OV40BmM7NbsENsjZHefCHNFvCk95z5Q7BPcrloFpASCuAzh9Z04K9ML4jZRu8W1FlTnIfG8BC76qgwxpHuXjatw1d6GGyJ9ecX3dN-x502qtRWBnM64WFwMExwvD75C6-nUJ2Pzi71K3AjXEr0F43SWUeVzEKWDW7"),
    "done": (c: "DG_DONE", t: "session-root-1", k: "done-session-root-1", eph: "PFgIfCRDXzPqqJ_FKNWxDDGVPTU-47Ox5MklStmKgU0",
      ct: "AAECAwQFBgcICQoLePwOgmKniBmSFylPIxD91afqNRUta19fND6QDYaA4T_G2f_wosGLygIOn7FYeZ-EV0mm_AJLBXu69EKeLlfCLSErpdPvJDaV5aE0cu3J8NYy0OpzAYfe3fI0wg3PRYNNDpPHJYhmNAIHYKbgprnQyv3ERIETvN6uINIAtTNFe_SHNFvCk94-EIjOpBDRMa0ymw4hpCWO3g"),
  ]

  var secrets: DgSecrets { DgSecrets.from(privateKey: devicePriv, deviceId: "d1", lang: "zh")! }

  func userInfo(_ kind: String, aad: Bool, dg: [String: Any]) -> [AnyHashable: Any] {
    let v = vectors[kind]!
    var u: [AnyHashable: Any] = ["v": 1, "ciphertext": v.ct, "ephemeralPub": v.eph, "dg": dg, "aps": ["mutable-content": 1]]
    if aad { u["aad"] = ["c": v.c, "t": v.t, "k": v.k] }
    return u
  }

  func testCryptoKitKeysMatchNode() {
    XCTAssertEqual(DgCrypto.publicKey(DgCrypto.unb64u(devicePriv)!).map(DgCrypto.b64u), devicePub)
  }

  func testOpensBridgeSealWithAadBlock() throws {
    let approval = try XCTUnwrap(DgNotify.render(
      userInfo: userInfo("approval", aad: true, dg: ["v": 1, "k": "approval", "s": "session-root-1", "e": "ev_demo_01"]),
      secrets: secrets))
    XCTAssertEqual(approval.title, "重构登录模块")
    // The token in the command is masked (first 8 characters kept).
    XCTAssertEqual(approval.body, "等你确认 · npm run migrate --token=sk-abcde******************")
    let q = try XCTUnwrap(DgNotify.render(
      userInfo: userInfo("question", aad: true, dg: ["v": 1, "k": "question", "s": "session-root-1", "e": "ev_demo_02"]),
      secrets: secrets))
    XCTAssertEqual(q.body, "等你回答 · 要把旧接口一起删掉吗？")
    let en = DgSecrets.from(privateKey: devicePriv, deviceId: "d1", lang: "en")
    let done = try XCTUnwrap(DgNotify.render(
      userInfo: userInfo("done", aad: true, dg: ["v": 1, "k": "done", "s": "session-root-1"]), secrets: en))
    XCTAssertEqual(done.body, "Done")
  }

  /// Without the block (an older bridge): the guesses open the root's own question and the done;
  /// a subagent's approval (envelope thread = the child) stays closed: the generic copy shows.
  func testLegacyGuesses() {
    XCTAssertNotNil(DgNotify.render(
      userInfo: userInfo("question", aad: false, dg: ["v": 1, "k": "question", "s": "session-root-1", "e": "ev_demo_02"]),
      secrets: secrets))
    XCTAssertNotNil(DgNotify.render(
      userInfo: userInfo("done", aad: false, dg: ["v": 1, "k": "done", "s": "session-root-1"]), secrets: secrets))
    XCTAssertNil(DgNotify.render(
      userInfo: userInfo("approval", aad: false, dg: ["v": 1, "k": "approval", "s": "session-root-1", "e": "ev_demo_01"]),
      secrets: secrets))
  }

  func testNothingOpensWithoutTheRightKeyOrAad() {
    let dg: [String: Any] = ["v": 1, "k": "question", "s": "session-root-1", "e": "ev_demo_02"]
    XCTAssertNil(DgNotify.render(userInfo: userInfo("question", aad: true, dg: dg), secrets: nil))
    let other = DgSecrets(privateKey: Data(repeating: 9, count: 32), deviceId: "x", lang: "zh")
    XCTAssertNil(DgNotify.render(userInfo: userInfo("question", aad: true, dg: dg), secrets: other))
    var tampered = userInfo("question", aad: true, dg: dg)
    tampered["aad"] = ["c": "DW_QUESTION", "t": "session-root-2", "k": "ev_demo_02"]
    XCTAssertNil(DgNotify.render(userInfo: tampered, secrets: secrets))
    var cut = userInfo("question", aad: true, dg: dg)
    cut["ciphertext"] = String(vectors["question"]!.ct.dropLast(4))
    XCTAssertNil(DgNotify.render(userInfo: cut, secrets: secrets))
    XCTAssertNil(DgNotify.render(userInfo: ["dg": dg], secrets: secrets))
  }

  func testRenderShapesAndRelevance() {
    XCTAssertEqual(DgNotify.render(dw: ["kind": "done", "outcome": "failed", "sessionTitle": "T", "reason": "测试未通过"], lang: "zh"),
      .init(title: "T", body: "出错了 · 测试未通过"))
    XCTAssertEqual(DgNotify.render(dw: ["kind": "done", "outcome": "completed", "summaryLine": "全部通过"], lang: "zh"),
      .init(title: "DSH Go", body: "做完了 · 全部通过"))
    XCTAssertEqual(DgNotify.render(dw: ["kind": "approval", "title": "A", "body": "line1\nline2"], lang: "zh"),
      .init(title: "A", body: "line1 line2"))
    XCTAssertNil(DgNotify.render(dw: ["kind": "withdraw"], lang: "zh"))
    XCTAssertEqual(DgNotify.render(dw: ["kind": "question", "displayReason": ["zh": "选哪个？", "en": "Which?"]], lang: "en")?.body,
      "Needs an answer · Which?")
    XCTAssertEqual(DgNotify.clean(String(repeating: "长", count: 300), max: 200).count, 200)
    XCTAssertEqual(DgNotify.relevance(["dg": ["k": "approval"]]), 1.0)
    XCTAssertEqual(DgNotify.relevance(["dg": ["k": "failed"]]), 0.8)
    XCTAssertEqual(DgNotify.relevance(["dg": ["k": "done"]]), 0.5)
    XCTAssertEqual(DgNotify.relevance(["dg": ["k": "done"], "aps": ["thread-id": "dsh.automation"]]), 0.3)
  }

  func testMask() {
    XCTAssertEqual(DgMask.mask("key ghp_" + String(repeating: "a", count: 36) + " end"),
      "key ghp_aaaa" + String(repeating: "*", count: 32) + " end")
    XCTAssertEqual(DgMask.mask("https://user:hunter2@example.com/x"), "https://user:*******@example.com/x")
    XCTAssertEqual(DgMask.mask("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"),
      "-----BEGIN RSA PRIVATE KEY-----\n***\n-----END RSA PRIVATE KEY-----")
    XCTAssertEqual(DgMask.mask("nothing here sk-short"), "nothing here sk-short")
  }

  func testSecretsFromChannel() {
    XCTAssertNil(DgSecrets.from(privateKey: "short", deviceId: "d", lang: "zh"))
    XCTAssertNil(DgSecrets.from(privateKey: devicePriv, deviceId: "", lang: "zh"))
    XCTAssertEqual(DgSecrets.from(privateKey: devicePriv, deviceId: "d", lang: "en-US")?.lang, "en")
    XCTAssertEqual(DgSecrets.from(privateKey: devicePriv, deviceId: "d", lang: nil)?.lang, "zh")
    XCTAssertEqual(DgSecrets.accessGroup, "4JV8BHB2KW.com.colex.dshgo.shared")
  }

  // MARK: Actions: never allowed on their own

  func testActionPlans() {
    typealias N = NotifyActions
    XCTAssertEqual(N.plan(action: "allow", category: N.approval, text: nil), .decide(.allow))
    XCTAssertEqual(N.plan(action: "deny", category: N.approval, text: nil), .decide(.deny))
    // A high-risk approval (or anything else) claiming allow only opens the App.
    XCTAssertEqual(N.plan(action: "allow", category: N.approvalHigh, text: nil), .open("open"))
    XCTAssertEqual(N.plan(action: "allow", category: N.question, text: nil), .open("open"))
    XCTAssertEqual(N.plan(action: "reply", category: N.question, text: "  用 SQLite \n"), .answer("用 SQLite"))
    XCTAssertEqual(N.plan(action: "reply", category: N.question, text: "   "), .open("open"))
    XCTAssertEqual(N.plan(action: "reply", category: N.approval, text: "x"), .open("open"))
    XCTAssertEqual(N.plan(action: "view", category: N.done, text: nil), .open("view"))
    XCTAssertEqual(N.plan(action: UNNotificationDefaultActionIdentifier, category: N.done, text: nil), .open(""))
    XCTAssertEqual(N.plan(action: UNNotificationDismissActionIdentifier, category: N.done, text: nil), .ignore)
  }

  func testCategories() throws {
    let cats = Dictionary(uniqueKeysWithValues: NotifyActions.categories(lang: "zh").map { ($0.identifier, $0) })
    XCTAssertEqual(Set(cats.keys), ["DG_APPROVAL", "DG_APPROVAL_HIGH", "DG_QUESTION", "DG_DONE", "DG_FAILED"])
    for a in try XCTUnwrap(cats["DG_APPROVAL"]).actions {
      XCTAssertTrue(a.options.contains(.authenticationRequired), a.identifier)
      XCTAssertFalse(a.options.contains(.foreground), a.identifier)
    }
    XCTAssertEqual(cats["DG_APPROVAL_HIGH"]?.actions.map(\.identifier), ["open"])
    let reply = try XCTUnwrap(cats["DG_QUESTION"]?.actions.first as? UNTextInputNotificationAction)
    XCTAssertEqual(reply.identifier, "reply")
    XCTAssertTrue(reply.options.contains(.authenticationRequired))
    XCTAssertEqual(cats["DG_DONE"]?.actions.map(\.identifier), ["continue", "view"])
    XCTAssertEqual(NotifyActions.categories(lang: "en").first { $0.identifier == "DG_APPROVAL" }?.actions.first?.title, "Allow")
  }
}
