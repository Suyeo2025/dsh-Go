// 正在发生: the conversations running or waiting on the person, fixed above
// the drawer's list (state/happening_state.dart decides who and in what
// order). Each row: a still whale for its state, the title, what it does now,
// a mm:ss for a run and, only when the conversation keeps a todo list, a thin
// lane filled by done / total. No percentage is made up.
//
// Nothing here animates on its own: the whales are still frames, the timer
// text follows [HappeningSeconds] (the shared ambient clock, one change a
// second) and only while it can be seen, and nothing at all with animations
// off. An empty section takes no height.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/happening_state.dart';
import '../../common/smooth_size.dart';
import '../../theme/theme.dart';
import 'happening_whales.dart';

/// The block: a heading with the count, then the rows ([maxRows] of them
/// until 还有 N 个 is tapped).
class HappeningSection extends ConsumerStatefulWidget {
  const HappeningSection({super.key, required this.onOpen, required this.onLongPress, this.seconds});

  /// Opens a conversation (and closes the drawer).
  final ValueChanged<String> onOpen;

  /// The row's actions (the list's menu).
  final void Function(SessionSummary session) onLongPress;

  /// The timers' clock (tests); [happeningSecondsProvider] when null.
  final HappeningSeconds? seconds;

  /// Rows shown before 还有 N 个: the section is fixed above the list.
  static const maxRows = 3;

  @override
  ConsumerState<HappeningSection> createState() => _HappeningSectionState();
}

