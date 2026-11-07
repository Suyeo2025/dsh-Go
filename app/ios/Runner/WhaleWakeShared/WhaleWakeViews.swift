// 「鲸游」views: Dynamic Island compact / minimal / expanded regions and the lock-screen banner
// (plan/design/live-activity-a/README.md §1/§3, behavior.md, and the plan/ios-wave2-design.md
// revision: the expanded leading region shows the 60×60 lock-* whale; the whale's sign is the only
// status icon). Plain SwiftUI views over (attributes, state, isStale) so WhaleWakeActivity wires them
// into ActivityConfiguration and RunnerTests renders them with ImageRenderer.
//
// v2 (plan/design/live-activity-v2-contract.md): option keys on a question, todo buoys on the lane,
// the conclusion line on done / failed, a two-tap 「停止」, the minimal as a progress ring, and the
// iOS 27 width-limited island (landscape). Each appears only when its keys are present: a v1
// payload draws the v1 views.
//
// Pixel frames come from WhaleWakeActivity/Assets.xcassets at their own size (@3x 72×48 → 24×16 pt,
// 180×180 → 60×60 pt), nearest neighbour, never resized.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Assets and colours

enum WhaleWakeAssets {
  /// The widget extension's own bundle; inside the App (tests) the embedded .appex.
  static let bundle: Bundle = {
    if Bundle.main.bundleURL.pathExtension == "appex" { return .main }
    if let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("WhaleWakeActivity.appex"),
      let b = Bundle(url: url)
    {
      return b
    }
    return .main
  }()
}

struct WhaleWakePalette {
  let blue, amber, green, red, status, hint, title: Color
  let track, fillStart, fillEnd: Color
  let card: Color
  let allowText, neutralBg, neutralText: Color

  static let dark = WhaleWakePalette(
    blue: Color(hex: 0x97B1F0), amber: Color(hex: 0xE6BD7C), green: Color(hex: 0x8BCCA6),
    red: Color(hex: 0xE69089), status: Color(hex: 0x9A9EA9), hint: Color(hex: 0x656971), title: .white,
    track: Color.white.opacity(0.14), fillStart: Color(hex: 0x4A6CFF), fillEnd: Color(hex: 0x8FB0FF),
    card: Color(hex: 0x1C1F28).opacity(0.78),
    allowText: Color(hex: 0x1C1F28), neutralBg: Color.white.opacity(0.14), neutralText: .white)

  static let light = WhaleWakePalette(
    blue: Color(hex: 0x4B67B4), amber: Color(hex: 0x936123), green: Color(hex: 0x337250),
    red: Color(hex: 0xA54743), status: Color(hex: 0x4F5562), hint: Color(hex: 0x8A8F99), title: Color(hex: 0x1E232E),
    track: Color(hex: 0x1E232E).opacity(0.10), fillStart: Color(hex: 0x4B67B4), fillEnd: Color(hex: 0x7F9BE0),
    card: Color(hex: 0xF0F4FD).opacity(0.82),
    allowText: .white, neutralBg: Color(hex: 0x1E232E).opacity(0.07), neutralText: Color(hex: 0x1E232E))

  static func of(_ scheme: ColorScheme) -> WhaleWakePalette { scheme == .dark ? dark : light }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: 1)
  }
}

// MARK: - Model helpers

@available(iOS 16.1, *)
typealias WhaleWakeState = WhaleWakeAttributes.ContentState

@available(iOS 16.1, *)
extension WhaleWakeAttributes.ContentState {
  /// Frame name suffix for this state (`compact-…`, `lock-…`).
  func frame(compact: Bool) -> String {
    if isMulti { return "multi" }
    switch phase {
    // background: the whale floats where it stopped (the swim frame; no hover frame in the set yet).
    case .running, .background: return "swim"
    case .approval: return "approval"
    case .question: return "question"
    case .failed: return "failed"
    case .done:
      // The update that reports done leaps (breach); the closing snapshot lands (done).
      return compact || ended == true || breachTick == 0 ? "done" : "breach"
    }
  }

  func color(_ p: WhaleWakePalette) -> Color {
    switch phase {
    case .running, .background: return p.blue
    case .approval, .question: return p.amber
    case .done: return p.green
    case .failed: return p.red
    }
  }

  /// The one-line status: what the banner says under the title.
  func subtitle(_ s: WhaleWakeStrings, now: Date = Date()) -> String {
    switch phase {
    case .running: return s.running(step: step, tool: toolLabel)
    case .background: return s.background(jobs: jobsRunning, subagents: calvesActive)
    case .approval:
      let text = pending?.text ?? ""
      return fromPrefix(s) + (approvalFolded(now: now) ? s.stillWaiting(text) : s.needsApproval(text))
    case .question: return fromPrefix(s) + s.needsAnswer(pending?.text ?? "")
    case .done: return s.doneLine(summary)
    case .failed: return s.failedLine(summary)
    }
  }

  /// Same, without the command / question text (locked phone, redacted).
  func bareSubtitle(_ s: WhaleWakeStrings) -> String {
    switch phase {
    case .approval: return fromPrefix(s) + s.needsApprovalBare
    case .question: return fromPrefix(s) + s.needsAnswerBare
    default: return subtitle(s)
    }
  }

  /// v3: 「子代理 · 审查员 」 when a descendant asks.
  func fromPrefix(_ s: WhaleWakeStrings) -> String {
    guard let from = pending?.from, !from.isEmpty else { return "" }
    return s.from(from) + " "
  }

