// A drawer row's quick actions behind a left swipe: 置顶 / 取消置顶, 文件夹 and
// 归档, from the content to the edge (no 文件夹 on iOS, where workspaces are
// the only grouping). A swipe past 60% of the row archives
// (the edge key). One row is open at a time ([openSwipeRowProvider]); a
// scroll, a tap anywhere, another row opening or the drawer closing put it
// back. With a mouse the same keys fade in at the row's end on hover.
//
// The keys call the same functions as the row's menu; the menu keeps every
// action (a swipe can't be reached with a screen reader).

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// The row whose keys show (its conversation id); null with all closed.
class OpenSwipeRowController extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String id) => state = id;

  /// Closes [id] (any row when null).
  void close([String? id]) {
    if (state != null && (id == null || state == id)) state = null;
  }
}

final openSwipeRowProvider = NotifierProvider<OpenSwipeRowController, String?>(OpenSwipeRowController.new);

/// A left swipe over [child] shows three keys.
class SwipeActions extends ConsumerStatefulWidget {
  const SwipeActions({
    super.key,
    required this.id,
    required this.pinned,
    required this.onPin,
    this.onFolder,
    required this.onArchive,
    required this.child,
    this.enabled = true,
  });

  /// Off (multi-select, a read-only list): the row as it is, no swipe. The
  /// widget stays in the tree either way, so the row keeps its state.
  final bool enabled;

  /// The conversation (one row open at a time).
  final String id;
  final bool pinned;
  final VoidCallback onPin;

  /// 文件夹; null: no such key (iOS, where workspaces are the only grouping).
  final VoidCallback? onFolder;
  final VoidCallback onArchive;
  final Widget child;

  /// One key's width.
  static const keyWidth = 72.0;

  /// All three keys (with 文件夹).
  static const keysWidth = keyWidth * 3;

  /// The keys this row shows, side by side.
  double get shownKeysWidth => keyWidth * (onFolder == null ? 2 : 3);

  /// A swipe past this share of the row archives on release.
  static const archiveShare = 0.6;

  /// Sideways travel before the row takes the finger. Under the pulled-over
  /// drawer's own 8 (`DrawerDragRecognizer`): a left swipe on a row is the
  /// row's, elsewhere on the drawer it still pushes the drawer back.
  static const slop = 6.0;

  @override
  ConsumerState<SwipeActions> createState() => SwipeActionsState();
}

class SwipeActionsState extends ConsumerState<SwipeActions> with TickerProviderStateMixin {
  /// How far the content is pushed left (≥ 0).
  double _shift = 0;
  double _width = 0;
  bool _dragging = false;
  bool _hovered = false;

  /// Only while it settles: created on release, disposed once closed.
  AnimationController? _settle;

