// The「鲸游」Live Activity's ContentState, built from what the app knows of a
// conversation. Keys and meaning: plan/design/live-activity-a/contract.md §1,
// plus the revision in plan/ios-wave2-design.md «la-dart › 契约修订»
// (`pending.approvalExpiresAt`, `pending.expired`) and the v2 additions in
// plan/design/live-activity-v2-contract.md §1 (question options, todo buoys,
// the conclusion's first sentence, the stop button), and v3 in
// plan/design/notify-v3-contract.md §2 (the work tree: `background`, calves,
// bubbles, workflow segments, team board, goal, tree-wide pending). The bridge
// (dsh-watch-bridge src/push/liveactivity.ts) sends the same shape while the
// app is away, so the labels here follow its table.
//
// Everything shown on the lock screen passes `maskSecrets` first and is cut
// to a fixed number of Unicode characters (title 24, text 48, both ending in
// 「…」when cut). Dates are device clock (Host time + clock skew); [toMap]
// writes them as Unix seconds.

import 'dart:ui' show Locale;

import 'package:dsh_client/dsh_client.dart'
    show ApprovalRequest, GoalProjection, JobInfo, TodoItem, UserQuestionRequest;

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';
import '../ui/chat/run_info.dart' show ActivityKind, RunActivity;
import '../ui/chat/secret_mask.dart';
import 'work_tree.dart';

/// Title ≤ 24 characters, pending text ≤ 48, tool label ≤ 12; at most two
/// other conversations are listed.
const islandTitleMax = 24;
const islandTextMax = 48;
const islandLabelMax = 12;
const islandOthersMax = 2;

/// v2: at most three answer buttons of ≤ 10 characters, eight todo buoys, a
/// conclusion line of ≤ 60.
const islandOptionsMax = 3;
const islandOptionLabelMax = 10;
const islandBuoysMax = 8;
const islandTodoLabelMax = 12;
const islandSummaryLineMax = 60;

/// v3: three calves of ≤ 6, two bubbles of ≤ 12, six workflow segments,
/// a workflow name of ≤ 16 and a requester name of ≤ 8.
const islandCalvesMax = 3;
const islandCalfLabelMax = 6;
const islandBubblesMax = 2;
const islandBubbleLabelMax = 12;
const islandSegmentsMax = 6;
const islandWorkflowNameMax = 16;
const islandFromMax = 8;

/// The ContentState version this app writes.
const islandContentVersion = 3;

/// How long an approval / question keeps its buttons on the island.
const islandApprovalWindow = Duration(seconds: 120);

enum IslandPhase { running, background, approval, question, done, failed }

/// The thing waiting on the person.
class IslandPending {
  const IslandPending({
    required this.eventId,
    required this.kind,
    required this.text,
    required this.risk,
    required this.askedAt,
    required this.approvalExpiresAt,
    this.expired = false,
    this.options = const [],
    this.from,
  });

  final String eventId;

  /// `approval` or `question`.
  final String kind;
  final String text;

  /// `normal`, `high` or `unknown` (approvals without a command).
  final String risk;
  final DateTime askedAt;
  final DateTime approvalExpiresAt;

  /// The two minutes are over: the island trades its buttons for 「打开」.
  final bool expired;

  /// One-tap answers of a question (v2 §1.1): `id` is the option's index in
  /// the original question, the bridge answers with that option's own label.
  final List<({String id, String label})> options;

  /// v3: the descendant conversation that asks (null: the root itself).
  final String? from;

  Map<String, Object?> toMap() => {
    'eventId': eventId,
    'kind': kind,
    'text': text,
    'risk': risk,
    'askedAt': unixSeconds(askedAt),
    'approvalExpiresAt': unixSeconds(approvalExpiresAt),
    'expired': expired,
    'from': ?from,
    if (options.isNotEmpty)
      'options': [
        for (final o in options) {'id': o.id, 'label': o.label},
      ],
  };
}

