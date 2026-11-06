// Known third-party seats on a host without dsh-go-bridge (the official
// `dsh web` an iOS client connects to): dsh-im and dsh-better-sidebar draw
// no `plugins.bundle.config`, so the package-list guess for it is dropped,
// and their real pages (settings sections, the right pane's tabs) get seats.

import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/islands/island_recipes.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart' show inventoryDisplayTitle;
import 'package:dsh_app/ui/plugins/seats/plugin_web_places.dart';
import 'package:dsh_app/ui/plugins/seats/seat_island.dart' show seatIslandLabels;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _im = '@xmanrui/dsh-im';
const _sidebar = 'dsh-better-sidebar';
const _market = 'dshmarket';
const _other = 'novel-writer';

SeatInventory _inventory({
  ClientInventoryTier tier = ClientInventoryTier.boot,
  Map<String, List<SlotOccupant>>? occupancy,
  bool stale = false,
  Set<String> off = const {},
}) => SeatInventory(
  tier: tier,
  webReachable: true,
  occupancy: occupancy,
  occupancyStale: stale,
  packages: {
    for (final name in [_im, _sidebar, _market, _other])
      name: PluginClientInfo(
        package: name,
        hasClient: true,
        installed: true,
        enabled: !off.contains(name),
        rowIds: [name],
      ),
  },
);

const _seat = SeatContext(host: HostRef.local, placement: SeatPlacement.page);

