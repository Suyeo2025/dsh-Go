// Dart side of the `dsh/live_activity` method channel (native:
// ios/Runner/LiveActivityChannel.swift, the「鲸游」Live Activity). Contract:
// plan/ios-wave2-design.md «la-native › 通道契约».
//
//   Dart → native: status, start, update, end, list, endAll, takePendingTokens
//   native → Dart: onPushToken, onPushToStartToken, onActivityState, onDecision
//
// Dates in the payloads are Unix seconds (int). Off iOS
// (`!isRemoteOnlyPlatform`) every call returns "unsupported" without touching
// the channel; a missing native side (tests, older builds) reads the same.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_caps.dart';
import '../state/notify_state.dart' show appForegroundProvider;

const liveActivityMethodChannel = MethodChannel('dsh/live_activity');

/// What the phone offers (`status`).
class LiveSupport {
  const LiveSupport({
    this.supported = false,
    this.enabled = false,
    this.pushToStart = false,
    this.frequentUpdates = false,
  });

  static const unsupported = LiveSupport();

  /// iOS 16.2+ on an iPhone.
  final bool supported;

  /// `ActivityAuthorizationInfo().areActivitiesEnabled` (系统设置 › 实时活动).
  final bool enabled;

  /// iOS 17.2+: the bridge can start one remotely.
  final bool pushToStart;
  final bool frequentUpdates;

  /// An Activity may be started now.
  bool get usable => supported && enabled;

