// Tells the push bridge (dsh-watch-bridge) about this phone's「鲸游」Live
// Activities, so it can keep them current with `liveactivity` pushes while
// the app is away (HTTP contract: plan/ios-wave2-design.md «la-bridge › A»):
//
//   PUT    /v1/device/live-activity              {sessionId, token, lang,
//                                                 clockOffsetMs, snapshot, startedAtMs}
//   DELETE /v1/device/live-activity/<sessionId>
//   PUT    /v1/device/live-activity/start-token  {token}   (前后台都显示 only)
//   DELETE /v1/device/live-activity/start-token
//
// Without a pairing every call only remembers what it was told; [resync]
// sends it all once a pairing exists (push_state.dart calls it after pairing
// and after each refresh). A network failure is retried once after 30 s; an
// unpaired device gives up. Tokens are never logged.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart' show AppLocale;
import '../platform/platform_caps.dart';
import '../push/bridge_client.dart';
import '../push/push_state.dart';
import '../state/hosts_state.dart' show secretStoreProvider;
import 'island_prefs_state.dart';
import 'live_activity_content.dart';

/// How long before a failed call (network) is tried again, once.
final liveBridgeRetryDelayProvider = Provider<Duration>((ref) => const Duration(seconds: 30));

class _Registration {
  _Registration({
    required this.token,
    required this.lang,
    required this.clockOffsetMs,
    required this.snapshot,
    required this.startedAtMs,
  });

  String token;
  String lang;
  int clockOffsetMs;
  Map<String, Object?> snapshot;
  int startedAtMs;

  /// The bridge has it (a later token change sends again).
  bool sent = false;
}

class LiveActivityBridgeSync {
  LiveActivityBridgeSync(this._ref);

  final Ref _ref;
  final _activities = <String, _Registration>{};
  String? _startToken;
  bool _startSent = false;
  final _retries = <String, Timer>{};
  bool _disposed = false;

  /// Sessions whose Activity token is known (tests, status).
  Iterable<String> get registered => _activities.keys;
  String? get pushToStartToken => _startToken;

  bool get _active => isRemoteOnlyPlatform && !_disposed && _ref.mounted;

  Future<(BridgeClient, String)?> _client() async {
    if (!_active) return null;
    final push = _ref.read(pushProvider.notifier);
    await push.ready;
    if (!_active) return null;
    final pairing = _ref.read(pushProvider).pairing;
    if (pairing == null) return null;
    final base = normalizeBridgeUrl(pairing.bridge);
    if (base == null) return null;
    String? token;
    try {
      token = await _ref.read(secretStoreProvider).read(PushController.deviceTokenKey);
    } catch (_) {
      token = null;
    }
    if (token == null || !_active) return null;
    return (_ref.read(bridgeClientFactoryProvider)(base, pin: pairing.pin), token);
  }

  /// Runs [call]; false when it failed. A network failure tries [key] again
  /// once after [liveBridgeRetryDelayProvider].
  Future<bool> _send(
    String key,
    Future<void> Function(BridgeClient client, String token) call, {
    bool retry = true,
  }) async {
    final c = await _client();
    if (c == null) return false;
    try {
      await call(c.$1, c.$2);
      return true;
    } on BridgeException catch (e) {
      if (e.code == 'network' && retry && _active) {
        _retries.remove(key)?.cancel();
        _retries[key] = Timer(_ref.read(liveBridgeRetryDelayProvider), () {
          _retries.remove(key);
          unawaited(_retry(key));
        });
      }
      return false;
    }
  }

  Future<void> _retry(String key) async {
    if (!_active) return;
    if (key == _startKey) {
      await _sendStartToken(retry: false);
    } else if (key.startsWith(_forgetPrefix)) {
      final sessionId = key.substring(_forgetPrefix.length);
      if (!_activities.containsKey(sessionId)) {
        await _send(key, (c, t) => c.deleteLiveActivity(t, sessionId), retry: false);
      }
    } else if (_activities[key] case final r? when !r.sent) {
      await _put(key, r, retry: false);
    }
  }

  static const _startKey = '\u0000start';
  static const _forgetPrefix = '\u0000forget:';

  Future<void> _put(String sessionId, _Registration r, {bool retry = true}) async {
    final token = r.token;
    final ok = await _send(
      sessionId,
      (c, t) => c.putLiveActivity(
        t,
        sessionId: sessionId,
        activityToken: r.token,
        lang: r.lang,
        clockOffsetMs: r.clockOffsetMs,
        snapshot: r.snapshot,
        startedAtMs: r.startedAtMs,
      ),
      retry: retry,
    );
    if (ok && identical(_activities[sessionId], r) && r.token == token) r.sent = true;
  }

