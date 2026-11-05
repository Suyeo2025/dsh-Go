// A connected direct link told "check yourself" (back in the foreground, a
// network change): after a long absence it replaces the socket at once,
// otherwise it asks the Host first; either way the header reads
// "重新连接中", not an error, while it does. Runs against the in-process
// imitation of `dsh web`; every token here is fake.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/remote/direct/direct_host_config.dart';
import 'package:dsh_app/remote/direct/direct_link.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

/// Health answers on demand (the link's own open never probes: the tests
/// sign in with the token).
class _ScriptedConnection extends DshConnection {
  _ScriptedConnection(super.baseUri);

  final List<Duration?> probes = [];
  DshHealth answer = DshHealth.ok;
  Completer<DshHealth>? gate;

  @override
  Future<DshHealth> checkHealth({Duration? timeout}) async {
    probes.add(timeout);
    final hold = gate;
    if (hold != null) return hold.future;
    return answer;
  }
}

class _CountingMux extends DshMux {
  _CountingMux(super.carrier);

  int reconnects = 0;

  @override
  void reconnect() {
    reconnects++;
    super.reconnect();
  }
}

class _Client extends DshClient {
  factory _Client(DshConnection connection) => _Client._(DshHttpCarrier(connection));
  _Client._(DshHttpCarrier super.carrier) : mux = _CountingMux(carrier), super.withCarrier();

  @override
  // ignore: overridden_fields
  final _CountingMux mux;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDsh dsh;
  setUp(() async {
    HttpOverrides.global = null;
    dsh = await FakeDsh.start();
  });
  tearDown(() => dsh.close());

  Future<void> settle([int ms = 50]) => Future<void>.delayed(Duration(milliseconds: ms));

  /// A connected link whose app was away for whatever [away] says.
  Future<
    ({
      DirectHostLink link,
      _ScriptedConnection connection,
      _CountingMux mux,
      List<HostLinkStatus> statuses,
      List<DshCookie?> saved,
    })
  >
  connected({
    Duration? Function()? away,
    Duration refreshGrace = const Duration(seconds: 10),
  }) async {
    final clients = <_Client>[];
    final saved = <DshCookie?>[];
    final link = DirectHostLink(
      config: DirectHostConfig(id: 'direct-t', name: 't', baseUrl: dsh.baseUri.toString()),
      loadSecrets: () async => const DirectSecrets(token: FakeDsh.token),
      saveCookie: (c) async => saved.add(c),
      clientFactory: (uri) {
        final client = _Client(_ScriptedConnection(uri));
        clients.add(client);
        return client;
      },
      retryFirstOpen: false,
      readyTimeout: const Duration(seconds: 5),
      awayFor: away,
      refreshGrace: refreshGrace,
    );
    addTearDown(link.close);
    await link.open();
    expect(link.status.isConnected, isTrue);
    final statuses = <HostLinkStatus>[];
    link.statuses.listen(statuses.add);
    final client = clients.single;
    return (
      link: link,
      connection: client.connection as _ScriptedConnection,
      mux: client.mux,
      statuses: statuses,
      saved: saved,
    );
  }

  Future<void> backConnected(DirectHostLink link) =>
      link.statuses.firstWhere((s) => s.isConnected).timeout(const Duration(seconds: 10));

  test('back after 25 s: reconnects at once, "重新连接中" without an error, no probe', () async {
    final t = await connected(away: () => const Duration(seconds: 25));
    final back = backConnected(t.link);
    t.link.kick();
    expect(t.mux.reconnects, 1);
    expect(t.link.status.phase, HostLinkPhase.reconnecting);
    expect(t.link.status.error, isNull);
    await back;
    await settle();
    expect(t.connection.probes, isEmpty, reason: 'no waiting on a probe first');
    expect(t.mux.reconnects, 1);
    expect(t.statuses.map((s) => s.phase), [HostLinkPhase.reconnecting, HostLinkPhase.connected]);
    expect(t.statuses.where((s) => s.error != null), isEmpty);
    expect(t.link.status.isConnected, isTrue);
  });

