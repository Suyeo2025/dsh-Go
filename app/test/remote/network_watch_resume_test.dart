// How long the app was away is known by the time the resume kick arrives, so
// a direct link can tell "back after a while" from a quick switch.

import 'dart:ui' show AppLifecycleState;

import 'package:dsh_app/remote/network_watch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // The test binding passes states through as given; walk them one step at a
  // time the way the engine does (AppLifecycleListener checks the order).
  void lifecycle(List<AppLifecycleState> states) => states.forEach(binding.handleAppLifecycleStateChanged);
  const leave = [AppLifecycleState.inactive, AppLifecycleState.hidden];
  const leaveFully = [...leave, AppLifecycleState.paused];
  const back = [AppLifecycleState.inactive, AppLifecycleState.resumed];
  const backFully = [AppLifecycleState.hidden, ...back];

  test('hidden → wait → resumed: lastAway covers the wait and is set before the kick', () async {
    lifecycle([AppLifecycleState.resumed]);
    final seen = <Duration?>[];
    final sub = networkKicks().listen((_) => seen.add(appSuspension.lastAway));
    addTearDown(sub.cancel);

    lifecycle(leave);
    const wait = Duration(milliseconds: 120);
    await Future<void>.delayed(wait);
    lifecycle(back);
    await Future<void>.delayed(Duration.zero);

    expect(seen, hasLength(1));
    expect(seen.single, isNotNull);
    expect(seen.single!, greaterThanOrEqualTo(wait));
    expect(appSuspension.lastAway, seen.single);

    // A second round measures from its own leave, not the first one.
    lifecycle(leaveFully);
    lifecycle(backFully);
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(2));
    expect(seen.last!, lessThan(wait));
  });

  group('AppSuspension', () {
    late DateTime now;
    late AppSuspension s;
    setUp(() {
      now = DateTime(2026, 11, 5, 8);
      s = AppSuspension(now: () => now);
    });

    test('nothing before the first resume, or for a resume without a leave', () {
      expect(s.lastAway, isNull);
      s.markResumed();
      expect(s.lastAway, isNull);
    });

    test('the earliest of inactive / hidden / paused counts', () {
      s.markLeft();
      now = now.add(const Duration(seconds: 5));
      s.markLeft();
      now = now.add(const Duration(seconds: 20));
      s.markResumed();
      expect(s.lastAway, const Duration(seconds: 25));
    });

    test('only for the resume that just happened (a later network kick is not a resume)', () {
      s.markLeft();
      now = now.add(const Duration(minutes: 2));
      s.markResumed();
      expect(s.lastAway, const Duration(minutes: 2));
      now = now.add(AppSuspension.fresh + const Duration(milliseconds: 1));
      expect(s.lastAway, isNull);
    });

    test('a clock set backwards reads as not away', () {
      s.markLeft();
      now = now.subtract(const Duration(hours: 1));
      s.markResumed();
      expect(s.lastAway, Duration.zero);
    });
  });
}
