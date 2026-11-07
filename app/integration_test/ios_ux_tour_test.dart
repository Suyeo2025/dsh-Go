// iOS UX tour: screenshots of every screen the remote-only build shows, for
// the product / interaction review. Read-only on the host: nothing is sent,
// no host or conversation setting is changed, no terminal is started (the
// terminal page is opened only for a conversation that already has one).
// Run by tooling/ios/sim-smoke.sh --tour [--dark] [--ipad] (flutter test on a
// simulator); results in logs/ux-tour/<variant>/: NNN-<name>.png and
// tour.json (what each picture is, and the problems noticed on the way).
//
// Defines: SMOKE_OUT (host folder, else the app's Documents), SMOKE_DIRECT_URL /
// SMOKE_DIRECT_TOKEN (the real host; the token never reaches a file), TOUR_VARIANT
// (iphone-light / iphone-dark / ipad), TOUR_LANDSCAPE (true: the whole tour on
// its side).
//
// Privacy: a picture is not taken when the screen shows something that looks
// like a secret (password / token / key patterns) or a photo the person sent,
// and conversations whose title points at credentials are never opened.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/app.dart';
import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/l10n/l10n.dart' show appL10n;
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/state/terminal_state.dart' show terminalBackendProvider;
import 'package:dsh_app/ui/chat/chat_list.dart' show ChatList;
import 'package:dsh_app/ui/chat/mention/mention_picker.dart' show MentionPicker;
import 'package:dsh_app/ui/chat/model_sheet.dart' show ModelChip;
import 'package:dsh_app/ui/chat/slash_palette.dart' show SlashPalette;
import 'package:dsh_app/ui/chat/widgets/approval_card.dart' show ApprovalCard;
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart' show ArtifactCard, ArtifactTile;
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart' show AssistantMessage;
import 'package:dsh_app/ui/chat/widgets/attachments.dart' show AttachButton, SentAttachments;
import 'package:dsh_app/ui/chat/widgets/change_card.dart' show ChangeCard;
import 'package:dsh_app/ui/chat/widgets/permission_pill.dart' show PermissionPill, StripRiskChip;
import 'package:dsh_app/ui/chat/widgets/question_card.dart' show QuestionCard;
import 'package:dsh_app/ui/chat/widgets/tool_row.dart' show ToolGroup, ToolRow;
import 'package:dsh_app/ui/common/capsule_chip.dart' show CapsuleChoiceChip;
import 'package:dsh_app/ui/common/third_party_licenses.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart' show GlassSegments, SessionDetailPage;
import 'package:dsh_app/ui/session/session_tab.dart';
import 'package:dsh_app/ui/settings/appearance/font_picker.dart' show FontEntryTile, FontSheet;
import 'package:dsh_app/ui/settings/font_licenses.dart';
import 'package:dsh_app/ui/settings/index/settings_pages.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart' show DrawerViewButton;
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/page_frame.dart' show GlassIconButton;
import 'package:dsh_app/ui/shell/quick_panel.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart' show SessionSearchBar;
import 'package:dsh_app/state/drawer_view_state.dart' show DrawerLayout, drawerViewProvider;
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart' show TerminalPage;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;

const _out = String.fromEnvironment('SMOKE_OUT');
const _url = String.fromEnvironment('SMOKE_DIRECT_URL');
const _token = String.fromEnvironment('SMOKE_DIRECT_TOKEN');
const _variant = String.fromEnvironment('TOUR_VARIANT', defaultValue: 'iphone-light');
const _landscape = bool.fromEnvironment('TOUR_LANDSCAPE');

/// `TOUR_ONLY=drawer,settings` (sim-smoke.sh --tour --only=…): those parts alone.
const _only = String.fromEnvironment('TOUR_ONLY');
bool _runs(String part) => _only.isEmpty || _only.split(',').contains(part);

String _scrub(String s) => _token.isEmpty ? s : s.replaceAll(_token, '<token>');

/// Text that looks like a credential on screen: the picture is skipped.
final _secret = RegExp(
  r'(密码|口令|password|passwd|pwd)\s*[:：=是为]\s*\S'
  r'|token=[A-Za-z0-9]'
  r'|\bsk-[A-Za-z0-9_-]{16,}'
  r'|Bearer\s+[A-Za-z0-9._-]{16,}'
  r'|-----BEGIN [A-Z ]*PRIVATE KEY'
  r'|\bAKIA[0-9A-Z]{16}\b'
  r'|\bgh[pousr]_[A-Za-z0-9]{20,}',
  caseSensitive: false,
);

/// Conversation titles not to open (what they hold is likely credentials).
final _riskyTitle = RegExp(r'密码|口令|password|token|密钥|凭据|credential|宽带|账号|secret|api ?key', caseSensitive: false);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS UX tour', timeout: const Timeout(Duration(minutes: 45)), (tester) async {
    final tour = _Tour(tester, binding);
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    final done = Completer<void>();
    runZonedGuarded(
      () => tour.run().then(
        (_) => done.complete(),
        onError: (Object e, StackTrace s) {
          tour.problem('tour', 'aborted: ${_scrub('$e')}');
          done.complete();
        },
      ),
      (e, s) => tour.problem(tour.current, 'uncaught: ${_scrub('$e')}'),
    );
    await done.future;
    appErrorCapture.uninstall();
    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;
    await tour.finish();
    // A tour reports; it fails only when it could not run at all.
    expect(tour.shots, isNotEmpty);
  });
}

class _Tour {
  _Tour(this.tester, this.binding);

  final WidgetTester tester;
  final IntegrationTestWidgetsFlutterBinding binding;

  String out = '';
  String current = 'boot';

  /// Landscape laid out by resizing the Flutter view (the iPad simulator can't be
  /// turned from the command line, and an iPad app that supports multitasking
  /// ignores orientation requests): pictures then come from the layer tree.
  bool emulatedLandscape = false;
  int _n = 0;
  final shots = <Map<String, Object?>>[];
  final problems = <Map<String, String>>[];
  final skipped = <Map<String, String>>[];

  void problem(String where, String what) {
    final text = _scrub(what);
    if (problems.any((p) => p['where'] == where && p['what'] == text)) return;
    problems.add({'where': where, 'what': text});
    debugPrint('TOUR_PROBLEM [$where] ${text.split('\n').first}');
  }

