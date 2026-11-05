import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 「发送到 DSH Go」: the share sheet's target. No UI of its own — it copies what was shared into
/// the App Group's `share-inbox/<uuid>/` (photos scaled like the composer's picker), writes
/// `manifest.json` last, asks the system to open `dshgo://share-inbox` and finishes. DSH Go
/// (Runner/ShareChannel.swift) picks the folder up on that link, or the next time it becomes
/// active, and opens a new conversation with it (lib/ui/shell/system_entry_host.dart).
///
/// Limits match Android's share/SharePlugin.kt: 9 items, 200 MB a file, 400 MB a share, text
/// capped at 200 000 characters. Extensions get ~120 MB of memory: images are downsampled
/// through ImageIO (never fully decoded) and files are copied one at a time.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
  static let appGroup = "group.com.colex.dshgo"
  static let maxItems = 9
  static let maxFileBytes: Int64 = 200 * 1024 * 1024
  static let maxTotalBytes: Int64 = 400 * 1024 * 1024
  static let maxTextChars = 200_000
  static let maxSide = 2560

  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    DispatchQueue.global(qos: .userInitiated).async {
      let written = ShareWriter(items: items).write()
      DispatchQueue.main.async { self.finish(opening: written) }
    }
  }

  private func finish(opening written: Bool) {
    if written, let url = URL(string: "dshgo://share-inbox") { openContainingApp(url) }
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }

  /// Share extensions have no `extensionContext.open`: the application object further up the
  /// responder chain does it. When this doesn't go through, the app drains the inbox the next
  /// time it becomes active.
  private func openContainingApp(_ url: URL) {
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let r = responder {
      if r is UIApplication, r.responds(to: selector), let method = r.method(for: selector) {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let open = unsafeBitCast(method, to: Open.self)
        open(r, selector, url as NSURL, NSDictionary(), nil)
        return
      }
      responder = r.next
    }
  }
}

/// Reads one share's items into a new inbox folder. Runs off the main thread; every provider
/// load is waited for before the next starts (one file in memory / on the way at a time).
private final class ShareWriter {
  init(items: [NSExtensionItem]) { self.items = items }

  let items: [NSExtensionItem]
  private let fm = FileManager.default
  private var texts: [String] = []
  private var subject: String?
  private var files: [[String: Any]] = []
  private var skipped: [[String: Any]] = []
  private var total: Int64 = 0
  private var taken = 0
  private var dir: URL?

