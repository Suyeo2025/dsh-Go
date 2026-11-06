// Manual order of a workspace's conversations (`workspace/insertSessionBefore`)
// and the row actions built on it: the DOM `insertBefore` reorder, the
// optimistic `moveSession` (shown at once, the Host's answer wins, rolled back
// on failure or silence), and the UI-free 置顶 / 上移 / 下移 functions.
//
//   flutter test test/drawer/move_session_test.dart

import 'dart:async';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/row_actions.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeRuntime, FakeSettings;
import '../workspace/support.dart';

/// [FakeWorkspaceHost] that also takes `workspace/insertSessionBefore` the
/// way rc.5 does: refuses unaccounted ids, moves like DOM `insertBefore`,
/// bumps `updatedAt`, follows with an `upsert` frame and answers `{workspace}`.
class OrderHost extends FakeWorkspaceHost {
  OrderHost() : super(folders: ['/root/a', '/root/b']);

  /// Holds the reply until completed.
  Completer<void>? gate;

  /// Never answer (a lost reply).
  bool silent = false;

  /// Refuse with this code.
  String? refuse;
  bool pushUpsert = true;
  int _tick = 0;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'workspace/insertSessionBefore') return super.call(endpoint, args, timeout: timeout);
    calls.add((endpoint, args));
    if (silent) return Completer<RpcResult>().future;
    await gate?.future;
    final request = (args['request']! as Map).cast<String, Object?>();
    if (refuse case final code?) return RpcError(DshRemoteException(code, code, request));
    final w = workspaces.where((w) => w['workspaceId'] == request['workspaceId']).firstOrNull;
    if (w == null) return RpcError(DshRemoteException(WorkspaceErrors.notFound, 'not found', request));
    final ids = (w['sessionIds']! as List).cast<String>();
    final id = request['sessionId']! as String;
    final before = request['beforeSessionId'] as String?;
    if (!ids.contains(id) || (before != null && !ids.contains(before))) {
      return RpcError(DshRemoteException(WorkspaceErrors.moveInvalid, 'not accounted', request));
    }
    w['sessionIds'] = sessionOrderAfterMove(ids, id, before);
    w['updatedAt'] = DateTime.utc(2026, 11, 1, 0, 0, ++_tick).toIso8601String();
    if (pushUpsert) push({'type': 'upsert', 'workspace': w});
    return RpcOk({'workspace': w});
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SessionSummary _s(String id) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime(2026, 10, 24),
  running: false,
  blank: false,
  agentAvailable: false,
  projections: SessionProjections(1, {'title': id}),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ProviderContainer, OrderHost)> ready({DrawerScope? scope}) async {
    final host = OrderHost();
    host.seedWorkspace('/root/b', sessionIds: ['s9']);
    host.seedWorkspace('/root/a', sessionIds: ['s1', 's2', 's3', 's4']);
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(workspaceHost(host))),
        localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true))),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        if (scope != null) drawerScopeProvider.overrideWithValue(scope),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(workspacesProvider, (_, _) {});
    addTearDown(sub.close);
    await _settle();
    expect(container.read(workspacesProvider).ready, isTrue);
    return (container, host);
  }

  List<String> order(ProviderContainer c, [String id = 'ws-2']) => c.read(workspacesProvider).byId(id)!.sessionIds;

  group('the reorder itself', () {
    test('sessionOrderAfterMove is DOM insertBefore', () {
      const ids = ['a', 'b', 'c', 'd'];
      expect(sessionOrderAfterMove(ids, 'd', 'b'), ['a', 'd', 'b', 'c']);
      expect(sessionOrderAfterMove(ids, 'a', 'd'), ['b', 'c', 'a', 'd']);
      expect(sessionOrderAfterMove(ids, 'b', null), ['a', 'c', 'd', 'b']);
      expect(sessionOrderAfterMove(ids, 'b', 'b'), ids);
      expect(sessionOrderAfterMove(ids, 'b', 'c'), ids);
      expect(sessionOrderAfterMove(ids, 'x', 'a'), ids);
      expect(sessionOrderAfterMove(ids, 'a', 'x'), ids);
    });

    test('moveAnchorFor gives the row that will follow, null at the end', () {
      const ids = ['a', 'b', 'c', 'd'];
      expect(moveAnchorFor(ids, 'a', 2), 'd');
      expect(moveAnchorFor(ids, 'd', 0), 'a');
      expect(moveAnchorFor(ids, 'b', 3), isNull);
      expect(moveAnchorFor(ids, 'b', 99), isNull);
      expect(moveAnchorFor(ids, 'c', -4), 'a');
      for (var to = 0; to < ids.length; to++) {
        final moved = sessionOrderAfterMove(ids, 'b', moveAnchorFor(ids, 'b', to));
        expect(moved.indexOf('b'), to);
      }
    });

    test('rowMoveAnchor moves inside the pinned zone or the rest, among listed rows', () {
      const order = ['p1', 'a', 'hidden', 'b', 'p2', 'c'];
      final listed = {'p1', 'a', 'b', 'p2', 'c'};
      final pinned = {'p1', 'p2'};
      String? anchor(String id, int delta) =>
          rowMoveAnchor(order: order, listed: listed, pinned: pinned, sessionId: id, delta: delta);
      // The rest: a, b, c.
      expect(anchor('b', -1), 'a');
      expect(anchor('a', 1), 'c');
      expect(anchor('b', 1), isNull);
      expect(anchor('c', rowMoveFirst), 'a');
      expect(anchor('a', rowMoveLast), isNull);
      expect(anchor('a', -1), rowMoveNowhere);
      expect(anchor('c', 1), rowMoveNowhere);
      // The pinned zone: p1, p2.
      expect(anchor('p2', -1), 'p1');
      expect(anchor('p1', 1), isNull);
      expect(anchor('p1', -1), rowMoveNowhere);
      // Applying the anchor really moves the row by that much in its zone.
      final moved = sessionOrderAfterMove(order, 'a', anchor('a', 1));
      expect([for (final id in moved) if (listed.contains(id) && !pinned.contains(id)) id], ['b', 'a', 'c']);
    });
  });

  group('WorkspacesController.moveSession', () {
    test('the new order shows at once; the Host answer then stands', () async {
      final (c, host) = await ready();
      expect(order(c), ['s1', 's2', 's3', 's4']);
      host.gate = Completer();
      final done = c.read(workspacesProvider.notifier).moveSession('ws-2', 's4', beforeId: 's2');
      // Optimistic: nothing has come back yet.
      expect(order(c), ['s1', 's4', 's2', 's3']);
      expect(host.argsOf('workspace/insertSessionBefore').single, {
        'request': {'workspaceId': 'ws-2', 'sessionId': 's4', 'beforeSessionId': 's2'},
      });
      host.gate!.complete();
      expect(await done, isTrue);
      await _settle();
      expect(order(c), ['s1', 's4', 's2', 's3']);
      expect(c.read(workspacesProvider).byId('ws-2')!.updatedAt, DateTime.utc(2026, 11, 1, 0, 0, 1));
    });

    test('the reply wins over the guess (another writer moved too)', () async {
      final (c, host) = await ready();
      host.gate = Completer();
      host.pushUpsert = false;
      final done = c.read(workspacesProvider.notifier).moveSession('ws-2', 's1');
      expect(order(c), ['s2', 's3', 's4', 's1']);
      // Meanwhile the Host's order changed elsewhere.
      final w = host.workspaces.firstWhere((w) => w['workspaceId'] == 'ws-2');
      w['sessionIds'] = ['s3', 's1', 's2', 's4'];
      host.gate!.complete();
      expect(await done, isTrue);
      expect(order(c), ['s3', 's2', 's4', 's1']);
    });

    test('to the end the anchor is left out', () async {
      final (c, host) = await ready();
      expect(await c.read(workspacesProvider.notifier).moveSession('ws-2', 's2'), isTrue);
      final request = host.argsOf('workspace/insertSessionBefore').single['request']! as Map;
      expect(request.containsKey('beforeSessionId'), isFalse);
      expect(order(c), ['s1', 's3', 's4', 's2']);
    });

    test('a refusal rolls the guess back and returns false', () async {
      final (c, host) = await ready();
      host.refuse = WorkspaceErrors.moveInvalid;
      host.gate = Completer();
      final done = c.read(workspacesProvider.notifier).moveSession('ws-2', 's3', beforeId: 's1');
      expect(order(c), ['s3', 's1', 's2', 's4']);
      host.gate!.complete();
      expect(await done, isFalse);
      expect(order(c), ['s1', 's2', 's3', 's4']);
    });

    test('no answer within the timeout rolls back too', () async {
      final (c, host) = await ready();
      host.silent = true;
      final started = DateTime.now();
      final saved = await c.read(workspacesProvider.notifier).moveSession('ws-2', 's1', beforeId: 's4');
      expect(saved, isFalse);
      expect(DateTime.now().difference(started), greaterThanOrEqualTo(WorkspacesController.moveTimeout));
      expect(order(c), ['s1', 's2', 's3', 's4']);
    });

    test('a later move owns the row: an earlier failure does not undo it', () async {
      final (c, host) = await ready();
      host.refuse = WorkspaceErrors.moveInvalid;
      host.gate = Completer();
      final notifier = c.read(workspacesProvider.notifier);
      final first = notifier.moveSession('ws-2', 's4', beforeId: 's1');
      final second = notifier.moveSession('ws-2', 's2');
      expect(order(c), ['s4', 's1', 's3', 's2']);
      host.gate!.complete();
      expect(await first, isFalse);
      expect(await second, isFalse);
      // The last one to fail goes back to the Host's order, not to the
      // earlier guess it was built on.
      expect(order(c), ['s1', 's2', 's3', 's4']);
    });

    test('nothing is sent for an unaccounted id, a bad anchor or the same place', () async {
      final (c, host) = await ready();
      final notifier = c.read(workspacesProvider.notifier);
      expect(() => notifier.moveSession('ws-2', 's9'), throwsStateError);
      expect(() => notifier.moveSession('ws-2', 's1', beforeId: 's9'), throwsStateError);
      expect(() => notifier.moveSession('gone', 's1'), throwsStateError);
      expect(await notifier.moveSession('ws-2', 's1', beforeId: 's2'), isTrue);
      expect(host.argsOf('workspace/insertSessionBefore'), isEmpty);
    });

    test('workspaceOf and pinnedInWorkspace', () async {
      final (c, host) = await ready();
      host.push({
        'type': 'pinned',
        'pinnedSessionIds': ['s3', 's9', 's1'],
      });
      await _settle();
      final state = c.read(workspacesProvider);
      expect(state.workspaceOf('s3')?.workspaceId, 'ws-2');
      expect(state.workspaceOf('s9')?.workspaceId, 'ws-1');
      expect(state.workspaceOf('nowhere'), isNull);
      expect(state.pinnedInWorkspace(state.byId('ws-2')!), ['s3', 's1']);
    });
  });

  group('row actions', () {
    DrawerScope scope({bool readOnly = false}) => DrawerScope(
      sessions: [for (final id in ['s1', 's2', 's3', 's4', 's9']) _s(id)],
      bots: const [],
      scoped: false,
      readOnly: readOnly,
    );

    test('moveRow steps inside the zone and writes the Host order', () async {
      final (c, host) = await ready(scope: scope());
      expect(await moveRowWith(c.read, 'ws-2', 's3', delta: -1), RowActionResult.ok);
      expect(order(c), ['s1', 's3', 's2', 's4']);
      expect(await moveRowWith(c.read, 'ws-2', 's1', delta: rowMoveLast), RowActionResult.ok);
      expect(order(c), ['s3', 's2', 's4', 's1']);
      final last = host.argsOf('workspace/insertSessionBefore').last['request']! as Map;
      expect(last.containsKey('beforeSessionId'), isFalse);
      // Already first: nothing to send.
      final sent = host.argsOf('workspace/insertSessionBefore').length;
      expect(await moveRowWith(c.read, 'ws-2', 's3', delta: rowMoveFirst), RowActionResult.ok);
      expect(host.argsOf('workspace/insertSessionBefore'), hasLength(sent));
      // Another workspace's row, or a refusal.
      expect(await moveRowWith(c.read, 'ws-2', 's9', delta: 1), RowActionResult.notAllowed);
      host.refuse = WorkspaceErrors.moveInvalid;
      expect(await moveRowWith(c.read, 'ws-2', 's2', delta: 1), RowActionResult.failed);
      expect(order(c), ['s3', 's2', 's4', 's1']);
    });

    test('a pinned row moves among the pinned ones only', () async {
      final (c, host) = await ready(scope: scope());
      await c.read(workspacesProvider.notifier).pinSession('s4');
      await c.read(workspacesProvider.notifier).pinSession('s2');
      // Pinned zone in the Host order: s2, s4. Moving s4 up puts it before s2.
      expect(await moveRowWith(c.read, 'ws-2', 's4', delta: -1), RowActionResult.ok);
      expect(order(c), ['s1', 's4', 's2', 's3']);
      expect(await moveRowWith(c.read, 'ws-2', 's4', delta: -1), RowActionResult.ok);
      expect(host.argsOf('workspace/insertSessionBefore'), hasLength(1));
    });

    test('togglePin pins and unpins through the registry', () async {
      final (c, host) = await ready(scope: scope());
      expect(await togglePinWith(c.read, 's2'), RowActionResult.ok);
      await _settle();
      expect(c.read(workspacesProvider).pinnedSessionIds, ['s2']);
      expect(await togglePinWith(c.read, 's2'), RowActionResult.ok);
      await _settle();
      expect(c.read(workspacesProvider).pinnedSessionIds, isEmpty);
      expect(host.argsOf('workspace/pinSession'), hasLength(1));
      expect(host.argsOf('workspace/unpinSession'), hasLength(1));
      expect(await togglePinWith(c.read, 'not-listed'), RowActionResult.notAllowed);
    });

    test('a read-only list allows nothing and sends nothing', () async {
      final (c, host) = await ready(scope: scope(readOnly: true));
      expect(await togglePinWith(c.read, 's1'), RowActionResult.notAllowed);
      expect(await archiveRowWith(c.read, 's1'), RowActionResult.notAllowed);
      expect(await moveRowWith(c.read, 'ws-2', 's1', delta: 1), RowActionResult.notAllowed);
      expect(
        host.calls.where((c) => c.$1.startsWith('workspace/') && c.$1 != 'workspace/follow'),
        isEmpty,
      );
    });
  });
}
