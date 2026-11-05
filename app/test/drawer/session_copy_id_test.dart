// 复制会话 ID in a conversation's long-press actions, and the 仅归档 view's
// own wording when nothing is archived.
//
//   flutter test test/drawer/session_copy_id_test.dart

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/session_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../search/support.dart';
import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'support.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

void main() {
  testWidgets('long press → 复制会话 ID puts the id on the clipboard and says so', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final copied = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String?);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final host = DrawerHost();
    final midnight = DateTime(sampleNow.year, sampleNow.month, sampleNow.day);
    host.seedSession('s1', '修复登录按钮', midnight.add(const Duration(seconds: 2)));
    host.seedSession('session-42', '深色模式', midnight.add(const Duration(seconds: 1)));
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        overrides: workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: null),
      ),
    );
    await _settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    addTearDown(container.read(activeConnectionProvider).value!.client.close);

    await tester.longPress(find.widgetWithText(SessionTile, '深色模式'));
    await _settle(tester);
    // Right after 分享.
    final share = tester.getTopLeft(find.text('分享'));
    final copy = tester.getTopLeft(find.text('复制会话 ID'));
    expect(copy.dy, greaterThan(share.dy));
    final callsBefore = host.calls.length;
    await tester.tap(find.text('复制会话 ID'));
    await _settle(tester);
    expect(copied, ['session-42']);
    expect(find.text('已复制会话 ID'), findsOneWidget);
    // Nothing went to the Host for it.
    expect(host.calls.skip(callsBefore), isEmpty);
  });

  testWidgets('仅归档 with nothing archived: its own title and empty wording', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: SessionSearchPage(now: searchNow, archivedOnly: true),
        brightness: Brightness.light,
        overrides: [
          sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions())),
          sessionContentSearchProvider.overrideWithValue(FakeContentSearch()),
          currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('已归档的对话'), findsWidgets); // the field's hint and the notice
    expect(find.text('还没有归档过的对话'), findsOneWidget);
    expect(find.text('还没有对话'), findsNothing);
  });
}
