// 「鲸游」views: Dynamic Island compact / minimal / expanded regions and the lock-screen banner
// (plan/design/live-activity-a/README.md §1/§3, behavior.md, and the plan/ios-wave2-design.md
// revision: the expanded leading region shows the 60×60 lock-* whale; the whale's sign is the only
// status icon). Plain SwiftUI views over (attributes, state, isStale) so WhaleWakeActivity wires them
// into ActivityConfiguration and RunnerTests renders them with ImageRenderer.
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
    case .running: return "swim"
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
    case .running: return p.blue
    case .approval, .question: return p.amber
    case .done: return p.green
    case .failed: return p.red
    }
  }

  /// The one-line status: what the banner says under the title.
  func subtitle(_ s: WhaleWakeStrings, now: Date = Date()) -> String {
    switch phase {
    case .running: return s.running(step: step, tool: toolLabel)
    case .approval:
      let text = pending?.text ?? ""
      return approvalFolded(now: now) ? s.stillWaiting(text) : s.needsApproval(text)
    case .question: return s.needsAnswer(pending?.text ?? "")
    case .done: return s.doneLine(summary)
    case .failed: return s.failedLine(summary)
    }
  }

  /// Same, without the command / question text (locked phone, redacted).
  func bareSubtitle(_ s: WhaleWakeStrings) -> String {
    switch phase {
    case .approval: return s.needsApprovalBare
    case .question: return s.needsAnswerBare
    default: return subtitle(s)
    }
  }
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
    .lineLimit(1)
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
    WhaleWakeFrame(name: "compact-" + state.frame(compact: true), width: 24, height: 16)
  }
}

@available(iOS 16.1, *)
struct WhaleWakeCompactTrailing: View {
  let attributes: WhaleWakeAttributes
  let state: WhaleWakeState
  let isStale: Bool

  var body: some View {
    let s = WhaleWakeStrings(lang: attributes.lang)
    let p = WhaleWakePalette.dark
    Group {
      if state.isMulti {
        HStack(spacing: 4) {
          Text(s.sessionsShort(state.othersCount + 1)).font(.footnote.weight(.medium)).monospacedDigit()
            .foregroundColor(.white)
          if state.othersPending > 0 { Circle().fill(p.amber).frame(width: 6, height: 6) }
        }
      } else {
        switch state.phase {
        case .running: WhaleWakeTimer(state: state, isStale: isStale, font: .footnote.weight(.medium)).frame(maxWidth: 52)
        case .approval: word(s.review, p.amber)
        case .question: word(s.reply, p.amber)
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

@available(iOS 16.1, *)
struct WhaleWakeMinimal: View {
  let state: WhaleWakeState

  var body: some View {
    WhaleWakeFrame(name: "compact-" + state.frame(compact: true), width: 24, height: 16)
      .overlay(alignment: .topTrailing) {
        if state.needsYou {
          Circle().fill(WhaleWakePalette.dark.amber).frame(width: 6, height: 6).offset(x: 3, y: -3)
        }
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
        WhaleWakeSubtitle(state: state, strings: s, isStale: isStale, color: state.color(p), font: .subheadline)
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
    case .running:
      WhaleWakeTimer(state: state, isStale: isStale).frame(maxWidth: 76, alignment: .trailing)
    case .question:
      WhaleWakeLinkKey(title: s.answer, url: url, background: p.amber, foreground: p.allowText)
    case .done, .failed:
      WhaleWakeLinkKey(title: s.view, url: url, background: p.neutralBg, foreground: .white)
    case .approval:
      EmptyView()
    }
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
            HStack {
              WhaleWakeSubtitle(state: state, strings: s, isStale: isStale, color: p.status, font: .caption)
              Spacer(minLength: 6)
              if let t = state.tokens { Text(s.tokens(t)).font(.caption).monospacedDigit().foregroundColor(p.status) }
            }
          }
        case .approval:
          WhaleWakeApprovalKeys(attributes: attributes, state: state, isStale: isStale, palette: p)
        case .question, .done, .failed:
          EmptyView()
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
              color: state.phase == .running ? p.status : state.color(p), font: .subheadline.weight(.medium))
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
    case .running:
      WhaleWakeTimer(state: state, isStale: isStale, font: .title3.weight(.medium), color: p.title)
        .frame(maxWidth: 84, alignment: .trailing)
    case .question:
      WhaleWakeLinkKey(title: s.answer, url: url, background: p.amber, foreground: p.allowText)
    case .done, .failed:
      WhaleWakeLinkKey(title: s.view, url: url, background: p.neutralBg, foreground: p.neutralText)
    case .approval:
      EmptyView()
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
              } else if let left = minutesLeft {
                Text(s.minutesLeft(left))
              } else {
                Text(s.running(step: state.step, tool: state.toolLabel))
              }
            }
            .font(.caption).foregroundColor(p.status).lineLimit(1)
            Spacer(minLength: 6)
            if let t = state.tokens { Text(s.tokens(t)).font(.caption).monospacedDigit().foregroundColor(p.status) }
          }
        }
      case .approval:
        WhaleWakeApprovalKeys(attributes: attributes, state: state, isStale: isStale, palette: p)
      default:
        EmptyView()
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
