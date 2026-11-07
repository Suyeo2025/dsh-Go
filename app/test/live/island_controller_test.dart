import 'dart:async';

import 'package:dsh_app/live/island_prefs_state.dart';
import 'package:dsh_app/live/live_activity_channel.dart';
import 'package:dsh_app/live/live_activity_content.dart' show OtherRun;
import 'package:dsh_app/live/live_activity_state.dart';
import 'package:dsh_app/live/work_tree.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/state/notify_state.dart' show appForegroundProvider;
import 'package:dsh_app/state/sessions_state.dart' show currentSessionProvider;
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The chat states the controller sees, per conversation.
class FakeViews extends Notifier<Map<String, IslandSessionView>> {
  @override
  Map<String, IslandSessionView> build() => const {};

  void set(String id, IslandSessionView view) => state = {...state, id: view};
}

final fakeViewsProvider = NotifierProvider<FakeViews, Map<String, IslandSessionView>>(FakeViews.new);

/// The work trees the controller sees, per root.
class FakeTrees extends Notifier<Map<String, WorkTree>> {
  @override
  Map<String, WorkTree> build() => const {};

  void set(String id, WorkTree tree) => state = {...state, id: tree};
}

final fakeTreesProvider = NotifierProvider<FakeTrees, Map<String, WorkTree>>(FakeTrees.new);

extension on JobInfo {
  JobInfo copyWithStatus(String status) => JobInfo(id: id, kind: kind, label: label, status: status);
}

extension on IslandSessionView {
  IslandSessionView copyWithWake() =>
      IslandSessionView(running: running, synced: synced, title: title, activity: activity, wake: true);
}

final _t0 = DateTime.utc(2026, 11, 6, 8);

/// The device clock the controller reads (tests move it).
var _now = _t0.add(const Duration(minutes: 1));

IslandSessionView _idle() => const IslandSessionView(synced: true);
IslandSessionView _sending() => const IslandSessionView(synced: true, localSend: true);
IslandSessionView _running({
  int done = 0,
  String tool = 'bash',
  bool localSend = false,
  List<ApprovalRequest> approvals = const [],
}) => IslandSessionView(
  running: true,
  synced: true,
  localSend: localSend,
  title: '重构登录模块',
  approvals: approvals,
  activity: RunActivity(kind: ActivityKind.tool, title: '', toolName: tool, turnStart: _t0, toolsDone: done),
);

/// A run just started, nothing but thinking yet (a short reply so far).
IslandSessionView _fresh({bool localSend = false, Duration age = Duration.zero}) => IslandSessionView(
  running: true,
  synced: true,
  localSend: localSend,
  title: '回个话',
  activity: RunActivity(kind: ActivityKind.thinking, title: '', turnStart: _now.subtract(age)),
);
IslandSessionView _ended(String kind, {int tools = 14, String? reply}) => IslandSessionView(
  synced: true,
  title: '重构登录模块',
  reply: reply,
  lastTurnTools: tools,
  lastTurn: TurnTrace(
    turn: 1,
    startSeq: 0,
    start: _t0,
    spans: const [],
    end: _t0.add(const Duration(minutes: 12, seconds: 34)),
    endReason: TurnEndReason(kind),
  ),
);

