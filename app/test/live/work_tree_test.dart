// The work tree (plan/design/notify-v3-contract.md §1): who belongs to it,
// what keeps it busy, what the root's log says (workflow phases, a woken
// turn), and how it shows on the island (calves, bubbles, segments, board,
// goal, tree-wide pending, the summary).

import 'dart:convert';

import 'package:dsh_app/live/live_activity_content.dart';
import 'package:dsh_app/live/work_tree.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 11, 7, 8);
final _now = _t0.add(const Duration(minutes: 3));

SessionSummary _s(
  String id, {
  String? parent,
  bool running = false,
  String? title,
  Map<String, Object?> values = const {},
  bool? completed,
  DateTime? updatedAt,
}) => SessionSummary(
  sessionId: id,
  updatedAt: updatedAt ?? _t0.add(const Duration(minutes: 1)),
  running: running,
  blank: false,
  agentAvailable: true,
  parentSessionId: parent,
  origin: parent == null ? null : 'subagent',
  projections: SessionProjections(1, {
    'title': ?title,
    ...values,
    if (completed != null) 'subagentTiming': {'settledMs': 0, 'lastTurnCompleted': completed},
  }),
);

Map<String, Object?> _goal(String phase, {int rounds = 3, int max = 20}) => {
  'goal': {'id': 'g1', 'revision': 1, 'objective': '修好', 'phase': phase, 'maxGoalRounds': max},
  'roundsStarted': rounds,
};

JobInfo _job(String id, String status, {String? progress, DateTime? finishedAt}) => JobInfo(
  id: id,
  kind: 'bash',
  label: 'npm test --watch',
  status: status,
  progress: progress,
  startedAt: _t0.add(Duration(seconds: id.hashCode % 50)),
  finishedAt: finishedAt,
);