  /// The row is showing its keys (tests).
  @visibleForTesting
  bool get isOpen => _shift > 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The drawer closed (or the page was covered): put it back.
    if (!TickerMode.valuesOf(context).enabled && _shift > 0) _snapClosed();
  }

  @override
  void didUpdateWidget(SwipeActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _shift > 0) {
      _settle?.dispose();
      _settle = null;
      _shift = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(openSwipeRowProvider.notifier).close(widget.id);
      });
    }
  }

  @override
  void dispose() {
    _settle?.dispose();
    super.dispose();
  }

  void _snapClosed() {
    _settle?.dispose();
    _settle = null;
    _shift = 0;
    if (mounted) setState(() {});
  }

  void _start() {
    _settle?.stop();
    _dragging = true;
    final open = ref.read(openSwipeRowProvider);
    if (open != null && open != widget.id) ref.read(openSwipeRowProvider.notifier).close();
  }

  void _update(double dx) {
    final max = math.max(_width, widget.shownKeysWidth);
    setState(() => _shift = (_shift - dx).clamp(0.0, max));
  }

  void _end(double velocity) {
    _dragging = false;
    final width = _width <= 0 ? widget.shownKeysWidth : _width;
    if (_shift >= width * SwipeActions.archiveShare) {
      _animateTo(
        width,
        then: () {
          widget.onArchive();
          ref.read(openSwipeRowProvider.notifier).close(widget.id);
          _snapClosed();
        },
      );
      return;
    }
    final open = velocity < -300 || (velocity <= 300 && _shift > widget.shownKeysWidth / 2);
    if (open) {
      ref.read(openSwipeRowProvider.notifier).open(widget.id);
      _animateTo(widget.shownKeysWidth);
    } else {
      close();
    }
  }

  /// Back to the content alone.
  void close() {
    ref.read(openSwipeRowProvider.notifier).close(widget.id);
    if (_shift == 0) return;
    _animateTo(0);
  }

  void _animateTo(double target, {VoidCallback? then}) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced) {
      setState(() => _shift = target);
      if (target == 0) _snapClosed();
      then?.call();
      return;
    }
    final from = _shift;
    final controller = _settle ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    controller
      ..stop()
      ..value = 0;
    void tick() {
      if (!mounted) return;
      setState(() => _shift = from + (target - from) * Curves.easeOutCubic.transform(controller.value));
    }

    controller.addListener(tick);
    controller.forward().whenCompleteOrCancel(() {
      controller.removeListener(tick);
      if (!mounted || controller.status != AnimationStatus.completed) return;
      if (target == 0) {
        _snapClosed();
      }
      then?.call();
    });
  }

  void _key(VoidCallback action) {
    close();
    action();
  }

  @override
  Widget build(BuildContext context) {
    // Another row opened: this one closes.
    ref.listen(openSwipeRowProvider, (_, open) {
      if (open != widget.id && _shift > 0 && !_dragging) close();
    });
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth.isFinite ? constraints.maxWidth : widget.shownKeysWidth;
        final open = _shift > 0;
        Widget content = Transform.translate(offset: Offset(-_shift, 0), child: widget.child);
        if (open) {
          // While open, a tap on the row closes it instead of opening the chat.
          content = TapRegion(
            onTapOutside: (_) => close(),
            child: Stack(
              children: [
                content,
                Positioned.fill(
                  right: _shift,
                  child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: close),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: _shift,
                  child: _Keys(
                    width: _shift,
                    pinned: widget.pinned,
                    onPin: () => _key(widget.onPin),
                    keysWidth: widget.shownKeysWidth,
                    onFolder: widget.onFolder == null ? null : () => _key(widget.onFolder!),
                    onArchive: () => _key(widget.onArchive),
                  ),
                ),
              ],
            ),
          );
        } else if (_hovered && widget.enabled) {
          content = Stack(
            children: [
              content,
              Positioned(
                top: 0,
                bottom: 0,
                right: 4,
                child: _HoverKeys(
                  pinned: widget.pinned,
                  onPin: widget.onPin,
                  onFolder: widget.onFolder,
                  onArchive: widget.onArchive,
                ),
              ),
            ],
          );
        }
        return MouseRegion(
          onEnter: (e) {
            if (e.kind == PointerDeviceKind.mouse) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (_hovered) setState(() => _hovered = false);
          },
          child: RawGestureDetector(
            gestures: !widget.enabled
                ? const {}
                : {
                    _RowSwipeRecognizer: GestureRecognizerFactoryWithHandlers<_RowSwipeRecognizer>(
                      () => _RowSwipeRecognizer(debugOwner: this),
                      (r) => r
                        ..isOpen = (() => _shift > 0)
                        ..onStart = _start
                        ..onUpdate = _update
                        ..onEnd = _end,
                    ),
                  },
            child: content,
          ),
        );
      },
    );
  }
}

/// The three keys, revealed from the right as the content moves away: only
/// the part beside the content shows (the row itself is transparent).
class _Keys extends StatelessWidget {
  const _Keys({
    required this.width,
    required this.pinned,
    required this.onPin,
    required this.keysWidth,
    required this.onFolder,
    required this.onArchive,
  });

