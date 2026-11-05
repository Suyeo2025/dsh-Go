import Flutter
import UIKit
import os

/// `dsh/islands` on iOS: only `device`, which the island budget reads
/// (app/lib/ui/plugins/islands/island_platform.dart; the Android side is islands/IslandsPlugin.kt).
///
///   device -> {totalMem, availMem (bytes), lowRam (< 3 GB), webView: "WKWebView"}
///
/// Everything else (attach, setDark, setTextZoom, pause, resume, destroy, appPss) is Android
/// WebView plumbing with no WKWebView counterpart here: FlutterMethodNotImplemented, which the
/// Dart side treats as "not available". WKWebView follows the app's appearance for
/// `prefers-color-scheme` on its own.
enum IslandsChannel {
  static let lowRamBelow: UInt64 = 3 * 1024 * 1024 * 1024

  static func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/islands", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "device":
        result(device())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // The handler retains nothing but the channel's own closure; keep the channel alive.
    channels.append(channel)
  }

  private static var channels: [FlutterMethodChannel] = []

  static func device() -> [String: Any] {
    let total = ProcessInfo.processInfo.physicalMemory
    return [
      "totalMem": Int(clamping: total),
      "availMem": Int(clamping: os_proc_available_memory()),
      "lowRam": total < lowRamBelow,
      "webView": "WKWebView",
    ]
  }
}
