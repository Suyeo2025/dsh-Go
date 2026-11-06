// 正在发生's data: the pure list (`happeningOf`: who is in it and in what
// order, what each row knows, todo progress, no made-up numbers), the rows
// that linger after a run ends, and the narrow follows of other running
// conversations (`happeningFeedProvider`: none while hidden, at most three,
// closed when the run stops, counts read from the frames).
//
//   flutter test test/drawer/happening_test.dart

import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/happening_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/session_run_clock.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/common/ambient_clock.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show FakeChatController;

final _now = DateTime(2026, 11, 6, 10);

SessionSummary _s(String id, {bool running = false, Duration age = Duration.zero, String? parent}) => SessionSummary(
  sessionId: id,
  updatedAt: _now.subtract(age),
  running: running,
  blank: false,
  agentAvailable: running,
  parentSessionId: parent,
  origin: parent == null ? null : 'subagent',
  projections: SessionProjections(1, {'title': 'T-$id'}),
);

List<String> _ids(List<HappeningEntry> list) => [for (final e in list) e.sessionId];

/// The scope the drawer would list; tests change it.
final _scope = NotifierProvider<_ScopeController, DrawerScope?>(_ScopeController.new);

class _ScopeController extends Notifier<DrawerScope?> {
  @override
  DrawerScope? build() => null;

  void set(List<SessionSummary> sessions) => state = DrawerScope(sessions: sessions, bots: const [], scoped: false);
}

class _Pending extends PendingInteractionsController {
  @override
  Map<String, PendingKind> build() => const {};
}

class _Current extends CurrentSessionController {
  @override
  String? build() => null;
}

