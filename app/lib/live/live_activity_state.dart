// The「鲸游」Live Activity's life on iOS (the Android status-bar activity is
// lib/state/live_activity_state.dart, a different thing).
//
// * Start, while the app is in front, 灵动岛 is on and the system allows Live
//   Activities (never on an iPad), for the conversation open on screen when:
//   - it starts running within a moment of a message sent from this phone;
//   - it has been running (started here or anywhere else) while open for
//     [islandDwellProvider]: on the home screen it is there already;
//   - the app is about to leave the screen (`inactive`) with it running and
//     the wait not over yet.
//   One Activity at a time: a new conversation ends the old one first, unless
//   the old one waits on the person (an approval or a question keeps it).
// * Update: while the app is in front, from the conversation's chat state
//   (every 2 s at most; a request appearing or going away, done and failed at
//   once). In the background the bridge takes over (live_activity_bridge_sync).
// * End: done → a last update (breachTick + 1) and an end that lingers 4 s;
//   failed → 15 min; stopped / forked → at once; opening the finished
//   conversation in the app → at once. The system's own end or dismissal
//   clears it here and tells the bridge.
// * After a relaunch the Activity the system still runs is taken over.
// * 灵动岛 switched off, or Live Activities off in Settings: everything ends.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart'
    show ApprovalRequest, TodoItem, ToolChatItem, TraceKind, TurnTrace, UserQuestionRequest;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../links/app_links.dart';
import '../platform/platform_caps.dart';
import '../push/push_state.dart';
import '../state/chat_focus.dart';
import '../state/chat_state.dart' show ChatState, chatProvider;
import '../state/drawer_view_state.dart' show drawerScopeProvider;
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show appForegroundProvider;
import '../state/session_attention_state.dart' show pendingInteractionsProvider;
import '../state/sessions_state.dart' show currentSessionProvider;
import '../ui/chat/media/media_format.dart' show chatTitleShown;
import '../ui/chat/run_info.dart' show RunActivity, runActivityOf;
import '../ui/chat/tool_view.dart';
import '../ui/common/discard_guard.dart';
import 'island_prefs_state.dart';
import 'live_activity_bridge_sync.dart';
import 'live_activity_channel.dart';
import 'live_activity_content.dart';

/// A turn that starts this long after a message sent from here counts as
/// started by it.
const islandLocalSendWindow = Duration(seconds: 2);

/// Device clock (tests pin it).
final islandClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Looking at a running conversation this long starts its Activity. Before
/// the app leaves the screen, not at the moment it leaves: ActivityKit only
/// starts one for an app in front, and `inactive` gives the native call a
/// few hundred milliseconds at most, so leaving is the second chance only.
final islandDwellProvider = Provider<Duration>((ref) => const Duration(seconds: 3));

/// The app is about to leave the screen (`AppLifecycleState.inactive`: going
/// home, the app switcher, a call; the notification shade too). Tests feed it.
final islandLeavingProvider = Provider<Stream<void>>((ref) {
  final leaving = StreamController<void>.broadcast();
  final listener = AppLifecycleListener(onInactive: () => leaving.add(null));
  ref.onDispose(() {
    listener.dispose();
    unawaited(leaving.close());
  });
  return leaving.stream;
});

/// At most one local update per this (requests and endings go at once).
final islandThrottleProvider = Provider<Duration>((ref) => const Duration(seconds: 2));

/// What the island needs of one conversation, out of its [ChatState]. Equal
/// views show the same Activity (streamed text doesn't change it).
class IslandSessionView {
  const IslandSessionView({
    this.running = false,
    this.synced = false,
    this.activity,
    this.approvals = const [],
    this.questions = const [],
    this.todos,
    this.tokens,
    this.lastTurnDuration,
    this.lastTurn,
    this.lastTurnTools = 0,
    this.clockSkew = Duration.zero,
    this.title,
    this.localSend = false,
    this.commands = const {},
  });

