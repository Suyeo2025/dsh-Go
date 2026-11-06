// Dragging rows in the workspace tree: where a drop may land (its own group
// only; the pinned zone follows its neighbours), what it asks of the Host
// (`moveSession(workspace, id, beforeId)`), and the 「排序没有保存」 notice with
// 重试 when the Host doesn't take it.
//
//   flutter test test/drawer/reorder_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sm_ui_support.dart';

const _tree = DrawerView(loaded: true, layout: DrawerLayout.tree);

TreeSlot _head(String g) => TreeSlot(groupId: g, header: true);
TreeSlot _row(String g, String id, {bool pinned = false}) => TreeSlot(groupId: g, sessionId: id, pinned: pinned);

RecordingWorkspaces _registry({List<String> pinned = const []}) => RecordingWorkspaces(
  WorkspacesState(
    status: WorkspacesStatus.ready,
    workspaces: [
      smWorkspace('w1', ['c', 'a', 'b']),
      smWorkspace('w2', ['d']),
    ],
    pinnedSessionIds: pinned,
  ),
);

final _sessions = [
  smSession('a'),
  smSession('b', age: const Duration(minutes: 1)),
  smSession('c', age: const Duration(minutes: 2)),
  smSession('d', age: const Duration(minutes: 3)),
];

/// Long press on [id]'s row, then move it by [dy] in small steps and let go.
Future<void> _drag(WidgetTester tester, String id, double dy) async {
  final gesture = await tester.startGesture(tester.getCenter(smTitle(id)), kind: PointerDeviceKind.touch);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  final steps = (dy.abs() / 8).ceil();
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, dy / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 200));
  await gesture.up();
  await settleActions(tester);
}

void main() {
  group('treeDropOf', () {
    test('within its group: the next row of its zone is the anchor, none at the end', () {
      final order = [const TreeSlot(), _head('w1'), _row('w1', 'c'), _row('w1', 'b'), _row('w1', 'a'), _head('w2')];
      expect(treeDropOf(order, 4), const TreeDrop(workspaceId: 'w1', sessionId: 'a'));
      final up = [const TreeSlot(), _head('w1'), _row('w1', 'a'), _row('w1', 'c'), _row('w1', 'b')];
      expect(treeDropOf(up, 2), const TreeDrop(workspaceId: 'w1', sessionId: 'a', beforeId: 'c'));
    });

    test('another group, above every group or first in the list: no drop', () {
      final other = [_head('w1'), _row('w1', 'c'), _row('w2', 'd'), _row('w1', 'a'), _head('w2')];
      expect(treeDropOf(other, 2), isNull);
      final top = [_row('w1', 'a'), _head('w1'), _row('w1', 'c')];
      expect(treeDropOf(top, 0), isNull);
      final above = [const TreeSlot(), _row('w1', 'a'), _head('w1'), _row('w1', 'c')];
      expect(treeDropOf(above, 1), isNull);
    });

    test('into the pinned zone pins it, out of it unpins it; the anchor stays in its zone', () {
      final intoPinned = [_head('w1'), _row('w1', 'a'), _row('w1', 'b', pinned: true), _row('w1', 'c')];
      expect(treeDropOf(intoPinned, 1), const TreeDrop(workspaceId: 'w1', sessionId: 'a', beforeId: 'b', pin: true));
      final outOfPinned = [_head('w1'), _row('w1', 'c'), _row('w1', 'b', pinned: true), _row('w1', 'a')];
      expect(treeDropOf(outOfPinned, 2), const TreeDrop(workspaceId: 'w1', sessionId: 'b', beforeId: 'a', pin: false));
      // On the boundary it keeps its zone: a pinned row after the last pinned one.
      final boundary = [_head('w1'), _row('w1', 'x', pinned: true), _row('w1', 'b', pinned: true), _row('w1', 'c')];
      expect(treeDropOf(boundary, 2), const TreeDrop(workspaceId: 'w1', sessionId: 'b'));
    });
  });

  testWidgets('a long press lifts a row; dropped lower in its group, the Host gets that order', (tester) async {
    final registry = _registry();
    await pumpSmList(tester, sessions: _sessions, workspaces: registry, view: _tree);
    // c, a, b: a goes below b (to the end).
    await _drag(tester, 'a', 60);
    expect(registry.moves, [('w1', 'a', null)]);
    expect(registry.state.byId('w1')!.sessionIds, ['c', 'b', 'a']);
    // c, b, a: a goes back to the top, before c.
    await _drag(tester, 'a', -100);
    expect(registry.moves.last, ('w1', 'a', 'c'));
  });

  testWidgets('dropped in another workspace: nothing is sent, it springs back', (tester) async {
    final registry = _registry();
    await pumpSmList(tester, sessions: _sessions, workspaces: registry, view: _tree);
    await _drag(tester, 'a', 140);
    expect(registry.moves, isEmpty);
    expect(registry.pins, isEmpty);
  });

  testWidgets('the Host does not take it: 排序没有保存, and 重试 asks again', (tester) async {
    final registry = _registry()..moveSaves = false;
    await pumpSmList(tester, sessions: _sessions, workspaces: registry, view: _tree);
    await _drag(tester, 'a', 60);
    expect(registry.moves, [('w1', 'a', null)]);
    expect(find.text('排序没有保存'), findsOneWidget);
    registry.moveSaves = true;
    // The notice has slid in.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('重试'));
    await settleActions(tester);
    expect(registry.moves, [('w1', 'a', null), ('w1', 'a', null)]);
  });

  testWidgets('dragged above the pinned row: pinned first, then moved', (tester) async {
    final registry = _registry(pinned: ['c']);
    await pumpSmList(tester, sessions: _sessions, workspaces: registry, view: _tree);
    // Pinned zone: c; then a, b. Drag b over c.
    await _drag(tester, 'b', -100);
    expect(registry.pins, [('b', true)]);
    expect(registry.moves, [('w1', 'b', 'c')]);
  });

  testWidgets('a read-only list cannot drag: a long press does nothing to the order', (tester) async {
    final registry = RecordingWorkspaces(const WorkspacesState(status: WorkspacesStatus.loading, workspaces: []));
    await pumpSmList(tester, sessions: _sessions, workspaces: registry, view: _tree);
    await _drag(tester, 'a', 60);
    expect(registry.moves, isEmpty);
  });
}
