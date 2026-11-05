// 字体 lives on the settings hub's 外观 group (one tap from 设置), no longer a
// level down on 设置 › 主题; its search trail follows: 设置 › 外观 › 字体.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/settings/appearance/font_picker.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 6000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      goldenApp(
        home: home,
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

  testWidgets('the hub\'s 外观 group has the 字体 row, after 主题 and before the text size', (tester) async {
    await pump(tester, const SettingsScreen());
    final font = find.byType(FontEntryTile);
    expect(font, findsOneWidget);
    expect(find.descendant(of: font, matching: find.text(_zh.fontTitle)), findsOneWidget);
    expect(find.descendant(of: font, matching: find.text(_zh.fontSystem)), findsOneWidget);
    // The same card as 主题 (one group, one SettingsSection).
    final group = find.ancestor(of: font, matching: find.byType(SettingsSection)).first;
    expect(find.descendant(of: group, matching: find.byType(AppearanceEntryTile)), findsOneWidget);
    expect(find.descendant(of: group, matching: find.text(_zh.hubSettingsChatTextSize)), findsOneWidget);
    final y = tester.getTopLeft(font).dy;
    expect(tester.getTopLeft(find.byType(AppearanceEntryTile)).dy, lessThan(y));
    expect(tester.getTopLeft(find.text(_zh.hubSettingsChatTextSize)).dy, greaterThan(y));
    // It carries its icon, like its neighbours.
    expect(find.descendant(of: font, matching: find.byType(SettingsIcon)), findsOneWidget);
  });

  testWidgets('设置 › 主题 no longer has it', (tester) async {
    await pump(tester, const AppearancePage());
    expect(find.byType(FontEntryTile), findsNothing);
    expect(find.text(_zh.fontTitle), findsNothing);
  });

  test('the spot is the hub\'s, in 外观: 设置 › 外观 › 字体', () {
    expect(Spots.font.page, SettingsPageId.hub);
    expect([...SettingsIndex.path(Spots.font, _zh), Spots.font.title(_zh)], ['设置', '外观', '字体']);
    expect(SettingsIndex.path(Spots.font, _en), ['Settings', _en.hubSettingsAppearance]);
    expect(SettingsIndex.on(SettingsPageId.hub), contains(Spots.font));
    expect(SettingsIndex.on(SettingsPageId.appearance), isNot(contains(Spots.font)));
    expect(SettingsIndex.has(Spots.font), isTrue);
  });

  testWidgets('without a tint the row is plain, as before (alone on a page)', (tester) async {
    await pump(tester, const Scaffold(body: SettingsSection(children: [FontEntryTile()])));
    expect(find.byType(FontEntryTile), findsOneWidget);
    expect(find.byType(SettingsIcon), findsNothing);
  });
}
