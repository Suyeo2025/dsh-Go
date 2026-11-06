// A workspace's group header in the drawer's workspace tree, and the line an
// empty group shows.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'folder_header.dart';
import 'session_tile.dart';

/// The workspace's glyph on the 20 line, its title, how many conversations
/// it lists and how many run, and a chevron that turns as it opens. Same
/// 44 height and 10 edges as a conversation row. Tap: fold or unfold.
class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.title,
    required this.count,
    required this.running,
    required this.collapsed,
    required this.onTap,
  });

  final String title;
  final int count;
  final int running;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final small = AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary));
    return Semantics(
      button: true,
      expanded: !collapsed,
      label: [
        l10n.smUiWorkspaceSemantics(title, count),
        if (running > 0) l10n.smUiWorkspaceRunning(running),
      ].join(l10n.shellSemanticsSeparator),
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: Squircle.border(AppShape.md),
          child: SizedBox(
            height: SessionTile.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(AppIcons.workspace, size: DrawerFolderHeader.mark, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: SessionTile.folderIndent - DrawerFolderHeader.mark),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 15,
                        height: 1.4,
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('$count', style: small),
                  if (running > 0) ...[
                    Text(' · ', style: small),
                    Text(l10n.smUiWorkspaceRunning(running), style: small.copyWith(color: theme.colorScheme.primary)),
                  ],
                  const SizedBox(width: 4),
                  Transform.translate(
                    offset: const Offset(DrawerFolderHeader.chevronNudge, 0),
                    child: AnimatedRotation(
                      turns: collapsed ? -0.25 : 0,
                      duration: AppMotion.of(context, AppMotion.collapse),
                      curve: AppMotion.collapseCurve,
                      child: Icon(AppIcons.expand, size: 18, color: colors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An open workspace group with nothing in it: says so, and offers 新对话 in it.
class WorkspaceEmptyLine extends StatelessWidget {
  const WorkspaceEmptyLine({super.key, this.onNewChat});

  final VoidCallback? onNewChat;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.only(left: 10 + SessionTile.folderIndent, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.smUiWorkspaceEmpty,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
              ),
            ),
            if (onNewChat != null)
              TextButton(
                onPressed: onNewChat,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: Text(l10n.commonNewChat),
              ),
          ],
        ),
      ),
    );
  }
}