List<SeatItem> _plan(SeatInventory inventory, String slot, {String? package, String? sessionId}) =>
    SlotAdapterRegistry.standard().plan(
      slot,
      inventory.occupantsFor(slot, package: package),
      SeatContext(host: const HostRef.direct('dsh-app'), placement: SeatPlacement.page, sessionId: sessionId),
      budget: const OpenIslandBudget(),
      overrides: SeatOverrides.none,
      inventory: inventory,
    );

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  group('occupants without an occupancy table', () {
    test('no bundle-config guess for plugins known to have no form there', () {
      final cells = _inventory().occupantsFor(Slots.bundleConfig).map((o) => o.package);
      expect(cells, unorderedEquals([_market, _other]));
    });

    test('settings sections of the known plugins, under their names', () {
      final sections = _inventory().occupantsFor(Slots.settingsSection);
      expect({for (final o in sections) o.package: (o.cell, o.label)}, {
        _im: ('xmanrui-dsh-im', 'IM机器人'),
        _sidebar: ('better-sidebar', '侧边卡片'),
        _market: ('market', '插件市场'),
      });
      expect(sections.every((o) => !o.inferred), isTrue);
    });

    test('names follow the App language', () {
      AppLocale.use(AppLocale.en);
      final sections = _inventory().occupantsFor(Slots.settingsSection, package: _im);
      expect(sections.single.label, 'IM bots');
    });

    test("better-sidebar's right pane tabs: Files, Git, Tasks, Side Chat", () {
      final tabs = _inventory().occupantsFor(Slots.rightPaneTab);
      expect(tabs.map((o) => o.cell), [
        'dsh-better-sidebar:files',
        'dsh-better-sidebar:git',
        'dsh-better-sidebar:subagent',
        'dsh-better-sidebar:sidechat',
      ]);
    });

    test('a switched-off plugin has no known seats', () {
      final inventory = _inventory(off: {_sidebar});
      expect(inventory.occupantsFor(Slots.rightPaneTab), isEmpty);
      expect(inventory.occupantsFor(Slots.settingsSection).map((o) => o.package), isNot(contains(_sidebar)));
    });

    test('a stale table still gets them; a fresh one is the only word', () {
      expect(_inventory(occupancy: const {}, stale: true).occupantsFor(Slots.rightPaneTab), hasLength(4));
      final fresh = _inventory(tier: ClientInventoryTier.bridge, occupancy: const {});
      expect(fresh.occupantsFor(Slots.rightPaneTab), isEmpty);
      expect(fresh.occupantsFor(Slots.settingsSection), isEmpty);
    });
  });

  group('plans', () {
    test('a settings section is a page island found by its names', () {
      final items = _plan(_inventory(), Slots.settingsSection, package: _im);
      expect(items.single.mode, SeatMode.island);
      final spec = items.single.island!;
      expect((spec.slot, spec.cell, spec.package), (Slots.settingsSection, 'xmanrui-dsh-im', _im));
      // DSH Web may not show the App's language: both names.
      expect(seatIslandLabels(items, null), ['IM机器人', 'IM bots']);
      final target = IslandRecipeBook.parse(File('assets/islands/recipes.json').readAsStringSync())
          .targetFor(spec, labels: seatIslandLabels(items, null));
      expect(target, {
        'web': {'settings': 'general'},
        'then': {
          'settings': ['IM机器人', 'IM bots'],
        },
      });
    });

    test('a right pane tab is a page island in a conversation, none without one', () {
      final items = _plan(_inventory(), Slots.rightPaneTab, sessionId: 's1');
      expect(items.map((i) => i.mode).toSet(), {SeatMode.island});
      expect(items.first.island!.sessionId, 's1');
      expect(seatIslandLabels([items[2]], null), ['任务管理', 'Tasks']);
      expect(_plan(_inventory(), Slots.rightPaneTab).map((i) => i.mode).toSet(), {SeatMode.webLink});
    });

    test('a known section stays the plugin page when the package also has a schema form', () {
      // iPhone sim: better-sidebar's namespaces arrived first, the schema
      // adapter took the seat, and its details lost 「侧边卡片」.
      SeatInventory withForm({Map<String, List<SlotOccupant>>? occupancy, ClientInventoryTier? tier}) => SeatInventory(
        tier: tier ?? ClientInventoryTier.boot,
        webReachable: true,
        occupancy: occupancy,
        packages: const {
          _sidebar: PluginClientInfo(
            package: _sidebar,
            hasClient: true,
            installed: true,
            enabled: true,
            rowIds: [_sidebar],
            configNamespaces: [_sidebar],
          ),
        },
      );
      final row = SlotAdapterRegistry.standard().plan(
        Slots.settingsSection,
        withForm().occupantsFor(Slots.settingsSection),
        const SeatContext(host: HostRef.direct('dsh-app'), placement: SeatPlacement.row),
        budget: const OpenIslandBudget(),
        overrides: SeatOverrides.none,
        inventory: withForm(),
      );
      expect(row.single.mode, SeatMode.webLink, reason: 'a row: the page behind it is the island');
      expect(_plan(withForm(), Slots.settingsSection).single.mode, SeatMode.island);
      // A host whose bridge reports it: the schema form, as before.
      final reported = withForm(
        tier: ClientInventoryTier.bridge,
        occupancy: {
          Slots.settingsSection: [
            const SlotOccupant(slot: Slots.settingsSection, package: _sidebar, cell: 'better-sidebar', label: '侧边卡片'),
          ],
        },
      );
      expect(_plan(reported, Slots.settingsSection).single.mode, SeatMode.native);
    });

    test('dsh-im has no config page seat any more', () {
      expect(_plan(_inventory(), Slots.bundleConfig, package: _im), isEmpty);
      expect(_plan(_inventory(), Slots.bundleConfig, package: _sidebar), isEmpty);
      expect(_plan(_inventory(), Slots.bundleConfig, package: _market).single.mode, SeatMode.island);
    });

    test('the official seat context is unchanged for unknown packages', () {
      // A plugin the app has no record of keeps the guess (the island's gate
      // decides).
      expect(_inventory().occupantsFor(Slots.bundleConfig, package: _other).single.inferred, isTrue);
      expect(_seat.webAvailable, isTrue);
    });
  });

  group('网页版界面', () {
    test('a known plugin lists its other places instead of "unknown"', () {
      // dsh-im's IM panel (`main`) and its sidebar entry, its Plugins-page
      // button, its avatars on the session rows.
      expect(pluginWebPlaces(_inventory(), _im), [WebPlace.sidebar, WebPlace.plugins, WebPlace.elsewhere]);
      expect(pluginWebPlaces(_inventory(), _sidebar), [WebPlace.header, WebPlace.overlay]);
      expect(pluginWebPlaces(_inventory(), _other), [WebPlace.unknown]);
    });
  });

  group('recipes', () {
    test('rc.5, and the bundle config card opens itself', () {
      final book = IslandRecipeBook.parse(File('assets/islands/recipes.json').readAsStringSync());
      expect(book.release, '0.2.1-rc.5');
      expect(book.recipeFor(Slots.bundleConfig)!.expand, isTrue);
      expect(book.recipeFor(Slots.settingsSection)!.expand, isFalse);
    });
  });

  group('inventory names', () {
    test('an entry named by its path shows its package', () {
      expect(inventoryDisplayTitle('file:///home/u/.dsh-browser/release/dsh-browser-x/lib/index.js'), 'dsh-browser-x');
      expect(inventoryDisplayTitle('/srv/plugins/node_modules/@scope/thing/dist/client.js'), '@scope/thing');
      expect(inventoryDisplayTitle('file:///opt/plugin.js'), 'opt');
      expect(inventoryDisplayTitle('插件管理服务'), '插件管理服务');
      expect(inventoryDisplayTitle('dsh-context'), 'dsh-context');
    });
  });
}
