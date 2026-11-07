// A conversation's work tree (plan/design/notify-v3-contract.md §1): the root
// conversation, its descendant conversations (subagents, teammates, workflow
// members), the background jobs of the root and of descendants that run, the
// root's foreground workflow run, its goal, and every request waiting on the
// person anywhere in it. The「鲸游」Live Activity follows the tree, not one
// turn of the root: it is over once the whole tree has been quiet for the
// settle window (the bridge runs the same rule).

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/connection_state.dart' show activeConnectionProvider;
import '../state/session_attention_state.dart' show pendingInteractionsProvider, pendingSourceProvider;
import '../state/sessions_state.dart' show sessionsProvider;

/// A tree quiet this long is settled (contract §1.2; bridge
/// `cfg.tuning.settleWindowMs`, the same default).
final islandSettleWindowProvider = Provider<Duration>((ref) => const Duration(seconds: 20));

/// The `user/message` sources that wake the root without a person (contract
/// §1.3). `team-message` is the older name of `agent-message`.
const islandWakeSources = {'tool-jobs', 'schedule', 'goal', 'subagent-settled', 'agent-message', 'team-message'};

// ── Workflow ────────────────────────────────────────────────────────────────

/// One phase of a foreground workflow run, in first-seen order.
class WorkflowPhase {
  WorkflowPhase(this.title);
  final String title;
  int members = 0;
  int ended = 0;
  int failed = 0;
}

/// The root's latest foreground workflow run (`tool-workflow/*` events).
class WorkflowRun {
  WorkflowRun(this.runId, this.name);
  final String runId;
  final String name;
  final phases = <WorkflowPhase>[];

  /// Member session id → its label (agent-start).
  final members = <String, String>{};
  bool ended = false;
  String? stopReason;

  /// The phase a member last started in.
  String? current;

  int get memberCount => phases.fold(0, (n, p) => n + p.members);
  int get endedCount => phases.fold(0, (n, p) => n + p.ended);
  int get failedCount => phases.fold(0, (n, p) => n + p.failed);
}

/// What the root's durable log says beyond [ChatState]: the latest workflow
/// run of the last turn, and what started that turn.
class RootLogFacts {
  const RootLogFacts({this.workflow, this.turnSource});

  final WorkflowRun? workflow;

  /// `data.source.kind` of the last turn's first prompt that isn't context
  /// (`user` or one of [islandWakeSources]); null while not seen yet.
  final String? turnSource;

  /// The last turn was started by something other than a person.
  bool get wake => turnSource != null && islandWakeSources.contains(turnSource);
}

/// Folds [events] (in order) into [RootLogFacts]. Only the last turn counts.
RootLogFacts foldRootLog(Iterable<SessionLogEvent> events) {
  WorkflowRun? run;
  String? source;
  final runs = <String, WorkflowRun>{};
  // Per run: member seq (and child id) → the phase it started in.
  final phaseOf = <String, Map<String, String>>{};
  WorkflowPhase? phaseNamed(WorkflowRun r, String title) => r.phases.where((p) => p.title == title).firstOrNull;
  for (final e in events) {
    final d = e.data;
    switch (e.type) {
      case 'turn/start':
        source = null;
        run = null;
        runs.clear();
        phaseOf.clear();
      case 'user/message' when source == null:
        final kind = _str(_map(d['source'])?['kind']) ?? 'user';
        if (kind == 'user' || islandWakeSources.contains(kind)) source = kind;
      case 'tool-workflow/run-start':
        final id = _str(d['runId']);
        if (id == null) break;
        run = runs[id] = WorkflowRun(id, _str(d['name']) ?? '');
      case 'tool-workflow/agent-start':
        final id = _str(d['runId']);
        final r = runs[id];
        if (id == null || r == null) break;
        final title = _str(d['phase']) ?? '';
        final phase = phaseNamed(r, title) ?? WorkflowPhase(title);
        if (!r.phases.contains(phase)) r.phases.add(phase);
        phase.members++;
        r.current = title;
        final keys = phaseOf[id] ??= {};
        if (d['seq'] case final seq?) keys['s$seq'] = title;
        final child = _str(d['childId']);
        if (child != null) {
          keys['c$child'] = title;
          r.members[child] = _str(d['label']) ?? '';
        }
      case 'tool-workflow/agent-end':
        final id = _str(d['runId']);
        final r = runs[id];
        if (id == null || r == null) break;
        final keys = phaseOf[id] ?? const {};
        final title =
            _str(d['phase']) ??
            (d['seq'] == null ? null : keys['s${d['seq']}']) ??
            (_str(d['childId']) == null ? null : keys['c${d['childId']}']) ??
            r.current ??
            '';
        final phase = phaseNamed(r, title);
        if (phase == null) break;
        phase.ended++;
        if (_str(d['outcome']) == 'failed') phase.failed++;
      case 'tool-workflow/run-end':
        final r = runs[_str(d['runId'])];
        if (r == null) break;
        r.ended = true;
        r.stopReason = _str(d['stopReason']);
    }
  }
  return RootLogFacts(workflow: run, turnSource: source);
}

