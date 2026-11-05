// 设置 › 界面 › 生成中发送: the row shows the choice, the sheet writes it,
// 跟随主机 says what the host keeps, and settings search finds the row.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/state/busy_send_state.dart';
import 'package:dsh_app/state/provider_keys.dart' show providerKeyVaultProvider;
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/settings/busy_send_tile.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show testApp, usePhoneView;
import '../performance/support.dart' show FakePerformanceChannel, snapshot;
import '../providers/support.dart' show MemoryProviderKeyVault;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> pump(WidgetTester tester, {String? host}) async {
    usePhoneView(tester);
    final channel = FakePerformanceChannel(Future.value(snapshot(DeviceTier.high)));
    addTearDown(channel.events.close);
    await tester.pumpWidget(
      testApp(
        Scaffold(body: BusySendTile(spot: Spots.busySend)),
        overrides: [
          performanceChannelProvider.overrideWithValue(channel),
          hostBusyEnterProvider.overrideWithValue(host),
          providerKeyVaultProvider.overrideWithValue(MemoryProviderKeyVault()),
        ],
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(BusySendTile)));
    // The real controller loads its preferences; the key store answers
    // outside the fake clock.
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !container.read(settingsProvider).loaded; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).loaded, isTrue);
    return container;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(BusySendTile));
    await tester.pumpAndSettle();
  }

  testWidgets('the row shows the choice; each of the three is written and kept', (tester) async {
    final container = await pump(tester, host: 'queue');
    expect(find.text('生成中发送'), findsOneWidget);
    expect(find.text('跟随主机'), findsOneWidget);

    for (final (key, label, want) in [
      ('steer', '总是插话', BusySendOverride.steer),
      ('queue', '总是排队', BusySendOverride.queue),
      ('followHost', '跟随主机', BusySendOverride.followHost),
    ]) {
      await open(tester);
      await tester.tap(find.byKey(ValueKey('busy-send-$key')));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).busySendOverride, want);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('busy_send_override'), want.name);
      // The sheet closed; the row says the new choice.
      expect(find.byKey(ValueKey('busy-send-$key')), findsNothing);
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('the choice in use is checked', (tester) async {
    SharedPreferences.setMockInitialValues({'busy_send_override': 'queue'});
    await pump(tester);
    expect(find.text('总是排队'), findsOneWidget);
    await open(tester);
    bool checked(String key) => tester
        .widget<Semantics>(
          find.ancestor(of: find.byKey(ValueKey('busy-send-$key')), matching: find.byType(Semantics)).first,
        )
        .properties
        .checked!;
    expect(checked('queue'), isTrue);
    expect(checked('steer'), isFalse);
    expect(checked('followHost'), isFalse);
  });

  for (final (host, line) in [('queue', '主机当前：排队'), ('steer', '主机当前：插话'), (null, '主机未提供，按插话')]) {
    testWidgets('跟随主机 says what the host keeps: $host', (tester) async {
      await pump(tester, host: host);
      await open(tester);
      expect(find.text('与网页版「AI 工作时发送」一致；$line'), findsOneWidget);
      expect(find.text('不打断，AI 下一步会看到'), findsOneWidget);
      expect(find.text('等本轮结束后再发'), findsOneWidget);
    });
  }

  test('settings search finds 生成中发送 on 界面, in both languages', () {
    final zh = lookupL10n(AppLocale.zhCN);
    final en = lookupL10n(AppLocale.en);
    List<String?> ids(String q) => [
      for (final h in searchSettings(q, spots: SettingsIndex.spots, features: featureSections, zh: zh, en: en))
        h.spot?.id,
    ];
    expect(ids('生成中发送').first, 'busy-send');
    expect(ids('send while generating').first, 'busy-send');
    expect(ids('排队'), contains('busy-send'));
    expect(SettingsIndex.spot('busy-send')!.page, SettingsPageId.interface);
  });
}
