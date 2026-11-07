// How the drawer organises a host's conversations: user folders (with a
// colour or emoji mark, collapsible, reorderable), a sort order, quiet status
// filters and multi-select.
//
// The official DSH has nothing to hang folders on: `session/*` carries
// titles, `workspace/*` directory workspaces, pins and the archived set, and
// the settings document is a validated schema. So folders live on this phone,
// per host, in shared preferences — like the workspace pins and groups in
// workspaces_state.dart. A conversation is in at most one folder.
//
// On iOS ([drawerFoldersShown] false) the one way to group conversations is
// the Host's workspaces, the grouping DSH Web shows too: folders are neither
// shown nor offered there, and a host's stored folders are kept untouched.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../platform/platform_caps.dart';
import 'bots_state.dart';
import 'hosts_state.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'session_attention_state.dart';
import 'session_created_state.dart';
import 'sessions_state.dart';
import 'workspaces_state.dart';

// ── Folders ──────────────────────────────────────────────────────────────────

/// Whether this phone's own folders take part in the drawer: not on iOS,
/// where conversations are grouped by the Host's workspaces only (synced
/// with DSH Web). Stored folders stay in the preferences either way.
bool get drawerFoldersShown => !isRemoteOnlyPlatform;

/// The once-only note that folders gave way to workspaces, shown on iOS
/// where a host still has stored folders. False once closed (on this phone,
/// for every host).
class FoldersRetiredNoticeController extends Notifier<bool> {
  static const _key = 'drawer.folders_retired_notice_closed';

  @override
  bool build() {
    if (drawerFoldersShown) return false;
    unawaited(_load());
    return false;
  }

  /// Null until the stored choice is read.
  bool? _closed;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _closed = prefs.getBool(_key) ?? false;
    } catch (_) {
      _closed = false;
    }
    if (ref.mounted && !_closed!) state = true;
  }

  Future<void> close() async {
    _closed = true;
    state = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, true);
    } catch (_) {
      // Closed for this run.
    }
  }
}

/// True while the note may show (iOS, not closed); the drawer shows it only
/// where the host has stored folders.
final foldersRetiredNoticeProvider = NotifierProvider<FoldersRetiredNoticeController, bool>(
  FoldersRetiredNoticeController.new,
);

/// One user folder. [tint] indexes `DshColors.identity` (0–7); [emoji]
/// replaces the folder glyph. Neither: the plain folder glyph.
class DrawerFolder {
  const DrawerFolder({
    required this.id,
    required this.name,
    this.tint,
    this.emoji,
    this.collapsed = false,
    this.sessionIds = const [],
  });

  static DrawerFolder? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) return null;
    final tint = json['tint'];
    final emoji = json['emoji'];
    final ids = json['sessions'];
    return DrawerFolder(
      id: id,
      name: name.trim(),
      tint: tint is int && tint >= 0 && tint < markTints ? tint : null,
      emoji: emoji is String && emoji.isNotEmpty ? emoji : null,
      collapsed: json['collapsed'] == true,
      sessionIds: ids is List ? ids.whereType<String>().toList() : const [],
    );
  }

  /// Hues a folder can take (the identity palette).
  static const markTints = 8;

  final String id;
  final String name;
  final int? tint;
  final String? emoji;
  final bool collapsed;

  /// Members, most recently added first.
  final List<String> sessionIds;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'tint': ?tint,
    'emoji': ?emoji,
    if (collapsed) 'collapsed': true,
    'sessions': sessionIds,
  };

  DrawerFolder copyWith({
    String? name,
    int? Function()? tint,
    String? Function()? emoji,
    bool? collapsed,
    List<String>? sessionIds,
  }) => DrawerFolder(
    id: id,
    name: name ?? this.name,
    tint: tint == null ? this.tint : tint(),
    emoji: emoji == null ? this.emoji : emoji(),
    collapsed: collapsed ?? this.collapsed,
    sessionIds: sessionIds ?? this.sessionIds,
  );
}

/// The drawer's list order.
enum DrawerSort {
  /// Latest activity first (the host's `updatedAt`).
  activity,

  /// Newest conversation first (time of its first event).
  created,
}

/// How the list below 正在发生 is laid out.
enum DrawerLayout {
  /// 按时间: 置顶, folders, then days (the list as it has always been).
  time,

  /// 按工作区: one collapsible group per workspace in the Host's manual
  /// order, then 其它对话.
  tree,
}

/// The drawer's view of one host: folders in display order, the sort, the
/// layout and the workspace groups folded in the tree.
class DrawerView {
  const DrawerView({
    this.loaded = false,
    this.folders = const [],
    this.sort = DrawerSort.activity,
    this.layout = DrawerLayout.time,
    this.collapsedWorkspaces = const {},
  });

