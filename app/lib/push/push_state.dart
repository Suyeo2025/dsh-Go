// 推送通知 (remote-only builds): pairs this phone with the push bridge that
// watches the DSH host, hands the bridge the APNs device token, and keeps that
// registration fresh. The bridge pushes 回复完成 / 等你审批 / 等你回答; a tap
// opens the conversation (push_tap_host.dart).
//
// Stored: the pairing (bridge URL, host id, device id, the hash of the last
// token sent and when) in SharedPreferences; the bridge's device token and
// this phone's X25519 key in the [SecretStore]. Never logged.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../live/live_activity_bridge_sync.dart';
import '../platform/platform_caps.dart';
import '../remote/secret_store.dart';
import '../state/app_info.dart';
import '../state/hosts_state.dart';
import 'bridge_client.dart';
import 'push_channel.dart';

/// A paired bridge.
class PushPairing {
  const PushPairing({
    required this.bridge,
    required this.hostId,
    required this.deviceId,
    this.pin,
    this.tokenHash,
    this.pushedAt,
  });

  /// `https://watch.example.com`.
  final String bridge;

  /// The direct host whose conversations the pushes open.
  final String hostId;
  final String deviceId;

  /// SHA-256 (hex) of a self-signed bridge certificate; null for a public one.
  final String? pin;

  /// SHA-256 (hex) of the APNs token last registered, and when.
  final String? tokenHash;
  final int? pushedAt;

  PushPairing copyWith({String? tokenHash, int? pushedAt}) => PushPairing(
    bridge: bridge,
    hostId: hostId,
    deviceId: deviceId,
    pin: pin,
    tokenHash: tokenHash ?? this.tokenHash,
    pushedAt: pushedAt ?? this.pushedAt,
  );

  Map<String, Object?> toJson() => {
    'bridge': bridge,
    'hostId': hostId,
    'deviceId': deviceId,
    'pin': ?pin,
    'tokenHash': ?tokenHash,
    'pushedAt': ?pushedAt,
  };

  static PushPairing? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final bridge = raw['bridge'];
    final hostId = raw['hostId'];
    final deviceId = raw['deviceId'];
    if (bridge is! String || normalizeBridgeUrl(bridge) == null) return null;
    if (hostId is! String || hostId.isEmpty || deviceId is! String || deviceId.isEmpty) return null;
    final pin = raw['pin'];
    final hash = raw['tokenHash'];
    final at = raw['pushedAt'];
    return PushPairing(
      bridge: bridge,
      hostId: hostId,
      deviceId: deviceId,
      pin: pin is String ? pin : null,
      tokenHash: hash is String ? hash : null,
      pushedAt: at is int ? at : null,
    );
  }
}

/// Where the pushes stand, for the settings row.
enum PushHealth {
  /// Not paired.
  off,

  /// Paired, the system hasn't been asked yet or said no.
  needsPermission,

  /// Paired and allowed, the token isn't with the bridge yet.
  registering,

  /// Everything in place.
  on,

  /// APNs dropped the token, or registering failed: tap to retry.
  tokenFailed,

  /// The bridge couldn't be reached on the last check.
  unreachable,

  /// The bridge no longer knows this phone (revoked there).
  revoked,
}

/// Why pairing failed, for one line in the UI.
enum PushPairProblem {
  bridgeUrlInvalid,
  noDirectHost,

  /// No DSH session on this phone for the host: connect to it once first.
  notSignedIn,
  notABridge,
  unreachable,
  badCertificate,

  /// The bridge refused the DSH session (expired, or another server's).
  dshRejected,

  /// The bridge doesn't offer pairing by DSH sign-in: use a pairing link.
  dshPairingOff,
  codeInvalid,
  codeExpired,
  locked,
  rateLimited,
  failed,
}

class PushPairException implements Exception {
  const PushPairException(this.problem, {this.attemptsRemaining});
  final PushPairProblem problem;
  final int? attemptsRemaining;

  @override
  String toString() => 'PushPairException(${problem.name})';
}

class PushState {
  const PushState({
    this.loaded = false,
    this.pairing,
    this.system = const PushSystemStatus.unsupported(),
    this.health = PushHealth.off,
    this.busy = false,
  });

  final bool loaded;
  final PushPairing? pairing;
  final PushSystemStatus system;
  final PushHealth health;

  /// Pairing or unpairing in flight.
  final bool busy;

