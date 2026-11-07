// 定时任务提醒 (plan/design/notify-v3-contract.md §3.3): failures by default,
// per-task choices stored and handed to the bridge whole; and the
// Notification Service Extension's key (§4.3) handed over on launch, taken
// back on unpairing. Every token here is fake.

import 'dart:convert';

import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/bridge_client.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/push/schedule_notify_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge_client_test.dart' show FakeBridge;

final _pairing = jsonEncode({'bridge': 'https://watch.example.com', 'hostId': 'direct-1', 'deviceId': 'd-1'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBridge bridge;
  late MemorySecretStore secrets;
  final native = <MethodCall>[];
  var network = false;

  setUp(() {
    network = false;
    native.clear();
    bridge = FakeBridge({
      'GET /v1/device': (200, {'deviceId': 'd-1', 'push': null, 'invalid': false}),
      'PUT /v1/device/schedule-notify': (204, null),
      'DELETE /v1/device': (204, null),
    });
    secrets = MemorySecretStore({PushController.deviceTokenKey: 'device-secret', PushController.keyPairKey: 'a2V5'});
    SharedPreferences.setMockInitialValues({PushController.prefsKey: _pairing});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pushMethodChannel, (
      call,
    ) async {
      native.add(call);
      return null;
    });
    debugRemoteOnlyOverride = true;
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
        scheduleNotifyRetryDelayProvider.overrideWithValue(const Duration(milliseconds: 20)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<ScheduleNotifyController> ready(ProviderContainer c) async {
    await c.read(pushProvider.notifier).ready;
    final n = c.read(scheduleNotifyProvider.notifier);
    await n.ready;
    await pumpEventQueue();
    bridge.calls.clear();
    return n;
  }

  List<String> calls() => [for (final c in bridge.calls) '${c.method} ${c.url.path}'];

  test('failures by default; a task that differs is stored and sent whole', () async {
    final c = make();
    final n = await ready(c);
    expect(c.read(scheduleNotifyProvider).fallback, ScheduleNotify.failures);
    expect(c.read(scheduleNotifyProvider).of('sch-1'), ScheduleNotify.failures);

    await n.setTask('sch-1', ScheduleNotify.always);
    expect(calls(), ['PUT /v1/device/schedule-notify']);
    expect(bridge.calls.single.json, {
      'default': 'failures',
      'tasks': {'sch-1': 'always'},
    });
    expect(bridge.calls.single.headers['authorization'], 'Bearer device-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(ScheduleNotifyController.prefsKey)!), {
      'default': 'failures',
      'tasks': {'sch-1': 'always'},
    });

    // Back to the default's value: the task's own entry goes.
    await n.setTask('sch-1', ScheduleNotify.failures);
    expect(bridge.calls.last.json, {'default': 'failures', 'tasks': <String, Object?>{}});

    await n.setDefault(ScheduleNotify.never);
    expect(bridge.calls.last.json['default'], 'never');
    expect(c.read(scheduleNotifyProvider).of('sch-2'), ScheduleNotify.never);

    // Not an id: ignored.
    bridge.calls.clear();
    await n.setTask('bad id', ScheduleNotify.always);
    expect(calls(), isEmpty);
  });

  test('a stored choice is read back; a network failure is tried again once', () async {
    SharedPreferences.setMockInitialValues({
      PushController.prefsKey: _pairing,
      ScheduleNotifyController.prefsKey: jsonEncode({
        'default': 'always',
        'tasks': {'sch-9': 'never', 'sch-x': 'bogus'},
      }),
    });
    final c = make();
    final n = await ready(c);
    final prefs = c.read(scheduleNotifyProvider);
    expect(prefs.fallback, ScheduleNotify.always);
    expect(prefs.tasks, {'sch-9': ScheduleNotify.never});

    network = true;
    expect(await n.sync(), isFalse);
    network = false;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls(), ['PUT /v1/device/schedule-notify']);
  });

  test('pairing / refresh send it only once something was chosen', () async {
    final c = make();
    final n = await ready(c);
    expect(await n.sync(ifChosen: true), isFalse);
    expect(calls(), isEmpty, reason: 'all default: the bridge assumes the same');
    await n.setDefault(ScheduleNotify.always);
    bridge.calls.clear();
    expect(await n.sync(ifChosen: true), isTrue);
    expect(calls(), ['PUT /v1/device/schedule-notify']);
  });

  test('not paired: kept here, nothing sent', () async {
    SharedPreferences.setMockInitialValues({});
    final c = make();
    final n = await ready(c);
    await n.setDefault(ScheduleNotify.always);
    expect(calls(), isEmpty);
    expect(c.read(scheduleNotifyProvider).fallback, ScheduleNotify.always);
  });

  test("the extension gets the key on launch (never the bridge token) and loses it on unpairing", () async {
    final c = make();
    await ready(c);
    final set = native.where((m) => m.method == 'setNotificationSecrets').toList();
    expect(set, hasLength(1));
    final args = set.single.arguments as Map;
    expect(args['privateKey'], 'a2V5');
    expect(args['deviceId'], 'd-1');
    expect(args['lang'], anyOf('zh', 'en'));
    expect(args.values, isNot(contains('device-secret')));

    await c.read(pushProvider.notifier).unpair();
    await pumpEventQueue();
    expect(native.map((m) => m.method), contains('clearNotificationSecrets'));
  });
}