  /// v3: requests waiting in the tree beyond the one shown.
  var moreWaiting: Int { max(0, (pendingCount ?? 0) - 1) }
}

enum WhaleWakeClock {
  /// 12:34 / 1:02:03.
  static func format(_ seconds: TimeInterval) -> String {
    let t = max(0, Int(seconds))
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
}

// MARK: - Pieces

/// A pixel frame at its own size.
struct WhaleWakeFrame: View {
  let name: String
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    Image(name, bundle: WhaleWakeAssets.bundle)
      .interpolation(.none)
      .frame(width: width, height: height)
      .accessibilityHidden(true)
  }
}

/// The running clock: system-driven, frozen when stale.
@available(iOS 16.1, *)
struct WhaleWakeTimer: View {
  let state: WhaleWakeState
  let isStale: Bool
  var font: Font = .subheadline.weight(.medium)
  var color: Color = .white

  var body: some View {
    Group {
      if isStale {
        Text(WhaleWakeClock.format((state.updatedAt ?? Date()).timeIntervalSince(state.startedAt)))
      } else {
        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
      }
    }
    .font(font)
    .monospacedDigit()
    .foregroundColor(color)
    .multilineTextAlignment(.trailing)
    .lineLimit(1)
  }
}

/// The subtitle line: redacted on a locked phone to the bare 「等你确认」.
@available(iOS 16.1, *)
struct WhaleWakeSubtitle: View {
  let state: WhaleWakeState
  let strings: WhaleWakeStrings
  let isStale: Bool
  let color: Color
  let font: Font
  @Environment(\.redactionReasons) private var redaction

  var body: some View {
    Group {
      if isStale && state.phase == .running {
        staleLine
      } else if redaction.contains(.privacy) {
        Text(state.bareSubtitle(strings))
      } else {
        Text(state.subtitle(strings))
      }
    }
    .font(font)
    .foregroundColor(color)
    .lineLimit(state.phase == .background ? 2 : 1)
    .truncationMode(.tail)
    .contentTransition(.opacity)
  }

  @ViewBuilder private var staleLine: some View {
    if let at = state.updatedAt {
      Text("\(strings.mayBeStale) · \(strings.updatedPrefix)") + Text(at, style: .relative) + Text(strings.updatedSuffix)
    } else {
      Text(strings.mayBeStale)
    }
  }
}

/// A capsule key that opens the App (`去回答` / `查看` / `打开`).
struct WhaleWakeLinkKey: View {
  let title: String
  let url: URL
  let background: Color
  let foreground: Color
  var height: CGFloat = 32

  var body: some View {
    Link(destination: url) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundColor(foreground)
        .padding(.horizontal, 16)
        .frame(height: height)
        .background(Capsule().fill(background))
    }
  }
}

/// Renderers that can't run the system's timer-driven progress (ImageRenderer in RunnerTests'
/// boards) draw the lane at its snapshot value instead.
private struct WhaleWakeStaticLaneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  var whaleWakeStaticLane: Bool {
    get { self[WhaleWakeStaticLaneKey.self] }
    set { self[WhaleWakeStaticLaneKey.self] = newValue }
  }
}

/// Boards (RunnerTests) can ask for the width-limited island the simulator never shows.
private struct WhaleWakeForceLimitedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  var whaleWakeForceLimited: Bool {
    get { self[WhaleWakeForceLimitedKey.self] }
    set { self[WhaleWakeForceLimitedKey.self] = newValue }
  }
}

/// iOS 27: the island limited in width (landscape) — its compact must fit a 28 pt circle.
struct WhaleWakeLimitedWidth<Content: View>: View {
  @ViewBuilder let content: (Bool) -> Content
  @Environment(\.whaleWakeForceLimited) private var forced

  var body: some View {
    if forced {
      content(true)
    } else if #available(iOS 27.0, *) {
      WhaleWakeLimitedReader(content: content)
    } else {
      content(false)
    }
  }
}

@available(iOS 27.0, *)
private struct WhaleWakeLimitedReader<Content: View>: View {
  let content: (Bool) -> Content
  @Environment(\.isDynamicIslandLimitedInWidth) private var limited

  var body: some View { content(limited) }
}

/// The swim lane: track, wave, fill (todo progress, or the system clock), the whale riding it.
@available(iOS 16.1, *)
struct WhaleWakeLane: View {
  let state: WhaleWakeState
  let isStale: Bool
  let palette: WhaleWakePalette
  var now: Date = Date()
  @Environment(\.whaleWakeStaticLane) private var staticLane

  private let height: CGFloat = 10

  var body: some View {
    if state.phase == .done {
      clockLane
    } else {
      switch state.laneSource {
      case .workflow: WhaleWakeSegmentLane(wf: state.wf!, isStale: isStale, palette: palette)
      case .team, .todos: WhaleWakeBuoyLane(state: state, isStale: isStale, palette: palette)
      case .clock: clockLane
      }
    }
  }

