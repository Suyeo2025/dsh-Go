// Remote-only devices (iOS): first run asks how to reach a host (Google
// sign-in suggested), the remote page leads with direct hosts, and the
// add form splits a pasted launch link. Android keeps its pages.

import 'dart:convert';

import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/remote/direct/direct_google_sign_in.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/onboarding/onboarding_flow.dart';
import 'package:dsh_app/ui/onboarding/remote_only_setup.dart';
import 'package:dsh_app/ui/remote/direct_host_form.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

const _direct = DirectHostConfig(id: 'direct-1', name: '我的服务器', baseUrl: 'https://dsh.example.com');

void main() {
  late MemorySecretStore secrets;
  var linkStatus = HostLinkStatus.idle;
  WebAuthenticator auth = (_, _) async => throw const DirectSignInException(DirectSignInFailure.unsupported);

  setUp(() {
    secrets = MemorySecretStore();
    linkStatus = HostLinkStatus.idle;
    SharedPreferences.setMockInitialValues({
      HostsController.directPrefsKey: jsonEncode([_direct.toJson()]),
    });
  });
  tearDown(() => debugRemoteOnlyOverride = null);

  List<Override> overrides() => [
    secretStoreProvider.overrideWithValue(secrets),
    networkKicksProvider.overrideWithValue(const Stream.empty()),
    relayBackendProvider.overrideWithValue(FakeRelayBackend()),
    hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(linkStatus)),
    directWebAuthenticatorProvider.overrideWith((ref) => auth),
    urlOpenerProvider.overrideWithValue((_) async => true),
    localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  ];

  Future<void> pump(WidgetTester tester, Widget home) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides()));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('remote-only first run: no 本机, other ways open the host list, direct opens the form', (tester) async {
    debugRemoteOnlyOverride = true;
    var other = 0;
    await pump(
      tester,
      OnboardingFlow(
        step: OnboardingStep.runtime,
        chooseRuntime: true,
        onWelcomeDone: () {},
        onRuntimeDone: () {},
        onKeyDone: () {},
        onRemote: () => other++,
        onRemoteConnected: () {},
      ),
    );
    expect(find.byType(RemoteOnlySetupView), findsOneWidget);
    expect(find.text('本机'), findsNothing, reason: 'no 「本机」 choice without an engine');
    expect(find.text('推荐'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-only-other')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-only-continue')));
    await tester.pump();
    expect(other, 1);

    await tester.tap(find.byKey(const ValueKey('remote-only-direct')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-only-continue')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(DirectHostFormPage), findsOneWidget);
  });

  testWidgets('remote-only first run: Google sign-in comes first and opens the sign-in-only form', (tester) async {
    debugRemoteOnlyOverride = true;
    await pump(
      tester,
      OnboardingFlow(
        step: OnboardingStep.runtime,
        chooseRuntime: true,
        onWelcomeDone: () {},
        onRuntimeDone: () {},
        onKeyDone: () {},
        onRemote: () {},
        onRemoteConnected: () {},
      ),
    );
    final google = tester.getTopLeft(find.byKey(const ValueKey('remote-only-google'))).dy;
    expect(google, lessThan(tester.getTopLeft(find.byKey(const ValueKey('remote-only-direct'))).dy));
    await tester.tap(find.byKey(const ValueKey('remote-only-continue')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(DirectHostFormPage), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-google')), findsOneWidget);
    expect(find.byKey(const ValueKey('direct-url')), findsNothing);
  });

  testWidgets('a stale token on a Google-gated host offers 用 Google 重新登录, which renews it', (tester) async {
    debugRemoteOnlyOverride = true;
    final gated = _direct.copyWith(signInUrl: () => 'https://gate.example.com');
    SharedPreferences.setMockInitialValues({
      HostsController.directPrefsKey: jsonEncode([gated.toJson()]),
      ActiveHostController.prefsKey: const HostRef.direct('direct-1').encode(),
    });
    secrets.values[DirectSecrets.tokenKey('direct-1')] = 'old-fake';
    secrets.values[DirectSecrets.cookieKey('direct-1')] = '{"name":"dsh-auth-x","value":"v1.old","authority":"x"}';
    linkStatus = const HostLinkStatus(
      HostLinkPhase.failed,
      error: HostLinkError(HostLinkErrorKind.authFailed, '启动 token 已失效'),
    );
    Uri? asked;
    auth = (url, _) async {
      asked = url;
      return Uri(
        scheme: 'dshgo-auth',
        host: 'auth',
        queryParameters: {
          'state': url.queryParameters['state']!,
          'token': 'new-fake',
          'base': 'https://dsh.example.com',
        },
      ).toString();
    };
    await pump(tester, const RemoteScreen());
    final button = find.text('用 Google 重新登录');
    expect(button, findsOneWidget);
    await tester.tap(button);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(asked!.origin, 'https://gate.example.com');
    expect(secrets.values[DirectSecrets.tokenKey('direct-1')], 'new-fake');
    expect(secrets.values.containsKey(DirectSecrets.cookieKey('direct-1')), isFalse);
  });

  testWidgets('the add form splits a pasted launch link and requires a URL', (tester) async {
    debugRemoteOnlyOverride = true;
    await pump(tester, const DirectHostFormPage());
    await tester.enterText(find.byKey(const ValueKey('direct-token')), 'https://dsh.example.com/?token=fake-token-1');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final url = tester.widget<TextField>(find.byKey(const ValueKey('direct-url'))).controller!.text;
    final token = tester.widget<TextField>(find.byKey(const ValueKey('direct-token'))).controller!.text;
    expect(url, 'https://dsh.example.com');
    expect(token, 'fake-token-1');

    await tester.enterText(find.byKey(const ValueKey('direct-url')), '');
    await tester.tap(find.byKey(const ValueKey('direct-save')));
    await tester.pump();
    expect(find.text('填写主机网址'), findsOneWidget);
  });

  testWidgets('remote-only remote page and host sheet list direct hosts, no 本机', (tester) async {
    debugRemoteOnlyOverride = true;
    await pump(tester, const RemoteScreen());
    expect(find.text('直连 URL'), findsOneWidget);
    expect(find.text('我的服务器'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-direct-host')), findsOneWidget);

    await pump(tester, const Scaffold(body: HostSheet(onManage: _noop)));
    expect(find.text('我的服务器'), findsOneWidget);
    expect(find.text('直连 · dsh.example.com'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-row-local-local')), findsNothing);
  });

  testWidgets('Android keeps its remote page and host sheet', (tester) async {
    debugRemoteOnlyOverride = false;
    SharedPreferences.setMockInitialValues({});
    await pump(tester, const RemoteScreen());
    expect(find.text('直连 URL'), findsNothing);
    await pump(tester, const Scaffold(body: HostSheet(onManage: _noop)));
    expect(find.byKey(const ValueKey('host-row-local-local')), findsOneWidget);
  });
}

void _noop() {}
