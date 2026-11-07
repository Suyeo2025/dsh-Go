// DSH Go notifications, shared by Runner (dsh/push setNotificationSecrets, tests) and the
// Notification Service Extension (NotificationService/, com.colex.dshgo.notify).
// Contract: plan/design/notify-v3-contract.md §4.3.
//
// - DgSecrets: this phone's X25519 private key, deviceId and copy language, in the shared Keychain
//   group `<team>.com.colex.dshgo.shared` (service com.colex.dshgo.push), AfterFirstUnlockThisDeviceOnly.
//   The bridge bearer token never goes there: the NSE only decrypts.
// - DgCrypto: the bridge's seal (src/push/e2ee.ts) reversed: X25519 → HKDF-SHA256(salt = eph ‖ dev,
//   info "dw-push-v1", 32) → ChaCha20-Poly1305, ciphertext = base64url(nonce 12 ‖ ct ‖ tag 16).
// - DgNotify.render: title / body from the decrypted payload, masked (DgMask, the bridge's
//   SECRET_FORMATS); nil when nothing opens — the notification then goes out as it came.

import CryptoKit
import Foundation
import Security

// MARK: - Secrets

struct DgSecrets: Equatable {
  let privateKey: Data
  let deviceId: String
  let lang: String

  static let service = "com.colex.dshgo.push"
  static let teamPrefix = "4JV8BHB2KW."
  /// `$(AppIdentifierPrefix)com.colex.dshgo.shared` (both targets' keychain-access-groups).
  static var accessGroup: String { teamPrefix + "com.colex.dshgo.shared" }

  private enum Account: String, CaseIterable { case x25519, deviceId, lang }

  /// From the channel: privateKey is base64url (32 bytes).
  static func from(privateKey: String?, deviceId: String?, lang: String?) -> DgSecrets? {
    guard let raw = privateKey.flatMap(DgCrypto.unb64u), raw.count == 32, let deviceId, !deviceId.isEmpty else { return nil }
    return DgSecrets(privateKey: raw, deviceId: deviceId, lang: lang?.lowercased().hasPrefix("en") == true ? "en" : "zh")
  }

  /// Writes all three (replacing what was there). False when the Keychain refused.
  @discardableResult
  func save() -> Bool {
    var ok = true
    for (account, value) in [
      (Account.x25519, DgCrypto.b64u(privateKey)), (.deviceId, deviceId), (.lang, lang),
    ] {
      ok = Self.write(account, Data(value.utf8)) && ok
    }
    return ok
  }

  static func load() -> DgSecrets? {
    guard let key = read(.x25519).flatMap({ String(data: $0, encoding: .utf8) }),
      let device = read(.deviceId).flatMap({ String(data: $0, encoding: .utf8) })
    else { return nil }
    let lang = read(.lang).flatMap { String(data: $0, encoding: .utf8) }
    return from(privateKey: key, deviceId: device, lang: lang)
  }

  static func clear() {
    for account in Account.allCases {
      SecItemDelete(base(account) as CFDictionary)
    }
  }

