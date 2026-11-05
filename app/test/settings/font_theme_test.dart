// 设置 › 主题 › 字体 in the theme: a chosen font names every text style the app
// draws text with (type ladder, buttons, menus, dialogs…), keeps the system
// CJK fonts as fallback, and leaves code monospace and icons on their own
// fonts. The system font leaves the theme exactly as before.

import 'package:dsh_app/state/font_state.dart';
import 'package:dsh_app/ui/settings/appearance/font_picker.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _kai = 'LXGW WenKai';

List<TextStyle?> _ladder(TextTheme t) => [
  t.displayLarge,
  t.displayMedium,
  t.displaySmall,
  t.headlineLarge,
  t.headlineMedium,
  t.headlineSmall,
  t.titleLarge,
  t.titleMedium,
  t.titleSmall,
  t.bodyLarge,
  t.bodyMedium,
  t.bodySmall,
  t.labelLarge,
  t.labelMedium,
  t.labelSmall,
];

/// The component text styles built from the ladder in app_theme.dart.
List<TextStyle?> _components(ThemeData theme) => [
  theme.appBarTheme.titleTextStyle,
  theme.filledButtonTheme.style?.textStyle?.resolve({}),
  theme.outlinedButtonTheme.style?.textStyle?.resolve({}),
  theme.textButtonTheme.style?.textStyle?.resolve({}),
  theme.elevatedButtonTheme.style?.textStyle?.resolve({}),
  theme.chipTheme.labelStyle,
  theme.dialogTheme.titleTextStyle,
  theme.dialogTheme.contentTextStyle,
  theme.snackBarTheme.contentTextStyle,
  theme.popupMenuTheme.textStyle,
  theme.listTileTheme.titleTextStyle,
  theme.listTileTheme.subtitleTextStyle,
  theme.tooltipTheme.textStyle,
  theme.tabBarTheme.labelStyle,
  theme.badgeTheme.textStyle,
  theme.navigationBarTheme.labelTextStyle?.resolve({}),
];

void main() {
  for (final (name, build) in [('light', buildLightTheme), ('dark', buildDarkTheme)]) {
    group(name, () {
      test('WenKai: the whole ladder, primaryTextTheme and every component style use it', () {
        final theme = build(sansFamily: _kai);
        for (final style in [..._ladder(theme.textTheme), ..._ladder(theme.primaryTextTheme), ..._components(theme)]) {
          expect(style, isNotNull);
          expect(style!.fontFamily, _kai);
          expect(style.fontFamilyFallback, AppType.sansFallback);
        }
        // The system CJK sans stays behind it for anything WenKai lacks.
        expect(AppType.sansFallback, containsAll(['PingFang SC', 'Noto Sans CJK SC']));
      });

      test('WenKai: code stays monospace, metrics stay the ladder', () {
        final theme = build(sansFamily: _kai);
        final mono = AppType.mono();
        expect(mono.fontFamily, AppType.monoFamily);
        expect(mono.fontFamilyFallback, AppType.monoFallback);
        // A code style laid over the body text keeps its own family.
        expect(theme.textTheme.bodyMedium!.merge(mono).fontFamily, AppType.monoFamily);
        expect(theme.textTheme.bodyLarge!.fontSize, AppType.textTheme.bodyLarge!.fontSize);
        expect(theme.textTheme.titleMedium!.fontWeight, FontWeight.w600);
      });

      test('system font: no family or fallback added anywhere', () {
        final theme = build();
        final same = build(sansFamily: null);
        for (final (a, b) in [for (final (i, s) in _ladder(theme.textTheme).indexed) (s, _ladder(same.textTheme)[i])]) {
          expect(a, b);
          expect(a!.fontFamily, isNot(_kai));
          expect(a.fontFamilyFallback, isNull);
        }
        for (final style in _components(theme)) {
          expect(style?.fontFamily, isNull);
          expect(style?.fontFamilyFallback, isNull);
        }
      });
    });
  }

  testWidgets('icons keep their own font under WenKai', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(sansFamily: _kai),
        home: const Scaffold(body: Icon(AppIcons.selected)),
      ),
    );
    final text = tester.widget<RichText>(find.descendant(of: find.byType(Icon), matching: find.byType(RichText)));
    expect(text.text.style!.fontFamily, AppIcons.selected.fontFamily);
    expect(text.text.style!.fontFamily, isNot(_kai));
  });

  testWidgets('text in a WenKai app draws in WenKai; the picker\'s system sample does not', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(sansFamily: _kai),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                const Text('正文'),
                FilledButton(onPressed: () {}, child: const Text('按钮')),
                Text('系统', style: systemSampleStyle(context)),
              ],
            ),
          ),
        ),
      ),
    );
    TextStyle styleOf(String text) =>
        tester.widget<RichText>(find.descendant(of: find.text(text), matching: find.byType(RichText))).text.style!;
    expect(styleOf('正文').fontFamily, _kai);
    expect(styleOf('按钮').fontFamily, _kai);
    expect(styleOf('系统').fontFamily, isNull);
  });

  test('the sans family follows the setting', () {
    expect(const FontState().family, isNull);
    expect(
      const FontState(chosen: AppFont.wenkai, phase: FontPhase.ready).family,
      isNull,
      reason: 'not registered yet',
    );
    expect(
      const FontState(chosen: AppFont.wenkai, phase: FontPhase.ready, registered: true).family,
      wenKaiRelease.family,
    );
    expect(const FontState(chosen: AppFont.wenkai, phase: FontPhase.broken, registered: true).family, isNull);
  });
}