  factory DrawerView.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final folders = map['folders'];
    final collapsed = map['collapsedWorkspaces'];
    final seen = <String>{};
    return DrawerView(
      loaded: true,
      folders: [
        if (folders is List)
          for (final raw in folders)
            if (DrawerFolder.fromJson(raw) case final f? when seen.add(f.id)) f,
      ],
      sort: map['sort'] == 'created' ? DrawerSort.created : DrawerSort.activity,
      // Missing or unknown (older builds): the time layout, as before.
      layout: map['layout'] == 'tree' ? DrawerLayout.tree : DrawerLayout.time,
      collapsedWorkspaces: {
        if (collapsed is List)
          for (final id in collapsed)
            if (id is String && id.isNotEmpty) id,
      },
    );
  }

  final bool loaded;
  final List<DrawerFolder> folders;
  final DrawerSort sort;
  final DrawerLayout layout;

  /// Workspace ids whose group is folded in the tree.
  final Set<String> collapsedWorkspaces;

  Map<String, Object?> toJson() => {
    'folders': [for (final f in folders) f.toJson()],
    'sort': sort.name,
    // Written only when set, so a view stored by this build reads the same
    // in an older one.
    if (layout != DrawerLayout.time) 'layout': layout.name,
    if (collapsedWorkspaces.isNotEmpty) 'collapsedWorkspaces': collapsedWorkspaces.toList(),
  };

  DrawerFolder? byId(String? id) {
    if (id == null) return null;
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Conversation id → the folder it is in.
  Map<String, String> get folderOf => {
    for (final f in folders)
      for (final id in f.sessionIds) id: f.id,
  };

  DrawerView copyWith({
    List<DrawerFolder>? folders,
    DrawerSort? sort,
    DrawerLayout? layout,
    Set<String>? collapsedWorkspaces,
  }) => DrawerView(
    loaded: loaded,
    folders: folders ?? this.folders,
    sort: sort ?? this.sort,
    layout: layout ?? this.layout,
    collapsedWorkspaces: collapsedWorkspaces ?? this.collapsedWorkspaces,
  );
}

/// [DrawerView] of the active host, in shared preferences.
class DrawerViewController extends Notifier<DrawerView> {
  String _key = '';
  Future<void> _loading = Future.value();
  int _seq = 0;

  /// Preferences key of [host]'s view.
  static String keyFor(HostRef host) => 'drawer.view.${host.kind.name}.${host.id}';

  /// Longest folder name.
  static const maxName = 20;

  @override
  DrawerView build() {
    final key = keyFor(ref.watch(activeHostProvider));
    _key = key;
    _loading = _load(key);
    return const DrawerView();
  }

  /// Completes once the stored view has loaded.
  Future<void> ready() => _loading;

