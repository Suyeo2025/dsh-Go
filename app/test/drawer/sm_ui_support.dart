// Shared setup for the drawer's session-management UI tests (正在发生, the
// workspace tree, dragging, the swipe keys): the list over fixed providers and
// a workspace registry that records what the rows ask of the Host.

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/happening_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_list.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

SessionSummary smSession(String id, {bool running = false, Duration age = Duration.zero}) => SessionSummary(
  sessionId: id,
  updatedAt: sampleNow.subtract(age),
  running: running,
  blank: false,
  agentAvailable: running,
  projections: SessionProjections(1, {'title': 'T-$id'}),
);

Workspace smWorkspace(String id, List<String> sessionIds) =>
    Workspace(workspaceId: id, path: '/root/$id', title: 'W-$id', sessionIds: sessionIds);

/// A ready registry; moves and pins are recorded, and answer as told.
class RecordingWorkspaces extends WorkspacesController {
  RecordingWorkspaces(this.initial);

  final WorkspacesState initial;
  final moves = <(String, String, String?)>[];
  final pins = <(String, bool)>[];

  /// What [moveSession] answers (false: the Host refused or went silent).
  bool moveSaves = true;

  @override
  WorkspacesState build() => initial;

  @override
  Future<bool> moveSession(String workspaceId, String sessionId, {String? beforeId}) async {
    moves.add((workspaceId, sessionId, beforeId));
    if (!moveSaves) return false;
    state = state.copyWith(
      workspaces: [
        for (final w in state.workspaces)
          w.workspaceId == workspaceId
              ? Workspace(
                  workspaceId: w.workspaceId,
                  path: w.path,
                  title: w.title,
                  sessionIds: sessionOrderAfterMove(w.sessionIds, sessionId, beforeId),
                )
              : w,
      ],
    );
    return true;
  }

  @override
  Future<void> pinSession(String sessionId) async {
    pins.add((sessionId, true));
    state = state.copyWith(pinnedSessionIds: [sessionId, ...state.pinnedSessionIds]);
  }

  @override
  Future<void> unpinSession(String sessionId) async {
    pins.add((sessionId, false));
    state = state.copyWith(pinnedSessionIds: [...state.pinnedSessionIds]..remove(sessionId));
  }
}

/// The drawer list alone (320 × 600), animations off unless [animations].
Future<ProviderContainer> pumpSmList(
  WidgetTester tester, {
  required List<SessionSummary> sessions,
  RecordingWorkspaces? workspaces,
  DrawerView view = const DrawerView(loaded: true),
  Map<String, PendingKind> pending = const {},
  void Function(SessionSummary session, String? workspaceId)? onMore,
  ValueChanged<SessionSummary>? onLongPress,
  bool animations = false,
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues(storedView(view));
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      overrides: [
        drawerScopeProvider.overrideWithValue(DrawerScope(sessions: sessions, bots: const [], scoped: false)),
        workspacesProvider.overrideWith(
          () => workspaces ?? RecordingWorkspaces(const WorkspacesState(status: WorkspacesStatus.ready)),
        ),
        currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
        pendingInteractionsProvider.overrideWith(() => FixedPending(pending)),
        unreadSessionIdsProvider.overrideWithValue(const {}),
        happeningFeedProvider.overrideWith(_NoFeed.new),
        ...overrides,
      ],
      home: ScaffoldMessenger(
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 600,
              child: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: !animations),
                  child: Consumer(
                    builder: (context, ref, _) {
                      if (!ref.watch(drawerViewProvider).loaded) return const SizedBox.shrink();
                      return DrawerConversationList(
                        now: sampleNow,
                        onOpen: (_) {},
                        onLongPress: onLongPress ?? (_) {},
                        onMore: onMore,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return ProviderScope.containerOf(tester.element(find.byType(DrawerConversationList)));
}

class _NoFeed extends HappeningFeedController {
  @override
  Map<String, RunDigest> build() => const {};
}

/// Lets the async row actions finish.
Future<void> settleActions(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// A row's title in the list.
Finder smTitle(String id) => find.text('T-$id');
