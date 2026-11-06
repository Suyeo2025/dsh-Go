// Opening a conversation for one request (a push tap, the Live Activity's
// `dshgo://session/<id>#event=<id>`): the card of that event id scrolls into
// view and lights up once; a card that never shows (answered already) leaves
// nothing behind.

import 'dart:convert';

import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/push/push_channel.dart';
import 'package:dsh_app/push/push_state.dart';
import 'package:dsh_app/push/push_tap_host.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/chat_focus.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_focus_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push/push_state_test.dart' show FakeNative;

final _t0 = DateTime.utc(2026, 11, 6, 9);

/// A tall list with the card of `ev-1` far below the fold.
class _List extends StatelessWidget {
  const _List({required this.withCard});
  final bool withCard;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      children: [
        for (var i = 0; i < 30; i++) SizedBox(height: 80, child: Text('row $i')),
        if (withCard)
          const ChatFocusTarget(
            eventId: 'ev-1',
            child: SizedBox(key: ValueKey('card'), height: 120, child: Text('card')),
          ),
        const SizedBox(height: 40),
      ],
    ),
  );
}

void main() {
  group('linkFocusEventId', () {
    test('reads #event=<id>', () {
      expect(linkFocusEventId(Uri.parse('dshgo://session/s1#event=ev_01J.x')), 'ev_01J.x');
      expect(linkFocusEventId(Uri.parse('dshgo://session/s1')), isNull);
      expect(linkFocusEventId(Uri.parse('dshgo://session/s1#other=1')), isNull);
      expect(linkFocusEventId(Uri.parse('dshgo://session/s1#event=bad%20id')), isNull);
      expect(linkFocusEventId(Uri.parse('dshgo://session/s1#event=')), isNull);
    });
  });

  group('ChatFocusTarget', () {
    var now = _t0;
    late ProviderContainer container;

    Future<void> pump(WidgetTester tester, {required bool withCard}) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: _List(withCard: withCard)),
          ),
        ),
      );
      await tester.pump();
    }

    setUp(() {
      now = _t0;
      container = ProviderContainer(overrides: [chatFocusClockProvider.overrideWithValue(() => now)]);
    });
    tearDown(() => container.dispose());

    Color border(WidgetTester tester) {
      final box = tester.widget<AnimatedContainer>(find.byKey(const ValueKey('chat-focus-ev-1')));
      return ((box.foregroundDecoration! as BoxDecoration).border! as Border).top.color;
    }

    bool onScreen(WidgetTester tester) {
      final rect = tester.getRect(find.byKey(const ValueKey('card')));
      final screen = tester.getRect(find.byType(Scaffold));
      return rect.top >= screen.top && rect.bottom <= screen.bottom;
    }

    testWidgets('scrolls the card into view and lights it up once', (tester) async {
      await pump(tester, withCard: true);
      expect(onScreen(tester), isFalse);
      expect(border(tester).a, 0);

      container.read(chatFocusProvider.notifier).focus('s1', 'ev-1');
      await tester.pumpAndSettle();
      expect(onScreen(tester), isTrue);
      expect(border(tester).a, greaterThan(0));
      expect(container.read(chatFocusProvider), isNull, reason: 'taken');

      await tester.pump(ChatFocusTarget.lit);
      await tester.pumpAndSettle();
      expect(border(tester).a, 0, reason: 'nothing keeps running');
    });

    testWidgets('asked before the card exists: taken once it is built', (tester) async {
      await pump(tester, withCard: false);
      container.read(chatFocusProvider.notifier).focus('s1', 'ev-1');
      await tester.pump();
      expect(container.read(chatFocusProvider), isNotNull);

      await pump(tester, withCard: true);
      await tester.pumpAndSettle();
      expect(onScreen(tester), isTrue);
      expect(container.read(chatFocusProvider), isNull);
      await tester.pump(ChatFocusTarget.lit);
      await tester.pumpAndSettle();
    });

    testWidgets('another card, or a request that lapsed, is left alone', (tester) async {
      await pump(tester, withCard: true);
      container.read(chatFocusProvider.notifier).focus('s1', 'ev-2');
      await tester.pumpAndSettle();
      expect(onScreen(tester), isFalse);
      expect(container.read(chatFocusProvider)?.eventId, 'ev-2');

      now = _t0.add(chatFocusWindow + const Duration(seconds: 1));
      container.read(chatFocusProvider.notifier).focus('s1', 'ev-1');
      now = now.add(chatFocusWindow + const Duration(seconds: 1));
      await pump(tester, withCard: false);
      await pump(tester, withCard: true);
      await tester.pumpAndSettle();
      expect(onScreen(tester), isFalse);
      expect(border(tester).a, 0);
    });
  });

  group('push tap', () {
    late FakeNative native;

    setUp(() {
      debugRemoteOnlyOverride = true;
      native = FakeNative();
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
    });

    testWidgets('an approval push asks for its card; a done push does not', (tester) async {
      final container = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore({PushController.deviceTokenKey: 'device-secret'})),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: PushTapHost())),
        ),
      );
      await tester.runAsync(() => container.read(pushProvider.notifier).ready);
      await tester.pump();
      final channel = container.read(pushChannelProvider);

      Future<void> tap(Map<String, Object?> dg) async {
        await tester.runAsync(() async {
          await channel.handle(MethodCall('onTap', dg));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
      }

      await tap({'v': 1, 'k': 'approval', 's': 'sess-9', 'e': 'ev-7'});
      expect(container.read(activeHostProvider), const HostRef.direct('direct-1'));
      expect(container.read(currentSessionProvider), 'sess-9');
      final focus = container.read(chatFocusProvider)!;
      expect((focus.sessionId, focus.eventId), ('sess-9', 'ev-7'));

      container.read(chatFocusProvider.notifier).consume(focus.serial);
      await tap({'v': 1, 'k': 'done', 's': 'sess-8', 'e': 'ev-8'});
      expect(container.read(currentSessionProvider), 'sess-8');
      expect(container.read(chatFocusProvider), isNull);
    });
  });
}