  private var clockLane: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let fraction = state.laneFraction(now: now)
      let fill = LinearGradient(colors: [palette.fillStart, palette.fillEnd], startPoint: .leading, endPoint: .trailing)
      ZStack(alignment: .leading) {
        Capsule().fill(palette.track).frame(height: height)
        if !isStale && state.phase != .done {
          WhaleWakeWave().stroke(palette.fillEnd.opacity(0.55), lineWidth: 1.2).frame(height: height)
        }
        if state.progress != nil || isStale || state.phase == .done || staticLane {
          Capsule().fill(fill).frame(width: max(height, w * fraction), height: height)
        } else {
          // System-driven: 90 % of the track over startedAt...laneClockEnd (the 0.9 cap).
          ProgressView(timerInterval: state.startedAt...state.laneClockEnd, countsDown: false) {
            EmptyView()
          } currentValueLabel: {
            EmptyView()
          }
          .progressViewStyle(.linear)
          .tint(palette.fillEnd)
          .scaleEffect(x: 1, y: 2.4, anchor: .center)
          .frame(width: w * 0.9, height: height)
          .clipShape(Capsule())
        }
        if state.phase != .done {
          WhaleWakeFrame(name: "compact-swim", width: 24, height: 16)
            .offset(x: min(w - 24, max(0, w * fraction - 14)), y: -12)
        }
      }
      .frame(height: geo.size.height, alignment: .center)
    }
    .frame(height: 22)
    .opacity(isStale ? 0.8 : 1)
  }
}

/// v2 C3: one buoy per todo on the water line — done ones ticked, the active one lit, the rest
/// hollow — and the whale resting at the active one. Static: it moves only with an update.
@available(iOS 16.1, *)
struct WhaleWakeBuoyLane: View {
  let state: WhaleWakeState
  let isStale: Bool
  let palette: WhaleWakePalette

  private let size: CGFloat = 11

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let n = CGFloat(state.laneBuoys.count)
      let y = geo.size.height / 2 + 4
      ZStack(alignment: .topLeading) {
        WhaleWakeWave().stroke(palette.fillEnd.opacity(isStale ? 0.25 : 0.55), lineWidth: 1.2)
          .frame(width: w, height: 8)
          .offset(y: y - 4)
        ForEach(Array(state.laneBuoys.enumerated()), id: \.offset) { i, todo in
          buoy(todo.s)
            .position(x: w * (CGFloat(i) + 0.5) / n, y: y)
        }
        WhaleWakeFrame(name: "compact-swim", width: 24, height: 16)
          .position(x: min(w - 12, max(12, w * CGFloat(state.buoyWhaleFraction))), y: y - 13)
          .animation(.easeOut(duration: 0.6), value: state.buoyWhaleFraction)
      }
    }
    .frame(height: 30)
    .opacity(isStale ? 0.8 : 1)
    .accessibilityElement()
    .accessibilityLabel(Text("\(state.team?.done ?? state.todoDone ?? 0)/\(state.team?.total ?? state.todoTotal ?? state.laneBuoys.count)"))
  }

  @ViewBuilder private func buoy(_ s: WhaleWakeState.Todo.State) -> some View {
    switch s {
    case .done:
      Circle().fill(palette.green).frame(width: size, height: size)
        .overlay(Image(systemName: "checkmark").font(.system(size: 6, weight: .heavy)).foregroundColor(.white))
    case .active:
      Circle().fill(palette.fillEnd).frame(width: size + 2, height: size + 2)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
        .shadow(color: palette.fillEnd.opacity(0.9), radius: 4)
    case .todo:
      Circle().strokeBorder(palette.status, lineWidth: 1.5).frame(width: size, height: size)
    }
  }
}

/// v2 C2: 「停止」, then 「再点一次停止 0:05」 after the first tap. Only the intent's own time check
/// decides; this is what the person sees.
@available(iOS 16.1, *)
struct WhaleWakeStopKey: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let palette: WhaleWakePalette
  var now: Date = Date()

  var body: some View {
    if #available(iOS 17.0, *) {
      let s = WhaleWakeStrings(lang: attributes.lang)
      let armed = state.stopArmed(now: now)
      Button(intent: StopIntent(sessionId: attributes.sessionId)) {
        HStack(spacing: 4) {
          Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
          Text(armed ? s.stopAgain : s.stop).lineLimit(1)
          if armed, let until = state.stopArmedUntil {
            Text(timerInterval: now...max(now, until), countsDown: true)
              .monospacedDigit()
              .frame(width: 30, alignment: .leading)
          }
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(armed ? .white : palette.red)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(armed ? palette.red : palette.neutralBg))
        .fixedSize()
      }
      .buttonStyle(.plain)
      .invalidatableContent()
    }
  }
}

/// v2 C1: a question's options as equal keys, 10 pt apart, then 「去回答」 (the other options, or
/// typing an answer) — always last.
@available(iOS 16.1, *)
struct WhaleWakeAnswerKeys: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool
  let palette: WhaleWakePalette

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    let eventId = state.pending?.eventId
    let url = WhaleWakeAttributes.sessionURL(attributes.sessionId, eventId: eventId)
    let options = isStale ? [] : state.answerOptions
    HStack(spacing: 10) {
      ForEach(options, id: \.id) { o in
        option(o, eventId: eventId ?? "", url: url)
      }
      Link(destination: url) {
        label(
          s.answer, fill: options.isEmpty ? palette.amber : .clear, stroke: options.isEmpty ? nil : palette.amber,
          text: options.isEmpty ? palette.allowText : palette.amber)
      }
    }
  }

  @ViewBuilder private func option(_ o: WhaleWakeState.Pending.Option, eventId: String, url: URL) -> some View {
    let l = label(o.label, fill: palette.neutralBg, stroke: nil, text: palette.neutralText)
    if #available(iOS 17.0, *) {
      Button(intent: AnswerIntent(sessionId: attributes.sessionId, eventId: eventId, optionId: o.id)) { l }
        .buttonStyle(.plain)
        .invalidatableContent()
    } else {
      Link(destination: url) { l }
    }
  }

  private func label(_ t: String, fill: Color, stroke: Color?, text: Color) -> some View {
    Text(t)
      .font(.footnote.weight(.semibold))
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .foregroundColor(text)
      .padding(.horizontal, 6)
      .frame(maxWidth: .infinity)
      .frame(height: 36)
      .background(Capsule().fill(fill))
      .overlay(Capsule().strokeBorder(stroke ?? .clear, lineWidth: 1.5))
  }
}

