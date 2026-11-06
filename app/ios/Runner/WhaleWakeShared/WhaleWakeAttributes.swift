// 「鲸游」Live Activity: attributes and content state (plan/design/live-activity-a/contract.md §1,
// with the plan/ios-wave2-design.md revision: Pending.approvalExpiresAt / expired).
// Compiled into Runner (LiveActivityChannel, the intents' perform) and WhaleWakeActivity (the views).
//
// Dates are Unix seconds on every wire this crosses (the dsh/live_activity channel map, the bridge's
// APNs content-state). Codable is written out by hand so that holds whatever date strategy the
// decoder uses (ActivityKit decodes pushed content-state with its own decoder). Unknown keys are
// ignored; optional keys may be missing.

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct WhaleWakeAttributes: ActivityAttributes {
  /// One Activity per top-level conversation.
  let sessionId: String
  /// Masked, ≤ 24 characters (the App cuts it; the views only clip).
  let title: String
  let hostId: String
  /// "zh" / "en": the copy, fixed for the Activity's life.
  let lang: String

  struct ContentState: Codable, Hashable {
    enum Phase: String, Codable, Hashable {
      case running, approval, question, done, failed
    }

    var phase: Phase
    var startedAt: Date
    var expectedEndAt: Date
    /// 0…1 when the turn has todos; nil: the lane runs on the clock (capped at 0.9).
    var progress: Double?
    var step: Int
    var toolLabel: String
    var tokens: Int?
    var pending: Pending?
    var others: [Other]
    var othersCount: Int
    var othersPending: Int
    var summary: String?
    var breachTick: Int
    /// Optional (not in contract.md): when this state was made, for 「可能已过时 · N 分钟前更新」.
    var updatedAt: Date?
    /// Optional, set only by LiveActivityChannel.end: the closing snapshot (the done frame lands
    /// instead of the leap).
    var ended: Bool?

    struct Pending: Codable, Hashable {
      enum Kind: String, Codable, Hashable { case approval, question }
      let eventId: String
      let kind: Kind
      /// Masked, ≤ 48 characters.
      let text: String
      /// "normal" / "high" / "unknown".
      let risk: String
      let askedAt: Date
      /// askedAt + 120 s: after it the buttons fold into 「打开」.
      let approvalExpiresAt: Date
      /// Set by one update when approvalExpiresAt passed (bridge or App).
      let expired: Bool

      init(eventId: String, kind: Kind, text: String, risk: String, askedAt: Date, approvalExpiresAt: Date? = nil, expired: Bool = false) {
        self.eventId = eventId
        self.kind = kind
        self.text = text
        self.risk = risk
        self.askedAt = askedAt
        self.approvalExpiresAt = approvalExpiresAt ?? askedAt.addingTimeInterval(120)
        self.expired = expired
      }

      private enum Keys: String, CodingKey { case eventId, kind, text, risk, askedAt, approvalExpiresAt, expired }

      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let asked = try WhaleWakeWire.date(c, .askedAt)
        self.init(
          eventId: try c.decode(String.self, forKey: .eventId),
          kind: (try? c.decode(Kind.self, forKey: .kind)) ?? .approval,
          text: (try? c.decode(String.self, forKey: .text)) ?? "",
          risk: (try? c.decode(String.self, forKey: .risk)) ?? "unknown",
          askedAt: asked,
          approvalExpiresAt: try WhaleWakeWire.dateIfPresent(c, .approvalExpiresAt),
          expired: (try? c.decodeIfPresent(Bool.self, forKey: .expired)) ?? false
        )
      }

      func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(eventId, forKey: .eventId)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encode(risk, forKey: .risk)
        try c.encode(WhaleWakeWire.seconds(askedAt), forKey: .askedAt)
        try c.encode(WhaleWakeWire.seconds(approvalExpiresAt), forKey: .approvalExpiresAt)
        try c.encode(expired, forKey: .expired)
      }
    }

    struct Other: Codable, Hashable {
      let sessionId: String
      let title: String
      let startedAt: Date

      private enum Keys: String, CodingKey { case sessionId, title, startedAt }

      init(sessionId: String, title: String, startedAt: Date) {
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
      }

      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        startedAt = try WhaleWakeWire.date(c, .startedAt)
      }

      func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(title, forKey: .title)
        try c.encode(WhaleWakeWire.seconds(startedAt), forKey: .startedAt)
      }
    }

    init(
      phase: Phase, startedAt: Date, expectedEndAt: Date, progress: Double? = nil, step: Int = 1, toolLabel: String = "",
      tokens: Int? = nil, pending: Pending? = nil, others: [Other] = [], othersCount: Int = 0, othersPending: Int = 0,
      summary: String? = nil, breachTick: Int = 0, updatedAt: Date? = nil, ended: Bool? = nil
    ) {
      self.phase = phase
      self.startedAt = startedAt
      self.expectedEndAt = expectedEndAt
      self.progress = progress
      self.step = step
      self.toolLabel = toolLabel
      self.tokens = tokens
      self.pending = pending
      self.others = others
      self.othersCount = othersCount
      self.othersPending = othersPending
      self.summary = summary
      self.breachTick = breachTick
      self.updatedAt = updatedAt
      self.ended = ended
    }

    private enum Keys: String, CodingKey {
      case phase, startedAt, expectedEndAt, progress, step, toolLabel, tokens, pending, others, othersCount
      case othersPending, summary, breachTick, updatedAt, ended
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      let started = try WhaleWakeWire.date(c, .startedAt)
      self.init(
        phase: (try? c.decode(Phase.self, forKey: .phase)) ?? .running,
        startedAt: started,
        expectedEndAt: try WhaleWakeWire.dateIfPresent(c, .expectedEndAt) ?? started.addingTimeInterval(600),
        progress: try? c.decodeIfPresent(Double.self, forKey: .progress),
        step: (try? c.decodeIfPresent(Int.self, forKey: .step)) ?? 1,
        toolLabel: (try? c.decodeIfPresent(String.self, forKey: .toolLabel)) ?? "",
        tokens: try? c.decodeIfPresent(Int.self, forKey: .tokens),
        pending: try c.decodeIfPresent(Pending.self, forKey: .pending),
        others: Array(((try? c.decodeIfPresent([Other].self, forKey: .others)) ?? []).prefix(2)),
        othersCount: (try? c.decodeIfPresent(Int.self, forKey: .othersCount)) ?? 0,
        othersPending: (try? c.decodeIfPresent(Int.self, forKey: .othersPending)) ?? 0,
        summary: try? c.decodeIfPresent(String.self, forKey: .summary),
        breachTick: (try? c.decodeIfPresent(Int.self, forKey: .breachTick)) ?? 0,
        updatedAt: try WhaleWakeWire.dateIfPresent(c, .updatedAt),
        ended: try? c.decodeIfPresent(Bool.self, forKey: .ended)
      )
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Keys.self)
      try c.encode(phase, forKey: .phase)
      try c.encode(WhaleWakeWire.seconds(startedAt), forKey: .startedAt)
      try c.encode(WhaleWakeWire.seconds(expectedEndAt), forKey: .expectedEndAt)
      try c.encodeIfPresent(progress, forKey: .progress)
      try c.encode(step, forKey: .step)
      try c.encode(toolLabel, forKey: .toolLabel)
      try c.encodeIfPresent(tokens, forKey: .tokens)
      try c.encodeIfPresent(pending, forKey: .pending)
      try c.encode(others, forKey: .others)
      try c.encode(othersCount, forKey: .othersCount)
      try c.encode(othersPending, forKey: .othersPending)
      try c.encodeIfPresent(summary, forKey: .summary)
      try c.encode(breachTick, forKey: .breachTick)
      try c.encodeIfPresent(updatedAt.map(WhaleWakeWire.seconds), forKey: .updatedAt)
      try c.encodeIfPresent(ended, forKey: .ended)
    }

    // MARK: Derived

    /// The approval buttons are folded (expired, past their two minutes at this snapshot).
    func approvalFolded(now: Date = Date()) -> Bool {
      guard let p = pending else { return false }
      return p.expired || now >= p.approvalExpiresAt
    }

    /// More than one conversation is running: the multi layout (only while nothing waits on the
    /// main one; a pending approval keeps its own layout and buttons).
    var isMulti: Bool { phase == .running && othersCount > 0 }

    /// Some conversation waits for the person (amber dot).
    var needsYou: Bool { pending != nil || othersPending > 0 }

    /// Lane fill at [now]: progress when the turn has todos, else the clock's share, capped at 0.9.
    func laneFraction(now: Date = Date()) -> Double {
      if phase == .done { return 1 }
      if let p = progress { return min(1, max(0, p)) }
      let total = expectedEndAt.timeIntervalSince(startedAt)
      guard total > 0 else { return 0 }
      return min(0.9, max(0, now.timeIntervalSince(startedAt) / total))
    }

    /// Clock-driven lane: a system ProgressView(timerInterval:) drawn on 90 % of the track over
    /// startedAt...laneClockEnd is at 0.9 of the track at expectedEndAt and stays full after.
    var laneClockEnd: Date {
      expectedEndAt > startedAt ? expectedEndAt : startedAt.addingTimeInterval(600)
    }

    /// relevance-score (contract.md §2).
    var relevance: Double {
      switch phase {
      case .approval, .question: return 100
      case .running: return 60
      case .done: return 50
      case .failed: return 70
      }
    }
  }
}

