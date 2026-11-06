// The workspace tree layout's data: `drawerTreeBlocks` (groups in the Host's
// manual order, the pinned zone, 其它对话, filters, a selected workspace),
// the layout / folded groups kept per host, 全选 over folded groups, and the
// dispatch in `watchDrawerBlocks`.
//
//   flutter test test/drawer/tree_blocks_test.dart

import 'dart:convert';

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';

final _now = DateTime(2026, 10, 24, 15);

SessionSummary _s(String id, Duration age, {bool running = false}) => SessionSummary(
  sessionId: id,
  updatedAt: _now.subtract(age),
  running: running,
  blank: false,
  agentAvailable: running,
  projections: SessionProjections(1, {'title': id}),
);

Workspace _w(String id, List<String> sessionIds) =>
    Workspace(workspaceId: id, path: '/root/$id', title: id, sessionIds: sessionIds);

/// a..f, newest first; a and d run.
List<SessionSummary> _sample() => [
  _s('a', const Duration(minutes: 1), running: true),
  _s('b', const Duration(minutes: 2)),
  _s('c', const Duration(minutes: 3)),
  _s('d', const Duration(minutes: 4), running: true),
  _s('e', const Duration(days: 1)),
  _s('f', const Duration(days: 3)),
];

/// w1 orders c, a, b by hand (plus an archived x); w2 holds d; e, f are loose.
final _workspaces = [
  _w('w1', ['c', 'x', 'a', 'b']),
  _w('w2', ['d']),
  _w('w3', const []),
];

List<DrawerBlock> _tree({
  List<SessionSummary>? sessions,
  List<Workspace>? workspaces,
  List<String> pinned = const [],
  DrawerView view = const DrawerView(loaded: true),
  DrawerFilter filter = DrawerFilter.all,
  Map<String, PendingKind> pending = const {},
  Map<String, DateTime> created = const {},
  String? selected,
  bool readOnly = false,
  Map<String, String> sectionStarts = const {},
}) => drawerTreeBlocks(
  sessions: sessions ?? _sample(),
  workspaces: workspaces ?? _workspaces,
  pinnedIds: pinned,
  view: view,
  filter: filter,
  pending: pending,
  unread: const {},
  createdAt: created,
  now: _now,
  selectedWorkspaceId: selected,
  readOnly: readOnly,
  sectionStarts: sectionStarts,
);

List<String> _ids(DrawerBlock b) => [for (final s in b.items) s.sessionId];

