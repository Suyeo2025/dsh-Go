// Opening a conversation from outside the app (the Live Activity's
// `dshgo://session/<id>`, a push tap): the host decides whether it is still
// there (plan/design/sync-contract.md §2). Archived: it opens read-only with a
// note; deleted: it doesn't open, a note says so. Either way its Activity goes.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';
import '../state/chat_focus.dart';
import '../state/hosts_state.dart';
import '../state/sessions_state.dart' show currentSessionProvider;
import '../ui/common/brief_notice.dart';
import 'session_presence.dart';

/// Opens [sessionId] on [host] (its card [eventId] in view) unless the host
/// no longer has it. [retire] puts its Live Activity away.
Future<SessionPresence> openSessionChecked({
  required PresenceRead read,
  required BuildContext? Function() context,
  required HostRef host,
  required String sessionId,
  String? eventId,
  Future<void> Function(String sessionId)? retire,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final previousHost = read(activeHostProvider);
  final previousSession = read(currentSessionProvider);
  // As ChatAlertsController.open: selecting also stops a still-pending
  // restore of the last host from switching away on a cold start.
  read(activeHostProvider.notifier).select(host);
  var presence = read(sessionPresenceProvider(sessionId));
  if (presence == SessionPresence.unknown) {
    presence = await settledSessionPresence(read, sessionId, timeout: timeout);
  }
  void notice(String Function(L10n l) text) {
    final c = context();
    if (c != null && c.mounted) showBriefNotice(c, text(c.l10n));
  }

  switch (presence) {
    case SessionPresence.gone:
      // Stay where the person was.
      if (previousHost != host) read(activeHostProvider.notifier).select(previousHost);
      if (read(currentSessionProvider) != previousSession) {
        read(currentSessionProvider.notifier).select(previousSession);
      }
      notice((l) => l.sessionGoneNotice);
      if (retire != null) unawaited(retire(sessionId));
    case SessionPresence.archived:
      read(currentSessionProvider.notifier).select(sessionId);
      notice((l) => l.sessionArchivedNotice);
      if (retire != null) unawaited(retire(sessionId));
    case SessionPresence.live || SessionPresence.unknown:
      read(currentSessionProvider.notifier).select(sessionId);
      if (eventId != null) read(chatFocusProvider.notifier).focus(sessionId, eventId);
  }
  return presence;
}
