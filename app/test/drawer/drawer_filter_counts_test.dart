// The drawer's filter capsules and its list come from one rule
// (`drawerFilterMatches`) over the same inputs (`watchDrawerFilterCounts` /
// `watchDrawerBlocks`): the number on 待确认 / 未读 is always the rows that
// filter lists. Covers the inspection report's "待确认 1 but 没有待确认的对话".
//
//   flutter test test/drawer/drawer_filter_counts_test.dart

import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/capsule_chip.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_list.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'support.dart';

// ── Shared checks ────────────────────────────────────────────────────────────

SessionSummary _row(String id, {bool running = false, int age = 0}) => SessionSummary(
  sessionId: id,
  updatedAt: sampleNow.subtract(Duration(minutes: age)),
  running: running,
  blank: false,
  agentAvailable: running,
  projections: SessionProjections(1, {'title': 'Chat $id'}),
);

Finder get _chips => find.descendant(of: find.byType(DrawerFilterBar), matching: find.byType(CapsuleChoiceChip));

Finder get _rows => find.descendant(of: find.byType(DrawerConversationList), matching: find.byType(SessionTile));

/// Capsule label per filter, in the bar's order.
Map<DrawerFilter, String> _labels(WidgetTester tester) => {
  for (final (i, chip) in tester.widgetList<CapsuleChoiceChip>(_chips).indexed) DrawerFilter.values[i]: chip.label,
};

/// The number a capsule shows (none: 0).
int _shown(String label) => int.tryParse(RegExp(r' (\d+)$').firstMatch(label)?.group(1) ?? '') ?? 0;

/// Under the selected filter, a capsule's number equals the rows listed.
void _expectSameSource(WidgetTester tester, DrawerFilter filter) {
  final label = _labels(tester)[filter]!;
  expect(
    _rows.evaluate().length,
    _shown(label),
    reason: 'capsule "$label" vs ${_rows.evaluate().length} rows under $filter',
  );
}

// ── Small harness: the bar and the list over controllable providers ─────────

class _Scope extends Notifier<DrawerScope?> {
  _Scope(this.initial);

  final DrawerScope? initial;

  @override
  DrawerScope? build() => initial;

  void set(DrawerScope? scope) => state = scope;
}

final _scopeProvider = NotifierProvider<_Scope, DrawerScope?>(() => _Scope(null));

class _Pending extends PendingInteractionsController {
  _Pending(this.initial);

  final Map<String, PendingKind> initial;

  @override
  Map<String, PendingKind> build() => initial;

  void set(Map<String, PendingKind> next) => state = next;
}

class _Unread extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void set(Set<String> next) => state = next;
}

final _unreadProvider = NotifierProvider<_Unread, Set<String>>(_Unread.new);

class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.ready);
}

