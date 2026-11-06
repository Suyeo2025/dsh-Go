// The window classes and the column plan of the home
// screen on tablets and foldables. Geometry follows DSH Web's AppFrame
// (`@deepseek-ai/dsh-client-ui-layout`): the right panel gives way first to
// keep the chat column wide enough. When the sidebar and the panel are both
// asked for and the chat would get too narrow between them, the side opened
// last stays and the other folds (the sidebar into the rail, the panel away).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Window size classes (Material 3 breakpoints), with one rule on top: a
/// window under [compactHeight] tall is [compact] whatever its width.
///
/// That is a phone on its side (915 × 412): wide, but with the status bar,
/// the header and the composer there is room for a few lines of chat, and
/// the keyboard takes half of it. Columns side by side would each get that
/// sliver; one centred column keeps the width for code and tables, the way
/// Android has always told phones from tablets (by the shortest side).
enum WindowClass {
  /// < 600, or under [compactHeight]: phones, upright or on their side. The
  /// conversation detail is a pushed page.
  compact,

  /// 600–840: an open foldable, a small tablet in portrait. The detail is a
  /// wide bottom sheet with two heights.
  medium,

  /// ≥ 840: tablets in landscape, large screens. The detail is a persistent
  /// right panel; the conversation list is a rail or a sidebar.
  expanded;

  static const mediumMin = 600.0;
  static const expandedMin = 840.0;

  /// Material 3's compact height: below it, a window is a phone on its side.
  static const compactHeight = 480.0;

  static WindowClass of(double width, [double height = double.infinity]) => height < compactHeight
      ? compact
      : width >= expandedMin
      ? expanded
      : width >= mediumMin
      ? medium
      : compact;

  /// [of] for a window [size].
  static WindowClass ofSize(Size size) => of(size.width, size.height);
}

/// What stands at the left edge of a wide window.
enum LeftPane {
  /// Nothing persistent: the conversation list is the pull-over drawer.
  none,

  /// A column of round keys (open the list, search, host, 网页版, 设置).
  rail,

  /// The conversation list itself, always shown.
  sidebar,
}

/// One of the two columns beside the chat: the one opened last wins when
/// both don't fit with a comfortable chat between them.
enum LayoutSide { sidebar, panel }

/// What the ≡ key does in the current layout.
enum MenuAction {
  /// Pull the drawer over everything (phones, or no room for the sidebar).
  overlay,

  /// Unfold the rail into the persistent sidebar.
  expand,

  /// Fold the persistent sidebar back into the rail.
  collapse,
}

/// How the conversation detail opens.
enum DetailPresentation { page, sheet, panel }

/// Column widths and margins, in logical pixels.
abstract final class AdaptiveMetrics {
  /// Round keys: 44, 12 from the edges like the header's.
  static const key = 44.0;
  static const edge = 12.0;
  static const gap = 8.0;

  /// 12 + 44 + 12.
  static const railWidth = edge + key + edge;

  /// The phone drawer's own width, so the list reads the same.
  static const sidebarWidth = 320.0;

  /// The sidebar's outline column (正在发生, workspaces, folders) at its left.
  static const outlineWidth = 56.0;

  /// The sidebar with its outline and the list still [sidebarWidth] wide:
  /// taken whenever the chat keeps its comfortable width beside it.
  static const sidebarWideWidth = sidebarWidth + outlineWidth;

  /// The right panel: about a phone's width, which its tabs were drawn for.
  static const panelMin = 320.0;
  static const panelIdealMin = 360.0;
  static const panelMax = 420.0;
  static const panelFraction = 0.3;

  /// The chat column never gets narrower than a phone (DSH Web keeps 400).
  static const chatMin = 400.0;

  /// The sidebar stays unfolded only while the chat keeps this much.
  static const chatComfort = 600.0;

  /// Between the sidebar and the panel both, the chat keeps its whole
  /// reading width (720, `AppSpace.readingWidth`, and its 12 margins), or one
  /// of them folds: three columns on a 13" iPad in landscape (1376) would
  /// leave it 644.
  static const chatBesideBoth = 720.0 + 2 * edge;

  /// Snapped to the 4dp grid.
  static double panelIdeal(double windowWidth) {
    final raw = (windowWidth * panelFraction / 4).roundToDouble() * 4;
    return raw.clamp(panelIdealMin, panelMax);
  }
}

/// The resolved plan for one window: which columns show and how wide they are.
///
/// Pure: [resolve] turns the window, the system insets and the person's
/// choices (sidebar / panel unfolded) into columns. Everything that has to
/// agree — the scaffold, the header keys, where 对话详情 opens — reads the
/// same value.
@immutable
class AdaptiveLayout {
  const AdaptiveLayout({
    required this.windowClass,
    required this.window,
    required this.padding,
    required this.left,
    required this.panelWidth,
    required this.panelAvailable,
    required this.panelShown,
    required this.sidebarFits,
    this.sidebarWidth = AdaptiveMetrics.sidebarWidth,
  });

  /// Every column hidden: the phone layout.
  const AdaptiveLayout.compact({
    this.window = Size.zero,
    this.padding = EdgeInsets.zero,
    this.windowClass = WindowClass.compact,
  }) : left = LeftPane.none,
       panelWidth = 0,
       panelAvailable = false,
       panelShown = false,
       sidebarFits = false,
       sidebarWidth = AdaptiveMetrics.sidebarWidth;

