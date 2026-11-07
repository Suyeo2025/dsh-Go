// Whether a conversation still is on the active host, as the host says
// (plan/design/sync-contract.md §0: the host is the one source of truth).
// The Live Activity, its links and push taps check it before they open a
// conversation or keep showing one.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../state/read_list_identity.dart' show readListLiveConnectionProvider;
import '../state/sessions_state.dart' show sessionsProvider;

enum SessionPresence {
  /// The list isn't in yet (not connected, loading): nothing to judge by.
  unknown,
  live,
  archived,

  /// The loaded list of a connected host doesn't have it: deleted, or never there.
  gone;

  /// Archived or deleted: nothing may show it as going on.
  bool get over => this == archived || this == gone;
}

/// [sessionId] on the active host now.
final sessionPresenceProvider = Provider.autoDispose.family<SessionPresence, String>((ref, sessionId) {
  final list = ref.watch(sessionsProvider);
  if (ref.watch(readListLiveConnectionProvider) == null || !list.hasValue || list.isLoading) {
    return SessionPresence.unknown;
  }
  final sessions = ref.read(sessionsProvider.notifier);
  final all = sessions.allSessions;
  // An empty list proves nothing (a host still settling).
  if (all.isEmpty) return SessionPresence.unknown;
  if (!all.any((s) => s.sessionId == sessionId)) return SessionPresence.gone;
  return sessions.archivedSessions.any((s) => s.sessionId == sessionId)
      ? SessionPresence.archived
      : SessionPresence.live;
});

/// Changes with every loaded list of the active host (connected again, a
/// conversation archived, deleted or added anywhere); null while none is in.
/// The Live Activity reconciles on it. Tests override it.
final hostSessionsSignalProvider = Provider<Object?>((ref) {
  final list = ref.watch(sessionsProvider);
  return list.hasValue && !list.isLoading ? list.value : null;
});

typedef PresenceRead = T Function<T>(ProviderListenable<T> provider);

/// [sessionId] once the active host's list is in (at most [timeout]; then
/// whatever is known, [SessionPresence.unknown] when nothing).
Future<SessionPresence> settledSessionPresence(
  PresenceRead read,
  String sessionId, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    await read(sessionsProvider.future).timeout(timeout);
  } catch (_) {
    // Not connected in time, or the read failed: judge by what there is.
  }
  return read(sessionPresenceProvider(sessionId));
}
