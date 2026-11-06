// 设置 › 推送通知 › 灵动岛 (remote-only builds): the three modes, the note
// when Live Activities are off in Settings, the pairing hint for 前后台都显示,
// the status row; Android keeps its 通知 page with 实时活动 and no island.

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/live/island_prefs_state.dart';
import 'package:dsh_app/live/live_activity_channel.dart';
import 'package:dsh_app/live/live_activity_state.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/bridge_client.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_settings_page.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/settings/notification_settings.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push/bridge_client_test.dart' show FakeBridge;
import '../push/push_state_test.dart' show FakeNative;
import '../shell/golden_harness.dart';

const _on = LiveSupport(supported: true, enabled: true, pushToStart: true);
const _systemOff = LiveSupport(supported: true, enabled: false);

void main() {
  late FakeNative native;
  late FakeBridge bridge;
  late MemorySecretStore secrets;

  setUp(() {
    debugRemoteOnlyOverride = true;
    native = FakeNative();
    bridge = FakeBridge({
      'GET /v1/device': (200, {'deviceId': 'd-1', 'push': null, 'invalid': false}),
    });
    secrets = MemorySecretStore();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pushMethodChannel,
      native.handle,
    );
  });

  tearDown(() {
    debugRemoteOnlyOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pushMethodChannel, null);
  });

  List<Override> overrides(LiveSupport support) => [
    secretStoreProvider.overrideWithValue(secrets),
    bridgeClientFactoryProvider.overrideWithValue(
      (base, {pin}) => BridgeClient(base, pinSha256: pin, transport: bridge.send),
    ),
    liveActivityStatusProvider.overrideWith((ref) async => support),
    islandLinksProvider.overrideWithValue((_) => () {}),
  ];

  Future<ProviderContainer> pump(WidgetTester tester, Widget home, {LiveSupport support = _on}) async {
    usePhoneSurface(tester);
    tester.view.physicalSize = const Size(390 * 2, 2400 * 2);
    await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides(support)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  SettingsSegmentTile<IslandMode> modeTile(WidgetTester tester) =>
      tester.widget<SettingsSegmentTile<IslandMode>>(find.byKey(const ValueKey('island-mode')));

  testWidgets('remote-only: the three modes, 仅前台 by default; 前后台都显示 asks for pairing', (tester) async {
    final c = await pump(tester, const PushSettingsPage());
    final l10n = appL10n;
    expect(find.text(l10n.laSettingsSection), findsOneWidget);
    for (final label in [l10n.laSettingsModeOff, l10n.laSettingsModeForeground, l10n.laSettingsModeAlways]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text(l10n.laSettingsFooter), findsOneWidget);
    final tile = modeTile(tester);
    expect(tile.selected, IslandMode.foreground);
    expect(tile.onChanged, isNotNull);
    expect(find.byKey(const ValueKey('island-system-off')), findsNothing);
    // Registered in the settings index, on this page.
    expect(SettingsIndex.has(Spots.islandMode), isTrue);
    expect(
      find.byWidgetPredicate((w) => w is SpotAnchor && w.spot.id == Spots.islandMode.id, skipOffstage: false),
      findsOneWidget,
    );

    tile.onChanged!(IslandMode.always);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(c.read(islandPrefsProvider).mode, IslandMode.always);
    expect((await SharedPreferences.getInstance()).getString(IslandPrefsController.prefsKey), 'always');
    expect(find.byKey(const ValueKey('island-needs-pairing')), findsOneWidget);

    modeTile(tester).onChanged!(IslandMode.off);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(c.read(islandPrefsProvider).mode, IslandMode.off);
    expect(find.byKey(const ValueKey('island-needs-pairing')), findsNothing);
  });

  testWidgets('Live Activities off in Settings: greyed out, with the way to the switch', (tester) async {
    await pump(tester, const PushSettingsPage(), support: _systemOff);
    expect(find.byKey(const ValueKey('island-system-off')), findsOneWidget);
    expect(find.text(appL10n.laSettingsSystemOffText), findsOneWidget);
    expect(find.byKey(const ValueKey('island-open-system')), findsOneWidget);
    expect(modeTile(tester).onChanged, isNull);
  });

  testWidgets('an iPad (no Live Activities): off and greyed out, says why', (tester) async {
    await pump(tester, const PushSettingsPage(), support: LiveSupport.unsupported);
    expect(find.text(appL10n.laSettingsUnsupported), findsOneWidget);
    expect(modeTile(tester).selected, IslandMode.off);
    expect(modeTile(tester).onChanged, isNull);
  });

  testWidgets('paired: the status row says how the island stands', (tester) async {
    SharedPreferences.setMockInitialValues({
      PushController.prefsKey: jsonEncode({
        'bridge': 'https://watch.example.com',
        'hostId': 'direct-1',
        'deviceId': 'd-1',
      }),
      IslandPrefsController.prefsKey: 'always',
    });
    secrets.values[PushController.deviceTokenKey] = 'device-secret';
    await pump(tester, const PushSettingsPage());
    expect(find.byKey(const ValueKey('push-unpair')), findsOneWidget);
    expect(find.text(appL10n.laSettingsIslandMode), findsWidgets);
    expect(find.text(appL10n.laSettingsStatusIdle), findsOneWidget);
    expect(find.byKey(const ValueKey('island-needs-pairing')), findsNothing);
  });

  testWidgets('Android: no island, the 通知 page keeps 实时活动', (tester) async {
    debugRemoteOnlyOverride = false;
    expect(SettingsIndex.has(Spots.islandMode), isFalse);
    await pump(tester, const NotificationSettingsPage());
    expect(find.byKey(const ValueKey('island-mode')), findsNothing);
    expect(find.text(appL10n.laSettingsSection), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is SpotAnchor && w.spot.id == Spots.notifyLive.id, skipOffstage: false),
      findsOneWidget,
    );
  });
}
