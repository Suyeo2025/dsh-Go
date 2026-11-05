// 「DeepSeek」 on a remote host: the row opens a key sheet that writes or
// clears the host's own credential (`credentials/set` / `credentials/unset`).

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/providers/providers_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../workspace/support.dart';

/// A host with a credential store; `credentials/set` can be made to fail.
class _KeyHost extends FakeWorkspaceHost {
  _KeyHost({this.configured = false, this.writable = true, this.hasCredentials = true, this.setError});

  bool configured;
  final bool writable;
  final bool hasCredentials;
  final String? setError;
  int catalogReads = 0;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint.startsWith('credentials/')) {
      calls.add((endpoint, args));
      if (!hasCredentials) return RpcError(DshRemoteException('gateway/method-not-found', 'no', const {}));
      switch (endpoint) {
        case 'credentials/describe':
          return RpcOk({
            'DEEPSEEK_API_KEY': {'configured': configured, 'writable': writable, 'source': 'file'},
          });
        case 'credentials/set':
          if (setError != null) return RpcError(DshRemoteException(setError!, setError!, const {}));
          configured = true;
          return const RpcOk(<String, Object?>{});
        case 'credentials/unset':
          configured = false;
          return const RpcOk(<String, Object?>{});
      }
    }
    if (endpoint == 'session/modelCatalog') {
      catalogReads++;
      return RpcOk({
        'groups': [
          if (configured)
            {
              'id': 'deepseek-official',
              'models': [
                {'provider': 'deepseek-official', 'model': 'deepseek-v4-pro', 'label': 'V4 Pro'},
              ],
            },
        ],
      });
    }
    return super.call(endpoint, args, timeout: timeout);
  }
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  const secret = 'sk-test-0123456789abcdef';

  Future<ProviderContainer> pump(WidgetTester tester, _KeyHost host) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const ProvidersPage(),
        overrides: [activeConnectionProvider.overrideWithValue(AsyncData(workspaceHost(host, local: false)))],
      ),
    );
    await pumpFrames(tester, 12);
    return ProviderScope.containerOf(tester.element(find.byType(ProvidersPage)));
  }

  List<Map<String, Object?>> sent(_KeyHost host, String endpoint) => host.argsOf(endpoint);

  testWidgets('saving sends credentials/set once with the ref, then the status is re-read', (tester) async {
    final host = _KeyHost();
    await pump(tester, host);
    final readsBefore = sent(host, 'credentials/describe').length;

    await tester.tap(find.text('DeepSeek'));
    await pumpFrames(tester, 12);
    final input = find.byKey(const ValueKey('secret-input'));
    expect(input, findsOneWidget);
    expect(tester.widget<TextField>(input).obscureText, isTrue);
    expect(tester.widget<TextField>(input).autocorrect, isFalse);

    await tester.enterText(input, secret);
    await tester.pump();
    await tester.tap(find.text('完成'));
    await pumpFrames(tester, 14);

    expect(sent(host, 'credentials/set'), [
      {'ref': 'DEEPSEEK_API_KEY', 'value': secret},
    ]);
    // The sheet closed and the host's key status was read again (the model
    // catalog is invalidated with it).
    expect(find.byKey(const ValueKey('secret-input')), findsNothing);
    expect(sent(host, 'credentials/describe').length, greaterThan(readsBefore));
  });

  testWidgets('a configured key can be cleared', (tester) async {
    final host = _KeyHost(configured: true);
    await pump(tester, host);
    await tester.tap(find.text('DeepSeek'));
    await pumpFrames(tester, 12);
    await tester.tap(find.text('移除'));
    await pumpFrames(tester, 14);
    expect(sent(host, 'credentials/unset'), [
      {'ref': 'DEEPSEEK_API_KEY'},
    ]);
    expect(sent(host, 'credentials/set'), isEmpty);
    expect(find.byKey(const ValueKey('secret-input')), findsNothing);
  });

  testWidgets('a rejected write shows the host\'s answer and keeps the sheet open', (tester) async {
    final host = _KeyHost(setError: 'credential/rejected');
    await pump(tester, host);
    await tester.tap(find.text('DeepSeek'));
    await pumpFrames(tester, 12);
    await tester.enterText(find.byKey(const ValueKey('secret-input')), secret);
    await tester.pump();
    await tester.tap(find.text('完成'));
    await pumpFrames(tester, 14);
    expect(find.byKey(const ValueKey('secret-input')), findsOneWidget);
    // describeSettingsError words credential/rejected (supplied by the launch environment).
    expect(find.textContaining('启动环境'), findsOneWidget);
    // Only the field holds the key; no label or message repeats it.
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(secret)), findsNothing);
  });

  testWidgets('a key supplied by the environment cannot be written', (tester) async {
    final host = _KeyHost(configured: true, writable: false);
    await pump(tester, host);
    await tester.tap(find.text('DeepSeek'));
    await pumpFrames(tester, 12);
    final input = find.byKey(const ValueKey('secret-input'));
    expect(tester.widget<TextField>(input).enabled, isFalse);
    expect(sent(host, 'credentials/set'), isEmpty);
  });

  testWidgets('a host without credentials/* keeps the row read-only', (tester) async {
    final host = _KeyHost(hasCredentials: false);
    await pump(tester, host);
    await tester.tap(find.text('DeepSeek'));
    await pumpFrames(tester, 12);
    expect(find.byKey(const ValueKey('secret-input')), findsNothing);
    expect(find.text('未在这台主机上配置'), findsOneWidget);
  });
}
