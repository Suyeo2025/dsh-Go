// Counts the frames a screen asks for while nobody touches it: time moves on
// in [step]s, and after each one the binding is asked whether anything
// (a ticker, a timer that repainted, a rebuild) scheduled a frame; that frame
// is then drawn. A screen at rest asks for none.

import 'package:flutter_test/flutter_test.dart';

/// Frames requested over [window], checked every [step] (16 ms ≈ 60 Hz).
Future<int> framesOver(WidgetTester tester, Duration window, {Duration step = const Duration(milliseconds: 16)}) async {
  var frames = 0;
  for (var t = Duration.zero; t < window; t += step) {
    await tester.binding.delayed(step);
    if (tester.binding.hasScheduledFrame) {
      frames++;
      await tester.pump();
    }
  }
  return frames;
}
