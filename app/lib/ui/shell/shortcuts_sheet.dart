// ⌘/ on the home screen: the keyboard shortcuts at a glance. iPadOS shows
// an app's commands while ⌘ is held only through UIKeyCommand, which
// Flutter has no way to declare; this list stands in for it.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../theme/theme.dart';
import 'shortcuts.dart';

/// What [shortcut] does, in words.
String shortcutTitle(L10n l10n, HomeShortcut shortcut) => switch (shortcut) {
  HomeShortcut.newChat => l10n.ipadShortcutNewChat,
  HomeShortcut.search => l10n.ipadShortcutSearch,
  HomeShortcut.previousSession => l10n.ipadShortcutPrevSession,
  HomeShortcut.nextSession => l10n.ipadShortcutNextSession,
  HomeShortcut.stop => l10n.ipadShortcutStop,
  HomeShortcut.settings => l10n.ipadShortcutSettings,
  HomeShortcut.toggleList => l10n.ipadShortcutToggleList,
  HomeShortcut.toggleDetails => l10n.ipadShortcutToggleDetails,
  HomeShortcut.help => l10n.ipadShortcutHelp,
};

Future<void> showShortcutsSheet(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const ShortcutsSheet());

/// Every [HomeShortcut]: what it does, and its keys.
class ShortcutsSheet extends StatelessWidget {
  const ShortcutsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(l10n.ipadShortcutsTitle),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: bottom + 16),
            child: SheetGroup(
              children: [
                for (final shortcut in HomeShortcut.values)
                  Padding(
                    key: ValueKey('shortcut-${shortcut.name}'),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(child: Text(shortcutTitle(l10n, shortcut), style: theme.textTheme.bodyLarge)),
                        const SizedBox(width: 12),
                        Text(shortcut.label, style: AppType.mono(size: 14, height: 1.3, color: dsh.textTertiary)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