SessionLogEvent _e(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': _t0.millisecondsSinceEpoch + seq, 'type': type, 'data': data});

void main() {
  group('tree', () {
    test('descendants by parent (several levels), labels from the catalog and the team', () {
      final tree = buildWorkTree(
        rootId: 'r',
        sessions: [
          _s(
            'r',
            values: {
              'subagentCatalog': [
                {'id': 'a1', 'label': '审查员', 'mode': 'oneshot'},
              ],
              'agentTeam': {
                'members': [
                  {'id': 'm1', 'name': '测试手', 'phase': 'active'},
                ],
                'tasks': [
                  {'id': 't1', 'subject': 'x', 'status': 'completed'},
                  {'id': 't2', 'subject': 'y', 'status': 'pending'},
                ],
              },
            },
          ),
          _s('a1', parent: 'r', running: true),
          _s('m1', parent: 'r'),
          _s('deep', parent: 'a1', running: true, title: '查日志'),
          _s('other', title: '别的对话', running: true),
          _s('x1', parent: 'other', running: true),
        ],
      );
      expect([for (final a in tree.agents) a.sessionId], ['a1', 'm1', 'deep']);
      expect([for (final a in tree.agents) a.label], ['审查员', '测试手', '查日志']);
      expect(tree.team!.tasks, hasLength(2));
      // A teammate standing by (not running) keeps nothing busy.
      expect(tree.runningAgents.map((a) => a.sessionId), ['a1', 'deep']);
      expect(tree.busyWith(), isTrue);
      expect(
        buildWorkTree(
          rootId: 'r',
          sessions: [
            _s('r'),
            _s('m1', parent: 'r'),
          ],
        ).busyWith(),
        isFalse,
      );
    });

    test('jobs counted once; live ones keep it busy, finished ones do not', () {
      final shared = _job('j1', 'running');
      final tree = buildWorkTree(
        rootId: 'r',
        sessions: [
          _s('r'),
          _s('a1', parent: 'r', running: true),
        ],
        jobs: {
          'r': [shared, _job('j2', 'completed')],
          'a1': [shared],
        },
      );
      expect(tree.jobs.map((j) => j.id), ['j1', 'j2']);
      expect(tree.liveJobs, hasLength(1));
      final idle = buildWorkTree(
        rootId: 'r',
        sessions: [_s('r')],
        jobs: {
          'r': [_job('j2', 'completed'), _job('j3', 'killed'), _job('j4', 'stopping')],
        },
      );
      expect(idle.busyWith(), isTrue, reason: 'stopping is still live');
    });

    test('requests anywhere in the tree are the root\'s; a goal that will go on keeps it busy', () {
      final tree = buildWorkTree(
        rootId: 'r',
        sessions: [
          _s('r'),
          _s('a1', parent: 'r'),
          _s('other'),
        ],
        pending: const [
          ApprovalRequestedEvent(ApprovalRequest(eventId: 'ev1', sessionId: 'a1', toolName: 'bash')),
          ApprovalRequestedEvent(ApprovalRequest(eventId: 'ev2', sessionId: 'other', toolName: 'bash')),
        ],
      );
      expect(tree.approvals.map((a) => a.eventId), ['ev1']);
      expect(tree.busyWith(), isTrue);
      expect(tree.nameOf('a1'), 'a1');
      expect(tree.nameOf('r'), isNull);

      GoalProjection g(String phase, {int rounds = 3, int max = 20}) =>
          GoalProjection.fromJson(_goal(phase, rounds: rounds, max: max))!;
      expect(goalContinues(g('active')), isTrue);
      expect(goalContinues(g('active', rounds: 20)), isFalse);
      expect(goalContinues(g('active', rounds: 99, max: 0)), isTrue, reason: '0: no cap');
      expect(goalContinues(g('complete')), isFalse);
      expect(goalContinues(g('paused')), isFalse);
      final goalTree = buildWorkTree(
        rootId: 'r',
        sessions: [
          _s('r', values: {'goal': _goal('active')}),
        ],
      );
      expect(goalTree.goal!.roundsStarted, 3);
      expect(goalTree.busyWith(), isTrue);
    });
  });

  group('root log', () {
    test('a woken turn: the first prompt that isn\'t context decides', () {
      RootLogFacts fold(List<String> kinds) => foldRootLog([
        _e(1, 'turn/start', {}),
        for (final (i, k) in kinds.indexed)
          _e(2 + i, 'user/message', {
            'source': {'kind': k},
            'parts': [],
          }),
      ]);
      expect(fold(['time-context', 'runtime-context', 'tool-jobs']).wake, isTrue);
      expect(fold(['plugin:meow-memory', 'schedule']).turnSource, 'schedule');
      expect(fold(['skill-catalog', 'user', 'goal']).wake, isFalse, reason: 'a person started it');
      expect(fold(['subagent-settled']).wake, isTrue);
      expect(fold(['agent-message']).wake, isTrue);
      expect(fold(['time-context']).turnSource, isNull, reason: 'not known yet');
      // Only the last turn counts.
      final two = foldRootLog([
        _e(1, 'turn/start', {}),
        _e(2, 'user/message', {
          'source': {'kind': 'user'},
        }),
        _e(3, 'turn/start', {}),
        _e(4, 'user/message', {
          'source': {'kind': 'tool-jobs'},
        }),
      ]);
      expect(two.wake, isTrue);
    });

    test('workflow phases in first-seen order, members ended and failed', () {
      final facts = foldRootLog([
        _e(1, 'turn/start', {}),
        _e(2, 'tool-workflow/run-start', {'runId': 'w1', 'name': '发布前检查'}),
        for (var i = 0; i < 3; i++)
          _e(3 + i, 'tool-workflow/agent-start', {
            'runId': 'w1',
            'seq': i,
            'label': '审 $i',
            'phase': '审查',
            'childId': 'c$i',
          }),
        _e(6, 'tool-workflow/agent-end', {'runId': 'w1', 'seq': 0, 'outcome': 'completed'}),
        _e(7, 'tool-workflow/agent-end', {'runId': 'w1', 'seq': 1, 'outcome': 'failed'}),
        _e(8, 'tool-workflow/agent-start', {'runId': 'w1', 'seq': 3, 'label': '修', 'phase': '修复', 'childId': 'c3'}),
        _e(9, 'tool-workflow/agent-end', {'runId': 'w1', 'seq': 2, 'outcome': 'cancelled'}),
      ]);
      final run = facts.workflow!;
      expect(run.name, '发布前检查');
      expect([for (final p in run.phases) (p.title, p.members, p.ended, p.failed)], [('审查', 3, 3, 1), ('修复', 1, 0, 0)]);
      expect(run.current, '修复');
      expect(run.ended, isFalse);
      expect(run.members['c3'], '修');
      final keys = islandWorkflowKeys(run);
      expect(keys['name'], '发布前检查');
      expect(keys['seg'], [
        {'s': 'err', 'f': 1.0},
        {'s': 'active', 'f': 0.0},
      ]);
      expect(keys['label'], '修复');
    });

    test('more than six phases merge into six segments', () {
      final run = WorkflowRun('w', 'n');
      for (var i = 0; i < 9; i++) {
        run.phases.add(
          WorkflowPhase('p$i')
            ..members = 1
            ..ended = i < 4 ? 1 : 0,
        );
      }
      final seg = islandWorkflowKeys(run)['seg']! as List;
      expect(seg, hasLength(6));
      expect((seg.first as Map)['s'], 'done');
      expect((seg.last as Map)['s'], 'active');
    });
  });

  group('island content', () {
    IslandContent content({
      WorkTree? tree,
      WorkflowRun? workflow,
      GoalProjection? goal,
      bool background = false,
      RunActivity? activity,
      List<TodoItem>? todos,
      List<ApprovalRequest> approvals = const [],
      IslandFinish? finish,
    }) => islandContentOf(
      host: const HostRef.direct('h'),
      sessionId: 'r',
      rawTitle: '重构登录模块',
      activity: activity,
      approvals: approvals,
      questions: const [],
      todos: todos,
      tokens: null,
      others: const [],
      othersPending: 0,
      clockSkew: Duration.zero,
      now: _now,
      lang: 'zh',
      tree: tree,
      workflow: workflow,
      goal: goal,
      background: background,
      since: _t0,
      finish: finish,
    );

    final busy = buildWorkTree(
      rootId: 'r',
      sessions: [
        _s('r'),
        _s('a1', parent: 'r', running: true, title: '审查代码的子代理'),
        _s('a2', parent: 'r', title: '查日志', completed: true),
        _s('a3', parent: 'r', title: '跑测试', completed: false),
        _s('a4', parent: 'r', running: true, title: '改文档'),
        _s('a5', parent: 'r', running: true, title: '写报告'),
        _s('old', parent: 'r', title: '老的', completed: true, updatedAt: _t0.subtract(const Duration(hours: 1))),
      ],
      jobs: {
        'r': [
          _job('j1', 'running', progress: '阶段 2 · 构建'),
          _job('j2', 'running'),
          _job('j3', 'running'),
          _job('j4', 'failed', finishedAt: _t0.add(const Duration(minutes: 2))),
          _job('j5', 'failed', finishedAt: _t0.subtract(const Duration(hours: 2))),
        ],
      },
      pending: const [ApprovalRequestedEvent(ApprovalRequest(eventId: 'ev-sub', sessionId: 'a3', toolName: 'bash'))],
    );

    test('background: the root idle while the tree works', () {
      final quiet = buildWorkTree(
        rootId: 'r',
        sessions: [_s('r')],
        jobs: {
          'r': [_job('j1', 'running')],
        },
      );
      final c = content(tree: quiet, background: true);
      expect(c.phase, IslandPhase.background);
      expect(c.toolLabel, '后台进行中');
      expect(c.showStop, isTrue);
      expect(c.toMap()['phase'], 'background');
    });

    test('calves, bubbles and a request from a subagent', () {
      final map = content(
        tree: busy,
        activity: RunActivity(kind: ActivityKind.thinking, title: '', turnStart: _t0),
      ).toMap();
      expect(map['calves'], [
        {'s': 'wait', 'l': '跑测试'},
        {'s': 'run', 'l': '审查代码的…'},
        {'s': 'run', 'l': '改文档'},
      ]);
      expect(map['calvesMore'], 1, reason: '写报告 runs too; 查日志 is done and not counted');
      final bubbles = map['bubbles']! as Map;
      expect(bubbles['run'], 3);
      expect(bubbles['fail'], 1, reason: 'a job that failed before this run is not counted');
      expect((bubbles['top'] as List), hasLength(2));
      final pending = map['pending']! as Map;
      expect(pending['eventId'], 'ev-sub', reason: "the root's chat doesn't have a subagent's request (B8)");
      expect(pending['from'], '跑测试');
      expect(map['phase'], 'approval');
      expect(map.containsKey('pendingCount'), isFalse);
    });

    test('the lane: a workflow wins over the board, the board over todos', () {
      final todos = [const TodoItem('一', 'completed'), const TodoItem('二', 'pending')];
      final team = buildWorkTree(
        rootId: 'r',
        sessions: [
          _s(
            'r',
            values: {
              'agentTeam': {
                'members': <Object?>[],
                'tasks': [
                  {'id': 't1', 'subject': 'a', 'status': 'completed'},
                  {'id': 't2', 'subject': 'b', 'status': 'completed'},
                  {'id': 't3', 'subject': 'c', 'status': 'in_progress'},
                  {'id': 't4', 'subject': 'd', 'status': 'pending'},
                ],
              },
            },
          ),
        ],
      );
      final board = content(tree: team, todos: todos);
      expect(board.toMap()['team'], {'done': 2, 'total': 4});
      expect(board.progress, 0.5);
      expect(board.toMap().containsKey('todos'), isFalse);
      final run = WorkflowRun('w', '检查')
        ..phases.add(
          WorkflowPhase('一')
            ..members = 4
            ..ended = 1,
        );
      final wf = content(tree: team, todos: todos, workflow: run).toMap();
      expect(wf.containsKey('wf'), isTrue);
      expect(wf.containsKey('team'), isFalse);
      expect(wf['progress'], 0.25);
      final plain = content(todos: todos).toMap();
      expect(plain['todoTotal'], 2);
      expect(plain.containsKey('wf'), isFalse);
    });

    test('goal rounds; the summary tells what the tree did and what failed', () {
      final goal = GoalProjection.fromJson(_goal('active', rounds: 3, max: 20))!;
      expect(content(goal: goal).toMap()['goal'], {'round': 3, 'max': 20});
      final done = content(
        tree: busy,
        finish: IslandFinish(
          failed: false,
          start: _t0,
          end: _t0.add(const Duration(minutes: 9)),
          steps: 7,
          agents: 3,
          jobs: 2,
          failures: 1,
        ),
      );
      expect(done.summary, '7 步 · 09:00 · 3 个子代理 · 2 个后台任务 · 其中 1 个失败');
      expect(done.toMap().containsKey('calves'), isFalse);
      expect(done.toMap().containsKey('bubbles'), isFalse);
      final reached = content(
        goal: goal,
        finish: IslandFinish(failed: false, start: _t0, end: _t0, steps: 1, goalRounds: 12),
      );
      expect(reached.summary, '目标达成 · 12 轮');
      final stuck = content(
        goal: goal,
        finish: IslandFinish(failed: true, start: _t0, end: _t0, steps: 1, goalRounds: 20, reason: '测试一直不过'),
      );
      expect(stuck.phase, IslandPhase.failed);
      expect(stuck.summary, '目标卡住了：测试一直不过');
    });

    test('v3 at the limits stays under 4 KB', () {
      final huge = '😀' * 300;
      final run = WorkflowRun('w', huge);
      for (var i = 0; i < 40; i++) {
        run.phases.add(
          WorkflowPhase(huge)
            ..members = 3
            ..ended = 1
            ..failed = 1,
        );
      }
      run.current = huge;
      final tree = buildWorkTree(
        rootId: 'r',
        sessions: [
          _s('r', values: {'goal': _goal('active')}),
          for (var i = 0; i < 40; i++) _s('a$i', parent: 'r', running: true, title: huge),
        ],
        jobs: {
          'r': [
            for (var i = 0; i < 40; i++)
              JobInfo(id: 'j$i', kind: 'bash', label: huge, status: 'running', progress: huge),
          ],
        },
        pending: [
          for (var i = 0; i < 20; i++)
            ApprovalRequestedEvent(ApprovalRequest(eventId: 'ev$i', sessionId: 'a$i', toolName: huge)),
        ],
      );
      final c = content(
        tree: tree,
        workflow: run,
        activity: RunActivity(kind: ActivityKind.tool, title: '', toolName: huge, turnStart: _t0),
      );
      final bytes = utf8.encode(jsonEncode(c.toMap())).length;
      expect(bytes, lessThan(4096));
      expect((c.toMap()['pending']! as Map)['from'], isNotNull);
      expect(c.toMap()['pendingCount'], 20);
    });
  });
}
