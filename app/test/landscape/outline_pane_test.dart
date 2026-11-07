// The wide sidebar's outline column and the keyboard's multi-select:
// where the outline shows (a wide window with the sidebar, nowhere else),
// what its keys do (filter or fold to a workspace, open a folder, all
// conversations, 正在发生 back to the top), its count and what it marks, no
// frames at rest; ⌘A / Esc / Delete and ⇧-click ranges while selecting.
//
//   flutter test test/landscape/outline_pane_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/happening_state.dart';
import 'package:dsh_app/state/outline_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/adaptive/adaptive_layout.dart';
import 'package:dsh_app/ui/shell/drawer/outline_pane.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../drawer/sm_ui_support.dart';
import '../drawer/support.dart' show storedView;
import '../shell/adaptive/support.dart';
import '../shell/golden_harness.dart';
import '../support/frame_counter.dart';

HappeningEntry _running(String id) => HappeningEntry(sessionId: id, title: id, phase: HappeningPhase.running);

RecordingWorkspaces _registry() => RecordingWorkspaces(
  WorkspacesState(
    status: WorkspacesStatus.ready,
    workspaces: [
      smWorkspace('w1', ['a', 'b']),
      smWorkspace('w2', ['c']),
      smWorkspace('w3', const []),
    ],
  ),
);

const _folders = [
  DrawerFolder(id: 'f1', name: '工作', tint: 0, sessionIds: ['a']),
  DrawerFolder(id: 'f2', name: '学习', tint: 5, collapsed: true, sessionIds: ['c']),
];

