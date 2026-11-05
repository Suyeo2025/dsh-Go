// "用 Google 登录" for direct hosts: the request URL, the callback checks
// (state, scheme, base), the channel's cancel / failure / missing plugin, the
// saved sign-in address, and the form's Google button over a mocked channel.
// Every token here is fake.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/remote/direct/direct_google_sign_in.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/direct_host_form.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

const _state = 'state-abcdefghijklmnopqrstuvwxyz0123456789';

String _callback({
  String scheme = 'dshgo-auth',
  String host = 'auth',
  String state = _state,
  String? token = 'fake-token-1',
  String? base = 'https://dsh-app.example.com',
}) => Uri(scheme: scheme, host: host, queryParameters: {'state': state, 'token': ?token, 'base': ?base}).toString();

void main() {
  group('callback parsing', () {
    Matcher invalid() =>
        throwsA(isA<DirectSignInException>().having((e) => e.kind, 'kind', DirectSignInFailure.invalidCallback));

    test('a matching callback yields the base and token', () {
      final result = parseSignInCallback(_callback(base: 'https://dsh-app.example.com/'), state: _state);
      expect(result.baseUri.toString(), 'https://dsh-app.example.com');
      expect(result.token, 'fake-token-1');
    });

    test('state mismatch', () {
      expect(() => parseSignInCallback(_callback(state: '${_state}x'), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(), state: 'another-state-0123456789'), invalid());
    });

    test('wrong scheme or host', () {
      expect(() => parseSignInCallback(_callback(scheme: 'https'), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(scheme: 'evil-auth'), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(host: 'elsewhere'), state: _state), invalid());
      expect(() => parseSignInCallback('not a url at all', state: _state), invalid());
    });

    test('base must be an https URL', () {
      expect(() => parseSignInCallback(_callback(base: 'http://dsh-app.example.com'), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(base: 'dsh-app.example.com'), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(base: 'https://me:pw@dsh.example.com'), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(base: 'javascript:alert(1)'), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(base: null), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(token: null), state: _state), invalid());
      expect(() => parseSignInCallback(_callback(token: ''), state: _state), invalid());
    });

    test('a failure never repeats the token', () {
      try {
        parseSignInCallback(
          _callback(state: 'wrong-state-0123456789', token: 'secret-fake-token'),
          state: _state,
        );
        fail('should throw');
      } on DirectSignInException catch (e) {
        expect(e.toString(), isNot(contains('secret-fake-token')));
        expect(e.message, isNot(contains('secret-fake-token')));
      }
    });
  });

  group('request', () {
    test('state is 32 random bytes in base64url without padding', () {
      final a = newSignInState();
      expect(a, hasLength(43));
      expect(RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(a), isTrue);
      expect(newSignInState(), isNot(a));
    });

    test('request URL goes to the gate with cb and state', () {
      final url = directSignInRequestUrl(Uri.parse('https://dsh.example.com'), 'st-0123456789abcdef');
      expect(url.toString(), 'https://dsh.example.com/__gate/app?cb=dshgo-auth&state=st-0123456789abcdef');
      expect(normalizeSignInUrl('http://dsh.example.com'), isNull);
      expect(normalizeSignInUrl('dsh.example.com/')!.toString(), 'https://dsh.example.com');
    });

    test('signInWithGoogle checks the callback against the state it sent', () async {
      Uri? asked;
      String? scheme;
      final result = await signInWithGoogle(
        Uri.parse('https://dsh.example.com'),
        random: math.Random(1),
        authenticate: (url, s) async {
          asked = url;
          scheme = s;
          return _callback(state: url.queryParameters['state']!);
        },
      );
      expect(scheme, 'dshgo-auth');
      expect(asked!.path, '/__gate/app');
      expect(result.token, 'fake-token-1');
      // A callback carrying someone else's state is refused.
      await expectLater(
        signInWithGoogle(Uri.parse('https://dsh.example.com'), authenticate: (_, _) async => _callback()),
        throwsA(isA<DirectSignInException>()),
      );
    });
  });

  group('channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(directWebAuthChannel, null));

    Future<DirectSignInFailure?> failureOf(Future<Object?> Function(MethodCall) handler) async {
      messenger.setMockMethodCallHandler(directWebAuthChannel, handler);
      try {
        await channelWebAuthenticator(Uri.parse('https://dsh.example.com/__gate/app'), 'dshgo-auth');
        return null;
      } on DirectSignInException catch (e) {
        return e.kind;
      }
    }

    test('sends url, callbackScheme and ephemeral; returns the callback', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(directWebAuthChannel, (call) async {
        seen = call;
        return _callback();
      });
      final callback = await channelWebAuthenticator(Uri.parse('https://dsh.example.com/x'), 'dshgo-auth');
      expect(callback, _callback());
      expect(seen!.method, 'authenticate');
      expect(seen!.arguments, {'url': 'https://dsh.example.com/x', 'callbackScheme': 'dshgo-auth', 'ephemeral': false});
    });

    test('cancel, failure, no plugin', () async {
      expect(await failureOf((_) async => throw PlatformException(code: 'CANCELED')), DirectSignInFailure.canceled);
      expect(await failureOf((_) async => throw PlatformException(code: 'FAILED')), DirectSignInFailure.failed);
      expect(await failureOf((_) async => null), DirectSignInFailure.failed);
      // No handler at all: Android and tests.
      messenger.setMockMethodCallHandler(directWebAuthChannel, null);
      try {
        await channelWebAuthenticator(Uri.parse('https://dsh.example.com'), 'dshgo-auth');
        fail('should throw');
      } on DirectSignInException catch (e) {
        expect(e.kind, DirectSignInFailure.unsupported);
      }
      expect(const DirectSignInException(DirectSignInFailure.canceled).message, isNull);
    });
  });

  group('config', () {
    test('signInUrl round-trips; older entries and http addresses have none', () {
      const config = DirectHostConfig(
        id: 'direct-1',
        name: 's',
        baseUrl: 'https://dsh-app.example.com',
        signInUrl: 'https://dsh.example.com',
      );
      expect(DirectHostConfig.fromJson(jsonDecode(jsonEncode(config.toJson()))), config);
      final old = DirectHostConfig.fromJson({'id': 'direct-1', 'name': 's', 'baseUrl': 'https://a.example'})!;
      expect(old.signInUrl, isNull);
      expect(old.toJson().containsKey('signInUrl'), isFalse);
      expect(
        DirectHostConfig.fromJson({'id': 'd', 'baseUrl': 'https://a.example', 'signInUrl': 'http://x.example'})!
            .signInUrl,
        isNull,
      );
      expect(config.copyWith(signInUrl: () => null).signInUrl, isNull);
    });

    test('renewDirectToken replaces the token and drops the cookie', () async {
      SharedPreferences.setMockInitialValues({});
      final secrets = MemorySecretStore();
      final c = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
        ],
      );
      addTearDown(c.dispose);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.ready;
      const config = DirectHostConfig(
        id: 'direct-1',
        name: 's',
        baseUrl: 'https://a.example',
        signInUrl: 'https://g.example',
      );
      await hosts.saveDirect(
        config,
        token: 'old-fake',
        cookie: const DshCookie(name: 'dsh-auth-x', value: 'v1.old', authority: 'a.example'),
      );
      expect(
        await hosts.renewDirectToken('direct-1', token: 'new-fake', baseUri: Uri.parse('https://b.example')),
        isTrue,
      );
      final loaded = await hosts.loadDirectSecrets('direct-1');
      expect(loaded.token, 'new-fake');
      expect(loaded.cookie, isNull);
      final saved = c.read(hostsProvider).directById('direct-1')!;
      expect(saved.baseUrl, 'https://b.example');
      expect(saved.signInUrl, 'https://g.example');
      expect(await hosts.renewDirectToken('gone', token: 'x'), isFalse);
    });
  });

  group('form', () {
    late MemorySecretStore secrets;
    setUp(() {
      secrets = MemorySecretStore();
      SharedPreferences.setMockInitialValues({});
      debugRemoteOnlyOverride = true;
      // Real sockets for the fake DSH (the test binding answers every request 400).
      HttpOverrides.global = null;
    });
    tearDown(() => debugRemoteOnlyOverride = null);

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required WebAuthenticator auth,
      bool signInOnly = false,
      Uri? dialInstead,
    }) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(body: DirectHostFormPage(signInOnly: signInOnly)),
            ),
          ),
          brightness: Brightness.light,
          overrides: [
            secretStoreProvider.overrideWithValue(secrets),
            networkKicksProvider.overrideWithValue(const Stream.empty()),
            relayBackendProvider.overrideWithValue(FakeRelayBackend()),
            hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
            urlOpenerProvider.overrideWithValue((_) async => true),
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            directWebAuthenticatorProvider.overrideWithValue(auth),
            // The callback names an https address; dial the local fake instead.
            if (dialInstead != null)
              directClientFactoryProvider.overrideWithValue((_) => DshClient(DshConnection(dialInstead))),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      return ProviderScope.containerOf(tester.element(find.byType(DirectHostFormPage)));
    }

    Future<void> frames(WidgetTester tester, [int n = 8]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('Google button fills the URL and token from the callback over the channel', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(directWebAuthChannel, (call) async {
        calls.add(call);
        final url = Uri.parse((call.arguments as Map)['url'] as String);
        return _callback(state: url.queryParameters['state']!, base: 'https://127.0.0.1:9');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(directWebAuthChannel, null));
      await pump(tester, auth: channelWebAuthenticator);

      // An address is needed first.
      await tester.tap(find.byKey(const ValueKey('direct-google')));
      await tester.pump();
      expect(find.text('填写登录地址'), findsOneWidget);
      expect(calls, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('direct-sign-in-url')), 'dsh.example.com');
      await tester.tap(find.byKey(const ValueKey('direct-google')));
      await tester.pump();
      await tester.pump();
      expect(calls.single.method, 'authenticate');
      final asked = Uri.parse((calls.single.arguments as Map)['url'] as String);
      expect(asked.origin, 'https://dsh.example.com');
      expect(asked.path, '/__gate/app');
      expect(asked.queryParameters['cb'], 'dshgo-auth');

      final url = tester.widget<TextField>(find.byKey(const ValueKey('direct-url'))).controller!.text;
      final token = tester.widget<TextField>(find.byKey(const ValueKey('direct-token'))).controller!.text;
      expect(url, 'https://127.0.0.1:9');
      expect(token, 'fake-token-1');
      // The test connection runs by itself (and fails here: nothing listens).
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await frames(tester);
    });

    testWidgets('sign-in-only form: cancel says nothing, a failure says so, manual entry stays reachable', (
      tester,
    ) async {
      var outcome = PlatformException(code: 'CANCELED');
      await pump(
        tester,
        signInOnly: true,
        auth: (_, _) async => throw DirectSignInException(
          outcome.code == 'CANCELED' ? DirectSignInFailure.canceled : DirectSignInFailure.failed,
        ),
      );
      expect(find.byKey(const ValueKey('direct-url')), findsNothing);
      expect(find.byKey(const ValueKey('direct-save')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('direct-sign-in-url')), 'https://dsh.example.com');
      await tester.tap(find.byKey(const ValueKey('direct-google')));
      await frames(tester, 3);
      expect(find.text('Google 登录没有完成，请重试'), findsNothing);

      outcome = PlatformException(code: 'FAILED');
      await tester.tap(find.byKey(const ValueKey('direct-google')));
      await frames(tester, 3);
      expect(find.text('Google 登录没有完成，请重试'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('direct-manual')));
      await frames(tester, 3);
      expect(find.byKey(const ValueKey('direct-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('direct-save')), findsOneWidget);
    });

    testWidgets('sign-in-only form: a good callback is tested, saved with its sign-in address, and closes', (
      tester,
    ) async {
      final dsh = (await tester.runAsync(FakeDsh.start))!;
      addTearDown(() => tester.runAsync(dsh.close));
      final c = await pump(
        tester,
        signInOnly: true,
        dialInstead: dsh.baseUri,
        auth: (url, _) async =>
            _callback(state: url.queryParameters['state']!, token: FakeDsh.token, base: 'https://dsh-app.example.com'),
      );
      await tester.enterText(find.byKey(const ValueKey('direct-sign-in-url')), 'https://dsh.example.com');
      await tester.tap(find.byKey(const ValueKey('direct-google')));
      for (var i = 0; i < 20 && find.byType(DirectHostFormPage).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(DirectHostFormPage), findsNothing, reason: 'saved and closed');
      final host = c.read(hostsProvider).direct.single;
      expect(host.baseUrl, 'https://dsh-app.example.com');
      expect(host.signInUrl, 'https://dsh.example.com');
      final saved = (await tester.runAsync(() => c.read(hostsProvider.notifier).loadDirectSecrets(host.id)))!;
      expect(saved.token, FakeDsh.token);
      expect(saved.cookie!.value, FakeDsh.cookieValue);
    });

    testWidgets('no Google block on Android', (tester) async {
      debugRemoteOnlyOverride = false;
      await pump(tester, auth: (_, _) async => '');
      expect(find.byKey(const ValueKey('direct-google')), findsNothing);
      expect(find.byKey(const ValueKey('direct-url')), findsOneWidget);
    });
  });
}
