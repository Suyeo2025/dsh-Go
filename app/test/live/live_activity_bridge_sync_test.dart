// The bridge side of the「鲸游」Live Activity: what goes to dsh-watch-bridge
// (body shapes of the three routes), push-to-start only in 前后台都显示, a
// network failure retried once, and nothing without a pairing or off iOS.
// Every token here is fake.

import 'dart:convert';

import 'package:dsh_app/live/island_prefs_state.dart';
import 'package:dsh_app/live/live_activity_bridge_sync.dart';
import 'package:dsh_app/live/live_activity_content.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/bridge_client.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push/bridge_client_test.dart' show FakeBridge;

final _laToken = 'ab' * 40;
final _startToken = 'cd' * 40;
final _t0 = DateTime.utc(2026, 11, 6, 8);

final _content = IslandContent(
  title: '重构登录模块',
  phase: IslandPhase.running,
  startedAt: _t0,
  expectedEndAt: _t0.add(const Duration(minutes: 15)),
  step: 3,
  toolLabel: '运行 Bash',
);

Map<String, (int, Object?)> _routes() => {
  'GET /v1/device': (200, {'deviceId': 'd-1', 'push': null, 'invalid': false}),
  'PUT /v1/device/live-activity': (204, null),
  'DELETE /v1/device/live-activity/s1': (204, null),
  'PUT /v1/device/live-activity/start-token': (204, null),
  'DELETE /v1/device/live-activity/start-token': (204, null),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBridge bridge;
  late MemorySecretStore secrets;
  var network = false;

  setUp(() {
    network = false;
    bridge = FakeBridge(_routes());
    secrets = MemorySecretStore({PushController.deviceTokenKey: 'device-secret'});
    SharedPreferences.setMockInitialValues({
      PushController.prefsKey: jsonEncode({
        'bridge': 'https://watch.example.com',
        'hostId': 'direct-1',
        'deviceId': 'd-1',
      }),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pushMethodChannel,
      (_) async => null,
    );
  });

  tearDown(() {
    debugRemoteOnlyOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pushMethodChannel, null);
  });

  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        bridgeClientFactoryProvider.overrideWithValue(
          (base, {pin}) => BridgeClient(
            base,
            pinSha256: pin,
            transport: (method, url, {required headers, body, pinSha256}) {
              if (network) throw const BridgeException('network');
              return bridge.send(method, url, headers: headers, body: body, pinSha256: pinSha256);
            },
          ),
        ),
        liveBridgeRetryDelayProvider.overrideWithValue(const Duration(milliseconds: 20)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<LiveActivityBridgeSync> ready(ProviderContainer c) async {
    await c.read(pushProvider.notifier).ready;
    await c.read(islandPrefsProvider.notifier).ready;
    await pumpEventQueue();
    bridge.calls.clear();
    return c.read(liveActivityBridgeSyncProvider);
  }

  List<String> calls() => [for (final c in bridge.calls) '${c.method} ${c.url.path}'];

  group('iOS', () {
    setUp(() => debugRemoteOnlyOverride = true);

    test('an Activity token is registered with its snapshot, and forgotten', () async {
      final c = make();
      final sync = await ready(c);
      await sync.onPushToken('s1', _laToken, content: _content, lang: 'zh', clockOffsetMs: -1500);
      expect(calls(), ['PUT /v1/device/live-activity']);
      final call = bridge.calls.single;
      expect(call.headers['authorization'], 'Bearer device-secret');
      final body = call.json;
      expect(body.keys.toSet(), {'sessionId', 'token', 'lang', 'clockOffsetMs', 'snapshot', 'startedAtMs'});
      expect(body['sessionId'], 's1');
      expect(body['token'], _laToken);
      expect(body['lang'], 'zh');
      expect(body['clockOffsetMs'], -1500);
      expect(body['startedAtMs'], _t0.millisecondsSinceEpoch);
      final snapshot = body['snapshot'] as Map;
      expect(snapshot['phase'], 'running');
      expect(snapshot['startedAt'], _t0.millisecondsSinceEpoch ~/ 1000);
      expect(snapshot['title'], '重构登录模块');
      expect(snapshot['others'], isEmpty);

      // The same token again: nothing to send.
      await sync.onPushToken('s1', _laToken, content: _content, lang: 'zh', clockOffsetMs: -1500);
      expect(bridge.calls, hasLength(1));

      await sync.forget('s1');
      expect(calls().last, 'DELETE /v1/device/live-activity/s1');
      expect(sync.registered, isEmpty);
    });

    test('push-to-start only in 前后台都显示; switching away deletes it', () async {
      final c = make();
      final sync = await ready(c);
      await sync.onPushToStartToken(_startToken);
      expect(bridge.calls, isEmpty, reason: '仅前台启动 is the default');

      await c.read(islandPrefsProvider.notifier).setMode(IslandMode.always);
      await sync.onModeChanged(IslandMode.always);
      expect(calls(), ['PUT /v1/device/live-activity/start-token']);
      expect(bridge.calls.single.json, {'token': _startToken, 'lang': 'zh'});

      await c.read(islandPrefsProvider.notifier).setMode(IslandMode.foreground);
      await sync.onModeChanged(IslandMode.foreground);
      expect(calls().last, 'DELETE /v1/device/live-activity/start-token');
    });

    test('a network failure is tried again once', () async {
      final c = make();
      final sync = await ready(c);
      network = true;
      await sync.onPushToken('s1', _laToken, content: _content, lang: 'en', clockOffsetMs: 0);
      expect(bridge.calls, isEmpty);
      network = false;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue();
      expect(calls(), ['PUT /v1/device/live-activity']);
      expect(bridge.calls.single.json['lang'], 'en');
    });

    test('resync sends everything again; clear tells the bridge, unpair does not', () async {
      final c = make();
      final sync = await ready(c);
      await c.read(islandPrefsProvider.notifier).setMode(IslandMode.always);
      await sync.onPushToken('s1', _laToken, content: _content, lang: 'zh', clockOffsetMs: 0);
      await sync.onPushToStartToken(_startToken);
      bridge.calls.clear();

      await sync.resync();
      expect(calls(), ['PUT /v1/device/live-activity', 'PUT /v1/device/live-activity/start-token']);

      bridge.calls.clear();
      await sync.clear(remote: false);
      expect(bridge.calls, isEmpty);
      expect(sync.registered, isEmpty);
      expect(sync.pushToStartToken, isNull);

      await sync.onPushToken('s1', _laToken, content: _content, lang: 'zh', clockOffsetMs: 0);
      await sync.onPushToStartToken(_startToken);
      bridge.calls.clear();
      await sync.clear();
      expect(calls(), ['DELETE /v1/device/live-activity/s1', 'DELETE /v1/device/live-activity/start-token']);
    });

    test('without a pairing nothing is sent, and resync after pairing sends it', () async {
      SharedPreferences.setMockInitialValues({});
      final c = make();
      final sync = await ready(c);
      await sync.onPushToken('s1', _laToken, content: _content, lang: 'zh', clockOffsetMs: 0);
      expect(bridge.calls, isEmpty);
      expect(sync.registered, ['s1'], reason: 'kept for the next resync');
    });
  });

  test('Android: no call at all', () async {
    final c = make();
    final sync = c.read(liveActivityBridgeSyncProvider);
    await sync.onPushToken('s1', _laToken, content: _content, lang: 'zh', clockOffsetMs: 0);
    await sync.onPushToStartToken(_startToken);
    await sync.resync();
    await sync.clear();
    expect(bridge.calls, isEmpty);
    expect(sync.registered, isEmpty);
  });
}