/// The outline alone, 56 × 700.
Future<ProviderContainer> _pumpOutline(
  WidgetTester tester, {
  List<HappeningEntry> happening = const [],
  DrawerView view = const DrawerView(loaded: true, folders: _folders),
  String? current,
}) async {
  SharedPreferences.setMockInitialValues(storedView(view));
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      overrides: [
        workspacesProvider.overrideWith(_registry),
        happeningProvider.overrideWithValue(happening),
        currentSessionProvider.overrideWith(() => FakeCurrentSession(current)),
      ],
      home: const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(height: 700, child: OutlinePane()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final container = ProviderScope.containerOf(tester.element(find.byType(OutlinePane)));
  // Stored views load asynchronously.
  await tester.runAsync(() => container.read(drawerViewProvider.notifier).setSort(view.sort));
  await tester.pump();
  return container;
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
}

bool _selected(WidgetTester tester, String key) =>
    isSemantics(isSelected: true).matches(tester.getSemantics(find.byKey(ValueKey(key))), {});

void main() {
  group('the outline column', () {
    testWidgets('keys: 正在发生, 全部, each workspace, each folder, 已归档; a count only when something happens', (
      tester,
    ) async {
      await _pumpOutline(tester);
      for (final key in [
        'outline-happening',
        'outline-all',
        'outline-ws-w1',
        'outline-ws-w2',
        'outline-ws-w3',
        'outline-folder-f1',
        'outline-folder-f2',
        'outline-archived',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('outline-badge')), findsNothing);
      expect(find.byTooltip('W-w1'), findsOneWidget);
      await _pumpOutline(tester, happening: [_running('x'), _running('y')]);
      expect(
        find.descendant(of: find.byKey(const ValueKey('outline-badge')), matching: find.text('2')),
        findsOneWidget,
      );
    });

    testWidgets('按时间: a workspace key filters the list to it; 全部 clears it', (tester) async {
      final container = await _pumpOutline(tester);
      final top = container.read(outlineScrollTopProvider);
      await _tapKey(tester, 'outline-ws-w2');
      expect(container.read(workspacePrefsProvider).selected, 'w2');
      expect(container.read(outlineScrollTopProvider), top + 1);
      await _tapKey(tester, 'outline-all');
      expect(container.read(workspacePrefsProvider).selected, isNull);
    });

    testWidgets('按工作区: a workspace key opens its group and folds the others', (tester) async {
      final container = await _pumpOutline(
        tester,
        view: const DrawerView(loaded: true, layout: DrawerLayout.tree, collapsedWorkspaces: {'w2'}),
      );
      await _tapKey(tester, 'outline-ws-w2');
      expect(container.read(drawerViewProvider).collapsedWorkspaces, {'w1', 'w3'});
      expect(container.read(workspacePrefsProvider).selected, isNull, reason: 'no filter in the tree');
      await _tapKey(tester, 'outline-all');
      expect(container.read(drawerViewProvider).collapsedWorkspaces, isEmpty);
    });

    testWidgets('a folder key: the time layout, that folder open, the others closed', (tester) async {
      final container = await _pumpOutline(
        tester,
        view: const DrawerView(loaded: true, layout: DrawerLayout.tree, folders: _folders),
      );
      await _tapKey(tester, 'outline-folder-f2');
      final view = container.read(drawerViewProvider);
      expect(view.layout, DrawerLayout.time);
      expect(view.byId('f2')!.collapsed, isFalse);
      expect(view.byId('f1')!.collapsed, isTrue);
    });

    testWidgets('正在发生 asks for the list from the top', (tester) async {
      final container = await _pumpOutline(tester);
      final top = container.read(outlineScrollTopProvider);
      await _tapKey(tester, 'outline-happening');
      expect(container.read(outlineScrollTopProvider), top + 1);
    });

    testWidgets('marks the filtered workspace, else the one holding the open conversation', (tester) async {
      final handle = tester.ensureSemantics();
      final container = await _pumpOutline(tester, current: 'c');
      expect(_selected(tester, 'outline-ws-w2'), isTrue);
      expect(_selected(tester, 'outline-all'), isTrue);
      await _tapKey(tester, 'outline-ws-w1');
      expect(container.read(outlineMarksProvider).markedWorkspaceId, 'w1');
      expect(_selected(tester, 'outline-ws-w1'), isTrue);
      expect(_selected(tester, 'outline-ws-w2'), isFalse);
      expect(_selected(tester, 'outline-all'), isFalse);
      handle.dispose();
    });

    testWidgets('at rest: no frames', (tester) async {
      await _pumpOutline(tester, happening: [_running('x')]);
      expect(await framesOver(tester, const Duration(seconds: 2)), 0);
    });
  });

  group('in the shell', () {
    const sidebarFirst = LayoutPrefs(loaded: true);

    Future<void> pumpHome(WidgetTester tester, Size size, {LayoutPrefs prefs = sidebarFirst}) async {
      useWindow(tester, size);
      await tester.pumpWidget(homeApp(prefs: prefs));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
    }

    testWidgets('1280 with the sidebar: the outline at its left, the list keeping 320', (tester) async {
      await pumpHome(tester, const Size(1280, 800));
      final outline = tester.getRect(find.byType(OutlinePane));
      final list = tester.getRect(find.byKey(const ValueKey('persistent-sidebar')));
      expect(outline.width, AdaptiveMetrics.outlineWidth);
      expect(outline.left, 0);
      expect(list.left, outline.right);
      expect(list.width, AdaptiveMetrics.sidebarWidth);
    });

    testWidgets('the sidebar folded into the rail: no outline', (tester) async {
      await pumpHome(tester, const Size(1280, 800), prefs: const LayoutPrefs(loaded: true, sidebarOpen: false));
      expect(find.byType(OutlinePane), findsNothing);
    });

    for (final size in [const Size(390, 844), const Size(700, 900)]) {
      testWidgets('${size.width.toInt()} wide (no sidebar): no outline', (tester) async {
        await pumpHome(tester, size);
        expect(find.byType(OutlinePane), findsNothing);
      });
    }

    group('multi-select keys', () {
      ProviderContainer container(WidgetTester tester) =>
          ProviderScope.containerOf(tester.element(find.byKey(const ValueKey('persistent-sidebar'))));

      Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool command = false}) async {
        final modifier = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        if (command) await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        if (command) await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        await tester.pump();
      }

      testWidgets('⌘A chooses every listed row; Esc ends it', (tester) async {
        await pumpHome(tester, const Size(1280, 800));
        final c = container(tester);
        await press(tester, LogicalKeyboardKey.keyA, command: true);
        expect(c.read(drawerSelectionProvider), isNull, reason: 'not selecting: ⌘A is left alone');
        c.read(drawerSelectionProvider.notifier).start('s2');
        await tester.pump();
        await press(tester, LogicalKeyboardKey.keyA, command: true);
        // Every conversation the sidebar lists (the sample's seven).
        expect(c.read(drawerSelectionProvider), {for (var i = 1; i <= 7; i++) 's$i'});
        await press(tester, LogicalKeyboardKey.escape);
        expect(c.read(drawerSelectionProvider), isNull);
      });

      testWidgets('⇧-click chooses the rows between, in the list\'s order', (tester) async {
        await pumpHome(tester, const Size(1280, 800));
        final c = container(tester);
        c.read(drawerSelectionProvider.notifier).start('s2');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        // High in the list: the selection bar covers the bottom of the sidebar.
        await tester.tap(find.byKey(const ValueKey('session-s4')));
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(c.read(drawerSelectionProvider), {'s2', 's3', 's4'});
        // Without ⇧, one row as before; it becomes the anchor.
        await tester.tap(find.byKey(const ValueKey('session-s3')));
        await tester.pump();
        expect(c.read(drawerSelectionProvider), {'s2', 's4'});
        expect(c.read(selectionAnchorProvider), 's3');
      });

      testWidgets('Delete archives the chosen rows and ends the selection', (tester) async {
        await pumpHome(tester, const Size(1280, 800));
        final c = container(tester);
        c.read(drawerSelectionProvider.notifier)
          ..start('s3')
          ..toggle('s4');
        await tester.pump();
        await press(tester, LogicalKeyboardKey.delete);
        await tester.pump(const Duration(milliseconds: 300));
        expect(c.read(drawerSelectionProvider), isNull);
        expect(find.byType(SnackBar), findsOneWidget);
      });
    });
  });

  group('ranges', () {
    test('selectionRange runs either way; an unlisted end is just the target', () {
      const order = ['a', 'b', 'c', 'd'];
      expect(selectionRange(order, 'b', 'd'), ['b', 'c', 'd']);
      expect(selectionRange(order, 'd', 'b'), ['b', 'c', 'd']);
      expect(selectionRange(order, 'x', 'c'), ['c']);
      expect(selectionRange(order, null, 'c'), ['c']);
    });

    test('toggledRow: one row in or out, nothing else', () {
      expect(toggledRow({'a'}, {'a', 'b'}), 'b');
      expect(toggledRow({'a', 'b'}, {'a'}), 'b');
      expect(toggledRow({'a'}, {'a', 'b', 'c'}), isNull);
      expect(toggledRow(null, {'a'}), isNull);
    });

    test('shiftRange: the range takes the clicked row\'s turn', () {
      const order = ['a', 'b', 'c', 'd'];
      expect(shiftRange(previous: {'a'}, next: {'a', 'd'}, order: order, anchor: 'a', target: 'd'), {
        'a',
        'b',
        'c',
        'd',
      });
      expect(
        shiftRange(previous: {'a', 'b', 'c', 'd'}, next: {'a', 'b', 'c'}, order: order, anchor: 'b', target: 'd'),
        {'a'},
      );
      expect(shiftRange(previous: {'a'}, next: {'a', 'b'}, order: order, anchor: null, target: 'b'), isNull);
    });
  });

  test('the sidebar widens for the outline only where the chat keeps its comfort', () {
    AdaptiveLayout at(double width) =>
        AdaptiveLayout.resolve(window: Size(width, 800), hasSession: true, panelOpen: false);
    expect(at(1280).sidebarWidth, AdaptiveMetrics.sidebarWideWidth);
    expect(at(940).sidebarWidth, AdaptiveMetrics.sidebarWidth);
    expect(at(940).left, LeftPane.sidebar);
    expect(at(700).hasOutline, isFalse);
  });
}
