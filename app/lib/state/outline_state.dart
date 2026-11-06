// The iPad sidebar's outline column (ui/shell/drawer/outline_pane.dart): what
// it marks as current, its request to bring the list back to the top, and
// the anchor of a Shift-click range in multi-select.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'drawer_view_state.dart';
import 'sessions_state.dart';
import 'workspaces_state.dart';

/// What the outline marks: the workspace the list is filtered to, else the
/// one holding the open conversation.
class OutlineMarks {
  const OutlineMarks({this.selectedWorkspaceId, this.currentWorkspaceId});

  /// The list's workspace filter (null: all conversations).
  final String? selectedWorkspaceId;

  /// The workspace the open conversation belongs to.
  final String? currentWorkspaceId;

  /// The workspace key drawn as current.
  String? get markedWorkspaceId => selectedWorkspaceId ?? currentWorkspaceId;

  @override
  bool operator ==(Object other) =>
      other is OutlineMarks &&
      other.selectedWorkspaceId == selectedWorkspaceId &&
      other.currentWorkspaceId == currentWorkspaceId;

  @override
  int get hashCode => Object.hash(selectedWorkspaceId, currentWorkspaceId);
}

final outlineMarksProvider = Provider<OutlineMarks>((ref) {
  final current = ref.watch(currentSessionProvider);
  return OutlineMarks(
    selectedWorkspaceId: ref.watch(selectedWorkspaceIdProvider),
    currentWorkspaceId: current == null
        ? null
        : ref.watch(workspacesProvider.select((s) => s.workspaceOf(current)?.workspaceId)),
  );
});

/// Counts requests to bring the sidebar's list back to its top (正在发生 in
/// the outline); the shell scrolls on each new value.
class OutlineScrollTopController extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final outlineScrollTopProvider = NotifierProvider<OutlineScrollTopController, int>(OutlineScrollTopController.new);

/// The row a Shift-click range starts from: the last row toggled in
/// multi-select (or the one it started with). Cleared with the selection.
class SelectionAnchorController extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(drawerSelectionProvider, (_, next) {
      if (next == null) state = null;
    });
    return null;
  }

  void set(String? id) => state = id;
}

final selectionAnchorProvider = NotifierProvider<SelectionAnchorController, String?>(SelectionAnchorController.new);

/// The rows from [anchor] to [target] inclusive, in [order] (the list's
/// selectable rows); just [target] when either is not listed.
List<String> selectionRange(List<String> order, String? anchor, String target) {
  final to = order.indexOf(target);
  final from = anchor == null ? -1 : order.indexOf(anchor);
  if (to < 0 || from < 0) return [target];
  final (a, b) = from <= to ? (from, to) : (to, from);
  return order.sublist(a, b + 1);
}

/// The one row a selection change toggled ([previous] → [next] differ by
/// exactly that id), or null for anything else (start, 全选, a range).
String? toggledRow(Set<String>? previous, Set<String>? next) {
  if (previous == null || next == null) return null;
  final added = next.difference(previous);
  final removed = previous.difference(next);
  if (added.length + removed.length != 1) return null;
  return added.isEmpty ? removed.single : added.single;
}

/// A ⇧-click on [target] (just toggled from [previous] to [next]): the rows
/// from [anchor] to it take the same turn — all chosen when it was chosen,
/// all let go when it was let go. Null when there is no range to apply.
Set<String>? shiftRange({
  required Set<String> previous,
  required Set<String> next,
  required List<String> order,
  required String? anchor,
  required String target,
}) {
  if (anchor == null || anchor == target) return null;
  final range = selectionRange(order, anchor, target);
  if (range.length < 2) return null;
  final result = next.contains(target) ? {...previous, ...range} : ({...previous}..removeAll(range));
  return result.length == next.length && result.containsAll(next) ? null : result;
}
