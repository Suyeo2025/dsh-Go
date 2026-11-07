// Opening a conversation from the Live Activity or a push tap
// (plan/design/sync-contract.md §2): the host decides. Archived: it opens
// (read-only) with a note; deleted: nothing opens, a note says so; either way
// its Activity is put away. A live one opens as before, its card in view.

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/live/live_activity_channel.dart' show liveActivityMethodChannel;
import 'package:dsh_app/live/live_activity_state.dart' show islandLinksProvider;
import 'package:dsh_app/live/session_open.dart';
import 'package:dsh_app/live/session_presence.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/bridge_client.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/push/push_tap_host.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/chat_focus.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push/bridge_client_test.dart' show FakeBridge;
import '../push/push_state_test.dart' show FakeNative;

const _host = HostRef.direct('direct-1');

void main() {
  final presence = <String, SessionPresence>{};

  setUp(() {
    presence.clear();
    SharedPreferences.setMockInitialValues({});
  });

  Future<ProviderContainer> pump(WidgetTester tester, {List<Override> more = const [], Widget? body}) async {
    final c = ProviderContainer(
      overrides: [sessionPresenceProvider.overrideWith((ref, id) => presence[id] ?? SessionPresence.unknown), ...more],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: Scaffold(body: body ?? const SizedBox())),
      ),
    );
    return c;
  }

  Future<(SessionPresence, List<String>)> open(WidgetTester tester, ProviderContainer c, String id) async {
    final retired = <String>[];
    final result = await openSessionChecked(
      read: c.read,
      context: () => tester.element(find.byType(Scaffold)),
      host: _host,
      sessionId: id,
      eventId: 'ev-1',
      retire: (s) async => retired.add(s),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return (result, retired);
  }

  testWidgets('live: opens, its card in view; nothing put away', (tester) async {
    presence['s1'] = SessionPresence.live;
    final c = await pump(tester);
    final (result, retired) = await open(tester, c, 's1');
    expect(result, SessionPresence.live);
    expect(c.read(activeHostProvider), _host);
    expect(c.read(currentSessionProvider), 's1');
    expect(c.read(chatFocusProvider)?.eventId, 'ev-1');
    expect(retired, isEmpty);
  });

  testWidgets('archived: opens with the note, its Activity goes', (tester) async {
    presence['s1'] = SessionPresence.archived;
    final c = await pump(tester);
    final (result, retired) = await open(tester, c, 's1');
    expect(result, SessionPresence.archived);
    expect(c.read(currentSessionProvider), 's1');
    expect(find.text(appL10n.sessionArchivedNotice), findsOneWidget);
    expect(c.read(chatFocusProvider), isNull, reason: 'no card to answer in an archived chat');
    expect(retired, ['s1']);
  });

  testWidgets('deleted: stays where it was, the note says so, its Activity goes', (tester) async {
    presence['s2'] = SessionPresence.gone;
    final c = await pump(tester);
    c.read(currentSessionProvider.notifier).select('s-here');
    final before = c.read(activeHostProvider);
    final (result, retired) = await open(tester, c, 's2');
    expect(result, SessionPresence.gone);
    expect(c.read(currentSessionProvider), 's-here');
    expect(c.read(activeHostProvider), before);
    expect(find.text(appL10n.sessionGoneNotice), findsOneWidget);
    expect(retired, ['s2']);
  });

  group('push tap', () {
    late FakeNative native;
    late FakeBridge bridge;
    final live = <MethodCall>[];

    // Event channels the island controller's host providers open (no native side here).
    const quiet = [MethodChannel('dev.fluttercommunity.plus/connectivity_status'), MethodChannel('dsh/runtime/events')];

    setUp(() {
      live.clear();
      for (final ch in quiet) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          ch,
          (_) async => null,
        );
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        liveActivityMethodChannel,
        (call) async {
          live.add(call);
          return switch (call.method) {
            'status' => {'supported': true, 'enabled': true},
            'list' => <Object?>[],
            'takePendingTokens' => {'activities': <Object?>[]},
            _ => null,
          };
        },
      );
      debugRemoteOnlyOverride = true;
      native = FakeNative();
      bridge = FakeBridge({'DELETE /v1/device/live-activity/s-gone': (204, null)});
      SharedPreferences.setMockInitialValues({
        PushController.prefsKey: jsonEncode({
          'bridge': 'https://watch.example.com',
          'hostId': 'direct-1',
          'deviceId': 'd-1',
        }),
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pushMethodChannel,
        native.handle,
      );
    });

    tearDown(() {
      debugRemoteOnlyOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pushMethodChannel,
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        liveActivityMethodChannel,
        null,
      );
      for (final ch in quiet) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
      }
    });

    testWidgets('a deleted conversation\'s push opens nothing and says so', (tester) async {
      presence['s-gone'] = SessionPresence.gone;
      final c = await pump(
        tester,
        body: const PushTapHost(),
        more: [
          secretStoreProvider.overrideWithValue(MemorySecretStore({PushController.deviceTokenKey: 'device-secret'})),
          bridgeClientFactoryProvider.overrideWithValue(
            (base, {pin}) => BridgeClient(base, pinSha256: pin, transport: bridge.send),
          ),
          islandLinksProvider.overrideWithValue((_) => () {}),
        ],
      );
      await tester.runAsync(() => c.read(pushProvider.notifier).ready);
      await tester.pump();
      c.read(currentSessionProvider.notifier).select('s-here');
      final channel = c.read(pushChannelProvider);
      await tester.runAsync(() async {
        await channel.handle(const MethodCall('onTap', {'v': 1, 'k': 'approval', 's': 's-gone', 'e': 'ev-9'}));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(currentSessionProvider), 's-here');
      expect(c.read(chatFocusProvider), isNull);
      expect(find.text(appL10n.sessionGoneNotice), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      expect(live.where((m) => m.method == 'end').map((m) => (m.arguments as Map)['sessionId']), ['s-gone']);
      expect(bridge.calls.map((x) => '${x.method} ${x.url.path}'), contains('DELETE /v1/device/live-activity/s-gone'));
    });
  });
}