  Future<void> _load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (_key != key || state.loaded) return;
      state = raw == null ? const DrawerView(loaded: true) : DrawerView.fromJson(jsonDecode(raw));
    } catch (_) {
      // No preferences backend (tests) or a damaged entry: start empty.
      if (_key == key && !state.loaded) state = const DrawerView(loaded: true);
    }
  }

  /// Applies [change] once the stored view is in, so an early tap can't be
  /// undone by a late load.
  Future<void> _update(DrawerView Function(DrawerView view) change, {bool Function()? isCurrent}) async {
    final key = _key;
    await _loading;
    if (key != _key || (isCurrent != null && !isCurrent())) return;
    final next = change(state);
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(next.toJson()));
    } catch (_) {
      // Kept in memory for this run.
    }
  }

  String _newId() {
    final taken = {for (final f in state.folders) f.id};
    String id;
    do {
      id = 'f${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';
    } while (taken.contains(id));
    return id;
  }

  /// Adds a folder at the top and moves [sessionIds] into it; returns its id,
  /// or null when the originating action no longer belongs to this Host.
  Future<String?> createFolder(
    String name, {
    int? tint,
    String? emoji,
    Iterable<String> sessionIds = const [],
    bool Function()? isCurrent,
  }) async {
    String? id;
    await _update((view) {
      final created = _newId();
      id = created;
      final members = sessionIds.toSet();
      return view.copyWith(
        folders: [
          DrawerFolder(id: created, name: _clean(name), tint: tint, emoji: emoji, sessionIds: members.toList()),
          for (final f in view.folders) _without(f, members),
        ],
      );
    }, isCurrent: isCurrent);
    return id;
  }

  /// Renames or re-marks a folder. Pass `() => null` to clear a mark.
  Future<void> updateFolder(String id, {String? name, int? Function()? tint, String? Function()? emoji}) => _update(
    (view) => view.copyWith(
      folders: [
        for (final f in view.folders)
          if (f.id == id) f.copyWith(name: name == null ? null : _clean(name), tint: tint, emoji: emoji) else f,
      ],
    ),
  );

  /// Removes a folder (its conversations stay); returns it and where it was,
  /// for [restoreFolder].
  Future<(DrawerFolder, int)?> deleteFolder(String id, {bool Function()? isCurrent}) async {
    final key = _key;
    await _loading;
    if (key != _key || (isCurrent != null && !isCurrent())) return null;
    final index = state.folders.indexWhere((f) => f.id == id);
    if (index < 0) return null;
    final folder = state.folders[index];
    await _update(
      (view) => view.copyWith(folders: [...view.folders]..removeWhere((f) => f.id == id)),
      isCurrent: isCurrent,
    );
    return (folder, index);
  }

  /// Puts a deleted folder back. Conversations filed elsewhere since stay
  /// where they are now.
  Future<void> restoreFolder(DrawerFolder folder, int index, {bool Function()? isCurrent}) => _update((view) {
    if (view.byId(folder.id) != null) return view;
    final taken = view.folderOf;
    final restored = folder.copyWith(
      sessionIds: [
        for (final id in folder.sessionIds)
          if (!taken.containsKey(id)) id,
      ],
    );
    final folders = [...view.folders]..insert(index.clamp(0, view.folders.length), restored);
    return view.copyWith(folders: folders);
  }, isCurrent: isCurrent);

  Future<void> setCollapsed(String id, bool collapsed) => _update(
    (view) => view.copyWith(
      folders: [
        for (final f in view.folders)
          if (f.id == id) f.copyWith(collapsed: collapsed) else f,
      ],
    ),
  );

  Future<void> toggleCollapsed(String id) async {
    await _loading;
    final folder = state.byId(id);
    if (folder != null) await setCollapsed(id, !folder.collapsed);
  }

  /// Moves [ids] into [folderId] (null: out of any folder). Returns where
  /// each one was before, for [restoreAssignments].
  Future<Map<String, String?>> moveSessions(
    Iterable<String> ids,
    String? folderId, {
    bool Function()? isCurrent,
  }) async {
    final key = _key;
    await _loading;
    if (key != _key || (isCurrent != null && !isCurrent())) return const {};
    final moving = ids.toList();
    final before = state.folderOf;
    final previous = {for (final id in moving) id: before[id]};
    if (folderId != null && state.byId(folderId) == null) return const {};
    final set = moving.toSet();
    await _update(
      (view) => view.copyWith(
        folders: [
          for (final f in view.folders)
            if (f.id == folderId)
              f.copyWith(
                sessionIds: [
                  ...moving,
                  for (final id in f.sessionIds)
                    if (!set.contains(id)) id,
                ],
              )
            else
              _without(f, set),
        ],
      ),
      isCurrent: isCurrent,
    );
    return previous;
  }

  /// Puts conversations back where [moveSessions] found them.
  Future<void> restoreAssignments(Map<String, String?> previous) => _update((view) {
    final set = previous.keys.toSet();
    return view.copyWith(
      folders: [
        for (final f in view.folders)
          f.copyWith(
            sessionIds: [
              for (final MapEntry(:key, :value) in previous.entries)
                if (value == f.id && !f.sessionIds.contains(key)) key,
              for (final id in f.sessionIds)
                if (!set.contains(id) || previous[id] == f.id) id,
            ],
          ),
      ],
    );
  });

  /// Moves the folder at [oldIndex] to [newIndex] (its index once moved).
  Future<void> reorderFolders(int oldIndex, int newIndex) => _update((view) {
    if (oldIndex < 0 || oldIndex >= view.folders.length) return view;
    final folders = [...view.folders];
    final moved = folders.removeAt(oldIndex);
    folders.insert(newIndex.clamp(0, folders.length), moved);
    return view.copyWith(folders: folders);
  });

  Future<void> setSort(DrawerSort sort) => _update((view) => view.copyWith(sort: sort));

  /// 按时间 / 按工作区, remembered per host.
  Future<void> setLayout(DrawerLayout layout) => _update((view) => view.copyWith(layout: layout));

  /// Folds or unfolds [workspaceId]'s group in the tree.
  Future<void> setWorkspaceCollapsed(String workspaceId, bool collapsed) => _update((view) {
    if (view.collapsedWorkspaces.contains(workspaceId) == collapsed) return view;
    return view.copyWith(
      collapsedWorkspaces: collapsed
          ? {...view.collapsedWorkspaces, workspaceId}
          : ({...view.collapsedWorkspaces}..remove(workspaceId)),
    );
  });

  Future<void> toggleWorkspaceCollapsed(String workspaceId) => _update(
    (view) => view.copyWith(
      collapsedWorkspaces: view.collapsedWorkspaces.contains(workspaceId)
          ? ({...view.collapsedWorkspaces}..remove(workspaceId))
          : {...view.collapsedWorkspaces, workspaceId},
    ),
  );

  /// Drops only confirmed deleted members, including the last session in a
  /// folder; unlike a guessed empty inventory this is authoritative.
  Future<void> forgetSessions(Set<String> ids, {required bool Function() isCurrent}) => _update(
    (view) => view.copyWith(folders: [for (final folder in view.folders) _without(folder, ids)]),
    isCurrent: isCurrent,
  );

  /// Drops members the host no longer has ([known]: every stored
  /// conversation, archived ones included, so an unarchive finds its folder).
  Future<void> forgetMissing(Set<String> known) async {
    await _loading;
    final stale = state.folders.any((f) => f.sessionIds.any((id) => !known.contains(id)));
    if (!stale) return;
    await _update(
      (view) => view.copyWith(
        folders: [
          for (final f in view.folders)
            f.copyWith(
              sessionIds: [
                for (final id in f.sessionIds)
                  if (known.contains(id)) id,
              ],
            ),
        ],
      ),
    );
  }

  static String _clean(String name) {
    final trimmed = name.trim();
    return trimmed.length <= maxName ? trimmed : trimmed.substring(0, maxName);
  }

  static DrawerFolder _without(DrawerFolder f, Set<String> ids) => f.sessionIds.any(ids.contains)
      ? f.copyWith(
          sessionIds: [
            for (final id in f.sessionIds)
              if (!ids.contains(id)) id,
          ],
        )
      : f;
}

