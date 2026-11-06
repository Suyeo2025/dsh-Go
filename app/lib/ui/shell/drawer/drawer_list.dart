// The drawer's conversation list once it has loaded: DS Bot's row, the
// 按时间 / 工作区树 switch, then
// * 按时间: 置顶, the folders (opening and closing in place), then the rest
//   by day;
// * 工作区树: one foldable group per workspace in the Host's manual order
//   (its pinned zone first), rows dragged within their group after a long
//   press, then 其它对话;
// or, under a status filter, just the matches. A left swipe on a row shows
// 置顶 / 文件夹 / 归档 (swipe_actions.dart). Loading, error and empty-host
// states stay with the drawer (sessions_drawer.dart).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/session_attention_state.dart';
import '../../../state/session_created_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import '../../common/empty_view.dart';
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../sessions_drawer.dart' show sessionTitle;
import 'archive_notice.dart';
import 'drawer_actions.dart';
import 'folder_header.dart';
import 'folder_mark.dart';
import 'layout_switch.dart';
import 'row_actions.dart';
import 'session_tile.dart';
import 'swipe_actions.dart';
import 'workspace_header.dart';

// ── Drops in the workspace tree ──────────────────────────────────────────────

/// What a row of the tree is, as far as a drop cares: a workspace's header,
/// one of its conversations (in the pinned zone or not), or anything else.
@immutable
class TreeSlot {
  const TreeSlot({this.groupId, this.header = false, this.sessionId, this.pinned = false});

  /// The workspace the row belongs to (null: no group, or 其它对话).
  final String? groupId;
  final bool header;
  final String? sessionId;
  final bool pinned;

  bool get member => groupId != null && sessionId != null;
}

/// What a drop asks of the Host.
@immutable
class TreeDrop {
  const TreeDrop({required this.workspaceId, required this.sessionId, this.beforeId, this.pin});

  final String workspaceId;
  final String sessionId;

  /// `workspace/insertSessionBefore`'s anchor; null: to the end.
  final String? beforeId;

  /// Into the pinned zone (true), out of it (false), or neither (null).
  final bool? pin;

  @override
  bool operator ==(Object other) =>
      other is TreeDrop &&
      other.workspaceId == workspaceId &&
      other.sessionId == sessionId &&
      other.beforeId == beforeId &&
      other.pin == pin;

  @override
  int get hashCode => Object.hash(workspaceId, sessionId, beforeId, pin);

  @override
  String toString() => 'TreeDrop($workspaceId, $sessionId, before: $beforeId, pin: $pin)';
}

/// The drop of the row now at [to] of [order] (the rows once moved), or null
/// when it may not land there: outside its own group (another workspace,
/// 其它对话, above every group, under a folded header).
///
/// Its zone follows its neighbours: after a pinned row (or first, before
/// one) it is pinned, after an unpinned row it is not; on the boundary it
/// keeps what it was. The anchor is the next row of that zone in its group.
TreeDrop? treeDropOf(List<TreeSlot> order, int to) {
  final moved = order[to];
  final group = moved.groupId;
  final id = moved.sessionId;
  if (group == null || id == null || to == 0) return null;
  final prev = order[to - 1];
  if (prev.groupId != group || !(prev.header || prev.member)) return null;
  final next = to + 1 < order.length && order[to + 1].groupId == group && order[to + 1].member ? order[to + 1] : null;
  final bool pinned;
  if (prev.header) {
    pinned =
        (next?.pinned ?? false) || (moved.pinned && next != null && !next.pinned) || (moved.pinned && next == null);
  } else if (!prev.pinned) {
    pinned = false;
  } else {
    // After a pinned row: pinned when one follows, else on the boundary.
    pinned = (next?.pinned ?? false) || moved.pinned;
  }
  String? before;
  for (var i = to + 1; i < order.length; i++) {
    final s = order[i];
    if (s.groupId != group || !s.member) break;
    if (s.pinned == pinned) {
      before = s.sessionId;
      break;
    }
  }
  return TreeDrop(workspaceId: group, sessionId: id, beforeId: before, pin: pinned == moved.pinned ? null : pinned);
}

