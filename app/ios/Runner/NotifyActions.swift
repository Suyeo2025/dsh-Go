import Foundation
import UIKit
import UserNotifications

/// Actionable `dg` notifications (plan/design/notify-v3-contract.md §4.1): the categories, and what
/// their actions do in the App's process.
///
/// - allow / deny (DG_APPROVAL): `.authenticationRequired`, no `.foreground` — the phone is unlocked
///   before the App runs; `POST /v1/approvals/<e>/decision` with the same request code as ApproveIntent.
///   A high-risk approval comes as DG_APPROVAL_HIGH, which has only 「打开」: never allowed from here.
/// - reply (DG_QUESTION): a text field; `POST /v1/questions/<e>/answer {text}`.
/// - open / view / continue: into the App like a tap (`onTap` with `a`).
/// Every send is one person's action on one event. A failed one (no pairing, non-2xx, 8 s) leaves a
/// local notification 「没能发送，点开处理」 that opens the card; a successful one removes it.
enum NotifyActions {
  static let approval = "DG_APPROVAL"
  static let approvalHigh = "DG_APPROVAL_HIGH"
  static let question = "DG_QUESTION"
  static let done = "DG_DONE"
  static let failed = "DG_FAILED"

  private struct Copy {
    let zh: Bool
    var allow: String { zh ? "允许" : "Allow" }
    var deny: String { zh ? "拒绝" : "Deny" }
    var open: String { zh ? "打开" : "Open" }
    var reply: String { zh ? "回复…" : "Reply…" }
    var send: String { zh ? "发送" : "Send" }
    var placeholder: String { zh ? "输入回答" : "Your answer" }
    var cont: String { zh ? "继续" : "Continue" }
    var view: String { zh ? "查看" : "View" }
    var failedTitle: String { zh ? "没能发送，点开处理" : "Couldn't send — tap to handle" }
  }

  /// The copy language: the App's (from setNotificationSecrets), else the system's.
  static var lang: String {
    if let l = DgSecrets.load()?.lang { return l }
    return (Locale.preferredLanguages.first ?? "zh").hasPrefix("zh") ? "zh" : "en"
  }

  static func categories(lang: String) -> Set<UNNotificationCategory> {
    let c = Copy(zh: !lang.hasPrefix("en"))
    let auth: UNNotificationActionOptions = [.authenticationRequired]
    let fg: UNNotificationActionOptions = [.foreground]
    let open = UNNotificationAction(identifier: "open", title: c.open, options: fg)
    let view = UNNotificationAction(identifier: "view", title: c.view, options: fg)
    return [
      UNNotificationCategory(
        identifier: approval,
        actions: [
          UNNotificationAction(identifier: "allow", title: c.allow, options: auth),
          UNNotificationAction(identifier: "deny", title: c.deny, options: auth.union(.destructive)),
        ], intentIdentifiers: [], options: []),
      UNNotificationCategory(identifier: approvalHigh, actions: [open], intentIdentifiers: [], options: []),
      UNNotificationCategory(
        identifier: question,
        actions: [
          UNTextInputNotificationAction(
            identifier: "reply", title: c.reply, options: auth, textInputButtonTitle: c.send,
            textInputPlaceholder: c.placeholder),
          open,
        ], intentIdentifiers: [], options: []),
      UNNotificationCategory(
        identifier: done, actions: [UNNotificationAction(identifier: "continue", title: c.cont, options: fg), view],
        intentIdentifiers: [], options: []),
      UNNotificationCategory(identifier: failed, actions: [view], intentIdentifiers: [], options: []),
    ]
  }

  static func register() {
    UNUserNotificationCenter.current().setNotificationCategories(categories(lang: lang))
  }

  /// What one action means, before anything is sent.
  enum Plan: Equatable {
    /// Into the App (onTap with this action id).
    case open(String)
    case decide(WhaleWakeDecision)
    case answer(String)
    /// Not ours / nothing to do.
    case ignore
  }