final drawerViewProvider = NotifierProvider<DrawerViewController, DrawerView>(DrawerViewController.new);

// ── Filter and selection (this run only) ─────────────────────────────────────

/// The status capsules above the list.
enum DrawerFilter {
  all,
  running,
  pending,
  unread;

  String get label => switch (this) {
    all => appL10n.stateDrawerAll,
    running => appL10n.commonRunning,
    pending => appL10n.stateCordisPending,
    unread => appL10n.stateDrawerUnread,
  };
}

class DrawerFilterController extends Notifier<DrawerFilter> {
  @override
  DrawerFilter build() {
    // Another host: back to everything.
    ref.watch(activeHostProvider);
    return DrawerFilter.all;
  }

  void set(DrawerFilter filter) => state = filter;
}

final drawerFilterProvider = NotifierProvider<DrawerFilterController, DrawerFilter>(DrawerFilterController.new);

/// Multi-select: null when off, else the chosen conversation ids.
class DrawerSelectionController extends Notifier<Set<String>?> {
  @override
  Set<String>? build() {
    ref.watch(activeHostProvider);
    return null;
  }

  bool get active => state != null;

  /// Turns multi-select on, with [first] chosen.
  void start([String? first]) => state = {?first};

  void toggle(String id) {
    final current = state;
    if (current == null) return;
    state = current.contains(id) ? ({...current}..remove(id)) : {...current, id};
  }

  /// Chooses exactly [ids] (全选 / 取消全选).
  void setAll(Iterable<String> ids) {
    if (state != null) state = ids.toSet();
  }

  void end() => state = null;
}

final drawerSelectionProvider = NotifierProvider<DrawerSelectionController, Set<String>?>(
  DrawerSelectionController.new,
);

// ── What the list shows ──────────────────────────────────────────────────────

enum SessionDay { today, yesterday, thisWeek, earlier }

/// Calendar grouping in local time; weeks start on Monday.
SessionDay sessionDayOf(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return SessionDay.today;
  if (diff == 1) return SessionDay.yesterday;
  final monday = today.subtract(Duration(days: today.weekday - DateTime.monday));
  if (!day.isBefore(monday)) return SessionDay.thisWeek;
  return SessionDay.earlier;
}

Map<SessionDay, String> get sessionDayLabels => {
  SessionDay.today: appL10n.stateDrawerToday,
  SessionDay.yesterday: appL10n.commonYesterday,
  SessionDay.thisWeek: appL10n.stateDrawerThisWeek,
  SessionDay.earlier: appL10n.stateDrawerEarlier,
};

