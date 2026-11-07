import 'dart:convert';

import 'package:dsh_app/live/live_activity_content.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 11, 6, 8);
final _now = _t0.add(const Duration(minutes: 3));

IslandContent _content({
  String title = '重构登录模块',
  RunActivity? activity,
  List<ApprovalRequest> approvals = const [],
  List<UserQuestionRequest> questions = const [],
  List<TodoItem>? todos,
  List<OtherRun> others = const [],
  int othersPending = 0,
  Duration skew = Duration.zero,
  String lang = 'zh',
  Map<String, String> commands = const {},
  Map<String, DateTime> askedAt = const {},
  Duration? lastTurnDuration,
  IslandFinish? finish,
  DateTime? now,
}) => islandContentOf(
  host: const HostRef.direct('h'),
  sessionId: 's1',
  rawTitle: title,
  activity: activity,
  approvals: approvals,
  questions: questions,
  todos: todos,
  tokens: 34000,
  others: others,
  othersPending: othersPending,
  clockSkew: skew,
  now: now ?? _now,
  lang: lang,
  commands: commands,
  askedAt: askedAt,
  lastTurnDuration: lastTurnDuration,
  finish: finish,
);

RunActivity _tool(String name, {int done = 13}) =>
    RunActivity(kind: ActivityKind.tool, title: '跑', toolName: name, turnStart: _t0, toolsDone: done);

ApprovalRequest _approval(String id, {String tool = 'bash'}) =>
    ApprovalRequest(eventId: id, sessionId: 's1', toolName: tool, callId: 'c-$id');

