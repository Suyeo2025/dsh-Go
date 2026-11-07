// iOS has one way to group conversations: the Host's workspaces (what DSH
// Web shows, synced across devices). This phone's own folders are neither
// shown nor offered there: no 文件夹 block (their members list by day), no
// 新建 / 管理文件夹, no 移到文件夹 in the menu or the selection bar, a left
// swipe of 置顶 and 归档 only, no folder marks, no folder keys in the iPad
// outline. Stored folders stay untouched; a host that has some says once
// where they went. Android keeps its folders (drawer_flows_test.dart and the
// rest of test/drawer run there).
//
//   flutter test test/drawer/folders_ios_test.dart

import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_list.dart';
import 'package:dsh_app/ui/shell/drawer/folder_header.dart';
import 'package:dsh_app/ui/shell/drawer/folder_sheets.dart';
import 'package:dsh_app/ui/shell/drawer/outline_pane.dart';
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/drawer/swipe_actions.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart' show DrawerViewButton;
import 'package:dsh_app/ui/workspace/directory_picker.dart' show DirectoryLocationsSheet;
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'sm_ui_support.dart';
import 'support.dart';

const _closedKey = 'drawer.folders_retired_notice_closed';

/// s1..s4; 工作 holds s2 and s3, s1 is pinned.
final _sessions = [for (var i = 1; i <= 4; i++) smSession('s$i', age: Duration(minutes: i))];

const _folders = DrawerView(
  loaded: true,
  folders: [
    DrawerFolder(id: 'f1', name: '工作', tint: 0, sessionIds: ['s2', 's3']),
  ],
);

RecordingWorkspaces _registry() =>
    RecordingWorkspaces(const WorkspacesState(status: WorkspacesStatus.ready, pinnedSessionIds: ['s1']));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