/// v2 C4: the conclusion's first sentence on a finished card (stays on the lock screen for the
/// 20 minutes the ended Activity is kept).
@available(iOS 16.1, *)
struct WhaleWakeSummaryLine: View {
  let state: WhaleWakeState
  let color: Color
  let font: Font
  var lines = 2

  var body: some View {
    if let line = state.summaryLine, !line.isEmpty, state.phase == .done || state.phase == .failed {
      Text(line)
        .font(font)
        .foregroundColor(color)
        .lineLimit(lines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .privacySensitive()
    }
  }
}

@available(iOS 16.1, *)
extension WhaleWakeAttributes.ContentState {
  /// The running line under the lane when there are todos: 「3/8 · 跑测试 · 运行 Bash」.
  func laneCaption(_ s: WhaleWakeStrings) -> String? {
    var parts: [String] = []
    switch laneSource {
    case .workflow:
      guard let wf else { return nil }
      let c = wf.current
      if !wf.name.isEmpty { parts.append(wf.name) }
      parts.append(s.phaseLine(c.index, c.of, wf.label))
    case .team:
      guard let team else { return nil }
      parts.append(s.board(team.done, team.total))
    case .todos:
      guard let total = todoTotal ?? (buoys.isEmpty ? nil : buoys.count), total > 0 else { return nil }
      let done = todoDone ?? buoys.filter { $0.s == .done }.count
      parts.append(s.todoLine(done: done, total: total, label: todoLabel))
      if !toolLabel.isEmpty, toolLabel != todoLabel, phase == .running { parts.append(toolLabel) }
    case .clock:
      guard goal != nil else { return nil }
      if phase == .running, !toolLabel.isEmpty { parts.append(s.running(step: step, tool: toolLabel)) }
    }
    if let goal { parts.append(s.round(goal.round, goal.max)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

// MARK: - v3 pieces (notify-v3-contract §2)

/// v3: a workflow run's phases as segments of the lane, each filled with its finished members;
/// the whale on the active one.
@available(iOS 16.1, *)
struct WhaleWakeSegmentLane: View {
  let wf: WhaleWakeState.Workflow
  let isStale: Bool
  let palette: WhaleWakePalette

  var body: some View {
    GeometryReader { geo in
      let n = CGFloat(max(1, wf.seg.count))
      let gap: CGFloat = 4
      let w = (geo.size.width - gap * (n - 1)) / n
      let y = geo.size.height - 7
      let at = CGFloat(wf.current.index - 1)
      ZStack(alignment: .topLeading) {
        ForEach(Array(wf.seg.enumerated()), id: \.offset) { i, seg in
          let x = CGFloat(i) * (w + gap)
          ZStack(alignment: .leading) {
            Capsule().fill(palette.track)
            Capsule().fill(fill(seg)).frame(width: max(seg.f > 0 || seg.s == .done ? 8 : 0, w * CGFloat(seg.s == .done ? 1 : seg.f)))
          }
          .frame(width: w, height: 8)
          .overlay(alignment: .trailing) {
            if seg.s == .err { Circle().fill(palette.red).frame(width: 7, height: 7).offset(x: 2) }
          }
          .offset(x: x, y: y - 4)
        }
        WhaleWakeFrame(name: "compact-swim", width: 24, height: 16)
          .position(x: min(geo.size.width - 12, max(12, at * (w + gap) + w / 2)), y: y - 13)
      }
    }
    .frame(height: 30)
    .opacity(isStale ? 0.8 : 1)
    .accessibilityElement()
    .accessibilityLabel(Text("\(wf.name) \(wf.current.index)/\(wf.current.of)"))
  }

  private func fill(_ seg: WhaleWakeState.Workflow.Segment) -> Color {
    switch seg.s {
    case .done: return palette.green
    case .err: return palette.red.opacity(0.85)
    case .active: return palette.fillEnd
    case .todo: return palette.status.opacity(0.5)
    }
  }
}

/// v3: calves — the tree's parallel descendants (≤ 3) as small whales with a status dot and a
/// six-character label, then 「+N」.
@available(iOS 16.1, *)
struct WhaleWakeCalvesRow: View {
  let state: WhaleWakeState
  let strings: WhaleWakeStrings
  let palette: WhaleWakePalette

  var body: some View {
    HStack(spacing: 10) {
      ForEach(Array((state.calves ?? []).enumerated()), id: \.offset) { _, calf in
        HStack(spacing: 3) {
          WhaleWakeFrame(name: "compact-swim", width: 24, height: 16)
            .scaleEffect(0.6)
            .frame(width: 15, height: 10)
          Circle().fill(color(calf.s)).frame(width: 5, height: 5)
          Text(calf.l).font(.caption2).foregroundColor(palette.status).lineLimit(1)
        }
      }
      if let more = state.calvesMore, more > 0 {
        Text(strings.plus(more)).font(.caption2.weight(.semibold)).monospacedDigit().foregroundColor(palette.status)
      }
      Spacer(minLength: 0)
    }
  }

  private func color(_ s: WhaleWakeState.Calf.State) -> Color {
    switch s {
    case .run: return palette.blue
    case .wait: return palette.amber
    case .err: return palette.red
    case .done: return palette.green
    }
  }
}

/// v3: the tree's background jobs — the first two with their running time, failures counted.
@available(iOS 16.1, *)
struct WhaleWakeBubblesList: View {
  let state: WhaleWakeState
  let strings: WhaleWakeStrings
  let isStale: Bool
  let palette: WhaleWakePalette

  var body: some View {
    if let b = state.bubbles, b.run > 0 || b.fail > 0 {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(b.top.enumerated()), id: \.offset) { _, job in
          HStack(spacing: 6) {
            Image(systemName: "circle.dotted").font(.system(size: 9, weight: .bold)).foregroundColor(palette.blue)
            Text(job.l).font(.caption).foregroundColor(palette.status).lineLimit(1)
            Spacer(minLength: 4)
            Group {
              if isStale {
                Text(WhaleWakeClock.format((state.updatedAt ?? Date()).timeIntervalSince(job.startedAt)))
              } else {
                Text(timerInterval: job.startedAt...Date.distantFuture, countsDown: false)
              }
            }
            .font(.caption).monospacedDigit().foregroundColor(palette.title)
            .multilineTextAlignment(.trailing).frame(width: 56, alignment: .trailing)
          }
        }
        if b.fail > 0 {
          Text(strings.zh ? "\(b.fail) 个后台任务失败" : "\(b.fail) background task\(b.fail == 1 ? "" : "s") failed")
            .font(.caption2).foregroundColor(palette.red)
        }
      }
    }
  }
}

/// v3: the bubble count at the lane's end while the root still runs.
@available(iOS 16.1, *)
struct WhaleWakeBubbleChip: View {
  let count: Int
  let palette: WhaleWakePalette

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "circle.dotted").font(.system(size: 9, weight: .bold))
      Text("\(count)").monospacedDigit()
    }
    .font(.caption.weight(.semibold))
    .foregroundColor(palette.blue)
  }
}