/// Another running conversation, as listed under the main one.
class IslandOther {
  const IslandOther({required this.sessionId, required this.title, required this.startedAt});
  final String sessionId;
  final String title;
  final DateTime startedAt;

  Map<String, Object?> toMap() => {'sessionId': sessionId, 'title': title, 'startedAt': unixSeconds(startedAt)};
}

/// Input: another running top-level conversation ([startedAt] Host time).
class OtherRun {
  const OtherRun({required this.sessionId, required this.title, required this.startedAt});
  final String sessionId;
  final String title;
  final DateTime startedAt;
}

/// Input: how the turn ended ([start] / [end] Host time).
class IslandFinish {
  const IslandFinish({
    required this.failed,
    required this.start,
    required this.end,
    required this.steps,
    this.reason,
    this.reply,
    this.agents = 0,
    this.jobs = 0,
    this.failures = 0,
    this.goalRounds,
  });
  final bool failed;
  final DateTime start;
  final DateTime end;

  /// Tool calls the turn made.
  final int steps;

  /// The failure as the Host gave it (masked and cut here).
  final String? reason;

  /// The turn's last reply (its first statement becomes `summaryLine`).
  final String? reply;

  /// v3: descendant conversations and background jobs the tree ran, and how
  /// many of them failed (told in the summary, never on their own).
  final int agents;
  final int jobs;
  final int failures;

  /// A goal reached in this many rounds (done) or stuck (failed).
  final int? goalRounds;
}

class IslandContent {
  const IslandContent({
    required this.title,
    required this.phase,
    required this.startedAt,
    required this.expectedEndAt,
    required this.step,
    required this.toolLabel,
    this.progress,
    this.tokens,
    this.pending,
    this.others = const [],
    this.othersCount = 0,
    this.othersPending = 0,
    this.summary,
    this.breachTick = 0,
    this.buoys = const [],
    this.todoDone,
    this.todoTotal,
    this.todoLabel,
    this.summaryLine,
    this.showStop = false,
    this.stepStartedAt,
    this.tree = const {},
  });

  /// The Activity's title (an attribute, not part of ContentState).
  final String title;
  final IslandPhase phase;
  final DateTime startedAt;
  final DateTime expectedEndAt;
  final double? progress;
  final int step;
  final String toolLabel;
  final int? tokens;
  final IslandPending? pending;
  final List<IslandOther> others;
  final int othersCount;
  final int othersPending;
  final String? summary;
  final int breachTick;

  /// v2: `done` / `active` / `todo` per buoy (≤ 8, see [islandBuoys]).
  final List<String> buoys;
  final int? todoDone;
  final int? todoTotal;
  final String? todoLabel;

  /// The conclusion's first statement (done / failed only).
  final String? summaryLine;

  /// The run can be stopped from the island.
  final bool showStop;

  /// When the tool at work started (device clock).
  final DateTime? stepStartedAt;

  /// v3 keys, already in wire shape (`calves`, `calvesMore`, `bubbles`, `wf`,
  /// `team`, `goal`, `pendingCount`); see [islandContentOf].
  final Map<String, Object?> tree;

  bool get finished => phase == IslandPhase.done || phase == IslandPhase.failed;

  IslandContent copyWith({IslandPhase? phase, int? breachTick, bool? expired}) => IslandContent(
    title: title,
    phase: phase ?? this.phase,
    startedAt: startedAt,
    expectedEndAt: expectedEndAt,
    step: step,
    toolLabel: toolLabel,
    progress: progress,
    tokens: tokens,
    pending: pending == null || expired == null
        ? pending
        : IslandPending(
            eventId: pending!.eventId,
            kind: pending!.kind,
            text: pending!.text,
            risk: pending!.risk,
            askedAt: pending!.askedAt,
            approvalExpiresAt: pending!.approvalExpiresAt,
            expired: expired,
            options: pending!.options,
            from: pending!.from,
          ),
    others: others,
    othersCount: othersCount,
    othersPending: othersPending,
    summary: summary,
    breachTick: breachTick ?? this.breachTick,
    buoys: buoys,
    todoDone: todoDone,
    todoTotal: todoTotal,
    todoLabel: todoLabel,
    summaryLine: summaryLine,
    showStop: showStop,
    stepStartedAt: stepStartedAt,
    tree: tree,
  );