  factory LiveSupport.fromMap(Map<Object?, Object?> m) => LiveSupport(
    supported: m['supported'] == true,
    enabled: m['enabled'] == true,
    pushToStart: m['pushToStart'] == true,
    frequentUpdates: m['frequentUpdates'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is LiveSupport &&
      other.supported == supported &&
      other.enabled == enabled &&
      other.pushToStart == pushToStart &&
      other.frequentUpdates == frequentUpdates;

  @override
  int get hashCode => Object.hash(supported, enabled, pushToStart, frequentUpdates);

  @override
  String toString() => 'LiveSupport(supported: $supported, enabled: $enabled, pushToStart: $pushToStart)';
}

/// How an ended Activity leaves the screen.
enum LiveDismissal {
  immediate('immediate'),
  after4s('after4s'),
  after15m('after15m'),

  /// v2: a finished turn's card stays on the lock screen this long.
  after20m('after20m'),
  system('default');

  const LiveDismissal(this.wire);
  final String wire;
}

/// `ActivityState` as the native side reports it.
enum LiveActivityPhase {
  active,
  ended,
  dismissed,
  stale;

  static LiveActivityPhase? parse(Object? raw) => switch (raw) {
    'active' => active,
    'ended' => ended,
    'dismissed' => dismissed,
    'stale' => stale,
    _ => null,
  };

  /// Gone from the system's point of view (no more updates land).
  bool get over => this == ended || this == dismissed;
}

/// One Activity the system still holds (`list`).
class LiveActivityInfo {
  const LiveActivityInfo({
    required this.sessionId,
    required this.activityId,
    required this.state,
    this.hostId,
    this.phase,
    this.updatedAt,
    this.pushToken,
  });
  final String sessionId;
  final String activityId;
  final LiveActivityPhase state;

  /// plan/design/sync-contract.md §5, when the native side tells them: the
  /// host it belongs to, what it shows (`running`, `failed`, …) and since when.
  final String? hostId;
  final String? phase;
  final DateTime? updatedAt;

  /// Its current push token (hex), when the native side has one.
  final String? pushToken;
}

/// A token for one Activity (hex), or a state change of one.
typedef LivePushToken = ({String sessionId, String token});
typedef LiveStateChange = ({String sessionId, LiveActivityPhase state});

/// The result of an Approve / Deny App Intent (`onDecision`).
typedef LiveDecision = ({String sessionId, String eventId, String decision, String result});

/// Tokens the native side kept while Dart wasn't listening.
class LivePendingTokens {
  const LivePendingTokens({this.activities = const [], this.pushToStart});
  static const none = LivePendingTokens();
  final List<LivePushToken> activities;
  final String? pushToStart;
}

/// Why [LiveActivityChannel.start] did not start one.
enum LiveStartError { unsupported, disabled, failed }

typedef LiveStartResult = ({String? activityId, LiveStartError? error});

class LiveActivityChannel {
  LiveActivityChannel([this._channel = liveActivityMethodChannel]);

  final MethodChannel _channel;
  final _pushTokens = StreamController<LivePushToken>.broadcast();
  final _pushToStart = StreamController<String>.broadcast();
  final _states = StreamController<LiveStateChange>.broadcast();
  final _decisions = StreamController<LiveDecision>.broadcast();
  bool _attached = false;

  static final _hex = RegExp(r'^[0-9a-f]{16,400}$');
  static final _id = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

  Stream<LivePushToken> get pushTokens => _pushTokens.stream;
  Stream<String> get pushToStartTokens => _pushToStart.stream;
  Stream<LiveStateChange> get activityStates => _states.stream;
  Stream<LiveDecision> get decisions => _decisions.stream;

  /// Starts taking native calls. Idempotent; nothing off iOS.
  void attach() {
    if (_attached || !isRemoteOnlyPlatform) return;
    _attached = true;
    _channel.setMethodCallHandler(handle);
  }

  static String? _str(Object? m, String key, [RegExp? shape]) {
    if (m is! Map) return null;
    final v = m[key];
    if (v is! String || v.isEmpty) return null;
    if (shape != null && !shape.hasMatch(v)) return null;
    return v;
  }

  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'onPushToken':
        final session = _str(args, 'sessionId', _id);
        final token = _str(args, 'token')?.toLowerCase();
        if (session != null && token != null && _hex.hasMatch(token)) {
          _pushTokens.add((sessionId: session, token: token));
        }
        return null;
      case 'onPushToStartToken':
        final token = _str(args, 'token')?.toLowerCase();
        if (token != null && _hex.hasMatch(token)) _pushToStart.add(token);
        return null;
      case 'onActivityState':
        final session = _str(args, 'sessionId', _id);
        final state = LiveActivityPhase.parse(args is Map ? args['state'] : null);
        if (session != null && state != null) _states.add((sessionId: session, state: state));
        return null;
      case 'onDecision':
        final session = _str(args, 'sessionId', _id);
        // A stop has no event (Swift sends an empty eventId).
        final decision = _str(args, 'decision') ?? '';
        final event = decision == 'stop' ? '' : _str(args, 'eventId', _id);
        if (session != null && event != null) {
          _decisions.add((
            sessionId: session,
            eventId: event,
            decision: decision,
            result: _str(args, 'result') ?? '',
          ));
        }
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }

  Future<T?> _call<T>(String method, [Object? args]) async {
    if (!isRemoteOnlyPlatform) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<LiveSupport> status() async {
    final m = await _call<Map<Object?, Object?>>('status');
    return m == null ? LiveSupport.unsupported : LiveSupport.fromMap(m);
  }

  /// Starts the Activity of [sessionId]; one already active for it is
  /// returned as is.
  Future<LiveStartResult> start({
    required String sessionId,
    required String title,
    required String hostId,
    required String lang,
    required Map<String, Object?> state,
  }) async {
    if (!isRemoteOnlyPlatform) return (activityId: null, error: LiveStartError.unsupported);
    try {
      final r = await _channel.invokeMethod<Object?>('start', {
        'sessionId': sessionId,
        'title': title,
        'hostId': hostId,
        'lang': lang,
        'state': state,
      });
      final id = _str(r, 'activityId');
      return id == null ? (activityId: null, error: LiveStartError.failed) : (activityId: id, error: null);
    } on MissingPluginException {
      return (activityId: null, error: LiveStartError.unsupported);
    } on PlatformException catch (e) {
      final error = switch (e.code) {
        'unsupported' => LiveStartError.unsupported,
        'disabled' => LiveStartError.disabled,
        _ => LiveStartError.failed,
      };
      // `exists` carries the id of the one already running.
      if (e.code == 'exists') {
        final id = _str(e.details, 'activityId');
        if (id != null) return (activityId: id, error: null);
      }
      return (activityId: null, error: error);
    }
  }

  /// False when the native side doesn't know [sessionId] (`not-found`) or
  /// there is none.
  Future<bool> update({
    required String sessionId,
    required Map<String, Object?> state,
    ({String title, String body})? alert,
  }) async {
    if (!isRemoteOnlyPlatform) return false;
    try {
      await _channel.invokeMethod<void>('update', {
        'sessionId': sessionId,
        'state': state,
        if (alert != null) 'alert': {'title': alert.title, 'body': alert.body},
      });
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> end({
    required String sessionId,
    Map<String, Object?>? state,
    LiveDismissal dismissal = LiveDismissal.system,
  }) => _call<void>('end', {'sessionId': sessionId, 'state': ?state, 'dismissal': dismissal.wire});

  Future<List<LiveActivityInfo>> list() async {
    final raw = await _call<List<Object?>>('list');
    if (raw == null) return const [];
    return [
      for (final m in raw)
        if (_str(m, 'sessionId', _id) case final session?)
          if (_str(m, 'activityId') case final id?)
            if (LiveActivityPhase.parse((m as Map)['state']) case final state?)
              LiveActivityInfo(
                sessionId: session,
                activityId: id,
                state: state,
                hostId: _str(m, 'hostId'),
                phase: _str(m, 'phase'),
                updatedAt: switch (m['updatedAt']) {
                  final num s => DateTime.fromMillisecondsSinceEpoch((s * 1000).round()),
                  _ => null,
                },
                pushToken: _str(m, 'pushToken'),
              ),
    ];
  }

  Future<void> endAll({LiveDismissal dismissal = LiveDismissal.immediate}) =>
      _call<void>('endAll', {'dismissal': dismissal.wire});

  Future<LivePendingTokens> takePendingTokens() async {
    final m = await _call<Map<Object?, Object?>>('takePendingTokens');
    if (m == null) return LivePendingTokens.none;
    final list = m['activities'];
    final start = _str(m, 'pushToStart')?.toLowerCase();
    return LivePendingTokens(
      activities: [
        if (list is List)
          for (final a in list)
            if (_str(a, 'sessionId', _id) case final session?)
              if (_str(a, 'token')?.toLowerCase() case final token? when _hex.hasMatch(token))
                (sessionId: session, token: token),
      ],
      pushToStart: start != null && _hex.hasMatch(start) ? start : null,
    );
  }

  Future<void> dispose() async {
    if (_attached) _channel.setMethodCallHandler(null);
    await _pushTokens.close();
    await _pushToStart.close();
    await _states.close();
    await _decisions.close();
  }
}

final liveActivityChannelProvider = Provider<LiveActivityChannel>((ref) {
  final channel = LiveActivityChannel();
  ref.onDispose(() => unawaited(channel.dispose()));
  return channel;
});

/// What the phone offers; re-read whenever the app comes back to the
/// foreground (the person may have switched 实时活动 off in Settings).
final liveActivityStatusProvider = FutureProvider<LiveSupport>((ref) {
  ref.listen<bool>(appForegroundProvider, (previous, next) {
    if (next && previous == false) ref.invalidateSelf();
  });
  return ref.watch(liveActivityChannelProvider).status();
});
