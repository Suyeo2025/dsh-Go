// The drawer row's quick actions without any UI: 置顶 / 取消置顶, 归档 and
// the four keyboard / screen-reader moves of the workspace tree (上移一位,
// 下移一位, 移到最前, 移到最后). The swipe keys, the ⋯ menu and the keyboard
// all call these and decide themselves what to show for the result; nothing
// here opens a sheet, a dialog or a snack bar.
//
// Each returns [RowActionResult.notAllowed] without touching the Host when
// the drawer's list is read-only (cached / reconnecting), the conversation
// is not in it, or (pins, moves) the workspace registry is not ready.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../state/drawer_view_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';

enum RowActionResult {
  ok,

  /// The Host refused or the request failed; nothing changed.
  failed,

  /// Not offered here: a read-only list, an unknown row, or no registry.
  notAllowed,
}

/// `ref.read` of a [WidgetRef], a `Ref` or a `ProviderContainer`.
typedef RowRead = T Function<T>(ProviderListenable<T> provider);

/// [moveRow] deltas for 移到最前 / 移到最后 (any larger step clamps too).
const int rowMoveFirst = -(1 << 30);
const int rowMoveLast = 1 << 30;

bool _listed(RowRead read, String sessionId) {
  final scope = read(drawerScopeProvider);
  return scope != null && !scope.readOnly && scope.sessions.any((s) => s.sessionId == sessionId);
}

/// 置顶 when [sessionId] is not pinned, else 取消置顶 (the Host's pins).
Future<RowActionResult> togglePin(WidgetRef ref, String sessionId) => togglePinWith(ref.read, sessionId);

Future<RowActionResult> togglePinWith(RowRead read, String sessionId) async {
  if (!_listed(read, sessionId)) return RowActionResult.notAllowed;
  final registry = read(workspacesProvider);
  if (!registry.ready) return RowActionResult.notAllowed;
  final notifier = read(workspacesProvider.notifier);
  try {
    if (registry.pinnedSessionIds.contains(sessionId)) {
      await notifier.unpinSession(sessionId);
    } else {
      await notifier.pinSession(sessionId);
    }
    return RowActionResult.ok;
  } catch (_) {
    return RowActionResult.failed;
  }
}

/// Archives [sessionId] on the Host right away (running work stops).
///
/// No undo: the swipe key and the menu use `scheduleArchiveNotice` (an undo
/// window, then the same Host call) instead; this is for callers that have
/// no notice of their own.
Future<RowActionResult> archiveRow(WidgetRef ref, String sessionId) => archiveRowWith(ref.read, sessionId);

Future<RowActionResult> archiveRowWith(RowRead read, String sessionId) async {
  if (!_listed(read, sessionId)) return RowActionResult.notAllowed;
  try {
    await read(sessionsProvider.notifier).archive(sessionId);
    return RowActionResult.ok;
  } catch (_) {
    return RowActionResult.failed;
  }
}

/// Moves [sessionId] by [delta] rows inside its zone of [workspaceId]'s
/// group in the tree (the pinned zone or the rest; -1 上移一位, +1 下移一位,
/// [rowMoveFirst], [rowMoveLast]). Rows the drawer doesn't list (archived,
/// DS Bot) are not counted. Already at that end: [RowActionResult.ok] and no
/// request.
Future<RowActionResult> moveRow(WidgetRef ref, String workspaceId, String sessionId, {required int delta}) =>
    moveRowWith(ref.read, workspaceId, sessionId, delta: delta);

Future<RowActionResult> moveRowWith(RowRead read, String workspaceId, String sessionId, {required int delta}) async {
  if (!_listed(read, sessionId)) return RowActionResult.notAllowed;
  final registry = read(workspacesProvider);
  final workspace = registry.byId(workspaceId);
  if (!registry.ready || workspace == null || !workspace.sessionIds.contains(sessionId)) {
    return RowActionResult.notAllowed;
  }
  final listed = {for (final s in read(drawerScopeProvider)!.sessions) s.sessionId};
  final beforeId = rowMoveAnchor(
    order: workspace.sessionIds,
    listed: listed,
    pinned: registry.pinnedSessionIds.toSet(),
    sessionId: sessionId,
    delta: delta,
  );
  if (beforeId == rowMoveNowhere) return RowActionResult.ok;
  try {
    final saved = await read(workspacesProvider.notifier).moveSession(workspaceId, sessionId, beforeId: beforeId);
    return saved ? RowActionResult.ok : RowActionResult.failed;
  } on StateError {
    return RowActionResult.notAllowed;
  }
}

/// [rowMoveAnchor]'s answer when the row stays where it is.
const String rowMoveNowhere = '\u0000';

/// The `beforeId` of moving [sessionId] by [delta] rows inside its zone (the
/// [listed] ids of [order] that are pinned like it): the row it will precede,
/// null for the end, or [rowMoveNowhere] when it doesn't move.
String? rowMoveAnchor({
  required List<String> order,
  required Set<String> listed,
  required Set<String> pinned,
  required String sessionId,
  required int delta,
}) {
  final isPinned = pinned.contains(sessionId);
  final zone = [
    for (final id in order)
      if (id == sessionId || (listed.contains(id) && pinned.contains(id) == isPinned)) id,
  ];
  final from = zone.indexOf(sessionId);
  if (from < 0) return rowMoveNowhere;
  final to = (from + delta.clamp(-zone.length, zone.length)).clamp(0, zone.length - 1);
  if (to == from) return rowMoveNowhere;
  // Up: before the row now at [to]. Down: before the row after it.
  if (to < from) return zone[to];
  return to + 1 < zone.length ? zone[to + 1] : null;
}
