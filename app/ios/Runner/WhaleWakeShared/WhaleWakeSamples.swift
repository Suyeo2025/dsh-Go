// Sample 「鲸游」states: the widget's previews, RunnerTests' rendered boards, and the Debug-only
// demo launch argument (`-DSHGOLADemo <name>`, LiveActivityChannel). Text from the design boards.

import Foundation

@available(iOS 16.1, *)
enum WhaleWakeSamples {
  static let names = [
    "running", "running-todo", "approval", "approval-high", "approval-expired", "question", "done", "failed",
    "multi", "stale",
  ]

  static func attributes(lang: String = "zh") -> WhaleWakeAttributes {
    WhaleWakeAttributes(
      sessionId: "session-demo-whale-wake", title: lang.hasPrefix("zh") ? "重构登录模块" : "Refactor the login module",
      hostId: "demo", lang: lang)
  }

  /// [name] at [now]; nil for an unknown name.
  static func state(_ name: String, lang: String = "zh", now: Date = Date()) -> WhaleWakeAttributes.ContentState? {
    let zh = lang.hasPrefix("zh")
    let started = now.addingTimeInterval(-(12 * 60 + 34))
    let end = started.addingTimeInterval(21 * 60)
    let bash = zh ? "运行 Bash" : "Run Bash"
    func pending(_ kind: WhaleWakeAttributes.ContentState.Pending.Kind, _ text: String, risk: String = "normal", asked: Date = now, expired: Bool = false)
      -> WhaleWakeAttributes.ContentState.Pending
    {
      .init(eventId: "ev_demo_01", kind: kind, text: text, risk: risk, askedAt: asked, expired: expired)
    }
    typealias S = WhaleWakeAttributes.ContentState
    switch name {
    case "running":
      return S(phase: .running, startedAt: started, expectedEndAt: end, step: 14, toolLabel: bash, tokens: 34_000, updatedAt: now)
    case "running-todo":
      return S(phase: .running, startedAt: started, expectedEndAt: end, progress: 0.6, step: 14, toolLabel: bash, tokens: 34_000, updatedAt: now)
    case "approval":
      return S(phase: .approval, startedAt: started, expectedEndAt: end, step: 14, toolLabel: bash, tokens: 34_000,
        pending: pending(.approval, zh ? "运行 git push origin feature/login" : "git push origin feature/login"), updatedAt: now)
    case "approval-high":
      return S(phase: .approval, startedAt: started, expectedEndAt: end, step: 14, toolLabel: bash, tokens: 34_000,
        pending: pending(.approval, zh ? "运行 git push --force" : "git push --force", risk: "high"), updatedAt: now)
    case "approval-expired":
      return S(phase: .approval, startedAt: started, expectedEndAt: end, step: 14, toolLabel: bash, tokens: 34_000,
        pending: pending(.approval, zh ? "运行 git push --force" : "git push --force", risk: "high", asked: now.addingTimeInterval(-150), expired: true),
        updatedAt: now)
    case "question":
      return S(phase: .question, startedAt: started, expectedEndAt: end, step: 9, toolLabel: zh ? "思考中" : "Thinking", tokens: 21_000,
        pending: pending(.question, zh ? "用哪个分支？" : "Which branch?"), updatedAt: now)
    case "done":
      return S(phase: .done, startedAt: started, expectedEndAt: now, progress: 1, step: 14, tokens: 34_000,
        summary: zh ? "14 步 · 12:34" : "14 steps · 12:34", breachTick: 1, updatedAt: now, ended: true)
    case "failed":
      return S(phase: .failed, startedAt: started, expectedEndAt: now, step: 9, tokens: 21_000, summary: zh ? "测试未通过" : "tests failed", updatedAt: now)
    case "multi":
      return S(phase: .running, startedAt: started, expectedEndAt: end, step: 14, toolLabel: bash, tokens: 34_000,
        others: [.init(sessionId: "session-demo-other", title: zh ? "iOS 推送桥" : "iOS push bridge", startedAt: now.addingTimeInterval(-190))],
        othersCount: 1, othersPending: 1, updatedAt: now)
    case "stale":
      return S(phase: .running, startedAt: started, expectedEndAt: end, step: 14, toolLabel: bash, tokens: 34_000, updatedAt: now.addingTimeInterval(-180))
    default:
      return nil
    }
  }
}