/// v3: what sits under a running / background head — calves, jobs, the stop key.
@available(iOS 16.1, *)
struct WhaleWakeTreeBlock: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool
  let palette: WhaleWakePalette

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    VStack(alignment: .leading, spacing: 5) {
      if state.laneSource != .clock {
        WhaleWakeLane(state: state, isStale: isStale, palette: palette)
        if let caption = state.laneCaption(s) {
          Text(caption).font(.caption).foregroundColor(palette.status).lineLimit(1)
        }
      }
      WhaleWakeBubblesList(state: state, strings: s, isStale: isStale, palette: palette)
      HStack(spacing: 8) {
        if state.calves != nil { WhaleWakeCalvesRow(state: state, strings: s, palette: palette) } else { Spacer(minLength: 0) }
        if state.stopShown && !isStale { WhaleWakeStopKey(attributes: attributes, state: state, palette: palette) }
      }
    }
  }
}

/// 15 sine waves across the track, static.
struct WhaleWakeWave: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    let waves = 15.0
    let amp = rect.height * 0.3
    let steps = 180
    for i in 0...steps {
      let x = rect.width * CGFloat(i) / CGFloat(steps)
      let y = rect.midY + amp * CGFloat(sin(Double(i) / Double(steps) * waves * 2 * .pi))
      if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    return p
  }
}

/// Allow / Deny (approval), or the folded 「打开」 once expired / stale.
@available(iOS 16.1, *)
struct WhaleWakeApprovalKeys: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool
  let palette: WhaleWakePalette
  var now: Date = Date()

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    let pending = state.pending
    let url = WhaleWakeAttributes.sessionURL(attributes.sessionId, eventId: pending?.eventId)
    VStack(alignment: .leading, spacing: 6) {
      if Self.folded(state, isStale: isStale, now: now) {
        WhaleWakeLinkKey(title: s.open, url: url, background: palette.amber, foreground: palette.allowText, height: 36)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let pending {
        keys(pending, s, url)
        HStack(spacing: 6) {
          Text(s.hint).font(.caption2).foregroundColor(palette.hint).lineLimit(1)
          Spacer(minLength: 4)
          Text(timerInterval: now...max(now, pending.approvalExpiresAt), countsDown: true)
            .font(.caption2).monospacedDigit().foregroundColor(palette.hint)
            .multilineTextAlignment(.trailing).frame(width: 40, alignment: .trailing)
        }
      }
    }
  }

  /// Allow / Deny fold into one 「打开」: stale data, the approval expired (bridge or App update)
  /// or past its two minutes at this snapshot, or nothing pending.
  static func folded(_ state: WhaleWakeState, isStale: Bool, now: Date = Date()) -> Bool {
    isStale || state.pending == nil || state.approvalFolded(now: now)
  }

  @ViewBuilder
  private func keys(_ pending: WhaleWakeState.Pending, _ s: WhaleWakeStrings, _ url: URL) -> some View {
    let high = pending.risk == "high"
    HStack(spacing: 10) {
      key(s.deny, filled: palette.neutralBg, stroke: nil, text: palette.neutralText, decision: .deny, pending: pending, url: url)
      key(
        s.allow, filled: high ? .clear : palette.amber, stroke: high ? palette.amber : nil,
        text: high ? palette.amber : palette.allowText, decision: .allow, pending: pending, url: url)
    }
  }

  @ViewBuilder
  private func key(
    _ title: String, filled: Color, stroke: Color?, text: Color, decision: WhaleWakeDecision,
    pending: WhaleWakeState.Pending, url: URL
  ) -> some View {
    let label = Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundColor(text)
      .frame(maxWidth: .infinity)
      .frame(height: 36)
      .background(Capsule().fill(filled))
      .overlay(Capsule().strokeBorder(stroke ?? .clear, lineWidth: 1.5))
    if #available(iOS 17.0, *) {
      Group {
        switch decision {
        case .allow: Button(intent: ApproveIntent(sessionId: attributes.sessionId, eventId: pending.eventId)) { label }
        case .deny: Button(intent: DenyIntent(sessionId: attributes.sessionId, eventId: pending.eventId)) { label }
        }
      }
      .buttonStyle(.plain)
      .invalidatableContent()
    } else {
      // iOS 16: no intents on Live Activity buttons; both open the approval card in the App.
      Link(destination: url) { label }
    }
  }
}

