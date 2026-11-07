// 「鲸游」copy (plan/design/live-activity-a/behavior.md «文案（中 / 英）»), chosen by the
// Activity's `lang`, never the system language. A table in code rather than Localizable.strings: the
// same copy is compiled into the widget extension, the App (intents) and RunnerTests, and the
// language is picked explicitly per Activity.

import Foundation

struct WhaleWakeStrings {
  let zh: Bool

  init(lang: String) { zh = lang.lowercased().hasPrefix("zh") }

  var locale: Locale { Locale(identifier: zh ? "zh-Hans" : "en") }

  // compact trailing
  var review: String { zh ? "待确认" : "Review" }
  var reply: String { zh ? "待回答" : "Reply" }
  var done: String { zh ? "完成" : "Done" }
  var failed: String { zh ? "失败" : "Failed" }
  func sessionsShort(_ n: Int) -> String { zh ? "\(n) 个" : "×\(n)" }

  // status sentences
  func running(step: Int, tool: String) -> String {
    let head = zh ? "正在运行 · 第 \(step) 步" : "Running · step \(step)"
    return tool.isEmpty ? head : "\(head) · \(tool)"
  }
  func needsApproval(_ text: String) -> String { join(zh ? "等你确认" : "Needs approval", text) }
  func needsAnswer(_ text: String) -> String { join(zh ? "等你回答" : "Needs an answer", text) }
  func stillWaiting(_ text: String) -> String { join(zh ? "仍在等你确认" : "Still waiting for you", text) }
  func doneLine(_ summary: String?) -> String { join(zh ? "做完了" : "Done", summary ?? "") }
  func failedLine(_ reason: String?) -> String { join(zh ? "出错了" : "Failed", reason ?? "") }
  /// Locked phone (privacySensitive): the subtitle without the command.
  var needsApprovalBare: String { zh ? "等你确认" : "Needs approval" }
  var needsAnswerBare: String { zh ? "等你回答" : "Needs an answer" }

  func sessionsRunning(_ n: Int) -> String { zh ? "\(n) 个对话在跑" : "\(n) sessions running" }
  func needYou(_ n: Int) -> String { zh ? "\(n) 个等你确认" : "\(n) need\(n == 1 ? "s" : "") you" }
  func more(_ n: Int) -> String { zh ? "还有 \(n) 个" : "\(n) more" }

  var mayBeStale: String { zh ? "可能已过时" : "May be out of date" }
  var updatedPrefix: String { zh ? "" : "updated " }
  var updatedSuffix: String { zh ? "前更新" : " ago" }

  // buttons
  var allow: String { zh ? "允许" : "Allow" }
  var deny: String { zh ? "拒绝" : "Deny" }
  var answer: String { zh ? "去回答" : "Reply" }
  var view: String { zh ? "查看" : "View" }
  var open: String { zh ? "打开" : "Open" }
  var hint: String { zh ? "解锁后确认 · 2 分钟内未处理将收回按钮" : "Confirm after unlock · buttons hide after 2 min" }

  // v2
  var stop: String { zh ? "停止" : "Stop" }
  var stopAgain: String { zh ? "再点一次停止" : "Tap again to stop" }
  var stopping: String { zh ? "正在停止" : "Stopping" }
  /// 「3/7 · 跑测试」.
  func todoLine(done: Int, total: Int, label: String?) -> String {
    let head = "\(done)/\(total)"
    guard let label, !label.isEmpty else { return head }
    return "\(head) · \(label)"
  }

  /// A finished card past its retention.
  var outdated: String { zh ? "已过时" : "Out of date" }

  // v3 (notify-v3-contract §2.1)
  /// 「主线已回复 · 后台 2 个任务在跑」 and its variants.
  func background(jobs: Int, subagents: Int) -> String {
    switch (jobs > 0, subagents > 0) {
    case (true, true):
      return zh ? "主线已回复 · 后台 \(jobs) 个任务 · \(subagents) 个子代理" : "Replied · \(en(jobs, "task")) · \(en(subagents, "subagent"))"
    case (false, true): return zh ? "主线已回复 · \(subagents) 个子代理在跑" : "Replied · \(en(subagents, "subagent")) running"
    default:
      let n = max(1, jobs)
      return zh ? "主线已回复 · 后台 \(n) 个任务在跑" : "Replied · \(en(n, "background task")) running"
    }
  }
  private func en(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
  /// compact trailing: 「后台 2」.
  func backgroundShort(_ n: Int) -> String { zh ? "后台 \(n)" : "\(n) bg" }
  /// 「子代理 · 审查员」 before what a descendant asks.
  func from(_ name: String) -> String { zh ? "子代理 · \(name)" : "Subagent · \(name)" }
  /// 「还有 2 个等你」.
  func moreWaiting(_ n: Int) -> String { zh ? "还有 \(n) 个等你" : "\(n) more waiting" }
  /// compact trailing when several wait: 「3 个」.
  func waitingShort(_ n: Int) -> String { zh ? "\(n) 个" : "×\(n)" }
  /// 「阶段 2/4 · 审查」.
  func phaseLine(_ i: Int, _ n: Int, _ label: String) -> String {
    let head = zh ? "阶段 \(i)/\(n)" : "Phase \(i)/\(n)"
    return label.isEmpty ? head : "\(head) · \(label)"
  }
  /// 「任务板 3/7」.
  func board(_ done: Int, _ total: Int) -> String { zh ? "任务板 \(done)/\(total)" : "Board \(done)/\(total)" }
  /// 「第 3/20 轮」 / 「第 3 轮」.
  func round(_ r: Int, _ max: Int?) -> String {
    if let max, max > 0 { return zh ? "第 \(r)/\(max) 轮" : "Round \(r)/\(max)" }
    return zh ? "第 \(r) 轮" : "Round \(r)"
  }
  func plus(_ n: Int) -> String { "+\(n)" }

  func minutesLeft(_ m: Int) -> String { zh ? "预计还需约 \(m) 分钟" : "About \(m) min left" }

  /// 「3.4 万 tok」/「34k tok」.
  func tokens(_ n: Int) -> String {
    if zh {
      if n >= 10_000 { return "\(trim(Double(n) / 10_000)) 万 tok" }
      return "\(n) tok"
    }
    if n >= 1_000_000 { return "\(trim(Double(n) / 1_000_000))M tok" }
    if n >= 1_000 { return "\(trim(Double(n) / 1_000))k tok" }
    return "\(n) tok"
  }

  var brand: String { "DSH GO" }

  private func trim(_ v: Double) -> String {
    let r = (v * 10).rounded() / 10
    return r >= 100 || r == r.rounded() ? String(Int(r.rounded())) : String(format: "%.1f", r)
  }

  private func join(_ head: String, _ tail: String) -> String {
    tail.isEmpty ? head : "\(head) · \(tail)"
  }
}
