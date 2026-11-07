// Dart side of the `dsh/push` method channel (native: the iOS AppDelegate's
// APNs registration and UNUserNotificationCenter delegate). Both directions go
// over the one method channel:
//
//   Dart → native: getStatus, requestPermission, register, takeLaunchTap,
//                  clearDelivered
//   native → Dart: onToken, onTokenError, onTap, shouldPresent
//
// Every call tolerates the native side being absent (Android, widget tests):
// [PushChannel.status] then says `unsupported` and nothing else happens.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const pushMethodChannel = MethodChannel('dsh/push');

/// What the system lets the app do (UNAuthorizationStatus).
enum PushAuth {
  /// No native side (Android, tests).
  unsupported,
  notDetermined,
  denied,
  authorized,
  provisional,
  ephemeral;

  bool get allowed => this == authorized || this == provisional || this == ephemeral;

  static PushAuth parse(Object? raw) => switch (raw) {
    'notDetermined' => notDetermined,
    'denied' => denied,
    'authorized' => authorized,
    'provisional' => provisional,
    'ephemeral' => ephemeral,
    _ => unsupported,
  };
}

/// The native answer to `getStatus`.
class PushSystemStatus {
  const PushSystemStatus({required this.auth, this.env, this.topic});

  const PushSystemStatus.unsupported() : this(auth: PushAuth.unsupported);

  final PushAuth auth;

  /// `sandbox` (debug builds) or `production` (TestFlight / App Store).
  final String? env;

  /// The app's bundle id, which is the APNs topic (`com.colex.dshgo`).
  final String? topic;

  factory PushSystemStatus.fromMap(Map<Object?, Object?> m) {
    final env = m['env'];
    final topic = m['topic'];
    return PushSystemStatus(
      auth: PushAuth.parse(m['auth']),
      env: env == 'sandbox' || env == 'production' ? env as String : null,
      topic: topic is String && topic.isNotEmpty ? topic : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PushSystemStatus && other.auth == auth && other.env == env && other.topic == topic;

  @override
  int get hashCode => Object.hash(auth, env, topic);
}

/// A fresh APNs device token (lowercase hex) and the environment it is for.
class PushToken {
  const PushToken(this.token, this.env);
  final String token;
  final String env;

  static final _hex = RegExp(r'^[0-9a-f]{64,200}$');

  /// Null unless [m] carries a hex token and a known environment.
  static PushToken? fromMap(Object? m) {
    if (m is! Map) return null;
    final token = m['token'];
    final env = m['env'];
    if (token is! String || !_hex.hasMatch(token)) return null;
    if (env != 'sandbox' && env != 'production') return null;
    return PushToken(token, env as String);
  }

  @override
  String toString() => 'PushToken($env, ${token.length} hex)';
}

/// The kinds of push the bridge sends a DSH Go device (`dg.k`).
enum PushKind {
  approval,
  question,
  done,
  failed,
  notice,
  withdraw;

  static PushKind? parse(Object? raw) => switch (raw) {
    'approval' => approval,
    'question' => question,
    'done' => done,
    'failed' => failed,
    'notice' => notice,
    'withdraw' => withdraw,
    _ => null,
  };
}

/// The plain routing part of a push (`dg` in the APNs payload): the
/// conversation to open and, for a request, its event id. Only ids and
/// enums; the content stays encrypted.
class PushRoute {
  const PushRoute({required this.kind, this.sessionId, this.eventId});

  final PushKind kind;

  /// The top-level conversation (subagent requests are routed to their root).
  final String? sessionId;
  final String? eventId;

  static final _id = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

  /// Null for anything that isn't a version-1 `dg` dictionary.
  static PushRoute? fromMap(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != 1) return null;
    final kind = PushKind.parse(raw['k']);
    if (kind == null) return null;
    String? id(Object? v) => v is String && _id.hasMatch(v) ? v : null;
    return PushRoute(kind: kind, sessionId: id(raw['s']), eventId: id(raw['e']));
  }

  @override
  bool operator ==(Object other) =>
      other is PushRoute && other.kind == kind && other.sessionId == sessionId && other.eventId == eventId;

  @override
  int get hashCode => Object.hash(kind, sessionId, eventId);

  @override
  String toString() => 'PushRoute(${kind.name} $sessionId $eventId)';
}

class PushChannel {
  PushChannel([this._channel = pushMethodChannel]);

  final MethodChannel _channel;
  final _tokens = StreamController<PushToken>.broadcast();
  final _tokenErrors = StreamController<String>.broadcast();
  final _taps = StreamController<PushRoute>.broadcast();
  bool _attached = false;

  /// Asked while the app is on screen: whether a push for [route] still shows
  /// as a banner (false for the conversation that is open). Unset: show.
  bool Function(PushRoute route)? shouldPresent;

  Stream<PushToken> get tokens => _tokens.stream;

  /// The registration failed (`code` only, never the system's text).
  Stream<String> get tokenErrors => _tokenErrors.stream;

  /// A notification was tapped while the app was running (a cold start's
  /// tap comes from [takeLaunchTap]).
  Stream<PushRoute> get taps => _taps.stream;

  /// Starts taking native calls. Idempotent.
  void attach() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler(handle);
  }

  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        final token = PushToken.fromMap(call.arguments);
        if (token != null) _tokens.add(token);
        return null;
      case 'onTokenError':
        final args = call.arguments;
        final code = args is Map && args['code'] is String ? args['code'] as String : 'failed';
        _tokenErrors.add(code);
        return null;
      case 'onTap':
        final route = PushRoute.fromMap(call.arguments);
        if (route != null) _taps.add(route);
        return null;
      case 'shouldPresent':
        final route = PushRoute.fromMap(call.arguments);
        if (route == null) return true;
        return shouldPresent?.call(route) ?? true;
      default:
        throw MissingPluginException(call.method);
    }
  }

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<PushSystemStatus> status() async {
    final m = await _call<Map<Object?, Object?>>('getStatus');
    return m == null ? const PushSystemStatus.unsupported() : PushSystemStatus.fromMap(m);
  }

  /// Shows the system prompt once (later calls answer with the stored
  /// choice); on yes the native side also registers for remote notifications.
  Future<bool> requestPermission() async => await _call<bool>('requestPermission') ?? false;

  /// Asks APNs for the device token again; it arrives on [tokens].
  Future<void> register() => _call<void>('register');

  /// The notification that launched the app, once; null when none.
  Future<PushRoute?> takeLaunchTap() async => PushRoute.fromMap(await _call<Object?>('takeLaunchTap'));

  /// Hands the Notification Service Extension what it needs to decrypt the
  /// pushes (notify-v3 §4.3): this phone's X25519 private key (base64url),
  /// the bridge's device id and the app language, into the shared Keychain
  /// group. Never the bridge token. Without a native side: nothing.
  Future<void> setNotificationSecrets({required String privateKey, required String deviceId, required String lang}) =>
      _call<void>('setNotificationSecrets', {'privateKey': privateKey, 'deviceId': deviceId, 'lang': lang});

  /// Unpaired: the extension's copy goes.
  Future<void> clearNotificationSecrets() => _call<void>('clearNotificationSecrets', const <String, Object?>{});

  /// Removes the delivered notifications of [sessionId] (it is open now).
  Future<void> clearDelivered(String sessionId) => _call<void>('clearDelivered', {'sessionId': sessionId});

  Future<void> dispose() async {
    if (_attached) _channel.setMethodCallHandler(null);
    await _tokens.close();
    await _tokenErrors.close();
    await _taps.close();
  }
}
