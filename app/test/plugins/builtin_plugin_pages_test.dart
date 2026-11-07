// 插件 › 已安装 › 内置插件: DSH Web's built-in plugin pages (子智能体, 网页搜索,
// Agent 循环, 终端 — `plugins.item` on its Plugins page) listed in the app
// under DSH Web's names, each opening the app's own settings page; settings
// search finds 子智能体 at both; a settings write the host turns down because
// a plugin failed to start in the reload names that plugin.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/plugins/builtin_plugin_pages.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SettingsNamespaceView _ns(String ns) => SettingsNamespaceView.fromJson({
  'ns': ns,
  'autoGenerate': true,
  'schema': {
    'type': 'object',
    'dict': {
      'x': {'type': 'number'},
    },
  },
  'value': {'x': 1},
  'revision': 0,
});

EngineSettings _settings(List<String> namespaces) => EngineSettings(namespaces: {for (final ns in namespaces) ns: _ns(ns)});

class _Fixed extends EngineSettingsController {
  _Fixed(this.settings);
  final EngineSettings? settings;

  @override
  Future<EngineSettings?> build() async => settings;
}

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  group('served pages', () {
    test("DSH Web's order, each opened by the first namespace the host serves", () {
      final served = servedBuiltInPages(
        _settings(['agent-loop', 'web-deepseek-api', 'subagent-model-selection-settings', 'pwsh-sandbox', 'meow-memory']),
      );
      expect([for (final (p, ns) in served) (p.id, ns)], [
        ('subagent', 'subagent-model-selection-settings'),
        ('web-search', 'web-deepseek-api'),
        ('agent-loop', 'agent-loop'),
        ('shell', 'pwsh-sandbox'),
      ]);
    });

    test('none while the settings are unknown or the host serves none of them', () {
      expect(servedBuiltInPages(null), isEmpty);
      expect(servedBuiltInPages(_settings(['meow-memory'])), isEmpty);
    });
  });

  testWidgets("the card: DSH Web's names, the app's place for each under it", (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [engineSettingsProvider.overrideWith(() => _Fixed(_settings(['subagent', 'bash-sandbox'])))],
        child: MaterialApp(theme: buildLightTheme(), home: const Scaffold(body: SingleChildScrollView(child: BuiltInPluginsCard()))),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('内置插件'), findsOneWidget);
    final subagent = tester.widget<ListPageRow>(find.byKey(const ValueKey('builtin-plugin|subagent')));
    expect(subagent.title, '子智能体');
    expect(subagent.subtitle, SettingsIndex.trail(SettingsIndex.entry(SettingsPageId.subagent), appL10n).skip(1).join(' › '));
    expect(subagent.subtitle, endsWith('子代理'));
    expect(tester.widget<ListPageRow>(find.byKey(const ValueKey('builtin-plugin|shell'))).title, '终端');
    expect(find.byKey(const ValueKey('builtin-plugin|web-search')), findsNothing);
  });

  testWidgets('no card without any of them', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [engineSettingsProvider.overrideWith(() => _Fixed(_settings(['meow-memory'])))],
        child: MaterialApp(theme: buildLightTheme(), home: const Scaffold(body: BuiltInPluginsCard())),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('builtin-plugins')), findsNothing);
  });

  test("search: 子智能体 finds the app's 子代理 page and 插件 › 内置插件", () {
    final zh = lookupL10n(AppLocale.zhCN);
    final en = lookupL10n(AppLocale.en);
    for (final q in ['子智能体', 'Subagent']) {
      final hits = searchSettings(q, spots: SettingsIndex.spots, features: const [], zh: zh, en: en);
      final ids = [for (final h in hits) ?h.spot?.id];
      expect(ids, contains(SettingsIndex.entry(SettingsPageId.subagent).id), reason: q);
      if (q == '子智能体') expect(ids, contains(Spots.pluginsBuiltIn.id));
    }
  });

  group('a write turned down by the reload', () {
    test('names the plugin that did not start', () {
      const error = DshRemoteException(
        'settings/rejected',
        'dsh: warning: 1 entry did not activate\n'
            'mcp-browsersrv-lifecycle-gray (file:///x/gray-plugin.mjs): Managed MCP browsersrv_lifecycle startup failed',
      );
      final text = describeSettingsError(error);
      expect(text, contains('mcp-browsersrv-lifecycle-gray'));
      expect(text, contains('没有生效'));
    });

    test('other refusals keep their wording', () {
      expect(
        describeSettingsError(const DshRemoteException('settings/rejected', 'something else')),
        appL10n.stateSettingsRejected,
      );
    });
  });
}