  bool get paired => pairing != null;

  PushState copyWith({
    bool? loaded,
    PushPairing? Function()? pairing,
    PushSystemStatus? system,
    PushHealth? health,
    bool? busy,
  }) => PushState(
    loaded: loaded ?? this.loaded,
    pairing: pairing != null ? pairing() : this.pairing,
    system: system ?? this.system,
    health: health ?? this.health,
    busy: busy ?? this.busy,
  );
}

/// Re-register the token at least this often even when it hasn't changed.
const pushRefreshInterval = Duration(days: 7);

final pushChannelProvider = Provider<PushChannel>((ref) {
  final channel = PushChannel();
  ref.onDispose(() => unawaited(channel.dispose()));
  return channel;
});

/// Builds the client for a bridge (tests swap the transport).
final bridgeClientFactoryProvider = Provider<BridgeClient Function(Uri base, {String? pin})>(
  (ref) =>
      (base, {pin}) => BridgeClient(base, pinSha256: pin),
);

/// Clock for the refresh interval (tests pin it).
final pushClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class PushController extends Notifier<PushState> {
  static const prefsKey = 'push_bridge_v1';
  static const deviceTokenKey = 'push.bridge.deviceToken';
  static const keyPairKey = 'push.bridge.x25519';

  late Future<void> _loaded;
  final _subs = <StreamSubscription<Object?>>[];

  SecretStore get _secrets => ref.read(secretStoreProvider);
  PushChannel get _channel => ref.read(pushChannelProvider);

  @override
  PushState build() {
    ref.onDispose(() {
      for (final s in _subs) {
        unawaited(s.cancel());
      }
      _subs.clear();
    });
    _loaded = _load();
    return const PushState();
  }

  Future<void> get ready => _loaded;

  Future<void> _load() async {
    PushPairing? pairing;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      if (raw != null) pairing = PushPairing.fromJson(jsonDecode(raw));
    } catch (_) {
      // No preferences backend (tests) or a corrupt entry: not paired.
    }
    if (!ref.mounted) return;
    if (isRemoteOnlyPlatform) {
      final channel = _channel..attach();
      _subs.add(channel.tokens.listen((t) => unawaited(_onToken(t))));
      _subs.add(channel.tokenErrors.listen((_) => _setHealth(PushHealth.tokenFailed)));
    }
    final system = await _channel.status();
    if (!ref.mounted) return;
    state = state.copyWith(loaded: true, pairing: () => pairing, system: system, health: _healthFor(pairing, system));
    // Apple: ask for the token on every launch; it may have changed.
    if (pairing != null && system.auth.allowed) unawaited(_channel.register());
    if (pairing != null) unawaited(refresh());
  }

  PushHealth _healthFor(PushPairing? pairing, PushSystemStatus system) {
    if (pairing == null) return PushHealth.off;
    if (!system.auth.allowed) return PushHealth.needsPermission;
    return (pairing.tokenHash ?? '').isEmpty ? PushHealth.registering : PushHealth.on;
  }

  void _setHealth(PushHealth health) {
    if (ref.mounted && state.paired) state = state.copyWith(health: health);
  }

  /// Null when unreadable (a Keychain hiccup means "not there" here).
  Future<String?> _readSecret(String key) async {
    try {
      return await _secrets.read(key);
    } catch (_) {
      return null;
    }
  }

  BridgeClient _client(PushPairing p) =>
      ref.read(bridgeClientFactoryProvider)(normalizeBridgeUrl(p.bridge)!, pin: p.pin);

  Future<void> _save(PushPairing? pairing) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (pairing == null) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, jsonEncode(pairing.toJson()));
      }
    } catch (_) {}
  }

  /// This phone's X25519 public key (base64url, 32 bytes), made once. The
  /// bridge seals each push's content to it.
  Future<String> _devicePub() async {
    final algo = X25519();
    final stored = await _secrets.read(keyPairKey);
    SimpleKeyPair? pair;
    if (stored != null) {
      try {
        pair = await algo.newKeyPairFromSeed(base64Url.decode(base64Url.normalize(stored)));
      } catch (_) {
        pair = null;
      }
    }
    if (pair == null) {
      pair = await algo.newKeyPair();
      await _secrets.write(keyPairKey, base64Url.encode(await pair.extractPrivateKeyBytes()).replaceAll('=', ''));
    }
    final pub = await pair.extractPublicKey();
    return base64Url.encode(pub.bytes).replaceAll('=', '');
  }

  String get _clientVersion => AppInfo.version.split('+').first;

  static const _deviceName = 'DSH Go';

  /// Pairs with the bridge at [bridgeText] using this phone's DSH session on
  /// direct host [hostId], then asks for notification permission.
  Future<void> pairWithDsh(String bridgeText, String hostId) async {
    final base = normalizeBridgeUrl(bridgeText);
    if (base == null) throw const PushPairException(PushPairProblem.bridgeUrlInvalid);
    final hosts = ref.read(hostsProvider.notifier);
    await hosts.ready;
    if (ref.read(hostsProvider).directById(hostId) == null) throw const PushPairException(PushPairProblem.noDirectHost);
    final cookie = (await hosts.loadDirectSecrets(hostId)).cookie;
    if (cookie == null || cookie.isExpiredAt(ref.read(pushClockProvider)())) {
      throw const PushPairException(PushPairProblem.notSignedIn);
    }
    await _pair(base, hostId, null, (client, pub) {
      return client.pairWithDsh(
        dshHost: cookie.authority,
        cookie: cookie.header,
        deviceName: _deviceName,
        devicePub: pub,
        clientVersion: _clientVersion,
      );
    });
  }

  /// Pairs with a `dsh-watch-bridge pair` link pasted as [text].
  Future<void> pairWithLink(String text, String hostId) async {
    final link = BridgePairLink.tryParse(text);
    if (link == null) throw const PushPairException(PushPairProblem.codeInvalid);
    await ref.read(hostsProvider.notifier).ready;
    if (ref.read(hostsProvider).directById(hostId) == null) throw const PushPairException(PushPairProblem.noDirectHost);
    await _pair(link.bridge, hostId, link.fingerprint, (client, pub) {
      return client.pairWithCode(
        code: link.code,
        deviceName: _deviceName,
        devicePub: pub,
        clientVersion: _clientVersion,
      );
    });
  }

  Future<void> _pair(
    Uri base,
    String hostId,
    String? pin,
    Future<BridgePairing> Function(BridgeClient client, String pub) send,
  ) async {
    await _loaded;
    if (state.busy) return;
    state = state.copyWith(busy: true);
    try {
      final client = ref.read(bridgeClientFactoryProvider)(base, pin: pin);
      final BridgePairing result;
      try {
        if (!await client.health()) throw const PushPairException(PushPairProblem.notABridge);
        result = await send(client, await _devicePub());
      } on BridgeException catch (e) {
        throw _pairProblem(e);
      }
      // A previous pairing with another bridge is simply replaced (that
      // bridge drops the device when APNs reports the token gone).
      await _secrets.write(deviceTokenKey, result.deviceToken);
      final pairing = PushPairing(bridge: base.toString(), hostId: hostId, deviceId: result.deviceId, pin: pin);
      await _save(pairing);
      if (!ref.mounted) return;
      state = state.copyWith(pairing: () => pairing, health: _healthFor(pairing, state.system));
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
    // 灵动岛: the Live Activity tokens known so far go to the new bridge.
    if (ref.mounted) unawaited(ref.read(liveActivityBridgeSyncProvider).resync());
    await enableNotifications();
  }

  static PushPairException _pairProblem(BridgeException e) => PushPairException(switch (e.code) {
    'network' => PushPairProblem.unreachable,
    'bad-certificate' => PushPairProblem.badCertificate,
    'unauthorized' => PushPairProblem.dshRejected,
    'not-applicable' || 'not-found' => PushPairProblem.dshPairingOff,
    'pair-invalid' || 'bad-request' => PushPairProblem.codeInvalid,
    'pair-expired' => PushPairProblem.codeExpired,
    'pair-locked' => PushPairProblem.locked,
    'rate-limited' => PushPairProblem.rateLimited,
    'bad-response' => PushPairProblem.notABridge,
    _ => PushPairProblem.failed,
  }, attemptsRemaining: e.attemptsRemaining);

  /// Asks the system (once; later it answers from the stored choice) and
  /// registers for the device token.
  Future<void> enableNotifications() async {
    final granted = await _channel.requestPermission();
    final system = await _channel.status();
    if (!ref.mounted) return;
    state = state.copyWith(system: system, health: _healthFor(state.pairing, system));
    if (granted || system.auth.allowed) await _channel.register();
  }

  /// Re-reads the system permission (the person may have changed it in
  /// Settings) and asks the bridge how it sees this device.
  Future<void> refresh() async {
    await _loaded;
    final system = await _channel.status();
    if (!ref.mounted) return;
    state = state.copyWith(system: system, health: _healthFor(state.pairing, system));
    final pairing = state.pairing;
    final token = pairing == null ? null : await _readSecret(deviceTokenKey);
    if (pairing == null || token == null) return;
    try {
      final device = await _client(pairing).device(token);
      if (!ref.mounted || state.pairing?.deviceId != pairing.deviceId) return;
      if (device.invalid || !device.hasPush) {
        // Registered again on the next token (asked for right away).
        await _store(pairing.copyWith(tokenHash: ''));
        if (system.auth.allowed) {
          _setHealth(device.invalid ? PushHealth.tokenFailed : PushHealth.registering);
          unawaited(_channel.register());
        }
      }
      // 灵动岛: the bridge still knows this phone; re-send the Live Activity tokens.
      unawaited(ref.read(liveActivityBridgeSyncProvider).resync());
    } on BridgeException catch (e) {
      if (!ref.mounted) return;
      if (e.unpaired) {
        _setHealth(PushHealth.revoked);
      } else if (e.code == 'network') {
        _setHealth(PushHealth.unreachable);
      }
    }
  }

  Future<void> _store(PushPairing pairing) async {
    await _save(pairing);
    if (ref.mounted) state = state.copyWith(pairing: () => pairing);
  }

  static String _hash(String s) => crypto.sha256.convert(utf8.encode(s)).toString();

  Future<void> _onToken(PushToken t) async {
    await _loaded;
    final pairing = state.pairing;
    if (pairing == null) return;
    final now = ref.read(pushClockProvider)();
    final hash = _hash('${t.env}:${t.token}');
    final fresh =
        pairing.tokenHash == hash &&
        pairing.pushedAt != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(pairing.pushedAt!)) < pushRefreshInterval;
    if (fresh) {
      _setHealth(PushHealth.on);
      return;
    }
    final token = await _readSecret(deviceTokenKey);
    if (token == null) {
      _setHealth(PushHealth.revoked);
      return;
    }
    try {
      await _client(pairing).putPush(token, apnsToken: t.token, env: t.env, topic: state.system.topic);
      if (!ref.mounted || state.pairing?.deviceId != pairing.deviceId) return;
      await _store(pairing.copyWith(tokenHash: hash, pushedAt: now.millisecondsSinceEpoch));
      _setHealth(PushHealth.on);
    } on BridgeException catch (e) {
      if (!ref.mounted) return;
      _setHealth(
        e.unpaired
            ? PushHealth.revoked
            : e.code == 'network'
            ? PushHealth.unreachable
            : PushHealth.tokenFailed,
      );
    }
  }

  /// Retries the token registration (the 「重试」 of a failed state).
  Future<void> retry() async {
    final pairing = state.pairing;
    if (pairing == null) return;
    await _store(pairing.copyWith(tokenHash: ''));
    await enableNotifications();
  }

  /// Unpairs: tells the bridge (best effort) and forgets everything here.
  /// Returns false when the bridge couldn't be told (it keeps the device
  /// until APNs reports the token gone, or `devices revoke` on the server).
  Future<bool> unpair() async {
    await _loaded;
    final pairing = state.pairing;
    if (pairing == null) return true;
    state = state.copyWith(busy: true);
    var told = true;
    try {
      final token = await _readSecret(deviceTokenKey);
      if (token != null) {
        try {
          await _client(pairing).unpair(token);
        } on BridgeException catch (e) {
          // Already gone there counts as told.
          told = e.unpaired;
        }
      }
      await _secrets.delete(deviceTokenKey);
      await _save(null);
      // The bridge drops the whole device: forget the Live Activity tokens here only.
      if (ref.mounted) unawaited(ref.read(liveActivityBridgeSyncProvider).clear(remote: false));
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false, pairing: () => null, health: PushHealth.off);
    }
    return told;
  }
}

final pushProvider = NotifierProvider<PushController, PushState>(PushController.new);

@visibleForTesting
String debugPushTokenHash(PushToken t) => PushController._hash('${t.env}:${t.token}');
