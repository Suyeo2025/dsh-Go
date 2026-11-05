// HTTPS client for the push bridge (dsh-watch-bridge, Contract C): pairing,
// the APNs token registration, the device's own state, unpairing.
//
// Never logs or returns the bearer token, the DSH cookie or the APNs token in
// an error: [BridgeException] carries the bridge's error code only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;

/// One bridge response.
class BridgeResponse {
  const BridgeResponse(this.status, this.body);
  final int status;
  final String body;
}

/// Sends one request. [pinSha256] (hex) pins a self-signed bridge certificate.
typedef BridgeTransport =
    Future<BridgeResponse> Function(
      String method,
      Uri url, {
      required Map<String, String> headers,
      String? body,
      String? pinSha256,
    });

/// A failed bridge call: [code] is the bridge's stable error code
/// (`unauthorized`, `device-revoked`, `pair-invalid`, …) or one of
/// `network`, `bad-certificate`, `bad-response`.
class BridgeException implements Exception {
  const BridgeException(this.code, {this.status, this.attemptsRemaining, this.retryAfter});

  final String code;
  final int? status;
  final int? attemptsRemaining;
  final int? retryAfter;

  /// The bridge no longer knows this device: pair again.
  bool get unpaired => code == 'device-revoked' || code == 'unauthorized';

  @override
  String toString() => 'BridgeException($code${status == null ? '' : ' $status'})';
}

/// What `POST /v1/pair*` hands back.
class BridgePairing {
  const BridgePairing({required this.deviceId, required this.deviceToken});
  final String deviceId;
  final String deviceToken;
}

/// `GET /v1/device`: this device as the bridge sees it.
class BridgeDevice {
  const BridgeDevice({required this.deviceId, this.pushEnv, this.pushTopic, this.hasPush = false, this.invalid = false});

  final String deviceId;
  final bool hasPush;
  final String? pushEnv;
  final String? pushTopic;

  /// APNs said the token is gone (410): register again.
  final bool invalid;

  static BridgeDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['deviceId'];
    if (id is! String || id.isEmpty) return null;
    final push = json['push'];
    return BridgeDevice(
      deviceId: id,
      hasPush: push is Map,
      pushEnv: push is Map && push['env'] is String ? push['env'] as String : null,
      pushTopic: push is Map && push['topic'] is String ? push['topic'] as String : null,
      invalid: json['invalid'] == true,
    );
  }
}

/// `https://watch.example.com`, `watch.example.com/` → `https://watch.example.com`.
/// Https only, no path, query or user info; null otherwise.
Uri? normalizeBridgeUrl(String text) {
  var t = text.trim();
  if (t.isEmpty) return null;
  if (!t.contains('://')) t = 'https://$t';
  final uri = Uri.tryParse(t);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  if (uri.hasQuery || uri.hasFragment || (uri.path.isNotEmpty && uri.path != '/')) return null;
  return Uri(scheme: 'https', host: uri.host.toLowerCase(), port: uri.hasPort ? uri.port : null);
}

/// A `dshwatch://pair?b=<bridge>&c=<code>&fp=<sha256>&v=1` link, as
/// `dsh-watch-bridge pair` prints it.
class BridgePairLink {
  const BridgePairLink({required this.bridge, required this.code, this.fingerprint});

  final Uri bridge;
  final String code;

  /// Lowercase hex SHA-256 of the bridge certificate (pinned mode only).
  final String? fingerprint;

  static final _code = RegExp(r'^([A-Z2-7]{8}|[0-9]{6})$');
  static final _fp = RegExp(r'^[0-9a-f]{64}$');

  /// Finds the link anywhere in [text] (a pasted line); null when there is none.
  static BridgePairLink? tryParse(String text) {
    final m = RegExp(r'dshwatch://pair\?\S+').firstMatch(text);
    if (m == null) return null;
    final Uri uri;
    try {
      uri = Uri.parse(m[0]!);
    } on FormatException {
      return null;
    }
    final q = uri.queryParameters;
    if (q['v'] != '1') return null;
    final bridge = normalizeBridgeUrl(q['b'] ?? '');
    final code = (q['c'] ?? '').toUpperCase();
    final fp = q['fp']?.toLowerCase().replaceAll(':', '');
    if (bridge == null || !_code.hasMatch(code)) return null;
    if (fp != null && !_fp.hasMatch(fp)) return null;
    return BridgePairLink(bridge: bridge, code: code, fingerprint: fp);
  }
}