// MARK: - Dynamic Island

@available(iOS 16.1, *)
struct WhaleWakeCompactLeading: View {
  let state: WhaleWakeState

  var body: some View {
    WhaleWakeLimitedWidth { limited in
      if limited {
        WhaleWakeMinimal(state: state, diameter: 28)
      } else {
        WhaleWakeFrame(name: "compact-" + state.frame(compact: true), width: 24, height: 16)
      }
    }
  }
}

@available(iOS 16.1, *)
struct WhaleWakeCompactTrailing: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool

  var body: some View {
    // Width-limited (iOS 27 landscape): the system may hide the trailing side; leave it empty.
    WhaleWakeLimitedWidth { limited in
      if !limited { full }
    }
  }

  private var full: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    let p = WhaleWakePalette.dark
    return Group {
      if state.isMulti {
        HStack(spacing: 4) {
          Text(s.sessionsShort(state.othersCount + 1)).font(.footnote.weight(.medium)).monospacedDigit()
            .foregroundColor(.white)
          if state.othersPending > 0 { Circle().fill(p.amber).frame(width: 6, height: 6) }
        }
      } else {
        switch state.phase {
        case .running: WhaleWakeTimer(state: state, isStale: isStale, font: .footnote.weight(.medium)).frame(maxWidth: 52)
        case .background: word(s.backgroundShort(max(1, state.jobsRunning + state.calvesActive)), p.blue)
        case .approval: word(state.moreWaiting > 0 ? s.waitingShort(state.pendingCount ?? 2) : s.review, p.amber)
        case .question: word(state.moreWaiting > 0 ? s.waitingShort(state.pendingCount ?? 2) : s.reply, p.amber)
        case .done: word(s.done, p.green)
        case .failed: word(s.failed, p.red)
        }
      }
    }
    .opacity(isStale ? 0.6 : 1)
  }

  private func word(_ t: String, _ c: Color) -> some View {
    Text(t).font(.caption2.weight(.semibold)).foregroundColor(c).lineLimit(1)
  }
}

/// v2: the minimal (and the width-limited compact) is a progress ring around the whale — the
/// todo share with todos, else the turn's clock (system-driven, like the lane); full in the
/// colour of a waiting / finished / failed turn.
@available(iOS 16.1, *)
struct WhaleWakeMinimal: View {
  let state: WhaleWakeState
  var diameter: CGFloat = 34
  @Environment(\.whaleWakeStaticLane) private var staticLane

  var body: some View {
    let p = WhaleWakePalette.dark
    let color = state.color(p)
    let line: CGFloat = diameter >= 32 ? 2.5 : 2
    ZStack {
      Circle().stroke(color.opacity(0.25), lineWidth: line)
      ring(color, line)
      WhaleWakeFrame(name: "compact-" + state.frame(compact: true), width: 24, height: 16)
        .scaleEffect(diameter >= 32 ? 1 : 0.75)
    }
    .frame(width: diameter, height: diameter)
    .overlay(alignment: .topTrailing) {
      if state.needsYou {
        Circle().fill(p.amber).frame(width: 6, height: 6).offset(x: 1, y: -1)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      // v3 background: the jobs still running, as a bubble number.
      if state.phase == .background, state.jobsRunning > 0 {
        Text("\(min(9, state.jobsRunning))").font(.system(size: 8, weight: .bold)).monospacedDigit()
          .foregroundColor(.black).frame(width: 11, height: 11).background(Circle().fill(p.blue)).offset(x: 2, y: 2)
      }
    }
  }

  @ViewBuilder private func ring(_ color: Color, _ line: CGFloat) -> some View {
    let whole = (state.phase != .running && state.phase != .background) || state.isMulti
    if let f = whole ? 1 : (state.ringFraction ?? (staticLane ? state.laneFraction() : nil)) {
      Circle().trim(from: 0, to: max(0.02, f))
        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
        .rotationEffect(.degrees(-90))
    } else {
      ProgressView(timerInterval: state.startedAt...state.laneClockEnd, countsDown: false) {
        EmptyView()
      } currentValueLabel: {
        EmptyView()
      }
      .progressViewStyle(.circular)
      .tint(color)
    }
  }
}

/// Expanded leading: the big whale (lock-* frame, 60×60), leaping on done.
@available(iOS 16.1, *)
struct WhaleWakeExpandedLeading: View {
  let state: WhaleWakeState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    WhaleWakeBigWhale(state: state, reduceMotion: reduceMotion)
  }
}

@available(iOS 16.1, *)
struct WhaleWakeBigWhale: View {
  let state: WhaleWakeState
  let reduceMotion: Bool

  var body: some View {
    let name = "lock-" + state.frame(compact: false)
    let leaping = name == "lock-breach" && !reduceMotion
    WhaleWakeFrame(name: name, width: 60, height: 60)
      .id(name)
      .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
      .offset(y: leaping ? -10 : 0)
      .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: state.breachTick)
      .animation(.easeOut(duration: 0.25), value: state.phase)
  }
}

