import 'dart:async';

import 'package:dsh_app/live/island_prefs_state.dart';
import 'package:dsh_app/live/live_activity_channel.dart';
import 'package:dsh_app/live/live_activity_state.dart';
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

final _t0 = DateTime.utc(2026, 11, 6, 8);

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
IslandSessionView _ended(String kind, {int tools = 14}) => IslandSessionView(
  synced: true,
  title: '重构登录模块',
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

  setUp(() {
    calls.clear();
    listed = [];
    supported = true;
    dwell = const Duration(hours: 1);
    leaving = StreamController<void>.broadcast();
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
        islandOthersProvider.overrideWithValue((runs: const [], pending: const {})),
        islandLinksProvider.overrideWithValue((_) => () {}),
        islandClockProvider.overrideWithValue(() => _t0.add(const Duration(minutes: 1))),
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

    test('done: a last update with breachTick + 1, then end after 4 s', () async {
      final c = await ready();
      await sendIn(c, 's1');
      calls.clear();
      c.read(fakeViewsProvider.notifier).set('s1', _ended('completed'));
      await settle();
      expect(methods(), ['update', 'end']);
      final state = lastOf('update')['state']! as Map;
      expect(state['phase'], 'done');
      expect(state['breachTick'], 1);
      expect(state['summary'], '14 步 · 12:34');
      expect(lastOf('end')['dismissal'], 'after4s');
      expect((lastOf('end')['state']! as Map)['phase'], 'done');
      expect(c.read(islandControllerProvider).ended, isTrue);
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
      expect(lastOf('end')['dismissal'], 'after4s');
      expect(c.read(islandControllerProvider).ended, isTrue);
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
