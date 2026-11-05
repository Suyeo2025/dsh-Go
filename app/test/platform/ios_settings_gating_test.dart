// The iOS (remote-only) settings: 账号 is the on-device engine's and is gone
// from search and links, the web app opens the active host's own page, the
// hub says when a host lacks web search / the media plugin, and the quick
// panel starts with the entries an iPhone can use. Android is unchanged.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/remote/direct/direct_link.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_destination.dart';
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:dsh_app/ui/web/local_web_screen.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

void _asIos() {
  debugRemoteOnlyOverride = true;
  debugAndroidNativeOverride = false;
  addTearDown(() {
    debugRemoteOnlyOverride = null;
    debugAndroidNativeOverride = null;
  });
}

List<String> _ids(String q) => [
  for (final h in searchSettings(
    q,
    spots: SettingsIndex.spots.where(SettingsIndex.has),
    features: featureSections,
    zh: _zh,
    en: _en,
  ))
    h.spot?.id ?? 'feature:${h.feature!.id}',
];

const _direct = HostRef.direct('direct-1');
const _config = DirectHostConfig(id: 'direct-1', name: '服务器', baseUrl: 'https://dsh.example.com');

/// A direct host's link that is signed in (holds a session cookie), without a
/// connection.
class _SignedInLink extends DirectHostLink {
  _SignedInLink() : super(config: _config, loadSecrets: () async => const DirectSecrets(), saveCookie: (_) async {});

  @override
  DshCookie? get cookie => const DshCookie(name: 'dsh-auth-x', value: 'v1.fake', authority: 'dsh.example.com');
}

class _SignedOutLink extends DirectHostLink {
  _SignedOutLink() : super(config: _config, loadSecrets: () async => const DirectSecrets(), saveCookie: (_) async {});

  @override
  DshCookie? get cookie => null;
}