  private static func base(_ account: Account) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account.rawValue,
      kSecAttrAccessGroup as String: accessGroup,
    ]
  }

  private static func write(_ account: Account, _ data: Data) -> Bool {
    SecItemDelete(base(account) as CFDictionary)
    var add = base(account)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  private static func read(_ account: Account) -> Data? {
    var q = base(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }
}

// MARK: - Crypto

enum DgCrypto {
  static let info = Data("dw-push-v1".utf8)

  static func b64u(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func unb64u(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
  }

  static func publicKey(_ privateKey: Data) -> Data? {
    (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation
  }

  /// The sealed JSON's bytes, or nil (wrong key, wrong AAD, tampered, malformed).
  static func open(ciphertext: String, ephemeralPub: String, aad: Data, privateKey: Data) -> Data? {
    guard let sealed = unb64u(ciphertext), sealed.count > 28, let eph = unb64u(ephemeralPub), eph.count == 32,
      let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
      let ephKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph),
      let shared = try? priv.sharedSecretFromKeyAgreement(with: ephKey)
    else { return nil }
    let salt = eph + priv.publicKey.rawRepresentation
    let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    let nonceData = sealed.prefix(12)
    let tag = sealed.suffix(16)
    let body = sealed.dropFirst(12).dropLast(16)
    guard let nonce = try? ChaChaPoly.Nonce(data: nonceData),
      let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
    else { return nil }
    return try? ChaChaPoly.open(box, using: key, authenticating: aad)
  }
}

// MARK: - Rendering

enum DgNotify {
  struct Rendered: Equatable {
    let title: String
    let body: String
  }

  /// AADs to try, in order: the bridge's plaintext `aad` block (exact), else the pre-v3 guesses.
  static func aadCandidates(_ userInfo: [AnyHashable: Any]) -> [Data] {
    if let a = userInfo["aad"] as? [AnyHashable: Any], let c = a["c"] as? String, let t = a["t"] as? String,
      let k = a["k"] as? String
    {
      return [Data((c + t + k).utf8)]
    }
    let dg = userInfo["dg"] as? [AnyHashable: Any] ?? [:]
    guard let s = dg["s"] as? String, !s.isEmpty else { return [] }
    let e = dg["e"] as? String
    var out: [Data] = []
    for c in ["DW_APPROVAL", "DW_APPROVAL_HIGH", "DW_QUESTION", "DG_DONE"] {
      for k in [e, "done-" + s].compactMap({ $0 }) where !k.isEmpty {
        out.append(Data((c + s + k).utf8))
      }
    }
    return out
  }

  /// The decrypted payload as a dictionary.
  static func decrypt(_ userInfo: [AnyHashable: Any], secrets: DgSecrets) -> [String: Any]? {
    guard let ct = userInfo["ciphertext"] as? String, let eph = userInfo["ephemeralPub"] as? String else { return nil }
    for aad in aadCandidates(userInfo) {
      if let data = DgCrypto.open(ciphertext: ct, ephemeralPub: eph, aad: aad, privateKey: secrets.privateKey),
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        return obj
      }
    }
    return nil
  }

  static func render(userInfo: [AnyHashable: Any], secrets: DgSecrets?) -> Rendered? {
    guard let secrets, let dw = decrypt(userInfo, secrets: secrets) else { return nil }
    return render(dw: dw, lang: secrets.lang)
  }

  static func render(dw: [String: Any], lang: String) -> Rendered? {
    let zh = !lang.lowercased().hasPrefix("en")
    func str(_ k: String) -> String? { (dw[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func display() -> String? {
      guard let d = dw["displayReason"] as? [String: Any] else { return nil }
      return (d[zh ? "zh" : "en"] as? String) ?? (d["en"] as? String)
    }
    let title = clean(str("title") ?? str("sessionTitle") ?? "DSH Go", max: 60)
    // A body the bridge wrote itself (forward-compatible) wins.
    if let body = str("body") { return Rendered(title: title, body: clean(body, max: 200)) }
    let body: String
    switch dw["kind"] as? String {
    case "approval":
      let what = str("command") ?? display() ?? str("reason") ?? str("toolName") ?? ""
      body = join(zh ? "等你确认" : "Needs approval", what)
    case "question":
      body = join(zh ? "等你回答" : "Needs an answer", display() ?? str("reason") ?? "")
    case "done":
      let ok = (str("outcome") ?? "completed") == "completed"
      let line = str("summaryLine") ?? (ok ? nil : display() ?? str("reason"))
      body = join(ok ? (zh ? "做完了" : "Done") : (zh ? "出错了" : "Failed"), line ?? "")
    default:
      return nil
    }
    return Rendered(title: title, body: clean(body, max: 200))
  }

  /// relevanceScore by `dg.k` (contract §4.3).
  static func relevance(_ userInfo: [AnyHashable: Any]) -> Double {
    let dg = userInfo["dg"] as? [AnyHashable: Any] ?? [:]
    if (userInfo["aps"] as? [AnyHashable: Any])?["thread-id"] as? String == "dsh.automation" { return 0.3 }
    switch dg["k"] as? String {
    case "approval", "question": return 1.0
    case "failed": return 0.8
    case "done": return 0.5
    default: return 0.5
    }
  }

  private static func join(_ head: String, _ tail: String) -> String { tail.isEmpty ? head : "\(head) · \(tail)" }

  /// Masked, one line, at most [max] characters (… past it).
  static func clean(_ s: String, max: Int) -> String {
    let one = DgMask.mask(s).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    return one.count > max ? String(one.prefix(max - 1)) + "…" : one
  }
}

// MARK: - Masking (bridge src/push/liveactivity.ts SECRET_FORMATS / maskSecrets)

enum DgMask {
  private enum Kind { case prefixed, address, keyBlock }

  private static let table: [(String, Kind)] = [
    (#"-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]{0,40}PRIVATE KEY-----|$)"#, .keyBlock),
    (#"\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@?#]{0,256}:([^\s/@?#]+)@"#, .address),
    (#"(?<!\w)sk-(?=[A-Za-z0-9_-]{0,255}\d)[A-Za-z0-9_-]{20,}"#, .prefixed),
    (#"(?<!\w)AIza[A-Za-z0-9_-]{35}"#, .prefixed),
    (#"(?<!\w)gh[pousr]_[A-Za-z0-9]{36,}"#, .prefixed),
    (#"(?<!\w)github_pat_\w{22,}"#, .prefixed),
    (#"(?<!\w)glpat-[A-Za-z0-9_-]{20,}"#, .prefixed),
    (#"(?<!\w)npm_[A-Za-z0-9]{36,}"#, .prefixed),
    (#"(?<!\w)hf_[A-Za-z0-9]{30,}"#, .prefixed),
    (#"(?<!\w)A[KS]IA[A-Z0-9]{16}(?!\w)"#, .prefixed),
    (#"(?<!\w)LTAI[A-Za-z0-9]{12,20}(?!\w)"#, .prefixed),
    (#"(?<!\w)AKID[A-Za-z0-9]{28,36}(?!\w)"#, .prefixed),
    (#"(?<!\w)xox[abprs]-[A-Za-z0-9-]{10,}"#, .prefixed),
    (#"(?<!\w)[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#, .prefixed),
    (#"(?<!\w)whsec_[A-Za-z0-9]{24,}"#, .prefixed),
    (#"(?<!\w)eyJ[A-Za-z0-9_-]{8,2048}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, .prefixed),
  ]

  private static let formats: [(NSRegularExpression, Kind)] = table.map { entry in
    (try! NSRegularExpression(pattern: entry.0), entry.1)
  }

  static func mask(_ text: String) -> String {
    let ns = text as NSString
    var spans: [(NSRange, Kind)] = []
    for (re, kind) in formats {
      for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if kind == .address {
          let pw = m.range(at: 1)
          if pw.location != NSNotFound { spans.append((pw, .address)) }
        } else {
          spans.append((m.range, kind))
        }
      }
    }
    guard !spans.isEmpty else { return text }
    spans.sort { $0.0.location < $1.0.location || ($0.0.location == $1.0.location && NSMaxRange($0.0) > NSMaxRange($1.0)) }
    var merged: [(NSRange, Kind)] = []
    for s in spans {
      if let last = merged.last, s.0.location < NSMaxRange(last.0) {
        let end = max(NSMaxRange(last.0), NSMaxRange(s.0))
        merged[merged.count - 1].0 = NSRange(location: last.0.location, length: end - last.0.location)
        continue
      }
      merged.append(s)
    }
    var out = ""
    var at = 0
    for (r, kind) in merged {
      out += ns.substring(with: NSRange(location: at, length: r.location - at))
      let raw = ns.substring(with: r)
      switch kind {
      case .address: out += marks(raw)
      case .prefixed: out += String(raw.prefix(8)) + marks(String(raw.dropFirst(8)))
      case .keyBlock:
        if let nl = raw.firstIndex(of: "\n") {
          let head = raw[...nl]
          let rest = raw[raw.index(after: nl)...]
          if let end = rest.range(of: "\n-----END", options: .backwards) {
            out += head + marks(String(rest[..<end.lowerBound])) + rest[end.lowerBound...]
          } else {
            out += head + marks(String(rest))
          }
        } else {
          out += marks(raw)
        }
      }
      at = NSMaxRange(r)
    }
    out += ns.substring(from: at)
    return out
  }

  private static func marks(_ s: String) -> String {
    String(s.map { $0 == "\n" || $0 == "\r" ? $0 : "*" })
  }
}
