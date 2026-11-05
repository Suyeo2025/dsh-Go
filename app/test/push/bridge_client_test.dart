import 'dart:convert';

import 'package:dsh_app/push/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call {
  _Call(this.method, this.url, this.headers, this.body, this.pin);
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;
  final String? pin;
  Map<String, Object?> get json => jsonDecode(body!) as Map<String, Object?>;
}

/// A bridge that answers from [routes] (`METHOD /path` → status, body).
class FakeBridge {
  FakeBridge(this.routes);
  final Map<String, (int, Object?)> routes;
  final calls = <_Call>[];

  Future<BridgeResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
    String? pinSha256,
  }) async {
    calls.add(_Call(method, url, headers, body, pinSha256));
    final r = routes['$method ${url.path}'];
    if (r == null) return const BridgeResponse(404, '{"error":{"code":"not-found","message":"no such route"}}');
    return BridgeResponse(r.$1, r.$2 == null ? '' : jsonEncode(r.$2));
  }
}

void main() {
  test('normalizeBridgeUrl: https origins only', () {
    expect(normalizeBridgeUrl('watch.example.com').toString(), 'https://watch.example.com');
    expect(normalizeBridgeUrl(' https://Watch.Example.com/ ').toString(), 'https://watch.example.com');
    expect(normalizeBridgeUrl('https://w.example.com:8743').toString(), 'https://w.example.com:8743');
    expect(normalizeBridgeUrl('http://watch.example.com'), isNull);
    expect(normalizeBridgeUrl('https://watch.example.com/v1'), isNull);
    expect(normalizeBridgeUrl('https://u:p@watch.example.com'), isNull);
    expect(normalizeBridgeUrl(''), isNull);
  });

  test('BridgePairLink reads what `dsh-watch-bridge pair` prints', () {
    final fp = 'AB' * 32;
    final link = BridgePairLink.tryParse(
      'Pairing link:\ndshwatch://pair?b=https%3A%2F%2Fwatch.example.com&c=K7M2P4QX&fp=$fp&v=1',
    )!;
    expect(link.bridge.toString(), 'https://watch.example.com');
    expect(link.code, 'K7M2P4QX');
    expect(link.fingerprint, 'ab' * 32);
    expect(BridgePairLink.tryParse('dshwatch://pair?b=https%3A%2F%2Fw.example.com&c=123456&v=1')!.fingerprint, isNull);
    expect(BridgePairLink.tryParse('dshwatch://pair?b=https%3A%2F%2Fw.example.com&c=123456&v=2'), isNull);
    expect(BridgePairLink.tryParse('dshwatch://pair?b=http%3A%2F%2Fw.example.com&c=123456&v=1'), isNull);
    expect(BridgePairLink.tryParse('dshwatch://pair?b=https%3A%2F%2Fw.example.com&c=12&v=1'), isNull);
    expect(BridgePairLink.tryParse('nothing here'), isNull);
  });

  test('newIdempotencyKey is a v4 UUID', () {
    final key = newIdempotencyKey();
    expect(key, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(newIdempotencyKey(), isNot(key));
  });

  group('BridgeClient', () {
    final base = Uri.parse('https://watch.example.com');

    test('pairWithDsh sends the session once, as JSON with an Idempotency-Key', () async {
      final bridge = FakeBridge({
        'GET /v1/health': (200, {'api': [1], 'dsh': 'connected'}),
        'POST /v1/pair/dsh': (200, {'deviceId': 'd-1', 'deviceToken': 'tok', 'network': 'public-tls'}),
      });
      final client = BridgeClient(base, transport: bridge.send);
      expect(await client.health(), isTrue);
      final p = await client.pairWithDsh(
        dshHost: 'dsh.example.com',
        cookie: 'dsh-auth-x=v1.a.b',
        deviceName: 'DSH Go',
        devicePub: 'A' * 43,
        clientVersion: '1.0.10',
      );
      expect(p.deviceId, 'd-1');
      expect(p.deviceToken, 'tok');
      final call = bridge.calls.last;
      expect(call.headers['content-type'], 'application/json');
      expect(call.headers['idempotency-key'], isNotNull);
      expect(call.headers.containsKey('authorization'), isFalse);
      expect(call.json, {
        'dshHost': 'dsh.example.com',
        'cookie': 'dsh-auth-x=v1.a.b',
        'deviceName': 'DSH Go',
        'devicePub': 'A' * 43,
        'clientVersion': '1.0.10',
        'app': 'dshgo',
      });
      // GETs carry no key.
      expect(bridge.calls.first.headers.containsKey('idempotency-key'), isFalse);
    });

    test('putPush / device / unpair authenticate with the device token', () async {
      final bridge = FakeBridge({
        'PUT /v1/device/push': (204, null),
        'GET /v1/device': (
          200,
          {
            'deviceId': 'd-1',
            'app': 'dshgo',
            'push': {'mode': 'direct', 'env': 'production', 'topic': 'com.colex.dshgo'},
            'invalid': true,
          },
        ),
        'DELETE /v1/device': (204, null),
      });
      final client = BridgeClient(base, transport: bridge.send, pinSha256: 'ff' * 32);
      await client.putPush('tok', apnsToken: 'c' * 64, env: 'production', topic: 'com.colex.dshgo');
      expect(bridge.calls.last.json, {
        'mode': 'direct',
        'apnsToken': 'c' * 64,
        'env': 'production',
        'topic': 'com.colex.dshgo',
      });
      final d = await client.device('tok');
      expect(d.invalid, isTrue);
      expect(d.pushTopic, 'com.colex.dshgo');
      await client.unpair('tok');
      for (final c in bridge.calls) {
        expect(c.headers['authorization'], 'Bearer tok');
        expect(c.pin, 'ff' * 32);
      }
      expect(bridge.calls.last.body, isNull);
    });

    test('errors carry the bridge code only', () async {
      final bridge = FakeBridge({
        'POST /v1/pair': (
          400,
          {
            'error': {
              'code': 'pair-invalid',
              'message': 'wrong code',
              'details': {'attemptsRemaining': 3},
            },
          },
        ),
        'GET /v1/device': (
          401,
          {
            'error': {'code': 'device-revoked', 'message': 'device revoked'},
          },
        ),
      });
      final client = BridgeClient(base, transport: bridge.send);
      await expectLater(
        client.pairWithCode(code: '123456', deviceName: 'DSH Go', devicePub: 'A' * 43, clientVersion: '1.0'),
        throwsA(isA<BridgeException>().having((e) => e.code, 'code', 'pair-invalid').having((e) => e.attemptsRemaining, 'left', 3)),
      );
      await expectLater(
        client.device('tok'),
        throwsA(isA<BridgeException>().having((e) => e.unpaired, 'unpaired', isTrue)),
      );
      await expectLater(client.unpair('tok'), throwsA(isA<BridgeException>().having((e) => e.code, 'code', 'not-found')));
    });
  });
}