Map<String, Object?>? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

// ── Tree ────────────────────────────────────────────────────────────────────

/// One descendant conversation.
class TreeAgent {
  const TreeAgent({
    required this.sessionId,
    required this.label,
    required this.running,
    this.failed = false,
    this.updatedAt,
  });
  final String sessionId;

  /// Catalog label, teammate name, workflow member label or title.
  final String label;
  final bool running;

  /// Its latest turn ended otherwise than completed.
  final bool failed;
  final DateTime? updatedAt;
}

/// Everything of a tree but the root's own turn (that comes from its chat).
class WorkTree {
  const WorkTree({
    required this.rootId,
    this.agents = const [],
    this.jobs = const [],
    this.approvals = const [],
    this.questions = const [],
    this.team,
    this.goal,
  });

  const WorkTree.empty(this.rootId)
    : agents = const [],
      jobs = const [],
      approvals = const [],
      questions = const [],
      team = null,
      goal = null;

  final String rootId;
  final List<TreeAgent> agents;

  /// The root's and running descendants' jobs, one per id.
  final List<JobInfo> jobs;

  /// Waiting on the person anywhere in the tree (the root's own included).
  final List<ApprovalRequest> approvals;
  final List<UserQuestionRequest> questions;
  final TeamSnapshot? team;

  /// The root's goal as the conversation list knows it.
  final GoalProjection? goal;

  Iterable<TreeAgent> get runningAgents => agents.where((a) => a.running);
  Iterable<JobInfo> get liveJobs => jobs.where((j) => j.live);

  /// Something besides the root's own turn keeps the tree busy (§1.1). A
  /// teammate standing by isn't running, so it doesn't.
  bool busyWith({GoalProjection? goal}) =>
      runningAgents.isNotEmpty ||
      liveJobs.isNotEmpty ||
      approvals.isNotEmpty ||
      questions.isNotEmpty ||
      goalContinues(goal ?? this.goal);

  /// Short name of a request's conversation ([rootId]'s own: null).
  String? nameOf(String sessionId) {
    if (sessionId == rootId) return null;
    for (final a in agents) {
      if (a.sessionId == sessionId) return a.label;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is WorkTree &&
      other.rootId == rootId &&
      _same(
        other.agents,
        agents,
        (a, b) => a.sessionId == b.sessionId && a.running == b.running && a.failed == b.failed && a.label == b.label,
      ) &&
      _same(other.jobs, jobs, (a, b) => a.id == b.id && a.status == b.status && a.progress == b.progress) &&
      _same(other.approvals, approvals, (a, b) => a.eventId == b.eventId) &&
      _same(other.questions, questions, (a, b) => a.eventId == b.eventId) &&
      other.team?.tasks.length == team?.tasks.length &&
      other.team?.tasks.where((t) => t.status == 'completed').length ==
          team?.tasks.where((t) => t.status == 'completed').length &&
      other.goal == goal;

  @override
  int get hashCode => Object.hash(rootId, agents.length, jobs.length, approvals.length, questions.length);
}

bool _same<T>(List<T> a, List<T> b, bool Function(T, T) eq) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!eq(a[i], b[i])) return false;
  }
  return true;
}

/// An active goal that will run another round (`maxGoalRounds` 0: no cap).
bool goalContinues(GoalProjection? g) =>
    g != null &&
    g.goal.phase == GoalPhase.active &&
    (g.goal.maxGoalRounds <= 0 || g.roundsStarted < g.goal.maxGoalRounds);

