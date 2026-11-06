// iOS islands check: every plugin seat the connected direct host offers,
// opened at page size on the simulator, with what became of it — a web
// island (WKWebView) that came up, the 「在网页版打开」 fallback, a native
// form, nothing — plus white-screen / sign-in / size checks of each island,
// the islands' device answer (`dsh/islands device`, ios/Runner/IslandsChannel.swift)
// and a warm `dshgo://open/settings` the app opens itself (UIApplication.open →
// SceneDelegate → ios/Runner/LinksChannel.swift → LinkRouter; `simctl openurl`
// would stop at iOS's 「在"DSH Go"中打开？」 prompt).
//
// Read-only on the host: nothing is sent, saved or toggled; a fallback's
// 「在网页版打开」 is only looked at.
// Run by tooling/ios/sim-islands.sh (flutter test on a simulator); results in
// logs/sim-islands/: NNN-<name>.png and islands.json.
//
// Defines: SMOKE_OUT, SMOKE_DIRECT_URL / SMOKE_DIRECT_TOKEN (the token never
// reaches a file or the log).
//
// Privacy: an island whose page text looks like a credential is not
// photographed (a bot's app secret on a settings page).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui_;

import 'package:dsh_app/app.dart';
import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/l10n/l10n.dart' show appL10n;
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/state/sessions_state.dart' show sessionsProvider;
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_app/ui/common/capsule_chip.dart' show CapsuleChoiceChip;
import 'package:dsh_app/ui/common/segmented_pill.dart' show SegmentedPill;
import 'package:dsh_app/ui/common/third_party_licenses.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart' show showBundleSheet;
import 'package:dsh_app/ui/session/session_detail_page.dart' show SessionDetailPage;
import 'package:dsh_app/ui/session/session_tab.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/plugins/islands/islands.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_seat_page.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_web_places.dart' show pluginWebPlaces;
import 'package:dsh_app/ui/plugins/seats/seat_links.dart' show SeatWebLink;
import 'package:dsh_app/ui/settings/font_licenses.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart' show SettingsScreen;
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _out = String.fromEnvironment('SMOKE_OUT');
const _url = String.fromEnvironment('SMOKE_DIRECT_URL');
const _token = String.fromEnvironment('SMOKE_DIRECT_TOKEN');

String _scrub(String s) => _token.isEmpty ? s : s.replaceAll(_token, '<token>');

/// Text that looks like a credential: the picture is skipped.
final _secret = RegExp(
  r'(密码|口令|password|passwd|pwd|secret|密钥)\s*[:：=是为]\s*\S'
  r'|token=[A-Za-z0-9]'
  r'|\bsk-[A-Za-z0-9_-]{16,}'
  r'|Bearer\s+[A-Za-z0-9._-]{16,}'
  r'|-----BEGIN [A-Z ]*PRIVATE KEY'
  r'|\bgh[pousr]_[A-Za-z0-9]{20,}',
  caseSensitive: false,
);

/// What an island page says about itself (no text leaves the page but its
/// length and these flags).
const _probeJs = '''JSON.stringify((function () {
  var b = document.body, t = b ? (b.innerText || '') : '';
  return {
    path: location.pathname,
    text: t.trim().length,
    password: !!document.querySelector('input[type=password]'),
    signIn: /(登录|sign in|log in|launch token|访问令牌)/i.test(t) && t.length < 600,
    secret: SECRET.test(t),
    w: window.innerWidth, h: window.innerHeight,
    vw: window.visualViewport ? Math.round(window.visualViewport.width) : null,
    vh: window.visualViewport ? Math.round(window.visualViewport.height) : null
  };
})())''';