  factory IslandSessionView.of(ChatState s) {
    final approvals = [
      for (final a in s.approvals)
        if (!s.autoAnswered.contains(a.eventId)) a,
    ];
    final commands = <String, String>{};
    for (final a in approvals) {
      final callId = a.callId;
      if (callId == null) continue;
      for (final item in s.items.reversed) {
        if (item is ToolChatItem && item.callId == callId) {
          final command = ToolView.of(item).command;
          if (command != null && command.isNotEmpty) commands[a.eventId] = command;
          break;
        }
      }
    }
    Duration? lastDuration;
    for (final t in s.turns.reversed) {
      if (t.duration case final d?) {
        lastDuration = d;
        break;
      }
    }
    final last = s.turns.isEmpty ? null : s.turns.last;
    final usage = s.runningTurn?.usage;
    return IslandSessionView(
      running: s.running,
      synced: !s.loading && !s.syncing,
      activity: runActivityOf(s),
      approvals: approvals,
      questions: s.questions,
      todos: s.todos,
      tokens: usage == null || usage.isEmpty ? null : usage.total,
      lastTurnDuration: lastDuration,
      lastTurn: last,
      lastTurnTools: last == null ? 0 : last.spans.where((sp) => sp.kind == TraceKind.tool).length,
      clockSkew: s.clockSkew,
      title: s.title,
      localSend: s.pending.any((p) => p.inboxId == null && !p.isAutomatic && !p.failed),
      commands: commands,
    );
  }

  final bool running;

  /// A complete follow snapshot is applied (not loading or resyncing).
  final bool synced;
  final RunActivity? activity;

  /// Waiting on the person (auto-allowed ones left out).
  final List<ApprovalRequest> approvals;
  final List<UserQuestionRequest> questions;
  final List<TodoItem>? todos;
  final int? tokens;
  final Duration? lastTurnDuration;
  final TurnTrace? lastTurn;
  final int lastTurnTools;
  final Duration clockSkew;
  final String? title;

  /// A message sent from this phone hasn't reached the Host's inbox yet.
  final bool localSend;
  final Map<String, String> commands;

  static String _todoKey(List<TodoItem>? t) =>
      t == null ? '-' : '${t.length}/${t.where((x) => x.status == 'completed').length}';

  List<Object?> get _key => [
    running,
    synced,
    activity?.kind,
    activity?.toolName,
    activity?.turnStart,
    activity?.toolsDone,
    for (final a in approvals) a.eventId,
    '|',
    for (final q in questions) q.eventId,
    _todoKey(todos),
    tokens,
    lastTurnDuration,
    lastTurn?.turn,
    lastTurn?.end,
    lastTurn?.endReason?.kind,
    lastTurnTools,
    clockSkew,
    title,
    localSend,
    for (final e in commands.entries) '${e.key}=${e.value}',
  ];

  @override
  bool operator ==(Object other) {
    if (other is! IslandSessionView) return false;
    final a = _key, b = other._key;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_key);
}

/// One conversation's [IslandSessionView] (tests override it).
final islandSessionViewProvider = Provider.autoDispose.family<IslandSessionView, String>(
  (ref, sessionId) => IslandSessionView.of(ref.watch(chatProvider(sessionId))),
);

/// The other running top-level conversations of the active host, and which
/// conversations wait on the person (tests override it).
typedef IslandOthers = ({List<OtherRun> runs, Set<String> pending});

final islandOthersProvider = Provider<IslandOthers>((ref) {
  final sessions = ref.watch(drawerScopeProvider)?.sessions ?? const [];
  final pending = ref.watch(pendingInteractionsProvider);
  return (
    runs: [
      for (final s in sessions)
        if (s.running && !s.isSubagent)
          OtherRun(sessionId: s.sessionId, title: chatTitleShown(s.title ?? ''), startedAt: s.updatedAt),
    ],
    pending: pending.keys.toSet(),
  );
});

enum IslandSource { local, bridge }

class IslandState {
  const IslandState({
    this.activeSessionId,
    this.activityId,
    this.lastContent,
    this.source = IslandSource.local,
    this.host,
    this.lang = 'zh',
    this.ended = false,
  });

  /// The conversation the Activity follows; null: none.
  final String? activeSessionId;
  final String? activityId;

  /// What it shows (last sent from here); null after a takeover until the
  /// first local update.
  final IslandContent? lastContent;

  /// Who last fed it: this app, or the bridge (taken over after a relaunch).
  final IslandSource source;
  final HostRef? host;

