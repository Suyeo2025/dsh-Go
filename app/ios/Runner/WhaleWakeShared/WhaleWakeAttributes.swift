// 「鲸游」Live Activity: attributes and content state (plan/design/live-activity-a/contract.md §1,
// with the plan/ios-wave2-design.md revision: Pending.approvalExpiresAt / expired).
// v2 (plan/design/live-activity-v2-contract.md §1): pending.options, todos, todoDone / todoTotal /
// todoLabel, summaryLine, showStop, stopArmedUntil, stepStartedAt, v. All optional: a v1 payload
// decodes exactly as before, and a v1 Activity (no v2 keys) draws the v1 views.
// v3 (plan/design/notify-v3-contract.md §2): phase "background", calves, calvesMore, bubbles, wf, team,
// goal, pendingCount, pending.from. Optional too; a phase this build doesn't know reads as running.
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
      /// v3: the root conversation replied, its work tree is still busy (jobs, subagents, a run).
      case background
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

    // v2 (all optional; absent = the v1 view)
    /// Payload version, diagnostics only: views branch on the keys present, never on this.
    var v: Int?
    /// One buoy per todo (≤ 8, compressed by Dart / bridge).
    var todos: [Todo]?
    var todoDone: Int?
    var todoTotal: Int?
    /// The current todo, ≤ 12 characters.
    var todoLabel: String?
    /// The conclusion's first sentence (done / failed), ≤ 60 characters.
    var summaryLine: String?
    /// Draw 「停止」 (running / approval / question while the turn runs).
    var showStop: Bool?
    /// Written only here (StopIntent's first tap): a second tap before it stops the turn.
    var stopArmedUntil: Date?
    /// When the current tool call started (reserved; not drawn yet).
    var stepStartedAt: Date?

    // v3 (all optional; absent = the v2 view)
    /// Parallel descendants (subagents, teammates, workflow members), ≤ 3: wait > run > err > done.
    var calves: [Calf]?
    /// Descendants not drawn (wait / run / err only).
    var calvesMore: Int?
    /// The tree's background jobs.
    var bubbles: Bubbles?
    /// The current foreground workflow run (lane source, first choice).
    var wf: Workflow?
    /// The team's task board (lane source, second choice).
    var team: Team?
    var goal: Goal?
    /// Requests waiting in the whole tree (written when ≥ 2).
    var pendingCount: Int?

    struct Calf: Codable, Hashable {
      enum State: String, Hashable { case run, done, wait, err }
      let s: State
      let l: String
      init(_ s: State, _ l: String) { self.s = s; self.l = l }
      private enum Keys: String, CodingKey { case s, l }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        s = State(rawValue: (try? c.decode(String.self, forKey: .s)) ?? "") ?? .run
        l = (try? c.decode(String.self, forKey: .l)) ?? ""
      }
      func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(s.rawValue, forKey: .s)
        try c.encode(l, forKey: .l)
      }
    }

    struct Bubbles: Codable, Hashable {
      struct Job: Codable, Hashable {
        let l: String
        /// Started, Unix seconds (this phone's clock).
        let since: Int
        var startedAt: Date { Date(timeIntervalSince1970: TimeInterval(since)) }
        init(l: String, since: Int) { self.l = l; self.since = since }
        private enum Keys: String, CodingKey { case l, since }
        init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: Keys.self)
          l = (try? c.decode(String.self, forKey: .l)) ?? ""
          since = (try? c.decode(Int.self, forKey: .since)) ?? Int((try? c.decode(Double.self, forKey: .since)) ?? 0)
        }
      }
      let run: Int
      let fail: Int
      let top: [Job]
      init(run: Int, fail: Int = 0, top: [Job] = []) { self.run = run; self.fail = fail; self.top = Array(top.prefix(2)) }
      private enum Keys: String, CodingKey { case run, fail, top }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
          run: (try? c.decode(Int.self, forKey: .run)) ?? 0, fail: (try? c.decode(Int.self, forKey: .fail)) ?? 0,
          top: ((try? c.decodeIfPresent([Job].self, forKey: .top)) ?? nil) ?? [])
      }
    }

    struct Workflow: Codable, Hashable {
      struct Segment: Codable, Hashable {
        enum State: String, Hashable { case done, active, todo, err }
        let s: State
        /// Finished members / members, 0…1.
        let f: Double
        init(_ s: State, _ f: Double) { self.s = s; self.f = min(1, max(0, f)) }
        private enum Keys: String, CodingKey { case s, f }
        init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: Keys.self)
          self.init(
            State(rawValue: (try? c.decode(String.self, forKey: .s)) ?? "") ?? .todo,
            (try? c.decode(Double.self, forKey: .f)) ?? 0)
        }
        func encode(to encoder: Encoder) throws {
          var c = encoder.container(keyedBy: Keys.self)
          try c.encode(s.rawValue, forKey: .s)
          try c.encode(f, forKey: .f)
        }
      }
      let name: String
      let seg: [Segment]
      let label: String
      init(name: String, seg: [Segment], label: String = "") { self.name = name; self.seg = Array(seg.prefix(6)); self.label = label }
      private enum Keys: String, CodingKey { case name, seg, label }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
          name: (try? c.decode(String.self, forKey: .name)) ?? "",
          seg: ((try? c.decodeIfPresent([Segment].self, forKey: .seg)) ?? nil) ?? [],
          label: (try? c.decode(String.self, forKey: .label)) ?? "")
      }
      /// The segment being worked on (1-based) and the count.
      var current: (index: Int, of: Int) {
        let i = seg.firstIndex { $0.s == .active } ?? seg.lastIndex { $0.s == .done || $0.s == .err } ?? 0
        return (i + 1, seg.count)
      }
      var fraction: Double { seg.isEmpty ? 0 : seg.reduce(0) { $0 + ($1.s == .done ? 1 : $1.f) } / Double(seg.count) }
    }

    struct Team: Codable, Hashable {
      let done: Int
      let total: Int
    }

    struct Goal: Codable, Hashable {
      let round: Int
      let max: Int?
    }

    struct Todo: Codable, Hashable {
      enum State: String, Hashable { case done, active, todo }
      let s: State

      init(_ s: State) { self.s = s }

      private enum Keys: String, CodingKey { case s }

      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        s = State(rawValue: (try? c.decode(String.self, forKey: .s)) ?? "") ?? .todo
      }

      func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(s.rawValue, forKey: .s)
      }
    }

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
      /// v2: a single-choice question's first ≤ 3 options (id = index in the original list).
      let options: [Option]?
      /// v3: the descendant asking (≤ 8), when it isn't the root conversation.
      let from: String?

      struct Option: Codable, Hashable {
        let id: String
        let label: String
      }

      init(
        eventId: String, kind: Kind, text: String, risk: String, askedAt: Date, approvalExpiresAt: Date? = nil,
        expired: Bool = false, options: [Option]? = nil, from: String? = nil
      ) {
        self.eventId = eventId
        self.kind = kind
        self.text = text
        self.risk = risk
        self.askedAt = askedAt
        self.approvalExpiresAt = approvalExpiresAt ?? askedAt.addingTimeInterval(120)
        self.expired = expired
        self.options = options.map { Array($0.prefix(3)) }
        self.from = from?.isEmpty == false ? from : nil
      }

      private enum Keys: String, CodingKey { case eventId, kind, text, risk, askedAt, approvalExpiresAt, expired, options, from }

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
          expired: (try? c.decodeIfPresent(Bool.self, forKey: .expired)) ?? false,
          options: (try? c.decodeIfPresent([Option].self, forKey: .options)).flatMap { $0?.isEmpty == false ? $0 : nil },
          from: (try? c.decodeIfPresent(String.self, forKey: .from)) ?? nil
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
        try c.encodeIfPresent(options, forKey: .options)
        try c.encodeIfPresent(from, forKey: .from)
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
      summary: String? = nil, breachTick: Int = 0, updatedAt: Date? = nil, ended: Bool? = nil,
      v: Int? = nil, todos: [Todo]? = nil, todoDone: Int? = nil, todoTotal: Int? = nil, todoLabel: String? = nil,
      summaryLine: String? = nil, showStop: Bool? = nil, stopArmedUntil: Date? = nil, stepStartedAt: Date? = nil,
      calves: [Calf]? = nil, calvesMore: Int? = nil, bubbles: Bubbles? = nil, wf: Workflow? = nil, team: Team? = nil,
      goal: Goal? = nil, pendingCount: Int? = nil
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
      self.v = v
      self.todos = todos.flatMap { $0.isEmpty ? nil : Array($0.prefix(8)) }
      self.todoDone = todoDone
      self.todoTotal = todoTotal
      self.todoLabel = todoLabel
      self.summaryLine = summaryLine
      self.showStop = showStop
      self.stopArmedUntil = stopArmedUntil
      self.stepStartedAt = stepStartedAt
      self.calves = calves.flatMap { $0.isEmpty ? nil : Array($0.prefix(3)) }
      self.calvesMore = calvesMore
      self.bubbles = bubbles
      self.wf = wf.flatMap { $0.seg.isEmpty ? nil : $0 }
      self.team = team.flatMap { $0.total > 0 ? $0 : nil }
      self.goal = goal
      self.pendingCount = pendingCount
    }

    private enum Keys: String, CodingKey {
      case phase, startedAt, expectedEndAt, progress, step, toolLabel, tokens, pending, others, othersCount
      case othersPending, summary, breachTick, updatedAt, ended
      case v, todos, todoDone, todoTotal, todoLabel, summaryLine, showStop, stopArmedUntil, stepStartedAt
      case calves, calvesMore, bubbles, wf, team, goal, pendingCount
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
        ended: try? c.decodeIfPresent(Bool.self, forKey: .ended),
        v: try? c.decodeIfPresent(Int.self, forKey: .v),
        todos: (try? c.decodeIfPresent([Todo].self, forKey: .todos)) ?? nil,
        todoDone: try? c.decodeIfPresent(Int.self, forKey: .todoDone),
        todoTotal: try? c.decodeIfPresent(Int.self, forKey: .todoTotal),
        todoLabel: try? c.decodeIfPresent(String.self, forKey: .todoLabel),
        summaryLine: try? c.decodeIfPresent(String.self, forKey: .summaryLine),
        showStop: try? c.decodeIfPresent(Bool.self, forKey: .showStop),
        stopArmedUntil: try? WhaleWakeWire.dateIfPresent(c, .stopArmedUntil),
        stepStartedAt: try? WhaleWakeWire.dateIfPresent(c, .stepStartedAt),
        calves: (try? c.decodeIfPresent([Calf].self, forKey: .calves)) ?? nil,
        calvesMore: try? c.decodeIfPresent(Int.self, forKey: .calvesMore),
        bubbles: (try? c.decodeIfPresent(Bubbles.self, forKey: .bubbles)) ?? nil,
        wf: (try? c.decodeIfPresent(Workflow.self, forKey: .wf)) ?? nil,
        team: (try? c.decodeIfPresent(Team.self, forKey: .team)) ?? nil,
        goal: (try? c.decodeIfPresent(Goal.self, forKey: .goal)) ?? nil,
        pendingCount: try? c.decodeIfPresent(Int.self, forKey: .pendingCount)
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
      try c.encodeIfPresent(v, forKey: .v)
      try c.encodeIfPresent(todos, forKey: .todos)
      try c.encodeIfPresent(todoDone, forKey: .todoDone)
      try c.encodeIfPresent(todoTotal, forKey: .todoTotal)
      try c.encodeIfPresent(todoLabel, forKey: .todoLabel)
      try c.encodeIfPresent(summaryLine, forKey: .summaryLine)
      try c.encodeIfPresent(showStop, forKey: .showStop)
      try c.encodeIfPresent(stopArmedUntil.map(WhaleWakeWire.seconds), forKey: .stopArmedUntil)
      try c.encodeIfPresent(stepStartedAt.map(WhaleWakeWire.seconds), forKey: .stepStartedAt)
      try c.encodeIfPresent(calves, forKey: .calves)
      try c.encodeIfPresent(calvesMore, forKey: .calvesMore)
      try c.encodeIfPresent(bubbles, forKey: .bubbles)
      try c.encodeIfPresent(wf, forKey: .wf)
      try c.encodeIfPresent(team, forKey: .team)
      try c.encodeIfPresent(goal, forKey: .goal)
      try c.encodeIfPresent(pendingCount, forKey: .pendingCount)
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

    // MARK: v2 derived

    /// 「停止」 is drawn (never after the turn ended).
    var stopShown: Bool {
      showStop == true && (phase == .running || phase == .background || phase == .approval || phase == .question)
    }

    /// The stop key waits for its second tap at [now].
    func stopArmed(now: Date = Date()) -> Bool {
      guard let until = stopArmedUntil else { return false }
      return now < until
    }

    /// One-tap answers: a question with options, while the data is current.
    var answerOptions: [Pending.Option] {
      guard phase == .question, let p = pending, p.kind == .question, !p.expired else { return [] }
      return p.options ?? []
    }

    /// Buoys on the lane (todos present).
    var buoys: [Todo] { todos ?? [] }

    /// Where the whale rests on a buoy lane, 0…1: on the active buoy, else just past the last
    /// done one, else at the start; all done: the last buoy.
    var buoyWhaleFraction: Double {
      let b = laneBuoys
      guard !b.isEmpty else { return 0 }
      let n = Double(b.count)
      if let i = b.firstIndex(where: { $0.s == .active }) { return (Double(i) + 0.5) / n }
      if let i = b.lastIndex(where: { $0.s == .done }) {
        return i == b.count - 1 ? (Double(i) + 0.5) / n : (Double(i) + 1) / n
      }
      return 0.5 / n
    }

    /// Minimal ring: the todo share when there are todos (else nil: the clock ring).
    var ringFraction: Double? {
      if phase == .done { return 1 }
      switch laneSource {
      case .workflow: return wf?.fraction
      case .team: return team.map { min(1, Double($0.done) / Double(max(1, $0.total))) }
      default: break
      }
      if let d = todoDone, let t = todoTotal, t > 0 { return min(1, max(0, Double(d) / Double(t))) }
      if !buoys.isEmpty { return Double(buoys.filter { $0.s == .done }.count) / Double(buoys.count) }
      return nil
    }

    // MARK: v3 derived

    /// What the lane draws, one source only (v3 contract §2.2): workflow > team board > todos > clock.
    enum LaneSource: Equatable { case workflow, team, todos, clock }

    var laneSource: LaneSource {
      if let wf, !wf.seg.isEmpty { return .workflow }
      if let team, team.total > 0 { return .team }
      if !buoys.isEmpty { return .todos }
      return .clock
    }

    /// Buoys of the lane: the team board as buoys (done / active / todo, ≤ 8), else the todos.
    var laneBuoys: [Todo] {
      guard laneSource == .team, let team else { return buoys }
      let n = min(8, team.total)
      let done = team.total <= 8 ? team.done : Int((Double(team.done) / Double(team.total) * 8).rounded(.down))
      return (0..<n).map { i in i < done ? Todo(.done) : (i == done ? Todo(.active) : Todo(.todo)) }
    }

    /// Descendants still at it: running or waiting calves, plus the ones not drawn (calvesMore
    /// counts only wait / run / err; err ones there can't be told apart).
    var calvesActive: Int { (calves ?? []).filter { $0.s == .run || $0.s == .wait }.count + (calvesMore ?? 0) }

    /// Jobs running in the background.
    var jobsRunning: Int { bubbles?.run ?? 0 }

    /// relevance-score (contract.md §2).
    var relevance: Double {
      switch phase {
      case .approval, .question: return 100
      case .running: return 60
      case .background: return 55
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