/// Where an island that hasn't come up yet stands in DSH Web's page (no text,
/// only structure): for a seat that times out.
const _domJs = '''JSON.stringify((function () {
  var q = function (s) { return document.querySelectorAll(s); };
  var main = document.querySelector('[data-slot="main"]');
  var slots = {};
  q('[data-slot]').forEach(function (e) { slots[e.getAttribute('data-slot')] = 1; });
  return {
    main: !!main,
    cards: q('li[data-plugin-package]').length,
    cardsInMain: main ? main.querySelectorAll('li[data-plugin-package]').length : -1,
    packages: Array.prototype.map.call(q('li[data-plugin-package]'), function (e) { return e.getAttribute('data-plugin-package'); }),
    detail: Array.prototype.map.call(q('[data-plugin-detail]'), function (e) { return e.getAttribute('data-plugin-detail'); }),
    groups: Array.prototype.map.call(q('[data-plugin-group]'), function (e) { return e.getAttribute('data-plugin-group'); }),
    dialogs: q('[role=dialog]').length,
    config: q('[data-plugin-config]').length,
    rows: q('[data-plugin-row]').length,
    detailSlots: Array.prototype.map.call(q('[data-plugin-detail] [data-slot]'), function (e) { return e.getAttribute('data-slot'); }).slice(0, 20),
    w: window.innerWidth, h: window.innerHeight,
    slots: Object.keys(slots).slice(0, 60)
  };
})())''';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS islands', timeout: const Timeout(Duration(minutes: 30)), (tester) async {
    final run = _Run(tester, binding);
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    final done = Completer<void>();
    runZonedGuarded(
      () => run.run().then(
        (_) => done.complete(),
        onError: (Object e, StackTrace s) {
          run.problem('run', 'aborted: ${_scrub('$e')}');
          done.complete();
        },
      ),
      (e, s) => run.problem(run.current, 'uncaught: ${_scrub('$e')}'),
    );
    await done.future;
    appErrorCapture.uninstall();
    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;
    await run.finish();
    expect(run.ran, isTrue);
  });
}

class _Run {
  _Run(this.tester, this.binding);

  final WidgetTester tester;
  final IntegrationTestWidgetsFlutterBinding binding;

  String out = '';
  String current = 'boot';
  bool ran = false;
  int _n = 0;
  final problems = <Map<String, String>>[];
  final seats = <Map<String, Object?>>[];
  final places = <Map<String, Object?>>[];
  Map<String, Object?> device = const {};
  Map<String, Object?> link = const {};
  int? maxIslands;

  /// Every island the host made: its latest phase, by spec key.
  final islands = <String, IslandHandle>{};
  final phases = <String, List<String>>{};

  void problem(String where, String what) {
    final text = _scrub(what);
    if (problems.any((p) => p['where'] == where && p['what'] == text)) return;
    problems.add({'where': where, 'what': text});
    debugPrint('ISLANDS_PROBLEM [$where] ${text.split('\n').first}');
  }

