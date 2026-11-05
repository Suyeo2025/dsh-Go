// What a plain send does while a turn runs: the host's choice (DSH Web's
// `ui-conversation.busyEnter`, queue or steer), unless the app overrides it.
// A host that keeps no such value gets an interjection, as before.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_state.dart' show SendMode;
import 'engine_settings_state.dart';
import 'settings_state.dart';

/// The app's own say over a plain send while a turn runs.
enum BusySendOverride {
  /// Whatever the host's `ui-conversation.busyEnter` says (steer without one).
  followHost,

  /// Always an interjection (DSH `steer`).
  steer,

  /// Always waits for the turn to end (DSH `queue`).
  queue,
}

/// The web app's setting on the host's engine.
const busyEnterField = FieldRef('ui-conversation', ['busyEnter']);

/// `'queue'` or `'steer'` as the host keeps it; null when it keeps neither
/// (no `ui-conversation` namespace, not read yet, an unknown value).
final hostBusyEnterProvider = Provider<String?>((ref) {
  final value = ref.watch(engineSettingsProvider.select((s) => s.value?.valueOf(busyEnterField)));
  return value == 'queue' || value == 'steer' ? value as String : null;
});

final busySendOverrideProvider = Provider<BusySendOverride>(
  (ref) => ref.watch(settingsProvider.select((s) => s.busySendOverride)),
);

/// What [SendMode.now] becomes while a turn runs.
final busySendDefaultProvider = Provider<SendMode>(
  (ref) => busySendDefault(ref.watch(busySendOverrideProvider), ref.watch(hostBusyEnterProvider)),
);

/// [override] decides; following the host, its `'queue'` queues and anything
/// else (`'steer'`, nothing) steers.
SendMode busySendDefault(BusySendOverride override, String? host) => switch (override) {
  BusySendOverride.steer => SendMode.steer,
  BusySendOverride.queue => SendMode.queue,
  BusySendOverride.followHost => host == 'queue' ? SendMode.queue : SendMode.steer,
};
