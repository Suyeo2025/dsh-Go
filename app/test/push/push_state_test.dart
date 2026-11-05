import 'dart:convert';

import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/bridge_client.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart' show DshCookie;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge_client_test.dart' show FakeBridge;

const _host = 'direct-1';
final _token = 'ab' * 32;

/// The native side: permission state and how often it was asked to register.
class FakeNative {
  String auth = 'notDetermined';
  int registers = 0;
  final cleared = <String>[];

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'getStatus':
        return {'auth': auth, 'env': 'production', 'topic': 'com.colex.dshgo'};
      case 'requestPermission':
        auth = 'authorized';
        return true;
      case 'register':
        registers++;
        return null;
      case 'takeLaunchTap':
        return null;
      case 'clearDelivered':
        cleared.add((call.arguments as Map)['sessionId'] as String);
        return null;
    }
    return null;
  }
}

Map<String, (int, Object?)> _okRoutes() => {
  'GET /v1/health': (200, {'api': [1]}),
  'POST /v1/pair/dsh': (200, {'deviceId': 'd-1', 'deviceToken': 'device-secret', 'network': 'public-tls'}),
  'POST /v1/pair': (200, {'deviceId': 'd-2', 'deviceToken': 'device-secret-2', 'network': 'public-tls'}),
  'PUT /v1/device/push': (204, null),
  'GET /v1/device': (
    200,
    {
      'deviceId': 'd-1',
      'push': {'mode': 'direct', 'env': 'production', 'topic': 'com.colex.dshgo'},
      'invalid': false,
    },
  ),
  'DELETE /v1/device': (204, null),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNative native;
  late FakeBridge bridge;
  late MemorySecretStore secrets;
  late DateTime now;

  setUp(() {
    debugRemoteOnlyOverride = true;
    native = FakeNative();
    bridge = FakeBridge(_okRoutes());
    now = DateTime(2026, 11, 4, 12);
    SharedPreferences.setMockInitialValues({
      HostsController.directPrefsKey: jsonEncode([
        {'id': _host, 'name': 'My server', 'baseUrl': 'https://dsh.example.com'},
      ]),
    });
    secrets = MemorySecretStore({
      DirectSecrets.cookieKey(_host): DirectSecrets.encodeCookie(
        const DshCookie(name: 'dsh-auth-abc', value: 'v1.p.s', authority: 'dsh.example.com'),
      ),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pushMethodChannel,
      native.handle,
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
          (base, {pin}) => BridgeClient(base, pinSha256: pin, transport: bridge.send),
        ),
        pushClockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<PushController> ready(ProviderContainer c) async {
    final n = c.read(pushProvider.notifier);
    await n.ready;
    return n;
  }

  Future<void> deliverToken(ProviderContainer c, String token) async {
    await c.read(pushChannelProvider).handle(MethodCall('onToken', {'token': token, 'env': 'production'}));
    await pumpEventQueue();
  }

  List<String> calls() => [for (final c in bridge.calls) '${c.method} ${c.url.path}'];

  test('pairing with the DSH session, then the token goes to the bridge once', () async {
    final c = make();
    final push = await ready(c);
    expect(c.read(pushProvider).health, PushHealth.off);

    await push.pairWithDsh('watch.example.com', _host);
    expect(calls(), ['GET /v1/health', 'POST /v1/pair/dsh']);
    final pair = bridge.calls[1].json;
    expect(pair['dshHost'], 'dsh.example.com');
    expect(pair['cookie'], 'dsh-auth-abc=v1.p.s');
    expect(pair['app'], 'dshgo');
    expect(pair['devicePub'] as String, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(await secrets.read(PushController.deviceTokenKey), 'device-secret');
    expect(native.registers, 1);
    expect(c.read(pushProvider).health, PushHealth.registering);
    expect(c.read(pushProvider).pairing!.bridge, 'https://watch.example.com');

    await deliverToken(c, _token);
    expect(calls().last, 'PUT /v1/device/push');
    expect(bridge.calls.last.headers['authorization'], 'Bearer device-secret');
    expect(bridge.calls.last.json, {
      'mode': 'direct',
      'apnsToken': _token,
      'env': 'production',
      'topic': 'com.colex.dshgo',
    });
    expect(c.read(pushProvider).health, PushHealth.on);

    // The same token again within a week: nothing to send.
    await deliverToken(c, _token);
    expect(calls().where((x) => x == 'PUT /v1/device/push'), hasLength(1));

    // A week later it is sent again; a new token is sent at once.
    now = now.add(const Duration(days: 8));
    await deliverToken(c, _token);
    await deliverToken(c, 'cd' * 32);
    expect(calls().where((x) => x == 'PUT /v1/device/push'), hasLength(3));

    // The pairing (not the token) survives a restart; the keypair is reused.
    final stored = jsonDecode((await SharedPreferences.getInstance()).getString(PushController.prefsKey)!) as Map;
    expect(stored.toString(), isNot(contains(_token)));
    expect(stored.toString(), isNot(contains('device-secret')));
    expect(stored['deviceId'], 'd-1');
  });

  test('a launch with a pairing registers again and checks the bridge', () async {
    native.auth = 'authorized';
    SharedPreferences.setMockInitialValues({
      PushController.prefsKey: jsonEncode({'bridge': 'https://watch.example.com', 'hostId': _host, 'deviceId': 'd-1'}),
    });
    await secrets.write(PushController.deviceTokenKey, 'device-secret');
    final c = make();
    await ready(c);
    await pumpEventQueue();
    expect(native.registers, 1);
    expect(calls(), contains('GET /v1/device'));
  });

  test('the bridge reporting the token gone re-registers; a revoked device says so', () async {
    native.auth = 'authorized';
    SharedPreferences.setMockInitialValues({
      PushController.prefsKey: jsonEncode({
        'bridge': 'https://watch.example.com',
        'hostId': _host,
        'deviceId': 'd-1',
        'tokenHash': 'x',
        'pushedAt': now.millisecondsSinceEpoch,
      }),
    });
    await secrets.write(PushController.deviceTokenKey, 'device-secret');
    bridge.routes['GET /v1/device'] = (200, {'deviceId': 'd-1', 'push': null, 'invalid': true});
    final c = make();
    final push = await ready(c);
    await pumpEventQueue();
    expect(c.read(pushProvider).health, PushHealth.tokenFailed);
    expect(native.registers, 2);
    expect(c.read(pushProvider).pairing!.tokenHash, '');

    bridge.routes['GET /v1/device'] = (
      401,
      {
        'error': {'code': 'device-revoked', 'message': 'device revoked'},
      },
    );
    await push.refresh();
    expect(c.read(pushProvider).health, PushHealth.revoked);
  });

  test('pairing problems come back as one reason', () async {
    final c = make();
    final push = await ready(c);
    Future<PushPairProblem?> problem(Future<void> Function() f) async {
      try {
        await f();
        return null;
      } on PushPairException catch (e) {
        return e.problem;
      }
    }

    expect(await problem(() => push.pairWithDsh('http://watch.example.com', _host)), PushPairProblem.bridgeUrlInvalid);
    expect(await problem(() => push.pairWithDsh('watch.example.com', 'direct-unknown')), PushPairProblem.noDirectHost);
    bridge.routes['POST /v1/pair/dsh'] = (
      401,
      {
        'error': {'code': 'unauthorized', 'message': 'dsh session rejected'},
      },
    );
    expect(await problem(() => push.pairWithDsh('watch.example.com', _host)), PushPairProblem.dshRejected);
    bridge.routes['POST /v1/pair/dsh'] = (
      409,
      {
        'error': {'code': 'not-applicable', 'message': 'off'},
      },
    );
    expect(await problem(() => push.pairWithDsh('watch.example.com', _host)), PushPairProblem.dshPairingOff);
    expect(await problem(() => push.pairWithLink('garbage', _host)), PushPairProblem.codeInvalid);
    await secrets.delete(DirectSecrets.cookieKey(_host));
    expect(await problem(() => push.pairWithDsh('watch.example.com', _host)), PushPairProblem.notSignedIn);
    expect(c.read(pushProvider).paired, isFalse);
    expect(c.read(pushProvider).busy, isFalse);
  });

  test('a pairing link pairs with its code; unpair tells the bridge and forgets', () async {
    final c = make();
    final push = await ready(c);
    await push.pairWithLink('dshwatch://pair?b=https%3A%2F%2Fwatch.example.com&c=K7M2P4QX&v=1', _host);
    expect(bridge.calls.last.json['code'], 'K7M2P4QX');
    expect(bridge.calls.last.json['app'], 'dshgo');
    expect(c.read(pushProvider).pairing!.deviceId, 'd-2');

    expect(await push.unpair(), isTrue);
    expect(calls().last, 'DELETE /v1/device');
    expect(c.read(pushProvider).paired, isFalse);
    expect(await secrets.read(PushController.deviceTokenKey), isNull);
    expect((await SharedPreferences.getInstance()).getString(PushController.prefsKey), isNull);
  });

  test('unpair without the bridge still forgets here and says so', () async {
    final c = make();
    final push = await ready(c);
    await push.pairWithDsh('watch.example.com', _host);
    bridge.routes.remove('DELETE /v1/device');
    bridge.routes['DELETE /v1/device'] = (503, {'error': {'code': 'dsh-unavailable', 'message': 'x'}});
    expect(await push.unpair(), isFalse);
    expect(c.read(pushProvider).paired, isFalse);
  });
}
