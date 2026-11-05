// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/semantic_colors.dart';

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
/// 呼吸按 [stepEvery] 一步(约 8 次/秒)而不是每个 vsync:一个 7 dp 的点
/// 看不出差别,而几个点同时在列表、头部里呼吸也只是每秒 8 帧,不再让整页
/// 以屏幕刷新率(ProMotion 上 120Hz)出帧。系统关闭动画、或所在页面被盖住
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

  /// One step of the breathing.
  static const stepEvery = Duration(milliseconds: 125);

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

/// The one breathing every busy dot follows: a single timer while any dot
/// listens, so dots in a list and a header step together, at most
/// [StatusDot.stepEvery] apart, instead of each asking for its own frames.
class _Breath extends ValueNotifier<double> {
  _Breath() : super(1);

  Timer? _timer;
  int _steps = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(StatusDot.stepEvery, (_) {
      final next = StatusDot.opacityAt(StatusDot.stepEvery * ++_steps);
      if ((next - value).abs() >= 0.005) value = next;
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (hasListeners) return;
    _timer?.cancel();
    _timer = null;
    _steps = 0;
    value = 1;
  }
}

final _breath = _Breath();

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
      _breath.addListener(_step);
    } else {
      _breath.removeListener(_step);
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
    if (_listening) _breath.removeListener(_step);
    _tickerMode?.removeListener(_onTickerMode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _listening ? _breath.value : 1,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: StatusDot.colorFor(context, widget.tone), shape: BoxShape.circle),
      ),
    );
  }
}