/// The drawer's conversations of the active host after the workspace scope,
/// with DS Bot's own conversations split out (they fold into one row).
class DrawerScope {
  const DrawerScope({
    required this.sessions,
    required this.bots,
    required this.scoped,
    this.readOnly = false,
    this.status = ReadListStatus.current,
    this.workspaceLabel,
  });

  /// Listed conversations, newest activity first.
  final List<SessionSummary> sessions;

  /// DS Bot's conversations in scope.
  final List<SessionSummary> bots;

  /// A workspace is selected (folders without members in it are hidden).
  final bool scoped;
  final bool readOnly;
  final ReadListStatus status;

  /// Display text only, never a workspace path or an edit/create target.
  final String? workspaceLabel;
}

/// Null until the list (and a selected workspace's members) have arrived.
final drawerScopeProvider = Provider<DrawerScope?>((ref) {
  final sessions = ref.watch(sessionsProvider);
  final all = sessions.value;
  final identity = ref.watch(readListIdentityProvider);
  final connection = ref.watch(readListLiveConnectionProvider);
  final cache = ref.watch(readListCacheProvider);
  ref.watch(readListCacheChangesProvider);
  final prefs = ref.watch(workspacePrefsProvider);
  final registry = ref.watch(workspacesProvider);
  final registryCurrent = cache.current(registry, identity, connection?.client);
  final workspace = ref.watch(selectedWorkspaceProvider);
  final key = prefs.loaded
      ? readListKey(identity, ReadListKind.sessions, prefs.selected == null ? 'all' : 'workspace:${prefs.selected}')
      : null;
  final validSource = all != null && cache.current(all, identity, connection?.client);
  final activity = cache.refresh(ReadListKind.sessions, identity, all);
  final readOnly = sessions.isLoading || sessions.hasError || activity?.pending == true || activity?.failed == true;
  final status = sessions.hasError || activity?.failed == true
      ? ReadListStatus.failed
      : connection == null
      ? ReadListStatus.offline
      : ReadListStatus.updating;
  final pending = ref.watch(workspaceFilterPendingProvider);
  final workspaceKnown = prefs.selected == null || registryCurrent && registry.ready && workspace != null;
  if (!validSource || pending || !workspaceKnown || cache.origin(all) != null && !prefs.loaded) {
    final cached = cache.get<CachedSessions>(key);
    if (cached == null) return null;
    // Once a registry is known, deletion or a changed path/membership version
    // invalidates the old projection. Offline, only the exact last confirmed
    // selected workspace may be shown; never fall back to all sessions.
    if (prefs.selected != null &&
        registryCurrent &&
        registry.ready &&
        (workspace == null || readWorkspaceVersion(workspace) != cached.workspaceVersion)) {
      return null;
    }
    return DrawerScope(
      sessions: cached.sessions,
      bots: cached.bots,
      scoped: cached.scoped,
      readOnly: true,
      status: status,
      workspaceLabel: cached.workspaceLabel,
    );
  }
  // A workspace is selected but its members haven't arrived: wait rather
  // than flash every conversation.
  final members = workspace?.sessionIds.toSet();
  final archived = registryCurrent && registry.ready ? registry.archivedSessionIds.toSet() : const <String>{};
  final inScope = [
    for (final s in all)
      if (!archived.contains(s.sessionId) && (members == null || members.contains(s.sessionId))) s,
  ];
  final botOwned = ref.watch(dsBotOwnedSessionsProvider);
  final result = DrawerScope(
    sessions: [
      for (final s in inScope)
        if (!botOwned.contains(s.sessionId)) s,
    ],
    bots: [
      for (final s in inScope)
        if (botOwned.contains(s.sessionId)) s,
    ],
    scoped: workspace != null,
    readOnly: readOnly,
    status: readOnly ? status : ReadListStatus.current,
    workspaceLabel: workspace == null
        ? null
        : workspace.title.trim().isNotEmpty
        ? workspace.title.trim()
        : workspaceTitle(workspace),
  );
  // A workspace baseline also supplies the archived set. Do not cache a
  // partial pre-baseline session list or an unconfirmed membership.
  if (!result.readOnly && registry.ready && registryCurrent) {
    final version = workspace == null ? null : readWorkspaceVersion(workspace);
    if (workspace != null && version == null ||
        result.sessions.length + result.bots.length > ReadListData.maxRows ||
        (result.workspaceLabel?.length ?? 0) > 512) {
      cache.invalidate(key);
      return result;
    }
    var units = 0;
    for (final row in result.sessions.followedBy(result.bots)) {
      units += row.sessionId.length;
      if (row.sessionId.length > 256 || units > ReadListData.maxIdentityUnits) {
        cache.invalidate(key);
        return result;
      }
    }
    cache.put(
      key,
      all,
      () => CachedSessions(
        sessions: result.sessions,
        bots: result.bots,
        workspaceVersion: version,
        scoped: result.scoped,
        workspaceLabel: result.workspaceLabel,
      ),
      // The registry can deliver an archive frame before SessionsController's
      // independent subscription. Include the actual visible membership, not
      // only the original list revision or selected workspace version.
      projection: ReadListIdentity.of([
        version,
        result.workspaceLabel,
        [for (final row in result.sessions) row.sessionId],
        [for (final row in result.bots) row.sessionId],
      ]).digest,
    );
  }
  return result;
});

