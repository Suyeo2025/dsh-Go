// A page over the chat pauses the chat's provider subscriptions (Riverpod's
// TickerMode pause). Coming back resumes them inside the build that
// re-enables TickerMode and flushes what changed meanwhile: chat seat plan →
// seat inventory → web boot graph → installed list. When the installed list
// rebuilds there with a new value, the bridge table (or the boot graph) must
// not invalidate itself in that flush: that rebuilds ProviderScope during the
// build ("setState() or markNeedsBuild() called during build"; 快捷入口 →
// 插件 → back, iOS simulator smoke run).

import 'dart:async';

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for what the installed list depends on (the plugin host, the
/// read-list identity).
final _source = NotifierProvider<_Source, int>(_Source.new);

class _Source extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Rebuilds to a new list at once (a cached list), so the new value lands
/// inside the flush that rebuilds it.
class _Installed extends InstalledPluginsController {
  @override
  Future<List<PluginBundle>?> build() {
    ref.watch(_source);
    return SynchronousFuture(<PluginBundle>[]);
  }
}

class _NoSettings extends EngineSettingsController {
  @override
  Future<EngineSettings?> build() async => null;
}

const _chatSeats = SeatRequest(slot: Slots.main, placement: SeatPlacement.page);

/// The chat page, as far as seats go: it holds the inventory as ChatScreen
/// does ([keepAlive]) and reads its seats and the islands' route guard.
class _Chat extends ConsumerStatefulWidget {
  const _Chat({required this.keepAlive});
  final bool keepAlive;

  @override
  ConsumerState<_Chat> createState() => _ChatState();
}

class _ChatState extends ConsumerState<_Chat> {
  ProviderSubscription<void>? _inventory;

  @override
  void initState() {
    super.initState();
    if (widget.keepAlive) _inventory = keepSeatInventory(context);
  }

  @override
  void dispose() {
    _inventory?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(seatPlanProvider(_chatSeats));
    ref.watch(seatRouteGuardReportProvider(ref.watch(activeHostProvider)));
    return const Text('chat');
  }
}

void main() {
  late GlobalKey<NavigatorState> navigator;

  Future<ProviderContainer> pumpChat(WidgetTester tester, {bool keepAlive = true}) async {
    // An HTTP carrier: the web boot graph and the bridge table are read and
    // follow the installed list. The test binding answers every request 400.
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
    addTearDown(client.close);
    navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData(HostConnection(client: client, label: '电脑', isLocal: false)),
          ),
          installedPluginsProvider.overrideWith(_Installed.new),
          engineSettingsProvider.overrideWith(_NoSettings.new),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: _Chat(keepAlive: keepAlive),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.text('chat')));
  }

  Future<void> cover(WidgetTester tester) async {
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('plugins'))));
    await tester.pumpAndSettle();
  }

  // With the chat's keep-alive, and without it (the boot graph and the bridge
  // table then must not watch the installed list themselves).
  for (final keepAlive in [true, false]) {
    testWidgets('the installed list changes under a covering page: back without a rebuild during build'
        '${keepAlive ? '' : ' (no keep-alive)'}', (tester) async {
      final container = await pumpChat(tester, keepAlive: keepAlive);
      await cover(tester);
      container.read(_source.notifier).bump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('chat'), findsOneWidget);
    });
  }

  testWidgets('the boot graph and the bridge table still follow the installed list', (tester) async {
    final container = await pumpChat(tester);
    var boot = 0, bridge = 0;
    container.listen(webBootProvider, (_, next) => next.isLoading ? boot++ : null);
    container.listen(bridgeInventoryProvider, (_, next) => next.isLoading ? bridge++ : null);

    container.read(_source.notifier).bump();
    await tester.pumpAndSettle();
    expect((boot, bridge), (1, 1), reason: 'a new list reads both again');

    // Changed while covered: read again on the way back.
    await cover(tester);
    container.read(_source.notifier).bump();
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((boot, bridge), (2, 2));
  });
}
