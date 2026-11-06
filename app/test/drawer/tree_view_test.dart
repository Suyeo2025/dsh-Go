// The workspace tree on screen: the 按时间 / 工作区树 switch (greyed under a
// status filter), groups in the Host's order with their pinned zone first,
// folding a group, 其它对话, an empty group, and the ⋯ key that replaces the
// long-press menu where a long press drags.
//
//   flutter test test/drawer/tree_view_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/shell/drawer/layout_switch.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/drawer/workspace_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sm_ui_support.dart';

const _tree = DrawerView(loaded: true, layout: DrawerLayout.tree);

RecordingWorkspaces _registry({List<String> pinned = const []}) => RecordingWorkspaces(
  WorkspacesState(
    status: WorkspacesStatus.ready,
    workspaces: [
      smWorkspace('w1', ['c', 'a', 'b']),
      smWorkspace('w2', ['d']),
      smWorkspace('w3', const []),
    ],
    pinnedSessionIds: pinned,
  ),
);

final _sessions = [
  smSession('a', running: true),
  smSession('b', age: const Duration(minutes: 1)),
  smSession('c', age: const Duration(minutes: 2)),
  smSession('d', running: true, age: const Duration(minutes: 3)),
  smSession('e', age: const Duration(minutes: 4)),
];

double _y(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

void main() {
  testWidgets('按时间 by default: the switch row first, no ⋯ keys, the list as before', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    expect(find.byType(DrawerLayoutSwitch), findsOneWidget);
    expect(find.byType(WorkspaceHeader), findsNothing);
    expect(find.byKey(const ValueKey('session-more')), findsNothing);
    expect(find.text('今天'), findsOneWidget);
  });

  testWidgets('the switch turns the list into the tree, and is kept', (tester) async {
    final container = await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    await tester.tap(find.text('工作区树'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(drawerViewProvider).layout, DrawerLayout.tree);
    expect(find.byType(WorkspaceHeader), findsNWidgets(3));
  });

  testWidgets('groups in registry order, the Host order inside, pinned first; then 其它对话', (tester) async {
    await pumpSmList(
      tester,
      sessions: _sessions,
      workspaces: _registry(pinned: ['b']),
      view: _tree,
      onMore: (_, _) {},
    );
    expect(find.text('W-w1'), findsOneWidget);
    // w1: b (pinned) first, then c, a as the Host orders them.
    expect(_y(tester, smTitle('b')), lessThan(_y(tester, smTitle('c'))));
    expect(_y(tester, smTitle('c')), lessThan(_y(tester, smTitle('a'))));
    expect(_y(tester, smTitle('a')), lessThan(_y(tester, find.text('W-w2'))));
    expect(_y(tester, find.text('W-w2')), lessThan(_y(tester, smTitle('d'))));
    // Conversations in no workspace come last.
    expect(find.text('其它对话'), findsOneWidget);
    expect(_y(tester, find.text('其它对话')), lessThan(_y(tester, smTitle('e'))));
    // The pinned one says so; the header counts and says how many run.
    final pinnedTile = tester.widget<SessionTile>(find.ancestor(of: smTitle('b'), matching: find.byType(SessionTile)));
    expect(pinnedTile.pinned, isTrue);
    expect(find.text('1 在跑'), findsNWidgets(2));
    // ⋯ on every row (a long press drags here).
    expect(find.byKey(const ValueKey('session-more')), findsNWidgets(5));
  });

  testWidgets('an empty workspace says so', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry(), view: _tree);
    expect(find.text('这个工作区还没有对话'), findsOneWidget);
  });

  testWidgets('a tap on the header folds the group, and unfolds it', (tester) async {
    final container = await pumpSmList(tester, sessions: _sessions, workspaces: _registry(), view: _tree);
    await tester.tap(find.text('W-w1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(drawerViewProvider).collapsedWorkspaces, {'w1'});
    expect(smTitle('a'), findsNothing);
    expect(smTitle('d'), findsOneWidget);
    await tester.tap(find.text('W-w1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(smTitle('a'), findsOneWidget);
  });

  testWidgets('folding animates, then nothing is left running', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry(), view: _tree, animations: true);
    await tester.tap(find.text('W-w1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(smTitle('a'), findsOneWidget, reason: 'still folding');
    await tester.pump(const Duration(milliseconds: 500));
    expect(smTitle('a'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('under a status filter the switch is greyed, says why, and the list is flat', (tester) async {
    final container = await pumpSmList(tester, sessions: _sessions, workspaces: _registry(), view: _tree);
    container.read(drawerFilterProvider.notifier).set(DrawerFilter.running);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final pill = tester.widget<SegmentedPill<DrawerLayout>>(find.byType(SegmentedPill<DrawerLayout>));
    expect(pill.onChanged, isNull);
    expect(find.byTooltip('清除筛选后可切换'), findsOneWidget);
    expect(find.byType(WorkspaceHeader), findsNothing);
    expect(smTitle('a'), findsOneWidget);
    expect(smTitle('b'), findsNothing);
  });

  testWidgets('⋯ hands the row and its group to the menu', (tester) async {
    final asked = <(String, String?)>[];
    await pumpSmList(
      tester,
      sessions: _sessions,
      workspaces: _registry(),
      view: _tree,
      onMore: (s, ws) => asked.add((s.sessionId, ws)),
    );
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: smTitle('d'), matching: find.byType(SessionTile)),
        matching: find.byKey(const ValueKey('session-more')),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: smTitle('e'), matching: find.byType(SessionTile)),
        matching: find.byKey(const ValueKey('session-more')),
      ),
    );
    expect(asked, [('d', 'w2'), ('e', null)]);
  });

  testWidgets('at rest the tree asks for no frames', (tester) async {
    await pumpSmList(
      tester,
      sessions: [smSession('b'), smSession('c')],
      workspaces: _registry(),
      view: _tree,
      animations: true,
    );
    await tester.pump(const Duration(seconds: 1));
    var frames = 0;
    for (var i = 0; i < 60; i++) {
      await tester.binding.delayed(const Duration(milliseconds: 16));
      if (tester.binding.hasScheduledFrame) {
        frames++;
        await tester.pump();
      }
    }
    expect(frames, 0);
  });
}
