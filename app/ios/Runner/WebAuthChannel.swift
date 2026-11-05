import AuthenticationServices
import Flutter
import UIKit

/// `dsh/web_auth`: browser sign-in through ASWebAuthenticationSession (Google refuses embedded
/// WebViews). The session catches the `callbackScheme://` redirect itself, so no URL scheme is
/// registered in Info.plist.
///
///   authenticate({url: https URL, callbackScheme: String, ephemeral: Bool}) -> callback URL string
///   errors: CANCELED (user closed the sheet), FAILED (anything else, incl. "busy" when a session
///   is already running). Messages never contain URLs: the callback carries a token.
final class WebAuthChannel: NSObject, FlutterPlugin, ASWebAuthenticationPresentationContextProviding {
  private weak var registrar: FlutterPluginRegistrar?
  private var session: ASWebAuthenticationSession?
  private var anchor: UIWindow?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/web_auth", binaryMessenger: registrar.messenger())
    let instance = WebAuthChannel()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "authenticate" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    guard let urlString = args["url"] as? String, let url = URL(string: urlString),
      url.scheme?.lowercased() == "https", url.host?.isEmpty == false
    else {
      result(FlutterError(code: "FAILED", message: "url must be an https URL", details: nil))
      return
    }
    guard let scheme = args["callbackScheme"] as? String, !scheme.isEmpty else {
      result(FlutterError(code: "FAILED", message: "callbackScheme is required", details: nil))
      return
    }
    let ephemeral = args["ephemeral"] as? Bool ?? false

    guard session == nil else {
      result(FlutterError(code: "FAILED", message: "busy", details: nil))
      return
    }
    guard let window = presentingWindow() else {
      result(FlutterError(code: "FAILED", message: "no window to present from", details: nil))
      return
    }

    let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callbackURL, error in
      DispatchQueue.main.async {
        self?.session = nil
        self?.anchor = nil
        if let callbackURL {
          result(callbackURL.absoluteString)
        } else if let err = error as? ASWebAuthenticationSessionError, err.code == .canceledLogin {
          result(FlutterError(code: "CANCELED", message: "user canceled", details: nil))
        } else {
          let code = (error as NSError?).map { "\($0.domain) \($0.code)" } ?? "no callback"
          result(FlutterError(code: "FAILED", message: "web auth failed (\(code))", details: nil))
        }
      }
    }
    s.prefersEphemeralWebBrowserSession = ephemeral
    s.presentationContextProvider = self
    session = s
    anchor = window
    if !s.start() {
      session = nil
      anchor = nil
      result(FlutterError(code: "FAILED", message: "session did not start", details: nil))
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    anchor ?? presentingWindow() ?? ASPresentationAnchor()
  }

  /// The Flutter view's window, else the key window of the foreground scene.
  private func presentingWindow() -> UIWindow? {
    if let w = registrar?.viewController?.view.window { return w }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.filter { $0.activationState == .foregroundActive }
    for scene in active + scenes {
      if let w = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first { return w }
    }
    return nil
  }
}