class _HappeningSectionState extends ConsumerState<HappeningSection> {
  late final HappeningVisibleController _visible = ref.read(happeningVisibleProvider.notifier);
  ValueListenable<TickerModeData>? _mode;
  bool _shown = false;
  bool _all = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (mode != _mode) {
      _mode?.removeListener(_syncVisible);
      _mode = mode..addListener(_syncVisible);
    }
    _syncVisible();
  }

  /// Seen (the drawer open, or the sidebar): the other runs are followed.
  void _syncVisible() {
    final shown = mounted && (_mode?.value.enabled ?? true);
    if (shown == _shown) return;
    _shown = shown;
    final visible = _visible;
    // Not while the tree builds.
    scheduleMicrotask(() {
      try {
        visible.set(shown);
      } catch (_) {
        // The container went first (tests, a host switch).
      }
    });
  }

  @override
  void dispose() {
    _mode?.removeListener(_syncVisible);
    if (_shown) {
      _shown = false;
      final visible = _visible;
      scheduleMicrotask(() {
        try {
          visible.set(false);
        } catch (_) {}
      });
    }
    super.dispose();
  }

  void _longPress(String id) {
    final s = ref.read(drawerScopeProvider)?.sessions.where((s) => s.sessionId == id).firstOrNull;
    if (s != null) widget.onLongPress(s);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = ref.watch(happeningProvider);
    final now = ref.watch(drawerClockProvider)();
    final extra = entries.length - HappeningSection.maxRows;
    final shown = _all || extra <= 1 ? entries : entries.take(HappeningSection.maxRows).toList();
    final colors = DshColors.of(context);
    return SmoothSize(
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      alignment: Alignment.topCenter,
      child: entries.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: Column(
                key: const ValueKey('happening'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                    child: Semantics(
                      header: true,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(l10n.smUiHappening, style: AppType.eyebrow(color: colors.textTertiary)),
                          ),
                          Text(
                            '${entries.length}',
                            style: AppType.tabular(AppType.eyebrow(color: colors.textTertiary)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (final e in shown)
                    Padding(
                      key: ValueKey('happening-${e.sessionId}'),
                      padding: const EdgeInsets.only(bottom: 4),
                      child: HappeningRow(
                        entry: e,
                        now: now,
                        seconds: widget.seconds ?? ref.watch(happeningSecondsProvider),
                        onTap: () => widget.onOpen(e.sessionId),
                        onLongPress: () => _longPress(e.sessionId),
                      ),
                    ),
                  if (extra > 1)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _all = !_all),
                        child: Text(_all ? l10n.smUiHappeningLess : l10n.smUiHappeningMore(extra)),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// The still whale for a row's state: a frame of [happeningWhaleFrames].
String happeningWhale(HappeningPhase phase) => switch (phase) {
  HappeningPhase.running => 'swim',
  HappeningPhase.approval || HappeningPhase.plan => 'approval',
  HappeningPhase.question => 'question',
  HappeningPhase.done => 'done',
  HappeningPhase.failed => 'failed',
};

/// A still pixel whale, 24 × 16: the live activity's compact frame, drawn
/// from const cells (nothing to decode, there on the first frame).
class HappeningWhale extends StatelessWidget {
  const HappeningWhale(this.frame, {super.key});

  /// A key of [happeningWhaleFrames].
  final String frame;

  static const size = Size(24, 16);

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: size, painter: _WhalePainter(happeningWhaleFrames[frame] ?? const []));
}

class _WhalePainter extends CustomPainter {
  _WhalePainter(this.rows);

  final List<String> rows;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / happeningWhaleWidth;
    final paint = Paint()..isAntiAlias = false;
    for (var y = 0; y < rows.length; y++) {
      final row = rows[y];
      var x = 0;
      while (x < row.length) {
        final c = row[x];
        var end = x + 1;
        while (end < row.length && row[end] == c) {
          end++;
        }
        if (c != '.') {
          paint.color = Color(happeningWhalePalette[happeningWhaleCells.indexOf(c)]);
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, (end - x) * cell, cell), paint);
        }
        x = end;
      }
    }
  }

  @override
  bool shouldRepaint(_WhalePainter old) => !identical(old.rows, rows);
}

/// One row of 正在发生, 52 high.
class HappeningRow extends StatelessWidget {
  const HappeningRow({
    super.key,
    required this.entry,
    required this.now,
    required this.seconds,
    required this.onTap,
    required this.onLongPress,
  });

  final HappeningEntry entry;

  /// The drawer's clock when built (a settled row's summary).
  final DateTime now;
  final HappeningSeconds seconds;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static const height = 52.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final e = entry;
    final edge = switch (e.phase) {
      HappeningPhase.approval || HappeningPhase.plan || HappeningPhase.question => colors.warning,
      HappeningPhase.done => colors.success,
      HappeningPhase.failed => colors.danger,
      HappeningPhase.running => null,
    };
    final subtitle = happeningSubtitle(e, now);
    final elapsed = e.elapsedAt(now);
    final shape = Squircle.border(AppShape.md);
    final fill = scheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.06 : 0.035);
    final label = [
      e.title,
      subtitle,
      if (e.phase == HappeningPhase.running && elapsed != null)
        l10n.smUiElapsed(elapsed.inMinutes, elapsed.inSeconds % 60),
      if (e.hasTodos) l10n.smStateTodoProgress(e.todoDone, e.todoTotal),
    ].join(l10n.shellSemanticsSeparator);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          customBorder: shape,
          child: Ink(
            decoration: ShapeDecoration(color: fill, shape: shape),
            // 52 high; taller with large text.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: height),
              child: ClipPath(
                clipper: ShapeBorderClipper(shape: shape),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (edge != null)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: 3,
                        child: ColoredBox(key: const ValueKey('happening-edge'), color: edge),
                      ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(10, 6, 10, e.hasTodos ? 10 : 6),
                      child: Row(
                        children: [
                          ExcludeSemantics(child: HappeningWhale(happeningWhale(e.phase))),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontSize: 14,
                                    height: 1.3,
                                    fontWeight: FontWeight.w500,
                                    color: scheme.onSurface,
                                  ),
                                ),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    height: 1.3,
                                    color: e.phase.waiting ? colors.warning : colors.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (e.phase == HappeningPhase.running && e.startedAt != null) ...[
                            const SizedBox(width: 8),
                            // Its second's repaint stays in its own layer.
                            RepaintBoundary(
                              child: HappeningClock(startedAt: e.startedAt!, seconds: seconds),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (e.hasTodos)
                      Positioned(
                        left: 10 + 24 + 10,
                        right: 10,
                        bottom: 5,
                        height: 3,
                        child: _TodoLane(done: e.todoDone, total: e.todoTotal),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// done / total, nothing more: no number, no estimate.
class _TodoLane extends StatelessWidget {
  const _TodoLane({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final share = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return ClipRRect(
      key: const ValueKey('happening-lane'),
      borderRadius: BorderRadius.circular(1.5),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: scheme.primary.withValues(alpha: 0.14)),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: share,
            child: ColoredBox(color: scheme.primary),
          ),
        ],
      ),
    );
  }
}

/// mm:ss since [startedAt]. Steps once a second on [seconds] while it can be
/// seen and animations are on; otherwise shows the time when it was built.
class HappeningClock extends StatefulWidget {
  const HappeningClock({super.key, required this.startedAt, required this.seconds});

  final DateTime startedAt;

  /// The clock read; listened to only while live.
  final HappeningSeconds seconds;

  @override
  State<HappeningClock> createState() => _HappeningClockState();
}

class _HappeningClockState extends State<HappeningClock> {
  ValueListenable<TickerModeData>? _mode;
  HappeningSeconds? _listening;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (mode != _mode) {
      _mode?.removeListener(_onMode);
      _mode = mode..addListener(_onMode);
    }
    _sync();
  }

  @override
  void didUpdateWidget(HappeningClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seconds != widget.seconds) {
      _listening?.removeListener(_tick);
      _listening = null;
    }
    _sync();
  }

  void _onMode() {
    final was = _listening != null;
    _sync();
    if (mounted && was != (_listening != null)) setState(() {});
  }

  void _sync() {
    if (!mounted) return;
    final live = (_mode?.value.enabled ?? true) && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (live == (_listening != null)) return;
    if (live) {
      _listening = widget.seconds..addListener(_tick);
    } else {
      _listening?.removeListener(_tick);
      _listening = null;
    }
  }

  void _tick() => setState(() {});

  @override
  void dispose() {
    _listening?.removeListener(_tick);
    _mode?.removeListener(_onMode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.seconds.now.difference(widget.startedAt);
    final style = AppType.tabular(
      Theme.of(context).textTheme.bodySmall!.copyWith(color: DshColors.of(context).textTertiary),
    );
    final text = happeningClock(d.isNegative ? Duration.zero : d);
    // A box as large as the widest text of this form: the second's change
    // lays out this text alone, never the row or the section around it.
    final scaler = MediaQuery.textScalerOf(context);
    final template = text.replaceAll(RegExp('[0-9]'), '0');
    if (template != _template || style != _style || scaler != _scaler) {
      _template = template;
      _style = style;
      _scaler = scaler;
      final painter = TextPainter(
        text: TextSpan(text: template, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      _box = Size(painter.width.ceilToDouble() + 1, painter.height.ceilToDouble());
      painter.dispose();
    }
    return SizedBox.fromSize(
      size: _box,
      child: Text(text, style: style, maxLines: 1, softWrap: false, textAlign: TextAlign.right),
    );
  }

  String? _template;
  TextStyle? _style;
  TextScaler? _scaler;
  Size _box = Size.zero;
}
