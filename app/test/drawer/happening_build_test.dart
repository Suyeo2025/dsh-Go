// 正在发生 when a run ends while the list is hidden (the pulled-over drawer
// closed: TickerMode off pauses its subscriptions): shown again, the list
// catches up inside a widget's build, and the row that just ended must not be
// settled by writing a provider in that build (Riverpod's "Tried to modify a
// provider while the widget tree was building", seen in the iPhone smoke
// run). It shows as done in that same frame, lingers, then leaves.
//
//   flutter test test/drawer/happening_build_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/happening_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/session_run_clock.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show FakeCurrentSession, sampleNow;
import 'support.dart' show FixedPending;

SessionSummary _s(String id, {bool running = false}) => SessionSummary(
  sessionId: id,
  updatedAt: sampleNow,
  running: running,
  blank: false,
  agentAvailable: running,
  projections: SessionProjections(1, {'title': 'T-$id'}),
);

/// The Host's rows, as a test sets them.
class _Source extends Notifier<List<SessionSummary>> {
  @override
  List<SessionSummary> build() => [_s('a', running: true)];

  void set(List<SessionSummary> rows) => state = rows;
}

final _source = NotifierProvider<_Source, List<SessionSummary>>(_Source.new);

/// Shown or hidden, like the pulled-over drawer (TickerMode off pauses its
/// providers' subscriptions).
class _Shown extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool shown) => state = shown;
}

final _shown = NotifierProvider<_Shown, bool>(_Shown.new);

class _NoClock extends SessionRunClock {
  @override
  Map<String, DateTime> build() => const {};
}

class _NoFeed extends HappeningFeedController {
  @override
  Map<String, RunDigest> build() => const {};
}

void main() {
  testWidgets('a run that ended while the list was hidden settles as it builds again, then lingers', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          drawerScopeProvider.overrideWith((ref) {
            return DrawerScope(sessions: ref.watch(_source), bots: const [], scoped: false);
          }),
          pendingInteractionsProvider.overrideWith(() => FixedPending(const {})),
          happeningRequestsProvider.overrideWithValue(const {}),
          happeningCurrentRunProvider.overrideWithValue(null),
          currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
          sessionRunClockProvider.overrideWith(_NoClock.new),
          happeningFeedProvider.overrideWith(_NoFeed.new),
          drawerClockProvider.overrideWithValue(() => sampleNow),
          happeningLingerProvider.overrideWithValue(const Duration(seconds: 4)),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TickerMode(
              enabled: ref.watch(_shown),
              child: Consumer(
                key: const ValueKey('list'),
                builder: (context, ref, _) {
                  final rows = ref.watch(happeningProvider);
                  return Column(children: [for (final e in rows) Text('${e.sessionId}:${e.phase.name}')]);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('a:running'), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byKey(const ValueKey('list'))));
    // Hidden: the list's subscriptions pause, and the run ends meanwhile.
    container.read(_shown.notifier).set(false);
    await tester.pump();
    container.read(_source.notifier).set([_s('a')]);
    await tester.pump();
    // Shown again: the list catches up in this build.
    container.read(_shown.notifier).set(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('a:done'), findsOneWidget, reason: 'in the same frame, no gap');
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('a:done'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('a:done'), findsNothing);
    expect(find.textContaining('a:'), findsNothing);
  });
}