Future<ProviderContainer> _pumpBar(
  WidgetTester tester, {
  required DrawerScope scope,
  Map<String, PendingKind> pending = const {},
}) async {
  SharedPreferences.setMockInitialValues(storedView(const DrawerView(loaded: true)));
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      overrides: [
        _scopeProvider.overrideWith(() => _Scope(scope)),
        drawerScopeProvider.overrideWith((ref) => ref.watch(_scopeProvider)),
        pendingInteractionsProvider.overrideWith(() => _Pending(pending)),
        unreadSessionIdsProvider.overrideWith((ref) => ref.watch(_unreadProvider)),
        workspacesProvider.overrideWith(_Workspaces.new),
        currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
      ],
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            if (!ref.watch(drawerViewProvider).loaded) return const SizedBox.shrink();
            // As _SessionList passes it (sessions_drawer.dart).
            final readOnly = ref.watch(drawerScopeProvider)?.readOnly ?? false;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const DrawerFilterBar(),
                Expanded(
                  child: DrawerConversationList(now: sampleNow, readOnly: readOnly, onOpen: (_) {}, onLongPress: (_) {}),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(tester.element(find.byType(DrawerFilterBar)));
}

// ── Full harness: the real drawer, the real pending controller ──────────────

/// `$events` and the mux's held requests, scripted.
class _Requests {
  final events = StreamController<HostEvent>.broadcast();
  final held = <HostEvent>[];

  PendingSource get source => (events: events.stream, pending: () => List.of(held));

  void approval(String eventId, String sessionId) {
    final event = ApprovalRequestedEvent(ApprovalRequest(eventId: eventId, sessionId: sessionId, toolName: 'bash'));
    held.add(event);
    events.add(event);
  }

  void question(String eventId, String sessionId) {
    final event = UserQuestionRequestedEvent(
      UserQuestionRequest(
        eventId: eventId,
        sessionId: sessionId,
        questions: const [UserQuestion(id: 'q', question: '继续吗？')],
      ),
    );
    held.add(event);
    events.add(event);
  }
}

void _seedChild(FakeWorkspaceHost host, String id, String parent, DateTime at) => host.sessions.add({
  'sessionId': id,
  'updatedAt': at.millisecondsSinceEpoch,
  'running': true,
  'blank': false,
  'agentAvailable': true,
  'cwd': '/root/workspace',
  'origin': 'subagent',
  'parentSessionId': parent,
  'projections': {
    'kind': 'hints',
    'asOfSeq': 1,
    'values': {'title': 'child of $parent'},
  },
});

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

Future<(FakeWorkspaceHost, _Requests, ProviderContainer)> _startShell(
  WidgetTester tester, {
  void Function(FakeWorkspaceHost host, DateTime midnight)? seed,
  WorkspacePrefs prefs = const WorkspacePrefs(loaded: true),
  Set<String> botOwned = const {},
}) async {
  SharedPreferences.setMockInitialValues({});
  final host = DrawerHost();
  final midnight = DateTime(sampleNow.year, sampleNow.month, sampleNow.day);
  host.seedSession('r1', '主对话', midnight.add(const Duration(seconds: 5)), running: true);
  host.seedSession('s2', '深色模式', midnight.add(const Duration(seconds: 4)));
  seed?.call(host, midnight);
  final requests = _Requests();
  addTearDown(requests.events.close);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: [
        ...workspaceOverrides(host, prefs: prefs, current: null),
        pendingSourceProvider.overrideWithValue(requests.source),
        if (botOwned.isNotEmpty) dsBotOwnedSessionsProvider.overrideWithValue(botOwned),
      ],
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  addTearDown(container.read(activeConnectionProvider).value!.client.close);
  return (host, requests, container);
}

Future<void> _choose(WidgetTester tester, DrawerFilter filter) async {
  await tester.tap(_chips.at(DrawerFilter.values.indexOf(filter)));
  await _settle(tester);
}

void main() {
  group('drawerFilterCounts', () {
    final sessions = [
      _row('a', running: true),
      _row('b', age: 1),
      _row('c', running: true, age: 2),
      _row('d', age: 3),
    ];
    // Marks for conversations not listed (archived, another workspace, a
    // subagent whose root is elsewhere) must not count.
    const pending = {'c': PendingKind.question, 'b': PendingKind.approval, 'gone': PendingKind.approval};
    const unread = {'d', 'elsewhere'};

    test('each count is the row count drawerBlocks gives that filter', () {
      final counts = drawerFilterCounts(sessions: sessions, pending: pending, unread: unread);
      expect(counts, {DrawerFilter.all: 4, DrawerFilter.running: 2, DrawerFilter.pending: 2, DrawerFilter.unread: 1});
      for (final filter in DrawerFilter.values.where((f) => f != DrawerFilter.all)) {
        final blocks = drawerBlocks(
          sessions: sessions,
          pinnedIds: const [],
          view: const DrawerView(loaded: true),
          filter: filter,
          pending: pending,
          unread: unread,
          createdAt: const {},
          now: sampleNow,
        );
        expect(blocks.single, isA<FilteredBlock>());
        expect(blocks.single.items.length, counts[filter], reason: '$filter');
        expect(blocks.single.items.every((s) => drawerFilterMatches(filter, s, pending, unread)), isTrue);
      }
    });

    test('running and pending at once: listed under both', () {
      expect(drawerFilterMatches(DrawerFilter.running, sessions[2], pending, unread), isTrue);
      expect(drawerFilterMatches(DrawerFilter.pending, sessions[2], pending, unread), isTrue);
    });

    test('nothing listed: every count is 0', () {
      expect(drawerFilterCounts(sessions: const [], pending: pending, unread: unread).values, everyElement(0));
    });
  });

  group('bar and list in the same frame', () {
    final sessions = [_row('a', running: true), _row('b', age: 1), _row('c', age: 2)];

    testWidgets('read-only (cached) scope: no pending or unread number, no such rows', (tester) async {
      final container = await _pumpBar(
        tester,
        scope: DrawerScope(sessions: sessions, bots: const [], scoped: false, readOnly: true),
        pending: const {'b': PendingKind.approval},
      );
      container.read(_unreadProvider.notifier).set({'c'});
      await tester.pump();
      expect(_labels(tester)[DrawerFilter.pending], '待确认');
      expect(_labels(tester)[DrawerFilter.unread], '未读');
      for (final filter in [DrawerFilter.pending, DrawerFilter.unread]) {
        container.read(drawerFilterProvider.notifier).set(filter);
        await tester.pump();
        expect(_rows, findsNothing);
        _expectSameSource(tester, filter);
      }
    });

    testWidgets('cached → live in one frame: the number and the rows arrive together', (tester) async {
      final container = await _pumpBar(
        tester,
        scope: DrawerScope(sessions: sessions, bots: const [], scoped: false, readOnly: true),
        pending: const {'b': PendingKind.approval},
      );
      container.read(drawerFilterProvider.notifier).set(DrawerFilter.pending);
      await tester.pump();
      _expectSameSource(tester, DrawerFilter.pending);
      expect(_rows, findsNothing);

      container.read(_scopeProvider.notifier).set(DrawerScope(sessions: sessions, bots: const [], scoped: false));
      await tester.pump();
      expect(_labels(tester)[DrawerFilter.pending], '待确认 1');
      expect(_rows, findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);

      // And back to the cache (a refresh): both drop together.
      container
          .read(_scopeProvider.notifier)
          .set(DrawerScope(sessions: sessions, bots: const [], scoped: false, readOnly: true));
      await tester.pump();
      expect(_rows, findsNothing);
      _expectSameSource(tester, DrawerFilter.pending);
    });

    testWidgets('待确认 already chosen, then requests come and go: the list follows the number', (tester) async {
      final container = await _pumpBar(
        tester,
        scope: DrawerScope(sessions: sessions, bots: const [], scoped: false),
      );
      container.read(drawerFilterProvider.notifier).set(DrawerFilter.pending);
      await tester.pump();
      expect(find.text('没有待确认的对话'), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);

      final pending = container.read(pendingInteractionsProvider.notifier) as _Pending;
      pending.set(const {'b': PendingKind.approval});
      await tester.pump();
      expect(_labels(tester)[DrawerFilter.pending], '待确认 1');
      expect(find.text('没有待确认的对话'), findsNothing);
      _expectSameSource(tester, DrawerFilter.pending);

      pending.set(const {'b': PendingKind.approval, 'a': PendingKind.question});
      await tester.pump();
      expect(_labels(tester)[DrawerFilter.pending], '待确认 2');
      _expectSameSource(tester, DrawerFilter.pending);

      pending.set(const {});
      await tester.pump();
      expect(_labels(tester)[DrawerFilter.pending], '待确认');
      expect(find.text('没有待确认的对话'), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);
    });

    testWidgets('未读 chosen: marks arriving and leaving keep the number and rows equal', (tester) async {
      final container = await _pumpBar(
        tester,
        scope: DrawerScope(sessions: sessions, bots: const [], scoped: false),
      );
      container.read(drawerFilterProvider.notifier).set(DrawerFilter.unread);
      await tester.pump();
      container.read(_unreadProvider.notifier).set({'b', 'c', 'not-listed'});
      await tester.pump();
      expect(_labels(tester)[DrawerFilter.unread], '未读 2');
      _expectSameSource(tester, DrawerFilter.unread);
      container.read(_unreadProvider.notifier).set({'c'});
      await tester.pump();
      _expectSameSource(tester, DrawerFilter.unread);
    });
  });

  group('the real drawer and pending controller', () {
    testWidgets('a subagent asks: counted on its root, marked only after the settle', (tester) async {
      final (_, requests, _) = await _startShell(
        tester,
        seed: (host, midnight) => _seedChild(host, 'c1', 'r1', midnight.add(const Duration(seconds: 6))),
      );
      requests.approval('e1', 'c1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Inside the 800 ms settle: neither the number nor the row yet.
      expect(_labels(tester)[DrawerFilter.pending], '待确认');
      await tester.pump(const Duration(milliseconds: 800));
      expect(_labels(tester)[DrawerFilter.pending], '待确认 1');
      expect(find.descendant(of: find.widgetWithText(SessionTile, '主对话'), matching: find.text('待确认')), findsOneWidget);

      await _choose(tester, DrawerFilter.pending);
      expect(find.widgetWithText(SessionTile, '主对话'), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);
      // The child itself never lists.
      expect(find.widgetWithText(SessionTile, 'child of r1'), findsNothing);
    });

    testWidgets('待确认 chosen first, then a request arrives and settles', (tester) async {
      final (_, requests, _) = await _startShell(tester);
      await _choose(tester, DrawerFilter.pending);
      expect(find.text('没有待确认的对话'), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);

      requests.approval('e1', 's2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _expectSameSource(tester, DrawerFilter.pending);
      await tester.pump(const Duration(milliseconds: 800));
      expect(_labels(tester)[DrawerFilter.pending], '待确认 1');
      expect(find.widgetWithText(SessionTile, '深色模式'), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);

      // Answered on another device.
      requests.held.clear();
      requests.events.add(const HostRequestCancelledEvent('e1'));
      await _settle(tester);
      expect(_labels(tester)[DrawerFilter.pending], '待确认');
      expect(find.text('没有待确认的对话'), findsOneWidget);
    });

    testWidgets('roots out of scope (archived, DS Bot, another workspace) count nowhere', (tester) async {
      final (_, requests, _) = await _startShell(
        tester,
        seed: (host, midnight) {
          host.seedSession('r2', '已归档的', midnight.add(const Duration(seconds: 3)));
          host.seedSession('r3', 'Bot 的', midnight.add(const Duration(seconds: 2)));
          host.seedSession('r4', '别的工作区', midnight.add(const Duration(seconds: 1)));
          for (final root in ['r1', 'r2', 'r3', 'r4']) {
            _seedChild(host, 'c-$root', root, midnight.add(const Duration(seconds: 7)));
          }
          host.archived = ['r2'];
          host.seedWorkspace('/root/workspace', title: '工作', sessionIds: ['r1', 's2', 'r2', 'r3']);
        },
        prefs: const WorkspacePrefs(loaded: true, selected: 'ws-1'),
        botOwned: const {'r3'},
      );
      expect(find.widgetWithText(SessionTile, '主对话'), findsOneWidget);
      expect(find.widgetWithText(SessionTile, '别的工作区'), findsNothing);
      for (final root in ['r2', 'r3', 'r4']) {
        requests.approval('e-$root', 'c-$root');
      }
      await _settle(tester);
      expect(_labels(tester)[DrawerFilter.pending], '待确认');
      await _choose(tester, DrawerFilter.pending);
      expect(find.text('没有待确认的对话'), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);

      // One whose root is listed: exactly one, on both sides.
      requests.approval('e-r1', 'c-r1');
      await _settle(tester);
      expect(_labels(tester)[DrawerFilter.pending], '待确认 1');
      expect(find.widgetWithText(SessionTile, '主对话'), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);
    });

    testWidgets('running and waiting on an answer: 待回答 under 运行中, listed under 待确认', (tester) async {
      final (_, requests, _) = await _startShell(tester);
      requests.question('q1', 'r1');
      await _settle(tester);
      await _choose(tester, DrawerFilter.running);
      expect(find.descendant(of: find.widgetWithText(SessionTile, '主对话'), matching: find.text('待回答')), findsOneWidget);
      await _choose(tester, DrawerFilter.pending);
      expect(_labels(tester)[DrawerFilter.pending], '待确认 1');
      expect(find.descendant(of: find.widgetWithText(SessionTile, '主对话'), matching: find.text('待回答')), findsOneWidget);
      _expectSameSource(tester, DrawerFilter.pending);
    });
  });
}