/// The tree of [rootId] out of the conversation list, the jobs seen per
/// conversation and the open requests (pure; the provider feeds it).
WorkTree buildWorkTree({
  required String rootId,
  required List<SessionSummary> sessions,
  Map<String, List<JobInfo>> jobs = const {},
  List<HostEvent> pending = const [],
  Map<String, String> workflowLabels = const {},
}) {
  final byId = {for (final s in sessions) s.sessionId: s};
  String rootOf(String id) {
    for (var depth = 0; depth < 8; depth++) {
      final info = byId[id];
      final parent = info?.parentSessionId;
      if (info == null || !info.isSubagent || parent == null || parent.isEmpty) return id;
      id = parent;
    }
    return id;
  }

  final root = byId[rootId];
  final catalog = {for (final e in root?.projections.subagentCatalog ?? const <SubagentCatalogEntry>[]) e.id: e.label};
  final team = root?.projections.agentTeam;
  final teamNames = {for (final m in team?.members ?? const <TeamMember>[]) m.id: m.name};
  final agents = <TreeAgent>[
    for (final s in sessions)
      if (s.sessionId != rootId && s.isSubagent && rootOf(s.sessionId) == rootId)
        TreeAgent(
          sessionId: s.sessionId,
          label:
              catalog[s.sessionId] ??
              teamNames[s.sessionId] ??
              _str(workflowLabels[s.sessionId]) ??
              (s.title?.trim().isNotEmpty == true ? s.title!.trim() : s.sessionId),
          running: s.running,
          failed: !s.running && s.projections.subagentTiming?.lastTurnCompleted == false,
          updatedAt: s.updatedAt,
        ),
  ];
  final seen = <String>{};
  final allJobs = <JobInfo>[
    for (final id in [rootId, for (final a in agents) a.sessionId])
      for (final j in jobs[id] ?? const <JobInfo>[])
        if (seen.add(j.id)) j,
  ];
  final approvals = <ApprovalRequest>[];
  final questions = <UserQuestionRequest>[];
  for (final e in pending) {
    switch (e) {
      case ApprovalRequestedEvent(:final request) when rootOf(request.sessionId) == rootId:
        approvals.add(request);
      case UserQuestionRequestedEvent(:final request) when rootOf(request.sessionId) == rootId:
        questions.add(request);
      default:
    }
  }
  return WorkTree(
    rootId: rootId,
    agents: agents,
    jobs: allJobs,
    approvals: approvals,
    questions: questions,
    team: team,
    goal: GoalProjection.fromJson(root?.projections.values['goal']),
  );
}

// ── Providers ───────────────────────────────────────────────────────────────

/// The active host's conversations (tests override it).
final workTreeSessionsProvider = Provider<List<SessionSummary>>((ref) {
  ref.watch(sessionsProvider);
  return ref.read(sessionsProvider.notifier).allSessions;
});

/// The active host's open requests (tests override it).
final workTreePendingProvider = Provider<List<HostEvent>>((ref) {
  ref.watch(pendingInteractionsProvider);
  return ref.watch(pendingSourceProvider)?.pending() ?? const [];
});

/// One conversation's background jobs (`job/list`, the whole set each frame).
final workTreeJobsProvider = StreamProvider.autoDispose.family<List<JobInfo>, String>((ref, sessionId) {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return Stream.value(const []);
  return client.watchJobs(sessionId);
});

/// The work tree of [rootId]. Job lists are followed for the root and the
/// descendants that run (only while something, the Activity, watches it).
final workTreeProvider = Provider.autoDispose.family<WorkTree, String>((ref, rootId) {
  final sessions = ref.watch(workTreeSessionsProvider);
  final pending = ref.watch(workTreePendingProvider);
  final shape = buildWorkTree(rootId: rootId, sessions: sessions, pending: pending);
  final jobs = <String, List<JobInfo>>{
    for (final id in [rootId, for (final a in shape.runningAgents) a.sessionId])
      id: ref.watch(workTreeJobsProvider(id)).value ?? const [],
  };
  return buildWorkTree(rootId: rootId, sessions: sessions, pending: pending, jobs: jobs);
});