void main() {
  group('drawerTreeBlocks', () {
    test('one group per workspace in registry order, the Host order kept, then 其它对话', () {
      final blocks = _tree();
      expect(blocks.map((b) => b.runtimeType), [WorkspaceBlock, WorkspaceBlock, WorkspaceBlock, LooseBlock]);
      final w1 = blocks[0] as WorkspaceBlock;
      expect(w1.workspace.workspaceId, 'w1');
      // Manual order, not activity: c (older) before a (running, newest).
      expect(_ids(w1), ['c', 'a', 'b']);
      expect(w1.pinnedCount, 0);
      expect(w1.runningCount, 1);
      expect(w1.canReorder, isTrue);
      expect(w1.collapsed, isFalse);
      expect(_ids(blocks[1]), ['d']);
      // An empty workspace still has its group (count 0).
      expect((blocks[2] as WorkspaceBlock).items, isEmpty);
      expect(_ids(blocks[3]), ['e', 'f']);
    });

    test('ids the Host lists but the scope does not (archived, elsewhere) are skipped', () {
      final w1 = _tree().first as WorkspaceBlock;
      expect(_ids(w1), isNot(contains('x')));
      final scoped = _tree(sessions: _sample().where((s) => s.sessionId != 'a').toList()).first;
      expect(_ids(scoped), ['c', 'b']);
    });

    test('pinned members lead their group, each zone in the Host order', () {
      final w1 = _tree(pinned: ['b', 'c', 'e']).first as WorkspaceBlock;
      expect(_ids(w1), ['c', 'b', 'a']);
      expect(w1.pinnedCount, 2);
      expect([for (final s in w1.pinned) s.sessionId], ['c', 'b']);
      expect([for (final s in w1.unpinned) s.sessionId], ['a']);
      // A pinned loose conversation stays in 其它对话, by the sort key.
      final loose = _tree(pinned: ['f']).whereType<LooseBlock>().single;
      expect(_ids(loose), ['e', 'f']);
    });

    test('其它对话 follows the sort key; empty, it is left out', () {
      final created = {'e': _now.subtract(const Duration(days: 9)), 'f': _now};
      final byCreated = _tree(view: const DrawerView(loaded: true, sort: DrawerSort.created), created: created);
      expect(_ids(byCreated.whereType<LooseBlock>().single), ['f', 'e']);
      final none = _tree(sessions: _sample().where((s) => !{'e', 'f'}.contains(s.sessionId)).toList());
      expect(none.whereType<LooseBlock>(), isEmpty);
    });

    test('a status filter gives the same flat block as the time layout', () {
      final tree = _tree(filter: DrawerFilter.running);
      final time = drawerBlocks(
        sessions: _sample(),
        pinnedIds: const [],
        view: const DrawerView(loaded: true),
        filter: DrawerFilter.running,
        pending: const {},
        unread: const {},
        createdAt: const {},
        now: _now,
      );
      expect(tree.single, isA<FilteredBlock>());
      expect(_ids(tree.single), _ids(time.single));
      expect(_ids(tree.single), ['a', 'd']);
      final waiting = _tree(filter: DrawerFilter.pending, pending: {'e': PendingKind.question});
      expect(_ids(waiting.single), ['e']);
    });

    test('a selected workspace is its group alone, never folded, without 其它对话', () {
      final blocks = _tree(
        selected: 'w1',
        view: const DrawerView(loaded: true, collapsedWorkspaces: {'w1'}),
      );
      final only = blocks.single as WorkspaceBlock;
      expect(only.workspace.workspaceId, 'w1');
      expect(only.collapsed, isFalse);
      expect(_ids(only), ['c', 'a', 'b']);
      // A selection the list doesn't have falls back to the whole tree.
      expect(_tree(selected: 'gone').length, 4);
    });

    test('every conversation shows once: the first workspace claiming it wins', () {
      final blocks = _tree(workspaces: [_w('w1', ['a', 'b']), _w('w2', ['b', 'd'])]);
      expect(_ids(blocks[0]), ['a', 'b']);
      expect(_ids(blocks[1]), ['d']);
      expect(_ids(blocks[2]), ['c', 'e', 'f']);
    });

    test('folded groups keep their rows (for the count) but 全选 skips them', () {
      final blocks = _tree(view: const DrawerView(loaded: true, collapsedWorkspaces: {'w1'}));
      final w1 = blocks.first as WorkspaceBlock;
      expect(w1.collapsed, isTrue);
      expect(w1.items, hasLength(3));
      expect(drawerSelectableIds(blocks), ['d', 'e', 'f']);
    });

    test('read-only lists cannot reorder; section headings land on the first group', () {
      final blocks = _tree(readOnly: true, sectionStarts: {'w2': '个人'});
      expect(blocks.whereType<WorkspaceBlock>().every((b) => !b.canReorder), isTrue);
      expect([for (final b in blocks.whereType<WorkspaceBlock>()) b.sectionTitle], [null, '个人', null]);
    });
  });

  group('DrawerView layout and folded workspaces', () {
    test('stored JSON: older views read as the time layout; the new keys round-trip', () {
      final old = DrawerView.fromJson({'folders': [], 'sort': 'created'});
      expect(old.layout, DrawerLayout.time);
      expect(old.collapsedWorkspaces, isEmpty);
      // Untouched views write exactly what older builds wrote.
      expect(old.toJson().keys, ['folders', 'sort']);

      const view = DrawerView(loaded: true, layout: DrawerLayout.tree, collapsedWorkspaces: {'w1', 'w2'});
      final json = jsonDecode(jsonEncode(view.toJson())) as Map<String, Object?>;
      expect(json['layout'], 'tree');
      expect(json['collapsedWorkspaces'], unorderedEquals(['w1', 'w2']));
      final back = DrawerView.fromJson(json);
      expect(back.layout, DrawerLayout.tree);
      expect(back.collapsedWorkspaces, {'w1', 'w2'});

      final damaged = DrawerView.fromJson({
        'layout': 'grid',
        'collapsedWorkspaces': ['w1', 3, '', null],
      });
      expect(damaged.layout, DrawerLayout.time);
      expect(damaged.collapsedWorkspaces, {'w1'});
      expect(DrawerView.fromJson({'collapsedWorkspaces': 'w1'}).collapsedWorkspaces, isEmpty);
    });

    test('the controller keeps the layout and folds per host', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final view = c.read(drawerViewProvider.notifier);
      await view.ready();
      await view.setLayout(DrawerLayout.tree);
      await view.toggleWorkspaceCollapsed('w1');
      await view.setWorkspaceCollapsed('w2', true);
      await view.setWorkspaceCollapsed('w2', false);
      expect(c.read(drawerViewProvider).layout, DrawerLayout.tree);
      expect(c.read(drawerViewProvider).collapsedWorkspaces, {'w1'});
      await view.toggleWorkspaceCollapsed('w1');
      expect(c.read(drawerViewProvider).collapsedWorkspaces, isEmpty);
      await view.toggleWorkspaceCollapsed('w3');

      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString('drawer.view.local.local')!) as Map<String, Object?>;
      expect(stored['layout'], 'tree');
      expect(stored['collapsedWorkspaces'], ['w3']);

      // A fresh start reads it back.
      final again = ProviderContainer();
      addTearDown(again.dispose);
      await again.read(drawerViewProvider.notifier).ready();
      expect(again.read(drawerViewProvider).layout, DrawerLayout.tree);
      expect(again.read(drawerViewProvider).collapsedWorkspaces, {'w3'});
    });
  });

  testWidgets('watchDrawerBlocks follows the layout over the live providers', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final host = sampleWorkspaceHost();
    const prefs = WorkspacePrefs(loaded: true, pinned: ['ws-2'], groups: {'ws-1': '个人'});
    final container = ProviderContainer(overrides: workspaceOverrides(host, prefs: prefs));
    addTearDown(container.dispose);
    List<DrawerBlock>? blocks;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            blocks = watchDrawerBlocks(ref);
            return const SizedBox();
          },
        ),
      ),
    );
    for (var i = 0; i < 10 && blocks == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(blocks, isNotNull);
    expect(blocks!.whereType<WorkspaceBlock>(), isEmpty);

    await container.read(drawerViewProvider.notifier).setLayout(DrawerLayout.tree);
    await tester.pump();
    final groups = blocks!.whereType<WorkspaceBlock>().toList();
    // 置顶 (博客, ws-2) first, then the group 个人 (notes, ws-1), then dsh-app.
    expect([for (final g in groups) g.workspace.workspaceId], ['ws-2', 'ws-1', 'ws-3']);
    expect(groups.first.sectionTitle, isNotNull);
    expect(groups[1].sectionTitle, '个人');
    expect([for (final s in groups.last.items) s.sessionId], ['s1', 's2', 's4', 's6']);
    expect(groups.every((g) => g.canReorder), isTrue);
    expect([for (final s in blocks!.whereType<LooseBlock>().single.items) s.sessionId], ['s5']);
    // Let the list's debounced reads run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