  static func plan(action: String, category: String, text: String?) -> Plan {
    switch action {
    case UNNotificationDefaultActionIdentifier: return .open("")
    case "open", "view", "continue": return .open(action)
    // Only a normal-risk approval carries allow / deny; anything else claiming them opens the App.
    case "allow": return category == approval ? .decide(.allow) : .open("open")
    case "deny": return category == approval ? .decide(.deny) : .open("open")
    case "reply":
      guard category == question else { return .open("open") }
      let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? .open("open") : .answer(String(t.prefix(2000)))
    default: return .ignore
    }
  }

  /// Handles a response to a `dg` notification; calls [completion] once.
  static func handle(_ response: UNNotificationResponse, completion: @escaping () -> Void) {
    let content = response.notification.request.content
    let userInfo = content.userInfo
    let dg = PushChannel.dg(userInfo) ?? [:]
    let text = (response as? UNTextInputNotificationResponse)?.userText
    let plan = plan(action: response.actionIdentifier, category: content.categoryIdentifier, text: text)
    switch plan {
    case .ignore:
      completion()
    case .open(let action):
      PushChannel.shared.didTap(userInfo: userInfo, action: action.isEmpty ? nil : action)
      completion()
    case .decide, .answer:
      guard let eventId = dg["e"] as? String, !eventId.isEmpty else {
        completion()
        return
      }
      let sessionId = dg["s"] as? String ?? ""
      let requestId = response.notification.request.identifier
      Task {
        let ok = await send(plan, eventId: eventId)
        await MainActor.run {
          let center = UNUserNotificationCenter.current()
          if ok {
            center.removeDeliveredNotifications(withIdentifiers: [requestId, failedId(eventId)])
            if #available(iOS 16.2, *) {
              LiveActivityChannel.shared.settled(sessionId: sessionId, eventId: eventId, decision: decisionWord(plan))
            }
          } else {
            postFailure(dg: dg, action: response.actionIdentifier, original: content)
          }
          completion()
        }
      }
    }
  }

  static func decisionWord(_ plan: Plan) -> String {
    switch plan {
    case .decide(let d): return d.rawValue
    case .answer: return "answer"
    default: return ""
    }
  }

  private static func send(_ plan: Plan, eventId: String) async -> Bool {
    guard let c = BridgeCredentials.load() else { return false }
    switch plan {
    case .decide(let d):
      return await BridgeRequest.post(c, eventId: eventId, decision: d)
    case .answer(let text):
      guard let url = c.answerURL(eventId: eventId) else { return false }
      return BridgeRequest.settled(
        await BridgeRequest.send(c, url, ["text": text]), accept: ["submitted", "already-settled"])
    default:
      return false
    }
  }

  static func failedId(_ eventId: String) -> String { "dg-failed-" + eventId }

  /// 「没能发送，点开处理」: opens the card (`onTap` with the action id and `e`).
  private static func postFailure(dg: [String: Any], action: String, original: UNNotificationContent) {
    let c = Copy(zh: !lang.hasPrefix("en"))
    let n = UNMutableNotificationContent()
    n.title = c.failedTitle
    n.body = original.title.isEmpty ? original.body : original.title
    n.threadIdentifier = original.threadIdentifier
    var info = dg
    info["a"] = action
    n.userInfo = ["dg": info]
    if #available(iOS 15.0, *) { n.interruptionLevel = .active }
    let id = failedId(dg["e"] as? String ?? UUID().uuidString)
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: n, trigger: nil))
  }

  // MARK: dsh/push setNotificationSecrets / clearNotificationSecrets

  /// True when the copy for the NSE landed in the shared Keychain group.
  static func setSecrets(_ args: [String: Any]) -> Bool {
    guard let secrets = DgSecrets.from(
      privateKey: args["privateKey"] as? String, deviceId: args["deviceId"] as? String, lang: args["lang"] as? String)
    else { return false }
    let ok = secrets.save()
    UNUserNotificationCenter.current().setNotificationCategories(categories(lang: secrets.lang))
    return ok
  }

  static func clearSecrets() { DgSecrets.clear() }
}
