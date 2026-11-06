// Routes push notification taps (remote-only builds): a tap opens the paired
// direct host's conversation, the same way an in-app banner does. Also keeps
// the open conversation's banners away while it is on screen and clears its
// delivered notifications once it has been opened.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_caps.dart';
import '../state/chat_focus.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show appForegroundProvider;
import '../state/sessions_state.dart';
import '../ui/common/discard_guard.dart';
import 'push_channel.dart';
import 'push_state.dart';

/// Put it once inside the home route; it draws nothing.
class PushTapHost extends ConsumerStatefulWidget {
  const PushTapHost({super.key, this.onReveal});

  /// A tap is opening a conversation: the shell closes its drawer.
  final ValueChanged<bool>? onReveal;

  @override
  ConsumerState<PushTapHost> createState() => _PushTapHostState();
}

class _PushTapHostState extends ConsumerState<PushTapHost> {
  StreamSubscription<PushRoute>? _taps;

  /// Kept here: dispose must not touch `ref`.
  PushChannel? _channel;

  @override
  void initState() {
    super.initState();
    if (!isRemoteOnlyPlatform) return;
    final channel = ref.read(pushChannelProvider)..attach();
    _channel = channel;
    channel.shouldPresent = _shouldPresent;
    _taps = channel.taps.listen((route) => unawaited(_open(route)));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Starts the pairing state (it registers the token on launch).
      ref.read(pushProvider);
      final launch = await channel.takeLaunchTap();
      if (launch != null && mounted) await _open(launch);
    });
  }

  @override
  void dispose() {
    unawaited(_taps?.cancel());
    final channel = _channel;
    if (channel != null && channel.shouldPresent == _shouldPresent) channel.shouldPresent = null;
    super.dispose();
  }

  HostRef? get _host {
    final hostId = ref.read(pushProvider).pairing?.hostId;
    return hostId == null ? null : HostRef.direct(hostId);
  }

  /// No banner for the conversation that is open on screen.
  bool _shouldPresent(PushRoute route) {
    if (!mounted) return true;
    final host = _host;
    return pushShowsBanner(
      route,
      pairedHost: host,
      activeHost: ref.read(activeHostProvider),
      openSession: ref.read(currentSessionProvider),
      foreground: ref.read(appForegroundProvider),
    );
  }

  Future<void> _open(PushRoute route) async {
    await ref.read(pushProvider.notifier).ready;
    final host = _host;
    final sessionId = route.sessionId;
    if (!mounted || host == null || sessionId == null || route.kind == PushKind.withdraw) return;
    if (!await DiscardGuard.confirmLeave(context) || !mounted) return;
    widget.onReveal?.call(false);
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    // As ChatAlertsController.open: selecting also stops a still-pending
    // restore of the last host from switching away on a cold start.
    ref.read(activeHostProvider.notifier).select(host);
    ref.read(currentSessionProvider.notifier).select(sessionId);
    // A request's push: show its card (the same as the Live Activity's tap).
    final eventId = route.eventId;
    if (eventId != null && (route.kind == PushKind.approval || route.kind == PushKind.question)) {
      ref.read(chatFocusProvider.notifier).focus(sessionId, eventId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isRemoteOnlyPlatform) {
      // The open conversation's delivered notifications are moot.
      ref.listen<String?>(currentSessionProvider, (_, next) {
        if (next != null && ref.read(activeHostProvider) == _host) {
          unawaited(ref.read(pushChannelProvider).clearDelivered(next));
        }
      });
    }
    return const SizedBox.shrink();
  }
}

/// Whether a push for [route] arriving in the foreground still shows: not
/// for the conversation of the paired host that is open on screen.
bool pushShowsBanner(
  PushRoute route, {
  required HostRef? pairedHost,
  required HostRef activeHost,
  required String? openSession,
  required bool foreground,
}) {
  if (!foreground || pairedHost == null || route.sessionId == null) return true;
  return !(activeHost == pairedHost && openSession == route.sessionId);
}