  // ── Frames and finders ──

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
    await closeDrawer();
  }

  /// Pops the top route of the root navigator (a sheet, a page).
  Future<void> back([int ms = 1000]) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await rootNav().maybePop();
    await frames(ms);
  }

  Future<bool> reveal(Finder f) async {
    for (final dir in [-1.0, 1.0]) {
      for (var i = 0; i < 25; i++) {
        if (f.evaluate().isNotEmpty) {
          await Scrollable.ensureVisible(tester.element(f.first), alignment: 0.5);
          await frames(400);
          return true;
        }
        final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
        if (lists.evaluate().isEmpty) return false;
        final state = tester.state<ScrollableState>(lists.last);
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

  // ── Pictures ──

  String visibleText() {
    final parts = <String>[];
    for (final e in find.byType(RichText).evaluate()) {
      parts.add((e.widget as RichText).text.toPlainText());
    }
    for (final e in find.byType(EditableText).evaluate()) {
      final w = e.widget as EditableText;
      if (!w.obscureText) parts.add(w.controller.text);
    }
    return parts.join('\n');
  }

  /// One picture of what is on screen, unless it shows something private.
  Future<void> shot(String name, String what) async {
    await frames(500);
    final text = visibleText();
    if (_secret.hasMatch(text) || (_token.isNotEmpty && text.contains(_token))) {
      skipped.add({'name': name, 'why': 'looks like a credential on screen'});
      debugPrint('TOUR_SKIP $name: credential-like text');
      return;
    }
    if (find
        .descendant(of: find.byType(SentAttachments), matching: find.byType(Image))
        .hitTestable()
        .evaluate()
        .isNotEmpty) {
      skipped.add({'name': name, 'why': 'a photo the person sent is on screen'});
      debugPrint('TOUR_SKIP $name: sent photo');
      return;
    }
    _n++;
    final file = '${_n.toString().padLeft(3, '0')}-${name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_')}.png';
    try {
      // The whole device screen (keyboard, status bar, system sheets): sim-smoke-mac.zsh
      // answers TOUR_CAPTURE with `simctl io screenshot` into this folder. Without it
      // (or when it doesn't come), the Flutter view alone.
      var how = 'device';
      final target = File('$out/$file');
      if (emulatedLandscape) {
        how = 'flutter-layer';
        await target.writeAsBytes(await _layerPng());
      } else {
        debugPrint('TOUR_CAPTURE $file');
      }
      for (var i = 0; i < 40 && !emulatedLandscape && !(await target.exists() && await target.length() > 0); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!emulatedLandscape && !(await target.exists() && await target.length() > 0)) {
        how = 'flutter';
        final bytes = await binding.takeScreenshot(file);
        (binding.reportData?['screenshots'] as List?)?.clear();
        await target.writeAsBytes(bytes);
      }
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      shots.add({'file': file, 'what': what, 'screen': '${size.width.round()}x${size.height.round()}', 'capture': how});
      debugPrint('TOUR_SHOT $file');
    } catch (e) {
      problem(current, 'screenshot $file failed: $e');
    }
    // A spinner still up after the screen had time to load.
    final spinners = find.byWidgetPredicate((w) => w is CircularProgressIndicator || w is CupertinoActivityIndicator);
    if (spinners.hitTestable().evaluate().isNotEmpty) {
      await frames(6000);
      if (spinners.hitTestable().evaluate().isNotEmpty) problem(name, 'still loading (spinner) 6.5 s after opening');
    }
  }

  /// The app's own layers as a PNG (the whole Flutter view, physical pixels).
  Future<List<int>> _layerPng() async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    // The root layer carries the device-pixel-ratio transform: its own space is physical pixels.
    final image = await layer.toImage(Offset.zero & tester.view.physicalSize);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// A part of the tour: failures are noted and the tour goes on.
  Future<void> part(String name, Future<void> Function() body, {bool recover = true}) async {
    final outer = current;
    current = name;
    debugPrint('TOUR_PART $name');
    try {
      await body();
    } on _NotHere catch (e) {
      skipped.add({'name': name, 'why': e.why});
      debugPrint('TOUR_SKIP $name: ${e.why}');
    } catch (e) {
      problem(name, 'could not finish: ${e.toString().split('\n').first}');
      if (recover) {
        try {
          await home();
        } catch (_) {}
      }
    }
    current = outer;
  }

  // ── Conversations ──

  /// The conversations listed in the drawer: key, id, title.
  Future<List<({String key, String id, String title})>> sessions() async {
    await openDrawer();
    final out = <({String key, String id, String title})>[];
    final tiles = find.byElementPredicate(_isSessionTile);
    for (final e in tiles.evaluate()) {
      final key = (e.widget.key! as ValueKey<String>).value;
      final title = find
          .descendant(of: find.byElementPredicate((x) => x == e), matching: find.byType(RichText))
          .evaluate()
          .map((t) => (t.widget as RichText).text.toPlainText())
          .join(' ');
      out.add((key: key, id: key.substring('session-'.length), title: title));
    }
    return out;
  }

  Future<void> openSession(String key) async {
    await openDrawer();
    final tile = find.byKey(ValueKey(key));
    if (!await reveal(tile)) throw StateError('conversation $key not in the drawer');
    await tester.tap(tile.hitTestable().first);
    await frames(3500);
    await closeDrawer();
  }

  ScrollPosition? chatPosition() {
    final s = find.descendant(of: find.byType(ChatList), matching: find.byType(Scrollable));
    return s.evaluate().isEmpty ? null : tester.state<ScrollableState>(s.first).position;
  }

  /// Older messages until [f] shows (slow drags, no fling); true when found.
  Future<bool> scrollChatTo(Finder f, {int pages = 12}) async {
    for (var page = 0; page < pages; page++) {
      if (f.hitTestable().evaluate().isNotEmpty) {
        await Scrollable.ensureVisible(tester.element(f.hitTestable().first), alignment: 0.4);
        await frames(600);
        return true;
      }
      if (find.byType(ChatList).evaluate().isEmpty) return false;
      final list = tester.getRect(find.byType(ChatList));
      final finger = await tester.startGesture(Offset(list.left + 24, list.top + list.height * 0.3));
      for (var i = 0; i < 20; i++) {
        await finger.moveBy(const Offset(0, 18));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 200));
      await finger.up();
      await frames(900);
    }
    return f.hitTestable().evaluate().isNotEmpty;
  }

  Future<void> toBottom() async {
    final p = chatPosition();
    if (p == null) return;
    p.jumpTo(p.maxScrollExtent);
    await frames(800);
  }

  // ── The tour ──

  Future<void> run() async {
    for (final candidate in [_out, '${(await getApplicationDocumentsDirectory()).path}/ux-tour']) {
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

    FlutterError.onError = (d) {
      final text = '${d.exception}'.contains('overflowed')
          ? d
                .toString()
                .split('\n')
                .where((l) => l.contains('overflowed') || l.contains('file:///'))
                .take(3)
                .join(' | ')
          : '${d.exception}'.split('\n').first;
      problem(current, 'FlutterError: $text');
    };
    PlatformDispatcher.instance.onError = (e, s) {
      problem(current, 'uncaught: $e');
      return true;
    };

    if (_landscape) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
      await Future<void>.delayed(const Duration(seconds: 2));
      final p = tester.view.physicalSize;
      if (p.height > p.width) {
        emulatedLandscape = true;
        tester.view.physicalSize = Size(p.height, p.width);
        debugPrint('TOUR landscape emulated: ${tester.view.physicalSize}');
      }
    }

    await (await SharedPreferences.getInstance()).clear();
    await const FlutterSecureStorage().deleteAll();
    appErrorCapture.install();
    await Future.wait([AppLanguageController.load(), LaunchController.begin()]);
    registerThirdPartyLicenses();
    registerFontLicenses();
    await tester.pumpWidget(const ProviderScope(child: DshApp()));

    await onboarding();
    if (find.byType(HomeShell).evaluate().isEmpty) {
      problem('onboarding', 'never reached the home screen; tour stops');
      return;
    }
    if (_runs('home')) await part('home', () => shot('home-new-chat', '主界面：新对话（空会话）'));
    if (_runs('composer')) await composer(null);
    if (_runs('drawer')) await drawer();
    if (_runs('chats')) await chats();
    if (_runs('quick-panel')) await quickPanel();
    if (_runs('settings')) await settings();
    if (_runs('web')) await web();
    if (_only.split(',').contains('web-drawer')) await webDrawer();
    if (!_landscape && _runs('landscape')) await landscape();
  }

  Future<void> onboarding() async {
    await part('onboarding', () async {
      if (!await waitFor(find.byType(WelcomePage), seconds: 40)) throw StateError('no welcome page');
      await frames(1000);
      await shot('onboarding-welcome', '首次引导：欢迎页');
      await tapAndSettle(find.descendant(of: find.byType(WelcomePage), matching: find.byType(FilledButton)));
      await waitFor(find.byKey(const ValueKey('remote-only-google')));
      await shot('onboarding-connect', '首次引导：连接你的 DSH（Google / 直连 / 其他方式）');
      await tapAndSettle(find.byKey(const ValueKey('remote-only-continue')), 1500);
      await waitFor(find.byKey(const ValueKey('direct-google')));
      await shot('onboarding-google-form', '首次引导：用 Google 登录（登录地址）');
      await back();
      await tapAndSettle(find.byKey(const ValueKey('remote-only-other')), 500);
      await shot('onboarding-other-selected', '首次引导：选中「其他方式」');
      await tapAndSettle(find.byKey(const ValueKey('remote-only-continue')), 2000);
      await shot('onboarding-other-hosts', '首次引导：其他方式 → 远程主机列表（SSH / DSH Remote）');
      await back(1500);
      await tapAndSettle(find.byKey(const ValueKey('remote-only-direct')), 500);
      await tapAndSettle(find.byKey(const ValueKey('remote-only-continue')), 1500);
      await waitFor(find.byKey(const ValueKey('direct-url')));
      await shot('onboarding-direct-form', '首次引导：添加直连主机（空表单）');
      if (_url.isEmpty || _token.isEmpty) throw const _NotHere('no SMOKE_DIRECT_URL / TOKEN: offline tour');
      await tester.enterText(find.byKey(const ValueKey('direct-url')), _url);
      await tester.enterText(find.byKey(const ValueKey('direct-token')), _token);
      await frames(500);
      await shot('onboarding-direct-filled-keyboard', '首次引导：直连表单已填写（令牌遮挡）+ 键盘');
      FocusManager.instance.primaryFocus?.unfocus();
      await frames(800);
      await tapAndSettle(find.byKey(const ValueKey('direct-save')), 500);
      await shot('onboarding-direct-testing', '首次引导：保存时的连接测试进度');
      if (!await waitFor(find.byType(HomeShell), seconds: 60)) throw StateError('not home after saving');
      await frames(3000);
    }, recover: false);
  }

  /// Composer states on the open chat ([sessionId] null: a new chat).
  Future<void> composer(String? sessionId) async {
    final tag = sessionId == null ? 'new' : 'session';
    await part('composer-$tag', () async {
      final field = find.descendant(of: find.byType(HomeShell), matching: find.byType(EditableText));
      if (!await waitFor(field)) throw StateError('no composer');
      await tester.showKeyboard(field.last);
      await frames(1500);
      await shot('composer-$tag-keyboard', '输入框：键盘弹起（${sessionId == null ? '新对话' : '已有会话'}）');
      await tester.enterText(field.last, '/');
      await frames(1500);
      if (find.byType(SlashPalette).evaluate().isEmpty) problem('composer-$tag', '「/」 opened no command palette');
      await shot('composer-$tag-slash', '输入框：/ 命令菜单');
      await tester.enterText(field.last, '@');
      await frames(2000);
      if (find.byType(MentionPicker).evaluate().isEmpty) problem('composer-$tag', '「@」 opened no mention picker');
      await shot('composer-$tag-mention', '输入框：@ 提及菜单');
      await tester.enterText(field.last, '');
      FocusManager.instance.primaryFocus?.unfocus();
      await frames(1200);
    });
    await part('attach-$tag', () async {
      final attach = find.byType(AttachButton);
      if (attach.hitTestable().evaluate().isEmpty) throw const _NotHere('no attach key here');
      final before = rootNav().canPop();
      await tester.tap(attach.hitTestable().first);
      await frames(1500);
      await shot('composer-$tag-attach', '输入框：附件菜单');
      if (rootNav().canPop() != before) await back();
    });
    await part('model-$tag', () async {
      final chip = find.byType(ModelChip);
      if (chip.hitTestable().evaluate().isEmpty) throw const _NotHere('no model chip here');
      await tester.tap(chip.hitTestable().first);
      await frames(2000);
      await shot('composer-$tag-model', '模型选择（只看，不改）');
      await back();
    });
    if (sessionId != null) {
      await part('permission-$tag', () async {
        final pill = find.byWidgetPredicate((w) => w is PermissionPill || w is StripRiskChip);
        if (pill.hitTestable().evaluate().isEmpty) throw const _NotHere('no permission pill on this conversation');
        await tester.tap(pill.hitTestable().first);
        await frames(1800);
        await shot('composer-$tag-permission', '权限选择（只看，不改）');
        await back();
      });
    }
  }

  /// The wave-2 drawer: 正在发生, the time / tree switch, the workspace tree, the iPad outline.
  Future<void> drawerWave2() async {
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    final happening = find.byKey(const ValueKey('happening'));
    final rows = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('happening-session'),
    );
    debugPrint('TOUR_HAPPENING section=${happening.evaluate().isNotEmpty} rows=${rows.evaluate().length}');
    if (happening.evaluate().isNotEmpty) {
      await Scrollable.ensureVisible(tester.element(happening), alignment: 0);
      await frames(800);
      await shot('drawer-happening', '抽屉：正在发生（运行中 / 待确认）');
    } else {
      skipped.add({'name': 'drawer-happening', 'why': 'nothing running or waiting on the host now'});
    }
    final views = container.read(drawerViewProvider.notifier);
    final was = container.read(drawerViewProvider).layout;
    await views.setLayout(DrawerLayout.tree);
    await frames(3000);
    await shot('drawer-tree', '抽屉：工作区树');
    final groups = find.byType(Scrollable);
    if (groups.evaluate().isNotEmpty) {
      await tester.drag(find.byType(SessionsDrawer), const Offset(0, -500));
      await frames(1200);
      await shot('drawer-tree-scrolled', '抽屉：工作区树（往下）');
      await tester.drag(find.byType(SessionsDrawer), const Offset(0, 1500));
      await frames(800);
    }
    await views.setLayout(was);
    await frames(1200);
    final outline = find.byKey(const ValueKey('outline-happening'));
    if (outline.evaluate().isNotEmpty) {
      await shot('outline', 'iPad：侧栏大纲列');
      for (final key in ['outline-happening', 'outline-archived', 'outline-all']) {
        final f = find.byKey(ValueKey(key));
        if (f.hitTestable().evaluate().isEmpty) continue;
        await tester.tap(f.hitTestable().first);
        await frames(1500);
        if (key != 'outline-all') await shot('outline-${key.substring(8)}', 'iPad 大纲列：${key.substring(8)}');
        // 已归档 is a page of its own over the chat.
        if (key == 'outline-archived') await back(1500);
      }
    }
  }

  Future<void> drawer() async {
    await part('drawer', () async {
      await openDrawer();
      // The list (and 正在发生 over it) comes in after the drawer opens: shoot it loaded.
      if (!await waitFor(find.byElementPredicate(_isSessionTile), seconds: 40)) {
        problem('drawer', 'the conversation list did not load in 40 s');
      }
      await frames(2500);
      await shot('drawer', '抽屉：会话列表');
      await drawerWave2();
      final filters = find.descendant(of: find.byType(SessionsDrawer), matching: find.byType(CapsuleChoiceChip));
      final count = filters.evaluate().length;
      for (var i = 1; i < count; i++) {
        await tester.tap(filters.at(i));
        await frames(1500);
        final label = (tester.widget(filters.at(i)) as CapsuleChoiceChip).label;
        await shot('drawer-filter-$i', '抽屉：筛选「$label」');
      }
      if (count > 0) {
        await tester.tap(filters.first);
        await frames(1000);
      }
      final view = find.byType(DrawerViewButton);
      if (view.hitTestable().evaluate().isNotEmpty) {
        await tester.tap(view.hitTestable().first);
        await frames(1500);
        await shot('drawer-view-options', '抽屉：对话列表视图选项');
        await back();
        await openDrawer();
      } else {
        problem('drawer', 'no 视图选项 key');
      }
      final search = find.byType(SessionSearchBar);
      if (search.hitTestable().evaluate().isNotEmpty) {
        await tester.tap(search.hitTestable().first);
        await frames(2000);
        await shot('drawer-search', '抽屉：搜索对话');
        final field = find.byType(EditableText);
        if (field.evaluate().isNotEmpty) {
          await tester.enterText(field.first, 'iOS');
          await frames(2500);
          await shot('drawer-search-results', '抽屉：搜索「iOS」的结果');
          await tester.enterText(field.first, '');
        }
        await back();
      }
      await openDrawer();
      await tapAndSettle(find.byKey(const ValueKey('identity-host-switcher')), 1500);
      await shot('host-switcher', '主机切换器');
      await back();
    });
  }

  Future<void> chats() async {
    final all = (await sessions()).where((s) => !_riskyTitle.hasMatch(s.title)).toList();
    final excluded = (await sessions()).length - all.length;
    if (excluded > 0) {
      skipped.add({
        'name': 'conversations',
        'why': '$excluded conversation(s) not opened: title points at credentials',
      });
    }
    if (all.isEmpty) {
      problem('chats', 'no conversation to open');
      return;
    }
    // Waiting for an answer or approval / running: the tile's state dot.
    Future<String?> withDot(String dot) async {
      await openDrawer();
      for (final s in all) {
        final tile = find.byKey(ValueKey(s.key));
        if (find.descendant(of: tile, matching: find.byKey(ValueKey(dot))).evaluate().isNotEmpty) return s.key;
      }
      return null;
    }

    final pending = await withDot('pending');
    final running = await withDot('running');

    // The longest of the first ones.
    String? longest;
    var longestExtent = -1.0;
    await part('chat-measure', () async {
      for (final s in all.take(8)) {
        await openSession(s.key);
        final p = chatPosition();
        if (p == null) continue;
        final extent = p.maxScrollExtent - p.minScrollExtent;
        if (extent > longestExtent) {
          longestExtent = extent;
          longest = s.key;
        }
      }
    });
    final long = longest ?? all.first.key;

    await part('chat-long', () async {
      await openSession(long);
      await shot('chat-long-bottom', '聊天页：长会话（底部）');
      final p = chatPosition();
      if (p != null) {
        p.jumpTo(p.pixels - p.viewportDimension * 3);
        await frames(1500);
        await shot('chat-long-scrolled', '聊天页：长会话（往上翻，出现「回到底部」）');
      }
      await toBottom();
      final message = find.byType(AssistantMessage);
      if (await scrollChatTo(message, pages: 6)) {
        final target = message.hitTestable().evaluate().isNotEmpty ? message.hitTestable().last : message.last;
        // Its top left, a little in: the text, not a tool row folded inside.
        final r = tester.getRect(target);
        await tester.longPressAt(Offset(r.left + 40, r.top + math.min(24, r.height / 2)));
        await frames(1500);
        await shot('chat-message-menu', '长按消息的菜单');
        await back();
      } else {
        problem('chat-long', 'no assistant message on screen to long-press');
      }
    });
    await composer(long.substring('session-'.length));

    await part('chat-cards', () async {
      await openSession(long);
      final tool = find.byWidgetPredicate((w) => w is ToolGroup || w is ToolRow);
      if (await scrollChatTo(tool, pages: 10)) {
        await tester.tap(tool.hitTestable().first);
        await frames(1500);
        await shot('chat-tool-expanded', '聊天页：工具卡片展开');
      } else {
        skipped.add({'name': 'chat-tool-expanded', 'why': 'no tool row near the end of the longest conversation'});
      }
      Future<void> card(Finder f, String name, String what) async {
        for (final s in [long, ...all.map((s) => s.key).where((k) => k != long).take(5)]) {
          await openSession(s);
          if (await scrollChatTo(f, pages: 8)) {
            await shot(name, what);
            return;
          }
        }
        skipped.add({'name': name, 'why': 'none in the conversations looked at'});
      }

      await card(find.byType(ChangeCard), 'chat-change-card', '聊天页：改动卡');
      await card(
        find.byWidgetPredicate((w) => w is ArtifactCard || w is ArtifactTile),
        'chat-artifact-card',
        '聊天页：交付物卡',
      );
    });

    await part('chat-running', () async {
      if (running == null) throw const _NotHere('no conversation running now');
      await openSession(running);
      await toBottom();
      await shot('chat-streaming', '聊天页：正在生成的会话');
      await frames(3000);
      await shot('chat-streaming-later', '聊天页：正在生成（3 秒后）');
    });
    await part('chat-pending', () async {
      if (pending == null) throw const _NotHere('no conversation waiting for approval or an answer');
      await openSession(pending);
      final card = find.byWidgetPredicate((w) => w is ApprovalCard || w is QuestionCard);
      await scrollChatTo(card, pages: 4);
      await shot('chat-approval-question', '聊天页：审批 / 提问卡片（只看，不操作）');
    });

    await part('detail', () async {
      await openSession(long);
      final pill = find.byKey(const ValueKey('chat-title-pill'));
      if (find.byType(SessionDetailPage).hitTestable().evaluate().isEmpty) {
        final panelKey = find.byKey(const ValueKey('chat-panel-key'));
        await tapAndSettle(panelKey.hitTestable().evaluate().isNotEmpty ? panelKey : pill, 2500);
      }
      if (!await waitFor(find.byType(SessionDetailPage))) throw StateError('对话详情 did not open');
      for (final tab in SessionTab.values) {
        final label = find.descendant(of: find.byType(GlassSegments), matching: find.text(tab.label));
        if (label.hitTestable().evaluate().isEmpty) continue;
        await tester.tap(label.hitTestable().first);
        await frames(2500);
        await shot('detail-${tab.name}', '对话详情：「${tab.label}」');
        if (tab == SessionTab.files) {
          // Into the first folder of the workspace.
          final folder = find.descendant(of: find.byType(SessionDetailPage), matching: find.byIcon(AppIcons.folder));
          if (folder.hitTestable().evaluate().isNotEmpty) {
            await tester.tap(folder.hitTestable().first);
            await frames(2500);
            await shot('detail-files-folder', '对话详情：文件浏览（进入一个文件夹）');
            await back(1200);
          }
        }
      }
      await home();
    });
    await part('terminal', () async {
      // Only where one already runs: opening the page would start a shell.
      final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      String? withTerminal;
      for (final s in all.take(12)) {
        final backend = container.read(terminalBackendProvider(s.id));
        if (backend == null) continue;
        try {
          if ((await backend.list().timeout(const Duration(seconds: 8))).isNotEmpty) {
            withTerminal = s.key;
            break;
          }
        } catch (_) {}
      }
      if (withTerminal == null) throw const _NotHere('no conversation with a terminal already running');
      await openSession(withTerminal);
      unawaited(rootNav().push(TerminalPage.route(withTerminal.substring('session-'.length))));
      await frames(4000);
      await shot('terminal', '终端（已有终端的会话）');
      FocusManager.instance.primaryFocus?.unfocus();
      await back(1500);
    });
  }

  Future<void> quickPanel() async {
    await part('quick-panel', () async {
      await home();
      if (sidebar) throw const _NotHere('wide layout: no quick panel (the rail has its keys)');
      Future<void> open() async {
        final shell = tester.getRect(find.byType(HomeShell));
        final finger = await tester.startGesture(shell.center);
        for (var i = 0; i < 40; i++) {
          await finger.moveBy(const Offset(-6, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pump(const Duration(milliseconds: 400));
        await finger.up();
        await frames(1200);
      }

      await open();
      if (find.byType(QuickPanel).hitTestable().evaluate().isEmpty) throw StateError('quick panel did not open');
      await shot('quick-panel', '快捷面板');
      final rows = [
        for (final e
            in find
                .byWidgetPredicate(
                  (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('quick-panel-'),
                )
                .evaluate())
          (e.widget.key! as ValueKey<String>).value,
      ];
      for (final row in rows) {
        if (find.byKey(ValueKey(row)).hitTestable().evaluate().isEmpty) await open();
        await tapAndSettle(find.byKey(ValueKey(row)), 2500);
        await shot(row, '快捷面板 → ${row.substring('quick-panel-'.length)}');
        await home();
      }
    });
  }

  Future<void> settings() async {
    await part('settings', () async {
      await home();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => settingsPage(SettingsPageId.hub))));
      await frames(2000);
      await shot('settings', '设置首页');
      final hub = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
      if (hub.evaluate().isNotEmpty) {
        final p = tester.state<ScrollableState>(hub.last).position;
        if (p.maxScrollExtent > 0) {
          p.jumpTo(p.maxScrollExtent);
          await frames(800);
          await shot('settings-bottom', '设置首页（底部）');
          p.jumpTo(0);
          await frames(500);
        }
      }
      await walk(SettingsPageId.hub, 'settings');
    });
    await part('settings-font', () async {
      await home();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => settingsPage(SettingsPageId.hub))));
      await frames(1500);
      final tile = find.byType(FontEntryTile);
      if (!await reveal(tile)) throw StateError('no 字体 row');
      await tester.tap(tile.hitTestable().first);
      await frames(1800);
      if (find.byType(FontSheet).evaluate().isEmpty) throw StateError('字体 opened no sheet');
      await shot('settings-font-sheet', '设置 › 外观 › 字体（只看，不下载）');
      await back();
      await home();
    });
  }

  Future<void> walk(SettingsPageId page, String trail) async {
    final children = SettingsIndex.pages.values
        .where((m) => m.parent == page && SettingsIndex.hasPage(m.id) && SettingsIndex.has(m.entry))
        .toList();
    for (final m in children) {
      final name = '$trail-${m.id.name}';
      await part(name, () async {
        final nav = rootNav();
        Route<dynamic>? backTo;
        nav.popUntil((r) {
          backTo = r;
          return true;
        });
        final tile = find.byWidgetPredicate((w) => w is SettingsTile && w.spot?.id == SettingsIndex.entry(m.id).id);
        if (m.row && await reveal(tile) && tile.hitTestable().evaluate().isNotEmpty) {
          await tester.tap(tile.hitTestable().first);
        } else {
          unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => settingsPage(m.id))));
        }
        await frames(2200);
        await shot(
          name,
          '设置 › ${SettingsIndex.chain(m.id).skip(1).map((p) => SettingsIndex.page(p).title(appL10n)).join(' › ')}',
        );
        await walk(m.id, name);
        nav.popUntil((r) => r == backTo);
        await frames(800);
      }, recover: false);
    }
  }

  Future<void> web() async {
    await part('web', () async {
      await home();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => settingsPage(SettingsPageId.interface))));
      await frames(1500);
      await shot('web-entry', '设置 › 界面：「打开网页版」入口');
      final tile = find.byWidgetPredicate((w) => w is SettingsTile && w.spot?.id == Spots.openWeb.id);
      if (!await reveal(tile)) throw StateError('no 打开网页版 row');
      await tester.tap(tile.hitTestable().first);
      await frames(8000);
      await shot('web', '网页版（WebView）');
      await home();
    });
  }

  /// DSH Web's sidebar in the WebView (d9c45d30: the official _drawerMask hidden under the app's
  /// phone drawer). A simulator test can't put a finger on a WKWebView (Flutter's synthesized
  /// pointers never reach the platform view), so the page is asked through JS: what a touch at a
  /// point would land on (elementFromPoint), whether the list scrolls, and the app's own handlers
  /// fed the pointer events a touch makes.
  Future<void> webDrawer() async {
    await part('web-drawer', () async {
      await home();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => settingsPage(SettingsPageId.interface))));
      await frames(1500);
      final tile = find.byWidgetPredicate((w) => w is SettingsTile && w.spot?.id == Spots.openWeb.id);
      if (!await reveal(tile)) throw StateError('no 打开网页版 row');
      await tester.tap(tile.hitTestable().first);
      await frames(3000);
      final web = find.byType(WebViewWidget);
      if (!await waitFor(web, seconds: 20)) throw StateError('no WebView');
      final controller = (tester.widget(web.first) as WebViewWidget).platform.params.controller;
      Future<Object?> js(String body) async {
        try {
          final raw = await controller.runJavaScriptReturningResult('JSON.stringify((function(){$body})())');
          final text = raw is String ? raw : '$raw';
          final once = jsonDecode(text);
          return once is String ? jsonDecode(once) : once;
        } catch (e) {
          return {'error': '${e.runtimeType}'};
        }
      }

      const helpers = '''
        var f = document.querySelector('[data-slot="root"] > [class*="_frame"]');
        var side = f && f.querySelector('[class*="_sidebarCol"]');
        var rows = Array.prototype.slice.call(document.querySelectorAll('[role="treeitem"][class*="_sessionRow"]'));
        function scroller(el) {
          for (var e = el; e && e !== document.body; e = e.parentElement) {
            var o = getComputedStyle(e).overflowY;
            if ((o === 'auto' || o === 'scroll') && e.scrollHeight > e.clientHeight + 4) return e;
          }
          return null;
        }
        function where(x, y) {
          var t = document.elementFromPoint(x, y);
          if (!t) return 'nothing';
          if (side && side.contains(t)) return 'sidebar';
          var m = t.closest('[class*="_drawerMask"]');
          return m ? 'drawerMask' : (t.className && String(t.className).slice(0, 40)) || t.tagName;
        }
        function open() { return !!(window.__dshApp && window.__dshApp.sidebarOpen()); }
        // Read-only: another existing conversation of the open workspace (a sibling row of the
        // selected one), never one that would switch the workspace.
        function sameWorkspace() {
          var sel = rows.filter(function (r) { return /_selected/.test(r.className); })[0];
          if (!sel) return null;
          return rows.filter(function (r) { return r !== sel && r.parentElement === sel.parentElement; })[0] || null;
        }
        function touch(t, type, x, y) {
          t.dispatchEvent(new PointerEvent(type, {bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, pointerType: 'touch', isPrimary: true, pointerId: 7}));
        }
      ''';
      final result = <String, Object?>{};
      for (var i = 0; i < 40; i++) {
        final r = await js(
          '$helpers return {app: !!window.__dshApp, layout: document.documentElement.getAttribute("data-dsh-app-layout"), rows: rows.length};',
        );
        if (r is Map && r['app'] == true && (r['rows'] as num? ?? 0) > 0) {
          result['page'] = r;
          break;
        }
        await frames(500);
      }
      if (result['page'] == null) throw StateError('DSH Web did not come up with its conversation list');
      final drawerLayout = (result['page']! as Map)['layout'] == 'drawer';
      if ((result['page']! as Map)['layout'] == 'official') {
        await officialDrawer(js, helpers, result);
        return;
      }

      // Open: the app's menu key (the iPhone's drawer; on an iPad it unfolds the official sidebar).
      final folded = await js('return !(window.__dshApp && window.__dshApp.sidebarOpen());');
      result['startedFolded'] = folded;
      if (drawerLayout || folded == true) {
        debugPrint('WEB_DRAWER_PAGE ${jsonEncode(result['page'])} folded=$folded');
        final menu = find.byWidgetPredicate((w) => w is GlassIconButton && w.icon == AppIcons.menu);
        if (menu.hitTestable().evaluate().isNotEmpty) {
          await tester.tap(menu.hitTestable().first);
        } else {
          // No app menu key in this chrome (a wide page): the page's own toggle, as the key would.
          result['openedBy'] = 'page toggle (no app menu key)';
          await js('window.__dshApp && window.__dshApp.toggleSidebar(); return 1;');
        }
        await frames(1500);
      }
      // A secret-looking text anywhere on the page: no pictures of it.
      final secret = await js('return /${_secret.pattern.replaceAll('/', r'\/')}/i.test(document.body.innerText);');
      final mayShoot = secret != true;
      Future<void> webShot(String name, String what) async {
        // A programmatic click leaves the clicked key focused (:focus-visible shows its tooltip);
        // a finger doesn't. Blur first so the picture is what a tap leaves.
        await js('if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); return 1;');
        await frames(300);
        if (mayShoot) {
          await shot(name, what);
        } else {
          skipped.add({'name': name, 'why': 'credential-like text on the web page'});
        }
      }

      result['opened'] = await js('''$helpers
        var mask = f && f.querySelector('[class*="_drawerMask"]');
        var r = rows.length ? rows[Math.min(rows.length - 1, 3)].getBoundingClientRect() : null;
        return {
          open: open(),
          mask: mask ? getComputedStyle(mask).display : 'absent',
          rowHit: r ? where(r.left + r.width / 2, r.top + r.height / 2) : 'no row',
          listHit: side ? where(side.getBoundingClientRect().left + 60, innerHeight * 0.6) : 'no sidebar',
        };''');
      await webShot('web-drawer-open', '网页版：打开侧栏');
      // Scroll: the list's own scroller moves (a finger drag scrolls the same element).
      result['scroll'] = await js(
        '''$helpers
        var sc = rows.length ? scroller(rows[0]) : null;
        if (!sc) return {scrollable: false};
        var before = sc.scrollTop;
        sc.scrollTop = before + 400;
        var after = sc.scrollTop;
        var hit = sc.getBoundingClientRect();
        return {scrollable: true, height: sc.clientHeight, content: sc.scrollHeight, before: before, after: after,
                touchLandsOnList: sc.contains(document.elementFromPoint(hit.left + hit.width / 2, hit.top + hit.height / 2))};''',
      );
      await frames(800);
      await webShot('web-drawer-scrolled', '网页版：侧栏列表往下滚');
      await js('$helpers var sc = rows.length ? scroller(rows[0]) : null; if (sc) sc.scrollTop = 0; return 1;');
      if (drawerLayout) {
        // A tap beside the drawer (on the scrim): the app's handler closes it.
        result['tapBeside'] = await js('''$helpers
          var x = innerWidth - 24, y = innerHeight / 2, t = document.elementFromPoint(x, y);
          var landed = where(x, y);
          touch(t, 'pointerdown', x, y); touch(t, 'pointerup', x, y);
          return {landed: landed};''');
        await frames(1200);
        (result['tapBeside']! as Map)['closed'] = (await js('$helpers return !open();')) == true;
        await webShot('web-drawer-closed-by-scrim', '网页版：点侧栏右侧空白后收起');
        final menu = find.byWidgetPredicate((w) => w is GlassIconButton && w.icon == AppIcons.menu);
        await tester.tap(menu.hitTestable().first);
        await frames(1500);
      }
      // Pick a conversation (not the selected one): it opens and the drawer closes.
      result['pick'] = await js('''$helpers
        var row = sameWorkspace(); if (!row) return {skipped: 'no other conversation in the open workspace'};
        var r = row.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
        var landed = where(x, y);
        window.__pickPath = location.pathname + location.hash;
        row.click();
        return {landed: landed};''');
      await frames(3000);
      final after = await js(
        '$helpers return {open: open(), moved: (location.pathname + location.hash) !== window.__pickPath, selected: rows.filter(function (r) { return /_selected/.test(r.className); }).length};',
      );
      (result['pick']! as Map).addAll(after is Map ? after.cast<String, Object?>() : {'after': after});
      await webShot('web-drawer-picked', '网页版：点会话后打开并收起侧栏');
      debugPrint('WEB_DRAWER ${jsonEncode(result)}');
      skipped.add({'name': 'web-drawer-result', 'why': jsonEncode(result)});
      await home();
    });
  }

  /// DSH Web's own narrow drawer (layout "official", rc.5 frame[data-sidebar-drawer]): the app
  /// keeps one 36 pt button before the page's menu key and fades it while the drawer is open.
  Future<void> officialDrawer(Future<Object?> Function(String) js, String helpers, Map<String, Object?> result) async {
    const more = '''
      var seat = f && f.querySelector(':scope > [class*="_leadingSeat"]');
      var menu = seat && seat.querySelector('button');
      var mask = f && f.querySelector(':scope > [class*="_drawerMask"]');
      function bg(el) {
        for (var e = el; e; e = e.parentElement) {
          var c = getComputedStyle(e).backgroundColor;
          if (c && c !== 'rgba(0, 0, 0, 0)' && c !== 'transparent') return c;
        }
        return 'none';
      }
      function at(x, y) { var t = document.elementFromPoint(x, y); return {where: where(x, y), bg: bg(t)}; }
      function collapsed() { return f.hasAttribute('data-sidebar-collapsed'); }
    ''';
    final web = tester.getRect(find.byType(WebViewWidget).first);
    Rect? appButton() {
      final f = find.byKey(const ValueKey('web-controls-official'));
      return f.evaluate().isEmpty ? null : tester.getRect(f);
    }

    double? appOpacity() {
      final f = find.descendant(
        of: find.byKey(const ValueKey('web-controls-official')),
        matching: find.byType(AnimatedOpacity),
      );
      return f.evaluate().isEmpty ? null : (tester.widget(f.first) as AnimatedOpacity).opacity;
    }

    final secret = await js('return /${_secret.pattern.replaceAll('/', r'\\/')}/i.test(document.body.innerText);');
    Future<void> webShot(String name, String what) async {
      // A programmatic click leaves the clicked key focused (:focus-visible shows its tooltip);
      // a finger doesn't. Blur first so the picture is what a tap leaves.
      await js('if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); return 1;');
      await frames(300);
      if (secret != true) {
        await shot(name, what);
      } else {
        skipped.add({'name': name, 'why': 'credential-like text on the web page'});
      }
    }

    // Closed: the app's button and the page's menu key side by side on one line; the bars' bands
    // the page's colour.
    final closed = await js('''$helpers $more
      var m = menu && menu.getBoundingClientRect();
      return {drawerAttr: f.hasAttribute('data-sidebar-drawer'), collapsed: collapsed(),
        menu: m ? [m.left, m.top, m.width, m.height] : null,
        page: bg(document.querySelector('[data-slot="main"]') || f),
        status: at(innerWidth / 2, 4), gesture: at(innerWidth / 2, innerHeight - 6)};''');
    final c = closed is Map ? closed.cast<String, Object?>() : <String, Object?>{'error': closed};
    final button = appButton();
    final m = c['menu'];
    if (button != null && m is List && m.length == 4) {
      final menuRect = Rect.fromLTWH(
        web.left + (m[0] as num).toDouble(),
        web.top + (m[1] as num).toDouble(),
        (m[2] as num).toDouble(),
        (m[3] as num).toDouble(),
      );
      c['app'] = [button.left, button.top, button.width, button.height];
      c['overlap'] = button.overlaps(menuRect);
      c['gapPt'] = double.parse((menuRect.left - button.right).toStringAsFixed(1));
      c['centreDyPt'] = double.parse((menuRect.center.dy - button.center.dy).toStringAsFixed(1));
    }
    c['appOpacity'] = appOpacity();
    result['closed'] = c;
    await webShot('web-official-closed', '网页版（官方抽屉）：关闭状态，App 按钮 + 官方菜单键');

    Future<void> openDrawer() async {
      await js('$helpers $more if (menu) menu.click(); return 1;');
      await frames(1800);
    }

    await openDrawer();
    result['opened'] = {
      ...((await js('''$helpers $more
        var s = side && side.getBoundingClientRect(), k = mask && mask.getBoundingClientRect();
        var r = rows.length ? rows[Math.min(rows.length - 1, 3)].getBoundingClientRect() : null;
        return {collapsed: collapsed(), side: s ? [s.top, s.bottom, s.right] : null, height: innerHeight,
          mask: k ? [k.top, k.bottom, getComputedStyle(mask).display] : null,
          statusOverSide: at(20, 4), statusOverMask: at(innerWidth - 20, 4), gestureOverSide: at(20, innerHeight - 6),
          rowHit: r ? where(r.left + r.width / 2, r.top + r.height / 2) : 'no row'};''')) as Map? ??
              {})
          .cast<String, Object?>(),
      'appOpacity': appOpacity(),
    };
    await webShot('web-official-open', '网页版（官方抽屉）：打开');
    result['scroll'] = await js(
      '''$helpers
      var sc = rows.length ? scroller(rows[0]) : null;
      if (!sc) return {scrollable: false};
      var hit = sc.getBoundingClientRect();
      var lands = sc.contains(document.elementFromPoint(hit.left + hit.width / 2, hit.top + hit.height / 2));
      var before = sc.scrollTop; sc.scrollTop = before + 400;
      return {scrollable: true, height: sc.clientHeight, content: sc.scrollHeight, before: before, after: sc.scrollTop, touchLandsOnList: lands};''',
    );
    await frames(800);
    await webShot('web-official-scrolled', '网页版（官方抽屉）：列表往下滚');
    await js('$helpers var sc = rows.length ? scroller(rows[0]) : null; if (sc) sc.scrollTop = 0; return 1;');
    // Pick a conversation: it opens, the drawer folds, the app's button comes back.
    result['pick'] = await js('''$helpers $more
      var row = sameWorkspace(); if (!row) return {skipped: 'no other conversation in the open workspace'};
      var r = row.getBoundingClientRect();
      var landed = where(r.left + r.width / 2, r.top + r.height / 2);
      row.click();
      return {landed: landed};''');
    await frames(3000);
    (result['pick']! as Map)['after'] = await js(
      '$helpers $more return {collapsed: collapsed(), selected: rows.filter(function (r) { return /_selected/.test(r.className); }).length};',
    );
    (result['pick']! as Map)['appOpacity'] = appOpacity();
    await webShot('web-official-picked', '网页版（官方抽屉）：点会话后打开并收起');
    // Reopen, tap the mask beside the drawer: it folds.
    await openDrawer();
    result['mask'] = await js('''$helpers $more
      var x = innerWidth - 24, y = innerHeight / 2, t = document.elementFromPoint(x, y);
      var onMask = !!(mask && mask.contains(t));
      if (t) {
        t.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, clientX: x, clientY: y, pointerType: 'touch', isPrimary: true}));
        t.dispatchEvent(new PointerEvent('pointerup', {bubbles: true, clientX: x, clientY: y, pointerType: 'touch', isPrimary: true}));
        t.click();
      }
      return {onMask: onMask, collapsedBefore: collapsed()};''');
    await frames(1800);
    (result['mask']! as Map)['collapsedAfter'] = (await js('$helpers $more return collapsed();')) == true;
    (result['mask']! as Map)['appOpacity'] = appOpacity();
    await webShot('web-official-closed-by-mask', '网页版（官方抽屉）：点遮罩收起');
    debugPrint('WEB_DRAWER ${jsonEncode(result)}');
    skipped.add({'name': 'web-drawer-result', 'why': jsonEncode(result)});
    await home();
  }

  Future<void> landscape() async {
    await part('landscape', () async {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
      await frames(2500);
      await home();
      await shot('landscape-chat', '横屏：聊天页');
      await openDrawer();
      await shot('landscape-drawer', '横屏：抽屉');
      await closeDrawer();
      unawaited(rootNav().push(MaterialPageRoute<void>(builder: (_) => settingsPage(SettingsPageId.hub))));
      await frames(2000);
      await shot('landscape-settings', '横屏：设置首页');
      await home();
      final field = find.descendant(of: find.byType(HomeShell), matching: find.byType(EditableText));
      if (field.evaluate().isNotEmpty) {
        await tester.showKeyboard(field.last);
        await frames(1500);
        await shot('landscape-keyboard', '横屏：键盘弹起');
        FocusManager.instance.primaryFocus?.unfocus();
        await frames(800);
      }
    });
    await SystemChrome.setPreferredOrientations([]);
    await frames(1500);
  }

  Future<void> finish() async {
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpWidget(const SizedBox());
      await frames(300);
    } catch (_) {}
    await SystemChrome.setPreferredOrientations([]);
    await const FlutterSecureStorage().deleteAll();
    await (await SharedPreferences.getInstance()).clear();
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final report = {
      'variant': _variant,
      'landscape': _landscape,
      'landscapeEmulated': emulatedLandscape,
      'brightness': PlatformDispatcher.instance.platformBrightness.name,
      'screen': '${size.width.round()}x${size.height.round()}',
      'shots': shots,
      'skipped': skipped,
      'problems': problems,
    };
    if (out.isNotEmpty) {
      await File('$out/tour.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      await File('$out/.probe').delete().catchError((Object _) => File(''));
    }
    binding.reportData = null;
    debugPrint('SMOKE_REPORT_WRITTEN');
    debugPrint('TOUR shots=${shots.length} skipped=${skipped.length} problems=${problems.length}');
    await Future<void>.delayed(const Duration(seconds: 4));
  }
}

/// The part doesn't apply here (no such conversation, a layout without it).
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
