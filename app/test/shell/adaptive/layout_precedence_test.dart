// Three columns that don't fit: the side opened last stays
// (AdaptiveLayout.resolve's `prefer`), and the stored choice behind it
// (LayoutPrefs.prefer, written when a side is unfolded).
//
//   flutter test test/shell/adaptive/layout_precedence_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/ui/shell/adaptive/adaptive_layout.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// iPad Pro 11" / Air 13" in landscape, near enough.
const _ipad = Size(1376, 1032);

AdaptiveLayout _resolve(
  Size window, {
  LayoutSide? prefer,
  bool sidebarOpen = true,
  bool panelOpen = true,
  bool session = true,
}) => AdaptiveLayout.resolve(
  window: window,
  hasSession: session,
  sidebarOpen: sidebarOpen,
  panelOpen: panelOpen,
  prefer: prefer,
);

Future<LayoutPrefs> _loaded(ProviderContainer container) async {
  container.read(layoutPrefsProvider);
  for (var i = 0; i < 20 && !container.read(layoutPrefsProvider).loaded; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return container.read(layoutPrefsProvider);
}

void main() {
  group('resolve', () {
    test('first time on an iPad in landscape: sidebar and chat, the panel folded', () {
      final layout = _resolve(_ipad);
      expect(layout.left, LeftPane.sidebar);
      expect(layout.panelShown, isFalse);
      // Folded, not gone: the header's key unfolds it.
      expect(layout.panelAvailable, isTrue);
      expect(layout.detail, DetailPresentation.panel);
      // Room to spare: the sidebar takes its outline column beside the list.
      expect(layout.sidebarWidth, AdaptiveMetrics.sidebarWideWidth);
      expect(layout.chatRect.width, 1376 - AdaptiveMetrics.sidebarWideWidth);
      expect(layout.menuAction, MenuAction.collapse);
    });

    test('the sidebar opened last wins the same way', () {
      expect(_resolve(_ipad, prefer: LayoutSide.sidebar), _resolve(_ipad));
    });

    test('the panel opened last: it shows, the sidebar folds into the rail', () {
      final layout = _resolve(_ipad, prefer: LayoutSide.panel);
      expect(layout.panelShown, isTrue);
      expect(layout.left, LeftPane.rail);
      expect(layout.chatRect.width, 1376 - AdaptiveMetrics.railWidth - layout.panelWidth);
      // ≡ unfolds the sidebar again (which folds the panel), no overlay.
      expect(layout.sidebarFits, isTrue);
      expect(layout.menuAction, MenuAction.expand);
    });

    test('wide enough for all three: both show, whichever came last', () {
      for (final prefer in [null, LayoutSide.sidebar, LayoutSide.panel]) {
        final layout = _resolve(const Size(1600, 1000), prefer: prefer);
        expect(layout.left, LeftPane.sidebar, reason: '$prefer');
        expect(layout.panelShown, isTrue, reason: '$prefer');
        expect(layout.chatRect.width, greaterThanOrEqualTo(AdaptiveMetrics.chatBesideBoth));
      }
      // Three columns would leave the chat its reading width only from
      // about 1490: below, one side folds (1440 would leave it 700).
      expect(_resolve(const Size(1440, 1000)).panelShown, isFalse);
      expect(_resolve(const Size(1440, 1000), prefer: LayoutSide.panel).left, LeftPane.rail);
    });

    test('only one asked for: the preference does not matter', () {
      final noPanel = _resolve(_ipad, panelOpen: false, prefer: LayoutSide.panel);
      expect(noPanel.left, LeftPane.sidebar);
      expect(noPanel.panelShown, isFalse);
      final noSidebar = _resolve(_ipad, sidebarOpen: false);
      expect(noSidebar.left, LeftPane.rail);
      expect(noSidebar.panelShown, isTrue);
      expect(noSidebar.menuAction, MenuAction.expand);
    });

    test('too narrow for the sidebar at all: the rail and the panel, as before', () {
      final layout = _resolve(const Size(900, 700));
      expect(layout.left, LeftPane.rail);
      expect(layout.panelShown, isTrue);
      expect(layout.sidebarFits, isFalse);
      expect(layout.menuAction, MenuAction.overlay);
    });

    test('phones and medium windows are untouched', () {
      for (final size in [const Size(390, 844), const Size(744, 1133), const Size(915, 412)]) {
        for (final prefer in [null, LayoutSide.panel]) {
          final layout = _resolve(size, prefer: prefer);
          expect(layout.isExpanded, isFalse, reason: '$size');
          expect(layout.left, LeftPane.none);
          expect(layout.panelShown, isFalse);
        }
      }
      expect(_resolve(const Size(390, 844)).windowClass, WindowClass.compact);
    });
  });

  group('LayoutPrefs.prefer', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('nothing chosen at first', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final prefs = await _loaded(container);
      expect(prefs.prefer, isNull);
      expect(prefs.sidebarOpen, isTrue);
      expect(prefs.panelOpen, isTrue);
    });

    test('unfolding a side prefers it; folding leaves the choice; kept across launches', () async {
      final first = ProviderContainer();
      final controller = first.read(layoutPrefsProvider.notifier);
      await _loaded(first);
      await controller.setPanelOpen(true);
      expect(first.read(layoutPrefsProvider).prefer, LayoutSide.panel);
      await controller.setSidebarOpen(true);
      expect(first.read(layoutPrefsProvider).prefer, LayoutSide.sidebar);
      await controller.setSidebarOpen(false);
      expect(first.read(layoutPrefsProvider).prefer, LayoutSide.sidebar);
      await controller.togglePanel();
      await controller.togglePanel();
      expect(first.read(layoutPrefsProvider).prefer, LayoutSide.panel);
      first.dispose();

      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(LayoutPrefsController.preferKey), 'panel');
      final second = ProviderContainer();
      addTearDown(second.dispose);
      final prefs = await _loaded(second);
      expect(prefs.prefer, LayoutSide.panel);
      expect(prefs.sidebarOpen, isFalse);
    });

    test('an unknown stored value reads as nothing chosen', () async {
      SharedPreferences.setMockInitialValues({LayoutPrefsController.preferKey: 'bogus'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect((await _loaded(container)).prefer, isNull);
    });
  });
}