  /// The channel / bridge payload (`ContentStateMap`).
  Map<String, Object?> toMap() => {
    'v': islandContentVersion,
    'phase': phase.name,
    'startedAt': unixSeconds(startedAt),
    'expectedEndAt': unixSeconds(expectedEndAt),
    'progress': progress,
    'step': step,
    'toolLabel': toolLabel,
    'tokens': tokens,
    'pending': pending?.toMap(),
    'others': [for (final o in others) o.toMap()],
    'othersCount': othersCount,
    'othersPending': othersPending,
    'summary': summary,
    'breachTick': breachTick,
    // v2 keys only when they say something (older readers skip them anyway).
    if (buoys.isNotEmpty)
      'todos': [
        for (final b in buoys) {'s': b},
      ],
    'todoDone': ?todoDone,
    'todoTotal': ?todoTotal,
    'todoLabel': ?todoLabel,
    'summaryLine': ?summaryLine,
    'showStop': showStop,
    if (stepStartedAt case final at?) 'stepStartedAt': unixSeconds(at),
    ...tree,
  };

  /// Same payload (what the Activity would show is the same).
  bool sameAs(IslandContent? other) {
    if (other == null || other.title != title) return false;
    final a = toMap(), b = other.toMap();
    return _deepEquals(a, b);
  }

  static bool _deepEquals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_deepEquals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}

int unixSeconds(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

/// [text] cut to [max] Unicode characters (code points), the last one
/// replaced by 「…」when it had to be cut.
String islandClip(String text, int max) {
  final runes = text.runes;
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max - 1))}…';
}

/// Masked, on one line, cut.
String islandLine(String text, int max) => islandClip(maskSecrets(text).replaceAll(RegExp(r'\s+'), ' ').trim(), max);

/// The approval risk tier of a shell command. Copied from dsh-watch-bridge
/// `src/pending.ts` `riskOf` (line ~112); keep the two in step. Display
/// only: it never answers anything.
String islandRiskOf(String? command) {
  if (command == null || command.isEmpty) return 'unknown';
  return RegExp(
        r'(rm\s+-rf|sudo\b|--force|push\s+-f\b|chmod\s+777|drop\s+table|\|\s*(ba)?sh\b)',
        caseSensitive: false,
      ).hasMatch(command)
      ? 'high'
      : 'normal';
}

/// The fixed-language strings for an Activity's [lang] (`zh` / `en`).
L10n islandL10n(String lang) => lookupL10n(lang == 'en' ? AppLocale.en : AppLocale.zhCN);

/// The app's language as an Activity `lang`.
String islandLangOf(Locale locale) => locale.languageCode == 'en' ? 'en' : 'zh';

/// The short label of tool [name] (same table as the bridge's).
String islandToolLabel(String name, L10n l) {
  final label = switch (name) {
    'bash' || 'pwsh' => l.islandToolBash,
    'read' || 'read_image' => l.islandToolRead,
    'edit' || 'write' || 'str_replace_editor' || 'apply_patch' => l.islandToolEdit,
    'grep' || 'glob' => l.islandToolSearch,
    'web_search' || 'web_fetch' => l.islandToolWeb,
    _ => name,
  };
  return islandClip(label, islandLabelMax);
}

