// 正在发生: the conversations running or waiting on the person right now, for
// the fixed block at the top of the drawer (and the iPad outline's count).
//
// * Members: the drawer's scope (workspace filter applied, no archived or
//   DS Bot conversations) that run, plus those with a pending approval, plan
//   review or question (keyed by top-level conversation, so a subagent's
//   request counts for its parent).
// * What each row knows: the open conversation has everything in its
//   transcript ([runActivityOf]); up to [HappeningFeedController.maxFollows]
//   other running ones get a very narrow `session/follow` while the drawer
//   shows (only `turn/start`, `tool/call`, `tool/result`, `todo/write`,
//   `turn/end` are counted, no text kept); the rest know only that they run,
//   and since when if this phone saw them start ([sessionRunClockProvider]).
// * A run that ends stays [happeningLingerProvider] (4 s) as done / failed,
//   then leaves; a new run within that time takes it back.
//
// No percentage is ever made up: progress is the todo list's done / total,
// and only when the conversation has one.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../ui/chat/media/media_format.dart' show chatTitleShown;
import '../ui/chat/run_info.dart' show ActivityKind, runActivityOf;
import '../ui/chat/secret_mask.dart' show maskSecrets;
import '../ui/chat/widgets/live_clock.dart' show runClock;
import '../ui/common/ambient_clock.dart';
import '../ui/common/tool_glyph.dart' show ToolGlyphs;
import 'chat_state.dart';
import 'drawer_view_state.dart';
import 'hosts_state.dart';
import 'read_list_identity.dart';
import 'session_attention_state.dart';
import 'session_run_clock.dart';
import 'sessions_state.dart';
import 'workspaces_state.dart' show selectedWorkspaceIdProvider;

// ── Model ────────────────────────────────────────────────────────────────────

/// What a 正在发生 row shows.
enum HappeningPhase {
  running,
  approval,
  plan,
  question,

  /// Ended normally; lingers briefly.
  done,

  /// Ended in an error; lingers briefly.
  failed;

  /// Waits on the person (the amber edge).
  bool get waiting => this == approval || this == plan || this == question;

  /// The run ended and the row is about to leave.
  bool get settled => this == done || this == failed;
}

/// One row of 正在发生.
@immutable
class HappeningEntry {
  const HappeningEntry({
    required this.sessionId,
    required this.title,
    required this.phase,
    this.startedAt,
    this.step,
    this.toolLabel,
    this.pendingText,
    this.pendingEventId,
    this.todoDone = 0,
    this.todoTotal = 0,
    this.settledAt,
    this.tokens,
  });

  final String sessionId;
  final String title;
  final HappeningPhase phase;

  /// The current turn's start on this phone's clock (Host time with the
  /// clock skew applied); null when unknown (then no timer shows).
  final DateTime? startedAt;

  /// 第 N 步: tools finished in this turn + 1 (the open tool's own number
  /// while one runs); null when unknown.
  final int? step;

  /// What it does now, short: 「运行 Bash」「读取」「思考中」「等待回复」; null
  /// when unknown.
  final String? toolLabel;

  /// What is waited on: the command / path / question, secrets masked, one
  /// line, at most [pendingTextMax] characters. Null for a plan review or
  /// when unknown.
  final String? pendingText;
  final String? pendingEventId;

  /// The todo list's progress; 0 / 0 when it has none (draw nothing).
  final int todoDone;
  final int todoTotal;

  /// When a done / failed row ended (it leaves [happeningLingerProvider]
  /// later).
  final DateTime? settledAt;

  /// Tokens of the running turn; the open conversation only.
  final int? tokens;

  static const pendingTextMax = 48;

  bool get hasTodos => todoTotal > 0;

  /// Time this turn has taken at [now] (to [settledAt] once settled).
  Duration? elapsedAt(DateTime now) {
    final start = startedAt;
    if (start == null) return null;
    final end = settledAt ?? now;
    final d = end.difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  HappeningEntry copyWith({HappeningPhase? phase, DateTime? settledAt}) => HappeningEntry(
    sessionId: sessionId,
    title: title,
    phase: phase ?? this.phase,
    startedAt: startedAt,
    step: step,
    toolLabel: toolLabel,
    pendingText: pendingText,
    pendingEventId: pendingEventId,
    todoDone: todoDone,
    todoTotal: todoTotal,
    settledAt: settledAt ?? this.settledAt,
    tokens: tokens,
  );

  @override
  bool operator ==(Object other) =>
      other is HappeningEntry &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.phase == phase &&
      other.startedAt == startedAt &&
      other.step == step &&
      other.toolLabel == toolLabel &&
      other.pendingText == pendingText &&
      other.pendingEventId == pendingEventId &&
      other.todoDone == todoDone &&
      other.todoTotal == todoTotal &&
      other.settledAt == settledAt &&
      other.tokens == tokens;

  @override
  int get hashCode => Object.hash(
    sessionId,
    title,
    phase,
    startedAt,
    step,
    toolLabel,
    pendingText,
    pendingEventId,
    todoDone,
    todoTotal,
    settledAt,
    tokens,
  );

  @override
  String toString() => 'HappeningEntry($sessionId, $phase, step: $step, $toolLabel)';
}

/// What the narrow follow of one other running conversation has seen.
@immutable
class RunDigest {
  const RunDigest({
    this.startedAt,
    this.step,
    this.toolName,
    this.todoDone = 0,
    this.todoTotal = 0,
    this.lastEndKind,
    this.calls = const {},
  });