/// One block of the drawer list.
///
/// Not `sealed` while the tree blocks ([WorkspaceBlock], [LooseBlock]) are
/// new: a list that switches over the time layout's blocks keeps compiling
/// and simply has nothing to draw for them (only the tree layout makes them).
abstract class DrawerBlock {
  const DrawerBlock(this.items);

  final List<SessionSummary> items;
}

/// Pinned conversations that are in no folder.
final class PinnedBlock extends DrawerBlock {
  const PinnedBlock(super.items);
}

/// A folder and its members in scope (pinned members first).
final class FolderBlock extends DrawerBlock {
  const FolderBlock(this.folder, super.items);

  final DrawerFolder folder;
}

/// The rest, by day of the sort key.
final class DayBlock extends DrawerBlock {
  const DayBlock(this.day, super.items);

  final SessionDay day;
}

/// A status filter's matches, flat (no folders or days).
final class FilteredBlock extends DrawerBlock {
  const FilteredBlock(this.filter, super.items);

  final DrawerFilter filter;
}

/// One workspace's group in the tree layout. [items]: its pinned members
/// first ([pinnedCount] of them), then the rest, each part in the Host's
/// manual order (`Workspace.sessionIds`). Members outside the drawer's scope
/// (archived, DS Bot, elsewhere) are left out; the group shows even when
/// none are left.
final class WorkspaceBlock extends DrawerBlock {
  const WorkspaceBlock(
    this.workspace,
    super.items, {
    required this.pinnedCount,
    required this.collapsed,
    required this.runningCount,
    required this.canReorder,
    this.sectionTitle,
  });

  final Workspace workspace;
  final int pinnedCount;

  /// Folded (its rows are not drawn; never when the workspace is selected).
  final bool collapsed;

  /// Members running now (the header's 「N 在跑」).
  final int runningCount;

  /// Rows may be dragged and moved (`moveSession`): a live, writable list
  /// and a ready registry.
  final bool canReorder;

  /// Set on the first group of a titled block of the workspace list (置顶 or
  /// a group name from the phone's workspace preferences): a heading above
  /// this group.
  final String? sectionTitle;

  /// The pinned zone and the rest.
  List<SessionSummary> get pinned => items.sublist(0, pinnedCount);
  List<SessionSummary> get unpinned => items.sublist(pinnedCount);
}

/// 其它对话: conversations in scope that no workspace accounts, by the sort
/// key (newest first). Not reorderable.
final class LooseBlock extends DrawerBlock {
  const LooseBlock(super.items);
}

/// Whether [s] is listed under [filter]: the one rule both the list
/// ([drawerBlocks]) and the capsules' numbers ([drawerFilterCounts]) use.
/// [pending] and [unread] are keyed by top-level conversation id.
bool drawerFilterMatches(
  DrawerFilter filter,
  SessionSummary s,
  Map<String, PendingKind> pending,
  Set<String> unread,
) => switch (filter) {
  DrawerFilter.all => true,
  DrawerFilter.running => s.running,
  DrawerFilter.pending => pending.containsKey(s.sessionId),
  DrawerFilter.unread => unread.contains(s.sessionId),
};

/// How many of [sessions] each filter lists: always the row count
/// [drawerBlocks] gives that filter over the same inputs.
Map<DrawerFilter, int> drawerFilterCounts({
  required List<SessionSummary> sessions,
  required Map<String, PendingKind> pending,
  required Set<String> unread,
}) => {
  for (final filter in DrawerFilter.values)
    filter: sessions.where((s) => drawerFilterMatches(filter, s, pending, unread)).length,
};