/// A fresh random UUID v4 (Idempotency-Key).
String newIdempotencyKey([math.Random? random]) {
  final r = random ?? math.Random.secure();
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// [BridgeTransport] over dart:io, 15 s per request.
Future<BridgeResponse> ioBridgeTransport(
  String method,
  Uri url, {
  required Map<String, String> headers,
  String? body,
  String? pinSha256,
}) async {
  String fpOf(X509Certificate c) => crypto.sha256.convert(c.der).toString();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  if (pinSha256 != null) client.badCertificateCallback = (cert, _, _) => fpOf(cert) == pinSha256;
  try {
    final req = await client.openUrl(method, url).timeout(const Duration(seconds: 15));
    headers.forEach(req.headers.set);
    if (body != null) req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final cert = res.certificate;
    if (pinSha256 != null && (cert == null || fpOf(cert) != pinSha256)) {
      throw const BridgeException('bad-certificate');
    }
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    return BridgeResponse(res.statusCode, text);
  } on BridgeException {
    rethrow;
  } on HandshakeException {
    throw const BridgeException('bad-certificate');
  } catch (_) {
    throw const BridgeException('network');
  } finally {
    client.close(force: true);
  }
}

class BridgeClient {
  BridgeClient(this.base, {this.pinSha256, BridgeTransport? transport, this.random})
    : _send = transport ?? ioBridgeTransport;

  final Uri base;
  final String? pinSha256;
  final BridgeTransport _send;
  final math.Random? random;

  Future<Object?> _request(String method, String path, {String? token, Map<String, Object?>? body}) async {
    final headers = <String, String>{'accept': 'application/json'};
    if (token != null) headers['authorization'] = 'Bearer $token';
    if (method != 'GET') headers['idempotency-key'] = newIdempotencyKey(random);
    String? payload;
    if (body != null) {
      payload = jsonEncode(body);
      headers['content-type'] = 'application/json';
    }
    final res = await _send(method, base.replace(path: path), headers: headers, body: payload, pinSha256: pinSha256);
    Object? json;
    if (res.body.isNotEmpty) {
      try {
        json = jsonDecode(res.body);
      } on FormatException {
        json = null;
      }
    }
    if (res.status >= 200 && res.status < 300) return json;
    final error = json is Map ? json['error'] : null;
    final code = error is Map && error['code'] is String ? error['code'] as String : 'bad-response';
    final details = error is Map ? error['details'] : null;
    final remaining = details is Map ? details['attemptsRemaining'] : null;
    final retry = error is Map ? error['retryAfter'] : null;
    throw BridgeException(
      code,
      status: res.status,
      attemptsRemaining: remaining is int ? remaining : null,
      retryAfter: retry is int ? retry : null,
    );
  }

  BridgePairing _pairing(Object? json) {
    if (json is Map) {
      final id = json['deviceId'];
      final token = json['deviceToken'];
      if (id is String && id.isNotEmpty && token is String && token.isNotEmpty) {
        return BridgePairing(deviceId: id, deviceToken: token);
      }
    }
    throw const BridgeException('bad-response');
  }

  /// `GET /v1/health`: whether it is a bridge that speaks API 1.
  Future<bool> health() async {
    final json = await _request('GET', '/v1/health');
    return json is Map && json['api'] is List && (json['api'] as List).contains(1);
  }

  /// Pairs with the DSH session this app is already signed in with: the
  /// bridge checks [cookie] against its DSH (read-only) and forgets it.
  Future<BridgePairing> pairWithDsh({
    required String dshHost,
    required String cookie,
    required String deviceName,
    required String devicePub,
    required String clientVersion,
  }) async => _pairing(
    await _request(
      'POST',
      '/v1/pair/dsh',
      body: {
        'dshHost': dshHost,
        'cookie': cookie,
        'deviceName': deviceName,
        'devicePub': devicePub,
        'clientVersion': clientVersion,
        'app': 'dshgo',
      },
    ),
  );

  /// Pairs with a one-time code from `dsh-watch-bridge pair`.
  Future<BridgePairing> pairWithCode({
    required String code,
    required String deviceName,
    required String devicePub,
    required String clientVersion,
  }) async => _pairing(
    await _request(
      'POST',
      '/v1/pair',
      body: {
        'code': code,
        'deviceName': deviceName,
        'devicePub': devicePub,
        'clientVersion': clientVersion,
        'app': 'dshgo',
      },
    ),
  );

  Future<void> putPush(String token, {required String apnsToken, required String env, String? topic}) async {
    await _request(
      'PUT',
      '/v1/device/push',
      token: token,
      body: {'mode': 'direct', 'apnsToken': apnsToken, 'env': env, 'topic': ?topic},
    );
  }

  Future<BridgeDevice> device(String token) async {
    final d = BridgeDevice.fromJson(await _request('GET', '/v1/device', token: token));
    if (d == null) throw const BridgeException('bad-response');
    return d;
  }

  Future<void> unpair(String token) async {
    await _request('DELETE', '/v1/device', token: token);
  }
}