// ── The list ─────────────────────────────────────────────────────────────────

/// A list item's own key, around its row's [Key] (a row's widget keeps its
/// key too: the two never meet as siblings).
class _ListKey extends ValueKey<Key> {
  const _ListKey(super.value);
}

/// A row of the list: built only when it comes into view. [lifted]: the
/// copy that follows the finger while dragging.
class _Row {
  _Row(this.key, this.build, {this.slot = const TreeSlot(), this.draggable = false});

  final Key key;
  final Widget Function(BuildContext context, bool lifted) build;
  final TreeSlot slot;
  final bool draggable;
}

/// A workspace group folding: [opening] / [closing] are built in the old
/// state for one frame, then animate.
enum _Fold { opening, opened, closing, closed }

class DrawerConversationList extends ConsumerStatefulWidget {
  const DrawerConversationList({
    super.key,
    required this.onOpen,
    required this.onLongPress,
    this.onMore,
    this.onManageWorkspaces,
    this.onNewChat,
    this.leading,
    this.now,
    this.readOnly = false,
  });

  /// Opens a conversation (and closes the drawer).
  final ValueChanged<String> onOpen;

  /// Closes the drawer after choosing a folder for a new conversation.
  final VoidCallback? onNewChat;

  /// A conversation's actions.
  final void Function(SessionSummary session) onLongPress;

  /// The ⋯ key of a row in the workspace tree ([workspaceId]: the group it
  /// is in, null under 其它对话): its actions, with the four moves.
  final void Function(SessionSummary session, String? workspaceId)? onMore;

  /// 管理工作区, when the tree has no workspace to show.
  final VoidCallback? onManageWorkspaces;

  /// Above everything when nothing is filtered or chosen (DS Bot's row).
  final Widget? leading;

  /// Clock override for the day groups (tests).
  final DateTime? now;
  final bool readOnly;

  /// The list's padding: rows' edges on the drawer's 10 line.
  static const padding = EdgeInsets.fromLTRB(10, 4, 10, 16);

  @override
  ConsumerState<DrawerConversationList> createState() => _DrawerConversationListState();
}

class _DrawerConversationListState extends ConsumerState<DrawerConversationList> {
  final Map<String, _Fold> _fold = {};
  final Map<String, Timer> _foldTimers = {};

  @override
  void dispose() {
    for (final t in _foldTimers.values) {
      t.cancel();
    }
    super.dispose();
  }