  /// `turn/start` of the running turn, on this phone's clock.
  final DateTime? startedAt;
  final int? step;

  /// The latest `tool/call`'s tool.
  final String? toolName;
  final int todoDone;
  final int todoTotal;

  /// `turn/end.reason.kind` of the last turn that ended (`completed`,
  /// `error`, `aborted`, …); null while it runs or before any.
  final String? lastEndKind;

  /// Recent calls (newest last, a few): call id → [callTextOf] of it, so an
  /// approval can say what it is about.
  final Map<String, String> calls;

  @override
  bool operator ==(Object other) =>
      other is RunDigest &&
      other.startedAt == startedAt &&
      other.step == step &&
      other.toolName == toolName &&
      other.todoDone == todoDone &&
      other.todoTotal == todoTotal &&
      other.lastEndKind == lastEndKind &&
      mapEquals(other.calls, calls);

  @override
  int get hashCode =>
      Object.hash(startedAt, step, toolName, todoDone, todoTotal, lastEndKind, Object.hashAllUnordered(calls.keys));
}

/// What the open conversation's transcript says (one value per change that
/// matters, so the drawer does not rebuild per streamed token).
@immutable
class CurrentRun {
  const CurrentRun({
    required this.sessionId,
    required this.running,
    this.startedAt,
    this.step,
    this.toolLabel,
    this.todoDone = 0,
    this.todoTotal = 0,
    this.tokens,
    this.lastEndKind,
    this.failed = false,
    this.approvalText,
    this.questionText,
  });

  final String sessionId;
  final bool running;
  final DateTime? startedAt;
  final int? step;
  final String? toolLabel;
  final int todoDone;
  final int todoTotal;
  final int? tokens;
  final String? lastEndKind;

  /// The conversation shows an error now.
  final bool failed;

  /// The open approval's command / path, ready to show.
  final String? approvalText;

  /// The open question, ready to show.
  final String? questionText;

  @override
  bool operator ==(Object other) =>
      other is CurrentRun &&
      other.sessionId == sessionId &&
      other.running == running &&
      other.startedAt == startedAt &&
      other.step == step &&
      other.toolLabel == toolLabel &&
      other.todoDone == todoDone &&
      other.todoTotal == todoTotal &&
      other.tokens == tokens &&
      other.lastEndKind == lastEndKind &&
      other.failed == failed &&
      other.approvalText == approvalText &&
      other.questionText == questionText;

  @override
  int get hashCode => Object.hash(
    sessionId,
    running,
    startedAt,
    step,
    toolLabel,
    todoDone,
    todoTotal,
    tokens,
    lastEndKind,
    failed,
    approvalText,
    questionText,
  );
}

/// The pending request a top-level conversation waits on (the first one of
/// its strongest kind).
@immutable
class HappeningRequest {
  const HappeningRequest({
    required this.eventId,
    required this.kind,
    required this.order,
    this.toolName,
    this.callId,
    this.questionText,
  });

  final String eventId;
  final PendingKind kind;

  /// Arrival order among the pending requests (smaller: earlier).
  final int order;
  final String? toolName;
  final String? callId;
  final String? questionText;

  @override
  bool operator ==(Object other) =>
      other is HappeningRequest &&
      other.eventId == eventId &&
      other.kind == kind &&
      other.order == order &&
      other.toolName == toolName &&
      other.callId == callId &&
      other.questionText == questionText;