  Future<void> frames([int ms = 1200]) async {
    for (var t = 0; t < ms; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<bool> waitFor(Finder f, {int seconds = 15}) async {
    for (var i = 0; i < seconds * 5; i++) {
      if (f.hitTestable().evaluate().isNotEmpty) return true;
      await tester.pump(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<void> tapAndSettle(Finder f, [int ms = 1500]) async {
    if (!await waitFor(f, seconds: 10)) throw StateError('not found: ${f.describeMatch(Plurality.zero)}');
    await tester.tap(f.hitTestable().first);
    await frames(ms);
  }

  NavigatorState rootNav() => tester.state<NavigatorState>(find.byType(Navigator).first);

  Future<void> home() async {
    FocusManager.instance.primaryFocus?.unfocus();
    rootNav().popUntil((r) => r.isFirst);
    await frames(900);
  }

  /// The whole device screen (sim-smoke-mac.zsh answers TOUR_CAPTURE), else
  /// the Flutter view alone. Returns the file name, null when skipped.
  Future<String?> shot(String name, {bool private = false}) async {
    if (private) {
      debugPrint('ISLANDS_SKIP_SHOT $name: credential-like text');
      return null;
    }
    await frames(400);
    _n++;
    final file = '${_n.toString().padLeft(3, '0')}-${name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_')}.png';
    try {
      final target = File('$out/$file');
      if (layerShots) {
        final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
        final image = await layer.toImage(Offset.zero & tester.view.physicalSize);
        final data = await image.toByteData(format: ui_.ImageByteFormat.png);
        image.dispose();
        await target.writeAsBytes(data!.buffer.asUint8List());
        return file;
      }
      debugPrint('TOUR_CAPTURE $file');
      for (var i = 0; i < 40 && !(await target.exists() && await target.length() > 0); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!(await target.exists() && await target.length() > 0)) {
        final bytes = await binding.takeScreenshot(file);
        (binding.reportData?['screenshots'] as List?)?.clear();
        await target.writeAsBytes(bytes);
      }
      return file;
    } catch (e) {
      problem(current, 'screenshot $file failed: $e');
      return null;
    }
  }

  /// Taken once home is on screen (a page pushed over it puts HomeShell offstage).
  late final ProviderContainer container;

  /// The app's own frames of [stack], for a problem's note.
  static String frames0(StackTrace? stack) => (stack?.toString() ?? '')
      .split('\n')
      .where((l) => l.contains('package:dsh_app/'))
      .take(3)
      .map((l) => l.replaceAll(RegExp(r'^#\d+\s+'), '').trim())
      .join(' < ');

  Future<void> part(String name, Future<void> Function() body) async {
    final outer = current;
    current = name;
    debugPrint('ISLANDS_PART $name');
    try {
      await body();
    } catch (e, stack) {
      problem(name, 'could not finish: ${e.toString().split('\n').first} @ ${frames0(stack)}');
      try {
        await home();
      } catch (_) {}
    }
    current = outer;
  }

  // ── The run ──

  Future<void> run() async {
    for (final candidate in [_out, '${(await getApplicationDocumentsDirectory()).path}/sim-islands']) {
      if (candidate.isEmpty) continue;
      try {
        await Directory(candidate).create(recursive: true);
        await File('$candidate/.probe').writeAsString('ok');
        out = candidate;
        break;
      } catch (_) {}
    }
    if (out.isEmpty) throw StateError('no writable output directory');
    debugPrint('SMOKE_OUT_DIR=$out');

    FlutterError.onError = (d) =>
        problem(current, 'FlutterError: ${'${d.exception}'.split('\n').first} @ ${frames0(d.stack)}');
    PlatformDispatcher.instance.onError = (e, s) {
      problem(current, 'uncaught: $e');
      return true;
    };

    await (await SharedPreferences.getInstance()).clear();
    await const FlutterSecureStorage().deleteAll();
    appErrorCapture.install();
    await Future.wait([AppLanguageController.load(), LaunchController.begin()]);
    registerThirdPartyLicenses();
    registerFontLicenses();
    await tester.pumpWidget(const ProviderScope(child: DshApp()));

    if (_url.isEmpty || _token.isEmpty) {
      problem('connect', 'no SMOKE_DIRECT_URL / TOKEN: nothing to check');
      return;
    }
    if (!await connect()) return;
    ran = true;
    watchIslands();
    await part('device', checkDevice);
    await part('link-warm', warmLink);
    await part('seats', checkSeats);
    await part('ui-portrait', () => checkPluginUi('portrait'));
    // A wide screen (iPad) also on its side: the simulator can't be turned from the command line
    // and an iPad app that multitasks ignores orientation requests, so the Flutter view is
    // resized and pictured from its own layers (a web view there is a blank area).
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    if (size.shortestSide >= 600) {
      final p = tester.view.physicalSize;
      tester.view.physicalSize = Size(p.height, p.width);
      layerShots = true;
      await frames(2000);
      await part('ui-landscape', () => checkPluginUi('landscape'));
      tester.view.resetPhysicalSize();
      layerShots = false;
      await frames(1500);
    }
    maxIslands = container.read(islandHostProvider).max;
  }

  bool layerShots = false;
  final ui = <Map<String, Object?>>[];

  /// Visible text that looks like a credential (native screens).
  bool privateOnScreen() {
    for (final e in find.byType(RichText).evaluate()) {
      if (_secret.hasMatch((e.widget as RichText).text.toPlainText())) return true;
    }
    return false;
  }

  /// Any ready island page whose text looks like a credential.
  Future<bool> privateIsland() async {
    for (final h in container.read(islandHostProvider).live) {
      if (h.phase != IslandPhase.ready) continue;
      final probe = await _probe(h);
      if (probe is Map && probe['secret'] == true) return true;
    }
    return false;
  }

  Future<String?> uiShot(String name) async => shot(name, private: privateOnScreen() || await privateIsland());

  /// Islands alive now ([settleIsland] waits for one not among them).
  Set<IslandHandle> liveIslands() => container.read(islandHostProvider).live.toSet();

  /// Waits up to [seconds] for an island not in [before] to be ready (or a fallback link).
  Future<String> settleIsland({Set<IslandHandle> before = const {}, int seconds = 20}) async {
    for (var i = 0; i < seconds * 5; i++) {
      final live = container.read(islandHostProvider).live;
      if (live.any((h) => !before.contains(h) && h.phase == IslandPhase.ready)) return 'ready';
      if (find.byType(SeatWebLink).evaluate().isNotEmpty) return 'webFallback';
      await tester.pump(const Duration(milliseconds: 200));
    }
    return 'notReady';
  }

  /// plugin-ui item 5: the 「设置分区」 card on a plugin's detail sheet (and one of its rows
  /// opened), and 对话详情 › 插件 with its tab capsules.
  Future<void> checkPluginUi(String orientation) async {
    final bundles = container.read(installedPluginsProvider).value ?? const [];
    for (final package in ['@xmanrui/dsh-im', 'dsh-better-sidebar', 'dshmarket']) {
      await part('detail-$package-$orientation', () async {
        final bundle = bundles.where((b) => b.name == package).firstOrNull;
        if (bundle == null) throw StateError('$package not installed');
        await home();
        unawaited(showBundleSheet(tester.element(find.byType(Navigator).first), bundle));
        await frames(2000);
        final rows = find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('plugin-section|'),
        );
        // The sheet's list builds lazily: rows below the fold (a phone, a
        // plugin with more cards) only exist once scrolled to.
        if (rows.evaluate().isEmpty) {
          try {
            await tester.scrollUntilVisible(rows, 200, scrollable: find.byType(Scrollable).last, maxScrolls: 12);
          } catch (_) {
            // Not there at all: reported below.
          }
        }
        final entry = <String, Object?>{'part': 'detail', 'package': package, 'orientation': orientation};
        entry['rows'] = [for (final e in rows.evaluate()) (e.widget.key! as ValueKey<String>).value];
        if (rows.evaluate().isNotEmpty) {
          await Scrollable.ensureVisible(tester.element(rows.first), alignment: 0.5);
          await frames(800);
        } else {
          problem('detail-$package-$orientation', 'no 设置分区 rows on the detail sheet');
        }
        entry['shot'] = await uiShot('detail-$package-$orientation');
        if (rows.hitTestable().evaluate().isNotEmpty) {
          final before = liveIslands();
          await tester.tap(rows.hitTestable().first);
          await frames(1500);
          entry['opened'] = await settleIsland(before: before);
          await frames(1500);
          entry['openedShot'] = await uiShot('detail-$package-$orientation-section');
        }
        ui.add(entry);
        debugPrint('ISLANDS_UI ${jsonEncode(entry)}');
        await home();
      });
    }
    await part('session-plugins-$orientation', () async {
      final sessionId = container.read(sessionsProvider).value?.firstOrNull?.sessionId;
      if (sessionId == null) throw StateError('no conversation on the host');
      await home();
      unawaited(rootNav().push(SessionDetailPage.route(sessionId, initialTab: SessionTab.plugins)));
      await frames(2500);
      final entry = <String, Object?>{'part': 'session-plugins', 'orientation': orientation};
      final switcher = find.byKey(const ValueKey('session-plugins-switcher'));
      entry['switcher'] = switcher.evaluate().isNotEmpty;
      // ≤ 4 tabs: a SegmentedPill; more: a row of capsule chips.
      final labels = <String>[
        for (final e in switcher.evaluate())
          if (e.widget is SegmentedPill<int>)
            for (final seg in (e.widget as SegmentedPill<int>).segments) seg.label,
        for (final e in find.descendant(of: switcher, matching: find.byType(CapsuleChoiceChip)).evaluate())
          (e.widget as CapsuleChoiceChip).label,
      ];
      Finder chipOf(String label) => find.descendant(of: switcher, matching: find.text(label)).first;
      entry['tabs'] = labels;
      entry['first'] = await settleIsland();
      entry['shot'] = await uiShot('session-plugins-$orientation');
      final picks = <Map<String, Object?>>[];
      for (var i = 1; i < labels.length; i++) {
        // A tab whose island failed turns into a web link: the page shows the list instead.
        if (switcher.evaluate().isEmpty) {
          picks.add({'tab': labels[i], 'outcome': 'switcherGone'});
          break;
        }
        final chip = chipOf(labels[i]);
        if (chip.hitTestable().evaluate().isEmpty) await Scrollable.ensureVisible(tester.element(chip), alignment: 0.5);
        final had = liveIslands();
        await tester.tap(chip);
        await frames(300);
        final transition = await uiShot('session-plugins-$orientation-${i + 1}-switching');
        final before = DateTime.now();
        final outcome = await settleIsland(before: had);
        await frames(1200);
        picks.add({
          'tab': labels[i],
          'outcome': outcome,
          'ms': DateTime.now().difference(before).inMilliseconds,
          'transitionShot': transition,
          'shot': await uiShot('session-plugins-$orientation-${i + 1}'),
        });
      }
      // Back to the first one: the open tab should be made active again, not opened anew.
      if (labels.length > 1 && switcher.evaluate().isNotEmpty) {
        await tester.tap(chipOf(labels.first));
        await frames(300);
        picks.add({'tab': '${labels.first} (again)', 'outcome': await settleIsland()});
      }
      entry['picks'] = picks;
      entry['endsAsList'] = switcher.evaluate().isEmpty;
      if (switcher.evaluate().isEmpty) entry['endShot'] = await uiShot('session-plugins-$orientation-end');
      ui.add(entry);
      debugPrint('ISLANDS_UI ${jsonEncode(entry)}');
      if (!entry['switcher']!.toString().contains('true')) problem('session-plugins-$orientation', 'no tab capsules');
      await home();
    });
  }

  Future<bool> connect() async {
    current = 'connect';
    if (!await waitFor(find.byType(WelcomePage), seconds: 40)) {
      problem('connect', 'no welcome page');
      return false;
    }
    await tapAndSettle(find.descendant(of: find.byType(WelcomePage), matching: find.byType(FilledButton)));
    await tapAndSettle(find.byKey(const ValueKey('remote-only-direct')), 500);
    await tapAndSettle(find.byKey(const ValueKey('remote-only-continue')), 1500);
    if (!await waitFor(find.byKey(const ValueKey('direct-url')))) {
      problem('connect', 'no direct form');
      return false;
    }
    await tester.enterText(find.byKey(const ValueKey('direct-url')), _url);
    await tester.enterText(find.byKey(const ValueKey('direct-token')), _token);
    await frames(300);
    FocusManager.instance.primaryFocus?.unfocus();
    await frames(600);
    await tapAndSettle(find.byKey(const ValueKey('direct-save')), 500);
    if (!await waitFor(find.byType(HomeShell), seconds: 60)) {
      problem('connect', 'not home after saving');
      return false;
    }
    await frames(3000);
    container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    return true;
  }

  /// Follows every island the pool makes (phases, failures), so a seat that
  /// fell back still says why.
  void watchIslands() {
    final host = container.read(islandHostProvider);
    void seen() {
      for (final h in host.live) {
        if (identical(islands[h.spec.key], h)) continue;
        islands[h.spec.key] = h;
        final log = phases.putIfAbsent(h.spec.key, () => []);
        void note() {
          final entry = h.failure == null ? h.phase.name : '${h.phase.name}:${h.failure!.name}';
          if (log.isEmpty || log.last != entry) log.add(entry);
        }

        note();
        h.addListener(note);
      }
    }

    host.addListener(seen);
  }

  Future<void> checkDevice() async {
    final host = container.read(islandHostProvider);
    for (var i = 0; i < 50 && host.device.totalMem <= 0; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final d = host.device;
    device = {
      'totalMem': d.totalMem,
      'availMem': d.availMem,
      'lowRam': d.lowRam,
      'webView': d.webView,
      'supported': host.supported,
      'maxIslands': host.max,
    };
    debugPrint('ISLANDS_DEVICE ${jsonEncode(device)}');
    if (d.totalMem <= 0) problem('device', 'dsh/islands device gave no memory: islands stay off');
  }

  /// `dshgo://open/settings` while the app runs, through the system.
  Future<void> warmLink() async {
    await home();
    const uri = 'dshgo://open/settings';
    final opened = await launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!opened) problem('link-warm', 'UIApplication.open refused $uri');
    final landed = await waitFor(find.byType(SettingsScreen), seconds: 25);
    link = {'uri': uri, 'landed': landed, 'shot': await shot('link-warm-settings')};
    debugPrint('ISLANDS_LINK ${jsonEncode(link)}');
    if (!landed) problem('link-warm', '$uri did not open 设置');
    await home();
  }

  Future<void> checkSeats() async {
    final keep = container.listen(seatInventoryKeepAliveProvider, (_, _) {});
    try {
      SeatInventory? inventory;
      for (var i = 0; i < 150; i++) {
        inventory = container.read(seatInventoryProvider);
        if (inventory != null && inventory.packages.isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 200));
      }
      if (inventory == null) throw StateError('no seat inventory from the host');
      // The conversation list comes after the inventory: the right-pane tabs need one.
      for (var i = 0; i < 75 && (container.read(sessionsProvider).value?.isEmpty ?? true); i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final sessionId = container.read(sessionsProvider).value?.firstOrNull?.sessionId;
      debugPrint('ISLANDS_SESSION ${sessionId == null ? 'none' : 'found'}');
      final thirdParty = [
        for (final p in inventory.packages.values)
          if (p.hasClient && p.installed && !p.official) p.package,
      ]..sort();
      debugPrint('ISLANDS_INVENTORY tier=${inventory.tier.name} web=${inventory.webReachable} packages=$thirdParty');
      for (final package in thirdParty) {
        places.add({
          'package': package,
          'webPlaces': [for (final w in pluginWebPlaces(inventory, package)) w.name],
        });
      }

      final requests = <String, SeatRequest>{};
      for (final package in thirdParty) {
        requests['config-$package'] = SeatRequest(
          slot: Slots.bundleConfig,
          placement: SeatPlacement.page,
          package: package,
          cell: package,
        );
      }
      for (final slot in [Slots.settingsSection, Slots.main, Slots.conversationView, Slots.rightPaneTab]) {
        final scoped = slot == Slots.conversationView || slot == Slots.rightPaneTab;
        if (scoped && sessionId == null) continue;
        for (final o in inventory.occupantsFor(slot)) {
          if (o.official || inventory.isOfficial(o.package)) continue;
          requests['$slot-${o.package}-${o.cell}'] = SeatRequest(
            slot: slot,
            placement: SeatPlacement.page,
            sessionId: scoped ? sessionId : null,
            package: o.package,
            cell: o.cell,
          );
        }
      }
      var webShown = false;
      for (final MapEntry(key: name, value: request) in requests.entries) {
        await part('seat-$name', () async {
          webShown = await checkSeat(name, request, openWeb: !webShown) || webShown;
        });
      }
    } finally {
      keep.close();
    }
  }

  /// One seat at page size. True when its 「在网页版打开」 was followed.
  Future<bool> checkSeat(String name, SeatRequest request, {required bool openWeb}) async {
    await home();
    unawaited(rootNav().push(PluginSeatPage.route(title: name, request: request)));
    await frames(1500);
    final plan = container.read(seatPlanProvider(request)).visible;
    final island = plan.where((i) => i.mode == SeatMode.island).firstOrNull?.island;
    final entry = <String, Object?>{
      'seat': name,
      'slot': request.slot,
      'package': request.package,
      'cell': request.cell,
      'plan': [for (final i in plan) i.mode.name],
    };
    var outcome = plan.isEmpty ? 'empty' : plan.first.mode.name;
    var private = false;
    if (island != null) {
      // Up to the slowest ready gate (12 s) and a little more.
      for (var i = 0; i < 100; i++) {
        final h = islands[island.key];
        if (i == 50 && h != null && h.phase == IslandPhase.loading) entry['domAt10s'] = await _eval(h, _domJs);
        if (h != null && (h.phase != IslandPhase.loading)) break;
        if (find.byType(SeatWebLink).evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 200));
      }
      await frames(1500);
      final h = islands[island.key];
      entry['phases'] = phases[island.key] ?? const [];
      entry['readyMs'] = h?.readyAfter?.inMilliseconds;
      if (h != null && h.phase == IslandPhase.ready) {
        outcome = 'island';
        final probe = await _probe(h);
        entry['page'] = probe;
        final web = find.byType(WebViewWidget);
        if (web.evaluate().isNotEmpty) {
          final box = tester.getRect(web.last);
          entry['box'] = '${box.width.round()}x${box.height.round()}';
          if (box.width < 100 || box.height < 100) problem(name, 'island box ${entry['box']}: size wrong');
        }
        if (probe is Map) {
          private = probe['secret'] == true;
          if (probe['text'] == 0) problem(name, 'island ready but its page has no text: white screen?');
          if (probe['signIn'] == true) problem(name, 'island shows a sign-in page: session cookie not in WKWebView?');
        }
      } else {
        outcome = find.byType(SeatWebLink).evaluate().isNotEmpty ? 'webFallback' : 'islandNotReady';
        entry['failure'] = h?.failure?.name;
      }
    }
    entry['outcome'] = outcome;
    entry['shot'] = await shot('seat-$name', private: private);
    var followed = false;
    final open = find.text(appL10n.commonOpenInWeb);
    if (openWeb && outcome != 'island' && open.hitTestable().evaluate().isNotEmpty) {
      await tester.tap(open.hitTestable().first);
      await frames(8000);
      entry['webShot'] = await shot('seat-$name-web');
      followed = true;
    }
    seats.add(entry);
    debugPrint('ISLANDS_SEAT ${jsonEncode(entry)}');
    await home();
    return followed;
  }

  Future<Object?> _probe(IslandHandle h) =>
      _eval(h, _probeJs.replaceFirst('SECRET', '/${_secret.pattern.replaceAll('/', r'\/')}/i'));

  Future<Object?> _eval(IslandHandle h, String js) async {
    try {
      final raw = await h.controller.runJavaScriptReturningResult(js);
      final text = raw is String ? raw : '$raw';
      final decoded = jsonDecode(text);
      return decoded is String ? jsonDecode(decoded) : decoded;
    } catch (e) {
      return {'error': '${e.runtimeType}'};
    }
  }

  Future<void> finish() async {
    try {
      await tester.pumpWidget(const SizedBox());
      await frames(300);
    } catch (_) {}
    await const FlutterSecureStorage().deleteAll();
    await (await SharedPreferences.getInstance()).clear();
    final report = {
      'device': device,
      'link': link,
      'maxIslands': maxIslands,
      'seats': seats,
      'webPlaces': places,
      'ui': ui,
      'problems': problems,
    };
    if (out.isNotEmpty) {
      await File('$out/islands.json').writeAsString(_scrub(const JsonEncoder.withIndent('  ').convert(report)));
      await File('$out/.probe').delete().catchError((Object _) => File(''));
    }
    binding.reportData = null;
    debugPrint('SMOKE_REPORT_WRITTEN');
    debugPrint('ISLANDS_RESULT seats=${seats.length} problems=${problems.length}');
    await Future<void>.delayed(const Duration(seconds: 4));
  }
}
