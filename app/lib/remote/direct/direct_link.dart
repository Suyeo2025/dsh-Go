import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'direct_host_config.dart';

/// Builds the (not yet connected) client for [baseUri]; tests swap in fakes.
typedef DirectClientFactory = DshClient Function(Uri baseUri);

DshClient _defaultClient(Uri baseUri) => DshClient(DshConnection(baseUri));

/// Persists the session cookie a login bought (null forgets it).
typedef DirectCookieSaver = Future<void> Function(DshCookie? cookie);

/// A `dsh web` reachable at its own URL (`--trusted-host`, usually behind a
/// TLS reverse proxy): no tunnel and no engine to start, just DSH's own
/// login. The stored session cookie comes first (it outlives `dsh web`
/// restarts); when the Host refuses it the stored launch token logs in again;
/// when that is stale too the link fails with [HostLinkErrorKind.authFailed]
/// until a new token is saved.
///
/// The Host runs the stock DSH, without dsh-go's bridge (`/dsh-go/v1/*`):
/// like an SSH host, the client's bridge calls find no routes and the app
/// keeps those features off.
class DirectHostLink implements HostLink {
  DirectHostLink({
    required this._config,
    required this._loadSecrets,
    required this._saveCookie,
    DirectClientFactory? clientFactory,
    Stream<void>? kicks,
    Backoff? backoff,
    this.readyTimeout = const Duration(seconds: 20),
    this.healthTimeout = const Duration(seconds: 15),
    this.retryFirstOpen = true,
    this._awayFor,
    this.refreshGrace = const Duration(seconds: 10),
  }) : _clientFactory = clientFactory ?? _defaultClient,
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  DirectHostConfig _config;
  final Future<DirectSecrets> Function() _loadSecrets;
  final DirectCookieSaver _saveCookie;
  final DirectClientFactory _clientFactory;
  final Backoff _backoff;
  final Duration readyTimeout;
  final Duration healthTimeout;

  /// False for "测试连接": report the first failure instead of retrying.
  final bool retryFirstOpen;

  /// How long the app was just away from the foreground (null: unknown, or
  /// this kick is not a resume); see `appSuspension` in network_watch.dart.
  final Duration? Function()? _awayFor;

  /// Back after this long: the socket is taken for dead and replaced at once.
  static const resumeReconnectAfter = Duration(seconds: 20);

  /// Deadline for the health probe after a short absence or a network change.
  static const probeTimeout = Duration(seconds: 5);

  /// How long a self-started reconnect shows plain "重新连接中" before the
  /// usual "无法连接" error (the mux reports a failing attempt only once).
  final Duration refreshGrace;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _published = false;
  bool _relogging = false;
  int _reconnects = 0;

  /// A reconnect the link started itself (resume, failed probe) is under way.
  bool _refreshing = false;
  Timer? _refreshTimer;
  bool _probing = false;

  DirectHostConfig get config => _config;

  /// The session cookie the connected client signs in with (for the 网页版).
  DshCookie? get cookie => currentClient?.connection.cookie;

  /// Takes a rename in place (a new URL needs a new link).
  void updateConfig(DirectHostConfig next) {
    if (next.connectionKey == _config.connectionKey) _config = next;
  }

  @override
  HostLinkStatus get status => _status;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  void _emit(HostLinkStatus next) {
    if (_closed) return;
    _status = next;
    _statuses.add(next);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = currentClient;
    if (client != null) return Future.value(client);
    return _opening ??= _run().whenComplete(() => _opening = null);
  }