  @override
  int get hashCode => Object.hash(eventId, kind, order, toolName, callId, questionText);
}

// ── Text helpers ─────────────────────────────────────────────────────────────

/// One line, secrets masked, at most [max] characters (an ellipsis when cut).
String? happeningSnippet(String? text, {int max = HappeningEntry.pendingTextMax}) {
  if (text == null) return null;
  final flat = maskSecrets(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return null;
  final chars = flat.runes.toList();
  if (chars.length <= max) return flat;
  return '${String.fromCharCodes(chars.take(max - 1)).trimRight()}…';
}

/// What a tool call is about, for an approval line: the command's first line,
/// the file, the page or the query; null for other tools.
String? callTextOf(String name, String arguments) {
  Object? decoded;
  try {
    decoded = jsonDecode(arguments);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final args = decoded;
  final raw = switch (name) {
    'bash' || 'pwsh' => args['command'],
    'write' || 'edit' || 'str_replace_editor' || 'read' => args['file_path'] ?? args['path'],
    'web_fetch' => args['url'],
    'web_search' => args['query'],
    _ => null,
  };
  if (raw is! String || raw.trim().isEmpty) return null;
  return happeningSnippet(raw.trim().split('\n').first);
}

/// The short label of a tool in a row: the tool glyph's verb, with the shell
/// named for commands (「运行 Bash」).
String happeningToolLabel(String name) => switch (name) {
  'bash' => '${ToolGlyphs.labelFor(name)} Bash',
  'pwsh' => '${ToolGlyphs.labelFor(name)} PowerShell',
  _ => ToolGlyphs.labelFor(name),
};

/// mm:ss, or h:mm:ss from an hour.
String happeningClock(Duration d) {
  final s = d.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${two(s ~/ 60)}:${two(s % 60)}';
}

/// The row's subtitle (spec: 正在发生 › 每行内容). [now] times a settled row.
String happeningSubtitle(HappeningEntry e, DateTime now) {
  final l10n = appL10n;
  switch (e.phase) {
    case HappeningPhase.approval:
      return e.pendingText == null ? l10n.smStateNeedsApproval : l10n.smStateNeedsApprovalOf(e.pendingText!);
    case HappeningPhase.question:
      return e.pendingText == null ? l10n.smStateNeedsAnswer : l10n.smStateNeedsAnswerOf(e.pendingText!);
    case HappeningPhase.plan:
      return l10n.smStateNeedsPlanReview;
    case HappeningPhase.failed:
      return l10n.smStateFailed;
    case HappeningPhase.done:
      final elapsed = e.elapsedAt(now);
      final step = e.step;
      if (step == null || elapsed == null) return l10n.smStateDone;
      return l10n.smStateDoneSummary(step, happeningClock(elapsed));
    case HappeningPhase.running:
      final step = e.step;
      if (step == null) return e.toolLabel ?? l10n.smStateRunning;
      return e.toolLabel == null ? l10n.smStateStep(step) : l10n.smStateStepDoing(step, e.toolLabel!);
  }
}

String _titleOf(SessionSummary s) {
  final t = s.title?.trim();
  return t == null || t.isEmpty ? appL10n.commonUntitledChat : chatTitleShown(t);
}

// ── The pure list ────────────────────────────────────────────────────────────

/// How a turn that ended with [kind] lingers: done, failed, or not at all
/// (null: stopped by the person, or forked).
HappeningPhase? settledPhaseOf(String? kind, {bool failed = false}) => switch (kind) {
  'aborted' || 'forked' => null,
  null || 'completed' || 'max-tokens' || 'unknown' => failed ? HappeningPhase.failed : HappeningPhase.done,
  _ => HappeningPhase.failed,
};

/// 正在发生 from its inputs:
///
/// * [sessions]: the drawer's scope; [pending]: top-level id → kind
///   (`pendingInteractionsProvider`); [requests]: the request behind each;
/// * [current] (`currentId`'s transcript), [digests] (narrow follows),
///   [runClock] (start times seen), [settled] (rows that just ended).
///
/// Order: waiting first (approval > plan > question, earlier requests
/// first), then running by the turn's start (longest first; unknown starts
/// last, newest activity first), then the rows that just ended.
List<HappeningEntry> happeningOf({
  required List<SessionSummary> sessions,
  required Map<String, PendingKind> pending,
  Map<String, HappeningRequest> requests = const {},
  String? currentId,
  CurrentRun? current,
  Map<String, DateTime> runClock = const {},
  Map<String, RunDigest> digests = const {},
  Map<String, HappeningEntry> settled = const {},
}) {
  final waiting = <(HappeningEntry, int, int)>[];
  final running = <(HappeningEntry, DateTime)>[];
  final ended = <HappeningEntry>[];
  for (final s in sessions) {
    if (s.isSubagent) continue;
    final id = s.sessionId;
    final mine = current != null && current.sessionId == id && id == currentId ? current : null;
    final kind = pending[id];
    final isRunning = s.running || (mine?.running ?? false);
    if (kind == null && !isRunning) {
      final last = settled[id];
      if (last == null) continue;
      final phase = settledPhaseOf(mine?.lastEndKind ?? digests[id]?.lastEndKind, failed: mine?.failed ?? false);
      if (phase != null) ended.add(last.copyWith(phase: phase));
      continue;
    }
    // A digest of a turn that already ended (its follow closed when the run
    // stopped) says nothing about a new run: its start and step are old.
    final digest = mine == null ? digests[id] : null;
    final live = digest != null && digest.lastEndKind == null ? digest : null;
    final request = kind == null ? null : requests[id];
    String? pendingText;
    if (kind == PendingKind.approval) {
      final call = request?.callId;
      pendingText =
          mine?.approvalText ??
          (call == null ? null : live?.calls[call]) ??
          (request?.toolName == null ? null : happeningToolLabel(request!.toolName!));
    } else if (kind == PendingKind.question) {
      pendingText = mine?.questionText ?? request?.questionText;
    }
    final entry = HappeningEntry(
      sessionId: id,
      title: _titleOf(s),
      phase: switch (kind) {
        PendingKind.approval => HappeningPhase.approval,
        PendingKind.plan => HappeningPhase.plan,
        PendingKind.question => HappeningPhase.question,
        null => HappeningPhase.running,
      },
      startedAt: mine?.startedAt ?? live?.startedAt ?? runClock[id],
      step: mine?.step ?? live?.step,
      toolLabel: mine?.toolLabel ?? (live?.toolName == null ? null : happeningToolLabel(live!.toolName!)),
      pendingText: pendingText,
      pendingEventId: request?.eventId,
      todoDone: mine?.todoDone ?? live?.todoDone ?? 0,
      todoTotal: mine?.todoTotal ?? live?.todoTotal ?? 0,
      tokens: mine?.tokens,
    );
    if (kind != null) {
      waiting.add((entry, kind.index, request?.order ?? 1 << 30));
    } else {
      running.add((entry, s.updatedAt));
    }
  }
  waiting.sort((a, b) {
    final byKind = a.$2.compareTo(b.$2);
    if (byKind != 0) return byKind;
    final byOrder = a.$3.compareTo(b.$3);
    return byOrder != 0 ? byOrder : a.$1.sessionId.compareTo(b.$1.sessionId);
  });
  running.sort((a, b) {
    final sa = a.$1.startedAt, sb = b.$1.startedAt;
    if (sa != null && sb != null) {
      final c = sa.compareTo(sb);
      if (c != 0) return c;
    } else if (sa != null) {
      return -1;
    } else if (sb != null) {
      return 1;
    } else {
      final c = b.$2.compareTo(a.$2);
      if (c != 0) return c;
    }
    return a.$1.sessionId.compareTo(b.$1.sessionId);
  });
  ended.sort((a, b) {
    final c = (a.settledAt ?? DateTime(0)).compareTo(b.settledAt ?? DateTime(0));
    return c != 0 ? c : a.sessionId.compareTo(b.sessionId);
  });
  return [for (final w in waiting) w.$1, for (final r in running) r.$1, ...ended];
}

/// [CurrentRun] of [sessionId]'s transcript.
CurrentRun currentRunOf(String sessionId, ChatState s) {
  final activity = runActivityOf(s);
  final trace = s.runningTurn;
  final hostStart = activity?.turnStart ?? trace?.start;
  final usage = trace?.usage;
  String? approvalText;
  final approval = s.openApproval;
  if (approval != null) {
    final callId = approval.callId;
    final call = callId == null ? null : s.items.whereType<ToolChatItem>().where((t) => t.callId == callId).lastOrNull;
    approvalText =
        (call == null ? null : callTextOf(call.name, call.arguments)) ?? happeningToolLabel(approval.toolName);
  }
  final question = s.questions.firstOrNull?.questions.firstOrNull?.question;
  final String? label = switch (activity?.kind) {
    null => null,
    ActivityKind.tool => activity!.toolName == null ? activity.title : happeningToolLabel(activity.toolName!),
    ActivityKind.thinking || ActivityKind.writing => appL10n.smStateThinking,
    ActivityKind.waiting => appL10n.smStateWaitingReply,
    _ => activity!.title,
  };
  final lastTurn = s.turns.lastOrNull;
  return CurrentRun(
    sessionId: sessionId,
    running: s.running,
    startedAt: hostStart?.add(s.clockSkew),
    step: activity == null ? null : activity.toolsDone + 1,
    toolLabel: label,
    todoDone: activity?.todoDone ?? 0,
    todoTotal: activity?.todoTotal ?? 0,
    tokens: usage == null ? null : usage.uncachedInput + usage.cacheRead + usage.cacheWrite + usage.output,
    lastEndKind: s.running || lastTurn == null || lastTurn.running ? null : lastTurn.endReason?.kind,
    failed: !s.running && s.error != null,
    approvalText: approvalText,
    questionText: happeningSnippet(question),
  );
}

// ── Providers ────────────────────────────────────────────────────────────────

/// Whether 正在发生 is on screen (the drawer or the iPad sidebar sets it
/// while it shows). The narrow follows run only while it is true.
class HappeningVisibleController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool visible) {
    if (state != visible) state = visible;
  }
}

final happeningVisibleProvider = NotifierProvider<HappeningVisibleController, bool>(HappeningVisibleController.new);

/// How long a run that ended stays in 正在发生 (tests shorten it).
final happeningLingerProvider = Provider<Duration>((ref) => const Duration(seconds: 4));

/// The open conversation's [CurrentRun]; null with none open.
final happeningCurrentRunProvider = Provider<CurrentRun?>((ref) {
  final id = ref.watch(currentSessionProvider);
  if (id == null) return null;
  final chat = chatProvider(id);
  // Only the conversation the chat screen already holds: 正在发生 never
  // starts one itself (its controller follows the session over the mux, and
  // would stay alive for the drawer alone). The chat screen takes up a newly
  // chosen conversation in the same frame, so look once more after it.
  if (!ref.exists(chat)) {
    final owner = ref.read(currentSessionProvider.notifier);
    if (_currentRunLookedAgain[owner] != id) {
      _currentRunLookedAgain[owner] = id;
      scheduleMicrotask(() {
        if (ref.mounted) ref.invalidateSelf();
      });
    }
    return null;
  }
  return ref.watch(chat.select((s) => currentRunOf(id, s)));
});

/// Per container (its current-session controller): the conversation
/// [happeningCurrentRunProvider] already looked at twice.
final _currentRunLookedAgain = Expando<String>('happening current run');

/// The request behind each [pendingInteractionsProvider] entry.
final happeningRequestsProvider = Provider<Map<String, HappeningRequest>>((ref) {
  final pending = ref.watch(pendingInteractionsProvider);
  if (pending.isEmpty) return const {};
  final source = ref.watch(pendingSourceProvider);
  if (source == null) return const {};
  final all = {for (final s in ref.read(sessionsProvider.notifier).allSessions) s.sessionId: s};
  String rootOf(String sessionId) {
    var id = sessionId;
    for (var depth = 0; depth < 8; depth++) {
      final info = all[id];
      final parent = info?.parentSessionId;
      if (info == null || !info.isSubagent || parent == null || parent.isEmpty) return id;
      id = parent;
    }
    return id;
  }

  final out = <String, HappeningRequest>{};
  var order = 0;
  for (final event in source.pending()) {
    order++;
    final HappeningRequest request;
    final String sessionId;
    switch (event) {
      case ApprovalRequestedEvent(request: final r):
        sessionId = r.sessionId;
        request = HappeningRequest(
          eventId: r.eventId,
          kind: PendingKind.approval,
          order: order,
          toolName: r.toolName,
          callId: r.callId,
        );
      case UserQuestionRequestedEvent(request: final r):
        sessionId = r.sessionId;
        final plan = r.questions.any((q) => q.intent?['kind'] == 'plan-review');
        request = HappeningRequest(
          eventId: r.eventId,
          kind: plan ? PendingKind.plan : PendingKind.question,
          order: order,
          questionText: plan ? null : happeningSnippet(r.questions.firstOrNull?.question),
        );
      default:
        continue;
    }
    final root = rootOf(sessionId);
    if (pending[root] == request.kind) out.putIfAbsent(root, () => request);
  }
  return out;
});

List<HappeningEntry> _compute(Ref ref, Map<String, HappeningEntry> settled) {
  final scope = ref.watch(drawerScopeProvider);
  if (scope == null) return const [];
  // A cached (read-only) list has no live marks, like the drawer's filters.
  final live = !scope.readOnly;
  return happeningOf(
    sessions: scope.sessions,
    pending: live ? ref.watch(pendingInteractionsProvider) : const {},
    requests: live ? ref.watch(happeningRequestsProvider) : const {},
    currentId: ref.watch(currentSessionProvider),
    current: live ? ref.watch(happeningCurrentRunProvider) : null,
    runClock: live ? ref.watch(sessionRunClockProvider) : const {},
    digests: live ? ref.watch(happeningFeedProvider) : const {},
    settled: settled,
  );
}

/// Running and waiting rows, without the ones that just ended.
final happeningLiveProvider = Provider<List<HappeningEntry>>((ref) => _compute(ref, const {}));

/// Rows that just ended, by conversation id, each kept
/// [happeningLingerProvider] after it ended (or until it runs or waits
/// again). Kept by [happeningProvider] itself as it computes, never written
/// from a listener: the list is often recomputed by a widget's build reading
/// it, and a provider must not be modified while the tree builds. Expiry
/// comes from a timer, outside any build.
class HappeningLinger {
  final Map<String, HappeningEntry> _rows = {};
  final Map<String, Timer> _timers = {};
  List<HappeningEntry>? _lastLive;

