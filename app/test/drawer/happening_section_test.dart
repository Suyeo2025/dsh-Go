// 正在发生 on screen: the rows in their order with the right whale, edge and
// subtitle; the todo lane only with a todo list and never a percentage; no
// height when empty; 还有 N 个 past three; and the frames it costs: none with
// nothing timed, about one a second with a running timer, none with
// animations off or the drawer closed. A run that ends stays 4 s, then goes.
//
//   flutter test test/drawer/happening_section_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/happening_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/session_run_clock.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/common/ambient_clock.dart';
import 'package:dsh_app/ui/shell/drawer/happening_section.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import '../support/frame_counter.dart';
import 'sm_ui_support.dart';
import 'support.dart';

HappeningEntry _e(
  String id,
  HappeningPhase phase, {
  DateTime? startedAt,
  int? step,
  String? tool,
  String? pending,
  int done = 0,
  int total = 0,
}) => HappeningEntry(
  sessionId: id,
  title: 'T-$id',
  phase: phase,
  startedAt: startedAt,
  step: step,
  toolLabel: tool,
  pendingText: pending,
  todoDone: done,
  todoTotal: total,
);

/// The timers' seconds, on the test's fake time.
HappeningSeconds _seconds() => HappeningSeconds(clock: () => sampleNow.add(AmbientClock.instance.elapsed));

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<HappeningEntry>? entries,
  List<Override> overrides = const [],
  bool animations = true,
  bool shown = true,
  List<String>? opened,
  HappeningSeconds? seconds,
}) async {
  final clock = seconds ?? _seconds();
  addTearDown(clock.dispose);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      overrides: [
        if (entries != null) happeningProvider.overrideWithValue(entries),
        happeningFeedProvider.overrideWith(_NoFeed.new),
        ...overrides,
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: !animations),
            child: TickerMode(
              enabled: shown,
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: 320,
                  child: HappeningSection(seconds: clock, onOpen: (id) => opened?.add(id), onLongPress: (_) {}),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return ProviderScope.containerOf(tester.element(find.byType(HappeningSection)));
}

class _NoFeed extends HappeningFeedController {
  @override
  Map<String, RunDigest> build() => const {};
}

class _NoRunClock extends SessionRunClock {
  @override
  Map<String, DateTime> build() => const {};
}

class _Scope extends Notifier<DrawerScope?> {
  @override
  DrawerScope? build() => DrawerScope(sessions: [smSession('a', running: true)], bots: const [], scoped: false);

  void set(List<SessionSummary> sessions) => state = DrawerScope(sessions: sessions, bots: const [], scoped: false);
}

final _scope = NotifierProvider<_Scope, DrawerScope?>(_Scope.new);

String _whaleOf(WidgetTester tester, String id) {
  final row = find.byKey(ValueKey('happening-$id'));
  return tester.widget<HappeningWhale>(find.descendant(of: row, matching: find.byType(HappeningWhale))).frame;
}

void main() {
  testWidgets('rows in the given order, each with its whale, edge and line; a lane only with todos', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      opened: opened,
      entries: [
        _e('w', HappeningPhase.approval, pending: 'git push origin ios'),
        _e(
          'r',
          HappeningPhase.running,
          startedAt: sampleNow.subtract(const Duration(minutes: 12, seconds: 34)),
          step: 14,
          tool: '运行 Bash',
          done: 3,
          total: 5,
        ),
        _e('u', HappeningPhase.running),
      ],
    );
    expect(find.text('正在发生'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'the count');
    final ys = [
      for (final id in ['w', 'r', 'u']) tester.getTopLeft(find.byKey(ValueKey('happening-$id'))).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.text('等你确认 · git push origin ios'), findsOneWidget);
    expect(find.text('第 14 步 · 运行 Bash'), findsOneWidget);
    expect(find.text('12:34'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget, reason: 'step unknown: no number made up');
    expect(_whaleOf(tester, 'w'), 'approval');
    expect(_whaleOf(tester, 'r'), 'swim');
    // The amber edge on the waiting row only.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('happening-w')),
        matching: find.byKey(const ValueKey('happening-edge')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('happening-r')),
        matching: find.byKey(const ValueKey('happening-edge')),
      ),
      findsNothing,
    );
    // The lane: the todo list's share, no number.
    expect(find.byKey(const ValueKey('happening-lane')), findsOneWidget);
    final lane = tester.widget<FractionallySizedBox>(
      find.descendant(of: find.byKey(const ValueKey('happening-lane')), matching: find.byType(FractionallySizedBox)),
    );
    expect(lane.widthFactor, closeTo(0.6, 1e-9));
    expect(find.textContaining('%'), findsNothing);
    await tester.tap(find.text('T-r'));
    expect(opened, ['r']);
  });

  testWidgets('a running row reads its title, step, tool, time and todos', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      entries: [
        _e(
          'r',
          HappeningPhase.running,
          startedAt: sampleNow.subtract(const Duration(minutes: 12, seconds: 34)),
          step: 14,
          tool: '运行 Bash',
          done: 3,
          total: 5,
        ),
      ],
    );
    expect(find.bySemanticsLabel(RegExp('T-r.*第 14 步 · 运行 Bash.*已用 12 分 34 秒.*待办 3/5')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('done and failed: their whales and edges, no timer', (tester) async {
    await _pump(
      tester,
      entries: [
        _e('d', HappeningPhase.done, startedAt: sampleNow.subtract(const Duration(minutes: 3)), step: 7),
        _e('f', HappeningPhase.failed),
      ],
    );
    expect(_whaleOf(tester, 'd'), 'done');
    expect(_whaleOf(tester, 'f'), 'failed');
    expect(find.text('出错了'), findsOneWidget);
    expect(find.textContaining('做完了'), findsOneWidget);
  });

  testWidgets('nothing happening: no heading and no height', (tester) async {
    await _pump(tester, entries: const []);
    expect(find.text('正在发生'), findsNothing);
    expect(tester.getSize(find.byType(HappeningSection)).height, 0);
  });

  testWidgets('under 运行中 / 待确认 the list below is the same rows: none here', (tester) async {
    final container = await _pump(tester, entries: [_e('r', HappeningPhase.running)]);
    expect(find.text('正在发生'), findsOneWidget);
    for (final filter in [DrawerFilter.running, DrawerFilter.pending]) {
      container.read(drawerFilterProvider.notifier).set(filter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('正在发生'), findsNothing, reason: filter.name);
      expect(tester.getSize(find.byType(HappeningSection)).height, 0);
    }
    container.read(drawerFilterProvider.notifier).set(DrawerFilter.unread);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在发生'), findsOneWidget, reason: '未读 is another list');
  });

  testWidgets('past three rows: 还有 N 个, then all of them', (tester) async {
    await _pump(tester, entries: [for (var i = 0; i < 5; i++) _e('r$i', HappeningPhase.running)]);
    expect(find.byKey(const ValueKey('happening-r3')), findsNothing);
    await tester.tap(find.text('还有 2 个'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('happening-r4')), findsOneWidget);
  });

  group('frames', () {
    testWidgets('nothing timed (a waiting row, a run of unknown start): none', (tester) async {
      await _pump(tester, entries: [_e('w', HappeningPhase.approval), _e('u', HappeningPhase.running)]);
      expect(await framesOver(tester, const Duration(seconds: 3)), 0);
      expect(AmbientClock.instance.value, 0, reason: 'nothing listens: the shared clock is stopped');
    });

    testWidgets('a running timer: about one frame a second, the text moving on', (tester) async {
      await _pump(
        tester,
        entries: [_e('r', HappeningPhase.running, startedAt: sampleNow.subtract(const Duration(seconds: 10)))],
      );
      expect(find.text('00:10'), findsOneWidget);
      final frames = await framesOver(tester, const Duration(seconds: 3));
      expect(frames, inInclusiveRange(2, 4));
      expect(find.text('00:10'), findsNothing);
    });

    testWidgets('animations off: the time when built, no frames', (tester) async {
      await _pump(
        tester,
        animations: false,
        entries: [_e('r', HappeningPhase.running, startedAt: sampleNow.subtract(const Duration(seconds: 10)))],
      );
      expect(await framesOver(tester, const Duration(seconds: 3)), 0);
      expect(find.text('00:10'), findsOneWidget);
    });

    testWidgets('the drawer closed (TickerMode off): no frames, nothing followed', (tester) async {
      final container = await _pump(
        tester,
        shown: false,
        entries: [_e('r', HappeningPhase.running, startedAt: sampleNow.subtract(const Duration(seconds: 10)))],
      );
      expect(await framesOver(tester, const Duration(seconds: 3)), 0);
      expect(container.read(happeningVisibleProvider), isFalse);
    });

    testWidgets('shown: the other runs may be followed', (tester) async {
      final container = await _pump(tester, entries: const []);
      expect(container.read(happeningVisibleProvider), isTrue);
    });
  });

  testWidgets('a run that ends stays 4 s as done, then leaves', (tester) async {
    final container = await _pump(
      tester,
      overrides: [
        drawerScopeProvider.overrideWith((ref) => ref.watch(_scope)),
        pendingInteractionsProvider.overrideWith(() => FixedPending(const {})),
        happeningRequestsProvider.overrideWithValue(const {}),
        happeningCurrentRunProvider.overrideWithValue(null),
        currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
        sessionRunClockProvider.overrideWith(_NoRunClock.new),
      ],
    );
    expect(find.text('T-a'), findsOneWidget);
    container.read(_scope.notifier).set([smSession('a')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('做完了'), findsOneWidget);
    expect(_whaleOf(tester, 'a'), 'done');
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('T-a'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('T-a'), findsNothing);
    expect(find.text('正在发生'), findsNothing);
  });
}