/// A left swipe of [dx] over [id]'s row, in small steps.
Future<void> _swipe(WidgetTester tester, String id, double dx) async {
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

void main() {
  setUp(() => debugRemoteOnlyOverride = true);
  tearDown(() => debugRemoteOnlyOverride = null);

  testWidgets('按时间: no folder block; its members list by day, the pinned one still on top', (tester) async {
    final container = await pumpSmList(tester, sessions: _sessions, workspaces: _registry(), view: _folders);
    expect(find.byType(DrawerFolderHeader), findsNothing);
    expect(find.text('文件夹'), findsNothing);
    for (var i = 1; i <= 4; i++) {
      expect(smTitle('s$i'), findsOneWidget);
    }
    expect(find.text('置顶'), findsOneWidget);
    expect(tester.getTopLeft(smTitle('s1')).dy, lessThan(tester.getTopLeft(smTitle('s2')).dy));
    // Members are plain rows again: no folder indent.
    final tile = tester.widget<SessionTile>(find.ancestor(of: smTitle('s2'), matching: find.byType(SessionTile)));
    expect(tile.indent, 0);
    // Nothing stored was touched.
    final kept = container.read(drawerViewProvider).folders.single;
    expect((kept.id, kept.name), ('f1', '工作'));
    expect(kept.sessionIds, ['s2', 's3']);
  });

  testWidgets('a left swipe shows 置顶 and 归档 only', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry(), view: _folders);
    await _swipe(tester, 's2', -160);
    final row = tester.state<SwipeActionsState>(find.ancestor(of: smTitle('s2'), matching: find.byType(SwipeActions)));
    expect(row.isOpen, isTrue);
    expect(find.byTooltip('取消置顶').evaluate().length + find.byTooltip('置顶').evaluate().length, 1);
    expect(find.byTooltip('归档'), findsOneWidget);
    expect(find.byTooltip('文件夹'), findsNothing);
  });

  testWidgets('按工作区: no folder marks at the rows\' end', (tester) async {
    await pumpSmList(
      tester,
      sessions: _sessions,
      workspaces: RecordingWorkspaces(
        WorkspacesState(
          status: WorkspacesStatus.ready,
          workspaces: [
            smWorkspace('w1', ['s1', 's2', 's3', 's4']),
          ],
        ),
      ),
      view: DrawerView(loaded: true, layout: DrawerLayout.tree, folders: _folders.folders),
    );
    final tile = tester.widget<SessionTile>(find.ancestor(of: smTitle('s2'), matching: find.byType(SessionTile)));
    expect(tile.trailing, isNull);
  });

  testWidgets('the view sheet: 添加工作区 where 新建文件夹 was; no 管理文件夹', (tester) async {
    SharedPreferences.setMockInitialValues(storedView(_folders));
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: const Scaffold(body: DrawerViewSheet()),
      ),
    );
    await tester.pump();
    // The ordering is switched at the top of the list only.
    expect(find.text('按工作区'), findsNothing);
    expect(find.text('新建文件夹'), findsNothing);
    expect(find.text('管理文件夹'), findsNothing);
    expect(find.text('添加工作区'), findsOneWidget);
    expect(find.text('多选'), findsOneWidget);
  });

  testWidgets('the iPad outline has no folder keys', (tester) async {
    SharedPreferences.setMockInitialValues(storedView(_folders));
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [workspacesProvider.overrideWith(_registry)],
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
    expect(find.byKey(const ValueKey('outline-folder-f1')), findsNothing);
    expect(find.byKey(const ValueKey('outline-all')), findsOneWidget);
  });

  group('in the drawer', () {
    Future<void> start(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(storedView(_folders));
      final host = DrawerHost();
      final midnight = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
      host.seedSession('s1', '修复登录按钮', midnight.add(const Duration(seconds: 3)));
      host.seedSession('s2', '深色模式', midnight.add(const Duration(seconds: 2)));
      host.seedSession('s3', 'proot 入门', midnight.add(const Duration(seconds: 1)));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
          overrides: [...workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: 's1')],
        ),
      );
      await _settle(tester);
    }

    testWidgets('the menu and the selection bar have no 移到文件夹', (tester) async {
      await start(tester);
      await tester.longPress(find.widgetWithText(SessionTile, '深色模式'));
      await _settle(tester);
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('移到文件夹'), findsNothing);
      expect(find.text('移到其他文件夹'), findsNothing);
      await tester.tap(find.text('多选'));
      await _settle(tester);
      expect(find.byType(SelectionActionBar), findsOneWidget);
      expect(find.descendant(of: find.byType(SelectionActionBar), matching: find.text('移到文件夹')), findsNothing);
      expect(find.descendant(of: find.byType(SelectionActionBar), matching: find.text('归档')), findsOneWidget);
    });

    testWidgets('⋯ › 添加工作区 is the switcher\'s flow: the host\'s folder picker', (tester) async {
      await start(tester);
      await tester.tap(find.byType(DrawerViewButton));
      await _settle(tester);
      await tester.tap(find.text('添加工作区'));
      await _settle(tester);
      expect(find.byType(DrawerViewSheet), findsNothing);
      // showDirectoryPicker, as from the switcher's 「添加工作区」.
      expect(find.byType(DirectoryLocationsSheet), findsOneWidget);
      expect(find.text('添加工作区'), findsOneWidget);
    });

    testWidgets('a host with folders: the note shows once; closed, it stays closed', (tester) async {
      await start(tester);
      expect(find.byType(FoldersRetiredNote), findsOneWidget);
      expect(find.textContaining('文件夹已并入工作区'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('folders-retired-close')));
      await _settle(tester);
      expect(find.byType(FoldersRetiredNote), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_closedKey), isTrue);
      // The folders themselves are still stored.
      expect(prefs.getString('drawer.view.local.local'), contains('工作'));
    });

    testWidgets('closed before: not shown again', (tester) async {
      SharedPreferences.setMockInitialValues({...storedView(_folders), _closedKey: true});
      final host = DrawerHost()..seedSession('s1', '修复登录按钮', DateTime.now());
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
          overrides: [...workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true))],
        ),
      );
      await _settle(tester);
      expect(find.widgetWithText(SessionTile, '修复登录按钮'), findsOneWidget);
      expect(find.byType(FoldersRetiredNote), findsNothing);
    });
  });

  testWidgets('no folders stored: no note', (tester) async {
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry());
    expect(find.byType(FoldersRetiredNote), findsNothing);
  });

  testWidgets('Android keeps its folders (and no note)', (tester) async {
    debugRemoteOnlyOverride = false;
    await pumpSmList(tester, sessions: _sessions, workspaces: _registry(), view: _folders);
    expect(find.byType(DrawerFolderHeader), findsOneWidget);
    expect(find.byType(FoldersRetiredNote), findsNothing);
  });
}
