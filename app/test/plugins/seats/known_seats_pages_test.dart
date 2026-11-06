// The known third-party seats on the pages, on a host without the bridge
// (the official `dsh web` an iOS client connects to): a plugin's details lead
// to its settings sections, and 对话详情 › 插件 switches between a sidebar
// plugin's tabs in place.

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_seat_page.dart';
import 'package:dsh_app/ui/plugins/seats/session_plugins_tab.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../shell/golden_harness.dart';
import '../support/fake_plugin_host.dart';
import 'support.dart';

const _im = '@xmanrui/dsh-im';
const _sidebar = 'dsh-better-sidebar';

final _bundles = [
  PluginBundle.fromJson(bundleJson(_im, version: '5.9.1', title: {'zh': 'IM 机器人 (dsh-im)', 'en': 'IM bots'})),
  PluginBundle.fromJson(bundleJson(_sidebar, version: '0.28.2', title: {'zh': 'Better Sidebar', 'en': 'Better Sidebar'})),
];

SeatInventory _inventory() => SeatInventory(
  tier: ClientInventoryTier.boot,
  routeGuard: true,
  webReachable: true,
  packages: {
    for (final name in [_im, _sidebar])
      name: PluginClientInfo(package: name, hasClient: true, installed: true, enabled: true, rowIds: [name]),
  },
);

Future<void> _pump(WidgetTester tester, Widget home, {List<Override> extra = const []}) async {
  await tester.runAsync(loadGoldenFonts);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: home,
      brightness: Brightness.light,
      overrides: [
        ...extra,
        ...seatOverrides(inventory: _inventory(), budget: const OpenIslandBudget(), bundles: _bundles),
      ],
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

List<Override> _pluginHost() {
  final carrier = FakePluginCarrier();
  final client = DshClient.withCarrier(carrier);
  carrier.handlers['pluginManager/listBundles'] = (_) => const <Object?>[];
  addTearDown(client.close);
  return pluginOverrides(fakeHost(client), selectHost: false);
}

void main() {
  setUp(openedWeb.clear);

  testWidgets('dsh-im details: its IM settings section, no config row waiting for a slot it has not', (tester) async {
    await _pump(tester, const PluginsScreen(), extra: _pluginHost());
    await tester.tap(find.text('IM 机器人 (dsh-im)').first);
    await _settle(tester);
    expect(find.byType(BundleSheet), findsOneWidget);
    expect(find.text('设置'), findsNothing, reason: 'no plugins.bundle.config seat for dsh-im');
    final row = find.byKey(const ValueKey('plugin-section|xmanrui-dsh-im'));
    await tester.scrollUntilVisible(row, 120, scrollable: find.byType(Scrollable).last);
    expect(find.descendant(of: row, matching: find.text('IM机器人')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('网页版')), findsNothing);
    await tester.tap(row);
    await _settle(tester);
    expect(find.byType(PluginSeatPage), findsOneWidget);
    final spec = tester.widget<FakeIsland>(find.byType(FakeIsland)).spec;
    expect((spec.slot, spec.cell), (Slots.settingsSection, 'xmanrui-dsh-im'));
    expect(openedWeb, isEmpty);
  });

  testWidgets('对话详情 › 插件: Files, Git, Tasks, Side Chat switched in place', (tester) async {
    await _pump(tester, const Scaffold(body: SessionPluginsTab(sessionId: 's1')));
    final pill = tester.widget<SegmentedPill<int>>(find.byType(SegmentedPill<int>));
    expect([for (final s in pill.segments) s.label], ['文件', 'Git', '任务管理', '侧边对话(beta)']);
    expect(tester.widget<FakeIsland>(find.byType(FakeIsland)).spec.cell, 'dsh-better-sidebar:files');
    await tester.tap(find.text('Git'));
    await _settle(tester);
    final spec = tester.widget<FakeIsland>(find.byType(FakeIsland)).spec;
    expect((spec.slot, spec.cell, spec.sessionId), (Slots.rightPaneTab, 'dsh-better-sidebar:git', 's1'));
    expect(find.byType(FakeIsland), findsOneWidget);
  });

  testWidgets('a tab that can only open in DSH Web keeps the list', (tester) async {
    await tester.runAsync(loadGoldenFonts);
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(body: SessionPluginsTab(sessionId: 's1')),
        brightness: Brightness.light,
        overrides: seatOverrides(inventory: _inventory(), budget: const NoIslandBudget(), bundles: _bundles),
      ),
    );
    await _settle(tester);
    expect(find.byType(SegmentedPill<int>), findsNothing);
    expect(find.text('网页版'), findsNWidgets(4));
  });
}
