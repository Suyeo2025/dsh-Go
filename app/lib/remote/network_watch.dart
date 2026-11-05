import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// How long the app was last away from the foreground, for links that want
/// to tell "back after a while" (sockets likely dead: iOS suspends the app,
/// Android may freeze it) from a quick switch or a network change.
///
/// Fed by the lifecycle listener inside [networkKicks]; [lastAway] is
/// updated before the resume kick goes out.
class AppSuspension {
  AppSuspension({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// [lastAway] only describes the resume that just happened: a network kick
  /// later on is not "back from the background".
  static const fresh = Duration(seconds: 3);

  final DateTime Function() _now;
  DateTime? _leftAt;
  DateTime? _resumedAt;
  Duration? _lastAway;

  /// Time spent away before the latest resume, while that resume is recent;
  /// null before the first one, when no leave was seen, or once stale.
  Duration? get lastAway {
    final at = _resumedAt;
    if (at == null || _now().difference(at) > fresh) return null;
    return _lastAway;
  }

  /// The app went inactive / hidden / paused; the earliest one counts.
  void markLeft() => _leftAt ??= _now();

  void markResumed() {
    final now = _now();
    final left = _leftAt;
    _leftAt = null;
    _resumedAt = now;
    // Wall clock (it keeps counting while the device sleeps); a clock set
    // backwards reads as "not away".
    _lastAway = left == null ? null : (now.isBefore(left) ? Duration.zero : now.difference(left));
  }
}

final appSuspension = AppSuspension();

/// Moments worth re-checking remote links: the network changed (Wi-Fi ↔
/// cellular, VPN up/down) or the app came back to the foreground, where
/// Android may have frozen sockets for a while.
///
/// Emits nothing for the initial connectivity state.
Stream<void> networkKicks() {
  late final StreamController<void> controller;
  StreamSubscription<List<ConnectivityResult>>? connectivity;
  AppLifecycleListener? lifecycle;
  List<ConnectivityResult>? last;

  controller = StreamController<void>.broadcast(
    onListen: () {
      try {
        connectivity = Connectivity().onConnectivityChanged.listen((results) {
          final previous = last;
          last = results;
          if (previous == null) return;
          // Coming back online, or switching networks: either way sockets that
          // were bound to the old interface are dead.
          if (!results.contains(ConnectivityResult.none)) controller.add(null);
        }, onError: (_) {});
      } catch (_) {
        // No plugin (tests, desktop without NetworkManager): resume-only.
      }
      lifecycle = AppLifecycleListener(
        onInactive: appSuspension.markLeft,
        onHide: appSuspension.markLeft,
        onPause: appSuspension.markLeft,
        onResume: () {
          // Before the kick: listeners read how long the app was away.
          appSuspension.markResumed();
          controller.add(null);
        },
      );
    },
    onCancel: () {
      unawaited(connectivity?.cancel());
      lifecycle?.dispose();
      connectivity = null;
      lifecycle = null;
      last = null;
    },
  );
  return controller.stream;
}
