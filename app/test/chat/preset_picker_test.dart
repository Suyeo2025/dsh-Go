// New conversation: choosing the Agent preset. `createSessionInWorkspace`
// forwards `agentPreset` on all three paths, `SessionsController.create()`
// takes the pick (one-shot), switching host clears it, and the empty state
// shows a chip only when the host offers two or more presets.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/new_chat_preset_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeRuntime, FakeSettings;
import '../workspace/support.dart';
import 'support/harness.dart';

/// A workspace host that also lists Agent presets.
class _PresetHost extends FakeWorkspaceHost {
  _PresetHost(this.presets);

  final List<Map<String, Object?>> presets;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'agentPresets/list') {
      calls.add((endpoint, args));
      return RpcOk({'presets': presets});
    }
    return super.call(endpoint, args, timeout: timeout);
  }
}

Map<String, Object?> _preset(String id, {String? name, bool isDefault = false, String? description, String? broken}) =>
    {'id': id, 'name': ?name, 'isDefault': isDefault, 'description': ?description, 'broken': ?broken};

final _twoPresets = [
  _preset('general', name: '通用', isDefault: true, description: '日常对话与编码'),
  _preset('reviewer', name: '代码审查', description: '只读审阅改动'),
  _preset('legacy', name: '旧版', broken: 'schema 错误'),
];

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    await loadTestFonts();
  });

  List<Map<String, Object?>> created(FakeWorkspaceHost host) => [
    for (final a in host.argsOf('session/create')) (a['request'] as Map).cast<String, Object?>(),
  ];

  group('createSessionInWorkspace', () {
    test('sends agentPreset on every path, and nothing when it is null', () async {
      final host = FakeWorkspaceHost();
      final client = DshClient.withCarrier(host);
      await createSessionInWorkspace(client, null, cwd: '/root/workspace', agentPreset: 'reviewer');
      await createSessionInWorkspace(client, null, cwd: '/root/workspace');
      await createSessionInWorkspace(client, 'ws-gone', cwd: '/root/workspace', agentPreset: 'reviewer');
      expect(created(host), [
        {'cwd': '/root/workspace', 'agentPreset': 'reviewer'},
        {'cwd': '/root/workspace'},
        // The workspace branch, then the fallback after it was removed.
        {'workspaceId': 'ws-gone', 'agentPreset': 'reviewer'},
        {'cwd': '/root/workspace', 'agentPreset': 'reviewer'},
      ]);
    });

    test('a registered workspace gets the preset too', () async {
      final host = FakeWorkspaceHost(folders: ['/root/a']);
      final ws = host.seedWorkspace('/root/a');
      final client = DshClient.withCarrier(host);
      await createSessionInWorkspace(client, ws['workspaceId'] as String, agentPreset: 'reviewer');
      expect(created(host).single, {'workspaceId': ws['workspaceId'], 'agentPreset': 'reviewer'});
    });
  });

  group('the pick', () {
    ProviderContainer containerFor(FakeWorkspaceHost host) {
      final container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(workspaceHost(host))),
          localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true))),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('SessionsController.create() sends it once, then the host default applies', () async {
      final host = FakeWorkspaceHost();
      final container = containerFor(host);
      final sub = container.listen(sessionsProvider, (_, _) {});
      addTearDown(sub.close);
      await _settle();
      container.read(newChatPresetProvider.notifier).select('reviewer');
      await container.read(sessionsProvider.notifier).create();
      expect(created(host).last['agentPreset'], 'reviewer');
      expect(container.read(newChatPresetProvider), isNull);
      await container.read(sessionsProvider.notifier).create();
      expect(created(host).last.containsKey('agentPreset'), isFalse);
    });

    test('switching host clears it', () async {
      final host = FakeWorkspaceHost();
      final container = containerFor(host);
      container.read(activeHostProvider);
      container.read(newChatPresetProvider.notifier).select('reviewer');
      expect(container.read(newChatPresetProvider), 'reviewer');
      container.read(activeHostProvider.notifier).select(const HostRef.direct('other'));
      expect(container.read(newChatPresetProvider), isNull);
    });

    test('take() returns the pick and clears it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(newChatPresetProvider.notifier);
      expect(controller.take(), isNull);
      controller.select('a');
      expect(controller.take(), 'a');
      expect(container.read(newChatPresetProvider), isNull);
    });
  });

  group('the empty state', () {
    Future<ProviderContainer> pump(WidgetTester tester, List<Map<String, Object?>> presets) async {
      usePhoneView(tester);
      final host = _PresetHost(presets);
      await tester.pumpWidget(
        testApp(
          const Scaffold(
            body: Center(child: ChatEmptyState(connected: true, onSuggestion: _noop)),
          ),
          overrides: [
            activeConnectionProvider.overrideWithValue(AsyncData(workspaceHost(host, local: false))),
            activeHostProvider.overrideWith(ActiveHostController.new),
          ],
        ),
      );
      await pumpFrames(tester, 10);
      return ProviderScope.containerOf(tester.element(find.byType(ChatEmptyState)));
    }

    testWidgets('two presets: a chip with the default one, picking changes its text', (tester) async {
      final container = await pump(tester, _twoPresets);
      final chip = find.byKey(const ValueKey('preset-chip'));
      expect(chip, findsOneWidget);
      expect(find.descendant(of: chip, matching: find.text('通用')), findsOneWidget);

      await tester.tap(chip);
      await pumpFrames(tester, 10);
      expect(find.text('Agent 预设'), findsOneWidget);
      expect(find.text('只读审阅改动'), findsOneWidget);
      // A preset that failed to load shows why and cannot be picked.
      expect(find.text('不可用 · schema 错误'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preset-legacy')), warnIfMissed: false);
      await pumpFrames(tester, 10);
      expect(container.read(newChatPresetProvider), isNull);

      await tester.tap(find.byKey(const ValueKey('preset-reviewer')));
      await pumpFrames(tester, 12);
      expect(container.read(newChatPresetProvider), 'reviewer');
      expect(find.descendant(of: find.byKey(const ValueKey('preset-chip')), matching: find.text('代码审查')), findsOneWidget);
    });

    testWidgets('one preset: no chip', (tester) async {
      await pump(tester, [_preset('general', name: '通用', isDefault: true)]);
      expect(find.byKey(const ValueKey('preset-chip')), findsNothing);
    });

    testWidgets('switching host drops the pick and the chip text returns to the default', (tester) async {
      final container = await pump(tester, _twoPresets);
      container.read(newChatPresetProvider.notifier).select('reviewer');
      await pumpFrames(tester, 4);
      expect(find.descendant(of: find.byKey(const ValueKey('preset-chip')), matching: find.text('代码审查')), findsOneWidget);
      container.read(activeHostProvider.notifier).select(const HostRef.direct('other'));
      await pumpFrames(tester, 4);
      expect(container.read(newChatPresetProvider), isNull);
      expect(find.descendant(of: find.byKey(const ValueKey('preset-chip')), matching: find.text('通用')), findsOneWidget);
    });
  });
}

void _noop(ChatSuggestion _) {}