@available(iOS 16.1, *)
struct WhaleWakeExpandedCenter: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    let p = WhaleWakePalette.dark
    VStack(alignment: .leading, spacing: 2) {
      Text(state.isMulti ? s.sessionsRunning(state.othersCount + 1) : attributes.title)
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.white)
        .lineLimit(1)
        .truncationMode(.tail)
      if state.phase != .running {
        WhaleWakeSubtitle(
          state: state, strings: s, isStale: isStale, color: state.phase == .background ? p.status : state.color(p),
          font: .subheadline)
      }
      if state.moreWaiting > 0, state.phase == .approval || state.phase == .question {
        Text(s.moreWaiting(state.moreWaiting)).font(.caption2.weight(.semibold)).foregroundColor(p.amber)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

@available(iOS 16.1, *)
struct WhaleWakeExpandedTrailing: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    let p = WhaleWakePalette.dark
    let url = WhaleWakeAttributes.sessionURL(attributes.sessionId, eventId: state.pending?.eventId)
    switch state.phase {
    case .running, .background:
      WhaleWakeTimer(state: state, isStale: isStale).frame(maxWidth: 76, alignment: .trailing)
    case .question:
      if state.hasAnswerRow(isStale: isStale) {
        if state.stopShown && !isStale { WhaleWakeStopKey(attributes: attributes, state: state, palette: p) }
      } else {
        WhaleWakeLinkKey(title: s.answer, url: url, background: p.amber, foreground: p.allowText)
      }
    case .done, .failed:
      WhaleWakeLinkKey(title: s.view, url: url, background: p.neutralBg, foreground: .white)
    case .approval:
      if state.stopShown && !isStale { WhaleWakeStopKey(attributes: attributes, state: state, palette: p) }
    }
  }
}

@available(iOS 16.1, *)
extension WhaleWakeAttributes.ContentState {
  /// A question gets a row of keys under it (options and 「去回答」) when it has options, or when
  /// 「停止」 takes the trailing spot 「去回答」 had in v1.
  func hasAnswerRow(isStale: Bool) -> Bool {
    phase == .question && (!(isStale ? [] : answerOptions).isEmpty || (stopShown && !isStale))
  }
}

@available(iOS 16.1, *)
struct WhaleWakeExpandedBottom: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    let p = WhaleWakePalette.dark
    Group {
      if state.isMulti {
        WhaleWakeMultiRows(attributes: attributes, state: state, isStale: isStale, palette: p, font: .caption)
      } else {
        switch state.phase {
        case .running:
          VStack(spacing: 4) {
            WhaleWakeLane(state: state, isStale: isStale, palette: p)
            HStack(spacing: 8) {
              if !isStale, let caption = state.laneCaption(s) {
                Text(caption).font(.caption).foregroundColor(p.status).lineLimit(1)
              } else {
                WhaleWakeSubtitle(state: state, strings: s, isStale: isStale, color: p.status, font: .caption)
              }
              Spacer(minLength: 6)
              if let b = state.bubbles, b.run > 0, !state.stopArmed() { WhaleWakeBubbleChip(count: b.run, palette: p) }
              if let t = state.tokens, !state.stopArmed() { Text(s.tokens(t)).font(.caption).monospacedDigit().foregroundColor(p.status) }
              if state.stopShown && !isStale { WhaleWakeStopKey(attributes: attributes, state: state, palette: p) }
            }
            if state.calves != nil { WhaleWakeCalvesRow(state: state, strings: s, palette: p) }
          }
        case .background:
          WhaleWakeTreeBlock(attributes: attributes, state: state, isStale: isStale, palette: p)
        case .approval:
          WhaleWakeApprovalKeys(attributes: attributes, state: state, isStale: isStale, palette: p)
        case .question:
          if state.hasAnswerRow(isStale: isStale) {
            WhaleWakeAnswerKeys(attributes: attributes, state: state, isStale: isStale, palette: p)
          }
        case .done, .failed:
          WhaleWakeSummaryLine(state: state, color: p.status, font: .caption, lines: 2)
        }
      }
    }
    .opacity(isStale ? 0.6 : 1)
  }
}