Map<String, Object?> _event(String type, int seq, Map<String, Object?> data, {DateTime? at}) => {
  'type': 'event',
  'event': {'seq': seq, 'time': (at ?? _now).millisecondsSinceEpoch, 'type': type, 'data': data},
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('happeningOf', () {
    test('waiting first (approval, plan, question; earlier first), then running by start, longest first', () {
      final list = happeningOf(
        sessions: [
          _s('q', running: true),
          _s('r-late', running: true),
          _s('a2', running: true),
          _s('p'),
          _s('r-early', running: true),
          _s('a1'),
          _s('idle'),
        ],
        pending: const {
          'q': PendingKind.question,
          'a2': PendingKind.approval,
          'p': PendingKind.plan,
          'a1': PendingKind.approval,
        },
        requests: const {
          'a1': HappeningRequest(eventId: 'e1', kind: PendingKind.approval, order: 1),
          'a2': HappeningRequest(eventId: 'e2', kind: PendingKind.approval, order: 2),
        },
        runClock: {
          'r-late': _now.subtract(const Duration(minutes: 1)),
          'r-early': _now.subtract(const Duration(minutes: 9)),
        },
      );
      expect(_ids(list), ['a1', 'a2', 'p', 'q', 'r-early', 'r-late']);
      expect(list.first.phase, HappeningPhase.approval);
      expect(list.first.pendingEventId, 'e1');
      expect(list[2].phase, HappeningPhase.plan);
      expect(list[3].phase, HappeningPhase.question);
    });

    test('starts not known go last, newest activity first; subagents and idle ones stay out', () {
      final list = happeningOf(
        sessions: [
          _s('old', running: true, age: const Duration(minutes: 5)),
          _s('known', running: true, age: const Duration(minutes: 9)),
          _s('new', running: true, age: const Duration(minutes: 1)),
          _s('sub', running: true, parent: 'known'),
          _s('idle'),
        ],
        pending: const {},
        runClock: {'known': _now.subtract(const Duration(minutes: 2))},
      );
      expect(_ids(list), ['known', 'new', 'old']);
      expect(list.last.startedAt, isNull, reason: 'no timer: unknown, not "now"');
      expect(list.last.step, isNull);
      expect(happeningSubtitle(list.last, _now), '运行中');
    });

    test('the open conversation knows its step, tool and todos; another knows them from its follow', () {
      final list = happeningOf(
        sessions: [_s('mine', running: true), _s('other', running: true)],
        pending: const {},
        currentId: 'mine',
        current: CurrentRun(
          sessionId: 'mine',
          running: true,
          startedAt: _now.subtract(const Duration(minutes: 12, seconds: 34)),
          step: 14,
          toolLabel: '运行 Bash',
          todoDone: 3,
          todoTotal: 5,
          tokens: 900,
        ),
        digests: {
          'other': RunDigest(
            startedAt: _now.subtract(const Duration(minutes: 1)),
            step: 2,
            toolName: 'read',
            todoDone: 0,
            todoTotal: 0,
          ),
        },
      );
      final mine = list.firstWhere((e) => e.sessionId == 'mine');
      expect((mine.step, mine.toolLabel, mine.todoDone, mine.todoTotal, mine.tokens), (14, '运行 Bash', 3, 5, 900));
      expect(mine.hasTodos, isTrue);
      expect(happeningSubtitle(mine, _now), '第 14 步 · 运行 Bash');
      expect(happeningClock(mine.elapsedAt(_now)!), '12:34');
      final other = list.firstWhere((e) => e.sessionId == 'other');
      expect(other.step, 2);
      expect(other.toolLabel, happeningToolLabel('read'));
      expect(other.hasTodos, isFalse, reason: 'no todo list: nothing to draw');
      expect(other.tokens, isNull);
    });

    test('a digest of a turn that ended is not read for a new run', () {
      final list = happeningOf(
        sessions: [_s('x', running: true)],
        pending: const {},
        digests: {
          'x': RunDigest(startedAt: _now.subtract(const Duration(hours: 2)), step: 40, lastEndKind: 'completed'),
        },
      );
      expect((list.single.startedAt, list.single.step), (null, null));
    });

    test('an approval says what it is about, secrets masked, one short line', () {
      final list = happeningOf(
        sessions: [_s('a')],
        pending: const {'a': PendingKind.approval},
        requests: const {
          'a': HappeningRequest(eventId: 'e', kind: PendingKind.approval, order: 1, toolName: 'bash', callId: 'c1'),
        },
        digests: {
          'a': RunDigest(calls: {'c1': callTextOf('bash', '{"command":"git push origin ios\\nsecond line"}')!}),
        },
      );
      expect(list.single.pendingText, 'git push origin ios');
      expect(happeningSubtitle(list.single, _now), '等你确认 · git push origin ios');
      expect(happeningSnippet('a ' * 60)!.runes.length, HappeningEntry.pendingTextMax);
    });

    test('a run that just ended: done or failed, last; stopped by the person: gone', () {
      HappeningEntry ended(String id) => HappeningEntry(
        sessionId: id,
        title: id,
        phase: HappeningPhase.running,
        startedAt: _now.subtract(const Duration(minutes: 3)),
        step: 7,
        settledAt: _now,
      );
      final list = happeningOf(
        sessions: [_s('ok'), _s('bad'), _s('stopped'), _s('run', running: true)],
        pending: const {},
        digests: const {
          'ok': RunDigest(lastEndKind: 'completed'),
          'bad': RunDigest(lastEndKind: 'error'),
          'stopped': RunDigest(lastEndKind: 'aborted'),
        },
        settled: {'ok': ended('ok'), 'bad': ended('bad'), 'stopped': ended('stopped')},
      );
      expect(_ids(list), ['run', 'bad', 'ok']);
      expect(list[1].phase, HappeningPhase.failed);
      expect(list[2].phase, HappeningPhase.done);
      expect(happeningSubtitle(list[2], _now), '做完了 · 7 步 · 03:00');
    });
  });

  test('row timers step on the shared ambient clock, once a second, only while listened', () async {
    var t = _now;
    final seconds = HappeningSeconds(clock: () => t);
    var changes = 0;
    void listener() => changes++;
    seconds.addListener(listener);
    expect(seconds.value, _now.millisecondsSinceEpoch ~/ 1000);
    // Within the same second: ticks of the ambient clock change nothing.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(changes, 0);
    expect(AmbientClock.instance.value, greaterThan(0), reason: 'it rides the shared clock');
    t = t.add(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(changes, 1);
    seconds.removeListener(listener);
    expect(AmbientClock.instance.value, 0, reason: 'nobody listens: the shared clock stops');
    seconds.dispose();
  });

  group('providers', () {
    late ProviderContainer container;
    late List<String> opened;
    late Map<String, StreamController<Object?>> frames;
    late List<String> cancelled;

    void setUpContainer({Duration linger = const Duration(milliseconds: 60), bool connected = true}) {
      opened = [];
      cancelled = [];
      frames = {};
      final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
      addTearDown(client.close);
      container = ProviderContainer(
        overrides: [
          drawerScopeProvider.overrideWith((ref) => ref.watch(_scope)),
          pendingInteractionsProvider.overrideWith(_Pending.new),
          happeningRequestsProvider.overrideWithValue(const {}),
          currentSessionProvider.overrideWith(_Current.new),
          happeningCurrentRunProvider.overrideWithValue(null),
          sessionRunClockProvider.overrideWith(() => _NoClock()),
          drawerClockProvider.overrideWithValue(() => _now),
          happeningLingerProvider.overrideWithValue(linger),
          readListLiveConnectionProvider.overrideWithValue(
            connected ? HostConnection(client: client, label: 'h', isLocal: false) : null,
          ),
          happeningMuxReadyProvider.overrideWithValue((_) => true),
          happeningFollowOpenerProvider.overrideWithValue((client, id) {
            opened.add(id);
            final c = StreamController<Object?>();
            frames[id] = c;
            return (items: c.stream, cancel: () => cancelled.add(id));
          }),
        ],
      );
      addTearDown(container.dispose);
    }

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a run that ends lingers, then leaves; running again takes it back', () async {
      setUpContainer();
      final seen = container.listen(happeningProvider, (_, _) {});
      addTearDown(seen.close);
      final scope = container.read(_scope.notifier);
      scope.set([_s('a', running: true)]);
      expect(_ids(container.read(happeningProvider)), ['a']);
      scope.set([_s('a')]);
      await settle();
      final lingering = container.read(happeningProvider);
      expect(_ids(lingering), ['a']);
      expect(lingering.single.phase, HappeningPhase.done);
      expect(lingering.single.settledAt, _now);
      // Runs again within the linger: back to running, no timer leaves it.
      scope.set([_s('a', running: true)]);
      await settle();
      expect(container.read(happeningProvider).single.phase, HappeningPhase.running);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(_ids(container.read(happeningProvider)), ['a']);
      // Ends for good: gone after the linger.
      scope.set([_s('a')]);
      await settle();
      expect(container.read(happeningProvider).single.phase, HappeningPhase.done);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(container.read(happeningProvider), isEmpty);
    });

    test('archived (out of scope) while it runs: no linger', () async {
      setUpContainer();
      final seen = container.listen(happeningProvider, (_, _) {});
      addTearDown(seen.close);
      final scope = container.read(_scope.notifier);
      scope.set([_s('a', running: true)]);
      container.read(happeningProvider);
      scope.set(const []);
      await settle();
      expect(container.read(happeningProvider), isEmpty);
    });

    test('follows: none while hidden, one per other running conversation and at most three', () async {
      setUpContainer();
      final feed = container.listen(happeningFeedProvider, (_, _) {});
      addTearDown(feed.close);
      final scope = container.read(_scope.notifier);
      scope.set([
        for (var i = 0; i < 5; i++) _s('r$i', running: true, age: Duration(minutes: i)),
        _s('idle'),
        _s('sub', running: true, parent: 'r0'),
      ]);
      await settle();
      expect(opened, isEmpty, reason: 'hidden: no streams');
      container.read(happeningVisibleProvider.notifier).set(true);
      await settle();
      expect(opened, ['r0', 'r1', 'r2'], reason: 'the three newest, no subagent, no idle one');
      // r1 stops: its follow closes, r3 takes its place.
      scope.set([
        for (var i = 0; i < 5; i++)
          _s(
            'r$i',
            running: i != 1,
            age: Duration(minutes: i),
          ),
      ]);
      await settle();
      expect(cancelled, ['r1']);
      expect(opened, ['r0', 'r1', 'r2', 'r3']);
    });

    test('hidden for a while closes every follow', () async {
      setUpContainer();
      final feed = container.listen(happeningFeedProvider, (_, _) {});
      addTearDown(feed.close);
      container.read(_scope.notifier).set([_s('r', running: true)]);
      container.read(happeningVisibleProvider.notifier).set(true);
      await settle();
      expect(opened, ['r']);
      container.read(happeningVisibleProvider.notifier).set(false);
      await settle();
      expect(cancelled, isEmpty, reason: 'a short hide keeps it');
      await Future<void>.delayed(HappeningFeedController.hideGrace + const Duration(milliseconds: 100));
      expect(cancelled, ['r']);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('the frames give the start, the step, the tool and the todos; no text kept', () async {
      setUpContainer();
      final feed = container.listen(happeningFeedProvider, (_, _) {});
      addTearDown(feed.close);
      container.read(_scope.notifier).set([_s('r', running: true)]);
      container.read(happeningVisibleProvider.notifier).set(true);
      await settle();
      final f = frames['r']!;
      final start = _now.subtract(const Duration(minutes: 2));
      f.add(_event('turn/start', 1, {'turn': 1}, at: start));
      f.add(
        _event('tool/call', 2, {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'read', 'arguments': '{"path":"/a"}'}),
      );
      f.add(
        _event('tool/result', 3, {
          'turn': 1,
          'step': 1,
          'message': {'role': 'tool', 'content': 'secret file body'},
        }),
      );
      f.add(
        _event('todo/write', 4, {
          'todos': [
            {'content': 'one', 'status': 'completed'},
            {'content': 'two', 'status': 'pending'},
          ],
        }),
      );
      f.add(
        _event('tool/call', 5, {'turn': 1, 'step': 2, 'callId': 'c2', 'name': 'bash', 'arguments': '{"command":"ls"}'}),
      );
      await settle();
      final d = container.read(happeningFeedProvider)['r']!;
      expect(d.step, 2, reason: 'one tool done, the second one open');
      expect(d.toolName, 'bash');
      expect((d.todoDone, d.todoTotal), (1, 2));
      expect(d.startedAt, isNotNull);
      expect(d.calls.values, isNot(contains(contains('secret'))));
      final row = container.read(happeningProvider).single;
      expect(row.step, 2);
      expect(row.toolLabel, happeningToolLabel('bash'));
      expect(happeningSubtitle(row, _now), '第 2 步 · ${happeningToolLabel('bash')}');
    });

    test('no live connection: no follows', () async {
      setUpContainer(connected: false);
      final feed = container.listen(happeningFeedProvider, (_, _) {});
      addTearDown(feed.close);
      container.read(_scope.notifier).set([_s('r', running: true)]);
      container.read(happeningVisibleProvider.notifier).set(true);
      await settle();
      expect(opened, isEmpty);
    });
  });

  group('the open conversation\'s run', () {
    ProviderContainer make(List<String> built) {
      final c = ProviderContainer(
        overrides: [
          currentSessionProvider.overrideWith(_Open.new),
          chatProvider.overrideWith2((id) {
            built.add(id);
            return FakeChatController(id, const ChatState(loading: false, running: true));
          }),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('the drawer alone never starts a chat controller (no follow of its own)', () async {
      final built = <String>[];
      final c = make(built);
      final sub = c.listen(happeningCurrentRunProvider, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(happeningCurrentRunProvider), isNull);
      expect(built, isEmpty);
    });

    test('with the chat screen holding it (even built just after): its run', () async {
      final built = <String>[];
      final c = make(built);
      final sub = c.listen(happeningCurrentRunProvider, (_, _) {});
      addTearDown(sub.close);
      // The chat screen, later in the same frame.
      final chat = c.listen(chatProvider('open'), (_, _) {});
      addTearDown(chat.close);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(happeningCurrentRunProvider)?.sessionId, 'open');
      expect(built, ['open']);
    });
  });
}

class _Open extends CurrentSessionController {
  @override
  String? build() => 'open';
}

class _NoClock extends SessionRunClock {
  @override
  Map<String, DateTime> build() => const {};
}
