// A write the Host turns down (`settings/rejected`): the field says so in
// the app's words and shows the Host's own message under them, two lines,
// all of it on a tap — the message is what names the entry behind it (a
// plugin that failed to start in the profile reload every write runs:
// 「1 entry did not activate」). The next write of the field clears it.

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/field_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

FakeSettingsHost _host() => FakeSettingsHost(
  describe: {
    'namespaces': [
      {
        'ns': 'probe',
        'autoGenerate': true,
        'schema': {
          'type': 'object',
          'dict': {
            'enabled': {
              'type': 'boolean',
              'meta': {'default': false, 'description': 'Enabled'},
            },
          },
        },
        'base': {'enabled': false},
        'value': {'enabled': false},
        'revision': 0,
      },
    ],
  },
);

const _reload =
    'dsh: warning: 1 entry did not activate\n'
    'mcp-browsersrv-lifecycle-gray (file:///home/u/.dsh-browser/releases/gray/runtime/gray-plugin.mjs): '
    'Managed MCP browsersrv_lifecycle startup failed: STATE_LOCKED_OR_UNKNOWN';

void main() {
  test('the detail: blank lines dropped, long text cut', () {
    expect(hostRejectionDetail('a\n\n  \nb  '), 'a\nb');
    expect(hostRejectionDetail('  \n '), isNull);
    expect(hostRejectionDetail('x' * 30, maxLength: 10), '${'x' * 10}…');
  });

  testWidgets("a refused write shows the Host's words, folded to two lines; the next write clears them", (
    tester,
  ) async {
    final host = _host()..beforeMutate = (_) => throw const DshRemoteException('settings/rejected', _reload);
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'probe'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    await tester.tap(find.byType(Switch).first);
    await flush(tester);
    // The app's words name the entry; the Host's follow.
    expect(find.textContaining('mcp-browsersrv-lifecycle-gray 没能启动'), findsOneWidget);
    final detail = find.byType(HostDetail);
    expect(detail, findsOneWidget);
    expect(tester.widget<HostDetail>(detail).text, _reload);
    Text shown() => tester.widget<Text>(find.descendant(of: detail, matching: find.byType(Text)));
    expect(shown().maxLines, HostDetail.collapsedLines);
    await tester.tap(detail);
    await tester.pump();
    expect(shown().maxLines, isNull);

    host.beforeMutate = null;
    await tester.tap(find.byType(Switch).first);
    await flush(tester);
    expect(find.byType(HostDetail), findsNothing);
    expect(find.textContaining('没能启动'), findsNothing);
  });

  testWidgets('failures other than a refusal (the gateway) carry no Host words', (tester) async {
    final host = _host()
      ..beforeMutate = (_) => throw const DshRemoteException('gateway/unavailable', 'the gateway is down');
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'probe'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    await tester.tap(find.byType(Switch).first);
    await flush(tester);
    expect(find.byType(HostDetail), findsNothing);
  });
}