  /// [window] is the whole window, [padding] the system insets (status and
  /// navigation bars, cutouts). [hasSession]: no conversation, no panel.
  ///
  /// [prefer]: the side opened last. When the sidebar and the panel are both
  /// open but all three columns would leave the chat under
  /// [AdaptiveMetrics.chatBesideBoth], the other side folds: [LayoutSide.panel]
  /// folds the sidebar into the rail; [LayoutSide.sidebar] or null (nothing
  /// chosen yet) folds the panel away (still [panelAvailable], so the
  /// header's key unfolds it).
  factory AdaptiveLayout.resolve({
    required Size window,
    EdgeInsets padding = EdgeInsets.zero,
    required bool hasSession,
    bool sidebarOpen = true,
    bool panelOpen = true,
    LayoutSide? prefer,
  }) {
    final windowClass = WindowClass.ofSize(window);
    if (windowClass != WindowClass.expanded) {
      return AdaptiveLayout.compact(window: window, padding: padding, windowClass: windowClass);
    }
    final inner = window.width - padding.left - padding.right;
    // The panel gives way first: down to its minimum, then it doesn't show.
    final room = inner - AdaptiveMetrics.railWidth - AdaptiveMetrics.chatMin;
    final width = math.min(AdaptiveMetrics.panelIdeal(window.width), room);
    final available = hasSession && width >= AdaptiveMetrics.panelMin;
    final wantPanel = available && panelOpen;
    // The sidebar with the panel folded away, and beside the panel.
    final fitsAlone = inner - AdaptiveMetrics.sidebarWidth >= AdaptiveMetrics.chatComfort;
    final fitsBeside = inner - AdaptiveMetrics.sidebarWidth - width >= AdaptiveMetrics.chatBesideBoth;
    // Both asked for, room for one: the side opened last stays.
    final contested = sidebarOpen && wantPanel && fitsAlone && !fitsBeside;
    final shown = contested ? prefer == LayoutSide.panel : wantPanel;
    final sidebar = sidebarOpen && (shown ? fitsBeside : fitsAlone);
    // Whether it shows is decided at its narrow width (as it always was); the
    // outline then widens it when the chat keeps the same comfort beside it.
    // Folded or not, so it keeps its width while it slides in or out.
    final wide =
        inner - AdaptiveMetrics.sidebarWideWidth - (shown ? width : 0) >=
        (shown ? AdaptiveMetrics.chatBesideBoth : AdaptiveMetrics.chatComfort);
    return AdaptiveLayout(
      windowClass: windowClass,
      window: window,
      padding: padding,
      left: sidebar ? LeftPane.sidebar : LeftPane.rail,
      panelWidth: available ? width : 0,
      panelAvailable: available,
      panelShown: shown,
      // Unfolding it folds a panel the two don't fit beside.
      sidebarFits: fitsAlone,
      sidebarWidth: wide ? AdaptiveMetrics.sidebarWideWidth : AdaptiveMetrics.sidebarWidth,
    );
  }

  final WindowClass windowClass;
  final Size window;
  final EdgeInsets padding;
  final LeftPane left;

  /// The panel's content width (system insets excluded); 0 when it can't show.
  final double panelWidth;

  /// A conversation is open and the window has room for the panel.
  final bool panelAvailable;

  /// The panel is on screen (available and not folded away).
  final bool panelShown;

  /// The sidebar fits next to a comfortable chat, the panel folding away
  /// for it when the two don't fit together: ≡ on the rail unfolds it.
  final bool sidebarFits;

  /// The sidebar's width, its outline column included:
  /// [AdaptiveMetrics.sidebarWideWidth] when there is room, else
  /// [AdaptiveMetrics.sidebarWidth] (the list then gives the outline its 56).
  final double sidebarWidth;

  /// The sidebar, whenever it shows, has its outline column: wide windows
  /// only (the pulled-over drawer of a phone or a medium window has none).
  bool get hasOutline => isExpanded;

  bool get isExpanded => windowClass == WindowClass.expanded;

  /// The left column's content width.
  double get leftWidth => switch (left) {
    LeftPane.none => 0,
    LeftPane.rail => AdaptiveMetrics.railWidth,
    LeftPane.sidebar => sidebarWidth,
  };

  /// The left column on screen, the inset it covers included.
  double get leftExtent => left == LeftPane.none ? 0 : leftWidth + padding.left;

  /// The panel on screen, the inset it covers included.
  double get panelExtent => panelShown ? panelWidth + padding.right : 0;

  /// The chat column.
  Rect get chatRect => Rect.fromLTRB(leftExtent, 0, window.width - panelExtent, window.height);

  MenuAction get menuAction => switch (left) {
    LeftPane.none => MenuAction.overlay,
    LeftPane.sidebar => MenuAction.collapse,
    LeftPane.rail => sidebarFits ? MenuAction.expand : MenuAction.overlay,
  };

  /// Where 对话详情 opens.
  DetailPresentation get detail => panelAvailable
      ? DetailPresentation.panel
      : windowClass == WindowClass.compact
      ? DetailPresentation.page
      : DetailPresentation.sheet;

  @override
  bool operator ==(Object other) =>
      other is AdaptiveLayout &&
      other.windowClass == windowClass &&
      other.window == window &&
      other.padding == padding &&
      other.left == left &&
      other.panelWidth == panelWidth &&
      other.panelAvailable == panelAvailable &&
      other.panelShown == panelShown &&
      other.sidebarFits == sidebarFits &&
      other.sidebarWidth == sidebarWidth;

  @override
  int get hashCode => Object.hash(
    windowClass,
    window,
    padding,
    left,
    panelWidth,
    panelAvailable,
    panelShown,
    sidebarFits,
    sidebarWidth,
  );

  @override
  String toString() =>
      'AdaptiveLayout(${windowClass.name}, ${window.width}×${window.height}, '
      'left: ${left.name}${left == LeftPane.sidebar ? ' $sidebarWidth' : ''}, panel: ${panelShown ? panelWidth : '—'})';
}
