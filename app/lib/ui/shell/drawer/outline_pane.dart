// The outline column at the left of the wide-window sidebar (56 wide): 正在发生
// with its count, 全部对话, each workspace (pinned ones first), each folder,
// and 已归档 at the bottom. A key brings its part of the list into view the
// way the list allows: it filters (按时间) or folds the others away (工作区树),
// and asks the shell to scroll the list back to its top.
//
// Nothing here moves on its own: no frames at rest.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/happening_state.dart';
import '../../../state/outline_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../session_search_page.dart' show showSessionSearch;
import 'folder_mark.dart';
import 'happening_section.dart' show HappeningWhale;

class OutlinePane extends ConsumerWidget {
  const OutlinePane({super.key});

  /// One key: 44 square, 12 round.
  static const keySize = 44.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final happening = ref.watch(happeningProvider.select((list) => list.length));
    final sections = ref.watch(workspaceSectionsProvider);
    final folders = ref.watch(drawerViewProvider.select((v) => v.folders));
    final marks = ref.watch(outlineMarksProvider);
    final workspaces = [for (final section in sections) ...section.items];
    return Semantics(
      container: true,
      label: l10n.smIpadOutline,
      child: SizedBox(
        width: 56,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                // Its own controller: the sidebar's list is the primary one.
                primary: false,
                padding: const EdgeInsets.symmetric(vertical: 14),
                children: [
                  _OutlineKey(
                    key: const ValueKey('outline-happening'),
                    tooltip: l10n.smUiHappening,
                    semantics: happening == 0 ? l10n.smUiHappening : l10n.smIpadHappeningCount(happening),
                    badge: happening,
                    onTap: () => ref.read(outlineScrollTopProvider.notifier).request(),
                    child: const HappeningWhale('swim'),
                  ),
                  _OutlineKey(
                    key: const ValueKey('outline-all'),
                    tooltip: l10n.remoteWorkspaceAllChats,
                    selected: marks.selectedWorkspaceId == null,
                    onTap: () => showAll(ref),
                    child: Icon(AppIcons.chat, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  if (workspaces.isNotEmpty) const _Rule(),
                  for (final w in workspaces)
                    _OutlineKey(
                      key: ValueKey('outline-ws-${w.workspaceId}'),
                      tooltip: w.title,
                      semantics: l10n.smIpadWorkspaceKey(w.title),
                      selected: marks.markedWorkspaceId == w.workspaceId,
                      onTap: () => focusWorkspace(ref, w.workspaceId),
                      child: _Initial(title: w.title, id: w.workspaceId),
                    ),
                  if (folders.isNotEmpty) const _Rule(),
                  for (final f in folders)
                    _OutlineKey(
                      key: ValueKey('outline-folder-${f.id}'),
                      tooltip: f.name,
                      semantics: l10n.smIpadFolderKey(f.name),
                      onTap: () => focusFolder(ref, f.id),
                      child: FolderMarkGlyph.of(f, size: 20),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _OutlineKey(
                key: const ValueKey('outline-archived'),
                tooltip: l10n.shellArchived,
                onTap: () => unawaited(_openArchived(context, ref)),
                child: Icon(AppIcons.archive, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 全部对话: no workspace filter, every workspace group open.
  static void showAll(WidgetRef ref) {
    unawaited(ref.read(workspacePrefsProvider.notifier).select(null));
    final view = ref.read(drawerViewProvider.notifier);
    for (final id in ref.read(drawerViewProvider).collapsedWorkspaces) {
      unawaited(view.setWorkspaceCollapsed(id, false));
    }
    ref.read(outlineScrollTopProvider.notifier).request();
  }

  /// A workspace key: in the tree (all workspaces listed) its group opens
  /// and the others fold, once; otherwise the list filters to it.
  static void focusWorkspace(WidgetRef ref, String workspaceId) {
    final view = ref.read(drawerViewProvider);
    final filtered = ref.read(selectedWorkspaceIdProvider) != null;
    if (view.layout == DrawerLayout.tree && !filtered) {
      final notifier = ref.read(drawerViewProvider.notifier);
      for (final w in ref.read(workspacesProvider).workspaces) {
        final fold = w.workspaceId != workspaceId;
        if (view.collapsedWorkspaces.contains(w.workspaceId) != fold) {
          unawaited(notifier.setWorkspaceCollapsed(w.workspaceId, fold));
        }
      }
    } else {
      unawaited(ref.read(workspacePrefsProvider.notifier).select(workspaceId));
    }
    ref.read(outlineScrollTopProvider.notifier).request();
  }

  /// A folder key: the time layout (folders live there), that folder open
  /// and the others closed.
  static void focusFolder(WidgetRef ref, String folderId) {
    final notifier = ref.read(drawerViewProvider.notifier);
    final view = ref.read(drawerViewProvider);
    if (view.layout != DrawerLayout.time) unawaited(notifier.setLayout(DrawerLayout.time));
    for (final f in view.folders) {
      final close = f.id != folderId;
      if (f.collapsed != close) unawaited(notifier.setCollapsed(f.id, close));
    }
    ref.read(outlineScrollTopProvider.notifier).request();
  }

  static Future<void> _openArchived(BuildContext context, WidgetRef ref) async {
    final sessionId = await showSessionSearch(context, archivedOnly: true);
    if (sessionId == null || !context.mounted) return;
    ref.read(currentSessionProvider.notifier).select(sessionId);
  }
}

class _OutlineKey extends StatelessWidget {
  const _OutlineKey({
    super.key,
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.semantics,
    this.selected = false,
    this.badge = 0,
  });

  final String tooltip;
  final String? semantics;
  final VoidCallback onTap;
  final Widget child;
  final bool selected;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          label: semantics ?? tooltip,
          excludeSemantics: true,
          child: Material(
            color: selected ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
            shape: shape,
            child: InkWell(
              customBorder: shape,
              onTap: onTap,
              child: SizedBox.square(
                dimension: OutlinePane.keySize,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    child,
                    if (badge > 0)
                      Positioned(
                        top: 3,
                        right: 3,
                        child: Container(
                          key: const ValueKey('outline-badge'),
                          constraints: const BoxConstraints(minWidth: 16),
                          height: 16,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: ShapeDecoration(color: scheme.primary, shape: const StadiumBorder()),
                          child: Text(
                            badge > 99 ? '99+' : '$badge',
                            style: AppType.tabular(
                              Theme.of(context).textTheme.labelSmall!.copyWith(
                                color: scheme.onPrimary,
                                fontSize: 10,
                                height: 1,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A workspace's first letter on its identity colour.
class _Initial extends StatelessWidget {
  const _Initial({required this.title, required this.id});

  final String title;
  final String id;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final color = colors.identity[DshColors.identityIndex(id, colors.identity.length)];
    final trimmed = title.trim();
    final letter = trimmed.isEmpty ? '?' : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: ShapeDecoration(color: color.withValues(alpha: 0.22), shape: const CircleBorder()),
      child: Text(
        letter,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Color.lerp(color, Theme.of(context).colorScheme.onSurface, 0.35),
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Divider(height: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)),
  );
}
