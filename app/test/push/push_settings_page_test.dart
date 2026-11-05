import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/bridge_client.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_settings_page.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart' show DshCookie;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'bridge_client_test.dart' show FakeBridge;
import 'push_state_test.dart' show FakeNative;

void main() {
  late FakeNative native;
  late FakeBridge bridge;

  setUp(() {
    debugRemoteOnlyOverride = true;
    native = FakeNative();
    bridge = FakeBridge({
      'GET /v1/health': (200, {'api': [1]}),
      'POST /v1/pair/dsh': (200, {'deviceId': 'd-1', 'deviceToken': 'device-secret'}),
      'GET /v1/device': (200, {'deviceId': 'd-1', 'push': null, 'invalid': false}),
      'DELETE /v1/device': (204, null),
    });
    SharedPreferences.setMockInitialValues({
      HostsController.directPrefsKey: jsonEncode([
        {'id': 'direct-1', 'name': 'My server', 'baseUrl': 'https://dsh.example.com'},
      ]),
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

  testWidgets('turn on: pairs with the signed-in host, then shows where it stands', (tester) async {
    final secrets = MemorySecretStore({
      DirectSecrets.cookieKey('direct-1'): DirectSecrets.encodeCookie(
        const DshCookie(name: 'dsh-auth-abc', value: 'v1.p.s', authority: 'dsh.example.com'),
      ),
    });
    await tester.pumpWidget(
      goldenApp(
        home: const PushSettingsPage(),
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          bridgeClientFactoryProvider.overrideWithValue(
            (base, {pin}) => BridgeClient(base, pinSha256: pin, transport: bridge.send),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final l10n = appL10n;
    expect(find.text(l10n.pushEnable), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('push-bridge-url')), 'watch.example.com');
    // Pressed directly: the ink splash's shader isn't what this checks.
    tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('push-enable'))).onPressed!();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(bridge.calls.map((c) => '${c.method} ${c.url.path}'), containsAllInOrder(['GET /v1/health', 'POST /v1/pair/dsh']));
    expect(find.text(l10n.pushEnable), findsNothing);
    expect(find.text('watch.example.com'), findsOneWidget);
    expect(find.text('My server'), findsOneWidget);
    expect(find.byKey(const ValueKey('push-unpair')), findsOneWidget);
  });

  testWidgets('no direct host: says where to add one', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(goldenApp(home: const PushSettingsPage(), brightness: Brightness.light));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.pushNoDirectHost), findsOneWidget);
  });
}
