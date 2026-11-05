import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before anything else, so the tap that cold-started the app reaches PushChannel.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // App-local channels (not pub plugins), registered on the same implicit engine.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshWebAuthChannel") {
      WebAuthChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshPushChannel") {
      PushChannel.shared.attach(messenger: registrar.messenger())
    }
  }

  // MARK: Remote notifications (dsh/push)

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushChannel.shared.didRegister(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    PushChannel.shared.didFailToRegister()
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// Silent push: a withdrawal removes the notification it replaces (the alert went out with
  /// apns-collapse-id = eventId, which iOS uses as its request identifier). No Flutter needed.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard let dg = PushChannel.dg(userInfo) else {
      super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
      return
    }
    if dg["k"] as? String == "withdraw", let eventId = dg["e"] as? String, !eventId.isEmpty {
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [eventId])
      completionHandler(.newData)
    } else {
      completionHandler(.noData)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    guard PushChannel.dg(userInfo) != nil else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    PushChannel.shared.shouldPresent(userInfo: userInfo) { show in
      completionHandler(show ? [.banner, .list, .sound] : [])
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    guard PushChannel.dg(userInfo) != nil else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      PushChannel.shared.didTap(userInfo: userInfo)
    }
    completionHandler()
  }
}
