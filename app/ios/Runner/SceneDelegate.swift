import Flutter
import UIKit

/// The app's one scene. Flutter's own scene handling stays (every override calls super); on top
/// of it, URLs go to LinksChannel (`dsh/links`) and each activation drains the share inbox
/// (ShareChannel, `dsh/share`).
class SceneDelegate: FlutterSceneDelegate {
  /// Cold start: the URL that launched the app comes with the connection options.
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      LinksChannel.shared.take(context.url)
    }
  }

  /// Warm start: a URL opened while the app runs.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      LinksChannel.shared.take(context.url)
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    // A share made while the app wasn't woken (the extension's open didn't go through).
    ShareChannel.shared.drain()
  }
}