  void _toggleGroup(String id, {required bool collapsed}) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    unawaited(ref.read(drawerViewProvider.notifier).toggleWorkspaceCollapsed(id));
    if (reduced) return;
    _foldTimers.remove(id)?.cancel();
    setState(() => _fold[id] = collapsed ? _Fold.opening : _Fold.closing);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _fold[id] = switch (_fold[id]) {
          _Fold.opening => _Fold.opened,
          _Fold.closing => _Fold.closed,
          final other => other ?? _Fold.opened,
        };
      });
    });
    _foldTimers[id] = Timer(AppMotion.collapse + const Duration(milliseconds: 60), () {
      _foldTimers.remove(id);
      if (mounted) setState(() => _fold.remove(id));
    });
  }

  Future<void> _togglePin(SessionSummary s) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final wasPinned = ref.read(workspacesProvider).pinnedSessionIds.contains(s.sessionId);
    final result = await togglePin(ref, s.sessionId);
    if (result == RowActionResult.failed) {
      messenger?.showSnackBar(SnackBar(content: Text(wasPinned ? appL10n.shellUnpinFailed : appL10n.shellPinFailed)));
    }
  }

  void _archive(SessionSummary s) {
    final title = sessionTitle(s);
    unawaited(
      scheduleArchiveNotice(context, ref, [
        s.sessionId,
      ], s.running ? appL10n.shellChatStoppedArchived(title) : appL10n.shellChatArchived(title)),
    );
  }

  Future<void> _drop(TreeDrop drop) async {
    if (drop.pin != null) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final result = await togglePin(ref, drop.sessionId);
      if (result != RowActionResult.ok) {
        if (result == RowActionResult.failed) {
          messenger?.showSnackBar(
            SnackBar(content: Text(drop.pin! ? appL10n.shellPinFailed : appL10n.shellUnpinFailed)),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    await moveRowFlow(context, ref, drop.workspaceId, drop.sessionId, beforeId: drop.beforeId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final readOnly = widget.readOnly;
    final blocks = watchDrawerBlocks(ref, now: widget.now);
    if (blocks == null) return const SizedBox.shrink();
    final selection = ref.watch(drawerSelectionProvider);
    final selecting = !readOnly && selection != null;
    final filter = ref.watch(drawerFilterProvider);
    final current = ref.watch(currentSessionProvider);
    final pending = ref.watch(pendingInteractionsProvider);
    final unread = ref.watch(unreadSessionIdsProvider);
    final pinned = ref.watch(workspacesProvider.select((s) => s.pinnedSessionIds)).toSet();
    final sort = ref.watch(drawerViewProvider.select((v) => v.sort));
    final layout = ref.watch(drawerViewProvider.select((v) => v.layout));
    final folders = ref.watch(drawerViewProvider);
    final folderOf = folders.folderOf;
    final selectedWorkspace = ref.watch(selectedWorkspaceIdProvider);
    final tree = layout == DrawerLayout.tree && filter == DrawerFilter.all;
    if (!readOnly && sort == DrawerSort.created) {
      final ids = [
        for (final block in blocks)
          for (final s in block.items) s.sessionId,
      ];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) ref.read(sessionCreatedProvider.notifier).ensure(ids);
      });
    }
    final selectionNotifier = ref.read(drawerSelectionProvider.notifier);
    final swipe = !selecting && !readOnly;

    // Always in the tree (off while selecting): the row keeps its state.
    Widget swipeable(SessionSummary s, Widget child) => SwipeActions(
      enabled: swipe,
      id: s.sessionId,
      pinned: pinned.contains(s.sessionId),
      onPin: () => unawaited(_togglePin(s)),
      onFolder: () => unawaited(moveToFolderFlow(context, ref, [s.sessionId])),
      onArchive: () => _archive(s),
      child: child,
    );

    Widget tile(SessionSummary s, {bool inFolder = false}) {
      final id = s.sessionId;
      return swipeable(
        s,
        SessionTile(
          key: ValueKey('session-$id'),
          title: sessionTitle(s),
          running: s.running,
          current: id == current,
          pending: readOnly ? null : pending[id],
          unread: !readOnly && unread.contains(id),
          pinned: inFolder && pinned.contains(id),
          indent: inFolder ? SessionTile.folderIndent : 0,
          selecting: selecting,
          selected: selection?.contains(id) ?? false,
          onTap: selecting ? () => selectionNotifier.toggle(id) : () => widget.onOpen(id),
          onLongPress: readOnly
              ? null
              : selecting
              ? () => selectionNotifier.toggle(id)
              : () => widget.onLongPress(s),
        ),
      );
    }

    // Keep only builders for off-screen rows: preparing a title and a tile for
    // every conversation makes even a selection change scale with the history.
    final rows = <_Row>[];
    void add(Key key, WidgetBuilder builder, {TreeSlot slot = const TreeSlot()}) =>
        rows.add(_Row(key, (context, _) => builder(context), slot: slot));
    void addSessions(List<SessionSummary> items) {
      for (final s in items) {
        add(ValueKey('session-${s.sessionId}'), (_) => tile(s));
      }
    }

    final showLeading = widget.leading != null && filter == DrawerFilter.all && !selecting;
    if (showLeading) {
      const key = ValueKey('leading');
      add(key, (_) => KeyedSubtree(key: key, child: widget.leading!));
    }
    if (!selecting) {
      const key = ValueKey('layout-switch');
      add(key, (_) => const DrawerLayoutSwitch(key: key));
    }

    if (tree) {
      final registry = ref.watch(workspacesProvider);
      final mouse = RendererBinding.instance.mouseTracker.mouseIsConnected;
      if (registry.ready && registry.workspaces.isEmpty && selectedWorkspace == null) {
        const key = ValueKey('tree-no-workspaces');
        add(
          key,
          (_) => Padding(
            key: key,
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: EmptyView(
              compact: true,
              icon: AppIcons.workspace,
              title: l10n.remoteWorkspaceEmpty,
              actionLabel: widget.onManageWorkspaces == null ? null : l10n.remoteWorkspaceManage,
              onAction: widget.onManageWorkspaces,
            ),
          ),
        );
      }
      for (final block in blocks) {
        switch (block) {
          case WorkspaceBlock(:final workspace, :final items, :final pinnedCount, :final canReorder):
            final ws = workspace.workspaceId;
            final headed = selectedWorkspace == null;
            if (headed && block.sectionTitle != null) {
              final key = ValueKey('ws-section-$ws');
              add(key, (_) => DrawerEyebrow(block.sectionTitle!, key: key));
            }
            if (headed) {
              final key = ValueKey('ws-$ws');
              add(
                key,
                (_) => WorkspaceHeader(
                  key: key,
                  title: workspace.title,
                  count: items.length,
                  running: block.runningCount,
                  collapsed: block.collapsed,
                  onTap: () => _toggleGroup(ws, collapsed: block.collapsed),
                ),
                slot: TreeSlot(groupId: ws, header: true),
              );
            } else {
              // A chosen workspace is its group alone: an invisible header
              // keeps the first row a valid drop place.
              final key = ValueKey('ws-$ws');
              add(
                key,
                (_) => SizedBox(key: key, height: 0),
                slot: TreeSlot(groupId: ws, header: true),
              );
            }
            final fold = _fold[ws];
            if (block.collapsed && fold == null) break;
            final bool? reveal = switch (fold) {
              _Fold.opening || _Fold.closed => false,
              _Fold.opened || _Fold.closing => true,
              null => null,
            };
            Widget folding(Key key, Widget child) =>
                reveal == null ? child : ExpandReveal(key: key, open: reveal, child: child);
            if (items.isEmpty) {
              final key = ValueKey('ws-empty-$ws');
              add(
                key,
                (_) => folding(
                  key,
                  WorkspaceEmptyLine(
                    onNewChat: readOnly
                        ? null
                        : () async {
                            await ref.read(workspacePrefsProvider.notifier).select(ws);
                            ref.read(currentSessionProvider.notifier).select(null);
                            widget.onNewChat?.call();
                          },
                  ),
                ),
                slot: TreeSlot(groupId: ws),
              );
              break;
            }
            for (var i = 0; i < items.length; i++) {
              final s = items[i];
              final id = s.sessionId;
              final inPinnedZone = i < pinnedCount;
              final lastPinned = inPinnedZone && i == pinnedCount - 1 && pinnedCount < items.length;
              final draggable = canReorder && !selecting && fold == null;
              final key = ValueKey('session-$id');
              final index = rows.length;
              rows.add(
                _Row(
                  key,
                  (context, lifted) {
                    final folder = folders.byId(folderOf[id]);
                    final handle = draggable && (lifted || mouse)
                        ? ReorderableDragStartListener(
                            index: index,
                            child: Tooltip(
                              message: l10n.smUiDragToReorder,
                              child: Icon(AppIcons.dragHandle, size: 16, color: DshColors.of(context).textTertiary),
                            ),
                          )
                        : null;
                    Widget row = SessionTile(
                      key: ValueKey('session-$id'),
                      title: sessionTitle(s),
                      running: s.running,
                      current: id == current,
                      pending: readOnly ? null : pending[id],
                      unread: !readOnly && unread.contains(id),
                      pinned: inPinnedZone,
                      indent: headed ? SessionTile.folderIndent : 0,
                      selecting: selecting,
                      selected: selection?.contains(id) ?? false,
                      trailing: folder == null && handle == null
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (folder != null) FolderMarkGlyph.of(folder, size: 12),
                                if (folder != null && handle != null) const SizedBox(width: 6),
                                ?handle,
                              ],
                            ),
                      onMore: readOnly || selecting || widget.onMore == null ? null : () => widget.onMore!(s, ws),
                      onTap: selecting ? () => selectionNotifier.toggle(id) : () => widget.onOpen(id),
                      // A long press drags here; the actions are on ⋯.
                      onLongPress: readOnly
                          ? null
                          : selecting
                          ? () => selectionNotifier.toggle(id)
                          : draggable
                          ? null
                          : () => widget.onLongPress(s),
                    );
                    if (inPinnedZone) row = _PinnedZone(last: lastPinned, child: row);
                    if (!lifted) {
                      row = swipeable(s, row);
                      row = ReorderableDelayedDragStartListener(index: index, enabled: draggable, child: row);
                    }
                    return folding(key, row);
                  },
                  slot: TreeSlot(groupId: ws, sessionId: id, pinned: inPinnedZone),
                  draggable: draggable,
                ),
              );
            }
          case LooseBlock(:final items):
            const key = ValueKey('loose-label');
            add(key, (_) => DrawerEyebrow(l10n.smUiOtherChats, key: key));
            for (final s in items) {
              add(
                ValueKey('session-${s.sessionId}'),
                (_) => KeyedSubtree(
                  child: swipeable(
                    s,
                    SessionTile(
                      key: ValueKey('session-${s.sessionId}'),
                      title: sessionTitle(s),
                      running: s.running,
                      current: s.sessionId == current,
                      pending: readOnly ? null : pending[s.sessionId],
                      unread: !readOnly && unread.contains(s.sessionId),
                      selecting: selecting,
                      selected: selection?.contains(s.sessionId) ?? false,
                      trailing: switch (folders.byId(folderOf[s.sessionId])) {
                        final folder? => FolderMarkGlyph.of(folder, size: 12),
                        null => null,
                      },
                      onMore: readOnly || selecting || widget.onMore == null ? null : () => widget.onMore!(s, null),
                      onTap: selecting ? () => selectionNotifier.toggle(s.sessionId) : () => widget.onOpen(s.sessionId),
                      onLongPress: readOnly
                          ? null
                          : selecting
                          ? () => selectionNotifier.toggle(s.sessionId)
                          : () => widget.onLongPress(s),
                    ),
                  ),
                ),
              );
            }
          case FilteredBlock(filter: final matching, :final items) when items.isEmpty:
            const key = ValueKey('filter-empty');
            add(key, (_) => _FilterEmpty(matching, key: key));
          case FilteredBlock(:final items):
            addSessions(items);
          default:
            break;
        }
      }
      return _closeSwipeOnScroll(_TreeList(rows: rows, onDrop: (drop) => unawaited(_drop(drop))));
    }

    var foldersLabelled = false;
    for (final block in blocks) {
      switch (block) {
        case FilteredBlock(filter: final matching, :final items) when items.isEmpty:
          const key = ValueKey('filter-empty');
          add(key, (_) => _FilterEmpty(matching, key: key));
        case FilteredBlock(:final items):
          addSessions(items);
        case PinnedBlock(:final items):
          const key = ValueKey('pinned-label');
          add(key, (_) => DrawerEyebrow(l10n.commonPin, key: key));
          addSessions(items);
        case FolderBlock(:final folder, :final items):
          if (!foldersLabelled) {
            foldersLabelled = true;
            const key = ValueKey('folders-label');
            add(key, (_) => DrawerEyebrow(l10n.shellFolders, key: key));
          }
          final headerKey = ValueKey('folder-${folder.id}');
          add(
            headerKey,
            (_) => DrawerFolderHeader(
              key: headerKey,
              folder: folder,
              count: items.length,
              onTap: () => ref.read(drawerViewProvider.notifier).toggleCollapsed(folder.id),
              onLongPress: () {
                if (!readOnly) folderActionsFlow(context, ref, folder, onNewChat: widget.onNewChat);
              },
            ),
          );
          final bodyKey = ValueKey('folder-body-${folder.id}');
          add(
            bodyKey,
            (_) => DrawerFolderBody(
              key: bodyKey,
              open: !folder.collapsed,
              childrenBuilder: () => [for (final s in items) tile(s, inFolder: true)],
            ),
          );
        case DayBlock(:final day, :final items):
          final key = ValueKey('day-${day.name}');
          add(key, (_) => DrawerEyebrow(sessionDayLabels[day]!, key: key));
          addSessions(items);
        // The tree's blocks only come with the tree layout.
        default:
          break;
      }
    }
    // Preserve keyed row/folder state when pinning, sorting or hiding the
    // leading row changes indices. A new filter still starts at the top.
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    return _closeSwipeOnScroll(
      ListView.builder(
        key: ValueKey(filter),
        physics: AppMotion.scrollPhysics(context),
        padding: DrawerConversationList.padding,
        itemCount: rows.length,
        itemBuilder: (context, index) =>
            KeyedSubtree(key: _ListKey(rows[index].key), child: rows[index].build(context, false)),
        findChildIndexCallback: (key) => key is _ListKey ? indices[key.value] : null,
      ),
    );
  }

  /// A scroll by the finger puts an open row's keys away.
  Widget _closeSwipeOnScroll(Widget list) => NotificationListener<ScrollStartNotification>(
    onNotification: (n) {
      if (n.dragDetails != null && ref.read(openSwipeRowProvider) != null) {
        ref.read(openSwipeRowProvider.notifier).close();
      }
      return false;
    },
    child: list,
  );
}

