// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/semantic_colors.dart';
import 'ambient_clock.dart';

/// 状态语义。业务层把自己的枚举(引擎状态、远程连接状态)映射到这里。
enum StatusTone {
  /// 运行中 / 已连接。
  ok,

  /// 启动中 / 连接中 / 安装中(会呼吸)。
  busy,

  /// 降级、需要注意。
  warn,

  /// 失败 / 已崩溃。
  error,

  /// 已停止 / 未连接。
  idle,
}

/// 状态圆点。[StatusTone.busy] 且 [pulse] 时缓慢呼吸(透明度 1 ↔ 0.35)。
///
/// 呼吸跟着共用的 [AmbientClock] 一步一步走(约 12 次/秒)而不是每个 vsync:
/// 一个 7 dp 的点看不出差别,而几个点(连同工具行的转圈)同时在列表、头部里
/// 动也只是每秒 12 帧,不再让整页以屏幕刷新率出帧。系统关闭动画、或所在页面被盖住
/// (TickerMode 关)时不呼吸,也不出帧。
///
/// 颜色**不是唯一信号**:旁边总要配文字("运行中"/"已停止"),
/// 色弱用户和读屏都靠文字。
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.tone, this.size = 8, this.pulse = true});

  final StatusTone tone;
  final double size;

  /// [StatusTone.busy] breathes; false holds it still (an invisible dot).
  final bool pulse;

  /// One step of the breathing ([AmbientClock.step]).
  static const stepEvery = AmbientClock.step;

  /// One way of the breathing (1 → 0.35, then back).
  static const half = Duration(milliseconds: 1200);

  static Color colorFor(BuildContext context, StatusTone tone) {
    final colors = DshColors.of(context);
    return switch (tone) {
      StatusTone.ok => colors.success,
      StatusTone.busy => Theme.of(context).colorScheme.primary,
      StatusTone.warn => colors.warning,
      StatusTone.error => colors.danger,
      StatusTone.idle => Theme.of(context).colorScheme.outline,
    };
  }

  /// The opacity [elapsed] into the breathing: 1 ↔ 0.35 along [AppMotion.std].
  @visibleForTesting
  static double opacityAt(Duration elapsed) {
    final period = half.inMicroseconds * 2;
    final at = elapsed.inMicroseconds % period / half.inMicroseconds;
    final t = AppMotion.std.transform(at <= 1 ? at : 2 - at);
    return 1 + (0.35 - 1) * t;
  }

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> {
  bool _listening = false;
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (mode != _tickerMode) {
      _tickerMode?.removeListener(_onTickerMode);
      _tickerMode = mode..addListener(_onTickerMode);
    }
    _sync();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  bool get _breathing =>
      widget.tone == StatusTone.busy &&
      widget.pulse &&
      !AppMotion.reduced(context) &&
      (_tickerMode?.value.enabled ?? true);

  void _sync() {
    if (!mounted) return;
    final breathing = _breathing;
    if (breathing == _listening) return;
    _listening = breathing;
    if (breathing) {
      AmbientClock.instance.addListener(_step);
    } else {
      AmbientClock.instance.removeListener(_step);
    }
  }

  /// The page was covered or uncovered (no build of its own follows).
  void _onTickerMode() {
    final was = _listening;
    _sync();
    if (mounted && was != _listening) setState(() {});
  }

  void _step() => setState(() {});

  @override
  void dispose() {
    if (_listening) AmbientClock.instance.removeListener(_step);
    _tickerMode?.removeListener(_onTickerMode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _listening ? StatusDot.opacityAt(AmbientClock.instance.elapsed) : 1,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: StatusDot.colorFor(context, widget.tone), shape: BoxShape.circle),
      ),
    );
  }
}
