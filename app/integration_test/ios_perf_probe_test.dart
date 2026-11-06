// iOS idle-cost probe: how many frames each screen draws while nobody touches
// it, which widgets keep it drawing, what the app fetches meanwhile. Read-only
// on the host (nothing sent, no host setting changed). Run by
// tooling/ios/sim-smoke.sh --perf; results in logs/perf-probe/perf.json, with
// CPU samples the Mac script takes during each window (cpu-<scene>.txt).
//
// Per scene:
//  1. a clean 10 s window, hands off: frames begun by the framework, frames
//     rasterized (FrameTiming), tickers alive, HTTP requests (host + path);
//     the Mac side samples the Runner process's CPU meanwhile (PERF_CPU line).
//  2. a 3 s diagnosis window with debug hooks on: which render objects are
//     marked for paint and from where in lib/ (debugPrintMarkNeedsPaintStacks),
//     which widgets rebuild (debugOnRebuildDirtyWidget). The hooks are heavy,
//     so they stay out of the measured window.
//
// The simulator runs debug builds only (no profile / release on iOS
// simulators) at 60 Hz: frame COUNTS carry over to a device, CPU% does not.
//
// Defines: SMOKE_OUT, SMOKE_DIRECT_URL / SMOKE_DIRECT_TOKEN (never written anywhere).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dsh_app/app.dart';
import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_state.dart' show noPetId;
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart' show ChatList;
import 'package:dsh_app/ui/common/status_dot.dart' show StatusDot;
import 'package:dsh_app/ui/pets/pet_sprite.dart' show PetSprite;
import 'package:dsh_app/ui/common/third_party_licenses.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart' show GlassSegments, SessionDetailPage;
import 'package:dsh_app/ui/session/session_tab.dart';
import 'package:dsh_app/ui/settings/font_licenses.dart';
import 'package:dsh_app/ui/settings/index/settings_pages.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/web/local_web_screen.dart' show LocalWebScreen;
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _out = String.fromEnvironment('SMOKE_OUT');
const _url = String.fromEnvironment('SMOKE_DIRECT_URL');
const _token = String.fromEnvironment('SMOKE_DIRECT_TOKEN');
// 20 s: a pet put on screen just before plays for up to 8 s before it rests; the per-second
// counts show when a scene settles, fpsLast10 is the steady state.
const _window = Duration(seconds: 20);
const _diagWindow = Duration(seconds: 3);

final _riskyTitle = RegExp(r'密码|口令|password|token|密钥|凭据|credential|宽带|账号|secret|api ?key', caseSensitive: false);

/// Every HTTP request the app opens (dart:io): host and path, never the query.
final _http = <String>[];

final class _LoggingOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      _http.add('${uri.scheme} ${uri.host}${uri.path}');
      return 'DIRECT';
    };
    return client;
  }
}

/// Widgets that animate for as long as they are on screen (checked by type name).
const _animators = {
  'WhaleTail',
  'PetSprite',
  'PetLayer',
  'StatusDot',
  'ProgressHalo',
  'ThinkGlyph',
  'StreamingCursor',
  'TypingIndicator',
  'StatusChip',
  'DshUiSkeleton',
  'ThinkingPill',
  'ThinkingLabel',
  'RunPulse',
  'ActivityStrip',
  'BackdropFilter',
  'IslandView',
  'WebViewWidget',
  'UiKitView',
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS perf probe', timeout: const Timeout(Duration(minutes: 40)), (tester) async {
    final probe = _Probe(tester, binding);
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    final print = debugPrint;
    final done = Completer<void>();
    runZonedGuarded(
      () => probe.run().then(
        (_) => done.complete(),
        onError: (Object e, StackTrace s) {
          probe.notes.add('aborted: ${probe.scrub('$e')}');
          done.complete();
        },
      ),
      (e, s) => probe.notes.add('uncaught: ${probe.scrub('$e')}'),
    );
    await done.future;
    appErrorCapture.uninstall();
    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;
    debugPrint = print;
    await probe.finish();
    expect(probe.scenes, isNotEmpty);
  });
}

class _Probe {
  _Probe(this.tester, this.binding);

