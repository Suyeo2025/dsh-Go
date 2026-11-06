// Where some third-party plugins draw in DSH Web, read from their published
// sources, for hosts that can't say it themselves (no dsh-go-bridge, so no
// occupancy table: the official `dsh web` a remote-only client connects to).
//
// Without this the seats only know what a package list can guess
// (`plugins.bundle.config`, which a plugin may not register at all) and a
// plugin's real pages never get a seat. Every entry was checked against the
// version named in [KnownPluginSeats.checked]; the island's ready gate still
// confirms each one on the host, and a miss falls back to DSH Web as for any
// other occupant. Only entries an island reaches on the official client are
// listed (a settings section by its nav name, a right-pane tab by its guide
// entry); the rest of a plugin's web part is in [KnownPluginSeats.elsewhere].

import 'package:flutter/foundation.dart';

import 'slot_catalog.dart';

/// One known entry of a package in a slot.
@immutable
class KnownSeat {
  const KnownSeat(this.slot, this.cell, this.labels, {this.order = 0});

  final String slot;

  /// The list id or keyed key the plugin registers under.
  final String cell;

  /// Its name on screen, Chinese first, then English: island.js finds the
  /// entry by any of them (DSH Web may not show the App's language).
  final List<String> labels;
  final int order;

  /// The name in the App's language.
  String label({required bool english}) => english && labels.length > 1 ? labels[1] : labels.first;
}

/// What is known of one package.
@immutable
class KnownPluginSeats {
  const KnownPluginSeats({
    required this.checked,
    this.seats = const [],
    this.bundleConfig = true,
    this.elsewhere = const [],
  });

  /// The package version the entries were read from.
  final String checked;
  final List<KnownSeat> seats;

  /// It registers `plugins.bundle.config` (a form on its Plugins page): when
  /// false the package-list guess for that slot is dropped, so no seat waits
  /// for a slot DSH Web never draws.
  final bool bundleConfig;

  /// Other slots it draws in, where the app has no seat for it on such a
  /// host (its details' 「网页版界面」).
  final List<String> elsewhere;
}

/// Checked against DSH 0.2.1-rc.5.
const Map<String, KnownPluginSeats> knownPluginSeats = {
  // lib/client.js: settings.section `xmanrui-dsh-im` (t("IM机器人")); its
  // `main` panel is only listed in the sidebar when the person turns that
  // on, so it is not a seat here.
  '@xmanrui/dsh-im': KnownPluginSeats(
    checked: '5.9.1',
    bundleConfig: false,
    seats: [
      KnownSeat(Slots.settingsSection, 'xmanrui-dsh-im', ['IM机器人', 'IM bots'], order: 21),
    ],
    elsewhere: [Slots.main, Slots.panelList, 'plugins.detail.actions', 'sidebar.session.row.leading'],
  ),
  // lib/client.js: settings.section `better-sidebar` (t("settingsNav")); the
  // right pane's tab types `dsh-better-sidebar:<descriptor>` with guide
  // entries named by the descriptor's title (`files` takes over the
  // built-in Files kind).
  'dsh-better-sidebar': KnownPluginSeats(
    checked: '0.28.2',
    bundleConfig: false,
    seats: [
      KnownSeat(Slots.settingsSection, 'better-sidebar', ['侧边卡片', 'Side card'], order: 100),
      KnownSeat(Slots.rightPaneTab, 'dsh-better-sidebar:files', ['文件', 'Files'], order: 10),
      KnownSeat(Slots.rightPaneTab, 'dsh-better-sidebar:git', ['Git'], order: 20),
      KnownSeat(Slots.rightPaneTab, 'dsh-better-sidebar:subagent', ['任务管理', 'Tasks'], order: 30),
      KnownSeat(Slots.rightPaneTab, 'dsh-better-sidebar:sidechat', ['侧边对话(beta)', 'Side Chat (beta)'], order: 35),
    ],
    elsewhere: [Slots.headerUtilities, Slots.shellOverlay],
  ),
  // client/client.js: settings.section `market` (t("nav")) is the whole
  // market; its `plugins.bundle.config` card is the version and channel.
  'dshmarket': KnownPluginSeats(
    checked: '1.70.2',
    seats: [
      KnownSeat(Slots.settingsSection, 'market', ['插件市场', 'Plugin Market'], order: 40),
    ],
    elsewhere: ['plugins.tab', 'settings.plugins.tab', Slots.panelList, Slots.shellOverlay],
  ),
};

/// The known entry of [package] at [slot] / [cell], if any.
KnownSeat? knownSeat(String package, String slot, String cell) {
  for (final seat in knownPluginSeats[package]?.seats ?? const <KnownSeat>[]) {
    if (seat.slot == slot && seat.cell == cell) return seat;
  }
  return null;
}