/// The workspace tree: one reorderable list, so dragging scrolls the whole
/// drawer at its edges; only conversation rows of a group take a drop.
class _TreeList extends ConsumerWidget {
  const _TreeList({required this.rows, required this.onDrop});

  final List<_Row> rows;
  final ValueChanged<TreeDrop> onDrop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final scheme = Theme.of(context).colorScheme;
    return CustomScrollView(
      key: const ValueKey('drawer-tree'),
      physics: AppMotion.scrollPhysics(context),
      slivers: [
        SliverPadding(
          padding: DrawerConversationList.padding,
          sliver: SliverReorderableList(
            itemCount: rows.length,
            findChildIndexCallback: (key) => key is _ListKey ? indices[key.value] : null,
            itemBuilder: (context, index) {
              final row = rows[index];
              return KeyedSubtree(key: _ListKey(row.key), child: row.build(context, false));
            },
            onReorderStart: (_) {
              HapticFeedback.selectionClick();
              ref.read(openSwipeRowProvider.notifier).close();
            },
            onReorderItem: (from, to) {
              if (from == to || !rows[from].draggable) return;
              final order = [for (final r in rows) r.slot];
              final moved = order.removeAt(from);
              order.insert(to, moved);
              final drop = treeDropOf(order, to);
              if (drop != null) onDrop(drop);
            },
            proxyDecorator: (child, index, animation) {
              final lifted = Material(type: MaterialType.transparency, child: rows[index].build(context, true));
              if (reduced) return lifted;
              return AnimatedBuilder(
                animation: animation,
                child: lifted,
                builder: (context, child) {
                  final t = Curves.easeOut.transform(animation.value);
                  return Transform.scale(
                    scale: 1 - 0.08 * t,
                    child: Material(
                      color: scheme.surface.withValues(alpha: 0.96 * t),
                      elevation: 8 * t,
                      shadowColor: Colors.black26,
                      shape: Squircle.border(AppShape.md),
                      clipBehavior: Clip.antiAlias,
                      child: child,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The pinned zone at the top of a workspace group: a faint fill, and a hair
/// line under its last row.
class _PinnedZone extends StatelessWidget {
  const _PinnedZone({required this.last, required this.child});

  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.03),
        border: last ? Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))) : null,
      ),
      child: child,
    );
  }
}

/// A status filter with no matches.
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty(this.filter, {super.key});

  final DrawerFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, title) = switch (filter) {
      DrawerFilter.running => (AppIcons.running, l10n.shellNoRunningChats),
      DrawerFilter.pending => (AppIcons.toConfirm, l10n.shellNoPendingChats),
      DrawerFilter.unread => (AppIcons.allRead, l10n.shellNoUnreadChats),
      DrawerFilter.all => (AppIcons.chat, l10n.shellNoChatsYet),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: EmptyView(compact: true, icon: icon, title: title),
    );
  }
}