  /// Called when a row's linger ends (the list recomputes without it).
  VoidCallback? onExpired;

  /// The rows lingering now.
  Map<String, HappeningEntry> get rows => Map.unmodifiable(_rows);

  /// Follows the live rows from the last call to [live]: one that left while
  /// still listed in [inScope] lingers, settled at [now]; one back in the
  /// live list stops lingering.
  void update(List<HappeningEntry> live, Set<String> inScope, DateTime now, Duration linger) {
    final previous = _lastLive;
    if (identical(previous, live)) return;
    _lastLive = live;
    final ids = {for (final e in live) e.sessionId};
    for (final id in ids) {
      if (_rows.remove(id) != null) _timers.remove(id)?.cancel();
    }
    for (final e in previous ?? const <HappeningEntry>[]) {
      final id = e.sessionId;
      // Gone from scope (archived, deleted, another workspace): no linger.
      if (ids.contains(id) || !inScope.contains(id)) continue;
      _rows[id] = e.copyWith(settledAt: now);
      _timers.remove(id)?.cancel();
      _timers[id] = Timer(linger, () {
        _timers.remove(id);
        if (_rows.remove(id) != null) onExpired?.call();
      });
    }
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _rows.clear();
    onExpired = null;
  }
}

/// The lingering rows of one Host and workspace: another one starts afresh.
final happeningLingerBookProvider = Provider<HappeningLinger>((ref) {
  ref.watch(activeHostProvider);
  ref.watch(selectedWorkspaceIdProvider);
  final book = HappeningLinger();
  ref.onDispose(book.dispose);
  return book;
});

/// 正在发生, in display order (see [happeningOf]); empty while the list loads.
final happeningProvider = Provider<List<HappeningEntry>>((ref) {
  final book = ref.watch(happeningLingerBookProvider);
  final live = ref.watch(happeningLiveProvider);
  book.update(
    live,
    {for (final s in ref.watch(drawerScopeProvider)?.sessions ?? const <SessionSummary>[]) s.sessionId},
    ref.read(drawerClockProvider)(),
    ref.watch(happeningLingerProvider),
  );
  book.onExpired = () {
    if (ref.mounted) ref.invalidateSelf();
  };
  return _compute(ref, book.rows);
});

// ── The rows' timers ─────────────────────────────────────────────────────────

/// Whole seconds of the wall clock, stepped by the shared [AmbientClock]
/// (no timer of its own): a row's mm:ss listens to it and rebuilds once a
/// second, in the same frame as the tool arcs and breathing dots. It runs
/// only while something listens; listen only while the row can be seen
/// (TickerMode on) and animations are not off — with them off, read
/// [now] when building instead.
class HappeningSeconds extends ValueNotifier<int> {
  HappeningSeconds({DateTime Function()? clock}) : _clock = clock ?? DateTime.now, super(0);

