import Flutter
import UIKit

/// `dsh/share`: what the share extension (ios/ShareExtension) received, for
/// app/lib/links/share_intake.dart (the Android side is share/SharePlugin.kt; same contract).
///
/// The extension writes each share to `<App Group>/share-inbox/<uuid>/`: its files and, last,
/// `manifest.json` (`{text, subject, files: [{name, mime, size, path (relative)}],
/// skipped: [{name, reason}]}`), then wakes the app with `dshgo://share-inbox`.
///
/// Draining, once Dart is `ready`, on every `sceneDidBecomeActive` and on `dshgo://share-inbox`:
/// each finished share's files move to `tmp/share/<uuid>/`, Dart gets one `share` call
/// `{text, subject, files: [{path (absolute), name, mime, size}], skipped}`, the inbox folder goes.
/// A share without a manifest is still being written (or its extension died): left alone for a
/// while, then dropped.
final class ShareChannel: NSObject {
  static let shared = ShareChannel()

  static let appGroup = "group.com.colex.dshgo"
  static let inboxName = "share-inbox"
  private static let keepSlots = 4
  /// An inbox folder without a manifest this old is given up on.
  private static let abandonedAfter: TimeInterval = 10 * 60

  private var channel: FlutterMethodChannel?
  private var ready = false
  /// Shares are read one at a time, in order.
  private let io = DispatchQueue(label: "dsh-share")

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dsh/share", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "ready":
        self.ready = true
        result(true)
        self.drain()
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Sends every finished share in the inbox to Dart. Before `ready` it does nothing: the inbox
  /// keeps them (a share moved out before Dart listens would be lost with the process).
  func drain() {
    onMain {
      guard self.ready else { return }
      self.io.async {
        for event in ShareChannel.takeInbox() {
          DispatchQueue.main.async { self.channel?.invokeMethod("share", arguments: event) }
        }
      }
    }
  }

  // MARK: Inbox

  static func inboxURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent(inboxName, isDirectory: true)
  }

  private static func takeInbox() -> [[String: Any]] {
    let fm = FileManager.default
    guard let inbox = inboxURL(),
      let entries = try? fm.contentsOfDirectory(
        at: inbox, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
    else { return [] }
    let dated = entries.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) }
    var events: [[String: Any]] = []
    for (dir, created) in dated.sorted(by: { $0.1 < $1.1 }) {
      let manifest = dir.appendingPathComponent("manifest.json")
      guard fm.fileExists(atPath: manifest.path) else {
        if Date().timeIntervalSince(created) > abandonedAfter { try? fm.removeItem(at: dir) }
        continue
      }
      if let event = take(dir, manifest: manifest) { events.append(event) }
      try? fm.removeItem(at: dir)
    }
    return events
  }

  /// One share folder → the `share` call's arguments (its files moved into the app's tmp).
  private static func take(_ dir: URL, manifest: URL) -> [String: Any]? {
    let fm = FileManager.default
    guard let data = try? Data(contentsOf: manifest),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    var files: [[String: Any]] = []
    var skipped: [[String: Any]] = (json["skipped"] as? [[String: Any]]) ?? []
    let listed = (json["files"] as? [[String: Any]]) ?? []
    if !listed.isEmpty {
      let root = fm.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
      try? fm.createDirectory(at: root, withIntermediateDirectories: true)
      prune(root)
      let slot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? fm.createDirectory(at: slot, withIntermediateDirectories: true)
      let base = dir.standardizedFileURL.path + "/"
      for f in listed {
        let name = (f["name"] as? String).map(LinksChannel.safeName) ?? "shared"
        guard let rel = f["path"] as? String, !rel.isEmpty, !rel.hasPrefix("/") else {
          skipped.append(["name": name, "reason": "unreadable"])
          continue
        }
        // Only files inside this share's folder.
        let source = dir.appendingPathComponent(rel).standardizedFileURL
        guard source.path.hasPrefix(base), fm.fileExists(atPath: source.path) else {
          skipped.append(["name": name, "reason": "unreadable"])
          continue
        }
        let target = unique(slot, name)
        do {
          try fm.moveItem(at: source, to: target)
        } catch {
          skipped.append(["name": name, "reason": "unreadable"])
          continue
        }
        let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        var file: [String: Any] = ["path": target.path, "name": target.lastPathComponent, "size": size]
        if let mime = f["mime"] as? String, !mime.isEmpty { file["mime"] = mime }
        files.append(file)
      }
    }
    var event: [String: Any] = ["files": files, "skipped": skipped]
    if let text = json["text"] as? String, !text.isEmpty { event["text"] = text }
    if let subject = json["subject"] as? String, !subject.isEmpty { event["subject"] = subject }
    return event
  }

  /// `name`, or `name (2).ext` … when taken.
  private static func unique(_ dir: URL, _ name: String) -> URL {
    let fm = FileManager.default
    var candidate = dir.appendingPathComponent(name)
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var n = 2
    while fm.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
      n += 1
    }
    return candidate
  }

  /// Keeps the last few shares (Dart reads them right away; a share code stays a while).
  private static func prune(_ dir: URL) {
    let fm = FileManager.default
    guard
      let slots = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
    else { return }
    let dated = slots.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
    for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keepSlots - 1) { try? fm.removeItem(at: old) }
  }

  private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
  }
}