  /// The Activity of [sessionId] has (a new) push [token].
  Future<void> onPushToken(
    String sessionId,
    String token, {
    required IslandContent content,
    required String lang,
    required int clockOffsetMs,
  }) async {
    if (!isRemoteOnlyPlatform) return;
    final existing = _activities[sessionId];
    if (existing != null && existing.token == token && existing.sent) return;
    final r =
        existing ?? _Registration(token: token, lang: lang, clockOffsetMs: clockOffsetMs, snapshot: {}, startedAtMs: 0);
    r
      ..token = token
      ..lang = lang
      ..clockOffsetMs = clockOffsetMs
      ..snapshot = _snapshotOf(content)
      ..startedAtMs = content.startedAt.millisecondsSinceEpoch
      ..sent = false;
    _activities[sessionId] = r;
    _retries.remove('$_forgetPrefix$sessionId')?.cancel();
    await _put(sessionId, r);
  }

  /// Keeps the snapshot sent on the next [resync] current. No network.
  void updateSnapshot(String sessionId, IslandContent content) {
    final r = _activities[sessionId];
    if (r != null) r.snapshot = _snapshotOf(content);
  }

  /// The ContentState plus the masked title the Activity shows (the bridge
  /// uses it for alerts when the Host doesn't tell it one).
  static Map<String, Object?> _snapshotOf(IslandContent content) => {...content.toMap(), 'title': content.title};

  /// A push-to-start token arrived (iOS 17.2+). Sent only in 前后台都显示.
  Future<void> onPushToStartToken(String token) async {
    if (!isRemoteOnlyPlatform) return;
    if (_startToken == token && _startSent) return;
    _startToken = token;
    _startSent = false;
    await _sendStartToken();
  }

  Future<void> _sendStartToken({bool retry = true}) async {
    final token = _startToken;
    if (token == null || _ref.read(islandPrefsProvider).mode != IslandMode.always) return;
    final lang = islandLangOf(AppLocale.current);
    final ok = await _send(_startKey, (c, t) => c.putPushToStart(t, token, lang: lang), retry: retry);
    if (ok && _startToken == token) _startSent = true;
  }

  /// The 灵动岛 setting changed: push-to-start only in [IslandMode.always].
  Future<void> onModeChanged(IslandMode mode) async {
    if (!isRemoteOnlyPlatform) return;
    if (mode == IslandMode.always) {
      if (!_startSent) await _sendStartToken();
    } else if (_startSent) {
      _startSent = false;
      _retries.remove(_startKey)?.cancel();
      await _send('\u0000start-off', (c, t) => c.deletePushToStart(t), retry: false);
    }
  }

  /// The Activity of [sessionId] is over (ended, dismissed, switched off).
  Future<void> forget(String sessionId) async {
    if (!isRemoteOnlyPlatform) return;
    final r = _activities.remove(sessionId);
    _retries.remove(sessionId)?.cancel();
    if (r == null) return;
    await _send('$_forgetPrefix$sessionId', (c, t) => c.deleteLiveActivity(t, sessionId));
  }

  /// Forgets everything. [remote]: also tell the bridge (灵动岛 switched off);
  /// unpairing passes false (the bridge drops the whole device anyway).
  Future<void> clear({bool remote = true}) async {
    if (!isRemoteOnlyPlatform) return;
    final sessions = [..._activities.keys];
    final hadStart = _startSent;
    _activities.clear();
    _startToken = null;
    _startSent = false;
    for (final t in _retries.values) {
      t.cancel();
    }
    _retries.clear();
    if (!remote) return;
    for (final s in sessions) {
      await _send('$_forgetPrefix$s', (c, t) => c.deleteLiveActivity(t, s), retry: false);
    }
    if (hadStart) await _send('\u0000start-off', (c, t) => c.deletePushToStart(t), retry: false);
  }

  /// A pairing was made or checked: send every token again.
  Future<void> resync() async {
    if (!isRemoteOnlyPlatform) return;
    for (final MapEntry(key: sessionId, value: r) in [..._activities.entries]) {
      r.sent = false;
      await _put(sessionId, r);
    }
    if (_startToken != null) {
      _startSent = false;
      await _sendStartToken();
    }
  }

  void dispose() {
    _disposed = true;
    for (final t in _retries.values) {
      t.cancel();
    }
    _retries.clear();
  }
}

final liveActivityBridgeSyncProvider = Provider<LiveActivityBridgeSync>((ref) {
  final sync = LiveActivityBridgeSync(ref);
  ref.onDispose(sync.dispose);
  return sync;
});
