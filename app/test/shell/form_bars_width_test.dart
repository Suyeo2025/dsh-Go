// The form pages' bottom bars (RemoteFormBar: 测试连接 / 保存 of the host
// forms; FormBottomBar: 保存 of 个人偏好 and the provider forms) keep their
// keys in the page's column on a wide window, the fill still edge to edge.
//
//   flutter test test/shell/form_bars_width_test.dart

import 'package:dsh_app/ui/providers/provider_widgets.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

const _remoteKey = ValueKey('remote-bar-key');
const _formKey = ValueKey('form-bar-key');

Widget _page() => Scaffold(
  body: Stack(
    children: [
      const Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: RemoteFormBar(
          children: [
            Expanded(
              child: OutlinedButton(key: _remoteKey, onPressed: null, child: Text('测试连接')),
            ),
          ],
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: FormBottomBar(
          child: FilledButton(key: _formKey, onPressed: () {}, child: const Text('保存')),
        ),
      ),
    ],
  ),
);

void _window(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width, 800) * 2;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('1024 wide: the keys stay within the column, centred; the bars span the window', (tester) async {
    _window(tester, 1024);
    await tester.pumpWidget(testApp(_page()));
    for (final key in [_remoteKey, _formKey]) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.width, lessThanOrEqualTo(AppPage.contentWidth), reason: '$key');
      // 16 in from the column's edges, which are centred.
      expect(rect.width, AppPage.contentWidth - 32, reason: '$key');
      expect(rect.center.dx, closeTo(512, 0.5), reason: '$key');
    }
    expect(tester.getSize(find.byType(RemoteFormBar)).width, 1024);
    expect(tester.getSize(find.byType(FormBottomBar)).width, 1024);
    // Sized to its content, not stretched over the page.
    expect(tester.getSize(find.byType(FormBottomBar)).height, lessThan(FormBottomBar.height + 40));
  });

  testWidgets('390 wide: as before, the whole width less the margins', (tester) async {
    _window(tester, 390);
    await tester.pumpWidget(testApp(_page()));
    for (final key in [_remoteKey, _formKey]) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.left, 16, reason: '$key');
      expect(rect.width, 390 - 32, reason: '$key');
    }
  });
}