  Future<DshClient> _run() async {
    _backoff.reset();
    var last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, retryable: true);
    while (!_closed) {
      try {
        return await _connectOnce();
      } on HostLinkError catch (e) {
        last = e;
      } catch (e) {
        if (_closed) break;
        last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, detail: '$e', retryable: true);
      }
      if (_closed || !last.retryable || !retryFirstOpen || _backoff.exhausted) break;
      final delay = _backoff.next();
      _emit(
        HostLinkStatus(
          HostLinkPhase.reconnecting,
          attempt: _backoff.attempt,
          error: last,
          nextRetryAt: DateTime.now().add(delay),
        ),
      );
      await _delay.wait(delay);
    }
    if (_closed) throw StateError('link closed');
    _emit(HostLinkStatus(HostLinkPhase.failed, step: _status.step, completed: _status.completed, error: last));
    throw last;
  }

  void _checkOpen() {
    if (_closed) throw StateError('link closed');
  }

  /// One attempt: cookie first, then the launch token, then the mux.
  Future<DshClient> _connectOnce() async {
    var step = _status.withStep(HostLinkStep.connect, detail: _config.address);
    _emit(step);
    final secrets = await _loadSecrets();
    _checkOpen();

    // A client that gave up (stale login, lost Host) is not coming back:
    // every attempt starts from a fresh one, published through [clients].
    final previous = _client;
    _client = null;
    await _muxSub?.cancel();
    _muxSub = null;
    if (previous != null) unawaited(previous.close().catchError((_) {}));

    final client = _clientFactory(_config.baseUri);
    try {
      final connection = client.connection;
      var cookie = secrets.cookie;
      if (cookie != null && (cookie.authority != connection.authority || cookie.isExpiredAt(DateTime.now()))) {
        cookie = null;
        await _forgetCookie();
      }
      if (cookie != null) {
        connection.cookie = cookie;
        switch (await connection.checkHealth(timeout: healthTimeout)) {
          case DshHealth.ok:
            break;
          case DshHealth.unreachable:
            throw _unreachable();
          case DshHealth.unauthorized:
            connection.cookie = null;
            cookie = null;
            await _forgetCookie();
        }
        _checkOpen();
      }
      step = step.withStep(HostLinkStep.login);
      _emit(step);
      if (cookie == null) await _login(connection, secrets.token);
      _checkOpen();
      try {
        await client.mux.ready(timeout: readyTimeout);
      } on DshHttpException catch (e) {
        if (e.isForbidden) throw _forbidden(e);
        // A cookie the WebSocket refuses is no good for HTTP either.
        await _forgetCookie();
        throw HostLinkError(
          HostLinkErrorKind.loginFailed,
          appL10n.directErrSignInExpired,
          detail: '$e',
          retryable: true,
        );
      } on DshException catch (e) {
        throw HostLinkError(HostLinkErrorKind.unreachable, _unreachable().message, detail: '$e', retryable: true);
      }
      _checkOpen();
    } catch (_) {
      unawaited(client.close().catchError((_) {}));
      rethrow;
    }
    _client = client;
    _watchMux(client);
    _reconnects = 0;
    _emit(_connected());
    if (_published) _clients.add(client);
    _published = true;
    return client;
  }

  HostLinkStatus _connected() =>
      HostLinkStatus(HostLinkPhase.connected, completed: HostLinkStep.values.toSet(), detail: _config.address);

  /// Exchanges the launch token for a cookie and stores it.
  Future<void> _login(DshConnection connection, String? token) async {
    if (token == null || token.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.directErrTokenNeeded);
    }
    final DshCookie minted;
    try {
      minted = await connection.login(token);
    } on DshHttpException catch (e) {
      if (e.isUnauthorized) {
        throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.directErrTokenRejected, detail: '$e');
      }
      if (e.isForbidden) throw _forbidden(e);
      // 404 and friends: something else answers at this address.
      throw HostLinkError(
        HostLinkErrorKind.loginFailed,
        e.statusCode >= 500 ? appL10n.directErrSignIn : appL10n.directErrNotDsh,
        detail: '$e',
        retryable: e.statusCode >= 500,
      );
    } on DshTransportException catch (e) {
      throw HostLinkError(HostLinkErrorKind.unreachable, _unreachable().message, detail: '$e', retryable: true);
    } on DshProtocolException catch (e) {
      throw HostLinkError(HostLinkErrorKind.loginFailed, appL10n.directErrNotDsh, detail: '$e');
    }
    await _saveCookie(minted);
  }

  Future<void> _forgetCookie() => _saveCookie(null).catchError((_) {});

  HostLinkError _unreachable() =>
      HostLinkError(HostLinkErrorKind.unreachable, appL10n.directErrUnreachable(_config.address), retryable: true);

  HostLinkError _forbidden(Object e) =>
      HostLinkError(HostLinkErrorKind.loginFailed, appL10n.directErrForbidden(_config.baseUri.host), detail: '$e');

  /// The mux keeps itself alive (ping, backoff); the link mirrors it and
  /// logs in again with the stored token when the Host stops taking the cookie.
  void _watchMux(DshClient client) {
    _muxSub = client.mux.states.listen((state) {
      if (!identical(client, _client) || _closed) return;
      switch (state) {
        case DshConnectionState.connected:
          _endRefresh();
          _reconnects = 0;
          if (_status.phase != HostLinkPhase.connected) _emit(_connected());
        case DshConnectionState.connecting || DshConnectionState.reconnecting:
          if (_status.phase == HostLinkPhase.failed) return;
          _reconnects++;
          // The drop we asked for: keep showing "重新连接中" without an error.
          if (_refreshing && _reconnects == 1) return;
          _endRefresh();
          _emit(HostLinkStatus(HostLinkPhase.reconnecting, attempt: _reconnects, error: _unreachable()));
        case DshConnectionState.unauthorized:
          _endRefresh();
          unawaited(_relogin(client));
        case DshConnectionState.idle || DshConnectionState.closed:
          break;
      }
    });
  }

  Future<void> _relogin(DshClient client) async {
    if (_relogging) return;
    _relogging = true;
    try {
      _emit(
        HostLinkStatus(
          HostLinkPhase.reconnecting,
          step: HostLinkStep.login,
          attempt: ++_reconnects,
          error: HostLinkError(HostLinkErrorKind.loginFailed, appL10n.directErrSignInExpired, retryable: true),
        ),
      );
      final connection = client.connection;
      final rejected = connection.cookie;
      connection.cookie = null;
      if (rejected != null) await _forgetCookie();
      final secrets = await _loadSecrets();
      if (_closed || !identical(client, _client)) return;
      await _login(connection, secrets.token);
      if (_closed || !identical(client, _client)) return;
      client.mux.reconnect();
    } on HostLinkError catch (e) {
      if (!_closed && identical(client, _client)) {
        _emit(HostLinkStatus(HostLinkPhase.failed, error: e));
      }
    } catch (e) {
      if (!_closed && identical(client, _client)) {
        _emit(
          HostLinkStatus(
            HostLinkPhase.failed,
            error: HostLinkError(
              HostLinkErrorKind.other,
              appL10n.commonConnectionFailed,
              detail: '$e',
              retryable: true,
            ),
          ),
        );
      }
    } finally {
      _relogging = false;
    }
  }

  @override
  void kick() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.reconnecting:
        if (_opening != null) {
          _backoff.reset();
          _delay.skip();
        } else if (!_relogging) {
          _client?.mux.reconnect();
        }
      case HostLinkPhase.failed:
        if (_status.error?.retryable ?? false) retry();
      case HostLinkPhase.connected:
        final client = _client;
        if (client == null) return;
        Duration? away;
        try {
          away = _awayFor?.call();
        } catch (_) {
          away = null;
        }
        if (away != null && away >= resumeReconnectAfter) {
          // Long enough in the background that the socket is gone (iOS
          // suspends the app): no point probing first, reconnect now.
          _refresh(client);
        } else {
          // A quick switch or a network change: ask the Host rather than wait
          // up to a mux ping interval to learn the socket died.
          unawaited(_probe(client));
        }
      case HostLinkPhase.idle || HostLinkPhase.connecting:
        break;
    }
  }

  /// Replaces [client]'s socket now, showing "重新连接中" (no error) until the
  /// mux is back, fails a second time, or [refreshGrace] runs out.
  void _refresh(DshClient client) {
    if (_closed || !identical(client, _client)) return;
    _refreshing = true;
    _reconnects = 0;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(refreshGrace, () {
      _refreshTimer = null;
      if (!_refreshing || _closed || !identical(client, _client)) return;
      _refreshing = false;
      if (_status.phase != HostLinkPhase.reconnecting || _status.error != null) return;
      _emit(HostLinkStatus(HostLinkPhase.reconnecting, attempt: ++_reconnects, error: _unreachable()));
    });
    _emit(HostLinkStatus(HostLinkPhase.reconnecting, detail: _config.address));
    _backoff.reset();
    client.mux.reconnect();
  }

  void _endRefresh() {
    _refreshing = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// One health check of the connected [client]; acts only on a clear answer.
  Future<void> _probe(DshClient client) async {
    if (_probing) return;
    _probing = true;
    final DshHealth health;
    try {
      health = await client.connection.checkHealth(timeout: probeTimeout);
    } catch (_) {
      return;
    } finally {
      _probing = false;
    }
    if (_closed || !identical(client, _client)) return;
    // The mux may have noticed on its own meanwhile; leave it to that.
    if (_status.phase != HostLinkPhase.connected) return;
    switch (health) {
      case DshHealth.ok:
        break;
      case DshHealth.unreachable:
        _refresh(client);
      case DshHealth.unauthorized:
        unawaited(_relogin(client));
    }
  }

  /// "重试": skips a wait, or connects again from scratch (re-reading the
  /// stored token, which the person may just have replaced).
  @override
  void retry() {
    if (_closed) return;
    if (_status.phase == HostLinkPhase.reconnecting) {
      kick();
      return;
    }
    if (_status.isBusy) return;
    if (_status.phase == HostLinkPhase.connected) {
      _client?.mux.reconnect();
      return;
    }
    unawaited(open().then((_) {}, onError: (_) {}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _emit(HostLinkStatus.idle);
    _closed = true;
    _endRefresh();
    _delay.cancel();
    await _kickSub?.cancel();
    await _muxSub?.cancel();
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}
