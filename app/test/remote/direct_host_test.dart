// Direct-URL hosts: HostRef encoding, launch-link parsing, the saved config
// and secrets, and the link's cookie → token → "paste a new token" ladder
// against an in-process imitation of `dsh web`. Every token here is fake.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/direct/direct_link.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  group('HostRef', () {
    test('direct round-trips; older encodings decode as before', () {
      expect(HostRef.decode(const HostRef.direct('direct-1').encode()), const HostRef.direct('direct-1'));
      expect(const HostRef.direct('x').kind, HostKind.direct);
      expect(const HostRef.direct('x') == const HostRef.ssh('x'), isFalse);
      // What earlier versions stored still means the same host.
      expect(HostRef.decode('{"kind":"ssh","id":"ssh-1"}'), const HostRef.ssh('ssh-1'));
      expect(HostRef.decode('{"kind":"relay","id":"mac","name":"A"}').name, 'A');
      expect(HostRef.decode('{"kind":"local","id":"local"}'), HostRef.local);
      // Unknown kinds and broken ids fall back to 本机.
      expect(HostRef.decode('{"kind":"teleport","id":"x"}'), HostRef.local);
      expect(HostRef.decode('{"kind":"direct","id":""}'), HostRef.local);
      expect(HostRef.decode('{"kind":"direct"}'), HostRef.local);
    });

    test('label', () {
      expect(hostLabel(HostKind.direct, '服务器'), appL10n.directHostLabel('服务器'));
      expect(hostLabel(HostKind.direct, null), appL10n.directHostLabel(appL10n.directHostFallback));
    });
  });

  group('launch link parsing', () {
    test('a launch link in the URL field is split', () {
      final input = parseDirectHostInput(url: 'https://dsh.example.com/?token=fake-token-1');
      expect(input.baseUri.toString(), 'https://dsh.example.com');
      expect(input.token, 'fake-token-1');
    });

    test('a launch link in the token field fills the URL too', () {
      final input = parseDirectHostInput(url: '', token: 'dsh web: https://dsh.example.com:8443/dsh/?token=fake-2');
      expect(input.baseUri.toString(), 'https://dsh.example.com:8443/dsh');
      expect(input.token, 'fake-2');
    });

    test('typed URL wins over the link host; a bare token stays as typed', () {
      final input = parseDirectHostInput(url: 'dsh.example.com/', token: '  fake-3  ');
      expect(input.baseUri.toString(), 'https://dsh.example.com');
      expect(input.token, 'fake-3');
      expect(parseDirectHostInput(url: 'http://10.0.0.2:3080').baseUri.toString(), 'http://10.0.0.2:3080');
      expect(parseDirectHostInput(url: 'https://Dsh.Example.com').token, isNull);
    });

    test('bad or missing URLs', () {
      Matcher problem(DirectInputProblem p) =>
          throwsA(isA<DirectInputException>().having((e) => e.problem, 'problem', p));
      expect(() => parseDirectHostInput(url: ''), problem(DirectInputProblem.urlMissing));
      expect(() => parseDirectHostInput(url: '', token: 'fake-only'), problem(DirectInputProblem.urlMissing));
      expect(() => parseDirectHostInput(url: 'ftp://dsh.example.com'), problem(DirectInputProblem.urlInvalid));
      expect(() => parseDirectHostInput(url: 'https://me:pw@dsh.example.com'), problem(DirectInputProblem.urlInvalid));
    });

    test('config JSON round-trips and rejects junk', () {
      const config = DirectHostConfig(id: 'direct-1', name: '服务器', baseUrl: 'https://dsh.example.com');
      expect(DirectHostConfig.fromJson(jsonDecode(jsonEncode(config.toJson()))), config);
      expect(config.address, 'dsh.example.com');
      expect(DirectHostConfig.fromJson({'id': 'direct-1', 'baseUrl': 'ftp://x'}), isNull);
      expect(DirectHostConfig.fromJson({'baseUrl': 'https://x'}), isNull);
      expect(DirectHostConfig.fromJson({'id': 'd', 'baseUrl': 'https://x.example'})!.name, 'x.example');
      expect(DirectSecrets.decodeCookie('{oops'), isNull);
    });
  });

  group('link', () {
    late FakeDsh dsh;
    setUp(() async => dsh = await FakeDsh.start());
    tearDown(() => dsh.close());

    DshCookie cookie(String value) =>
        DshCookie(name: FakeDsh.cookieName, value: value, authority: '127.0.0.1:${dsh.port}');

    ({DirectHostLink link, List<DshCookie?> saved}) link(DirectSecrets secrets) {
      final saved = <DshCookie?>[];
      final link = DirectHostLink(
        config: DirectHostConfig(id: 'direct-t', name: 't', baseUrl: dsh.baseUri.toString()),
        loadSecrets: () async => secrets,
        saveCookie: (c) async => saved.add(c),
        retryFirstOpen: false,
        readyTimeout: const Duration(seconds: 5),
      );
      addTearDown(link.close);
      return (link: link, saved: saved);
    }

    bool tokenLogin() => dsh.acceptedAuthority != null;

    test('a stored cookie that still works connects without the token', () async {
      final t = link(DirectSecrets(token: 'stale-fake-token', cookie: cookie(FakeDsh.cookieValue)));
      final client = await t.link.open();
      expect(t.link.status.isConnected, isTrue);
      expect(tokenLogin(), isFalse);
      expect(t.saved, isEmpty);
      expect(client.connection.cookie!.value, FakeDsh.cookieValue);
    });

    test('a refused cookie falls back to the token and stores the new cookie', () async {
      final t = link(DirectSecrets(token: FakeDsh.token, cookie: cookie('v1.expired.sig')));
      await t.link.open();
      expect(t.link.status.isConnected, isTrue);
      expect(tokenLogin(), isTrue);
      expect(t.saved.first, isNull, reason: 'the refused cookie is forgotten');
      expect(t.saved.last!.value, FakeDsh.cookieValue);
      expect(t.link.cookie!.value, FakeDsh.cookieValue);
    });

    test('cookie refused and token stale: fails asking for a new token', () async {
      final t = link(DirectSecrets(token: 'wrong-fake-token', cookie: cookie('v1.expired.sig')));
      await expectLater(t.link.open(), throwsA(isA<HostLinkError>()));
      final error = t.link.status.error!;
      expect(t.link.status.phase, HostLinkPhase.failed);
      expect(error.kind, HostLinkErrorKind.authFailed);
      expect(error.retryable, isFalse);
      expect(error.message, appL10n.directErrTokenRejected);
      expect(error.toString(), isNot(contains('wrong-fake-token')));
      expect(t.saved, [null]);
    });

    test('no cookie and no token: asks for one', () async {
      final t = link(const DirectSecrets());
      await expectLater(t.link.open(), throwsA(isA<HostLinkError>()));
      expect(t.link.status.error!.kind, HostLinkErrorKind.authFailed);
      expect(t.link.status.error!.message, appL10n.directErrTokenNeeded);
    });

    test('a cookie for another address is not sent', () async {
      final other = DshCookie(name: FakeDsh.cookieName, value: FakeDsh.cookieValue, authority: 'elsewhere:1');
      final t = link(DirectSecrets(token: FakeDsh.token, cookie: other));
      await t.link.open();
      expect(tokenLogin(), isTrue);
    });

    test('nothing listening: a retryable unreachable error', () async {
      final port = dsh.port;
      final stored = cookie(FakeDsh.cookieValue);
      await dsh.close();
      final t = DirectHostLink(
        config: DirectHostConfig(id: 'direct-t', name: 't', baseUrl: 'http://127.0.0.1:$port'),
        loadSecrets: () async => DirectSecrets(token: FakeDsh.token, cookie: stored),
        saveCookie: (_) async {},
        retryFirstOpen: false,
      );
      addTearDown(t.close);
      await expectLater(t.open(), throwsA(isA<HostLinkError>()));
      expect(t.status.error!.kind, HostLinkErrorKind.unreachable);
      expect(t.status.error!.retryable, isTrue);
      dsh = await FakeDsh.start();
    });

    test('the Host dropping the cookie mid-session logs in again with the token', () async {
      final t = link(const DirectSecrets(token: FakeDsh.token));
      final client = await t.link.open();
      // The server forgets the session: the next socket is refused once.
      dsh.rejectWebSocket = true;
      final relogin = t.link.statuses.firstWhere((s) => s.step == HostLinkStep.login);
      for (final socket in [...dsh.sockets]) {
        await socket.ws.close();
      }
      await relogin.timeout(const Duration(seconds: 10));
      dsh.rejectWebSocket = false;
      await t.link.statuses.firstWhere((s) => s.isConnected).timeout(const Duration(seconds: 10));
      expect(identical(t.link.currentClient, client), isTrue);
      expect(t.saved.whereType<DshCookie>(), hasLength(2), reason: 'first login, then the re-login');
    });
  });

  group('hosts controller', () {
    ProviderContainer container(MemorySecretStore secrets) {
      final c = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          localConnectionProvider.overrideWith(_NoLocal.new),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('config in prefs, token and cookie only in the secret store; delete clears both', () async {
      final secrets = MemorySecretStore();
      final c = container(secrets);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.ready;
      const config = DirectHostConfig(id: 'direct-1', name: '服务器', baseUrl: 'https://dsh.example.com');
      const minted = DshCookie(name: 'dsh-auth-x', value: 'v1.fake.sig', authority: 'dsh.example.com');
      expect(await hosts.saveDirect(config, token: 'fake-token-9', cookie: minted), isTrue);

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(HostsController.directPrefsKey)!;
      expect(stored, contains('https://dsh.example.com'));
      expect(stored, isNot(contains('fake-token-9')));
      expect(stored, isNot(contains('v1.fake.sig')));
      expect(prefs.getString(HostsController.prefsKey), isNull, reason: 'SSH list untouched');

      final loaded = await hosts.loadDirectSecrets('direct-1');
      expect(loaded.token, 'fake-token-9');
      expect(loaded.cookie!.value, 'v1.fake.sig');

      // A fresh container reads it back.
      final again = container(secrets);
      await again.read(hostsProvider.notifier).ready;
      expect(again.read(hostsProvider).directById('direct-1'), config);

      // Moving to another URL forgets the cookie (it belonged to the old one),
      // an empty token keeps the saved one.
      await hosts.saveDirect(config.copyWith(baseUrl: 'https://other.example.com'));
      final moved = await hosts.loadDirectSecrets('direct-1');
      expect(moved.token, 'fake-token-9');
      expect(moved.cookie, isNull);

      c.read(activeHostProvider.notifier).select(const HostRef.direct('direct-1'));
      await hosts.removeDirect('direct-1');
      expect(c.read(hostsProvider).direct, isEmpty);
      expect(secrets.values.keys.where((k) => k.startsWith('direct.')), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(activeHostProvider), HostRef.local);
    });

    test('SSH saves keep the direct list', () async {
      final c = container(MemorySecretStore());
      final hosts = c.read(hostsProvider.notifier);
      await hosts.ready;
      await hosts.saveDirect(const DirectHostConfig(id: 'direct-1', name: 'a', baseUrl: 'https://a.example'));
      await hosts.saveSsh(const SshHostConfig(id: 'ssh-1', name: 'b', host: 'b', user: 'me'));
      expect(c.read(hostsProvider).direct, hasLength(1));
      expect(c.read(hostsProvider).ssh, hasLength(1));
    });

    test('a status row paused while the link connects still ends up connected', () async {
      // Riverpod pauses providers whose widgets are off screen (a closed
      // drawer); statuses emitted then must not be lost.
      final dsh = await FakeDsh.start();
      addTearDown(dsh.close);
      final c = container(MemorySecretStore());
      final hosts = c.read(hostsProvider.notifier);
      await hosts.ready;
      await hosts.saveDirect(
        DirectHostConfig(id: 'direct-1', name: 'fake', baseUrl: dsh.baseUri.toString()),
        token: FakeDsh.token,
      );
      const host = HostRef.direct('direct-1');
      c.read(activeHostProvider.notifier).select(host);
      final row = c.listen(hostLinkStatusProvider(host), (_, _) {}, fireImmediately: true);
      addTearDown(row.close);
      row.pause();
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(remoteConnectionProvider(host).future);
      row.resume();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.read(hostLinkStatusProvider(host)).value?.isConnected, isTrue);
    });

    test('the active direct host connects through hostLinkProvider', () async {
      final dsh = await FakeDsh.start();
      addTearDown(dsh.close);
      final secrets = MemorySecretStore();
      final c = container(secrets);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.ready;
      await hosts.saveDirect(
        DirectHostConfig(id: 'direct-1', name: 'fake', baseUrl: dsh.baseUri.toString()),
        token: FakeDsh.token,
      );
      c.read(activeHostProvider.notifier).select(const HostRef.direct('direct-1'));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      final connection = await c.read(remoteConnectionProvider(const HostRef.direct('direct-1')).future);
      expect(connection!.kind, HostKind.direct);
      expect(connection.label, appL10n.directHostLabel('fake'));
      expect((await hosts.loadDirectSecrets('direct-1')).cookie!.value, FakeDsh.cookieValue);
    });
  });
}