  /// The Activity's language (fixed when it starts).
  final String lang;

  /// Ended here, still on screen until its dismissal.
  final bool ended;

  IslandState copyWith({IslandContent? lastContent, IslandSource? source, bool? ended}) => IslandState(
    activeSessionId: activeSessionId,
    activityId: activityId,
    lastContent: lastContent ?? this.lastContent,
    source: source ?? this.source,
    host: host,
    lang: lang,
    ended: ended ?? this.ended,
  );
}

/// Registers `dshgo://session/<id>` (the Activity's tap) with the link
/// router; returns the unregister function. Tests override it with a no-op.
final islandLinksProvider = Provider<VoidCallback Function(IslandController controller)>(
  (ref) =>
      (controller) => ref.read(linkRouterProvider).registerLinkHandler('session', controller.openLink),
);

class IslandController extends Notifier<IslandState> {
  final _subs = <StreamSubscription<Object?>>[];
  ProviderSubscription<IslandSessionView>? _currentSub;
  ProviderSubscription<IslandSessionView>? _activeSub;
  ProviderSubscription<IslandOthers>? _othersSub;
  String? _currentId;
  IslandSessionView? _currentView;
  IslandSessionView? _activeView;
  DateTime? _lastLocalSendAt;
  DateTime? _lastSentAt;
  bool _sawRunning = false;
  bool _starting = false;
  bool _finishing = false;
  Timer? _throttle;
  Timer? _expiry;
  final _askedAt = <String, DateTime>{};

  /// Waits [islandDwellProvider] on the running conversation open on screen.
  Timer? _dwell;

  /// The open conversation this run has already been tried for (watched or
  /// left): no second try until it stops running or another one opens.
  String? _triedFor;

  LiveActivityChannel get _channel => ref.read(liveActivityChannelProvider);
  LiveActivityBridgeSync get _bridge => ref.read(liveActivityBridgeSyncProvider);
  DateTime _now() => ref.read(islandClockProvider)();

  @override
  IslandState build() {
    ref.onDispose(_dispose);
    if (!isRemoteOnlyPlatform) return const IslandState();
    final channel = _channel..attach();
    _subs
      ..add(channel.pushTokens.listen((t) => unawaited(_onPushToken(t.sessionId, t.token))))
      ..add(channel.pushToStartTokens.listen((t) => unawaited(_bridge.onPushToStartToken(t))))
      ..add(channel.activityStates.listen(_onActivityState))
      ..add(channel.decisions.listen((_) => _schedule(urgent: true)))
      ..add(ref.read(islandLeavingProvider).listen((_) => _onLeaving()));
    final off = ref.read(islandLinksProvider)(this);
    ref.onDispose(off);
    ref.listen<IslandPrefs>(islandPrefsProvider, (previous, next) {
      _reevaluate();
      if (!next.loaded || previous?.mode == next.mode && previous?.loaded == true) return;
      if (next.mode == IslandMode.off) unawaited(_shutDown());
      unawaited(_bridge.onModeChanged(next.mode));
    });
    ref.listen<AsyncValue<LiveSupport>>(liveActivityStatusProvider, (previous, next) {
      _reevaluate();
      final now = next.value;
      if (now == null || !now.supported || now.enabled) return;
      if (previous?.value?.enabled == true || state.activeSessionId != null) unawaited(_shutDown());
    });
    ref.listen<bool>(appForegroundProvider, (previous, next) {
      if (next && previous == false) _onForeground();
    });
    // Conversations are watched for a message sent from here only while an
    // Activity could start (not on an iPad, not with 灵动岛 off).
    ref.listen<String?>(currentSessionProvider, (_, id) => _watchCurrent(_eligible ? id : null));
    scheduleMicrotask(() => unawaited(_adopt()));
    return const IslandState();
  }

