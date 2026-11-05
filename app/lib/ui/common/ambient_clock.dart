// One clock for the small "something is going on" animations (the breathing
// status dot, the quiet arc on a running tool): they step on it about 12
// times a second instead of following every vsync, and all of them together
// cost those 12 frames a second, not one stream of frames each. The timer
// runs only while something listens.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// The shared step clock. [value] counts steps since the first listener came.
class AmbientClock extends ValueNotifier<int> {
  AmbientClock._() : super(0);

  static final instance = AmbientClock._();

  /// One step: 1/12 s.
  static const step = Duration(microseconds: 83333);

  Timer? _timer;

  /// Time on this clock: steps × [step].
  Duration get elapsed => step * value;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(step, (_) => value++);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (hasListeners) return;
    _timer?.cancel();
    _timer = null;
    value = 0;
  }
}