  final WidgetTester tester;
  final IntegrationTestWidgetsFlutterBinding binding;
  String out = '';
  final scenes = <Map<String, Object?>>[];
  final notes = <String>[];

  String scrub(String s) => _token.isEmpty ? s : s.replaceAll(_token, '<token>');

  // ── Frame counting ──

  bool _counting = false;
  int _begun = 0;

  /// Frames in which something was built or painted. The live test binding asks the engine for
  /// the next frame after every frame a pump didn't ask for (LiveTestWidgetsFlutterBinding.
  /// handleDrawFrame), so a single frame the app requests turns into an endless run of empty
  /// frames: [_begun] says "the app asked for a frame at all", [_work] how many it needed.
  int _work = 0;
  bool _workThisFrame = false;
  int _rastered = 0;
  int _buildUs = 0;
  int _rasterUs = 0;
  bool _persistentAdded = false;

  void _onTimings(List<FrameTiming> timings) {
    if (!_counting) return;
    _rastered += timings.length;
    for (final t in timings) {
      _buildUs += t.buildDuration.inMicroseconds;
      _rasterUs += t.rasterDuration.inMicroseconds;
    }
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

  bool get sidebar => find.byKey(const ValueKey('persistent-sidebar')).evaluate().isNotEmpty;

  Future<void> openDrawer() async {
    if (find.byType(SessionsDrawer).hitTestable().evaluate().isNotEmpty) return;
    final rail = find.byKey(const ValueKey('rail-menu'));
    await tapAndSettle(rail.hitTestable().evaluate().isNotEmpty ? rail : find.byKey(const ValueKey('chat-menu')));
    if (!await waitFor(find.byType(SessionsDrawer))) throw StateError('drawer did not open');
  }

  Future<void> closeDrawer() async {
    if (sidebar || find.byType(SessionsDrawer).hitTestable().evaluate().isEmpty) return;
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width - 12, size.height / 2));
    await frames(900);
  }

  Future<void> home() async {
    FocusManager.instance.primaryFocus?.unfocus();
    rootNav().popUntil((r) => r.isFirst);
    await frames(900);
    await closeDrawer();
  }

  Future<List<({String key, String title, bool running})>> sessions() async {
    await openDrawer();
    final out = <({String key, String title, bool running})>[];
    final tiles = find.byElementPredicate(_isSessionTile);
    for (final e in tiles.evaluate()) {
      final key = (e.widget.key! as ValueKey<String>).value;
      final of = find.byElementPredicate((x) => x == e);
      final title = find
          .descendant(of: of, matching: find.byType(RichText))
          .evaluate()
          .map((t) => (t.widget as RichText).text.toPlainText())
          .join(' ');
      final running = find.descendant(of: of, matching: find.byKey(const ValueKey('running'))).evaluate().isNotEmpty;
      out.add((key: key, title: title, running: running));
    }
    return out;
  }

  Future<void> openSession(String key) async {
    await openDrawer();
    final tile = find.byKey(ValueKey(key));
    if (tile.hitTestable().evaluate().isEmpty) throw StateError('conversation not in view: $key');
    await tester.tap(tile.hitTestable().first);
    await frames(3500);
    await closeDrawer();
  }

  ProviderContainer get container => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

  // ── What animates ──

  /// Animating widget types mounted where tickers run (TickerMode on).
  Map<String, int> census() {
    final counts = <String, int>{};
    void visit(Element e) {
      final w = e.widget;
      var name = w.runtimeType.toString();
      if (w is CircularProgressIndicator && w.value == null) name = 'CircularProgressIndicator(indeterminate)';
      if (w is LinearProgressIndicator && w.value == null) name = 'LinearProgressIndicator(indeterminate)';
      if (w is CupertinoActivityIndicator) name = 'CupertinoActivityIndicator';
      if (w is StatusDot) name = 'StatusDot(${w.tone.name})';
      if (w is PetSprite) name = 'PetSprite(${w.anim.name} rest=${w.rest} paused=${w.paused} still=${w.still})';
      final wanted =
          _animators.contains(name.split('(').first) ||
          name.contains('indeterminate') ||
          name == 'CupertinoActivityIndicator';
      if (wanted && TickerMode.valuesOf(e).enabled) counts[name] = (counts[name] ?? 0) + 1;
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return counts;
  }

  // ── A scene ──

  /// [settle]: pump frames before measuring (not in the background: no frames come there,
  /// and a pump would wait forever).
  Future<void> scene(String name, String what, Future<void> Function() setup, {bool settle = true}) async {
    debugPrint('PERF_SCENE $name');
    try {
      await setup();
    } on _NotHere catch (e) {
      scenes.add({'scene': name, 'what': what, 'skipped': e.why});
      debugPrint('PERF_SKIP $name: ${e.why}');
      await _write(partial: true);
      return;
    } catch (e) {
      scenes.add({'scene': name, 'what': what, 'skipped': 'setup failed: ${scrub('$e').split('\n').first}'});
      debugPrint('PERF_SKIP $name: setup failed: ${scrub('$e').split('\n').first}');
      try {
        await home();
      } catch (_) {}
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (settle) {
      await frames(2500); // transitions and first loads settle
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    }
    final result = <String, Object?>{'scene': name, 'what': what, 'census': census()};
    result.addAll(await measure(name));
    result['diagnosis'] = await diagnose();
    scenes.add(result);
    await _write(partial: true);
    debugPrint(
      'PERF_RESULT $name begun=${result['framesBegun']} work=${result['framesWork']} workLast10=${result['workLast10']}/s rastered=${result['framesRastered']} '
      'tickers=${result['transientCallbacksAtEnd']} http=${(result['http'] as Map).length}',
    );
  }

  /// The clean window: hands off, frames and requests counted.
  Future<Map<String, Object?>> measure(String name) async {
    _begun = _work = _rastered = _buildUs = _rasterUs = 0;
    _http.clear();
    debugOnProfilePaint = (_) => _workThisFrame = true;
    debugOnRebuildDirtyWidget = (_, _) => _workThisFrame = true;
    final tickers = <int>[];
    _counting = true;
    debugPrint('PERF_CPU $name ${_window.inSeconds}');
    final perSecond = <int>[];
    var mark = 0;
    final end = DateTime.now().add(_window);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      tickers.add(SchedulerBinding.instance.transientCallbackCount);
      if (tickers.length.isEven) {
        perSecond.add(_work - mark);
        mark = _work;
      }
    }
    _counting = false;
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
    final last10 = perSecond.length > 10 ? perSecond.sublist(perSecond.length - 10) : perSecond;
    // Timings come in batches: let the last ones arrive (they're dropped from now on).
    final requests = <String, int>{};
    for (final r in _http) {
      requests[r] = (requests[r] ?? 0) + 1;
    }
    final secs = _window.inMilliseconds / 1000;
    return {
      'seconds': secs,
      'framesBegun': _begun,
      'framesRastered': _rastered,
      'fpsBegun': double.parse((_begun / secs).toStringAsFixed(1)),
      'framesWork': _work,
      'fpsWork': double.parse((_work / secs).toStringAsFixed(1)),
      'workPerSecond': perSecond,
      'workLast10': last10.isEmpty
          ? 0
          : double.parse((last10.reduce((a, b) => a + b) / last10.length).toStringAsFixed(1)),
      'avgBuildMs': _rastered == 0 ? 0 : double.parse((_buildUs / _rastered / 1000).toStringAsFixed(2)),
      'avgRasterMs': _rastered == 0 ? 0 : double.parse((_rasterUs / _rastered / 1000).toStringAsFixed(2)),
      'transientCallbacksMax': tickers.isEmpty ? 0 : tickers.reduce((a, b) => a > b ? a : b),
      'transientCallbacksAtEnd': SchedulerBinding.instance.transientCallbackCount,
      'http': requests,
    };
  }

  /// Hooks on: who marks paint (and from where in lib/), who rebuilds.
  Future<Map<String, Object?>> diagnose() async {
    final painted = <String, int>{}; // 'RenderType#hash'
    final paintFrom = <String, int>{}; // first lib/ frame of the markNeedsPaint stack
    final rebuilt = <String, int>{};
    String? pending; // the render object whose stack is being printed
    final scheduledBy = <String, int>{}; // who asked for a frame (debugPrintScheduleFrameStacks)
    List<String>? sched; // frames of the scheduleFrame stack being printed
    void closeSched() {
      final frames = sched;
      sched = null;
      if (frames == null) return;
      final app = frames.where((f) => f.contains('package:dsh_app/')).take(2).toList();
      final key = app.isNotEmpty
          ? app.map((f) => RegExp(r'package:dsh_app/[^ )]+:\d+').firstMatch(f)?.group(0) ?? f).join(' ← ')
          : 'framework: ${frames.where((f) => !RegExp(r'scheduler/binding|flutter_test/|integration_test/|dart:async|<asynchronous').hasMatch(f)).take(5).map((f) => f.replaceFirst(RegExp(r'^#\d+\s+'), '')).join(' ← ')}';
      scheduledBy[key] = (scheduledBy[key] ?? 0) + 1;
    }

    final previousPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      final text = message ?? '';
      for (final line in text.split('\n')) {
        if (line.contains('scheduleFrame() called')) {
          closeSched();
          sched = [];
          continue;
        }
        if (sched != null && line.trimLeft().startsWith('#')) {
          sched!.add(line.trim());
          if (sched!.length >= 40 || line.contains('package:dsh_app/')) closeSched();
          continue;
        }
        final m = RegExp(r'markNeedsPaint\(\) called for (\w+#[0-9a-f]{5})').firstMatch(line);
        if (m != null) {
          pending = m.group(1);
          painted[pending!] = (painted[pending!] ?? 0) + 1;
          continue;
        }
        if (pending != null && line.contains('package:dsh_app/')) {
          final at = RegExp(r'(package:dsh_app/[^ )]+:\d+)').firstMatch(line)?.group(1) ?? line.trim();
          final key = '${pending!.split('#').first} ← $at';
          paintFrom[key] = (paintFrom[key] ?? 0) + 1;
          pending = null;
        }
      }
    };
    debugPrintMarkNeedsPaintStacks = true;
    debugPrintScheduleFrameStacks = true;
    debugOnRebuildDirtyWidget = (e, builtOnce) {
      if (!builtOnce) return;
      final key = e.debugGetCreatorChain(4);
      rebuilt[key] = (rebuilt[key] ?? 0) + 1;
    };
    await Future<void>.delayed(_diagWindow);
    // The tickers alive now, by where they were started: the scheduler keeps each transient
    // callback's registration stack (a repeating ticker keeps its first one) and reports
    // them through FlutterError when asked to assert there are none.
    final tickers = <String, int>{};
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      final blocks = d.toString().split('── callback').skip(1);
      for (final b in blocks) {
        final at = RegExp(r'package:dsh_app/[^ )]+:\d+').allMatches(b).map((m) => m.group(0)!).take(3).toList();
        final key = at.isEmpty ? 'framework only: ${b.split('\n').skip(1).take(2).join(' / ').trim()}' : at.join(' ← ');
        tickers[key] = (tickers[key] ?? 0) + 1;
      }
    };
    SchedulerBinding.instance.debugAssertNoTransientCallbacks('perf probe: tickers alive');
    FlutterError.onError = onError;
    debugPrintMarkNeedsPaintStacks = false;
    debugPrintScheduleFrameStacks = false;
    closeSched();
    debugOnRebuildDirtyWidget = null;
    debugPrint = previousPrint;

    // Who the painted render objects are: their creator chains.
    final chains = <String, String>{};
    void visit(RenderObject ro) {
      final id = '${ro.runtimeType}#${shortHash(ro)}';
      if (painted.containsKey(id)) {
        final creator = ro.debugCreator;
        chains[id] = creator is DebugCreator ? creator.element.debugGetCreatorChain(7) : '$creator';
      }
      ro.visitChildren(visit);
    }

    for (final view in WidgetsBinding.instance.renderViews) {
      visit(view);
    }
    List<Map<String, Object?>> top(Map<String, int> m, [int n = 10]) {
      final entries = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      return [
        for (final e in entries.take(n)) {'what': e.key, 'count': e.value},
      ];
    }

    return {
      'seconds': _diagWindow.inMilliseconds / 1000,
      'tickers': tickers,
      'scheduledBy': top(scheduledBy),
      'paintedFrom': top(paintFrom),
      'painted': [
        for (final e in top(painted, 8)) {...e, 'creator': chains[e['what']] ?? '(gone)'},
      ],
      'rebuilt': top(rebuilt),
    };
  }

  // ── The run ──

  Future<void> run() async {
    for (final candidate in [_out, '${(await getApplicationDocumentsDirectory()).path}/perf-probe']) {
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

    // Frames as the engine asks for them, not only when the test pumps.
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    if (!_persistentAdded) {
      _persistentAdded = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        if (_counting) {
          _begun++;
          if (_workThisFrame) _work++;
        }
        _workThisFrame = false;
      });
    }
    FlutterError.onError = (d) => notes.add(scrub('FlutterError: ${'${d.exception}'.split('\n').first}'));
    HttpOverrides.global = _LoggingOverrides();

    // The harness alone: nothing on screen should mean no frames.
    await tester.pumpWidget(const SizedBox());
    await scene('baseline-blank', '空白页（测试框架本身的基线）', () async {});

    await (await SharedPreferences.getInstance()).clear();
    await const FlutterSecureStorage().deleteAll();
    appErrorCapture.install();
    await Future.wait([AppLanguageController.load(), LaunchController.begin()]);
    registerThirdPartyLicenses();
    registerFontLicenses();
    await tester.pumpWidget(const ProviderScope(child: DshApp()));
    await scene('onboarding-welcome', '首次引导：欢迎页', () async {
      if (!await waitFor(find.byType(WelcomePage), seconds: 40)) throw StateError('no welcome page');
    });
    if (_url.isEmpty || _token.isEmpty) throw StateError('needs SMOKE_DIRECT_URL / TOKEN');
    await tapAndSettle(find.descendant(of: find.byType(WelcomePage), matching: find.byType(FilledButton)));
    await tapAndSettle(find.byKey(const ValueKey('remote-only-direct')), 500);
    await tapAndSettle(find.byKey(const ValueKey('remote-only-continue')), 1500);
    await waitFor(find.byKey(const ValueKey('direct-url')));
    await tester.enterText(find.byKey(const ValueKey('direct-url')), _url);
    await tester.enterText(find.byKey(const ValueKey('direct-token')), _token);
    FocusManager.instance.primaryFocus?.unfocus();
    await frames(800);
    await tapAndSettle(find.byKey(const ValueKey('direct-save')), 500);
    if (!await waitFor(find.byType(HomeShell), seconds: 60)) throw StateError('not home after saving');
    await frames(4000);

    final pets = container.read(petPrefsProvider.notifier);
    await scene('chat-empty-pet-on', '主聊天页：新对话（空会话），宠物开', () async {
      await pets.setPack(defaultPetId);
      await home();
    });
    await scene('chat-empty-pet-off', '主聊天页：新对话（空会话），宠物关', () async {
      await pets.setPack(noPetId);
      await home();
    });
    await pets.setPack(defaultPetId);
    await frames(1000);

    await scene('drawer-open', '抽屉打开', () async {
      await home();
      await openDrawer();
    });

    final all = (await sessions()).where((s) => !_riskyTitle.hasMatch(s.title)).toList();
    final running = all.where((s) => s.running).map((s) => s.key).firstOrNull;
    String? longest;
    var extent = -1.0;
    for (final s in all.where((s) => !s.running).take(6)) {
      await openSession(s.key);
      final sc = find.descendant(of: find.byType(ChatList), matching: find.byType(Scrollable));
      if (sc.evaluate().isEmpty) continue;
      final p = tester.state<ScrollableState>(sc.first).position;
      if (p.maxScrollExtent - p.minScrollExtent > extent) {
        extent = p.maxScrollExtent - p.minScrollExtent;
        longest = s.key;
      }
    }
    await scene('chat-long-pet-on', '主聊天页：长会话（已完成），宠物开', () async {
      if (longest == null) throw const _NotHere('no finished conversation');
      await openSession(longest);
    });
    await scene('chat-long-pet-off', '主聊天页：长会话（已完成），宠物关', () async {
      if (longest == null) throw const _NotHere('no finished conversation');
      final key = longest;
      await pets.setPack(noPetId);
      await openSession(key);
    });
    await pets.setPack(defaultPetId);
    await scene('chat-running-pet-on', '主聊天页：正在运行的会话，宠物开', () async {
      if (running == null) throw const _NotHere('no conversation running now');
      await openSession(running);
    });
    await scene('chat-running-pet-off', '主聊天页：正在运行的会话，宠物关', () async {
      if (running == null) throw const _NotHere('no conversation running now');
      await pets.setPack(noPetId);
      await openSession(running);
    });
    await pets.setPack(defaultPetId);
    await frames(1000);

    await scene('settings-hub', '设置首页', () async {
      await home();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => settingsPage(SettingsPageId.hub))));
    });
    await scene('web', '网页版（WebView 入口页）', () async {
      await home();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => const LocalWebScreen())));
    });
    await scene('detail-plugins', '对话详情的插件页（islands）', () async {
      await home();
      String? withPlugins;
      for (final s in all.take(10)) {
        await openSession(s.key);
        final pill = find.byKey(const ValueKey('chat-title-pill'));
        if (find.byType(SessionDetailPage).hitTestable().evaluate().isEmpty) {
          final panel = find.byKey(const ValueKey('chat-panel-key'));
          await tapAndSettle(panel.hitTestable().evaluate().isNotEmpty ? panel : pill, 2500);
        }
        final tab = find.descendant(of: find.byType(GlassSegments), matching: find.text(SessionTab.plugins.label));
        if (tab.hitTestable().evaluate().isNotEmpty) {
          await tester.tap(tab.hitTestable().first);
          withPlugins = s.key;
          break;
        }
        await home();
      }
      if (withPlugins == null) throw const _NotHere('no conversation with plugin tabs in the first 10');
    });

    // The app sent to the background (lifecycle only: iOS would also suspend it).
    await scene('background', '退到后台（模拟 lifecycle paused）', () async {
      await home();
      if (running != null) await openSession(running);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    }, settle: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await frames(1500);
  }

  /// perf.json, rewritten after every scene so a run that stops half way still reports.
  Future<void> _write({required bool partial}) async {
    if (out.isEmpty) return;
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await File('$out/perf.json').writeAsString(
      scrub(
        const JsonEncoder.withIndent('  ').convert({
          'screen': '${size.width.round()}x${size.height.round()}',
          'mode': kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release'),
          'partial': partial,
          'scenes': scenes,
          'notes': notes,
        }),
      ),
    );
  }

  Future<void> finish() async {
    try {
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      HttpOverrides.global = null;
      await tester.pumpWidget(const SizedBox());
      await frames(300);
    } catch (_) {}
    await const FlutterSecureStorage().deleteAll();
    await (await SharedPreferences.getInstance()).clear();
    await _write(partial: false);
    if (out.isNotEmpty) await File('$out/.probe').delete().catchError((Object _) => File(''));
    binding.reportData = null;
    debugPrint('SMOKE_REPORT_WRITTEN');
    debugPrint('PERF scenes=${scenes.length} notes=${notes.length}');
    await Future<void>.delayed(const Duration(seconds: 4));
  }
}

class _NotHere implements Exception {
  const _NotHere(this.why);
  final String why;
}

/// A conversation's row in the sessions list (keyed `session-<id>`). Session ids start with
/// `session-` themselves and the chat screen, its detail panel and todo bar are keyed with the
/// bare id, so only rows inside the sessions drawer / sidebar count (on iPad the chat beside the
/// sidebar matched too, and "opening" it tapped the middle of the chat).
bool _isSessionTile(Element e) {
  final key = e.widget.key;
  return key is ValueKey<String> &&
      RegExp(r'^session-(?!delete)').hasMatch(key.value) &&
      e.findAncestorWidgetOfExactType<SessionsDrawer>() != null;
}