  void _dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _throttle?.cancel();
    _expiry?.cancel();
    _dwell?.cancel();
    _currentSub?.close();
    _activeSub?.close();
    _othersSub?.close();
  }

  // ── Watching ────────────────────────────────────────────────────────────

  bool _eligible = false;

  void _reevaluate() {
    final support = ref.read(liveActivityStatusProvider).value;
    final eligible = ref.read(islandPrefsProvider).mode != IslandMode.off && (support?.usable ?? false);
    if (eligible == _eligible) return;
    _eligible = eligible;
    _watchCurrent(eligible ? ref.read(currentSessionProvider) : null);
  }

  void _watchCurrent(String? id) {
    if (id == _currentId) return;
    _currentSub?.close();
    _currentSub = null;
    _currentId = id;
    _currentView = null;
    _lastLocalSendAt = null;
    _dwell?.cancel();
    _dwell = null;
    _triedFor = null;
    if (id == null) return;
    _currentSub = ref.listen<IslandSessionView>(
      islandSessionViewProvider(id),
      (_, next) => _onCurrent(id, next),
      fireImmediately: true,
    );
    // Opening a finished conversation's Activity puts it away.
    if (state.activeSessionId == id && (state.lastContent?.finished ?? false) && ref.read(appForegroundProvider)) {
      scheduleMicrotask(() => unawaited(_endNow(id)));
    }
  }

  void _onCurrent(String id, IslandSessionView view) {
    if (id != _currentId) return;
    final previous = _currentView;
    _currentView = view;
    final now = _now();
    if (view.localSend) _lastLocalSendAt = now;
    final started = previous != null && !previous.running && view.running;
    final local = _lastLocalSendAt != null && now.difference(_lastLocalSendAt!) <= islandLocalSendWindow;
    if (started && local) {
      _dwell?.cancel();
      _dwell = null;
      _triedFor = id;
      scheduleMicrotask(() => unawaited(_start(id)));
      return;
    }
    _armDwell(id, view);
  }

  /// Whether the open conversation [id] could get an Activity now: running,
  /// fully loaded, and not the one already shown.
  bool _wants(String id, IslandSessionView? view) =>
      view != null && view.running && view.synced && !(state.activeSessionId == id && !state.ended);

  void _armDwell(String id, IslandSessionView view) {
    if (!view.running) {
      _dwell?.cancel();
      _dwell = null;
      if (_triedFor == id) _triedFor = null;
      return;
    }
    if (_dwell != null || _triedFor == id || !_wants(id, view)) return;
    _dwell = Timer(ref.read(islandDwellProvider), () {
      _dwell = null;
      if (_currentId != id || !_wants(id, _currentView)) return;
      _triedFor = id;
      unawaited(_start(id));
    });
  }

  /// Leaving the screen before the wait was over: try now, while still in front.
  void _onLeaving() {
    final id = _currentId;
    if (id == null || _triedFor == id || !_wants(id, _currentView)) return;
    _dwell?.cancel();
    _dwell = null;
    _triedFor = id;
    unawaited(_start(id));
  }

  /// The Activity on screen waits on the person: it isn't traded for another.
  bool get _activeWaits {
    if (state.activeSessionId == null || state.ended) return false;
    final view = _activeView;
    if (view != null && view.synced) return view.approvals.isNotEmpty || view.questions.isNotEmpty;
    return state.lastContent?.pending != null;
  }

  void _watchActive(String id) {
    _activeSub?.close();
    _othersSub?.close();
    _activeView = null;
    _sawRunning = false;
    _askedAt.clear();
    _activeSub = ref.listen<IslandSessionView>(
      islandSessionViewProvider(id),
      (_, next) => _onActive(id, next),
      fireImmediately: true,
    );
    _othersSub = ref.listen<IslandOthers>(islandOthersProvider, (_, _) => _schedule());
  }

  void _unwatchActive() {
    _activeSub?.close();
    _activeSub = null;
    _othersSub?.close();
    _othersSub = null;
    _activeView = null;
    _sawRunning = false;
    _throttle?.cancel();
    _throttle = null;
    _expiry?.cancel();
    _expiry = null;
    _askedAt.clear();
  }

  void _onActive(String id, IslandSessionView view) {
    if (id != state.activeSessionId) return;
    _activeView = view;
    final now = _now();
    final live = {for (final a in view.approvals) a.eventId, for (final q in view.questions) q.eventId};
    _askedAt.removeWhere((k, _) => !live.contains(k));
    for (final e in live) {
      _askedAt.putIfAbsent(e, () => now);
    }
    if (!view.synced) return;
    if (view.running) {
      _sawRunning = true;
    } else if (_sawRunning || state.source == IslandSource.bridge) {
      if (_canLocal) scheduleMicrotask(() => unawaited(_finish(id)));
      return;
    }
    _schedule();
  }

  bool get _canLocal {
    if (state.activeSessionId == null || state.ended) return false;
    if (!ref.read(appForegroundProvider)) return false;
    final host = state.host;
    return host == null || ref.read(activeHostProvider) == host;
  }

  void _onForeground() {
    final id = state.activeSessionId;
    if (id == null) return;
    if (state.ended) {
      if (_currentId == id && (state.lastContent?.finished ?? false)) unawaited(_endNow(id));
      return;
    }
    final view = _activeView;
    if (view != null && view.synced && !view.running && (_sawRunning || state.source == IslandSource.bridge)) {
      unawaited(_finish(id));
      return;
    }
    _schedule(urgent: true);
  }

  // ── Content ─────────────────────────────────────────────────────────────

  IslandContent _contentFor(String id, IslandSessionView view, {IslandFinish? finish, int? breachTick}) {
    final others = ref.read(islandOthersProvider);
    final runs = [
      for (final r in others.runs)
        if (r.sessionId != id) r,
    ];
    return islandContentOf(
      host: state.host ?? ref.read(activeHostProvider),
      sessionId: id,
      rawTitle: chatTitleShown(view.title ?? _summaryTitle(id) ?? ''),
      activity: view.activity,
      approvals: view.approvals,
      questions: view.questions,
      todos: view.todos,
      tokens: view.tokens,
      others: runs,
      othersPending: runs.where((r) => others.pending.contains(r.sessionId)).length,
      clockSkew: view.clockSkew,
      now: _now(),
      lang: state.lang,
      lastTurnDuration: view.lastTurnDuration,
      commands: view.commands,
      askedAt: _askedAt,
      finish: finish,
      turnStart: view.lastTurn?.start,
      breachTick: breachTick ?? state.lastContent?.breachTick ?? 0,
    );
  }

  String? _summaryTitle(String id) {
    for (final r in ref.read(islandOthersProvider).runs) {
      if (r.sessionId == id) return r.title;
    }
    return null;
  }

  // ── Start ───────────────────────────────────────────────────────────────

  Future<void> _start(String id) async {
    if (_starting || !ref.mounted) return;
    _starting = true;
    try {
      final prefs = ref.read(islandPrefsProvider.notifier);
      await prefs.ready;
      if (!ref.mounted || ref.read(islandPrefsProvider).mode == IslandMode.off) return;
      if (!ref.read(appForegroundProvider)) return;
      final support = await ref.read(liveActivityStatusProvider.future);
      if (!ref.mounted || !support.usable) return;
      final view = _currentId == id ? _currentView : _activeView;
      if (view == null || !view.running) return;
      if (state.activeSessionId == id && !state.ended) {
        _schedule(urgent: true);
        return;
      }
      final old = state.activeSessionId;
      // One waiting on the person stays (its buttons are the point).
      if (old != null && _activeWaits) return;
      if (old != null) {
        _unwatchActive();
        await _channel.end(sessionId: old, dismissal: LiveDismissal.immediate);
        unawaited(_bridge.forget(old));
        if (!ref.mounted) return;
        state = const IslandState();
      }
      final host = ref.read(activeHostProvider);
      final lang = islandLangOf(AppLocale.current);
      state = IslandState(activeSessionId: id, host: host, lang: lang);
      final content = _contentFor(id, view, breachTick: 0);
      final r = await _channel.start(
        sessionId: id,
        title: content.title,
        hostId: host.id,
        lang: lang,
        state: content.toMap(),
      );
      if (!ref.mounted) return;
      if (r.activityId == null || state.activeSessionId != id) {
        if (state.activeSessionId == id) state = const IslandState();
        return;
      }
      _lastSentAt = _now();
      state = IslandState(activeSessionId: id, activityId: r.activityId, lastContent: content, host: host, lang: lang);
      _watchActive(id);
    } finally {
      _starting = false;
    }
  }

  /// After a relaunch: the Activity the system still runs is ours again, and
  /// tokens the native side kept are reported.
  Future<void> _adopt() async {
    if (!ref.mounted) return;
    final support = await ref.read(liveActivityStatusProvider.future);
    if (!ref.mounted || !support.supported) return;
    final list = await _channel.list();
    if (!ref.mounted) return;
    final active = [
      for (final a in list)
        if (a.state == LiveActivityPhase.active) a,
    ];
    if (active.isNotEmpty && state.activeSessionId == null) {
      final first = active.first;
      for (final rest in active.skip(1)) {
        await _channel.end(sessionId: rest.sessionId, dismissal: LiveDismissal.immediate);
      }
      await ref.read(activeHostProvider.notifier).ready;
      if (!ref.mounted || state.activeSessionId != null) return;
      final prefs = ref.read(islandPrefsProvider.notifier);
      await prefs.ready;
      if (!ref.mounted || state.activeSessionId != null) return;
      if (ref.read(islandPrefsProvider).mode == IslandMode.off || !support.enabled) {
        await _shutDown();
        return;
      }
      final paired = ref.read(pushProvider).pairing?.hostId;
      state = IslandState(
        activeSessionId: first.sessionId,
        activityId: first.activityId,
        source: IslandSource.bridge,
        host: paired == null ? ref.read(activeHostProvider) : HostRef.direct(paired),
        lang: islandLangOf(AppLocale.current),
      );
      _watchActive(first.sessionId);
    }
    final pending = await _channel.takePendingTokens();
    if (!ref.mounted) return;
    for (final t in pending.activities) {
      await _onPushToken(t.sessionId, t.token);
    }
    if (pending.pushToStart case final token?) await _bridge.onPushToStartToken(token);
  }

  // ── Update ──────────────────────────────────────────────────────────────

  /// Sends the current content: at once when [urgent] or when a request came
  /// or went; otherwise at most once per [islandThrottleProvider].
  void _schedule({bool urgent = false}) {
    final id = state.activeSessionId;
    final view = _activeView;
    if (id == null || view == null || !view.synced || !view.running || !_canLocal || _finishing) return;
    final content = _contentFor(id, view);
    final last = state.lastContent;
    _armExpiry(content);
    if (content.sameAs(last)) return;
    final changed =
        last == null ||
        content.phase != last.phase ||
        content.pending?.eventId != last.pending?.eventId ||
        content.pending?.expired != last.pending?.expired;
    final throttle = ref.read(islandThrottleProvider);
    final now = _now();
    final since = _lastSentAt == null ? throttle : now.difference(_lastSentAt!);
    if (urgent || changed || (_throttle == null && since >= throttle)) {
      _throttle?.cancel();
      _throttle = null;
      unawaited(_send(id, content));
      return;
    }
    final wait = throttle - since;
    _throttle ??= Timer(wait.isNegative ? Duration.zero : wait, () {
      _throttle = null;
      _lastSentAt = null;
      _schedule();
    });
  }

  /// Wakes [_schedule] when the request's two minutes are over (the island
  /// trades its buttons for 「打开」).
  void _armExpiry(IslandContent content) {
    final p = content.pending;
    if (p == null || p.expired) {
      _expiry?.cancel();
      _expiry = null;
      return;
    }
    if (_expiry != null) return;
    final wait = p.approvalExpiresAt.difference(_now());
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      _expiry = null;
      _schedule();
    });
  }

  Future<void> _send(String id, IslandContent content) async {
    _lastSentAt = _now();
    state = state.copyWith(lastContent: content, source: IslandSource.local);
    _bridge.updateSnapshot(id, content);
    final ok = await _channel.update(sessionId: id, state: content.toMap());
    if (!ok && ref.mounted && state.activeSessionId == id && !state.ended) {
      // The system no longer has it (ended elsewhere).
      _clear(id);
    }
  }

  // ── End ─────────────────────────────────────────────────────────────────

  Future<void> _finish(String id) async {
    final view = _activeView;
    if (_finishing || view == null || state.activeSessionId != id || state.ended) return;
    _finishing = true;
    try {
      final turn = view.lastTurn;
      final kind = turn?.endReason?.kind ?? 'completed';
      if (kind == 'aborted' || kind == 'forked') {
        await _channel.end(sessionId: id, dismissal: LiveDismissal.immediate);
        _clear(id);
        return;
      }
      final failed = kind != 'completed';
      final end = turn?.end ?? _now().subtract(view.clockSkew);
      final finish = IslandFinish(
        failed: failed,
        start: turn?.start ?? end,
        end: end,
        steps: view.lastTurnTools,
        reason: failed ? turn?.endReason?.error?.message : null,
      );
      final breach = (state.lastContent?.breachTick ?? 0) + (failed ? 0 : 1);
      final content = _contentFor(id, view, finish: finish, breachTick: breach);
      state = state.copyWith(lastContent: content, ended: true);
      _unwatchActive();
      if (!failed) await _channel.update(sessionId: id, state: content.toMap());
      await _channel.end(
        sessionId: id,
        state: content.toMap(),
        dismissal: failed ? LiveDismissal.after15m : LiveDismissal.after4s,
      );
      unawaited(_bridge.forget(id));
      // Already looking at it: no need to linger.
      if (ref.mounted && _currentId == id && ref.read(appForegroundProvider) && failed) {
        await _endNow(id);
      }
    } finally {
      _finishing = false;
    }
  }

  /// Puts the Activity of [id] away now.
  Future<void> _endNow(String id) async {
    if (state.activeSessionId != id) return;
    await _channel.end(sessionId: id, dismissal: LiveDismissal.immediate);
    if (ref.mounted) _clear(id);
  }

  void _clear(String id) {
    if (state.activeSessionId != id) return;
    _unwatchActive();
    state = const IslandState();
    unawaited(_bridge.forget(id));
  }

  Future<void> _shutDown() async {
    _unwatchActive();
    if (ref.mounted) state = const IslandState();
    await _channel.endAll(dismissal: LiveDismissal.immediate);
    await _bridge.clear();
  }

  void _onActivityState(LiveStateChange change) {
    if (!change.state.over) return;
    if (state.activeSessionId == change.sessionId) {
      _clear(change.sessionId);
    } else {
      unawaited(_bridge.forget(change.sessionId));
    }
  }

  Future<void> _onPushToken(String sessionId, String token) async {
    if (!ref.mounted) return;
    if (state.activeSessionId == null) {
      // Started by the bridge (push-to-start) while the app was away.
      final paired = ref.read(pushProvider).pairing?.hostId;
      state = IslandState(
        activeSessionId: sessionId,
        source: IslandSource.bridge,
        host: paired == null ? ref.read(activeHostProvider) : HostRef.direct(paired),
        lang: islandLangOf(AppLocale.current),
      );
      _watchActive(sessionId);
    }
    final ours = state.activeSessionId == sessionId;
    final view = ours ? _activeView : null;
    final content =
        (ours ? state.lastContent : null) ??
        _contentFor(sessionId, view != null && view.synced ? view : const IslandSessionView(running: true));
    await _bridge.onPushToken(
      sessionId,
      token,
      content: content,
      lang: ours ? state.lang : islandLangOf(AppLocale.current),
      clockOffsetMs: (view?.clockSkew ?? Duration.zero).inMilliseconds,
    );
  }

  // ── Links ───────────────────────────────────────────────────────────────

  /// `dshgo://session/<id>[#event=<eventId>]`, the Activity's tap: opens that
  /// conversation on the Activity's host.
  Future<bool> openLink(Uri uri) async {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (uri.host.toLowerCase() != 'session' || segments.length != 1) return false;
    final id = segments.single;
    if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(id)) return false;
    final context = ref.read(linkRouterProvider).context;
    if (context == null || !context.mounted) return false;
    if (!await DiscardGuard.confirmLeave(context) || !context.mounted || !ref.mounted) return true;
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    final paired = ref.read(pushProvider).pairing?.hostId;
    final own = state.activeSessionId == id ? state.host : null;
    final HostRef host = own ?? (paired == null ? ref.read(activeHostProvider) : HostRef.direct(paired));
    ref.read(activeHostProvider.notifier).select(host);
    ref.read(currentSessionProvider.notifier).select(id);
    // `#event=<id>`: the approval / question card the Activity showed.
    if (linkFocusEventId(uri) case final eventId?) ref.read(chatFocusProvider.notifier).focus(id, eventId);
    return true;
  }
}

final islandControllerProvider = NotifierProvider<IslandController, IslandState>(IslandController.new);