  final DateTime Function() _clock;

  /// The wall clock now (what a timer subtracts the start from).
  DateTime get now => _clock();

  int _read() => _clock().millisecondsSinceEpoch ~/ 1000;

  void _step() {
    final next = _read();
    if (next != value) value = next;
  }

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    // Caught up before it listens: joining is not a change.
    if (first) value = _read();
    super.addListener(listener);
    if (first) AmbientClock.instance.addListener(_step);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) AmbientClock.instance.removeListener(_step);
  }
}

/// The rows' seconds on the wall clock the chat's live timers read
/// ([runClock]; tests freeze it), so a row and its conversation's own timer
/// agree. Not disposed with the provider: it holds nothing once nobody
/// listens.
final happeningSecondsProvider = Provider<HappeningSeconds>((ref) => HappeningSeconds(clock: () => runClock()));

// ── Narrow follows of other running conversations ───────────────────────────

/// The `session/follow` request of a narrow follow: the newest message only,
/// no assistant stream. `turnWindow` keys are `TurnWindow.toJson`'s
/// (`minMessages`, `minTurns`).
Map<String, Object?> happeningFollowRequest(DshClient client, String sessionId) => {
  'address': client.sessionAddressOf(sessionId),
  'maxMessages': 1,
  'turnWindow': const TurnWindow(1, 1).toJson(),
};

