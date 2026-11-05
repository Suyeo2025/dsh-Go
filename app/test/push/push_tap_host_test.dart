import 'dart:convert';

import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/push/push_tap_host.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'push_state_test.dart' show FakeNative;

void main() {
  late FakeNative native;

  setUp(() {
    debugRemoteOnlyOverride = true;
    native = FakeNative();
    SharedPreferences.setMockInitialValues({
      PushController.prefsKey: jsonEncode({'bridge': 'https://watch.example.com', 'hostId': 'direct-1', 'deviceId': 'd-1'}),
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

  testWidgets('a tap opens the conversation on the paired host; unmounting is clean', (tester) async {
    final container = ProviderContainer(
      overrides: [secretStoreProvider.overrideWithValue(MemorySecretStore({PushController.deviceTokenKey: 'device-secret'}))],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: PushTapHost())),
      ),
    );
    await tester.runAsync(() => container.read(pushProvider.notifier).ready);
    await tester.pump();

    final channel = container.read(pushChannelProvider);
    await tester.runAsync(() async {
      await channel.handle(const MethodCall('onTap', {'v': 1, 'k': 'done', 's': 'sess-9'}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(container.read(activeHostProvider), const HostRef.direct('direct-1'));
    expect(container.read(currentSessionProvider), 'sess-9');
    expect(native.cleared, contains('sess-9'));
    // That conversation is on screen now: no banner for it.
    expect(channel.shouldPresent, isNotNull);

    // The whole tree goes (hot restart, engine rebuilt): no use of ref after unmount.
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    expect(channel.shouldPresent, isNull);
  });
}