  test('back after 3 s, Host fine: one probe with the short deadline, no reconnect', () async {
    final t = await connected(away: () => const Duration(seconds: 3));
    t.link.kick();
    await settle();
    expect(t.connection.probes, [DirectHostLink.probeTimeout]);
    expect(t.mux.reconnects, 0);
    expect(t.statuses, isEmpty);
    expect(t.link.status.isConnected, isTrue);
  });

  test('back after 3 s, Host unreachable: reconnects, still without an error', () async {
    final t = await connected(away: () => const Duration(seconds: 3));
    t.connection.answer = DshHealth.unreachable;
    final back = backConnected(t.link);
    t.link.kick();
    await back;
    expect(t.connection.probes, hasLength(1));
    expect(t.mux.reconnects, 1);
    expect(t.statuses.first.phase, HostLinkPhase.reconnecting);
    expect(t.statuses.where((s) => s.error != null), isEmpty);
  });

  test('back after 3 s, cookie refused: logs in again with the token', () async {
    final t = await connected(away: () => const Duration(seconds: 3));
    t.connection.answer = DshHealth.unauthorized;
    final relogin = t.link.statuses.firstWhere((s) => s.step == HostLinkStep.login);
    t.link.kick();
    await relogin.timeout(const Duration(seconds: 5));
    await backConnected(t.link);
    expect(t.connection.probes, hasLength(1));
    expect(t.mux.reconnects, 1, reason: 'the re-login reconnects once');
    expect(t.saved.whereType<DshCookie>(), hasLength(2), reason: 'first login, then the re-login');
  });

  test('no absence known (a network change): probes', () async {
    final t = await connected();
    t.link.kick();
    await settle();
    expect(t.connection.probes, hasLength(1));
    expect(t.mux.reconnects, 0);

    final throwing = await connected(away: () => throw StateError('no clock'));
    throwing.link.kick();
    await settle();
    expect(throwing.connection.probes, hasLength(1), reason: 'a failing awayFor counts as unknown');
    expect(throwing.mux.reconnects, 0);
  });

  test('a probe in flight is not started again', () async {
    final t = await connected();
    final gate = t.connection.gate = Completer<DshHealth>();
    t.link.kick();
    t.link.kick();
    await settle();
    t.link.kick();
    await settle();
    expect(t.connection.probes, hasLength(1));
    gate.complete(DshHealth.ok);
    await settle();
    expect(t.mux.reconnects, 0);
    // Done: the next kick probes again.
    t.connection.gate = null;
    t.link.kick();
    await settle();
    expect(t.connection.probes, hasLength(2));
  });

  test('closed: kicks do nothing, a late probe answer is ignored', () async {
    final t = await connected(away: () => const Duration(seconds: 25));
    await t.link.close();
    t.link.kick();
    expect(t.mux.reconnects, 0);
    expect(t.connection.probes, isEmpty);

    final p = await connected();
    final gate = p.connection.gate = Completer<DshHealth>();
    p.link.kick();
    await settle();
    await p.link.close();
    gate.complete(DshHealth.unreachable);
    await settle();
    expect(p.mux.reconnects, 0);
  });

  test('a reconnect that does not come back turns into the usual error', () async {
    final t = await connected(
      away: () => const Duration(minutes: 5),
      refreshGrace: const Duration(milliseconds: 300),
    );
    dsh
      ..rejectWebSocket = true
      ..rejectedWebSocketStatus = 503;
    t.link.kick();
    expect(t.link.status.error, isNull);
    final failing = await t.link.statuses
        .firstWhere((s) => s.error != null)
        .timeout(const Duration(seconds: 5));
    expect(failing.phase, HostLinkPhase.reconnecting);
    expect(failing.error!.kind, HostLinkErrorKind.unreachable);
    dsh.rejectWebSocket = false;
  });
}