/// One open narrow follow: its frames and how to stop it.
typedef HappeningFollow = ({Stream<Object?> items, void Function() cancel});

/// Whether [client]'s mux is up: follows ride an open link and never start
/// one (tests that fake the opener say yes).
final happeningMuxReadyProvider = Provider<bool Function(DshClient client)>(
  (ref) =>
      (client) => client.mux.state == DshConnectionState.connected,
);

/// Opens a narrow follow of a conversation (tests swap in a fake mux).
typedef HappeningFollowOpener = HappeningFollow Function(DshClient client, String sessionId);

final happeningFollowOpenerProvider = Provider<HappeningFollowOpener>(
  (ref) => (client, sessionId) {
    final stream = client.mux.open('session/follow', {'request': happeningFollowRequest(client, sessionId)});
    return (items: stream.items, cancel: () => unawaited(stream.cancel()));
  },
);

/// The running counts of one followed conversation.
class _Fold {
  DateTime? hostStart;

  /// Tools finished this turn; null when the turn's start was not seen (the
  /// window began mid-turn), then the engine's step number stands in.
  int? toolsDone;
  int? engineStep;
  String? toolName;
  int todoDone = 0;
  int todoTotal = 0;
  String? lastEndKind;
  final LinkedHashMap<String, String> calls = LinkedHashMap();

