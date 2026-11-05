// The pill on a narrow screen: a long tool name beside the turn clock and the
// todo progress ends in an ellipsis instead of overflowing (iPhone smoke run:
// `terminal_send` in 76 pt), and a short title still leaves the detail all
// the room that is left.

import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

final _now = DateTime(2026, 10, 20, 15);

RunActivity _tool(String title, {String detail = ''}) => RunActivity(
  kind: ActivityKind.tool,
  title: title,
  detail: detail,
  detailIsCode: true,
  since: _now.subtract(const Duration(seconds: 9)),
  turnStart: _now.subtract(const Duration(seconds: 47)),
  todoDone: 3,
  todoTotal: 5,
);

Future<void> _pump(WidgetTester tester, RunActivity activity, double width) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(800, 400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: ActivityStrip(activity: activity),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester, 4);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
  });

  setUp(() => runClock = () => _now);
  tearDown(() => runClock = DateTime.now);

  testWidgets('a long title in a narrow pill ends in an ellipsis', (tester) async {
    await _pump(tester, _tool('terminal_send_with_a_rather_long_name', detail: 'echo hi'), 220);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('terminal_send'), findsOneWidget);
  });

  testWidgets('a short title leaves the detail the rest of the line', (tester) async {
    const detail = 'flutter test test/auth/login_controller_test.dart';
    await _pump(tester, _tool('跑', detail: detail), 400);
    expect(tester.takeException(), isNull);
    final title = tester.getRect(find.text('跑'));
    final copy = tester.getRect(find.text(detail, findRichText: true));
    expect(copy.left - title.right, moreOrLessEquals(6, epsilon: 0.01));
    // Wider than half the line: the detail is not capped at an equal share.
    final line = tester.getRect(find.byType(ActivityStrip));
    expect(copy.width, greaterThan(line.width / 3));
  });
}