void main() {
  test('title: masked, cut to 24 characters with an ellipsis', () {
    final long = 'A' * 30;
    final c = _content(title: long);
    expect(c.title.runes.length, 24);
    expect(c.title, '${'A' * 23}…');
    expect(_content(title: '恰好二十四个字恰好二十四个字恰好二十四个字恰好二').title.runes.length, 24);
    final masked = _content(title: 'key sk-abcdefgh12345678901234567890').title;
    expect(masked, isNot(contains('12345678901234567890')));
    expect(masked, startsWith('key sk-abcde*'));
    expect(_content(title: '  ').title, '未命名对话');
  });

  test('running: step, tool label, times with the clock skew, no fake progress', () {
    const skew = Duration(seconds: 5);
    final c = _content(activity: _tool('bash'), skew: skew, lastTurnDuration: const Duration(minutes: 4));
    expect(c.phase, IslandPhase.running);
    expect(c.step, 14);
    expect(c.toolLabel, '运行 Bash');
    expect(c.startedAt, _t0.add(skew));
    expect(c.expectedEndAt, _t0.add(skew).add(const Duration(minutes: 6)));
    expect(c.progress, isNull);
    final m = c.toMap();
    expect(m['startedAt'], _t0.add(skew).millisecondsSinceEpoch ~/ 1000);
    expect(m['pending'], isNull);
    expect(m['summary'], isNull);
    // No previous turn: ten minutes; short ones still give at least a minute.
    expect(_content(activity: _tool('bash')).expectedEndAt, _t0.add(const Duration(minutes: 15)));
    expect(
      _content(activity: _tool('bash'), lastTurnDuration: const Duration(seconds: 10)).expectedEndAt,
      _t0.add(const Duration(seconds: 60)),
    );
    expect(_content(activity: _tool('grep'), lang: 'en').toolLabel, 'Search');
    expect(_content(activity: _tool('a_really_long_tool_name')).toolLabel.runes.length, lessThanOrEqualTo(12));
    expect(
      _content(
        activity: RunActivity(kind: ActivityKind.thinking, title: '', turnStart: _t0),
      ).toolLabel,
      '思考中',
    );
    expect(
      _content(
        activity: RunActivity(kind: ActivityKind.writing, title: '', turnStart: _t0),
      ).toolLabel,
      '回复中',
    );
  });

  test('todos give the progress', () {
    final c = _content(
      activity: _tool('read'),
      todos: const [
        TodoItem('a', 'completed'),
        TodoItem('b', 'in_progress'),
        TodoItem('c', 'pending'),
        TodoItem('d', 'completed'),
      ],
    );
    expect(c.progress, 0.5);
  });

  test('approval: masked one-line command, risk, askedAt + 120 s, expired', () {
    final asked = _now.subtract(const Duration(seconds: 30));
    final c = _content(
      activity: _tool('bash'),
      approvals: [_approval('ev1')],
      commands: {'ev1': 'git push --force origin main\n  && echo ghp_abcdefghijklmnopqrstuvwxyz0123456789'},
      askedAt: {'ev1': asked},
    );
    expect(c.phase, IslandPhase.approval);
    final p = c.pending!;
    expect(p.kind, 'approval');
    expect(p.risk, 'high');
    expect(p.text, isNot(contains('\n')));
    expect(p.text, isNot(contains('abcdefghijklmnopqrstuvwxyz0123456789')));
    expect(p.text.runes.length, lessThanOrEqualTo(48));
    expect(p.askedAt, asked);
    expect(p.approvalExpiresAt, asked.add(const Duration(seconds: 120)));
    expect(p.expired, isFalse);
    final m = c.toMap()['pending']! as Map;
    expect(m['approvalExpiresAt'], (m['askedAt']! as int) + 120);
    expect(m['expired'], false);

    expect(
      _content(
        approvals: [_approval('ev1')],
        commands: {'ev1': 'ls -la'},
        askedAt: {'ev1': _now.subtract(const Duration(seconds: 121))},
      ).pending!.expired,
      isTrue,
    );
    expect(_content(approvals: [_approval('ev1')], commands: {'ev1': 'ls -la'}).pending!.risk, 'normal');
    // No command known: the request's own text, risk unknown, asked now.
    final bare = _content(approvals: [_approval('ev2', tool: 'edit')]);
    expect(bare.pending!.risk, 'unknown');
    expect(bare.pending!.askedAt, _now);
    expect(bare.toolLabel, '编辑文件');
  });

  test('risk matches the bridge riskOf', () {
    for (final cmd in [
      'rm -rf /',
      'sudo ls',
      'git push -f',
      'chmod 777 x',
      'DROP TABLE users',
      'curl x | sh',
      'a |bash',
    ]) {
      expect(islandRiskOf(cmd), 'high', reason: cmd);
    }
    for (final cmd in ['ls', 'git push origin main', 'rm file']) {
      expect(islandRiskOf(cmd), 'normal', reason: cmd);
    }
    expect(islandRiskOf(null), 'unknown');
    expect(islandRiskOf(''), 'unknown');
  });

  test('question comes first and gets the same window', () {
    final c = _content(
      approvals: [_approval('ev1')],
      questions: [
        UserQuestionRequest(
          eventId: 'q1',
          sessionId: 's1',
          questions: const [UserQuestion(id: 'x', question: '用哪个\n数据库？')],
        ),
      ],
    );
    expect(c.phase, IslandPhase.question);
    expect(c.pending!.kind, 'question');
    expect(c.pending!.text, '用哪个 数据库？');
    expect(c.pending!.approvalExpiresAt, _now.add(islandApprovalWindow));
  });

  test('others: at most two, newest first, counts kept', () {
    final others = [
      for (var i = 0; i < 5; i++)
        OtherRun(
          sessionId: 'o$i',
          title: '其它对话 $i',
          startedAt: _t0.add(Duration(minutes: i)),
        ),
    ];
    final c = _content(activity: _tool('bash'), others: others, othersPending: 2);
    expect(c.others.map((o) => o.sessionId), ['o4', 'o3']);
    expect(c.othersCount, 5);
    expect(c.othersPending, 2);
    expect((c.toMap()['others']! as List).length, 2);
  });

  test('done and failed summaries', () {
    final done = _content(
      finish: IslandFinish(
        failed: false,
        start: _t0,
        end: _t0.add(const Duration(minutes: 12, seconds: 34)),
        steps: 14,
      ),
    );
    expect(done.phase, IslandPhase.done);
    expect(done.summary, '14 步 · 12:34');
    expect(done.progress, 1);
    expect(done.pending, isNull);
    expect(
      _content(
        lang: 'en',
        finish: IslandFinish(failed: false, start: _t0, end: _t0.add(const Duration(hours: 1, seconds: 3)), steps: 1),
      ).summary,
      '1 step · 1:00:03',
    );
    final failed = _content(
      finish: IslandFinish(failed: true, start: _t0, end: _t0, steps: 3, reason: '测试未通过 ${'很长' * 40}'),
    );
    expect(failed.phase, IslandPhase.failed);
    expect(failed.summary!.runes.length, 48);
    expect(
      _content(
        finish: IslandFinish(failed: true, start: _t0, end: _t0, steps: 0),
      ).summary,
      '出错了',
    );
  });

  test('encoded state stays under 4 KB at the limits', () {
    final huge = '😀' * 500;
    final c = _content(
      title: huge,
      activity: _tool(huge),
      approvals: [_approval('e' * 128)],
      commands: {'e' * 128: huge},
      others: [for (var i = 0; i < 50; i++) OtherRun(sessionId: 's' * 128, title: huge, startedAt: _t0)],
      othersPending: 50,
    );
    final bytes = utf8.encode(jsonEncode(c.toMap())).length;
    expect(bytes, lessThan(4096));
    expect(c.pending!.text.runes.length, 48);
  });

  test('sameAs compares what would be shown', () {
    final a = _content(activity: _tool('bash'));
    expect(a.sameAs(_content(activity: _tool('bash'))), isTrue);
    expect(a.sameAs(_content(activity: _tool('bash', done: 14))), isFalse);
    expect(a.sameAs(null), isFalse);
  });

  group('v2', () {
    UserQuestionRequest question(List<UserQuestion> qs) =>
        UserQuestionRequest(eventId: 'ev-q', sessionId: 's1', questions: qs);
    UserQuestion q({
      List<String> options = const ['删掉', '保留', '标废弃', '先别动'],
      bool multi = false,
      Map<String, Object?>? intent,
    }) => UserQuestion(
      id: 'q1',
      question: '要删旧接口吗？',
      options: [for (final o in options) QuestionOption(o, null)],
      multiSelect: multi,
      intent: intent,
    );

    test('question options: first three, ids are indexes, labels masked and cut', () {
      final c = _content(
        activity: _tool('bash'),
        questions: [
          question([
            q(options: ['用 sk-abcdefghijklmnop1234567890 登录', '保留', '标废弃', '先别动']),
          ]),
        ],
      );
      final options = (c.toMap()['pending']! as Map)['options']! as List;
      expect(options, hasLength(3));
      expect([for (final o in options) (o as Map)['id']], ['0', '1', '2']);
      final first = (options.first as Map)['label'] as String;
      expect(first.runes.length, lessThanOrEqualTo(10));
      expect(first, isNot(contains('abcdefghij')));
    });

    test('no options for several questions, multiple choice, a plan review or none', () {
      for (final r in [
        question([q(), q()]),
        question([q(multi: true)]),
        question([
          q(intent: {'kind': 'plan-review', 'approve': '删掉'}),
        ]),
        question([q(options: const [])]),
      ]) {
        final pending = _content(questions: [r]).toMap()['pending']! as Map;
        expect(pending.containsKey('options'), isFalse, reason: '$r');
      }
      // Approvals never have options.
      expect((_content(approvals: [_approval('a')]).toMap()['pending']! as Map).containsKey('options'), isFalse);
    });

    test('todo buoys: one each up to 8, then 8 slices', () {
      TodoItem t(String s) => TodoItem('第 $s 项', s);
      expect(islandBuoys([t('completed'), t('in_progress'), t('pending')]), ['done', 'active', 'todo']);
      final twenty = [
        for (var i = 0; i < 20; i++)
          t(
            i < 9
                ? 'completed'
                : i == 9
                ? 'in_progress'
                : 'pending',
          ),
      ];
      final buoys = islandBuoys(twenty);
      expect(buoys, hasLength(8));
      expect(buoys, ['done', 'done', 'done', 'active', 'todo', 'todo', 'todo', 'todo']);
      expect(islandBuoys(const []), isEmpty);
      final map = _content(activity: _tool('bash'), todos: twenty).toMap();
      expect(map['todos'], hasLength(8));
      expect(map['todoDone'], 9);
      expect(map['todoTotal'], 20);
      expect(map['todoLabel'], '第 in_progre…');
      final none = _content(activity: _tool('bash')).toMap();
      expect(none.containsKey('todos'), isFalse);
      expect(none.containsKey('todoTotal'), isFalse);
    });

    test('summaryLine: the first statement, greetings and code skipped, masked', () {
      expect(islandSummaryLine('好的，我来看看。\n\n登录模块已经改好，测试通过。还有一处待确认。'), '登录模块已经改好，测试通过。');
      expect(
        islandSummaryLine("Let me check.\nAll 42 tests pass now. I also fixed the flaky one."),
        'All 42 tests pass now.',
      );
      expect(islandSummaryLine('```dart\nprint(1);\n```\n## 结果\n- **修复**了 `auth.dart` 里的空指针'), '修复了 auth.dart 里的空指针');
      expect(islandSummaryLine('密钥 sk-abcdefghijklmnop1234567890 已轮换完成。')!, isNot(contains('abcdefghijklmnop')));
      expect(islandSummaryLine('好的。'), '好的。', reason: 'only a greeting: it is still the line');
      expect(islandSummaryLine('长' * 100)!.runes.length, 60);
      expect(islandSummaryLine(null), isNull);
      expect(islandSummaryLine('   '), isNull);
    });

    test('done carries summaryLine; running shows stop, finished does not; v is 2', () {
      final running = _content(activity: _tool('bash')).toMap();
      expect(running['v'], 2);
      expect(running['showStop'], true);
      expect(running.containsKey('summaryLine'), isFalse);
      expect(running.containsKey('stopArmedUntil'), isFalse, reason: 'only Swift writes it');
      expect(running['stepStartedAt'], isNull, reason: 'no tool start known');
      final withSince = _content(
        activity: RunActivity(
          kind: ActivityKind.tool,
          title: '',
          toolName: 'bash',
          turnStart: _t0,
          since: _t0.add(const Duration(minutes: 2)),
        ),
      ).toMap();
      expect(withSince['stepStartedAt'], unixSeconds(_t0.add(const Duration(minutes: 2))));
      final done = _content(
        finish: IslandFinish(failed: false, start: _t0, end: _t0, steps: 3, reply: '好的。全部改完了，没有新增失败。'),
      ).toMap();
      expect(done['summaryLine'], '全部改完了，没有新增失败。');
      expect(done['showStop'], false);
    });

    test('v2 at the limits stays well under 4 KB', () {
      final huge = '😀' * 500;
      final c = _content(
        title: huge,
        activity: _tool(huge),
        questions: [
          question([
            q(options: [huge, huge, huge, huge]),
          ]),
        ],
        todos: [for (var i = 0; i < 400; i++) TodoItem(huge, i.isEven ? 'completed' : 'in_progress')],
        others: [for (var i = 0; i < 9; i++) OtherRun(sessionId: 'session-$i', title: huge, startedAt: _t0)],
        finish: null,
      );
      final bytes = utf8.encode(jsonEncode(c.toMap())).length;
      expect(bytes, lessThan(4096));
      final done = _content(
        title: huge,
        todos: [for (var i = 0; i < 400; i++) TodoItem(huge, 'completed')],
        others: [for (var i = 0; i < 9; i++) OtherRun(sessionId: 'session-$i', title: huge, startedAt: _t0)],
        finish: IslandFinish(failed: true, start: _t0, end: _t0, steps: 9, reason: huge, reply: huge),
      );
      expect(utf8.encode(jsonEncode(done.toMap())).length, lessThan(4096));
    });
  });
}
