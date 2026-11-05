// Hardware-keyboard shortcuts on the home screen (HomeShortcuts), through
// the real home screen and chat: ⌘N, ⌘K, ⌘⇧[ / ], ⌘., ⌘,, ⌘\, ⌘⇧D, ⌘/,
// with and without a text field focused.
//
//   flutter test test/shell/shortcuts_test.dart

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/ui/shell/shortcuts.dart';
import 'package:dsh_app/ui/shell/shortcuts_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';
import 'adaptive/support.dart';

const _phone = Size(390, 844);
const _wide = Size(1280, 800);

/// s1 is generating; the others are idle.
ChatState _chat(String id) =>
    ChatState(loading: false, running: id == 's1', items: [user(1, 'q $id'), assistant(2, 'a $id')]);

Future<ProviderContainer> _pump(WidgetTester tester, {Size size = _phone, String? session = 's1'}) async {
  useWindow(tester, size);
  mockClipboard(tester);
  await tester.pumpWidget(homeApp(session: session, chat: _chat));
  await pumpFrames(tester, 8);
  return ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
}

/// ⌘ (+ ⇧) + [key].
Future<void> _press(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await pumpFrames(tester, 8);
}

void main() {
  testWidgets('⌘N: a new chat', (tester) async {
    final container = await _pump(tester);
    expect(container.read(currentSessionProvider), 's1');
    await _press(tester, LogicalKeyboardKey.keyN);
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('⌘N with the composer focused still starts a new chat', (tester) async {
    final container = await _pump(tester);
    await tester.showKeyboard(find.byType(EditableText).first);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull);
    await _press(tester, LogicalKeyboardKey.keyN);
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('focus left on the page comes back to the shortcuts', (tester) async {
    final container = await _pump(tester);
    await tester.showKeyboard(find.byType(EditableText).first);
    await tester.pump();
    // The keyboard put away: focus falls back to the route's scope.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _press(tester, LogicalKeyboardKey.keyN);
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('⌘⇧] / ⌘⇧[: the next and previous chat in the list, not wrapping round', (tester) async {
    final container = await _pump(tester);
    await _press(tester, LogicalKeyboardKey.bracketRight, shift: true);
    expect(container.read(currentSessionProvider), 's2');
    await _press(tester, LogicalKeyboardKey.bracketRight, shift: true);
    expect(container.read(currentSessionProvider), 's3');
    await _press(tester, LogicalKeyboardKey.bracketLeft, shift: true);
    await _press(tester, LogicalKeyboardKey.bracketLeft, shift: true);
    expect(container.read(currentSessionProvider), 's1');
    // The first already: nowhere further up.
    await _press(tester, LogicalKeyboardKey.bracketLeft, shift: true);
    expect(container.read(currentSessionProvider), 's1');
  });

  test('⌘⇧[ / ] also as ⌘⇧{ / }, how Apple keyboards report them', () {
    bool binds(HomeShortcut shortcut, LogicalKeyboardKey key) =>
        shortcut.activators.any((a) => a is SingleActivator && a.trigger == key && a.meta && a.shift);
    expect(binds(HomeShortcut.nextSession, LogicalKeyboardKey.braceRight), isTrue);
    expect(binds(HomeShortcut.previousSession, LogicalKeyboardKey.braceLeft), isTrue);
    expect(binds(HomeShortcut.nextSession, LogicalKeyboardKey.bracketRight), isTrue);
  });

  testWidgets('⌘.: stops the turn being generated', (tester) async {
    final container = await _pump(tester);
    final chat = container.read(chatProvider('s1').notifier) as FakeChatController;
    await _press(tester, LogicalKeyboardKey.period);
    expect(chat.cancels, 1);
  });

  testWidgets('⌘. with nothing generating does nothing', (tester) async {
    final container = await _pump(tester, session: 's2');
    final chat = container.read(chatProvider('s2').notifier) as FakeChatController;
    await _press(tester, LogicalKeyboardKey.period);
    expect(chat.cancels, 0);
  });

  testWidgets('⌘K: search', (tester) async {
    await _pump(tester);
    await _press(tester, LogicalKeyboardKey.keyK);
    expect(find.byType(SessionSearchPage), findsOneWidget);
  });

  testWidgets('⌘,: settings', (tester) async {
    await _pump(tester);
    await _press(tester, LogicalKeyboardKey.comma);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('⌘/: the list of shortcuts, every one named', (tester) async {
    await _pump(tester);
    await _press(tester, LogicalKeyboardKey.slash);
    expect(find.byType(ShortcutsSheet), findsOneWidget);
    for (final shortcut in HomeShortcut.values) {
      expect(find.byKey(ValueKey('shortcut-${shortcut.name}')), findsOneWidget);
      expect(find.text(shortcut.label), findsOneWidget);
    }
    // Android's keyboard: Ctrl.
    expect(find.text(r'Ctrl+\'), findsOneWidget);
    expect(find.text('Ctrl+Shift+]'), findsOneWidget);
  });

  testWidgets('Ctrl works where ⌘ does off Apple platforms', (tester) async {
    final container = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpFrames(tester, 4);
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('wide: ⌘⇧D folds and unfolds 对话详情, ⌘\\ the list', (tester) async {
    await _pump(tester, size: _wide);
    final collapse = find.byKey(const ValueKey('panel-collapse'));
    final sidebar = find.byKey(const ValueKey('persistent-sidebar'));
    expect(collapse, findsOneWidget);
    expect(sidebar, findsNothing);
    await _press(tester, LogicalKeyboardKey.keyD, shift: true);
    expect(collapse, findsNothing);
    // The panel folded: the sidebar fits again.
    expect(sidebar, findsOneWidget);
    await _press(tester, LogicalKeyboardKey.keyD, shift: true);
    expect(collapse, findsOneWidget);
    expect(sidebar, findsNothing);
    // ⌘\ unfolds the sidebar, which folds the panel; again folds it.
    await _press(tester, LogicalKeyboardKey.backslash);
    expect(sidebar, findsOneWidget);
    expect(collapse, findsNothing);
    await _press(tester, LogicalKeyboardKey.backslash);
    expect(sidebar, findsNothing);
  });
}
