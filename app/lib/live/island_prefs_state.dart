// 灵动岛 (iOS Live Activity「鲸游」) preference: off / start only from the
// foreground / also let the bridge start one while the app is away
// (push-to-start). Stored in SharedPreferences as `island_mode`, only once
// the person picks one: with nothing stored the default applies, so the v2
// default ([IslandMode.always], 「自动」) reaches everyone who never chose,
// and a choice made in v1 stays (plan/design/live-activity-v2-contract.md §3.1).
//
// Android and every other platform: always off, and setMode does nothing
// (the Android status-bar activity is lib/state/live_activity_state.dart).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/platform_caps.dart';

enum IslandMode {
  /// 关: no Activity at all.
  off,

  /// 仅 App 内: only the app starts one (from a conversation it shows).
  foreground,

  /// 自动 (the default): as [foreground], and the bridge may start one while
  /// the app is away, only when you are needed: an approval, a question, a
  /// failure (iOS 17.2+).
  always;

  static const fallback = always;

  static IslandMode parse(Object? raw) => switch (raw) {
    'off' => off,
    'always' => always,
    'foreground' => foreground,
    _ => fallback,
  };
}

class IslandPrefs {
  const IslandPrefs({this.mode = IslandMode.fallback, this.loaded = false});

  final IslandMode mode;

  /// The stored choice has been read (until then [mode] is the default).
  final bool loaded;

  bool get enabled => mode != IslandMode.off;

  @override
  bool operator ==(Object other) => other is IslandPrefs && other.mode == mode && other.loaded == loaded;

  @override
  int get hashCode => Object.hash(mode, loaded);
}

class IslandPrefsController extends Notifier<IslandPrefs> {
  static const prefsKey = 'island_mode';

  late Future<void> _ready;

  /// Completes once the stored choice is read.
  Future<void> get ready => _ready;

  @override
  IslandPrefs build() {
    if (!isRemoteOnlyPlatform) {
      _ready = Future.value();
      return const IslandPrefs(mode: IslandMode.off, loaded: true);
    }
    _ready = _load();
    return const IslandPrefs();
  }

  Future<void> _load() async {
    IslandMode mode = IslandMode.fallback;
    try {
      mode = IslandMode.parse((await SharedPreferences.getInstance()).getString(prefsKey));
    } catch (_) {
      // No preferences backend (tests): the default.
    }
    if (!ref.mounted) return;
    state = IslandPrefs(mode: mode, loaded: true);
  }

  Future<void> setMode(IslandMode mode) async {
    if (!isRemoteOnlyPlatform) return;
    await _ready;
    if (!ref.mounted) return;
    if (state.mode != mode) state = IslandPrefs(mode: mode, loaded: true);
    try {
      await (await SharedPreferences.getInstance()).setString(prefsKey, mode.name);
    } catch (_) {}
  }
}

final islandPrefsProvider = NotifierProvider<IslandPrefsController, IslandPrefs>(IslandPrefsController.new);
