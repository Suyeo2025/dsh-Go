// Sample 「鲸游」states: the widget's previews, RunnerTests' rendered boards, and the Debug-only
// demo launch argument (`-DSHGOLADemo <name>`, LiveActivityChannel). Text from the design boards.

import Foundation

@available(iOS 16.1, *)
enum WhaleWakeSamples {
  static let names = [
    "running", "running-todo", "approval", "approval-high", "approval-expired", "question", "done", "failed",
    "multi", "stale",
  ]

  /// v2 (plan/design/live-activity-v2-contract.md): options, buoys, conclusion line, 「停止」.
  static let v2Names = [
    "v2-running-buoys", "v2-running-stop-armed", "v2-running-many", "v2-question-options", "v2-question-stop",
    "v2-approval-stop", "v2-done-summary", "v2-failed-summary",
  ]

  /// v3 (plan/design/notify-v3-contract.md §2): the work tree.
  static let v3Names = [
    "v3-background", "v3-background-calves", "v3-calves", "v3-workflow", "v3-team-goal", "v3-approval-from", "v3-question-from",
    "v3-goal-clock",
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
    // v2: all text is made up (no real conversation).
    case "v2-running-buoys", "v2-running-stop-armed":
      return S(phase: .running, startedAt: started, expectedEndAt: end, progress: 3.0 / 5, step: 14, toolLabel: bash, tokens: 34_000,
        updatedAt: now, v: 2, todos: [.init(.done), .init(.done), .init(.done), .init(.active), .init(.todo)], todoDone: 3, todoTotal: 5,
        todoLabel: zh ? "跑测试" : "Run tests", showStop: true,
        stopArmedUntil: name == "v2-running-stop-armed" ? now.addingTimeInterval(4) : nil)
    case "v2-running-many":
      return S(phase: .running, startedAt: started, expectedEndAt: end, progress: 9.0 / 20, step: 40, toolLabel: zh ? "读取文件" : "Read file",
        tokens: 120_000, updatedAt: now, v: 2,
        todos: [.init(.done), .init(.done), .init(.done), .init(.active), .init(.todo), .init(.todo), .init(.todo), .init(.todo)],
        todoDone: 9, todoTotal: 20, todoLabel: zh ? "更新接口文档" : "Update API docs", showStop: true)
    case "v2-question-options", "v2-question-stop":
      return S(phase: .question, startedAt: started, expectedEndAt: end, progress: 3.0 / 8, step: 14, toolLabel: zh ? "思考中" : "Thinking",
        tokens: 34_000,
        pending: .init(eventId: "ev_demo_02", kind: .question, text: zh ? "要把旧接口一起删掉吗？" : "Remove the old API too?",
          risk: "unknown", askedAt: now,
          options: zh
            ? [.init(id: "0", label: "删掉"), .init(id: "1", label: "保留并标废弃"), .init(id: "2", label: "先问我…")]
            : [.init(id: "0", label: "Remove"), .init(id: "1", label: "Deprecate"), .init(id: "2", label: "Ask me…")]),
        updatedAt: now, v: 2, showStop: name == "v2-question-stop")
    case "v2-approval-stop":
      return S(phase: .approval, startedAt: started, expectedEndAt: end, step: 14, toolLabel: bash, tokens: 34_000,
        pending: pending(.approval, zh ? "运行 npm run migrate" : "npm run migrate"), updatedAt: now, v: 2, showStop: true)
    case "v2-done-summary":
      return S(phase: .done, startedAt: started, expectedEndAt: now, progress: 1, step: 14, tokens: 34_000,
        summary: zh ? "14 步 · 12:34" : "14 steps · 12:34", breachTick: 1, updatedAt: now, ended: true, v: 2,
        summaryLine: zh ? "登录模块已拆成三层，42 个测试全部通过，旧接口标为废弃。" : "Login split into three layers; all 42 tests pass, old API deprecated.")
    case "v2-failed-summary":
      return S(phase: .failed, startedAt: started, expectedEndAt: now, step: 9, tokens: 21_000, summary: zh ? "测试未通过" : "tests failed",
        updatedAt: now, v: 2,
        summaryLine: zh ? "迁移脚本在第 3 步报错：users 表缺少 email 列。" : "The migration failed at step 3: users has no email column.")
    // v3: made-up text throughout.
    case "v3-background":
      return S(phase: .background, startedAt: started, expectedEndAt: end, step: 14, toolLabel: zh ? "后台进行中" : "In background",
        tokens: 34_000, updatedAt: now, v: 3, showStop: true,
        bubbles: .init(run: 2, top: [.init(l: zh ? "跑集成测试" : "Integration tests", since: Int(now.timeIntervalSince1970) - 192),
          .init(l: "npm run build", since: Int(now.timeIntervalSince1970) - 75)]))
    case "v3-background-calves":
      return S(phase: .background, startedAt: started, expectedEndAt: end, step: 14, toolLabel: zh ? "后台进行中" : "In background",
        updatedAt: now, v: 3, showStop: true,
        calves: [.init(.run, zh ? "审查员" : "Review"), .init(.run, zh ? "测试员" : "Tests"), .init(.err, zh ? "文档" : "Docs")],
        calvesMore: 2, bubbles: .init(run: 1, fail: 1, top: [.init(l: zh ? "跑集成测试" : "Integration tests", since: Int(now.timeIntervalSince1970) - 192)]))
    case "v3-calves":
      return S(phase: .running, startedAt: started, expectedEndAt: end, step: 22, toolLabel: zh ? "运行子代理" : "Run subagent", tokens: 58_000,
        updatedAt: now, v: 3, showStop: true,
        calves: [.init(.wait, zh ? "审查员" : "Review"), .init(.run, zh ? "测试员" : "Tests"), .init(.done, zh ? "调研" : "Research")],
        calvesMore: 1, bubbles: .init(run: 1, top: [.init(l: "pytest -x", since: Int(now.timeIntervalSince1970) - 40)]))
    case "v3-workflow":
      return S(phase: .running, startedAt: started, expectedEndAt: end, progress: 0.5, step: 31, toolLabel: zh ? "运行 workflow" : "Run workflow",
        tokens: 91_000, updatedAt: now, v: 3, showStop: true,
        calves: [.init(.run, zh ? "审查 A" : "Review A"), .init(.run, zh ? "审查 B" : "Review B"), .init(.done, zh ? "审查 C" : "Review C")],
        calvesMore: 2,
        wf: .init(name: zh ? "代码审查流水线" : "Review pipeline",
          seg: [.init(.done, 1), .init(.active, 0.6), .init(.todo, 0), .init(.todo, 0)], label: zh ? "审查" : "Review"))
    case "v3-team-goal":
      return S(phase: .running, startedAt: started, expectedEndAt: end, progress: 3.0 / 7, step: 8, toolLabel: zh ? "思考中" : "Thinking",
        tokens: 120_000, updatedAt: now, v: 3, showStop: true,
        calves: [.init(.run, zh ? "前端" : "Web"), .init(.run, zh ? "后端" : "API")], team: .init(done: 3, total: 7),
        goal: .init(round: 3, max: 20))
    case "v3-approval-from":
      return S(phase: .approval, startedAt: started, expectedEndAt: end, step: 22, toolLabel: bash, tokens: 58_000,
        pending: .init(eventId: "ev_demo_03", kind: .approval, text: zh ? "运行 npm publish" : "npm publish", risk: "normal", askedAt: now,
          from: zh ? "审查员" : "Review"),
        updatedAt: now, v: 3, showStop: true, calves: [.init(.wait, zh ? "审查员" : "Review"), .init(.run, zh ? "测试员" : "Tests")],
        pendingCount: 3)
    case "v3-question-from":
      return S(phase: .question, startedAt: started, expectedEndAt: end, step: 9, toolLabel: zh ? "思考中" : "Thinking",
        pending: .init(eventId: "ev_demo_04", kind: .question, text: zh ? "先改哪个模块？" : "Which module first?", risk: "unknown",
          askedAt: now, options: [.init(id: "0", label: zh ? "登录" : "Login"), .init(id: "1", label: zh ? "支付" : "Payments")],
          from: zh ? "前端" : "Web"),
        updatedAt: now, v: 3, pendingCount: 2)
    case "v3-goal-clock":
      return S(phase: .running, startedAt: started, expectedEndAt: end, step: 5, toolLabel: zh ? "读取文件" : "Read file", tokens: 12_000,
        updatedAt: now, v: 3, showStop: true, goal: .init(round: 4, max: nil))
    default:
      return nil
    }
  }
}