/// Runs [probe] with a context and ref of an app whose active host is [host].
Future<T?> _openWeb<T>(
  WidgetTester tester, {
  required HostRef host,
  DirectHostLink? link,
  required T? Function(BuildContext, WidgetRef) probe,
}) async {
  T? result;
  await tester.pumpWidget(
    goldenApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) =>
              TextButton(onPressed: () => result = probe(context, ref), child: const Text('go')),
        ),
      ),
      brightness: Brightness.light,
      overrides: [
        activeHostProvider.overrideWith(() => FixedActiveHost(host)),
        hostsProvider.overrideWith(FixedHosts.new),
        hostNameProvider.overrideWith((ref, h) => '服务器'),
        hostLinkProvider.overrideWith((ref, h) => link),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      ],
    ),
  );
  await tester.pump();
  await tester.tap(find.text('go'));
  await tester.pump();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('账号', () {
    test('Android keeps the page; iOS has no row, search hit or link to it', () {
      final account = SettingsIndex.entry(SettingsPageId.account);
      expect(SettingsIndex.hasPage(SettingsPageId.account), isTrue);
      expect(SettingsIndex.has(account), isTrue);
      expect(_ids('账号'), contains(account.id));
      _asIos();
      expect(SettingsIndex.hasPage(SettingsPageId.account), isFalse);
      expect(SettingsIndex.has(account), isFalse);
      expect(_ids('账号'), isNot(contains(account.id)));
      expect(_ids('account'), isNot(contains(account.id)));
    });

    test('no engine, phone-control or Android-system entry is left in iOS search', () {
      _asIos();
      for (final q in ['引擎', 'engine', '手机操控', 'phone control', '无障碍', '电池', '后台保活', '启动图标', '语音', '通知']) {
        for (final id in _ids(q)) {
          final spot = SettingsIndex.spot(id);
          if (spot == null) continue; // a feature, not a settings row
          expect(SettingsIndex.has(spot), isTrue, reason: '$q → $id');
        }
      }
      // The pages Android alone has never show up as a result.
      for (final id in SettingsIndex.androidOnlyPages) {
        expect(_ids(SettingsIndex.page(id).title(_zh)), isNot(contains(SettingsIndex.entry(id).id)), reason: id.name);
      }
    });

    testWidgets('the hub card is not 账号\'s anchor on iOS, and is on Android', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 6000);
      addTearDown(tester.view.reset);
      Future<void> pumpHub() async {
        await tester.pumpWidget(
          goldenApp(
            home: const SettingsScreen(),
            brightness: Brightness.light,
            overrides: [
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(const LocalRuntimeState(loaded: true, status: RuntimeStatus.unknown())),
              ),
              settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
      }

      final key = find.byKey(SpotKey(SettingsIndex.entry(SettingsPageId.account).id));
      await pumpHub();
      expect(key, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      _asIos();
      await pumpHub();
      expect(key, findsNothing);
      expect(find.byKey(SpotKey(SettingsIndex.entry(SettingsPageId.remote).id)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the web app opens the active host\'s own', () {
    testWidgets('a connected direct host: its WebViewPage at the host URL', (tester) async {
      _asIos();
      final link = _SignedInLink();
      addTearDown(link.close);
      final page = await _openWeb<Widget>(
        tester,
        host: _direct,
        link: link,
        probe: (context, ref) => dshWebPage(context, ref),
      );
      expect(page, isA<WebViewPage>());
      expect((page! as WebViewPage).url, Uri.parse('https://dsh.example.com/'));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a direct host not signed in: nothing, and a SnackBar says to connect first', (tester) async {
      _asIos();
      final link = _SignedOutLink();
      addTearDown(link.close);
      final page = await _openWeb<Widget>(
        tester,
        host: _direct,
        link: link,
        probe: (context, ref) => dshWebPage(context, ref),
      );
      expect(page, isNull);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('服务器'), findsWidgets);
    });

    testWidgets('openDshWeb with no web page for the host says why and pushes nothing', (tester) async {
      _asIos();
      final link = _SignedOutLink();
      addTearDown(link.close);
      await _openWeb<void>(tester, host: _direct, link: link, probe: (context, ref) => openDshWeb(context, ref));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(WebViewPage), findsNothing);
      expect(find.byType(LocalWebScreen), findsNothing);
    });

    testWidgets('the local engine is unchanged (LocalWebScreen)', (tester) async {
      final page = await _openWeb<Widget>(
        tester,
        host: HostRef.local,
        probe: (context, ref) => dshWebPage(context, ref),
      );
      expect(page, isA<LocalWebScreen>());
    });
  });

  group('the hub says what the host lacks', () {
    Future<void> pumpHub(
      WidgetTester tester, {
      required EngineSettings? engine,
      required MediaPluginState media,
      bool pluginsLoaded = true,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 6000);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: const SettingsScreen(),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: RuntimeStatus.unknown())),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            engineSettingsProvider.overrideWith(() => _EngineSettings(engine)),
            mediaPluginProvider.overrideWithValue(media),
            installedPluginsProvider.overrideWith(() => _Installed(pluginsLoaded)),
          ],
        ),
      );
      // The hub reads the host's settings only once something has.
      final container = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
      await tester.runAsync(() => container.read(engineSettingsProvider.future));
      await tester.pump(const Duration(milliseconds: 600));
    }

    Finder row(SettingsPageId id) =>
        find.byWidgetPredicate((w) => w is SettingsTile && w.spot?.id == SettingsIndex.entry(id).id);

    testWidgets('web search not served; media installable → 「主机未提供」 / 「未安装」', (tester) async {
      _asIos();
      await pumpHub(
        tester,
        engine: const EngineSettings(namespaces: {}),
        media: MediaPluginState.installable,
      );
      expect(
        find.descendant(of: row(SettingsPageId.webSearch), matching: find.text(_zh.settingsIosHostLacks)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row(SettingsPageId.media), matching: find.text(_zh.settingsIosNotInstalled)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('media the host does not list at all → 「主机未提供」', (tester) async {
      _asIos();
      await pumpHub(
        tester,
        engine: const EngineSettings(namespaces: {}),
        media: MediaPluginState.absent,
      );
      expect(
        find.descendant(of: row(SettingsPageId.media), matching: find.text(_zh.settingsIosHostLacks)),
        findsOneWidget,
      );
    });

    testWidgets('media ready → no mark on the row', (tester) async {
      _asIos();
      await pumpHub(
        tester,
        engine: const EngineSettings(namespaces: {}),
        media: MediaPluginState.ready,
      );
      expect(
        find.descendant(of: row(SettingsPageId.media), matching: find.text(_zh.settingsIosNotInstalled)),
        findsNothing,
      );
      expect(
        find.descendant(of: row(SettingsPageId.media), matching: find.text(_zh.settingsIosHostLacks)),
        findsNothing,
      );
    });

    testWidgets('plugin list not in yet → no media mark (every host would look bare)', (tester) async {
      _asIos();
      await pumpHub(
        tester,
        engine: const EngineSettings(namespaces: {}),
        media: MediaPluginState.absent,
        pluginsLoaded: false,
      );
      expect(
        find.descendant(of: row(SettingsPageId.media), matching: find.text(_zh.settingsIosHostLacks)),
        findsNothing,
      );
    });

    testWidgets('settings not read yet → web search shows no mark (nothing is claimed)', (tester) async {
      _asIos();
      await pumpHub(tester, engine: null, media: MediaPluginState.ready);
      expect(
        find.descendant(of: row(SettingsPageId.webSearch), matching: find.text(_zh.settingsIosHostLacks)),
        findsNothing,
      );
    });
  });

  group('the quick panel\'s defaults', () {
    test('Android: plugins, engine, settings', () {
      expect(const QuickPanelPrefs().items, [
        DrawerDestination.plugins,
        DrawerDestination.engine,
        DrawerDestination.settings,
      ]);
      expect(QuickPanelPrefs.defaultItems, const QuickPanelPrefs().items);
    });

    test('iOS: hosts, plugins, features, settings — four entries all shown', () {
      _asIos();
      const prefs = QuickPanelPrefs();
      expect(prefs.items, [
        DrawerDestination.remote,
        DrawerDestination.plugins,
        DrawerDestination.features,
        DrawerDestination.settings,
      ]);
      expect(prefs.shown, prefs.items);
    });

    test('a stored list is not replaced by the default', () {
      _asIos();
      final prefs = const QuickPanelPrefs().copyWith(items: [DrawerDestination.settings]);
      expect(prefs.items, [DrawerDestination.settings]);
    });
  });
}

class _EngineSettings extends EngineSettingsController {
  _EngineSettings(this.value);
  final EngineSettings? value;

  @override
  Future<EngineSettings?> build() async => value;
}

class _Installed extends InstalledPluginsController {
  _Installed(this.loaded);
  final bool loaded;

  @override
  Future<List<PluginBundle>?> build() async => loaded ? const <PluginBundle>[] : null;
}
