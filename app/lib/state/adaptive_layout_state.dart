// What the person chose about the wide-screen columns (sidebar unfolded,
// detail panel shown, which of the two was unfolded last), kept across
// launches, and the one 对话详情 tab shared by the page, the sheet and the
// panel.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/session/session_tab.dart';
import '../ui/shell/adaptive/adaptive_layout.dart' show LayoutSide;

/// The person's choices for wide windows. Both start unfolded.
class LayoutPrefs {
  const LayoutPrefs({this.sidebarOpen = true, this.panelOpen = true, this.prefer, this.loaded = false});

  /// The conversation list unfolds into a sidebar when it fits.
  final bool sidebarOpen;

  /// 对话详情 stays open beside the chat.
  final bool panelOpen;

  /// The side unfolded last: it stays when the window has no room for both
  /// beside a comfortable chat. Null until one is unfolded by hand (the
  /// sidebar wins then).
  final LayoutSide? prefer;

  /// The stored values are in (until then, the defaults show).
  final bool loaded;

  LayoutPrefs copyWith({bool? sidebarOpen, bool? panelOpen, LayoutSide? prefer, bool? loaded}) => LayoutPrefs(
    sidebarOpen: sidebarOpen ?? this.sidebarOpen,
    panelOpen: panelOpen ?? this.panelOpen,
    prefer: prefer ?? this.prefer,
    loaded: loaded ?? this.loaded,
  );

  @override
  bool operator ==(Object other) =>
      other is LayoutPrefs &&
      other.sidebarOpen == sidebarOpen &&
      other.panelOpen == panelOpen &&
      other.prefer == prefer &&
      other.loaded == loaded;

  @override
  int get hashCode => Object.hash(sidebarOpen, panelOpen, prefer, loaded);
}

class LayoutPrefsController extends Notifier<LayoutPrefs> {
  static const sidebarKey = 'layout_sidebar_open';
  static const panelKey = 'layout_detail_panel_open';
  static const preferKey = 'layout_prefer_side';

  late Future<void> _loaded;

  @override
  LayoutPrefs build() {
    _loaded = _load();
    return const LayoutPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final prefer = prefs.getString(preferKey);
      state = LayoutPrefs(
        sidebarOpen: prefs.getBool(sidebarKey) ?? true,
        panelOpen: prefs.getBool(panelKey) ?? true,
        prefer: LayoutSide.values.where((side) => side.name == prefer).firstOrNull,
        loaded: true,
      );
    } catch (_) {
      // No preferences backend: the defaults, for this run.
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  /// Applies after the stored values are in, so a late load can't undo a
  /// toggle made right after launch. Unfolding a side makes it [prefer]red.
  Future<void> _save(String key, bool value, LayoutSide side) async {
    await _loaded;
    if (!ref.mounted) return;
    final prefer = value ? side : null;
    state = key == sidebarKey
        ? state.copyWith(sidebarOpen: value, prefer: prefer)
        : state.copyWith(panelOpen: value, prefer: prefer);
    try {
      final store = await SharedPreferences.getInstance();
      await store.setBool(key, value);
      if (prefer != null) await store.setString(preferKey, prefer.name);
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> setSidebarOpen(bool open) => _save(sidebarKey, open, LayoutSide.sidebar);

  Future<void> setPanelOpen(bool open) => _save(panelKey, open, LayoutSide.panel);

  Future<void> togglePanel() async {
    await _loaded;
    await setPanelOpen(!state.panelOpen);
  }
}

final layoutPrefsProvider = NotifierProvider<LayoutPrefsController, LayoutPrefs>(LayoutPrefsController.new);

/// The 对话详情 tab on screen. One value for every form the detail takes, so
/// folding a sheet into the panel, or reopening the panel, keeps the tab.
class SessionDetailTabController extends Notifier<SessionTab> {
  @override
  SessionTab build() => SessionTab.trajectory;

  void select(SessionTab tab) {
    if (state != tab) state = tab;
  }
}

final sessionDetailTabProvider = NotifierProvider<SessionDetailTabController, SessionTab>(
  SessionDetailTabController.new,
);
