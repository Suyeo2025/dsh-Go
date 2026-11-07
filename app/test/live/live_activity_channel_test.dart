import 'package:dsh_app/live/live_activity_channel.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  late Object? Function(MethodCall call) answer;

  setUp(() {
    calls.clear();
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      liveActivityMethodChannel,
      (call) async {
        calls.add(call);
        return answer(call);
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

  test('Android (the test default): every call short-circuits, the channel is never used', () async {
    final ch = LiveActivityChannel()..attach();
    expect(await ch.status(), LiveSupport.unsupported);
    expect(
      (await ch.start(sessionId: 's', title: 't', hostId: 'h', lang: 'zh', state: const {})).error,
      LiveStartError.unsupported,
    );
    expect(await ch.update(sessionId: 's', state: const {}), isFalse);
    await ch.end(sessionId: 's');
    expect(await ch.list(), isEmpty);
    await ch.endAll();
    expect((await ch.takePendingTokens()).activities, isEmpty);
    expect(calls, isEmpty);
    await ch.dispose();
  });

  test('iOS: payloads and answers', () async {
    debugRemoteOnlyOverride = true;
    answer = (call) => switch (call.method) {
      'status' => {'supported': true, 'enabled': true, 'pushToStart': true, 'frequentUpdates': false},
      'start' => {'activityId': 'act-1'},
      'list' => [
        {'sessionId': 's1', 'activityId': 'act-1', 'state': 'active'},
        {'sessionId': 'bad id!', 'activityId': 'x', 'state': 'active'},
        {'sessionId': 's2', 'activityId': 'act-2', 'state': 'weird'},
      ],
      'takePendingTokens' => {
        'activities': [
          {'sessionId': 's1', 'token': 'AB' * 32},
          {'sessionId': 's2', 'token': 'not hex'},
        ],
        'pushToStart': 'cd' * 32,
      },
      _ => null,
    };
    final ch = LiveActivityChannel();
    expect(await ch.status(), const LiveSupport(supported: true, enabled: true, pushToStart: true));
    final r = await ch.start(sessionId: 's1', title: 'T', hostId: 'h', lang: 'en', state: const {'phase': 'running'});
    expect(r.activityId, 'act-1');
    expect(calls.last.arguments, {
      'sessionId': 's1',
      'title': 'T',
      'hostId': 'h',
      'lang': 'en',
      'state': {'phase': 'running'},
    });
    await ch.update(sessionId: 's1', state: const {'step': 2}, alert: (title: 'a', body: 'b'));
    expect(calls.last.arguments, {
      'sessionId': 's1',
      'state': {'step': 2},
      'alert': {'title': 'a', 'body': 'b'},
    });
    await ch.end(sessionId: 's1', dismissal: LiveDismissal.after4s);
    expect(calls.last.arguments, {'sessionId': 's1', 'dismissal': 'after4s'});
    await ch.endAll(dismissal: LiveDismissal.system);
    expect(calls.last.arguments, {'dismissal': 'default'});
    final list = await ch.list();
    expect(list.map((a) => a.sessionId), ['s1']);
    final tokens = await ch.takePendingTokens();
    expect(tokens.activities, [(sessionId: 's1', token: 'ab' * 32)]);
    expect(tokens.pushToStart, 'cd' * 32);
  });

  test('iOS: start errors, update not-found', () async {
    debugRemoteOnlyOverride = true;
    answer = (call) => switch (call.method) {
      'start' => throw PlatformException(code: 'disabled'),
      'update' => throw PlatformException(code: 'not-found'),
      _ => null,
    };
    final ch = LiveActivityChannel();
    expect(
      (await ch.start(sessionId: 's', title: '', hostId: '', lang: 'zh', state: const {})).error,
      LiveStartError.disabled,
    );
    expect(await ch.update(sessionId: 's', state: const {}), isFalse);
    answer = (call) => throw PlatformException(code: 'exists', details: {'activityId': 'act-9'});
    expect((await ch.start(sessionId: 's', title: '', hostId: '', lang: 'zh', state: const {})).activityId, 'act-9');
  });

  test('iOS: native calls in', () async {
    debugRemoteOnlyOverride = true;
    final ch = LiveActivityChannel();
    final tokens = <LivePushToken>[];
    final starts = <String>[];
    final states = <LiveStateChange>[];
    final decisions = <LiveDecision>[];
    ch.pushTokens.listen(tokens.add);
    ch.pushToStartTokens.listen(starts.add);
    ch.activityStates.listen(states.add);
    ch.decisions.listen(decisions.add);
    await ch.handle(MethodCall('onPushToken', {'sessionId': 's1', 'token': 'AB' * 32}));
    await ch.handle(const MethodCall('onPushToken', {'sessionId': 's1', 'token': 'zz'}));
    await ch.handle(MethodCall('onPushToStartToken', {'token': 'ef' * 40}));
    await ch.handle(const MethodCall('onActivityState', {'sessionId': 's1', 'state': 'dismissed'}));
    await ch.handle(
      const MethodCall('onDecision', {'sessionId': 's1', 'eventId': 'ev1', 'decision': 'allow', 'result': 'ok'}),
    );
    // A stop has no event: Swift sends an empty eventId.
    await ch.handle(
      const MethodCall('onDecision', {'sessionId': 's1', 'eventId': '', 'decision': 'stop', 'result': 'ok'}),
    );
    await pumpEventQueue();
    expect(tokens, [(sessionId: 's1', token: 'ab' * 32)]);
    expect(starts, ['ef' * 40]);
    expect(states.single.state, LiveActivityPhase.dismissed);
    expect(states.single.state.over, isTrue);
    expect(decisions, [
      (sessionId: 's1', eventId: 'ev1', decision: 'allow', result: 'ok'),
      (sessionId: 's1', eventId: '', decision: 'stop', result: 'ok'),
    ]);
    expect(() => ch.handle(const MethodCall('nope')), throwsA(isA<MissingPluginException>()));
  });
}