/// Lets the channel round trips (and what they start) finish.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var listed = <Map<String, Object?>>[];
  var supported = true;
  var dwell = const Duration(hours: 1);
  late StreamController<void> leaving;
  var others = (runs: const <OtherRun>[], pending: const <String>{});
  var waiting = const <String, IslandWaiting>{};
  var settleWindow = Duration.zero;

  setUp(() {
    calls.clear();
    listed = [];
    supported = true;
    dwell = const Duration(hours: 1);
    leaving = StreamController<void>.broadcast();
    _now = _t0.add(const Duration(minutes: 1));
    others = (runs: const <OtherRun>[], pending: const <String>{});
    waiting = const {};
    settleWindow = Duration.zero;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      liveActivityMethodChannel,
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'status' => {'supported': supported, 'enabled': supported, 'pushToStart': false, 'frequentUpdates': false},
          'start' => {'activityId': 'act-${(call.arguments as Map)['sessionId']}'},
          'list' => listed,
          'takePendingTokens' => {'activities': <Object?>[]},
          _ => null,
        };
      },
    );
  });

  tearDown(() {
    debugRemoteOnlyOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      liveActivityMethodChannel,
      null,
    );
  });

  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        islandSessionViewProvider.overrideWith((ref, id) => ref.watch(fakeViewsProvider)[id] ?? _idle()),
        islandOthersProvider.overrideWith((ref) => others),
        islandWaitingProvider.overrideWithValue(() => waiting),
        workTreeProvider.overrideWith((ref, id) => ref.watch(fakeTreesProvider)[id] ?? WorkTree.empty(id)),
        islandSettleWindowProvider.overrideWithValue(settleWindow),
        islandLinksProvider.overrideWithValue((_) => () {}),
        islandClockProvider.overrideWithValue(() => _now),
        islandThrottleProvider.overrideWithValue(const Duration(milliseconds: 40)),
        islandDwellProvider.overrideWithValue(dwell),
        islandLeavingProvider.overrideWithValue(leaving.stream),
      ],
    );
    addTearDown(c.dispose);
    // As the app does (app.dart): listened for its whole life, so its own
    // subscriptions are never paused.
    c.listen(islandControllerProvider, (_, _) {});
    return c;
  }

  Future<ProviderContainer> ready() async {
    final c = make();
    await c.read(liveActivityStatusProvider.future);
    await c.read(islandPrefsProvider.notifier).ready;
    await settle();
    return c;
  }

  List<String> methods() => [for (final c in calls) c.method];
  Map<Object?, Object?> lastOf(String method) => calls.lastWhere((c) => c.method == method).arguments as Map;

  /// A message sent from here in [id], then its turn starts.
  Future<void> sendIn(ProviderContainer c, String id) async {
    c.read(currentSessionProvider.notifier).select(id);
    await settle();
    final views = c.read(fakeViewsProvider.notifier);
    views.set(id, _idle());
    await settle();
    views.set(id, _sending());
    await settle();
    views.set(id, _running(localSend: true));
    await settle();
  }

  group('iOS', () {
    setUp(() => debugRemoteOnlyOverride = true);

    test('a message sent from here starts the Activity', () async {
      final c = await ready();
      await sendIn(c, 's1');
      expect(methods(), contains('start'));
      final start = lastOf('start');
      expect(start['sessionId'], 's1');
      expect(start['title'], '重构登录模块');
      expect(start['lang'], 'zh');
      expect((start['state']! as Map)['phase'], 'running');
      expect((start['state']! as Map)['toolLabel'], '运行 Bash');
      expect(c.read(islandControllerProvider).activeSessionId, 's1');
      expect(c.read(islandControllerProvider).activityId, 'act-s1');
    });

    /// [id] open on screen, running: started elsewhere (no message from here).
    Future<void> openRunning(ProviderContainer c, String id, [IslandSessionView? view]) async {
      c.read(fakeViewsProvider.notifier).set(id, view ?? _running());
      c.read(currentSessionProvider.notifier).select(id);
      await settle();
    }

    Future<void> leave() async {
      leaving.add(null);
      await settle();
    }

    test('a turn started elsewhere starts nothing at once', () async {
      final c = await ready();
      c.read(currentSessionProvider.notifier).select('s1');
      await settle();
      final views = c.read(fakeViewsProvider.notifier)..set('s1', _idle());
      await settle();
      views.set('s1', _running());
      await settle();
      expect(methods(), isNot(contains('start')));
    });

    test('running elsewhere, open on screen, the app leaves: started', () async {
      final c = await ready();
      await openRunning(c, 's1');
      expect(methods(), isNot(contains('start')));
      await leave();
      expect(methods().where((m) => m == 'start'), hasLength(1));
      expect(lastOf('start')['sessionId'], 's1');
      expect(c.read(islandControllerProvider).activeSessionId, 's1');
      // Leaving again (the shade, a second time): no second start.
      await leave();
      expect(methods().where((m) => m == 'start'), hasLength(1));
    });

    test('running elsewhere and looked at for the dwell: started before leaving', () async {
      dwell = const Duration(milliseconds: 40);
      final c = await ready();
      await openRunning(c, 's1');
      expect(methods(), isNot(contains('start')));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(lastOf('start')['sessionId'], 's1');
      await leave();
      expect(methods().where((m) => m == 'start'), hasLength(1), reason: 'not twice for the same conversation');
    });

    test('not running, or already finished: leaving starts nothing', () async {
      final c = await ready();
      await openRunning(c, 's1', _idle());
      await leave();
      await openRunning(c, 's2', _ended('completed'));
      await leave();
      await openRunning(c, 's3', const IslandSessionView(running: true));
      await leave();
      expect(methods(), isNot(contains('start')), reason: 'a chat still loading is not taken for running');
    });

    test('an Activity waiting on an approval is not traded for another', () async {
      final c = await ready();
      await sendIn(c, 's1');
      c
          .read(fakeViewsProvider.notifier)
          .set(
            's1',
            _running(
              approvals: const [ApprovalRequest(eventId: 'ev1', sessionId: 's1', toolName: 'bash')],
            ),
          );
      await settle();
      calls.clear();
      await openRunning(c, 's2');
      await leave();
      expect(methods(), isNot(contains('start')));
      expect(methods(), isNot(contains('end')));
      expect(c.read(islandControllerProvider).activeSessionId, 's1');

      // Answered: the next conversation may take its place.
      c.read(fakeViewsProvider.notifier).set('s1', _running(done: 1));
      await settle();
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      await openRunning(c, 's2');
      await leave();
      expect(lastOf('end'), {'sessionId': 's1', 'dismissal': 'immediate'});
      expect(lastOf('start')['sessionId'], 's2');
    });

    test('灵动岛 off, or no Live Activities on this device: leaving starts nothing', () async {
      final c = await ready();
      await c.read(islandPrefsProvider.notifier).setMode(IslandMode.off);
      await settle();
      await openRunning(c, 's1');
      await leave();
      expect(methods(), isNot(contains('start')));
    });

    test('an iPad: nothing starts', () async {
      supported = false;
      final c = await ready();
      await openRunning(c, 's1');
      await leave();
      await sendIn(c, 's2');
      expect(methods(), isNot(contains('start')));
    });

    test('a message in another conversation ends the old Activity first', () async {
      final c = await ready();
      await sendIn(c, 's1');
      calls.clear();
      await sendIn(c, 's2');
      final i = methods().indexOf('end');
      expect(i, greaterThanOrEqualTo(0));
      expect(lastOf('end'), {'sessionId': 's1', 'dismissal': 'immediate'});
      expect(methods().indexOf('start'), greaterThan(i));
      expect(lastOf('start')['sessionId'], 's2');
      expect(c.read(islandControllerProvider).activeSessionId, 's2');
    });

    test('updates are throttled; a request goes at once', () async {
      final c = await ready();
      await sendIn(c, 's1');
      calls.clear();
      final views = c.read(fakeViewsProvider.notifier);
      views.set('s1', _running(done: 1));
      await settle();
      views.set('s1', _running(done: 2));
      await settle();
      expect(methods().where((m) => m == 'update'), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(methods().where((m) => m == 'update').length, 1);
      expect((lastOf('update')['state']! as Map)['step'], 3);

      views.set(
        's1',
        _running(
          done: 2,
          approvals: const [ApprovalRequest(eventId: 'ev1', sessionId: 's1', toolName: 'bash')],
        ),
      );
      await settle();
      expect(methods().where((m) => m == 'update').length, 2);
      final state = lastOf('update')['state']! as Map;
      expect(state['phase'], 'approval');
      expect((state['pending']! as Map)['eventId'], 'ev1');
      expect((state['pending']! as Map)['expired'], false);
    });

    test('done while looking at another conversation: breachTick + 1, the card stays 20 min', () async {
      final c = await ready();
      await sendIn(c, 's1');
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed', reply: '好的，我来看看。登录接口已改成按令牌续期，测试全部通过。'));
      await settle();
      expect(methods(), ['update', 'end']);
      final state = lastOf('update')['state']! as Map;
      expect(state['phase'], 'done');
      expect(state['breachTick'], 1);
      expect(state['summary'], '14 步 · 12:34');
      expect(state['summaryLine'], '登录接口已改成按令牌续期，测试全部通过。');
      expect(state['showStop'], false);
      expect(lastOf('end')['dismissal'], 'after20m');
      expect((lastOf('end')['state']! as Map)['phase'], 'done');
      expect(c.read(islandControllerProvider).ended, isTrue);
    });

    test('done while looking at it: put away at once', () async {
      final c = await ready();
      await sendIn(c, 's1');
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
      await settle();
      expect(methods(), ['update', 'end']);
      expect(lastOf('end')['dismissal'], 'immediate');
      expect(c.read(islandControllerProvider).activeSessionId, isNull);
    });

    test('failed ends after 15 min; stopped ends at once', () async {
      final c = await ready();
      await sendIn(c, 's1');
      // Not looking at it any more.
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('error'));
      await settle();
      expect(methods(), ['end']);
      expect(lastOf('end')['dismissal'], 'after15m');
      expect((lastOf('end')['state']! as Map)['phase'], 'failed');

      // Opening the failed conversation puts it away.
      calls.clear();
      c.read(currentSessionProvider.notifier).select('s1');
      await settle();
      expect(lastOf('end'), {'sessionId': 's1', 'dismissal': 'immediate'});
      expect(c.read(islandControllerProvider).activeSessionId, isNull);

      await sendIn(c, 's2');
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s2', _ended('aborted'));
      await settle();
      expect(methods(), ['end']);
      expect(lastOf('end'), {'sessionId': 's2', 'dismissal': 'immediate'});
    });

    test('no local update in the background; one on return', () async {
      final c = await ready();
      await sendIn(c, 's1');
      calls.clear();
      c.read(appForegroundProvider.notifier).set(false);
      await settle();
      c.read(fakeViewsProvider.notifier).set('s1', _running(done: 5));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(methods().where((m) => m == 'update'), isEmpty);
      c.read(appForegroundProvider.notifier).set(true);
      await settle();
      expect(methods(), contains('update'));
      expect((lastOf('update')['state']! as Map)['step'], 6);
    });

    test('灵动岛 off: endAll, and nothing starts', () async {
      final c = await ready();
      await sendIn(c, 's1');
      calls.clear();
      await c.read(islandPrefsProvider.notifier).setMode(IslandMode.off);
      await settle();
      expect(methods(), contains('endAll'));
      expect(lastOf('endAll'), {'dismissal': 'immediate'});
      expect(c.read(islandControllerProvider).activeSessionId, isNull);
      calls.clear();
      await sendIn(c, 's2');
      expect(methods(), isNot(contains('start')));
    });

    test('the system dismissing it clears it here', () async {
      final c = await ready();
      await sendIn(c, 's1');
      await c
          .read(liveActivityChannelProvider)
          .handle(const MethodCall('onActivityState', {'sessionId': 's1', 'state': 'dismissed'}));
      await settle();
      expect(c.read(islandControllerProvider).activeSessionId, isNull);
    });

    test('a relaunch takes over the running Activity', () async {
      listed = [
        {'sessionId': 's9', 'activityId': 'act-9', 'state': 'active'},
      ];
      final c = make();
      // Still loading its chat when taken over.
      c.read(fakeViewsProvider.notifier).set('s9', const IslandSessionView());
      c.read(islandControllerProvider);
      await c.read(liveActivityStatusProvider.future);
      await settle();
      final s = c.read(islandControllerProvider);
      expect(s.activeSessionId, 's9');
      expect(s.activityId, 'act-9');
      expect(s.source, IslandSource.bridge);
      expect(methods(), containsAll(['status', 'list', 'takePendingTokens']));
      // Its chat state arrives: the first local update.
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s9', _running(done: 3));
      await settle();
      expect(lastOf('update')['sessionId'], 's9');
      // It ended while the app was away: put away like any finished turn.
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s9', _ended('completed'));
      await settle();
      expect(methods(), ['update', 'end']);
    });

    test('taken over but already idle: ended as done', () async {
      listed = [
        {'sessionId': 's9', 'activityId': 'act-9', 'state': 'active'},
      ];
      final c = make();
      c.read(fakeViewsProvider.notifier).set('s9', _ended('completed'));
      c.read(islandControllerProvider);
      await c.read(liveActivityStatusProvider.future);
      await settle();
      expect(lastOf('end')['dismissal'], 'after20m');
      expect(c.read(islandControllerProvider).ended, isTrue);
    });

    // ── v3 work tree ──

    WorkTree treeWith({List<JobInfo> jobs = const [], List<ApprovalRequest> approvals = const []}) => WorkTree(
      rootId: 's1',
      agents: [for (final a in approvals) TreeAgent(sessionId: a.sessionId, label: '审查员', running: false)],
      jobs: jobs,
      approvals: approvals,
    );
    const job = JobInfo(id: 'j1', kind: 'bash', label: 'sleep 120', status: 'running');

    test('root replied, a job still runs: background, nothing ends; the job done → settled after the window', () async {
      settleWindow = const Duration(milliseconds: 60);
      final c = await ready();
      await sendIn(c, 's1');
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      c.read(fakeTreesProvider.notifier).set('s1', treeWith(jobs: [job]));
      await settle();
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();
      expect(methods(), isNot(contains('end')));
      expect((lastOf('update')['state']! as Map)['phase'], 'background');
      expect(c.read(islandControllerProvider).ended, isFalse);

      // The job is over: quiet for the window, then one end.
      c.read(fakeTreesProvider.notifier).set('s1', treeWith(jobs: [job.copyWithStatus('completed')]));
      await settle();
      expect(methods(), isNot(contains('end')), reason: 'not before the window');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();
      expect(methods().where((m) => m == 'end'), hasLength(1));
      expect(lastOf('end')['dismissal'], 'after20m');
    });

    test('busy again within the window: not settled', () async {
      settleWindow = const Duration(milliseconds: 80);
      final c = await ready();
      await sendIn(c, 's1');
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
      await settle();
      // A job wakes the root at once (goal rounds, job wake-ups).
      c.read(fakeViewsProvider.notifier).set('s1', _running(done: 2));
      await Future<void>.delayed(const Duration(milliseconds: 160));
      await settle();
      expect(methods(), isNot(contains('end')));
      expect(c.read(islandControllerProvider).ended, isFalse);
    });

    test("a subagent's approval stays on the island while the root's chat has none (B8)", () async {
      final c = await ready();
      await sendIn(c, 's1');
      c.read(currentSessionProvider.notifier).select('s1');
      await settle();
      calls.clear();
      c
          .read(fakeTreesProvider.notifier)
          .set(
            's1',
            treeWith(
              approvals: const [ApprovalRequest(eventId: 'ev-sub', sessionId: 'sub1', toolName: 'bash')],
            ),
          );
      await settle();
      c.read(fakeViewsProvider.notifier).set('s1', _running(done: 3));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      final state = lastOf('update')['state']! as Map;
      expect(state['phase'], 'approval');
      expect((state['pending']! as Map)['eventId'], 'ev-sub');
      expect((state['pending']! as Map)['from'], '审查员');
      // The root idle, the subagent waiting: background-busy, not done.
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(methods(), isNot(contains('end')));
    });

    GoalProjection goalAt(String phase, DateTime updatedAt, {int rounds = 5}) => GoalProjection.fromJson({
      'goal': {'id': 'g1', 'revision': 1, 'objective': '修好', 'phase': phase, 'maxGoalRounds': 20},
      'roundsStarted': rounds,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    })!;
    IslandSessionView withGoal(IslandSessionView v, GoalProjection g) => IslandSessionView(
      running: v.running,
      synced: v.synced,
      title: v.title,
      activity: v.activity,
      lastTurn: v.lastTurn,
      lastTurnTools: v.lastTurnTools,
      goal: g,
    );

    test('a goal reached during this run: 目标达成; one reached or paused long ago says nothing', () async {
      final c = await ready();
      await sendIn(c, 's1');
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      final views = c.read(fakeViewsProvider.notifier);
      views.set('s1', withGoal(_running(done: 1), goalAt('active', _t0)));
      await settle();
      calls.clear();
      views.set('s1', withGoal(_ended('completed'), goalAt('complete', _t0.add(const Duration(minutes: 13)))));
      await settle();
      expect((lastOf('end')['state']! as Map)['summary'], '目标达成 · 5 轮');

      // Another conversation whose goal was reached (or paused) an hour before.
      for (final phase in ['complete', 'paused']) {
        await sendIn(c, 's2');
        c.read(currentSessionProvider.notifier).select(null);
        await settle();
        calls.clear();
        views.set('s2', withGoal(_ended('completed'), goalAt(phase, _t0.subtract(const Duration(hours: 1)))));
        await settle();
        expect(lastOf('end')['dismissal'], 'after20m', reason: phase);
        expect((lastOf('end')['state']! as Map)['summary'], '14 步 · 12:34', reason: phase);
        views.set('s2', _idle());
        await settle();
      }
    });

    test('a woken turn after the end does not start a new Activity', () async {
      final c = await ready();
      await sendIn(c, 's1');
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
      await settle();
      expect(c.read(islandControllerProvider).ended, isTrue);
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _running().copyWithWake());
      await settle();
      await leave();
      expect(methods(), isNot(contains('start')));
    });

    // ── v2 start rules ──

    test('a short reply from here never gets one; its first tool call does', () async {
      final c = await ready();
      c.read(currentSessionProvider.notifier).select('s1');
      await settle();
      final views = c.read(fakeViewsProvider.notifier)..set('s1', _idle());
      await settle();
      views.set('s1', _sending());
      await settle();
      views.set('s1', _fresh(localSend: true));
      await settle();
      expect(methods(), isNot(contains('start')));
      views.set('s1', _running());
      await settle();
      expect(lastOf('start')['sessionId'], 's1');
    });

    test('a reply from here that just runs on: started once it is 8 s old', () async {
      final c = await ready();
      c.read(currentSessionProvider.notifier).select('s1');
      await settle();
      final views = c.read(fakeViewsProvider.notifier)..set('s1', _idle());
      await settle();
      views.set('s1', _sending());
      await settle();
      views.set('s1', _fresh(localSend: true, age: islandShortRun - const Duration(milliseconds: 30)));
      await settle();
      expect(methods(), isNot(contains('start')));
      // The wait is a timer up to [islandShortRun] from the run's start.
      _now = _now.add(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(lastOf('start')['sessionId'], 's1');
    });

    test('a short reply that is over before it qualifies never shows up', () async {
      final c = await ready();
      await openRunning(c, 's1', _fresh());
      await leave();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
      await settle();
      await leave();
      expect(methods(), isNot(contains('start')));
    });

    test('leaving with nothing open: the conversation waiting on you', () async {
      const q = UserQuestionRequest(
        eventId: 'ev-q',
        sessionId: 's5',
        questions: [
          UserQuestion(
            id: 'q1',
            question: '要把旧接口一起删掉吗？',
            options: [QuestionOption('删掉', null), QuestionOption('保留并标记为废弃的接口', null)],
          ),
        ],
      );
      others = (runs: [OtherRun(sessionId: 's5', title: '接口清理', startedAt: _t0)], pending: const {'s5'});
      waiting = const {
        's5': (approvals: <ApprovalRequest>[], questions: [q]),
      };
      final c = await ready();
      await leave();
      final start = lastOf('start');
      expect(start['sessionId'], 's5');
      expect(start['title'], '接口清理');
      final state = start['state']! as Map;
      expect(state['phase'], 'question');
      final pending = state['pending']! as Map;
      expect(pending['eventId'], 'ev-q');
      expect(pending['options'], [
        {'id': '0', 'label': '删掉'},
        {'id': '1', 'label': '保留并标记为废弃的…'},
      ]);
      expect(c.read(islandControllerProvider).activeSessionId, 's5');
    });

    test('leaving: else the running conversation this phone sent to in the last 30 min', () async {
      others = (runs: [OtherRun(sessionId: 's6', title: '跑测试', startedAt: _t0)], pending: const <String>{});
      final c = await ready();
      // A message in s6 (a reply too young yet), then off to the list.
      c.read(currentSessionProvider.notifier).select('s6');
      await settle();
      final views = c.read(fakeViewsProvider.notifier)..set('s6', _sending());
      await settle();
      views.set('s6', _fresh());
      await settle();
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      expect(methods(), isNot(contains('start')));
      await leave();
      expect(lastOf('start')['sessionId'], 's6');

      // Swiped away while it runs: not again this run.
      await c
          .read(liveActivityChannelProvider)
          .handle(const MethodCall('onActivityState', {'sessionId': 's6', 'state': 'dismissed'}));
      await settle();
      calls.clear();
      await leave();
      expect(methods(), isNot(contains('start')));
    });

    test('a message sent over 30 min ago does not count', () async {
      others = (runs: [OtherRun(sessionId: 's6', title: '跑测试', startedAt: _t0)], pending: const <String>{});
      final c = await ready();
      c.read(currentSessionProvider.notifier).select('s6');
      await settle();
      c.read(fakeViewsProvider.notifier).set('s6', _sending());
      await settle();
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      _now = _now.add(islandRecentSend + const Duration(minutes: 1));
      await leave();
      expect(methods(), isNot(contains('start')));
    });

    test('leaving with an Activity already on: nothing else starts', () async {
      final c = await ready();
      await sendIn(c, 's1');
      waiting = const {
        's5': (
          approvals: [ApprovalRequest(eventId: 'ev5', sessionId: 's5', toolName: 'bash')],
          questions: <UserQuestionRequest>[],
        ),
      };
      c.read(currentSessionProvider.notifier).select(null);
      await settle();
      calls.clear();
      await leave();
      expect(methods(), isNot(contains('start')));
      expect(c.read(islandControllerProvider).activeSessionId, 's1');
    });
  });

  test('Android: no channel call at all', () async {
    final c = make();
    c.read(islandControllerProvider);
    await c.read(liveActivityStatusProvider.future);
    await settle();
    await sendIn(c, 's1');
    c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
    await settle();
    await c.read(islandPrefsProvider.notifier).setMode(IslandMode.always);
    expect(c.read(islandPrefsProvider).mode, IslandMode.off);
    expect(calls, isEmpty);
    expect(c.read(islandControllerProvider).activeSessionId, isNull);
  });
}
