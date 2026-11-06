// 灵动岛 (iOS Live Activity「鲸游」) preference: off / start only from the
// foreground / also let the bridge start one while the app is away
// (push-to-start). Stored in SharedPreferences as `island_mode`.
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

  /// 仅前台启动: the app starts one when a message is sent from it.
  foreground,

  /// 前后台都显示: as [foreground], and the bridge may start one for an
  /// approval or a question while the app is away (iOS 17.2+).
  always;

  static IslandMode parse(Object? raw) => switch (raw) {
    'off' => off,
    'always' => always,
    'foreground' => foreground,
    _ => foreground,
  };
}

class IslandPrefs {
  const IslandPrefs({this.mode = IslandMode.foreground, this.loaded = false});

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
    IslandMode mode = IslandMode.foreground;
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
