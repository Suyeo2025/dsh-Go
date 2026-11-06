// A left swipe on a drawer row: 置顶 / 文件夹 / 归档 behind it, each doing what
// the row's menu does; one row open at a time; a vertical drag still scrolls;
// none while selecting; a long swipe archives; and in the workspace tree the
// swipe and the long-press drag don't get in each other's way.
//
//   flutter test test/drawer/swipe_actions_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/swipe_actions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show FakeSessions;
import 'sm_ui_support.dart';

final _sessions = [for (var i = 0; i < 12; i++) smSession('s$i', age: Duration(minutes: i))];

RecordingWorkspaces _registry() => RecordingWorkspaces(
  WorkspacesState(
    status: WorkspacesStatus.ready,
    workspaces: [
      smWorkspace('w1', [for (var i = 0; i < 12; i++) 's$i']),
    ],
  ),
);

SwipeActionsState _swipe(WidgetTester tester, String id) =>
    tester.state<SwipeActionsState>(find.ancestor(of: smTitle(id), matching: find.byType(SwipeActions)));

/// A finger moving [dx] sideways over [id]'s row in small, unhurried steps.
Future<void> _swipeRow(WidgetTester tester, String id, double dx) async {
  final gesture = await tester.startGesture(tester.getCenter(smTitle(id)), kind: PointerDeviceKind.touch);
  final steps = (dx.abs() / 6).ceil();
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(dx / steps, 0));
    await tester.pump(const Duration(milliseconds: 40));
  }
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Records what the swipe asked to archive (the menu's own flow; its undo
/// notice needs a live Host, covered by the drawer's archive tests).
class _ArchiveSpy extends FakeSessions {
  _ArchiveSpy() : super(_sessions);

  static final scheduled = <List<String>>[];

  @override
  PendingSessionArchive scheduleArchive(Iterable<String> ids) {
    scheduled.add(ids.toList());
    return super.scheduleArchive(ids);
  }
}

void main() {
  setUp(_ArchiveSpy.scheduled.clear);

  testWidgets('a left swipe shows 置顶, 文件夹 and 归档; 置顶 pins and puts the row back', (tester) async {
    final registry = _registry();
    await pumpSmList(tester, sessions: _sessions, workspaces: registry);
    await _swipeRow(tester, 's1', -160);
    expect(_swipe(tester, 's1').isOpen, isTrue);
    expect(find.byTooltip('置顶'), findsOneWidget);
    expect(find.byTooltip('文件夹'), findsOneWidget);
    expect(find.byTooltip('归档'), findsOneWidget);
    await tester.tap(find.byTooltip('置顶'));
    await settleActions(tester);
    expect(registry.pins, [('s1', true)]);
    expect(_swipe(tester, 's1').isOpen, isFalse);
  });

  testWidgets('文件夹 opens the move-to-folder sheet', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    await _swipeRow(tester, 's1', -160);
    await tester.tap(find.byTooltip('文件夹'));
    await settleActions(tester);
    expect(find.text('移到文件夹'), findsOneWidget);
  });

  testWidgets('归档 archives with the undo notice', (tester) async {
    await pumpSmList(
      tester,
      sessions: _sessions,
      workspaces: _registry(),
      overrides: [sessionsProvider.overrideWith(() => _ArchiveSpy())],
    );
    await _swipeRow(tester, 's1', -160);
    await tester.tap(find.byTooltip('归档'));
    await settleActions(tester);
    expect(_ArchiveSpy.scheduled, [
      ['s1'],
    ]);
  });

  testWidgets('a long swipe archives on release', (tester) async {
    await pumpSmList(
      tester,
      sessions: _sessions,
      workspaces: _registry(),
      overrides: [sessionsProvider.overrideWith(() => _ArchiveSpy())],
    );
    await _swipeRow(tester, 's2', -260);
    await settleActions(tester);
    expect(_ArchiveSpy.scheduled, [
      ['s2'],
    ]);
  });

  testWidgets('one row open at a time; a right swipe closes it', (tester) async {
    final container = await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    await _swipeRow(tester, 's1', -160);
    await _swipeRow(tester, 's3', -160);
    expect(_swipe(tester, 's3').isOpen, isTrue);
    expect(_swipe(tester, 's1').isOpen, isFalse);
    expect(container.read(openSwipeRowProvider), 's3');
    await _swipeRow(tester, 's3', 160);
    expect(_swipe(tester, 's3').isOpen, isFalse);
    expect(container.read(openSwipeRowProvider), isNull);
  });

  testWidgets('a right swipe on a closed row is not the row\'s (the drawer may take it)', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    await _swipeRow(tester, 's1', 80);
    expect(_swipe(tester, 's1').isOpen, isFalse);
  });

  testWidgets('a vertical drag scrolls the list and opens nothing', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    final before = tester.getTopLeft(smTitle('s3')).dy;
    await tester.drag(smTitle('s3'), const Offset(-12, -200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(smTitle('s3')).dy, lessThan(before));
    expect(_swipe(tester, 's3').isOpen, isFalse);
  });

  testWidgets('while selecting there is no swipe', (tester) async {
    final container = await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    container.read(drawerSelectionProvider.notifier).start('s0');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _swipeRow(tester, 's1', -160);
    expect(_swipe(tester, 's1').isOpen, isFalse);
    expect(find.byTooltip('归档'), findsNothing);
  });

  testWidgets('in the workspace tree: a quick swipe opens the keys, a long press drags', (tester) async {
    final registry = _registry();
    await pumpSmList(
      tester,
      sessions: _sessions,
      workspaces: registry,
      view: const DrawerView(loaded: true, layout: DrawerLayout.tree),
    );
    await _swipeRow(tester, 's1', -160);
    expect(_swipe(tester, 's1').isOpen, isTrue);
    expect(registry.moves, isEmpty);
    await _swipeRow(tester, 's1', 160);
    // Held still: the long press lifts it instead, no keys.
    final gesture = await tester.startGesture(tester.getCenter(smTitle('s1')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await settleActions(tester);
    expect(_swipe(tester, 's1').isOpen, isFalse);
    expect(registry.moves, [('w1', 's1', 's3')]);
  });
}
