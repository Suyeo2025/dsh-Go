// The share card follows 设置 › 主题 › 字体: its theme (cached per template
// and palette) carries the app's current text font, so the exported PNG is
// drawn in it, and a font change in the same run is not served a stale theme.

import 'dart:io';

import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_export.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A family the test engine really has, unlike the system default: drawn
/// differently from the CJK sans the tests otherwise use.
const _probe = 'Probe Sans';

Future<void> _drainUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

Future<Uint8List> _capture(WidgetTester tester, GlobalKey key) async {
  Uint8List? png;
  final capture = captureShareCard(key).then((value) => png = value);
  await _drainUntil(tester, () => png != null);
  await capture;
  return png!;
}

void main() {
  setUpAll(() async {
    final loader = FontLoader(_probe)
      ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/JetBrainsMono-Regular.ttf').readAsBytesSync())));
    await loader.load();
  });
  tearDown(() => AppType.sansFamily = null);

  test('the cached theme follows the current font', () {
    final system = ShareCard.themeFor(ShareTemplate.light);
    expect(system.textTheme.bodyMedium!.fontFamily, isNot(_probe));
    AppType.sansFamily = _probe;
    final chosen = ShareCard.themeFor(ShareTemplate.light);
    expect(chosen.textTheme.bodyMedium!.fontFamily, _probe);
    expect(chosen.textTheme.titleLarge!.fontFamily, _probe);
    AppType.sansFamily = null;
    expect(ShareCard.themeFor(ShareTemplate.light), same(system));
  });

  testWidgets('the exported image is drawn in the chosen font', (tester) async {
    final key = GlobalKey();
    await pumpShareCard(
      tester,
      ShareCard(content: sampleReplyContent(), template: ShareTemplate.light),
      boundary: key,
    );
    final before = await _capture(tester, key);

    AppType.sansFamily = _probe;
    await pumpShareCard(
      tester,
      ShareCard(content: sampleReplyContent(), template: ShareTemplate.light),
      boundary: key,
    );
    final title = tester.widget<RichText>(
      find.descendant(of: find.byKey(const ValueKey('share-title')), matching: find.byType(RichText)).first,
    );
    expect(title.text.style!.fontFamily, _probe);
    final after = await _capture(tester, key);
    expect(after, isNot(equals(before)));
  });
}