/// The drawer list as blocks. Every conversation shows once: in its folder
/// if it has one, else under 置顶 if pinned, else under its day.
List<DrawerBlock> drawerBlocks({
  required List<SessionSummary> sessions,
  required List<String> pinnedIds,
  required DrawerView view,
  required DrawerFilter filter,
  required Map<String, PendingKind> pending,
  required Set<String> unread,
  required Map<String, DateTime> createdAt,
  required DateTime now,
  bool scoped = false,
}) {
  DateTime keyOf(SessionSummary s) =>
      view.sort == DrawerSort.created ? (createdAt[s.sessionId] ?? s.updatedAt) : s.updatedAt;
  final sorted = [...sessions]
    ..sort((a, b) {
      final byKey = keyOf(b).compareTo(keyOf(a));
      return byKey != 0 ? byKey : a.sessionId.compareTo(b.sessionId);
    });
  if (filter != DrawerFilter.all) {
    return [
      FilteredBlock(filter, [
        for (final s in sorted)
          if (drawerFilterMatches(filter, s, pending, unread)) s,
      ]),
    ];
  }
  final folderOf = view.folderOf;
  final pinnedSet = pinnedIds.toSet();
  final byId = {for (final s in sorted) s.sessionId: s};
  final blocks = <DrawerBlock>[];
  final pinned = [
    for (final id in pinnedIds)
      if (byId[id] case final s? when !folderOf.containsKey(id)) s,
  ];
  if (pinned.isNotEmpty) blocks.add(PinnedBlock(pinned));
  final membersByFolder = <String, List<SessionSummary>>{};
  for (final s in sorted) {
    final folderId = folderOf[s.sessionId];
    if (folderId != null) membersByFolder.putIfAbsent(folderId, () => []).add(s);
  }
  for (final folder in view.folders) {
    final members = membersByFolder[folder.id] ?? const <SessionSummary>[];
    if (members.isEmpty && scoped) continue;
    blocks.add(
      FolderBlock(folder, [
        for (final s in members)
          if (pinnedSet.contains(s.sessionId)) s,
        for (final s in members)
          if (!pinnedSet.contains(s.sessionId)) s,
      ]),
    );
  }
  final days = <SessionDay, List<SessionSummary>>{};
  for (final s in sorted) {
    if (folderOf.containsKey(s.sessionId) || pinnedSet.contains(s.sessionId)) continue;
    days.putIfAbsent(sessionDayOf(keyOf(s), now), () => []).add(s);
  }
  for (final day in SessionDay.values) {
    if (days[day] case final items?) blocks.add(DayBlock(day, items));
  }
  return blocks;
}

/// The drawer list in the tree layout: one [WorkspaceBlock] per workspace in
/// [workspaces]' order (the display order, the phone's pinned workspaces and
/// groups already applied; [sectionStarts] maps the first workspace of each
/// titled block to its heading), then a [LooseBlock] for conversations no
/// workspace accounts (left out when empty).
///
/// * A status [filter] gives the same single [FilteredBlock] as [drawerBlocks].
/// * With [selectedWorkspaceId] (and that workspace in [workspaces]) only its
///   group is returned, never collapsed, and no [LooseBlock].
/// * In a group, pinned members come first, then the rest; both parts keep
///   the Host's manual order (`Workspace.sessionIds`), so a drag inside
///   either part is a `workspace/insertSessionBefore`. Ids the Host lists
///   that are not in [sessions] (archived, DS Bot, elsewhere) are skipped.
/// * Every conversation shows once: the first workspace accounting it wins.
/// * Folders are not blocks here (the row marks its folder instead).
List<DrawerBlock> drawerTreeBlocks({
  required List<SessionSummary> sessions,
  required List<Workspace> workspaces,
  required List<String> pinnedIds,
  required DrawerView view,
  required DrawerFilter filter,
  required Map<String, PendingKind> pending,
  required Set<String> unread,
  required Map<String, DateTime> createdAt,
  required DateTime now,
  String? selectedWorkspaceId,
  bool readOnly = false,
  Map<String, String> sectionStarts = const {},
}) {
  if (filter != DrawerFilter.all) {
    return drawerBlocks(
      sessions: sessions,
      pinnedIds: pinnedIds,
      view: view,
      filter: filter,
      pending: pending,
      unread: unread,
      createdAt: createdAt,
      now: now,
    );
  }
  final byId = {for (final s in sessions) s.sessionId: s};
  final pinnedSet = pinnedIds.toSet();
  final placed = <String>{};
  WorkspaceBlock group(Workspace w, {required bool collapsed, String? sectionTitle}) {
    final pinned = <SessionSummary>[];
    final rest = <SessionSummary>[];
    for (final id in w.sessionIds) {
      final s = byId[id];
      if (s == null || !placed.add(id)) continue;
      (pinnedSet.contains(id) ? pinned : rest).add(s);
    }
    final items = [...pinned, ...rest];
    return WorkspaceBlock(
      w,
      items,
      pinnedCount: pinned.length,
      collapsed: collapsed,
      runningCount: items.where((s) => s.running).length,
      canReorder: !readOnly,
      sectionTitle: sectionTitle,
    );
  }

  if (selectedWorkspaceId != null) {
    for (final w in workspaces) {
      if (w.workspaceId == selectedWorkspaceId) return [group(w, collapsed: false)];
    }
  }
  final blocks = <DrawerBlock>[
    for (final w in workspaces)
      group(
        w,
        collapsed: view.collapsedWorkspaces.contains(w.workspaceId),
        sectionTitle: sectionStarts[w.workspaceId],
      ),
  ];
  DateTime keyOf(SessionSummary s) =>
      view.sort == DrawerSort.created ? (createdAt[s.sessionId] ?? s.updatedAt) : s.updatedAt;
  final loose = [
    for (final s in sessions)
      if (!placed.contains(s.sessionId)) s,
  ]..sort((a, b) {
      final byKey = keyOf(b).compareTo(keyOf(a));
      return byKey != 0 ? byKey : a.sessionId.compareTo(b.sessionId);
    });
  if (loose.isNotEmpty) blocks.add(LooseBlock(loose));
  return blocks;
}

