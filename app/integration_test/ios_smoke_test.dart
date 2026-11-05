// iOS simulator smoke test: one cold start walked through every screen the
// remote-only build shows, a screenshot per step, and every FlutterError /
// uncaught error collected (any one fails the run). Run by
// tooling/ios/sim-smoke.sh (`flutter test` on a simulator).
//
// Screenshots and report.json go straight to SMOKE_OUT (a host directory: a
// simulator app can write there), not through reportData, which would carry
// every PNG back in one message.
//
// A real direct host comes in through --dart-define-from-file:
//   SMOKE_DIRECT_URL    https://… of a `dsh web` (empty: no real connection;
//                       first run is then skipped through SharedPreferences)
//   SMOKE_DIRECT_TOKEN  its launch token. Never printed, reported or shot:
//                       every recorded string is scrubbed of it, and the
//                       token field is obscured before any screenshot.
// Read-only: it opens the host's sessions, never sends.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/app.dart';
import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/state/artifacts.dart' show ArtifactKind;
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart' show artifactPreviewable;
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart' show ArtifactTile;
import 'package:dsh_app/ui/chat/widgets/attachments.dart' show SentAttachments;
import 'package:dsh_app/ui/common/third_party_licenses.dart';
import 'package:dsh_app/ui/engine/diagnostics_export_card.dart' show DiagnosticsExportCard;
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/settings/font_licenses.dart';
import 'package:dsh_app/ui/settings/index/settings_pages.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/quick_panel.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
bool get _live => _url.isNotEmpty && _token.isNotEmpty;

/// The top of [stack] plus the app's own frames further down (the framework's
/// frames alone rarely say who did it).
String _stackText(StackTrace stack) {
  final lines = stack.toString().split('\n').where((l) => l.trim().isNotEmpty).toList();
  final own = lines.skip(6).where((l) => l.contains('package:dsh_app') || l.contains('package:dsh_')).take(12);
  // None of ours: the framework's chain is all there is, so more of it.
  if (own.isEmpty) return lines.take(40).join('\n');
  return [...lines.take(6), '  …', ...own].join('\n');
}

/// Provider updates made while the framework was building: what a "setState()
/// called during build" from riverpod's scheduler was set off by.
final _buildPhaseUpdates = <String>[];

final class _BuildPhaseObserver extends ProviderObserver {
  const _BuildPhaseObserver();

  void _note(String what, ProviderObserverContext context, Object? value) {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) return;
    _buildPhaseUpdates.add('$what ${context.provider} -> ${value.runtimeType}');
    if (_buildPhaseUpdates.length > 20) _buildPhaseUpdates.removeAt(0);
  }

  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) =>
      _note('update', context, newValue);

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) => _note('add', context, value);
}

/// A step that doesn't apply here (no such data on the host, a layout without
/// the control): recorded as skipped, not failed.
class _Skip implements Exception {
  const _Skip(this.reason);
  final String reason;
  @override
  String toString() => 'skipped: $reason';
}

String _scrub(String s) => _token.isEmpty ? s : s.replaceAll(_token, '<token>');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS smoke', timeout: const Timeout(Duration(minutes: 20)), (tester) async {
    // Errors the app leaves uncaught land here, not in the test binding's
    // handler (which insists on owning FlutterError.onError while it reports).
    final errors = <String>[];
    final done = Completer<void>();
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    final print = debugPrint;
    runZonedGuarded(
      () => _smoke(tester, binding, errors).then(
        (_) => done.complete(),
        onError: (Object e, StackTrace s) {
          errors.add(_scrub('[smoke] aborted: $e\n$s'));
          done.complete();
        },
      ),
      (e, s) => errors.add(_scrub('[zone] uncaught: $e\n${_stackText(s)}')),
    );
    await done.future;
    // Also after an aborted run: the binding checks these are its own again.
    appErrorCapture.uninstall();
    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;
    debugPrint = print;
    for (final e in errors) {
      debugPrint('SMOKE_ERROR ${e.split('\n').first}');
    }
    expect(errors, isEmpty, reason: 'errors during the smoke run (see report.json)');
  });
}