  static const maxCalls = 4;

  void startTurn(DateTime at) {
    hostStart = at;
    toolsDone = 0;
    engineStep = null;
    toolName = null;
    lastEndKind = null;
    // The todos projection is cleared when the next turn starts.
    todoDone = todoTotal = 0;
  }

  void todos(List<TodoItem>? items) {
    final list = items ?? const <TodoItem>[];
    todoTotal = list.length;
    todoDone = list.where((t) => t.status == 'completed').length;
  }

  void apply(SessionLogEvent event) {
    switch (event) {
      case TurnStartedEvent(:final time):
        startTurn(time);
      case StepStartedEvent(:final step):
        engineStep = step;
      case ToolCallEvent(:final step, :final callId, :final name, :final arguments):
        engineStep = step;
        toolName = name;
        final text = callTextOf(name, arguments);
        if (text != null && callId.isNotEmpty) {
          calls.remove(callId);
          calls[callId] = text;
          while (calls.length > maxCalls) {
            calls.remove(calls.keys.first);
          }
        }
      case ToolResultEvent(:final step):
        engineStep = step;
        if (toolsDone != null) toolsDone = toolsDone! + 1;
      case TodoWriteEvent(todos: final items):
        todos(items);
      case TurnEndedEvent(:final reason):
        lastEndKind = reason.kind;
      default:
        break;
    }
  }

  void snapshot(SessionSnapshotEvent snap) {
    // The newest turn start in the window, if it is still open.
    var start = -1;
    for (var i = snap.events.length - 1; i >= 0; i--) {
      if (snap.events[i] is TurnStartedEvent) {
        start = i;
        break;
      }
    }
    hostStart = null;
    toolsDone = null;
    engineStep = null;
    toolName = null;
    lastEndKind = null;
    if (start >= 0) startTurn(snap.events[start].time);
    for (final event in snap.events.skip(start < 0 ? 0 : start + 1)) {
      apply(event);
    }
    if (lastEndKind != null) {
      hostStart = null;
      toolsDone = null;
    }
    todos(snap.projections.todos);
  }

  RunDigest digest(Duration skew) => RunDigest(
    startedAt: hostStart?.add(skew),
    step: toolsDone == null ? engineStep : toolsDone! + 1,
    toolName: toolName,
    todoDone: todoDone,
    todoTotal: todoTotal,
    lastEndKind: lastEndKind,
    calls: Map.unmodifiable(calls),
  );
}

class _Follow {
  _Follow(this.stream);

  final HappeningFollow stream;
  StreamSubscription<Object?>? sub;

  void close() {
    unawaited(sub?.cancel());
    stream.cancel();
  }
}

/// Narrow follows of the other running conversations in scope while
/// 正在发生 shows: at most [maxFollows] (newest activity first), each closed
/// when its conversation stops running or drops out of the first
/// [maxFollows], when 正在发生 has been hidden [hideGrace], and on a new
/// connection. A follow that fails or ends is not reopened for [cooldown].
/// Read-only: never activates a conversation.
class HappeningFeedController extends Notifier<Map<String, RunDigest>> {
  static const maxFollows = 3;
  static const hideGrace = Duration(seconds: 5);
  static const cooldown = Duration(seconds: 30);

  final Map<String, _Follow> _follows = {};
  final Map<String, _Fold> _folds = {};
  final Map<String, DateTime> _retryAfter = {};
  Timer? _hideTimer;
  DshClient? _client;
  bool _sameClock = false;
  Duration? _skew;

  /// Conversations followed now (tests, diagnostics).
  Set<String> get followed => Set.unmodifiable(_follows.keys);

