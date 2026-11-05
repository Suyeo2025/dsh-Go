// Hardware-keyboard shortcuts on the home screen (an iPad with a keyboard,
// an Android tablet with one): new chat, search, previous / next chat, stop,
// settings, fold the list or 对话详情, and ⌘/ for the list of them. ⌘ on
// Apple platforms; Ctrl as well elsewhere. Nothing that text fields use
// (⌘A/C/V/X/Z, Enter, Esc, arrows) is taken.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/adaptive_layout_state.dart';
import '../../state/agents_state.dart' show subagentParentProvider;
import '../../state/chat_state.dart' show chatProvider;
import '../../state/drawer_view_state.dart' show drawerSelectableIds, watchDrawerBlocks;
import '../../state/sessions_state.dart' show currentSessionProvider;
import 'adaptive/adaptive_layout.dart';
import 'drawer/drawer_destination.dart';
import 'shortcuts_sheet.dart';

/// One shortcut: what it does, and its key with ⌘ (and ⇧).
enum HomeShortcut {
  newChat(LogicalKeyboardKey.keyN),
  search(LogicalKeyboardKey.keyK),
  previousSession(LogicalKeyboardKey.bracketLeft, shift: true),
  nextSession(LogicalKeyboardKey.bracketRight, shift: true),
  stop(LogicalKeyboardKey.period),
  settings(LogicalKeyboardKey.comma),
  toggleList(LogicalKeyboardKey.backslash),
  toggleDetails(LogicalKeyboardKey.keyD, shift: true),
  help(LogicalKeyboardKey.slash);

  const HomeShortcut(this.key, {this.shift = false});

  final LogicalKeyboardKey key;
  final bool shift;

  /// What the keyboard reports for [key] with ⇧ held, where it differs:
  /// Apple platforms read ⌘⇧[ as `{`.
  LogicalKeyboardKey? get shifted => switch (key) {
    LogicalKeyboardKey.bracketLeft => LogicalKeyboardKey.braceLeft,
    LogicalKeyboardKey.bracketRight => LogicalKeyboardKey.braceRight,
    _ => null,
  };

  /// ⌘ on iOS / macOS; Ctrl too on other platforms (an Android tablet's
  /// keyboard has its Ctrl where a Mac has ⌘).
  static bool get _apple => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => true,
    _ => false,
  };

  List<ShortcutActivator> get activators => [
    for (final k in [key, ?shifted]) ...[
      SingleActivator(k, meta: true, shift: shift),
      if (!_apple) SingleActivator(k, control: true, shift: shift),
    ],
  ];

  /// The key as the keyboard shows it: `⌘⇧]`, or `Ctrl+Shift+]` off Apple.
  String get label {
    final glyph = switch (key) {
      LogicalKeyboardKey.bracketLeft => '[',
      LogicalKeyboardKey.bracketRight => ']',
      LogicalKeyboardKey.period => '.',
      LogicalKeyboardKey.comma => ',',
      LogicalKeyboardKey.backslash => r'\',
      LogicalKeyboardKey.slash => '/',
      _ => key.keyLabel.toUpperCase(),
    };
    return _apple ? '⌘${shift ? '⇧' : ''}$glyph' : 'Ctrl+${shift ? 'Shift+' : ''}$glyph';
  }
}

/// Wraps the home screen: keyboard shortcuts while it is the page on top.
///
/// A [CallbackShortcuts] over a [Focus] that takes the focus when nothing
/// else has it, so keys work with no text field focused; with one focused
/// (the composer, the drawer's search) they still reach here up the focus
/// chain. Focus left on the page itself (a field unfocused, the keyboard
/// put away) comes back here.
class HomeShortcuts extends ConsumerStatefulWidget {
  const HomeShortcuts({
    super.key,
    required this.onSearch,
    required this.onMenu,
    required this.onOpen,
    required this.layout,
    required this.child,
  });

  /// 搜索对话 (the shell's search).
  final VoidCallback onSearch;

  /// ≡: fold / unfold the list (or pull the drawer over).
  final VoidCallback onMenu;

  /// A page from the drawer's destinations (设置).
  final void Function(DrawerDestination destination) onOpen;

  /// The columns as last built.
  final AdaptiveLayout Function() layout;

  final Widget child;

  @override
  ConsumerState<HomeShortcuts> createState() => _HomeShortcutsState();
}

class _HomeShortcutsState extends ConsumerState<HomeShortcuts> {
  final _focus = FocusNode(debugLabel: 'HomeShortcuts');

  /// The conversations in the list's order, as last built.
  List<String> _ids = const [];

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_reclaim);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_reclaim);
    _focus.dispose();
    super.dispose();
  }

  /// Focus that fell back to the page's scope (above this one, out of the
  /// shortcuts' reach) comes back here. Another page's focus stays put.
  void _reclaim() {
    final primary = FocusManager.instance.primaryFocus;
    if (!mounted || primary is! FocusScopeNode || _focus.hasFocus) return;
    if (!_focus.ancestors.contains(primary)) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _focus.requestFocus();
  }

  void _newChat() {
    final current = ref.read(currentSessionProvider);
    if (current == null || ref.read(subagentParentProvider(current)) != null) return;
    ref.read(currentSessionProvider.notifier).select(null);
  }

  /// [step] −1 / +1 along the list; no wrapping round.
  void _step(int step) {
    final ids = _ids;
    if (ids.isEmpty) return;
    final at = ids.indexOf(ref.read(currentSessionProvider) ?? '');
    final next = at < 0 ? (step > 0 ? 0 : -1) : at + step;
    if (next < 0 || next >= ids.length) return;
    HapticFeedback.selectionClick();
    ref.read(currentSessionProvider.notifier).select(ids[next]);
  }

  void _stop() {
    final current = ref.read(currentSessionProvider);
    if (current == null) return;
    final chat = ref.read(chatProvider(current));
    if (!chat.running || chat.stopping) return;
    unawaited(ref.read(chatProvider(current).notifier).cancel());
  }

  void _toggleDetails() {
    final layout = widget.layout();
    if (!layout.panelAvailable) return;
    // What shows, not the stored choice: a panel folded for the sidebar
    // unfolds (and folds the sidebar).
    unawaited(ref.read(layoutPrefsProvider.notifier).setPanelOpen(!layout.panelShown));
  }

  VoidCallback _action(HomeShortcut shortcut) => switch (shortcut) {
    HomeShortcut.newChat => _newChat,
    HomeShortcut.search => widget.onSearch,
    HomeShortcut.previousSession => () => _step(-1),
    HomeShortcut.nextSession => () => _step(1),
    HomeShortcut.stop => _stop,
    HomeShortcut.settings => () => widget.onOpen(DrawerDestination.settings),
    HomeShortcut.toggleList => widget.onMenu,
    HomeShortcut.toggleDetails => _toggleDetails,
    HomeShortcut.help => () => unawaited(showShortcutsSheet(context)),
  };

  @override
  Widget build(BuildContext context) {
    _ids = drawerSelectableIds(watchDrawerBlocks(ref) ?? const []);
    return CallbackShortcuts(
      bindings: {
        for (final shortcut in HomeShortcut.values)
          for (final activator in shortcut.activators) activator: _action(shortcut),
      },
      child: Focus(focusNode: _focus, autofocus: true, child: widget.child),
    );
  }
}