/// What 全选 picks: every conversation on screen (members of a collapsed
/// folder or workspace group are not).
List<String> drawerSelectableIds(List<DrawerBlock> blocks) => [
  for (final block in blocks)
    if (switch (block) {
      FolderBlock(:final folder) => !folder.collapsed,
      WorkspaceBlock(:final collapsed) => !collapsed,
      _ => true,
    })
      for (final s in block.items) s.sessionId,
];

/// Clock for day grouping (tests override it).
final drawerClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// What the filters see of the live providers: a cached (read-only) list has
/// no pending or unread marks.
({Map<String, PendingKind> pending, Set<String> unread}) _watchDrawerMarks(WidgetRef ref, DrawerScope scope) => (
  pending: scope.readOnly ? const {} : ref.watch(pendingInteractionsProvider),
  unread: scope.readOnly ? const {} : ref.watch(unreadSessionIdsProvider),
);

/// [drawerBlocks] (按时间) or [drawerTreeBlocks] (按工作区, by
/// [DrawerView.layout]) over the live providers; null while the list loads.
List<DrawerBlock>? watchDrawerBlocks(WidgetRef ref, {DateTime? now}) {
  final scope = ref.watch(drawerScopeProvider);
  if (scope == null) return null;
  final stored = ref.watch(drawerViewProvider);
  // No folders on iOS: their members list by day like the rest.
  final view = drawerFoldersShown ? stored : stored.copyWith(folders: const []);
  final marks = _watchDrawerMarks(ref, scope);
  if (view.layout == DrawerLayout.tree) {
    final sections = ref.watch(workspaceSectionsProvider);
    final ready = ref.watch(workspacesProvider.select((s) => s.ready));
    return drawerTreeBlocks(
      sessions: scope.sessions,
      workspaces: [for (final section in sections) ...section.items],
      sectionStarts: {
        for (final section in sections)
          if (section.title != null && section.items.isNotEmpty) section.items.first.workspaceId: section.title!,
      },
      pinnedIds: ref.watch(workspacesProvider.select((s) => s.pinnedSessionIds)),
      view: view,
      filter: ref.watch(drawerFilterProvider),
      pending: marks.pending,
      unread: marks.unread,
      createdAt: view.sort == DrawerSort.created ? ref.watch(sessionCreatedProvider) : const {},
      now: now ?? ref.watch(drawerClockProvider)(),
      selectedWorkspaceId: ref.watch(selectedWorkspaceIdProvider),
      readOnly: scope.readOnly || !ready,
    );
  }
  return drawerBlocks(
    sessions: scope.sessions,
    pinnedIds: ref.watch(workspacesProvider.select((s) => s.pinnedSessionIds)),
    view: view,
    filter: ref.watch(drawerFilterProvider),
    pending: marks.pending,
    unread: marks.unread,
    createdAt: view.sort == DrawerSort.created ? ref.watch(sessionCreatedProvider) : const {},
    now: now ?? ref.watch(drawerClockProvider)(),
    scoped: scope.scoped,
  );
}

/// [drawerFilterCounts] over the same providers as [watchDrawerBlocks];
/// null while the list loads.
Map<DrawerFilter, int>? watchDrawerFilterCounts(WidgetRef ref) {
  final scope = ref.watch(drawerScopeProvider);
  if (scope == null) return null;
  final marks = _watchDrawerMarks(ref, scope);
  return drawerFilterCounts(sessions: scope.sessions, pending: marks.pending, unread: marks.unread);
}
