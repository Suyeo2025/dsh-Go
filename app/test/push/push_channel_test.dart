import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_tap_host.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PushRoute', () {
    test('reads a version-1 dg dictionary', () {
      expect(
        PushRoute.fromMap({'v': 1, 'k': 'approval', 's': 'sess-1', 'e': 'ev-1'}),
        const PushRoute(kind: PushKind.approval, sessionId: 'sess-1', eventId: 'ev-1'),
      );
      expect(PushRoute.fromMap({'v': 1, 'k': 'done', 's': 'sess-1'})?.kind, PushKind.done);
    });

    test('rejects other versions, unknown kinds and odd ids', () {
      expect(PushRoute.fromMap({'v': 2, 'k': 'done', 's': 's'}), isNull);
      expect(PushRoute.fromMap({'v': 1, 'k': 'explode', 's': 's'}), isNull);
      expect(PushRoute.fromMap('nope'), isNull);
      expect(PushRoute.fromMap({'v': 1, 'k': 'done', 's': '../x y'})?.sessionId, isNull);
    });
  });

  test('PushToken keeps only hex tokens with a known environment', () {
    final hex = 'a' * 64;
    expect(PushToken.fromMap({'token': hex, 'env': 'production'})?.env, 'production');
    expect(PushToken.fromMap({'token': hex, 'env': 'staging'}), isNull);
    expect(PushToken.fromMap({'token': 'XYZ', 'env': 'sandbox'}), isNull);
    // The token itself never shows in logs.
    expect(PushToken(hex, 'sandbox').toString(), isNot(contains(hex)));
  });

  test('native calls reach the streams; shouldPresent asks Dart', () async {
    final channel = PushChannel(const MethodChannel('test/push'));
    final taps = <PushRoute>[];
    final tokens = <PushToken>[];
    final errors = <String>[];
    channel.taps.listen(taps.add);
    channel.tokens.listen(tokens.add);
    channel.tokenErrors.listen(errors.add);

    await channel.handle(MethodCall('onToken', {'token': 'b' * 64, 'env': 'sandbox'}));
    await channel.handle(const MethodCall('onTokenError', {'code': 'no-entitlement'}));
    await channel.handle(const MethodCall('onTap', {'v': 1, 'k': 'question', 's': 'sess-2', 'e': 'ev-2'}));
    await channel.handle(const MethodCall('onTap', {'v': 9}));
    expect(await channel.handle(const MethodCall('shouldPresent', {'v': 1, 'k': 'done', 's': 'x'})), isTrue);
    channel.shouldPresent = (r) => r.sessionId != 'x';
    expect(await channel.handle(const MethodCall('shouldPresent', {'v': 1, 'k': 'done', 's': 'x'})), isFalse);
    await pumpEventQueue();

    expect(tokens.single.env, 'sandbox');
    expect(errors, ['no-entitlement']);
    expect(taps, [const PushRoute(kind: PushKind.question, sessionId: 'sess-2', eventId: 'ev-2')]);
    await channel.dispose();
  });

  test('without a native side every call is a quiet no-op', () async {
    final channel = PushChannel(const MethodChannel('test/absent'));
    expect((await channel.status()).auth, PushAuth.unsupported);
    expect(await channel.requestPermission(), isFalse);
    expect(await channel.takeLaunchTap(), isNull);
    await channel.register();
    await channel.clearDelivered('s');
    await channel.dispose();
  });

  test('status reads the native map', () async {
    const ch = MethodChannel('test/status');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
      if (call.method == 'getStatus') return {'auth': 'authorized', 'env': 'production', 'topic': 'com.colex.dshgo'};
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));
    final status = await PushChannel(ch).status();
    expect(status, const PushSystemStatus(auth: PushAuth.authorized, env: 'production', topic: 'com.colex.dshgo'));
    expect(status.auth.allowed, isTrue);
  });

  group('pushShowsBanner', () {
    const host = HostRef.direct('direct-1');
    const route = PushRoute(kind: PushKind.done, sessionId: 'sess-1');

    test('hides only the open conversation of the paired host, in the foreground', () {
      expect(pushShowsBanner(route, pairedHost: host, activeHost: host, openSession: 'sess-1', foreground: true), isFalse);
      expect(pushShowsBanner(route, pairedHost: host, activeHost: host, openSession: 'sess-2', foreground: true), isTrue);
      expect(
        pushShowsBanner(route, pairedHost: host, activeHost: HostRef.local, openSession: 'sess-1', foreground: true),
        isTrue,
      );
      expect(pushShowsBanner(route, pairedHost: host, activeHost: host, openSession: 'sess-1', foreground: false), isTrue);
      expect(pushShowsBanner(route, pairedHost: null, activeHost: host, openSession: 'sess-1', foreground: true), isTrue);
    });
  });
}
