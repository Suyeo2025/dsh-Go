import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_focus.dart';
import '../theme/theme.dart';

/// Wraps the approval / question card of [eventId]: when a push tap or the
/// Live Activity asks for it ([chatFocusProvider]), it scrolls fully into
/// view and its outline lights up once (a single fade in and out, nothing
/// that keeps running). It takes the request whether it is built already or
/// only once its conversation has loaded.
class ChatFocusTarget extends ConsumerStatefulWidget {
  const ChatFocusTarget({super.key, required this.eventId, required this.child});

  final String eventId;
  final Widget child;

  /// How long the outline stays lit.
  static const lit = Duration(milliseconds: 1400);

  @override
  ConsumerState<ChatFocusTarget> createState() => _ChatFocusTargetState();
}

class _ChatFocusTargetState extends ConsumerState<ChatFocusTarget> {
  bool _lit = false;
  Timer? _off;

  @override
  void initState() {
    super.initState();
    // Asked before this card existed (a conversation still loading, a card
    // below the fold): take it now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _take(ref.read(chatFocusProvider));
    });
  }

  @override
  void dispose() {
    _off?.cancel();
    super.dispose();
  }

  void _take(ChatFocus? focus) {
    if (focus == null || focus.eventId != widget.eventId) return;
    if (!focus.freshAt(ref.read(chatFocusClockProvider)())) return;
    ref.read(chatFocusProvider.notifier).consume(focus.serial);
    // After the list has gone to its newest line (same change, its listener).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_reveal());
      setState(() => _lit = true);
      _off?.cancel();
      _off = Timer(ChatFocusTarget.lit, () {
        if (mounted) setState(() => _lit = false);
      });
    });
  }

  /// Scrolls only as far as needed: up from below the fold, then down again
  /// if a tall card's top went off the top (its title shows first).
  Future<void> _reveal() async {
    for (final policy in const [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ]) {
      if (!mounted) return;
      await Scrollable.ensureVisible(
        context,
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignmentPolicy: policy,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ChatFocus?>(chatFocusProvider, (_, next) => _take(next));
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedContainer(
      key: ValueKey('chat-focus-${widget.eventId}'),
      duration: AppMotion.of(context, AppMotion.slow),
      curve: AppMotion.std,
      foregroundDecoration: BoxDecoration(
        borderRadius: AppShape.radiusLg,
        border: Border.all(color: _lit ? color : color.withValues(alpha: 0), width: 2),
      ),
      child: widget.child,
    );
  }
}
