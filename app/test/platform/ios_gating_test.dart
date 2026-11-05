// The iOS (remote-only) build: Android's native layer is gated off without
// touching the Android path. `flutter test` reports Android, so each test
// flips the switches in platform_caps.dart and resets them afterwards.

import 'package:dsh_app/performance/performance_policy.dart';
import 'package:dsh_app/performance/refresh_rate.dart';
import 'package:dsh_app/platform/native_channel.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/settings/diagnostics_page.dart';
import 'package:dsh_app/ui/settings/direct_engine_settings.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_destination.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

void _asIos() {
  debugRemoteOnlyOverride = true;
  debugAndroidNativeOverride = false;
  addTearDown(() {
    debugRemoteOnlyOverride = null;
    debugAndroidNativeOverride = null;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('platform caps', () {
    test('flutter test reports Android: the native layer is there', () {
      expect(hasAndroidNativeLayer, isTrue);
      expect(isRemoteOnlyPlatform, isFalse);
    });

    test('follow the target platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(hasAndroidNativeLayer, isFalse);
      expect(isRemoteOnlyPlatform, isTrue);
    });
  });

  group('without the native layer', () {
    test('event channels stay quiet instead of activating a missing plugin', () async {
      _asIos();
      final channel = nativeEventChannel('dsh/runtime/events');
      expect(channel, isA<AbsentEventChannel>());
      var listened = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('dsh/runtime/events', (
        _,
      ) async {
        listened = true;
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
          'dsh/runtime/events',
          null,
        ),
      );
      final sub = RuntimeBridge().events.listen((_) => fail('no events'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(listened, isFalse);
    });

    test('the local runtime reads as loaded and not installed', () async {
      _asIos();
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
      );
      addTearDown(container.dispose);
      container.read(localRuntimeProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final state = container.read(localRuntimeProvider);
      expect(state.loaded, isTrue);
      expect(state.status.phase, RuntimePhase.notInstalled);
      expect(state.status.installedVersion, isNull);
    });

    test('the refresh-rate preference is never sent', () {
      _asIos();
      final calls = <MethodCall>[];
      const channel = MethodChannel('test/refresh-rate');
      final previous = RefreshRateService.channel;
      RefreshRateService.channel = channel;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        RefreshRateService.channel = previous;
        RefreshRateService.instance.resetForTest();
      });
      RefreshRateService.instance.resetForTest();
      RefreshRateService.instance.start();
      RefreshRateService.instance.setMode(RefreshRateMode.max);
      expect(calls, isEmpty);
    });

    test('no automatic APK update check', () async {
      _asIos();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(await container.read(appUpdateProvider.notifier).autoCheckIfDue(), isFalse);
    });

    test('settings index drops Android-only pages, their children and rows', () {
      expect(
        SettingsIndex.spots
            .where((s) => !SettingsIndex.remoteOnlyRows.any((r) => r.id == s.id))
            .where(
              (s) => !SettingsIndex.chain(s.isEntry ? s.opens! : s.page).any(SettingsIndex.remoteOnlyPages.contains),
            )
            .every(SettingsIndex.has),
        isTrue,
        reason: 'Android keeps everything but the remote-only rows and pages',
      );
      expect(SettingsIndex.has(Spots.addDirectHost), isFalse);
      _asIos();
      for (final id in [
        SettingsPageId.phone,
        SettingsPageId.phoneAppRules,
        SettingsPageId.phoneDnd,
        SettingsPageId.phoneUnlocks,
        SettingsPageId.engine,
        SettingsPageId.background,
        SettingsPageId.systemAccess,
        SettingsPageId.notifications,
        SettingsPageId.voice,
      ]) {
        expect(SettingsIndex.hasPage(id), isFalse, reason: id.name);
      }
      for (final id in [
        SettingsPageId.models,
        SettingsPageId.remote,
        SettingsPageId.appearance,
        SettingsPageId.about,
      ]) {
        expect(SettingsIndex.hasPage(id), isTrue, reason: id.name);
      }
      expect(SettingsIndex.has(Spots.appIcon), isFalse);
      expect(SettingsIndex.has(Spots.updateCheck), isFalse);
      expect(SettingsIndex.has(Spots.refreshRate), isFalse);
      expect(SettingsIndex.has(Spots.autoStart), isFalse, reason: 'on the engine page');
      expect(SettingsIndex.has(Spots.darkMode), isTrue);
    });

    test('the quick panel has no engine entry', () {
      const prefs = QuickPanelPrefs();
      expect(prefs.shown, contains(DrawerDestination.engine));
      _asIos();
      expect(DrawerDestination.engine.available, isFalse);
      expect(prefs.shown, isNot(contains(DrawerDestination.engine)));
      expect(prefs.shown, isNotEmpty);
    });

    testWidgets('the settings hub shows no engine, phone control or system rows', (tester) async {
      _asIos();
      // Tall enough that the whole (lazily built) hub is laid out.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 6000);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: const SettingsScreen(),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: RuntimeStatus.unknown())),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      Finder entry(SettingsPageId id) =>
          find.byWidgetPredicate((w) => w is SettingsTile && w.spot?.id == SettingsIndex.entry(id).id);
      for (final id in [
        SettingsPageId.phone,
        SettingsPageId.engine,
        SettingsPageId.background,
        SettingsPageId.systemAccess,
      ]) {
        expect(entry(id), findsNothing, reason: id.name);
      }
      expect(entry(SettingsPageId.models), findsOneWidget);
      expect(entry(SettingsPageId.remote), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('diagnostics shows no on-device runtime facts', (tester) async {
      Future<void> pump() async {
        await tester.pumpWidget(
          goldenApp(
            home: const DiagnosticsPage(),
            brightness: Brightness.light,
            overrides: [
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(const LocalRuntimeState(loaded: true, status: RuntimeStatus.unknown())),
              ),
              settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
      }

      await pump();
      expect(find.byType(RuntimeLaunchFacts), findsOneWidget, reason: 'Android keeps them');
      _asIos();
      await tester.pumpWidget(const SizedBox());
      await pump();
      expect(find.byType(RuntimeLaunchFacts), findsNothing);
      expect(find.byType(DirectEngineSettings), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
