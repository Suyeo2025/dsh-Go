import Flutter
import UIKit
import UserNotifications

/// `dsh/push`: remote notifications for DSH Go (app/lib/push/push_channel.dart is the only caller).
///
/// Dart → native: getStatus, requestPermission, register, takeLaunchTap, clearDelivered.
/// Native → Dart (always on the main thread): onToken, onTokenError, onTap, shouldPresent.
///
/// A tap that arrives before Dart is listening (a cold start from a notification) is kept for
/// takeLaunchTap instead of being lost. Withdrawals (silent pushes) are handled in AppDelegate
/// without Flutter.
final class PushChannel: NSObject {
  static let shared = PushChannel()

  private var channel: FlutterMethodChannel?
  /// Dart has called in at least once: its handler for onTap / shouldPresent is set.
  private var dartReady = false
  private var launchTap: [String: Any]?

  static var environment: String {
    #if DEBUG
      return "sandbox"
    #else
      return "production"
    #endif
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  // MARK: Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    dartReady = true
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "getStatus":
      center.getNotificationSettings { settings in
        let auth: String
        switch settings.authorizationStatus {
        case .notDetermined: auth = "notDetermined"
        case .denied: auth = "denied"
        case .authorized: auth = "authorized"
        case .provisional: auth = "provisional"
        case .ephemeral: auth = "ephemeral"
        @unknown default: auth = "notDetermined"
        }
        DispatchQueue.main.async {
          result(["auth": auth, "env": PushChannel.environment, "topic": Bundle.main.bundleIdentifier ?? ""])
        }
      }
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async {
          if granted { UIApplication.shared.registerForRemoteNotifications() }
          result(granted)
        }
      }
    case "register":
      center.getNotificationSettings { settings in
        DispatchQueue.main.async {
          switch settings.authorizationStatus {
          case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
          default:
            break
          }
          result(nil)
        }
      }
    case "takeLaunchTap":
      let tap = launchTap
      launchTap = nil
      result(tap)
    case "clearDelivered":
      guard let sessionId = (call.arguments as? [String: Any])?["sessionId"] as? String, !sessionId.isEmpty else {
        result(nil)
        return
      }
      center.getDeliveredNotifications { delivered in
        let ids = delivered.filter { $0.request.content.threadIdentifier == sessionId }.map { $0.request.identifier }
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        DispatchQueue.main.async { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Native → Dart

  func didRegister(deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    onMain { self.channel?.invokeMethod("onToken", arguments: ["token": token, "env": PushChannel.environment]) }
  }

  func didFailToRegister() {
    onMain { self.channel?.invokeMethod("onTokenError", arguments: ["code": "failed"]) }
  }

  /// The person tapped a notification.
  func didTap(userInfo: [AnyHashable: Any]) {
    guard let dg = PushChannel.dg(userInfo) else { return }
    onMain {
      guard self.dartReady, let channel = self.channel else {
        self.launchTap = dg
        return
      }
      channel.invokeMethod("onTap", arguments: dg) { reply in
        // Nobody listening after all: keep it for takeLaunchTap.
        if reply is FlutterError || (reply as AnyObject?) === FlutterMethodNotImplemented {
          self.launchTap = dg
        }
      }
    }
  }

  /// Foreground notification: Dart decides whether it shows (no answer within 500 ms, or an
  /// error, shows it).
  func shouldPresent(userInfo: [AnyHashable: Any], completion: @escaping (Bool) -> Void) {
    guard let dg = PushChannel.dg(userInfo) else {
      completion(true)
      return
    }
    onMain {
      guard self.dartReady, let channel = self.channel else {
        completion(true)
        return
      }
      var answered = false
      let answer: (Bool) -> Void = { show in
        if answered { return }
        answered = true
        completion(show)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(true) }
      channel.invokeMethod("shouldPresent", arguments: dg) { reply in
        answer((reply as? Bool) ?? true)
      }
    }
  }

  // MARK: Helpers

  /// The payload's `dg` dictionary, with string keys (what the codec can carry).
  static func dg(_ userInfo: [AnyHashable: Any]) -> [String: Any]? {
    guard let raw = userInfo["dg"] as? [AnyHashable: Any] else { return nil }
    var out: [String: Any] = [:]
    for (k, v) in raw {
      if let key = k as? String { out[key] = v }
    }
    return out
  }

  private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
  }
}
