// The iPad share popover's anchor (lib/ui/common/share_origin.dart): the
// triggering widget's box on iOS; nothing at all elsewhere, so other
// platforms (Android, `flutter test`'s default) send the very same parameters.

import 'package:dsh_app/ui/common/share_origin.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  Future<BuildContext> pumpBox(WidgetTester tester, {required double width, required double height}) async {
    late BuildContext box;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 30, top: 40),
            child: Builder(
              builder: (context) {
                box = context;
                return SizedBox(width: width, height: height);
              },
            ),
          ),
        ),
      ),
    );
    return box;
  }

  testWidgets('Android: no origin, the parameters untouched', (tester) async {
    final context = await pumpBox(tester, width: 44, height: 44);
    expect(shareOriginOf(context), isNull);
    final params = ShareParams(text: 'hi');
    expect(identical(withShareOrigin(params, shareOriginOf(context)), params), isTrue);
  });

  testWidgets('iOS: the triggering box in global coordinates', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final context = await pumpBox(tester, width: 44, height: 44);
    expect(shareOriginOf(context), const Rect.fromLTWH(30, 40, 44, 44));
    expect(shareOriginOf(null), isNull, reason: 'share_plus centres the popover itself');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS: a box that is the whole screen anchors nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final context = await pumpBox(tester, width: size.width - 30, height: size.height - 40);
    expect(shareOriginOf(context), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  test('withShareOrigin copies every field and keeps an origin already set', () {
    final file = XFile.fromData(Uint8List(1), name: 'a.png');
    final params = ShareParams(
      text: 't',
      subject: 's',
      title: 'ti',
      files: [file],
      fileNameOverrides: ['a.png'],
      downloadFallbackEnabled: false,
      mailToFallbackEnabled: false,
    );
    const origin = Rect.fromLTWH(1, 2, 3, 4);
    final out = withShareOrigin(params, origin);
    expect(out.sharePositionOrigin, origin);
    expect(out.text, 't');
    expect(out.subject, 's');
    expect(out.title, 'ti');
    expect(out.files, same(params.files));
    expect(out.fileNameOverrides, ['a.png']);
    expect(out.downloadFallbackEnabled, isFalse);
    expect(out.mailToFallbackEnabled, isFalse);
    final set = ShareParams(text: 'x', sharePositionOrigin: origin);
    expect(identical(withShareOrigin(set, const Rect.fromLTWH(9, 9, 9, 9)), set), isTrue);
    expect(identical(withShareOrigin(params, null), params), isTrue);
  });
}