  @override
  Map<String, RunDigest> build() {
    final conn = ref.watch(readListLiveConnectionProvider);
    _closeAll();
    _folds.clear();
    _retryAfter.clear();
    _skew = null;
    _client = conn?.client;
    _sameClock = conn?.isLocal ?? false;
    ref.onDispose(_closeAll);
    if (conn == null) return const {};
    // The link coming up (or going): follow then, never open it ourselves.
    final states = conn.client.mux.states.listen((_) {
      if (ref.mounted) _sync();
    }, onError: (Object _) {});
    ref.onDispose(() => unawaited(states.cancel()));
    ref.listen(happeningVisibleProvider, (_, _) => _sync());
    ref.listen(drawerScopeProvider, (_, _) => _sync());
    ref.listen(currentSessionProvider, (_, _) => _sync());
    // Not during build: opening may update the state.
    scheduleMicrotask(() {
      if (ref.mounted) _sync();
    });
    return const {};
  }

  void _closeAll() {
    _hideTimer?.cancel();
    _hideTimer = null;
    for (final f in _follows.values) {
      f.close();
    }
    _follows.clear();
  }

  List<String> _wanted() {
    final scope = ref.read(drawerScopeProvider);
    if (scope == null || scope.readOnly) return const [];
    final current = ref.read(currentSessionProvider);
    final running = [
      for (final s in scope.sessions)
        if (s.running && !s.isSubagent && s.sessionId != current) s,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [for (final s in running.take(maxFollows)) s.sessionId];
  }

  void _sync() {
    if (!ref.mounted) return;
    final client = _client;
    if (client == null) return;
    if (!ref.read(happeningVisibleProvider)) {
      if (_follows.isNotEmpty && _hideTimer == null) {
        _hideTimer = Timer(hideGrace, () {
          _hideTimer = null;
          if (ref.mounted && !ref.read(happeningVisibleProvider)) _closeAll();
        });
      }
      return;
    }
    _hideTimer?.cancel();
    _hideTimer = null;
    final wanted = ref.read(happeningMuxReadyProvider)(client) ? _wanted() : const <String>[];
    for (final id in [..._follows.keys]) {
      if (!wanted.contains(id)) _follows.remove(id)?.close();
    }
    final now = ref.read(drawerClockProvider)();
    for (final id in wanted) {
      if (_follows.containsKey(id)) continue;
      final after = _retryAfter[id];
      if (after != null && now.isBefore(after)) continue;
      _open(client, id);
    }
    // Forget conversations that left the scope.
    final inScope = {for (final s in ref.read(drawerScopeProvider)?.sessions ?? const <SessionSummary>[]) s.sessionId};
    final gone = [
      for (final id in state.keys)
        if (!inScope.contains(id)) id,
    ];
    if (gone.isNotEmpty) {
      _folds.removeWhere((id, _) => gone.contains(id));
      state = {...state}..removeWhere((id, _) => gone.contains(id));
    }
  }

  void _open(DshClient client, String id) {
    final HappeningFollow stream;
    try {
      stream = ref.read(happeningFollowOpenerProvider)(client, id);
    } catch (_) {
      _retryAfter[id] = ref.read(drawerClockProvider)().add(cooldown);
      return;
    }
    final follow = _Follow(stream);
    _follows[id] = follow;
    follow.sub = stream.items.listen(
      (item) {
        if (ref.mounted && identical(_follows[id], follow)) _onItem(id, item);
      },
      onError: (Object error) => _ended(id, follow, retry: error is! DshCarrierLostException),
      onDone: () => _ended(id, follow, retry: true),
    );
  }

  void _ended(String id, _Follow follow, {required bool retry}) {
    if (!ref.mounted || !identical(_follows[id], follow)) return;
    _follows.remove(id);
    follow.close();
    if (retry) _retryAfter[id] = ref.read(drawerClockProvider)().add(cooldown);
  }

  void _onItem(String id, Object? item) {
    final event = parseFollowFrame(id, item);
    final fold = _folds.putIfAbsent(id, _Fold.new);
    switch (event) {
      case SessionSnapshotEvent():
        fold.snapshot(event);
      case SessionLogEvent():
        _trackClock(event);
        fold.apply(event);
      default:
        return;
    }
    final next = fold.digest(_skew ?? Duration.zero);
    if (state[id] != next) state = {...state, id: next};
  }

  /// Like the chat's estimate: arrival minus Host time of live events, the
  /// smallest sample wins; over an hour is a replay and ignored.
  void _trackClock(SessionLogEvent event) {
    if (_sameClock) return;
    final sample = ref.read(drawerClockProvider)().difference(event.time);
    if (sample.abs() > const Duration(hours: 1)) return;
    final skew = _skew;
    if (skew == null || sample < skew) _skew = sample;
  }
}

final happeningFeedProvider = NotifierProvider<HappeningFeedController, Map<String, RunDigest>>(
  HappeningFeedController.new,
);
