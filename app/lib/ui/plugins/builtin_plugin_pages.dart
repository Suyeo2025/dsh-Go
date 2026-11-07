// 插件 › 已安装 › 内置插件: the settings pages DSH Web lists on its Plugins
// page as plugins of their own (`plugins.item`, DSH 0.2.1-rc.5 / 0.2.2:
// 子智能体 10, 网页搜索 20, Agent 循环 30, 终端 40). The app has native pages
// for all four under 设置; this card lists them where DSH Web does, under
// DSH Web's names, each opening the app's own page. A page shows only while
// the host serves one of its namespaces, as DSH Web registers it
// (`configForms.whileServed`).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../common/list_page_row.dart';
import '../engine_settings/engine_settings_page.dart' show openSettingsPage;
import '../settings/index/spots.dart';
import '../theme/app_icons.dart';

/// One built-in plugin page of DSH Web's Plugins page.
@immutable
class BuiltInPluginPage {
  const BuiltInPluginPage({
    required this.id,
    required this.namespaces,
    required this.title,
    required this.page,
    required this.icon,
  });

  /// Its `plugins.item` id in DSH Web.
  final String id;

  /// The namespaces it edits; the first one served opens the app's page.
  final List<String> namespaces;

  /// DSH Web's name for it.
  final String Function(L10n l) title;

  /// Where the app keeps the same settings.
  final SettingsPageId page;
  final IconData icon;
}

/// In DSH Web's order.
final builtInPluginPages = <BuiltInPluginPage>[
  BuiltInPluginPage(
    id: 'subagent',
    namespaces: const ['subagent', 'subagent-model-selection-settings'],
    title: (l) => l.plugUiBuiltInSubagent,
    page: SettingsPageId.subagent,
    icon: AppIcons.subagents,
  ),
  BuiltInPluginPage(
    id: 'web-search',
    namespaces: const ['web', 'web-deepseek-api', 'web-search-deepseek'],
    title: (l) => l.plugUiBuiltInWebSearch,
    page: SettingsPageId.webSearch,
    icon: AppIcons.webApp,
  ),
  BuiltInPluginPage(
    id: 'agent-loop',
    namespaces: const ['agent-loop'],
    title: (l) => l.plugUiBuiltInAgentLoop,
    page: SettingsPageId.agentLoop,
    icon: AppIcons.configure,
  ),
  BuiltInPluginPage(
    id: 'shell',
    namespaces: const ['bash-sandbox', 'pwsh-sandbox'],
    title: (l) => l.plugUiBuiltInShell,
    page: SettingsPageId.shell,
    icon: AppIcons.configure,
  ),
];

/// The pages [settings] serves, each with the namespace that opens it.
List<(BuiltInPluginPage, String)> servedBuiltInPages(EngineSettings? settings) => [
  if (settings != null)
    for (final page in builtInPluginPages)
      if (page.namespaces.where(settings.served).firstOrNull case final ns?) (page, ns),
];

/// The card; nothing while the host's settings are unknown or serve none.
class BuiltInPluginsCard extends ConsumerWidget {
  const BuiltInPluginsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final served = servedBuiltInPages(ref.watch(engineSettingsProvider.select((s) => s.value)));
    if (served.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ListPageCard(
      key: const ValueKey('builtin-plugins'),
      title: l10n.plugUiBuiltInTitle,
      children: [
        for (final (page, ns) in served)
          ListPageRow(
            key: ValueKey('builtin-plugin|${page.id}'),
            icon: page.icon,
            title: page.title(l10n),
            // The app's own place for it: 引擎设置 › 子代理.
            subtitle: SettingsIndex.trail(SettingsIndex.entry(page.page), l10n).skip(1).join(' › '),
            chevron: true,
            onTap: () => unawaited(openSettingsPage(context, ns)),
          ),
      ],
    );
  }
}
