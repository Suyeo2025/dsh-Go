// DSH Go's Notification Service Extension (com.colex.dshgo.notify): opens the E2EE body of a `dg`
// push with this phone's key (shared Keychain group, written by the App through dsh/push
// setNotificationSecrets) and shows the real title and text, masked. Anything it can't open goes
// out exactly as it came (the generic copy), never dropped. Contract: plan/design/notify-v3-contract.md §4.3.

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private var deliver: ((UNNotificationContent) -> Void)?
  private var fallback: UNNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    deliver = contentHandler
    fallback = request.content
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      finish(request.content)
      return
    }
    let userInfo = content.userInfo
    if let rendered = DgNotify.render(userInfo: userInfo, secrets: DgSecrets.load()) {
      content.title = rendered.title
      content.body = rendered.body
    }
    if #available(iOS 15.0, *) { content.relevanceScore = DgNotify.relevance(userInfo) }
    finish(content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let fallback { finish(fallback) }
  }

  private func finish(_ content: UNNotificationContent) {
    guard let deliver else { return }
    self.deliver = nil
    deliver(content)
  }
}
