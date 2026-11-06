// What the chat page's running indicators cost in frames (iOS heat report):
// the whale tail steps at its sprite's own frame rate instead of every vsync,
// a breathing status dot steps about 8 times a second, and with animations
// off in the system neither asks for frames. Counted at 120 Hz (8 ms steps),
// as a ProMotion screen would draw.

import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/common/fluid_bits.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/frame_counter.dart';
import 'support/harness.dart';

const _hz120 = Duration(milliseconds: 8);

Future<void> _pump(WidgetTester tester, Widget child, {bool reduced = false}) async {
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
  });

  group('whale tail', () {
    for (final (level, most) in [(2, 40), (3, 60), (4, 60)]) {
      testWidgets('level $level: its sprite rate, not every vsync', (tester) async {
        await _pump(tester, WhaleTail(level: level, color: deepSeekBlue));
        final frames = await framesOver(tester, const Duration(seconds: 1), step: _hz120);
        // Every vsync would be 125.
        expect(frames, inInclusiveRange(10, most));
      });
    }

    testWidgets('animations off: the still frame, no frames', (tester) async {
      await _pump(tester, const WhaleTail(level: 4, color: deepSeekBlue), reduced: true);
      expect(await framesOver(tester, const Duration(seconds: 1), step: _hz120), 0);
    });

    testWidgets('its page covered: holds, no frames', (tester) async {
      await _pump(tester, const TickerMode(enabled: false, child: WhaleTail(level: 4, color: deepSeekBlue)));
      expect(await framesOver(tester, const Duration(seconds: 1), step: _hz120), 0);
    });

    testWidgets('the levels still swim at different speeds', (tester) async {
      // Sprite frames covered in a second of the same form (level 0–2 share it).
      Future<double> swim(int level) async {
        await _pump(tester, WhaleTail(key: ValueKey(level), level: level, color: deepSeekBlue));
        final whale = tester.state<WhaleTailState>(find.byType(WhaleTail));
        var covered = 0.0;
        var last = whale.frame;
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 125));
          final now = whale.frame;
          covered += (now - last) % 24;
          last = now;
        }
        return covered;
      }

      final slow = await swim(0);
      final mid = await swim(1);
      final fast = await swim(2);
      expect(slow, lessThan(mid));
      expect(mid, lessThan(fast));
    });
  });

  group('quiet arc (a running tool)', () {
    testWidgets('turns about 12 steps a second, not every vsync', (tester) async {
      await _pump(tester, const QuietArc(color: deepSeekBlue));
      // Every vsync would be 250.
      final frames = await framesOver(tester, const Duration(seconds: 2), step: _hz120);
      expect(frames, inInclusiveRange(18, 30));
    });

    testWidgets('with breathing dots beside it: the same dozen frames', (tester) async {
      await _pump(
        tester,
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            QuietArc(color: deepSeekBlue),
            StatusDot(tone: StatusTone.busy),
            QuietArc(color: deepSeekBlue),
            StatusDot(tone: StatusTone.busy),
          ],
        ),
      );
      final frames = await framesOver(tester, const Duration(seconds: 2), step: _hz120);
      expect(frames, inInclusiveRange(18, 30));
    });

    // A running turn: the tool's arc, the strip's whale tail and the header's
    // dot all step on one clock, so together they still cost about 12 frames
    // a second instead of the whale's own rate on top.
    for (final level in [0, 1, 2, 3, 4]) {
      testWidgets('with the whale tail at level $level and a busy dot: the same dozen frames', (tester) async {
        await _pump(
          tester,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const QuietArc(color: deepSeekBlue),
              WhaleTail(level: level, color: deepSeekBlue),
              const StatusDot(tone: StatusTone.busy),
            ],
          ),
        );
        final frames = await framesOver(tester, const Duration(seconds: 2), step: _hz120);
        expect(frames, inInclusiveRange(18, 30));
      });
    }

    testWidgets('animations off: holds, no frames', (tester) async {
      await _pump(tester, const QuietArc(color: deepSeekBlue), reduced: true);
      expect(await framesOver(tester, const Duration(seconds: 2), step: _hz120), 0);
    });

    testWidgets('its page covered: holds, no frames', (tester) async {
      await _pump(tester, const TickerMode(enabled: false, child: QuietArc(color: deepSeekBlue)));
      expect(await framesOver(tester, const Duration(seconds: 2), step: _hz120), 0);
    });
  });

  group('status dot', () {
    testWidgets('busy: about 12 steps a second', (tester) async {
      await _pump(tester, const StatusDot(tone: StatusTone.busy));
      final frames = await framesOver(tester, const Duration(seconds: 2), step: _hz120);
      expect(frames, inInclusiveRange(18, 30));
    });

    testWidgets('busy, three at once: still about 12 frames a second', (tester) async {
      await _pump(
        tester,
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(tone: StatusTone.busy),
            StatusDot(tone: StatusTone.busy),
            StatusDot(tone: StatusTone.busy),
          ],
        ),
      );
      final frames = await framesOver(tester, const Duration(seconds: 2), step: _hz120);
      expect(frames, inInclusiveRange(18, 30));
    });

    testWidgets('busy, pulse off: no frames', (tester) async {
      await _pump(tester, const StatusDot(tone: StatusTone.busy, pulse: false));
      expect(await framesOver(tester, const Duration(seconds: 2), step: _hz120), 0);
    });

    testWidgets('busy, animations off: no frames', (tester) async {
      await _pump(tester, const StatusDot(tone: StatusTone.busy), reduced: true);
      expect(await framesOver(tester, const Duration(seconds: 2), step: _hz120), 0);
    });

    testWidgets('the pulse still breathes between 1 and 0.35', (tester) async {
      await _pump(tester, const StatusDot(tone: StatusTone.busy));
      final seen = <double>[];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        seen.add(
          tester.widget<Opacity>(find.descendant(of: find.byType(StatusDot), matching: find.byType(Opacity))).opacity,
        );
      }
      expect(seen.reduce((a, b) => a < b ? a : b), lessThan(0.45));
      expect(seen.reduce((a, b) => a > b ? a : b), greaterThan(0.9));
    });
  });
}
