// When each conversation's current run started, as far as this phone saw it:
// the moment the Host's `api-session/status` said it started running
// (`SessionStatusEvent(running: true)`), on this phone's clock.
//
// The 正在发生 list uses it only when nothing better is known (the open
// conversation's transcript and the narrow follow of happening_state.dart
// both carry the turn's own `turn/start`). A conversation already running
// when the app connected has no entry: its start is unknown, not "now".

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'drawer_view_state.dart' show drawerClockProvider;
import 'sessions_state.dart';

/// Conversation id → when it was seen to start running (local clock).
class SessionRunClock extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() {
    // A new connection (another Host, a reconnect generation's new client):
    // forget everything, the next status events start over.
    final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
    if (client == null) return const {};
    final clock = ref.read(drawerClockProvider);
    final sub = client.hostEvents.listen((event) {
      if (event is! SessionStatusEvent || !ref.mounted) return;
      final id = event.sessionId;
      if (event.running) {
        // Repeats (a redelivered status) keep the first sighting.
        if (!state.containsKey(id)) state = {...state, id: clock()};
      } else if (state.containsKey(id)) {
        state = {...state}..remove(id);
      }
    }, onError: (Object _) {});
    // A run that ended while a status event was missed (a reconnect): the
    // list says it is idle, so its start no longer applies.
    ref.listen(sessionsProvider, (_, next) {
      final rows = next.value;
      if (rows == null || state.isEmpty) return;
      // A list read in flight may predate a status event just applied.
      final settled = clock().subtract(const Duration(seconds: 5));
      final idle = {
        for (final s in rows)
          if (!s.running && (state[s.sessionId]?.isBefore(settled) ?? false)) s.sessionId,
      };
      if (idle.isNotEmpty) state = {...state}..removeWhere((id, _) => idle.contains(id));
    });
    ref.onDispose(() => unawaited(sub.cancel()));
    return const {};
  }
}

final sessionRunClockProvider = NotifierProvider<SessionRunClock, Map<String, DateTime>>(SessionRunClock.new);