Future<void> _smoke(WidgetTester tester, IntegrationTestWidgetsFlutterBinding binding, List<String> errors) async {
  {
    var out = '';
    final steps = <Map<String, Object?>>[];
    var current = 'boot';
    var shot = 0;

    void record(String source, Object error, StackTrace? stack) {
      final where = stack == null ? '' : '\n${_stackText(stack)}';
      final during = '$error'.contains('called during build') && _buildPhaseUpdates.isNotEmpty
          ? '\nprovider changes during build (latest last):\n  ${_buildPhaseUpdates.join('\n  ')}'
          : '';
      errors.add(_scrub('[$current] $source: $error$where$during'));
    }

    // Collect instead of failing on the first: the run should show them all.
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    final previousPrint = debugPrint;
    FlutterError.onError = (d) {
      // Layout errors name their widget only in the details (the creator chain).
      final text = d.exception is FlutterError && '${d.exception}'.contains('overflowed')
          ? d.toString().split('\n').take(60).join('\n')
          : d.exception;
      record('FlutterError', text, d.stack);
    };
    PlatformDispatcher.instance.onError = (e, s) {
      record('uncaught', e, s);
      return true;
    };
    debugPrint = (String? message, {int? wrapWidth}) {
      final text = _scrub(message ?? '');
      if (text.contains('MissingPluginException')) errors.add('[$current] debugPrint: $text');
      previousPrint(text, wrapWidth: wrapWidth);
    };

    Future<void> frames([int ms = 1200]) async {
      for (var t = 0; t < ms; t += 100) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<bool> waitFor(Finder f, {int seconds = 20}) async {
      for (var i = 0; i < seconds * 5; i++) {
        if (f.hitTestable().evaluate().isNotEmpty) return true;
        await tester.pump(const Duration(milliseconds: 200));
      }
      return false;
    }

    Future<void> screenshot(String name) async {
      shot++;
      final file = '${shot.toString().padLeft(3, '0')}-${name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_')}';
      try {
        final bytes = await binding.takeScreenshot(file);
        (binding.reportData?['screenshots'] as List?)?.clear();
        await File('$out/$file.png').writeAsBytes(bytes);
      } catch (e) {
        errors.add(_scrub('[$current] screenshot $file failed: $e'));
      }
    }

    NavigatorState rootNav() => tester.state<NavigatorState>(find.byType(Navigator).first);

    Route<dynamic>? topRoute(NavigatorState nav) {
      Route<dynamic>? top;
      nav.popUntil((r) {
        top = r;
        return true;
      });
      return top;
    }

    Future<void> home() async {
      rootNav().popUntil((r) => r.isFirst);
      await frames(800);
    }

    /// One named step: screenshot at the end; a failure is recorded and the
    /// walk goes on from the home screen.
    Future<void> step(String name, Future<void> Function() body, {bool shoot = true, bool recover = true}) async {
      final outer = current;
      current = name;
      final started = DateTime.now();
      debugPrint('SMOKE_STEP $name');
      _buildPhaseUpdates.clear();
      final before = errors.length;
      String? failure;
      String? skipped;
      try {
        await body();
        if (shoot) await screenshot(name);
      } on _Skip catch (e) {
        skipped = e.reason;
        debugPrint('SMOKE_SKIP $name: ${e.reason}');
      } catch (e, s) {
        failure = _scrub('$e');
        record('STEP FAILED', e, s);
        await screenshot('$name-FAILED');
        if (recover) {
          try {
            await home();
          } catch (_) {}
        }
      }
      steps.add({
        'step': name,
        'ok': failure == null && errors.length == before,
        'ms': DateTime.now().difference(started).inMilliseconds,
        'failure': ?failure,
        'skipped': ?skipped,
        'errors': errors.length - before,
      });
      current = outer;
    }

    Future<void> tapAndSettle(Finder f, [int ms = 1200]) async {
      if (!await waitFor(f, seconds: 10)) throw StateError('not found: $f');
      await tester.tap(f.hitTestable().first);
      await frames(ms);
    }

    /// Scrolls the top page's vertical list until [f] is built, then into view.
    Future<bool> reveal(Finder f) async {
      for (final dir in [-1.0, 1.0]) {
        for (var i = 0; i < 25; i++) {
          if (f.evaluate().isNotEmpty) {
            await tester.ensureVisible(f.first);
            await frames(400);
            return true;
          }
          final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
          if (lists.evaluate().isEmpty) return false;
          final state = tester.state<ScrollableState>(lists.first);
          final before = state.position.pixels;
          state.position.jumpTo(
            (before + dir * -350).clamp(state.position.minScrollExtent, state.position.maxScrollExtent),
          );
          await tester.pump(const Duration(milliseconds: 120));
          if (state.position.pixels == before) break;
        }
      }
      return f.evaluate().isNotEmpty;
    }

    Finder entryTile(SettingsPageId id) =>
        find.byWidgetPredicate((w) => w is SettingsTile && w.spot?.id == SettingsIndex.entry(id).id);

    /// Every settings page this build has, under [page]: by its row when
    /// there is one, else pushed (rows hidden by a condition, 全部功能).
    Future<void> walk(SettingsPageId page, String trail) async {
      final children = SettingsIndex.pages.values
          .where((m) => m.parent == page && SettingsIndex.hasPage(m.id) && SettingsIndex.has(m.entry))
          .toList();
      for (final m in children) {
        final name = '$trail/${m.id.name}';
        await step(name, () async {
          final tile = entryTile(m.id);
          final nav = tile.evaluate().isNotEmpty ? Navigator.of(tester.element(tile.first)) : rootNav();
          final back = topRoute(nav);
          var how = 'pushed';
          if (m.row && await reveal(tile)) {
            await tester.tap(tile.first);
            how = 'tapped';
          } else {
            unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => settingsPage(m.id))));
          }
          await frames(1800);
          steps.add({'step': '$name ($how)', 'ok': true});
          await screenshot(name);
          await walk(m.id, name);
          nav.popUntil((r) => r == back);
          await frames(700);
        }, shoot: false);
      }
    }

    Future<void> openDrawer() async {
      if (find.byType(SessionsDrawer).hitTestable().evaluate().isNotEmpty) return;
      // Phone: the chat header's ≡. Wide window (iPad) with the sessions folded
      // into the rail: the rail's ≡ brings the sidebar back.
      final rail = find.byKey(const ValueKey('rail-menu'));
      await tapAndSettle(rail.hitTestable().evaluate().isNotEmpty ? rail : find.byKey(const ValueKey('chat-menu')));
      if (!await waitFor(find.byType(SessionsDrawer))) throw StateError('drawer did not open');
    }

    Future<void> openQuickPanel() async {
      // A wide window keeps the sessions as a sidebar and has no quick panel.
      if (find.byKey(const ValueKey('persistent-sidebar')).evaluate().isNotEmpty) {
        throw const _Skip('sidebar layout: no quick panel');
      }
      final shell = tester.getRect(find.byType(HomeShell));
      final finger = await tester.startGesture(shell.center);
      for (var i = 0; i < 40; i++) {
        await finger.moveBy(const Offset(-6, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 400));
      await finger.up();
      await frames(1000);
      if (find.byType(QuickPanel).hitTestable().evaluate().isEmpty) throw StateError('quick panel did not open');
    }

    // SMOKE_OUT is a host directory (a simulator app can usually write there);
    // else the app's Documents, which sim-smoke-mac.zsh copies out.
    for (final candidate in [_out, '${(await getApplicationDocumentsDirectory()).path}/sim-smoke']) {
      if (candidate.isEmpty) continue;
      try {
        await Directory(candidate).create(recursive: true);
        await File('$candidate/.probe').writeAsString('ok');
        out = candidate;
        break;
      } catch (e) {
        debugPrint('SMOKE_OUT unusable: $candidate ($e)');
      }
    }
    if (out.isEmpty) throw StateError('no writable output directory');
    debugPrint('SMOKE_OUT_DIR=$out');

    // ── Start: a fresh install, as main() does it (main() itself would make a
    // second binding).
    await (await SharedPreferences.getInstance()).clear();
    await const FlutterSecureStorage().deleteAll();
    appErrorCapture.install();
    await Future.wait([AppLanguageController.load(), LaunchController.begin()]);
    registerThirdPartyLicenses();
    registerFontLicenses();
    await tester.pumpWidget(const ProviderScope(observers: [_BuildPhaseObserver()], child: DshApp()));

    await step('welcome', () async {
      if (!await waitFor(find.byType(WelcomePage), seconds: 30)) throw StateError('no welcome page');
      await frames(800);
    });
    await step('ios-onboarding', () async {
      await tapAndSettle(find.descendant(of: find.byType(WelcomePage), matching: find.byType(FilledButton)));
      for (final k in ['remote-only-google', 'remote-only-direct', 'remote-only-other']) {
        if (!await waitFor(find.byKey(ValueKey(k)), seconds: 10)) throw StateError('missing card $k');
      }
    });
    await step('direct-form-google', () async {
      await tapAndSettle(find.byKey(const ValueKey('remote-only-continue')), 1500);
      if (!await waitFor(find.byKey(const ValueKey('direct-google')))) throw StateError('no Google block');
    }, recover: false);
    await step('direct-form-google-back', () async {
      rootNav().pop();
      await frames(1000);
      if (!await waitFor(find.byKey(const ValueKey('remote-only-direct')))) throw StateError('not back on the cards');
    }, recover: false);
    await step('direct-form', () async {
      await tapAndSettle(find.byKey(const ValueKey('remote-only-direct')), 500);
      await tapAndSettle(find.byKey(const ValueKey('remote-only-continue')), 1500);
      if (!await waitFor(find.byKey(const ValueKey('direct-url')))) throw StateError('no URL field');
    }, recover: false);

    if (_live) {
      await step('direct-connect', () async {
        await tester.enterText(find.byKey(const ValueKey('direct-url')), _url);
        await tester.enterText(find.byKey(const ValueKey('direct-token')), _token);
        await frames(300);
        FocusManager.instance.primaryFocus?.unfocus();
        await frames(600);
        await tapAndSettle(find.byKey(const ValueKey('direct-save')), 500);
        // Test, save, first run over → the home shell.
        if (!await waitFor(find.byType(HomeShell), seconds: 60)) throw StateError('did not reach home after saving');
        await frames(2500);
      }, recover: false);
    } else {
      await step('skip-onboarding', () async {
        rootNav().pop();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('onboarding_welcome_seen', true);
        await prefs.setBool('onboarding_local_declined', true);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(const ProviderScope(observers: [_BuildPhaseObserver()], child: DshApp()));
        if (!await waitFor(find.byType(HomeShell), seconds: 30)) throw StateError('no home shell');
        await frames(1500);
      }, recover: false);
    }

    await step('drawer', () async {
      await openDrawer();
      if (_live) {
        final session = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> && RegExp(r'^session-(?!delete)').hasMatch((w.key! as ValueKey<String>).value),
        );
        if (!await waitFor(session, seconds: 40)) throw StateError('no sessions listed from the host');
      }
      await frames(800);
    });
    if (_live) {
      await step('session-open', () async {
        final session = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> && RegExp(r'^session-(?!delete)').hasMatch((w.key! as ValueKey<String>).value),
        );
        await tapAndSettle(session, 5000);
      });
    }
    if (_live) {
      // A conversation with a picture (sent, or an image the agent made): open it, look, back.
      await step('session-file-preview', () async {
        final sessionKeys = <String>[];
        await openDrawer();
        for (final e
            in find
                .byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      RegExp(r'^session-(?!delete)').hasMatch((w.key! as ValueKey<String>).value),
                )
                .hitTestable()
                .evaluate()) {
          sessionKeys.add((e.widget.key! as ValueKey<String>).value);
        }
        final targets = [
          find.descendant(of: find.byType(SentAttachments), matching: find.byType(Image)),
          // Images only: a PDF previews in a Quick Look platform view, under which
          // the test's frames and screenshots stall.
          find.byWidgetPredicate(
            (w) => w is ArtifactTile && w.artifact.kind == ArtifactKind.image && artifactPreviewable(w.artifact),
          ),
        ];
        for (final key in sessionKeys.take(14)) {
          await openDrawer();
          final tile = find.byKey(ValueKey(key));
          if (tile.hitTestable().evaluate().isEmpty) continue;
          await tester.tap(tile.hitTestable().first);
          await frames(3500);
          for (var page = 0; page < 6; page++) {
            for (final target in targets) {
              final hit = target.hitTestable();
              if (hit.evaluate().isEmpty) continue;
              final nav = Navigator.of(tester.element(hit.first));
              final back = topRoute(nav);
              final what = tester.widget(hit.first).runtimeType;
              await tester.tap(hit.first);
              await frames(3500);
              if (topRoute(nav) == back) throw StateError('tapping the file opened no page');
              // No screenshot: the picture is the person's own content (a photo of a
              // password turned up in the first run).
              steps.add({'step': 'session-file-preview: opened $what from $key', 'ok': true});
              nav.popUntil((r) => r == back);
              await frames(1000);
              return;
            }
            // Older messages: the list grows upwards.
            final chat = tester.getRect(find.byType(HomeShell));
            await tester.dragFrom(Offset(chat.center.dx, chat.top + chat.height * 0.3), const Offset(0, 450));
            await frames(1200);
          }
        }
        throw _Skip('no picture in the first ${sessionKeys.length} conversations');
      }, shoot: false);
    }
    await step('host-switcher', () async {
      await openDrawer();
      await tapAndSettle(find.byKey(const ValueKey('identity-host-switcher')), 1500);
    });
    await step('host-switcher-close', () async => home(), shoot: false);

    await step('settings', () async {
      await openDrawer();
      await tapAndSettle(
        find.descendant(of: find.byType(SessionsDrawer), matching: find.byIcon(AppIcons.settings)),
        1800,
      );
    }, recover: false);
    await walk(SettingsPageId.hub, 'settings');
    await step('settings-close', () async => home(), shoot: false);

    final shown = <DrawerDestination>[];
    await step('quick-panel', () async {
      await openQuickPanel();
      shown.addAll(
        DrawerDestination.values.where((d) => find.byKey(ValueKey('quick-panel-${d.name}')).evaluate().isNotEmpty),
      );
      steps.add({'step': 'quick-panel items: ${shown.map((d) => d.name).join(',')}', 'ok': shown.isNotEmpty});
    });
    await step('quick-panel-close', () async => home(), shoot: false);
    for (final d in shown) {
      final row = find.byKey(ValueKey('quick-panel-${d.name}'));
      await step('quick-panel/${d.name}', () async {
        await openQuickPanel();
        await tapAndSettle(row, 2500);
      });
      await step('quick-panel/${d.name}-back', () async => home(), shoot: false);
    }

    // Last, as the system share sheet can't be closed from here: 设置 › 诊断 › 分享诊断包.
    // On iPad the popover should point at the card (lib/ui/common/share_origin.dart).
    await step('share-sheet', () async {
      await home();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => settingsPage(SettingsPageId.diagnostics))));
      await frames(1500);
      await tapAndSettle(
        find.descendant(of: find.byType(DiagnosticsExportCard), matching: find.byIcon(AppIcons.share)),
        4000,
      );
    }, recover: false);

    // ── Report, clean up, verdict.
    await tester.pumpWidget(const SizedBox());
    await frames(300);
    appErrorCapture.uninstall();
    FlutterError.onError = previousFlutter;
    PlatformDispatcher.instance.onError = previousPlatform;
    debugPrint = previousPrint;
    await const FlutterSecureStorage().deleteAll();
    await (await SharedPreferences.getInstance()).clear();

    final failed = steps.where((s) => s['ok'] == false).map((s) => s['step']).toList();
    final report = <String, dynamic>{
      'live': _live,
      'screenshots': shot,
      'steps': steps,
      'errors': errors,
      'missingPlugin': errors.where((e) => e.contains('MissingPluginException')).length,
    };
    await File('$out/report.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    binding.reportData = null;
    // sim-smoke-mac.zsh copies the folder out while the app is still installed.
    debugPrint('SMOKE_REPORT_WRITTEN');
    await Future<void>.delayed(const Duration(seconds: 4));
    debugPrint('SMOKE steps=${steps.length} failed=${failed.length} errors=${errors.length} shots=$shot');
    if (failed.isNotEmpty) errors.add('failed steps: ${failed.join(', ')}');
  }
}