  final double width;
  final double keysWidth;
  final bool pinned;
  final VoidCallback onPin;
  final VoidCallback? onFolder;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    // Past the keys (towards archive) the edge key grows.
    final extra = math.max(0.0, width - keysWidth);
    return ClipRRect(
      borderRadius: AppShape.radiusMd,
      child: OverflowBox(
        alignment: Alignment.centerRight,
        minWidth: 0,
        maxWidth: double.infinity,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SwipeKey(
              width: SwipeActions.keyWidth,
              color: scheme.primary,
              onColor: scheme.onPrimary,
              icon: pinned ? AppIcons.pinActive : AppIcons.pin,
              label: pinned ? l10n.shellUnpin : l10n.commonPin,
              onTap: onPin,
            ),
            if (onFolder case final onFolder?)
              _SwipeKey(
                width: SwipeActions.keyWidth,
                color: scheme.surfaceContainerHighest,
                onColor: scheme.onSurface,
                icon: AppIcons.moveToFolder,
                label: l10n.smUiFolder,
                onTap: onFolder,
              ),
            _SwipeKey(
              width: SwipeActions.keyWidth + extra,
              color: colors.warning,
              onColor: Colors.white,
              icon: AppIcons.archive,
              label: l10n.shellArchive,
              onTap: onArchive,
            ),
          ],
        ),
      ),
    );
  }
}

class _SwipeKey extends StatelessWidget {
  const _SwipeKey({
    required this.width,
    required this.color,
    required this.onColor,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double width;
  final Color color;
  final Color onColor;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: onColor, fontSize: 11);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: color,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 18, color: onColor),
                  const SizedBox(height: 2),
                  Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: style),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// With a mouse: the same three actions as small keys at the row's end.
class _HoverKeys extends StatelessWidget {
  const _HoverKeys({required this.pinned, required this.onPin, this.onFolder, required this.onArchive});

  final bool pinned;
  final VoidCallback onPin;
  final VoidCallback? onFolder;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    Widget key(IconData icon, String label, VoidCallback onTap) => IconButton(
      tooltip: label,
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      style: IconButton.styleFrom(minimumSize: const Size.square(28), padding: EdgeInsets.zero),
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
    );
    return Center(
      child: DecoratedBox(
        decoration: ShapeDecoration(color: scheme.surface.withValues(alpha: 0.92), shape: const StadiumBorder()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            key(pinned ? AppIcons.pinActive : AppIcons.pin, pinned ? l10n.shellUnpin : l10n.commonPin, onPin),
            if (onFolder case final onFolder?) key(AppIcons.moveToFolder, l10n.smUiFolder, onFolder),
            key(AppIcons.archive, l10n.shellArchive, onArchive),
          ],
        ),
      ),
    );
  }
}

/// Takes a sideways finger early ([SwipeActions.slop]) when it goes left (or
/// either way once the row is open); a vertical start is left to the list,
/// a still finger to the row's tap and long press.
class _RowSwipeRecognizer extends OneSequenceGestureRecognizer {
  _RowSwipeRecognizer({super.debugOwner});

  late bool Function() isOpen;
  late VoidCallback onStart;
  late ValueChanged<double> onUpdate;
  late ValueChanged<double> onEnd;

  Offset _moved = Offset.zero;
  bool _accepted = false;
  VelocityTracker? _tracker;

  @override
  bool isPointerAllowed(PointerDownEvent event) => super.isPointerAllowed(event) && event.buttons == kPrimaryButton;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _moved = Offset.zero;
    _accepted = false;
    _tracker = VelocityTracker.withKind(event.kind)..addPosition(event.timeStamp, event.localPosition);
  }

  @override
  void handleEvent(PointerEvent event) {
    _tracker?.addPosition(event.timeStamp, event.localPosition);
    if (event is PointerMoveEvent) {
      if (_accepted) {
        onUpdate(event.localDelta.dx);
        return;
      }
      _moved += event.localDelta;
      final dx = _moved.dx.abs();
      final dy = _moved.dy.abs();
      if (dy > SwipeActions.slop && dy >= dx) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
      } else if (dx > SwipeActions.slop && dx > dy * 1.2) {
        if (_moved.dx < 0 || isOpen()) {
          resolve(GestureDisposition.accepted);
        } else {
          resolve(GestureDisposition.rejected);
          stopTrackingPointer(event.pointer);
        }
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_accepted) {
        onEnd(_tracker?.getVelocity().pixelsPerSecond.dx ?? 0);
      } else {
        resolve(GestureDisposition.rejected);
      }
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (_accepted) return;
    _accepted = true;
    onStart();
    // What moved before it was taken counts too.
    onUpdate(_moved.dx);
  }

  @override
  void rejectGesture(int pointer) {
    _accepted = false;
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'row swipe';
}