/// Unix-second dates, whatever the coder's date strategy.
enum WhaleWakeWire {
  static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded()) }

  static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date {
    if let d = try dateIfPresent(c, key) { return d }
    throw DecodingError.keyNotFound(key, .init(codingPath: c.codingPath, debugDescription: "missing date"))
  }

  static func dateIfPresent<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date? {
    guard c.contains(key), (try? c.decodeNil(forKey: key)) != true else { return nil }
    if let s = try? c.decode(Double.self, forKey: key) { return Date(timeIntervalSince1970: s) }
    if let s = try? c.decode(String.self, forKey: key), let v = Double(s) { return Date(timeIntervalSince1970: v) }
    throw DecodingError.typeMismatch(Double.self, .init(codingPath: c.codingPath + [key], debugDescription: "date: Unix seconds"))
  }
}

@available(iOS 16.1, *)
extension WhaleWakeAttributes.ContentState {
  /// From the dsh/live_activity channel's `state` map (Flutter standard codec: NSNull for nil).
  init(channelMap: Any?) throws {
    guard let map = channelMap as? [String: Any] else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "state is not a map"))
    }
    let data = try JSONSerialization.data(withJSONObject: map)
    self = try JSONDecoder().decode(Self.self, from: data)
  }

  var encodedSize: Int { (try? JSONEncoder().encode(self).count) ?? 0 }
}

@available(iOS 16.1, *)
extension WhaleWakeAttributes {
  var isChinese: Bool { lang.lowercased().hasPrefix("zh") }

  /// dshgo://session/<id>[#event=<eventId>] (the App's 'session' link handler).
  static func sessionURL(_ sessionId: String, eventId: String? = nil) -> URL {
    var c = URLComponents()
    c.scheme = "dshgo"
    c.host = "session"
    c.path = "/" + sessionId
    if let e = eventId { c.fragment = "event=" + e }
    return c.url ?? URL(string: "dshgo://session")!
  }
}