/// `12:34`, or `1:02:03` past an hour.
String islandDuration(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// The buoys of [todos] (v2 §1.2): one per todo up to [islandBuoysMax], else
/// [islandBuoysMax] even slices (all done → done, any in progress → active).
List<String> islandBuoys(List<TodoItem> todos) {
  String of(String status) => switch (status) {
    'completed' => 'done',
    'in_progress' => 'active',
    _ => 'todo',
  };
  final n = todos.length;
  if (n <= islandBuoysMax) return [for (final t in todos) of(t.status)];
  String slice(int i) {
    final part = [for (final t in todos.sublist(i * n ~/ islandBuoysMax, (i + 1) * n ~/ islandBuoysMax)) of(t.status)];
    if (part.every((s) => s == 'done')) return 'done';
    if (part.contains('active')) return 'active';
    return 'todo';
  }

  return [for (var i = 0; i < islandBuoysMax; i++) slice(i)];
}

/// One-tap answers for [request] (v2 §1.1): one single-choice question with
/// options, not a plan review; else none.
List<({String id, String label})> islandOptionsOf(UserQuestionRequest request) {
  if (request.questions.length != 1) return const [];
  final q = request.questions.single;
  if (q.multiSelect || q.options.isEmpty || q.intent?['kind'] == 'plan-review') return const [];
  return [
    for (final (i, o) in q.options.take(islandOptionsMax).indexed)
      (id: '$i', label: islandLine(o.label, islandOptionLabelMax)),
  ];
}

/// Openers that announce rather than conclude (v2 §1.3): Chinese ones as a
/// prefix, English ones as whole words ("Nowhere" is not "Now"). The same
/// table as dsh-watch-bridge `src/push/liveactivity.ts` `SMALL_TALK`.
final _smallTalk = RegExp(
  r"^(?:好的|好|当然|我来|我将|让我|接下来|首先)|^(?:Okay|OK|Sure|Let me|I'll|I will|Now)\b",
  caseSensitive: false,
);

/// The first statement of a reply (v2 §1.3): code blocks dropped whole,
/// inline code, headings, quotes, list markers and bold / strike marks
/// stripped; cut after 。！？, after an ASCII . ! ? followed by white space
/// (so `v1.2` and `foo.ts` stay whole), and at line breaks; small talk and
/// pieces of ≤ 4 characters skipped (all of them: the first); masked, one
/// line, ≤ [islandSummaryLineMax]. Null for nothing. Kept in step with the
/// bridge's `summaryLineOf` (its cases are in test/unit-la-v2.mjs).
String? islandSummaryLine(String? reply) {
  if (reply == null || reply.isEmpty) return null;
  final plain = reply
      .replaceAll(RegExp(r'```[\s\S]*?(```|$)'), '\n')
      .replaceAllMapped(RegExp(r'`([^`\n]*)`'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+', multiLine: true), '')
      .replaceAll(RegExp(r'\*\*|__|~~'), '');
  final sentences = [
    for (final piece in plain.split(RegExp(r'(?<=[。！？])|(?<=[.!?])(?=\s)|\n+')))
      if (piece.replaceAll(RegExp(r'\s+'), ' ').trim() case final s when s.isNotEmpty) s,
  ];
  if (sentences.isEmpty) return null;
  final chosen = sentences.firstWhere(
    (s) => !_smallTalk.hasMatch(s) && s.runes.length > 4,
    orElse: () => sentences.first,
  );
  final line = islandLine(chosen, islandSummaryLineMax);
  return line.isEmpty ? null : line;
}

/// The ContentState for one conversation's work tree.
///
/// [activity] is `runActivityOf` of the root (null when it isn't running);
/// [approvals] / [questions] are the root's own; [tree] adds its descendants'
/// requests, agents and jobs, [workflow] / [goal] the root's foreground
/// workflow run and goal. [background]: the root is idle while the tree still
/// works. [since] (Host time) is when this run of the tree began: finished
/// agents and failed jobs before it are not shown. [commands] maps an
/// approval's event id to its shell command when known; [askedAt] the device
/// time each request was first seen (else [now]). [finish] turns it into the
/// done / failed state.
IslandContent islandContentOf({
  required HostRef host,
  required String sessionId,
  required String rawTitle,
  required RunActivity? activity,
  required List<ApprovalRequest> approvals,
  required List<UserQuestionRequest> questions,
  required List<TodoItem>? todos,
  required int? tokens,
  required List<OtherRun> others,
  required int othersPending,
  required Duration clockSkew,
  required DateTime now,
  required String lang,
  Duration? lastTurnDuration,
  Map<String, String> commands = const {},
  Map<String, DateTime> askedAt = const {},
  IslandFinish? finish,
  DateTime? turnStart,
  int breachTick = 0,
  WorkTree? tree,
  WorkflowRun? workflow,
  GoalProjection? goal,
  bool background = false,
  DateTime? since,
}) {
  final l = islandL10n(lang);
  final trimmed = rawTitle.trim();
  final title = islandLine(trimmed.isEmpty ? l.commonUntitledChat : trimmed, islandTitleMax);

  final hostStart = activity?.turnStart ?? finish?.start ?? turnStart ?? activity?.since;
  final startedAt = hostStart == null ? now : hostStart.add(clockSkew);
  final last = lastTurnDuration ?? const Duration(minutes: 10);
  final expectMs = (last.inMilliseconds * 1.5).round();
  final expect = Duration(milliseconds: expectMs < 60000 ? 60000 : expectMs);

  final sorted = [...others]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  final listed = [
    for (final o in sorted.take(islandOthersMax))
      IslandOther(
        sessionId: o.sessionId,
        title: islandLine(o.title.trim().isEmpty ? l.commonUntitledChat : o.title, islandTitleMax),
        startedAt: o.startedAt.add(clockSkew),
      ),
  ];

  // ── Requests of the whole tree (§2.3): the root's own as its chat has them,
  // the descendants' from the Host's open requests.
  final allApprovals = [
    ...approvals,
    if (tree != null)
      for (final a in tree.approvals)
        if (a.sessionId != sessionId && !approvals.any((x) => x.eventId == a.eventId)) a,
  ];
  final allQuestions = [
    ...questions,
    if (tree != null)
      for (final q in tree.questions)
        if (q.sessionId != sessionId && !questions.any((x) => x.eventId == q.eventId)) q,
  ];
  final waiting = {for (final a in allApprovals) a.sessionId, for (final q in allQuestions) q.sessionId};
  DateTime asked(String eventId) => askedAt[eventId] ?? now;
  int byAsked(String a, String b) => asked(a).compareTo(asked(b));
  final firstApproval = ([...allApprovals]..sort((a, b) => byAsked(a.eventId, b.eventId))).firstOrNull;
  final firstQuestion = ([...allQuestions]..sort((a, b) => byAsked(a.eventId, b.eventId))).firstOrNull;
  final pendingTotal = allApprovals.length + allQuestions.length;

  // ── v3 keys (§2.2).
  final keys = <String, Object?>{};
  bool recent(DateTime? at) => since != null && at != null && !at.isBefore(since);
  if (tree != null) {
    String state(TreeAgent a) => waiting.contains(a.sessionId)
        ? 'wait'
        : a.running
        ? 'run'
        : a.failed
        ? 'err'
        : 'done';
    const rank = {'wait': 0, 'run': 1, 'err': 2, 'done': 3};
    final shown = [
      for (final a in tree.agents)
        if (a.running || waiting.contains(a.sessionId) || recent(a.updatedAt)) (a: a, s: state(a)),
    ]..sort((x, y) => rank[x.s]!.compareTo(rank[y.s]!));
    if (shown.isNotEmpty) {
      keys['calves'] = [
        for (final c in shown.take(islandCalvesMax)) {'s': c.s, 'l': islandLine(c.a.label, islandCalfLabelMax)},
      ];
      final more = shown.skip(islandCalvesMax).where((c) => c.s != 'done').length;
      if (more > 0) keys['calvesMore'] = more;
    }
    final live = [...tree.liveJobs]..sort((a, b) => (a.startedAt ?? now).compareTo(b.startedAt ?? now));
    final failedJobs = tree.jobs.where((j) => j.status == 'failed' && recent(j.finishedAt)).length;
    if (live.isNotEmpty || failedJobs > 0) {
      keys['bubbles'] = {
        'run': live.length,
        'fail': failedJobs,
        'top': [
          for (final JobInfo j in live.take(islandBubblesMax))
            {
              'l': islandLine(j.progress?.trim().isNotEmpty == true ? j.progress! : j.label, islandBubbleLabelMax),
              'since': unixSeconds((j.startedAt ?? now).add(clockSkew)),
            },
        ],
      };
    }
  }
  if (pendingTotal >= 2) keys['pendingCount'] = pendingTotal;
  // Only the goal the caller says belongs to this run (an old one says nothing).
  final g = goal;
  if (g != null) {
    keys['goal'] = {'round': g.roundsStarted, if (g.goal.maxGoalRounds > 0) 'max': g.goal.maxGoalRounds};
  }

  // ── The lane: workflow > team board > todos > estimate (§2.2).
  double? progress;
  var useTodos = false;
  final team = tree?.team;
  final teamTasks = team?.tasks ?? const [];
  if (workflow != null && workflow.memberCount > 0) {
    keys['wf'] = islandWorkflowKeys(workflow);
    progress = workflow.endedCount / workflow.memberCount;
  } else if (teamTasks.isNotEmpty) {
    final done = teamTasks.where((t) => t.status == 'completed').length;
    keys['team'] = {'done': done, 'total': teamTasks.length};
    progress = done / teamTasks.length;
  } else {
    useTodos = true;
  }
  final list = useTodos ? (todos ?? const <TodoItem>[]) : const <TodoItem>[];
  final done = list.where((t) => t.status == 'completed').length;
  if (useTodos && list.isNotEmpty) progress = done / list.length;
  final buoys = islandBuoys(list);
  final current =
      list.where((t) => t.status == 'in_progress').firstOrNull ??
      list.where((t) => t.status != 'completed').firstOrNull;
  final todoLabel = current == null ? null : islandLine(current.content, islandTodoLabelMax);

  if (finish != null) {
    final endAt = finish.end.add(clockSkew);
    final reason = finish.reason?.trim();
    final String summary;
    if (finish.failed) {
      final base = finish.goalRounds != null ? l.islandGoalStuck : l.islandFailed;
      summary = reason == null || reason.isEmpty
          ? base
          : islandLine(finish.goalRounds != null ? '$base：$reason' : reason, islandTextMax);
    } else {
      final parts = [
        if (finish.goalRounds case final rounds?)
          l.islandGoalDone(rounds)
        else
          l.islandSummaryDone(finish.steps, islandDuration(finish.end.difference(finish.start))),
        if (finish.agents > 0) l.islandTreeAgents(finish.agents),
        if (finish.jobs > 0) l.islandTreeJobs(finish.jobs),
        if (finish.failures > 0) l.islandTreeFailed(finish.failures),
      ];
      summary = islandClip(parts.join(' · '), islandTextMax);
    }
    // A finished tree: nothing runs any more, only the board / goal stays.
    keys
      ..remove('calves')
      ..remove('calvesMore')
      ..remove('bubbles')
      ..remove('pendingCount');
    return IslandContent(
      title: title,
      phase: finish.failed ? IslandPhase.failed : IslandPhase.done,
      startedAt: startedAt,
      expectedEndAt: endAt.isBefore(startedAt) ? startedAt : endAt,
      progress: finish.failed ? progress : 1,
      step: finish.steps < 1 ? 1 : finish.steps,
      toolLabel: '',
      tokens: tokens,
      others: listed,
      othersCount: others.length,
      othersPending: othersPending,
      summary: summary,
      breachTick: breachTick,
      buoys: buoys,
      todoDone: list.isEmpty ? null : done,
      todoTotal: list.isEmpty ? null : list.length,
      todoLabel: finish.failed ? todoLabel : null,
      summaryLine: islandSummaryLine(finish.reply),
      tree: keys,
    );
  }

  IslandPending? pending;
  var phase = background ? IslandPhase.background : IslandPhase.running;
  String? toolName = activity?.toolName;
  if (firstApproval != null) {
    final a = firstApproval;
    final command = commands[a.eventId];
    final at = asked(a.eventId);
    final expires = at.add(islandApprovalWindow);
    phase = IslandPhase.approval;
    toolName ??= a.toolName;
    pending = IslandPending(
      eventId: a.eventId,
      kind: 'approval',
      text: islandLine(command ?? a.describe(lang), islandTextMax),
      risk: islandRiskOf(command),
      askedAt: at,
      approvalExpiresAt: expires,
      expired: !now.isBefore(expires),
      from: _fromOf(tree, a.sessionId, sessionId),
    );
  } else if (firstQuestion != null) {
    final q = firstQuestion;
    final at = asked(q.eventId);
    final expires = at.add(islandApprovalWindow);
    phase = IslandPhase.question;
    pending = IslandPending(
      eventId: q.eventId,
      kind: 'question',
      text: islandLine(q.questions.firstOrNull?.question ?? '', islandTextMax),
      risk: 'unknown',
      askedAt: at,
      approvalExpiresAt: expires,
      expired: !now.isBefore(expires),
      options: islandOptionsOf(q),
      from: _fromOf(tree, q.sessionId, sessionId),
    );
  }

  final toolLabel = phase == IslandPhase.background
      ? l.islandBackground
      : switch (activity?.kind) {
          ActivityKind.tool || ActivityKind.approval when toolName != null => islandToolLabel(toolName, l),
          ActivityKind.writing => l.islandWriting,
          _ when toolName != null && phase == IslandPhase.approval => islandToolLabel(toolName, l),
          _ when activity == null && background => l.islandBackground,
          _ => l.islandThinking,
        };

  return IslandContent(
    title: title,
    phase: phase,
    startedAt: startedAt,
    expectedEndAt: startedAt.add(expect),
    progress: progress,
    step: (activity?.toolsDone ?? 0) + 1,
    toolLabel: islandClip(toolLabel, islandLabelMax),
    tokens: tokens,
    pending: pending,
    others: listed,
    othersCount: others.length,
    othersPending: othersPending,
    breachTick: breachTick,
    buoys: buoys,
    todoDone: list.isEmpty ? null : done,
    todoTotal: list.isEmpty ? null : list.length,
    todoLabel: todoLabel,
    showStop: true,
    stepStartedAt: activity?.kind == ActivityKind.tool ? activity?.since?.add(clockSkew) : null,
    tree: keys,
  );
}

String? _fromOf(WorkTree? tree, String requester, String rootId) {
  if (tree == null || requester == rootId) return null;
  final name = tree.nameOf(requester);
  return name == null ? null : islandLine(name, islandFromMax);
}

/// The `wf` key of [run] (§2.2): ≤ 6 segments in first-seen phase order (more
/// phases merge into 6 even slices), each with its share of ended members.
Map<String, Object?> islandWorkflowKeys(WorkflowRun run) {
  final phases = run.phases;
  final n = phases.length;
  List<List<WorkflowPhase>> groups;
  if (n <= islandSegmentsMax) {
    groups = [
      for (final p in phases) [p],
    ];
  } else {
    groups = [
      for (var i = 0; i < islandSegmentsMax; i++)
        phases.sublist(i * n ~/ islandSegmentsMax, (i + 1) * n ~/ islandSegmentsMax),
    ];
  }
  Map<String, Object?> seg(List<WorkflowPhase> g) {
    final members = g.fold(0, (s, p) => s + p.members);
    final ended = g.fold(0, (s, p) => s + p.ended);
    final failed = g.fold(0, (s, p) => s + p.failed);
    final f = members == 0 ? 0.0 : ended / members;
    final s = failed > 0
        ? 'err'
        : members > 0 && ended >= members
        ? 'done'
        : members > 0
        ? 'active'
        : 'todo';
    return {'s': s, 'f': double.parse(f.toStringAsFixed(3))};
  }

  return {
    'name': islandLine(run.name, islandWorkflowNameMax),
    'seg': [for (final g in groups) seg(g)],
    'label': islandLine(run.current ?? '', islandLabelMax),
  };
}