/// Multi: the main conversation and the next one, each a link, then 「还有 N 个」 / 「N 个等你确认」.
@available(iOS 16.1, *)
struct WhaleWakeMultiRows: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool
  let palette: WhaleWakePalette
  let font: Font

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    VStack(alignment: .leading, spacing: 3) {
      // Each conversation on its own line: title clipped, clock at a fixed width.
      row(attributes.sessionId, attributes.title, state.startedAt)
      if let other = state.others.first {
        row(other.sessionId, other.title, other.startedAt)
      }
      let rest = state.othersCount - min(1, state.others.count)
      if rest > 0 || state.othersPending > 0 {
        HStack(spacing: 8) {
          if state.othersPending > 0 { Text(s.needYou(state.othersPending)).font(font).foregroundColor(palette.amber) }
          if rest > 0 { Text(s.more(rest)).font(font).foregroundColor(palette.status) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ id: String, _ title: String, _ started: Date) -> some View {
    Link(destination: WhaleWakeAttributes.sessionURL(id)) {
      HStack(spacing: 4) {
        Text(title).font(font).foregroundColor(palette.status).lineLimit(1).truncationMode(.tail)
        Group {
          if isStale {
            Text(WhaleWakeClock.format((state.updatedAt ?? Date()).timeIntervalSince(started)))
          } else {
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
          }
        }
        .font(font).monospacedDigit().foregroundColor(palette.title)
        .lineLimit(1).frame(width: 54, alignment: .leading)
      }
      .layoutPriority(0)
    }
  }
}

// MARK: - Lock screen

@available(iOS 16.1, *)
struct WhaleWakeLockView: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool
  /// Lock-screen backgrounds go through activityBackgroundTint; previews draw the card themselves.
  var drawsCard = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let p = WhaleWakePalette.of(scheme)
    let s = WhaleWakeStrings(lang: attributes.lang)
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        WhaleWakeBigWhale(state: state, reduceMotion: reduceMotion)
        VStack(alignment: .leading, spacing: 3) {
          Text(state.isMulti ? s.sessionsRunning(state.othersCount + 1) : attributes.title)
            .font(.headline)
            .foregroundColor(p.title)
            .lineLimit(1)
            .truncationMode(.tail)
          if state.isMulti {
            WhaleWakeMultiRows(attributes: attributes, state: state, isStale: isStale, palette: p, font: .subheadline)
          } else {
            WhaleWakeSubtitle(
              state: state, strings: s, isStale: isStale,
              color: state.phase == .running || state.phase == .background ? p.status : state.color(p),
              font: .subheadline.weight(.medium))
            if state.moreWaiting > 0, state.phase == .approval || state.phase == .question {
              Text(s.moreWaiting(state.moreWaiting)).font(.caption.weight(.semibold)).foregroundColor(p.amber)
            }
          }
        }
        Spacer(minLength: 6)
        VStack(alignment: .trailing, spacing: 6) {
          Text(s.brand).font(.caption2.weight(.semibold)).foregroundColor(p.status)
          trailing(s, p)
        }
      }
      bottom(s, p)
    }
    .padding(16)
    .opacity(isStale ? 0.6 : 1)
    .background {
      if drawsCard { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(p.card) }
    }
    .activityBackgroundTint(p.card)
    .activitySystemActionForegroundColor(p.title)
    .widgetURL(WhaleWakeAttributes.sessionURL(attributes.sessionId, eventId: state.pending?.eventId))
    .environment(\.locale, s.locale)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("\(attributes.title), \(state.bareSubtitle(s))"))
  }

  @ViewBuilder private func trailing(_ s: WhaleWakeStrings, _ p: WhaleWakePalette) -> some View {
    let url = WhaleWakeAttributes.sessionURL(attributes.sessionId, eventId: state.pending?.eventId)
    switch state.phase {
    case .running, .background:
      WhaleWakeTimer(state: state, isStale: isStale, font: .title3.weight(.medium), color: p.title)
        .frame(maxWidth: 84, alignment: .trailing)
    case .question:
      if state.hasAnswerRow(isStale: isStale) {
        if state.stopShown && !isStale { WhaleWakeStopKey(attributes: attributes, state: state, palette: p) }
      } else {
        WhaleWakeLinkKey(title: s.answer, url: url, background: p.amber, foreground: p.allowText)
      }
    case .done, .failed:
      WhaleWakeLinkKey(title: s.view, url: url, background: p.neutralBg, foreground: p.neutralText)
    case .approval:
      if state.stopShown && !isStale { WhaleWakeStopKey(attributes: attributes, state: state, palette: p) }
    }
  }

  @ViewBuilder private func bottom(_ s: WhaleWakeStrings, _ p: WhaleWakePalette) -> some View {
    if state.isMulti {
      EmptyView()
    } else {
      switch state.phase {
      case .running:
        VStack(spacing: 6) {
          WhaleWakeLane(state: state, isStale: isStale, palette: p)
          HStack {
            Group {
              if isStale {
                Text(s.running(step: state.step, tool: state.toolLabel))
              } else if let caption = state.laneCaption(s) {
                Text(caption)
              } else if let left = minutesLeft {
                Text(s.minutesLeft(left))
              } else {
                Text(s.running(step: state.step, tool: state.toolLabel))
              }
            }
            .font(.caption).foregroundColor(p.status).lineLimit(1)
            Spacer(minLength: 6)
            if let b = state.bubbles, b.run > 0, !state.stopArmed() { WhaleWakeBubbleChip(count: b.run, palette: p) }
            if let t = state.tokens, !state.stopArmed() { Text(s.tokens(t)).font(.caption).monospacedDigit().foregroundColor(p.status) }
            if state.stopShown && !isStale { WhaleWakeStopKey(attributes: attributes, state: state, palette: p) }
          }
          if state.calves != nil { WhaleWakeCalvesRow(state: state, strings: s, palette: p) }
        }
      case .background:
        WhaleWakeTreeBlock(attributes: attributes, state: state, isStale: isStale, palette: p)
      case .approval:
        WhaleWakeApprovalKeys(attributes: attributes, state: state, isStale: isStale, palette: p)
      case .question:
        if state.hasAnswerRow(isStale: isStale) {
          WhaleWakeAnswerKeys(attributes: attributes, state: state, isStale: isStale, palette: p)
        }
      case .done, .failed:
        WhaleWakeSummaryLine(state: state, color: p.title, font: .subheadline, lines: 2)
      }
    }
  }

  /// 「预计还需约 N 分钟」 at this snapshot: only on the clock (no todos), at least a minute left.
  private var minutesLeft: Int? {
    guard state.progress == nil else { return nil }
    let left = state.expectedEndAt.timeIntervalSinceNow
    return left >= 60 ? Int((left / 60).rounded()) : nil
  }
}
