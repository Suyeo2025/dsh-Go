import Flutter
import UIKit

/// `dsh/links`: incoming `dshgo://…` links and files opened with the app, for
/// app/lib/links/app_links.dart (the Android side is links/LinksPlugin.kt; same contract).
///
/// Dart → native: `ready` (returns true) once its handler is set.
/// Native → Dart: `link` with `{uri}` (a `dshgo://` / `https://` link, or `file://` of a copy in
/// `tmp/links/<uuid>/<name>`) or `{error, name}` for a file that couldn't be read
/// (`too_large` over [maxFileBytes], `unreadable`).
///
/// Sources: SceneDelegate (the cold-start URL in the connection options, and every
/// `scene(_:openURLContexts:)`) and AppDelegate's `application(_:open:options:)` as a fallback.
/// What arrives before `ready` is held and sent, in order, on `ready`; each arrival goes to Dart
/// once (the same URL reported by two of the sources within a moment counts once).
/// `dshgo://share-inbox` is the share extension's wake-up call: it goes to ShareChannel instead.
final class LinksChannel: NSObject {
  static let shared = LinksChannel()

  static let scheme = "dshgo"
  static let shareInboxHost = "share-inbox"
  /// The composer's `maxFileBytes` (lib/state/attachments.dart).
  static let maxFileBytes: Int64 = 200 * 1024 * 1024
  private static let keepArrivals = 6
  private static let duplicateWindow: TimeInterval = 2

  private var channel: FlutterMethodChannel?
  private var ready = false
  private var pending: [[String: Any]] = []
  private var recent: [(url: String, at: Date)] = []
  /// One arrival at a time, in order (files are copied here, off the main thread).
  private let io = DispatchQueue(label: "dsh-links")

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/links", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "ready":
        self.ready = true
        result(true)
        let held = self.pending
        self.pending.removeAll()
        for event in held { self.channel?.invokeMethod("link", arguments: event) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Takes [url] from any source; false when it isn't ours (left to the system / super).
  @discardableResult
  func take(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    switch scheme {
    case LinksChannel.scheme, "https", "http", "file":
      break
    default:
      return false
    }
    onMain {
      guard self.firstTime(url) else { return }
      if scheme == LinksChannel.scheme, url.host?.lowercased() == LinksChannel.shareInboxHost {
        ShareChannel.shared.drain()
        return
      }
      if scheme == "file" {
        self.io.async {
          let event = LinksChannel.copy(url)
          DispatchQueue.main.async { self.deliver(event) }
        }
      } else {
        let text = url.absoluteString
        // Through the queue too, so a link never overtakes a file that came before it.
        self.io.async { DispatchQueue.main.async { self.deliver(["uri": text]) } }
      }
    }
    return true
  }

  /// False for a URL another source already reported a moment ago.
  private func firstTime(_ url: URL) -> Bool {
    let now = Date()
    recent.removeAll { now.timeIntervalSince($0.at) > LinksChannel.duplicateWindow }
    let key = url.absoluteString
    if recent.contains(where: { $0.url == key }) { return false }
    recent.append((key, now))
    return true
  }

  private func deliver(_ event: [String: Any]) {
    if ready, let channel {
      channel.invokeMethod("link", arguments: event)
    } else {
      pending.append(event)
    }
  }

  // MARK: Files

  /// Copies [source] into `tmp/links/<uuid>/` and returns the `link` arguments for it.
  private static func copy(_ source: URL) -> [String: Any] {
    let name = safeName(source.lastPathComponent)
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let fm = FileManager.default
    if let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) > maxFileBytes {
      removeIfInbox(source)
      return ["error": "too_large", "name": name]
    }
    let dir = fm.temporaryDirectory.appendingPathComponent("links", isDirectory: true)
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      prune(dir)
      let slot = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try fm.createDirectory(at: slot, withIntermediateDirectories: true)
      let target = slot.appendingPathComponent(name)
      try fm.copyItem(at: source, to: target)
      removeIfInbox(source)
      let copied = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
      if copied > maxFileBytes {
        try? fm.removeItem(at: slot)
        return ["error": "too_large", "name": name]
      }
      return ["uri": target.absoluteString, "name": name]
    } catch {
      removeIfInbox(source)
      return ["error": "unreadable", "name": name]
    }
  }

  /// A file iOS put in `Documents/Inbox` for us (not opened in place): the copy is ours now.
  private static func removeIfInbox(_ url: URL) {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let inbox = docs.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path + "/"
    if url.standardizedFileURL.path.hasPrefix(inbox) { try? FileManager.default.removeItem(at: url) }
  }

  /// Keeps the last few arrivals.
  private static func prune(_ dir: URL) {
    let fm = FileManager.default
    guard
      let slots = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
    else { return }
    let dated = slots.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
    for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keepArrivals - 1) { try? fm.removeItem(at: old) }
  }

  /// A file name without path separators or control characters (LinksPlugin.kt `safeName`).
  static func safeName(_ name: String) -> String {
    let last = name.split(separator: "/").last.map(String.init) ?? ""
    let banned = CharacterSet(charactersIn: "\\:*?\"<>|").union(.controlCharacters)
    let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.map { banned.contains($0) ? "_" : $0 }))
      .trimmingCharacters(in: .whitespaces)
    let named = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "shared" : cleaned
    return String(named.prefix(120))
  }

  private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
  }
}
