// 设置 › 主题 › 字体: the row says which font is in use, and the sheet shows
// both choices with WenKai's download state (size before, 已下载 · 删除 after,
// 需要重新下载 when its files are gone).

import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/font_state.dart';
import 'package:dsh_app/ui/settings/appearance/font_picker.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late List<String> registered;

  const release = FontRelease(
    id: 'test-font-1.0',
    family: 'Test Kai',
    version: '1.0',
    files: [FontFileSpec(name: 'Kai-Regular.ttf', bytes: 8, sha256: 'unused')],
    sources: [FontSource('a', 'https://example.invalid/{file}')],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('dsh-font-picker');
    registered = [];
  });
  tearDown(() => root.deleteSync(recursive: true));

  void install() {
    final dir = Directory('${root.path}/fonts/${release.id}')..createSync(recursive: true);
    File('${dir.path}/Kai-Regular.ttf').writeAsBytesSync([0, 1, 0, 0, 1, 2, 3, 4]);
  }

  Future<ProviderContainer> pump(WidgetTester tester, Widget child) async {
    final container = ProviderContainer(
      overrides: [
        fontEnvironmentProvider.overrideWithValue(
          FontEnvironment(
            release: release,
            directory: () async => Directory('${root.path}/fonts'),
            register: (family, _) async => registered.add(family),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() => container.read(fontProvider.notifier).ready);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    return container;
  }

  testWidgets('not downloaded: both choices with the sample, WenKai with its size', (tester) async {
    await pump(tester, const FontSheet());
    final l10n = appL10n;
    expect(find.text(l10n.fontTitle), findsOneWidget);
    expect(find.text(l10n.fontSystem), findsOneWidget);
    expect(find.text(l10n.fontWenKai), findsOneWidget);
    expect(find.text(l10n.fontSample), findsNWidgets(2));
    expect(find.text(l10n.fontDownloadSize('0')), findsOneWidget);
    // Not on the phone: its sample is in the system font too.
    for (final e in find.text(l10n.fontSample).evaluate()) {
      expect((e.widget as Text).style!.fontFamily, isNull);
    }
    expect(registered, isEmpty);
  });

  testWidgets('downloaded: its sample in WenKai, 已下载 with 删除, which removes it', (tester) async {
    install();
    final container = await pump(tester, const FontSheet());
    final l10n = appL10n;
    expect(registered, ['Test Kai'], reason: 'loaded for the sample');
    expect(find.text(l10n.fontDownloaded), findsOneWidget);
    final samples = [for (final e in find.text(l10n.fontSample).evaluate()) (e.widget as Text).style!.fontFamily];
    expect(samples, [null, 'Test Kai']);

    await tester.tap(find.byKey(const ValueKey('font-delete')));
    // Real file IO, continued in the test's zone: let both run a few rounds.
    final dir = Directory('${root.path}/fonts/${release.id}');
    for (var i = 0; i < 100 && (dir.existsSync() || container.read(fontProvider).phase != FontPhase.absent); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(container.read(fontProvider).phase, FontPhase.absent);
    expect(dir.existsSync(), isFalse);
    expect(find.text(l10n.fontDownloaded), findsNothing);
  });

  testWidgets('the row: the font in use, or 需要重新下载 when its files are gone', (tester) async {
    SharedPreferences.setMockInitialValues({FontController.prefKey: 'wenkai'});
    await pump(tester, const FontEntryTile());
    final l10n = appL10n;
    expect(find.text(l10n.fontTitle), findsOneWidget);
    expect(find.text('${l10n.fontWenKai} · ${l10n.fontNeedsDownload}'), findsOneWidget);
  });

  testWidgets('the row with WenKai in place and in use', (tester) async {
    install();
    SharedPreferences.setMockInitialValues({FontController.prefKey: 'wenkai'});
    final container = await pump(tester, const FontEntryTile());
    expect(container.read(appSansFamilyProvider), 'Test Kai');
    expect(find.text(appL10n.fontWenKai), findsOneWidget);
  });
}
