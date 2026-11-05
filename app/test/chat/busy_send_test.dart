// A plain send while a turn runs follows the host's `ui-conversation.busyEnter`
// (queue / steer), unless the app overrides it; a host with no such value
// keeps the interjection.

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/state/busy_send_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../performance/support.dart' show FakePerformanceChannel, snapshot;
import 'support/harness.dart';

/// Records the mode of each prompt; replays a scripted event stream.
class _PromptClient extends DshClient {
  _PromptClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final modes = <PromptMode>[];
  var cancels = 0;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    modes.add(mode);
    return requestId ?? 'r';
  }

  @override
  Future<void> cancel(String sessionId) async => cancels++;
}

/// The host's settings, fixed.
class _FixedEngine extends EngineSettingsController {
  _FixedEngine(this.busyEnter);
  final Object? busyEnter;

  @override
  Future<EngineSettings?> build() async => EngineSettings(
    namespaces: {
      if (busyEnter != null)
        'ui-conversation': SettingsNamespaceView.fromJson({
          'ns': 'ui-conversation',
          'schema': {'type': 'object'},
          'value': {'busyEnter': busyEnter},
          'revision': 1,
        }),
    },
  );
}

void main() {
  group('busySendDefaultProvider', () {
    for (final (override, host, want) in [
      (BusySendOverride.followHost, 'queue', SendMode.queue),
      (BusySendOverride.followHost, 'steer', SendMode.steer),
      (BusySendOverride.followHost, null, SendMode.steer),
      (BusySendOverride.steer, 'queue', SendMode.steer),
      (BusySendOverride.steer, 'steer', SendMode.steer),
      (BusySendOverride.steer, null, SendMode.steer),
      (BusySendOverride.queue, 'queue', SendMode.queue),
      (BusySendOverride.queue, 'steer', SendMode.queue),
      (BusySendOverride.queue, null, SendMode.queue),
    ]) {
      test('${override.name} × host $host → ${want.name}', () {
        final container = ProviderContainer(
          overrides: [
            busySendOverrideProvider.overrideWithValue(override),
            hostBusyEnterProvider.overrideWithValue(host),
          ],
        );
        addTearDown(container.dispose);
        expect(container.read(busySendDefaultProvider), want);
      });
    }
  });

  group('hostBusyEnterProvider', () {
    for (final (value, want) in [
      ('queue', 'queue'),
      ('steer', 'steer'),
      ('enter', null),
      (3, null),
      (null, null),
    ]) {
      test('host keeps $value → $want', () async {
        final container = ProviderContainer(
          overrides: [engineSettingsProvider.overrideWith(() => _FixedEngine(value))],
        );
        addTearDown(container.dispose);
        container.listen(hostBusyEnterProvider, (_, _) {});
        await container.read(engineSettingsProvider.future);
        expect(container.read(hostBusyEnterProvider), want);
      });
    }

    test('not read yet: null (steers)', () {
      final container = ProviderContainer(
        overrides: [
          engineSettingsProvider.overrideWith(() => _FixedEngine('queue')),
          busySendOverrideProvider.overrideWithValue(BusySendOverride.followHost),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(hostBusyEnterProvider), isNull);
      expect(container.read(busySendDefaultProvider), SendMode.steer);
    });
  });

  group('the override persists', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<ProviderContainer> start() async {
      final channel = FakePerformanceChannel(Future.value(snapshot(DeviceTier.high)));
      final container = ProviderContainer(overrides: [performanceChannelProvider.overrideWithValue(channel)]);
      addTearDown(() async {
        container.dispose();
        await channel.events.close();
      });
      container.read(settingsProvider);
      for (var i = 0; i < 40 && !container.read(settingsProvider).loaded; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(settingsProvider).loaded, isTrue);
      return container;
    }

    test('defaults to following the host, saves by name, reloads', () async {
      var container = await start();
      expect(container.read(busySendOverrideProvider), BusySendOverride.followHost);
      await container.read(settingsProvider.notifier).setBusySendOverride(BusySendOverride.queue);
      expect(container.read(busySendOverrideProvider), BusySendOverride.queue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('busy_send_override'), 'queue');
      container = await start();
      expect(container.read(busySendOverrideProvider), BusySendOverride.queue);
    });

    test('an unknown stored value follows the host', () async {
      SharedPreferences.setMockInitialValues({'busy_send_override': 'sometimes'});
      final container = await start();
      expect(container.read(busySendOverrideProvider), BusySendOverride.followHost);
    });
  });

  group('ChatController.send', () {
    late _PromptClient client;
    late ProviderContainer container;
    var busyDefault = SendMode.steer;

    ChatController chat() => container.read(chatProvider('s1').notifier);
    ChatState state() => container.read(chatProvider('s1'));

    Future<void> start({required bool running, bool onScreen = true}) async {
      client = _PromptClient();
      container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
          ),
          busySendDefaultProvider.overrideWith((ref) => busyDefault),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await client.events.close();
      });
      container.listen(chatProvider('s1'), (_, _) {});
      // The composer keeps it alive on screen.
      if (onScreen) container.listen(busySendDefaultProvider, (_, _) {});
      client.events.add(
        SessionSnapshotEvent.fromJson('s1', {
          'header': {'id': 's1'},
          'cursor': -1,
          'records': <Object?>[],
          'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
        }),
      );
      await container.pump();
      expect(state().controlReady, isTrue);
      if (running) {
        client.events.add(const SessionStatusEvent('s1', true));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(state().running, isTrue);
      }
    }

    test('running, default queue: a plain send queues', () async {
      busyDefault = SendMode.queue;
      await start(running: true);
      expect(await chat().send('之后再说'), isTrue);
      expect(client.modes, [PromptMode.queue]);
      expect(state().pending.single.mode, SendMode.queue);
      expect(state().pending.single.queued, isTrue);
    });

    test('running, default steer: a plain send steers', () async {
      busyDefault = SendMode.steer;
      await start(running: true);
      expect(await chat().send('用 pnpm'), isTrue);
      expect(client.modes, [PromptMode.steer]);
      expect(state().pending.single.mode, SendMode.steer);
    });

    for (final dflt in [SendMode.steer, SendMode.queue]) {
      test('running, default ${dflt.name}: an explicit mode is kept', () async {
        busyDefault = dflt;
        await start(running: true);
        await chat().send('插一句', mode: SendMode.steer);
        await chat().send('等等再说', mode: SendMode.queue);
        expect(client.modes, [PromptMode.steer, PromptMode.queue]);
        await chat().send('停一下', mode: SendMode.interrupt);
        expect(client.cancels, 1);
        expect(client.modes.last, PromptMode.queue);
      });
    }

    test('nothing on screen asks: a plain send steers, as before', () async {
      busyDefault = SendMode.queue;
      await start(running: true, onScreen: false);
      expect(await chat().send('用 pnpm'), isTrue);
      expect(client.modes, [PromptMode.steer]);
    });

    test('idle: every mode just starts a turn', () async {
      busyDefault = SendMode.steer;
      await start(running: false);
      for (final mode in SendMode.values) {
        await chat().send('你好 ${mode.name}', mode: mode);
      }
      expect(client.modes, List.filled(SendMode.values.length, PromptMode.queue));
      expect(client.cancels, 0);
    });
  });

  group('Composer while generating', () {
    Future<void> pump(WidgetTester tester, SendMode busyDefault) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Composer(
              controller: input,
              connected: true,
              running: true,
              busyDefault: busyDefault,
              onSend: () {},
              onStop: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('queue says so', (tester) async {
      await pump(tester, SendMode.queue);
      expect(find.text(appL10n.busySendGeneratingQueueHint), findsOneWidget);
      expect(find.text(appL10n.chatGeneratingSteerHint), findsNothing);
    });

    testWidgets('steer keeps the interjection hint', (tester) async {
      await pump(tester, SendMode.steer);
      expect(find.text(appL10n.chatGeneratingSteerHint), findsOneWidget);
      expect(find.text(appL10n.busySendGeneratingQueueHint), findsNothing);
    });
  });

  group('chat screen', () {
    Future<ChatHarness> pumpScreen(WidgetTester tester, {required String? host, AppSettings? settings}) async {
      final harness = ChatHarness(
        session: 's1',
        states: {'s1': const ChatState(loading: false, running: true)},
        settings: settings ?? const AppSettings(loaded: true, apiKey: testKey),
        extra: [hostBusyEnterProvider.overrideWithValue(host)],
      );
      usePhoneView(tester);
      mockClipboard(tester);
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
      await pumpFrames(tester);
      return harness;
    }

    List<String> sheetOrder(WidgetTester tester) {
      final keys = [
        for (final mode in [SendMode.steer, SendMode.interrupt, SendMode.queue])
          (mode, tester.getTopLeft(find.byKey(ValueKey('send-mode-${mode.name}'))).dy),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      return [for (final k in keys) k.$1.name];
    }

    testWidgets('host queues: the hint says so; the menu leads with 排队, marked', (tester) async {
      final harness = await pumpScreen(tester, host: 'queue');
      expect(find.text('生成中 · 发送将排队，长按发送键可改'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '等你忙完');
      await pumpFrames(tester, 2);
      await tester.longPress(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(sheetOrder(tester), ['queue', 'steer', 'interrupt']);
      expect(find.text('本轮结束后发送 · 默认'), findsOneWidget);
      expect(find.text('不打断，AI 下一步会看到'), findsOneWidget);

      // 插话 is still a choice.
      await tester.tap(find.text('插话'));
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sentModes, [SendMode.steer]);
    });

    testWidgets('no host value: steering as before, 插话 first and marked', (tester) async {
      await pumpScreen(tester, host: null);
      expect(find.text('生成中 · 可直接插话'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '用 pnpm');
      await pumpFrames(tester, 2);
      await tester.longPress(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(sheetOrder(tester), ['steer', 'interrupt', 'queue']);
      expect(find.text('不打断，AI 下一步会看到 · 默认'), findsOneWidget);
    });

    testWidgets('the app override wins over the host', (tester) async {
      await pumpScreen(
        tester,
        host: 'queue',
        settings: const AppSettings(loaded: true, apiKey: testKey, busySendOverride: BusySendOverride.steer),
      );
      expect(find.text('生成中 · 可直接插话'), findsOneWidget);
    });
  });
}