  /// True when a share was put in the inbox.
  func write() -> Bool {
    guard let inbox = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: ShareViewController.appGroup)?
      .appendingPathComponent("share-inbox", isDirectory: true)
    else { return false }
    let dir = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      return false
    }
    self.dir = dir
    for item in items {
      if subject == nil, let title = item.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines),
        !title.isEmpty
      {
        subject = title
      }
      var itemText: String?
      if let body = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
        itemText = body
      }
      for provider in item.attachments ?? [] {
        read(provider, alongside: &itemText)
      }
      if let itemText { texts.append(itemText) }
    }
    var text = texts.joined(separator: "\n\n")
    if text.count > ShareViewController.maxTextChars { text = String(text.prefix(ShareViewController.maxTextChars)) }
    if text.isEmpty && files.isEmpty && skipped.isEmpty {
      try? fm.removeItem(at: dir)
      return false
    }
    var manifest: [String: Any] = ["files": files, "skipped": skipped]
    if !text.isEmpty { manifest["text"] = text }
    if let subject { manifest["subject"] = subject }
    guard let data = try? JSONSerialization.data(withJSONObject: manifest),
      (try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)) != nil
    else {
      try? fm.removeItem(at: dir)
      return false
    }
    return true
  }

  // MARK: One attachment

  private func read(_ provider: NSItemProvider, alongside text: inout String?) {
    let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
    let isFileURL = types.contains { $0.conforms(to: .fileURL) }
    // A web page (Safari, a chat app's link): its URL joins the text.
    if !isFileURL, types.contains(where: { $0.conforms(to: .url) }), !types.contains(where: isFileLike) {
      if let url = loadURL(provider), !url.isFileURL {
        let link = url.absoluteString
        if !(text?.contains(link) ?? false) { text = [text, link].compactMap { $0 }.joined(separator: "\n") }
        return
      }
    }
    // Plain text with no file behind it.
    if !types.contains(where: isFileLike), types.contains(where: { $0.conforms(to: .plainText) }) {
      if let string = loadText(provider), !string.isEmpty {
        if !(text?.contains(string) ?? false) { text = [text, string].compactMap { $0 }.joined(separator: "\n\n") }
        return
      }
    }
    // A file (photo, video, document).
    guard taken < ShareViewController.maxItems else {
      skip(provider.suggestedName, "too_many")
      return
    }
    taken += 1
    let type = types.first(where: { $0.conforms(to: .image) })
      ?? types.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .audio) })
      ?? types.first(where: isFileLike) ?? types.first(where: { $0.conforms(to: .data) }) ?? .data
    readFile(provider, type: type, fileURL: isFileURL)
  }

  private func isFileLike(_ type: UTType) -> Bool {
    (type.conforms(to: .data) || type.conforms(to: .fileURL) || type.conforms(to: .content))
      && !type.conforms(to: .plainText) && !type.conforms(to: .url)
  }

  private func loadURL(_ provider: NSItemProvider, as type: UTType = .url) -> URL? {
    var found: URL?
    let done = DispatchSemaphore(value: 0)
    provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
      if let url = item as? URL {
        found = url
      } else if let data = item as? Data {
        found = URL(dataRepresentation: data, relativeTo: nil)
      } else if let string = item as? String {
        found = URL(string: string)
      }
      done.signal()
    }
    done.wait()
    return found
  }

  private func loadText(_ provider: NSItemProvider) -> String? {
    var found: String?
    let done = DispatchSemaphore(value: 0)
    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
      if let string = item as? String {
        found = string
      } else if let data = item as? Data {
        found = String(data: data, encoding: .utf8)
      } else if let attributed = item as? NSAttributedString {
        found = attributed.string
      }
      done.signal()
    }
    done.wait()
    return found?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Copies (or, for a photo that needs it, re-encodes) the provider's file into the folder.
  private func readFile(_ provider: NSItemProvider, type: UTType, fileURL: Bool) {
    let suggested = provider.suggestedName
    // Only a file URL (the Files app, some document providers): the file itself, read in place.
    if fileURL && type == .data {
      guard let url = loadURL(provider, as: .fileURL), url.isFileURL else {
        skip(suggested, "unreadable")
        return
      }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      take(url, suggested: suggested, type: UTType(filenameExtension: url.pathExtension) ?? .data)
      return
    }
    let done = DispatchSemaphore(value: 0)
    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
      // The file is only there until this handler returns: everything happens here.
      if let url {
        self.take(url, suggested: suggested, type: type)
      } else {
        self.skip(suggested, "unreadable")
      }
      done.signal()
    }
    done.wait()
  }

  private func skip(_ name: String?, _ reason: String) {
    var entry: [String: Any] = ["reason": reason]
    if let name { entry["name"] = ShareWriter.safeName(name) }
    skipped.append(entry)
  }

  private func take(_ url: URL, suggested: String?, type: UTType) {
    guard let dir else { return }
    let fileType = UTType(filenameExtension: url.pathExtension) ?? type
    var name = ShareWriter.safeName(suggested ?? url.lastPathComponent)
    if (name as NSString).pathExtension.isEmpty,
      let ext = fileType.preferredFilenameExtension ?? type.preferredFilenameExtension
    {
      name += ".\(ext)"
    }
    if fileType.conforms(to: .image), !fileType.conforms(to: .gif), !fileType.conforms(to: .svg),
      let scaled = ShareImages.prepare(url, into: dir, name: name)
    {
      add(scaled.url, name: scaled.url.lastPathComponent, mime: scaled.mime)
      return
    }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    if size > ShareViewController.maxFileBytes {
      skip(name, "too_large")
      return
    }
    let target = ShareWriter.unique(dir, name)
    do {
      try fm.copyItem(at: url, to: target)
    } catch {
      skip(name, "unreadable")
      return
    }
    add(target, name: target.lastPathComponent, mime: fileType.preferredMIMEType ?? type.preferredMIMEType)
  }

  private func add(_ file: URL, name: String, mime: String?) {
    let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    if size > ShareViewController.maxFileBytes || total + size > ShareViewController.maxTotalBytes {
      try? fm.removeItem(at: file)
      skipped.append(["name": name, "reason": "too_large"])
      return
    }
    total += size
    var entry: [String: Any] = ["name": name, "size": size, "path": file.lastPathComponent]
    if let mime { entry["mime"] = mime }
    files.append(entry)
  }

  static func unique(_ dir: URL, _ name: String) -> URL {
    var candidate = dir.appendingPathComponent(name)
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
      n += 1
    }
    return candidate
  }

  /// A file name without path separators or control characters (LinksPlugin.kt `safeName`).
  static func safeName(_ name: String) -> String {
    let last = name.split(separator: "/").last.map(String.init) ?? ""
    let banned = CharacterSet(charactersIn: "\\:*?\"<>|").union(.controlCharacters)
    let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.map { banned.contains($0) ? "_" : $0 }))
      .trimmingCharacters(in: .whitespaces)
    let named = cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned == "manifest.json" ? "shared" : cleaned
    return String(named.prefix(120))
  }
}

/// Shared photos sized like the composer's own picker (Android share/ShareImages.kt): long side
/// ≤ 2560, HEIC and friends turned into JPEG, the EXIF orientation applied. PNG / JPEG / WebP
/// that already fit and stand upright are copied as they are (screenshots stay lossless).
enum ShareImages {
  private static let keepAsIs: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, "org.webmproject.webp"]

  /// The image to send in [dir]; nil when the original should be copied as it is.
  static func prepare(_ source: URL, into dir: URL, name: String) -> (url: URL, mime: String)? {
    guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    let fits = max(width, height) <= ShareViewController.maxSide
    let type = CGImageSourceGetType(image) as String? ?? ""
    if fits && orientation == 1 && keepAsIs.contains(type) { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), ShareViewController.maxSide),
    ]
    guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
    let alpha: Bool
    switch scaled.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast: alpha = true
    default: alpha = false
    }
    let outType = alpha ? UTType.png : UTType.jpeg
    let stem = (name as NSString).deletingPathExtension
    let target = ShareWriter.unique(dir, "\(stem.isEmpty ? "image" : stem).\(alpha ? "png" : "jpg")")
    guard let out = CGImageDestinationCreateWithURL(target as CFURL, outType.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(out, scaled, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(out) else {
      try? FileManager.default.removeItem(at: target)
      return nil
    }
    return (target, alpha ? "image/png" : "image/jpeg")
  }
}
