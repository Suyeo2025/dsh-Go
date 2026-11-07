// 定时任务提醒 (remote-only builds, plan/design/notify-v3-contract.md §3.3):
// whether an automation task's unattended run notifies always, only when it
// fails (the default), or never. Requests waiting on the person always
// notify, whatever this says (the bridge enforces it).
//
// Stored in SharedPreferences `schedule_notify_v1` as
// `{"default": "failures", "tasks": {"<scheduleId>": "always"|"failures"|"never"}}`
// (only what the person changed), and handed to the push bridge whole
// (`PUT /v1/device/schedule-notify`) on pairing, refresh and every change.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/platform_caps.dart';
import '../state/hosts_state.dart' show secretStoreProvider;
import 'bridge_client.dart';
import 'push_state.dart';

enum ScheduleNotify {
  always,
  failures,
  never;

  static ScheduleNotify? parse(Object? raw) => switch (raw) {
    'always' => always,
    'failures' => failures,
    'never' => never,
    _ => null,
  };
}

/// The bridge takes at most this many per-task choices.
const scheduleNotifyTasksMax = 200;

class ScheduleNotifyPrefs {
  const ScheduleNotifyPrefs({this.fallback = ScheduleNotify.failures, this.tasks = const {}, this.loaded = false});

  /// For tasks without a choice of their own.
  final ScheduleNotify fallback;
  final Map<String, ScheduleNotify> tasks;
  final bool loaded;

  ScheduleNotify of(String scheduleId) => tasks[scheduleId] ?? fallback;

  /// What the bridge assumes for a device that never sent anything.
  bool get isDefault => fallback == ScheduleNotify.failures && tasks.isEmpty;

  Map<String, Object?> toJson() => {
    'default': fallback.name,
    'tasks': {for (final e in tasks.entries) e.key: e.value.name},
  };

  static ScheduleNotifyPrefs fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final tasks = map['tasks'];
    return ScheduleNotifyPrefs(
      fallback: ScheduleNotify.parse(map['default']) ?? ScheduleNotify.failures,
      tasks: {
        if (tasks is Map)
          for (final MapEntry(:key, :value) in tasks.entries)
            if ((key, ScheduleNotify.parse(value)) case (final String k, final ScheduleNotify v)) k: v,
      },
      loaded: true,
    );
  }
}

/// How long before a failed send (network) is tried again, once.
final scheduleNotifyRetryDelayProvider = Provider<Duration>((ref) => const Duration(seconds: 30));

class ScheduleNotifyController extends Notifier<ScheduleNotifyPrefs> {
  static const prefsKey = 'schedule_notify_v1';
  static final _id = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

  late Future<void> _ready;
  Timer? _retry;

  Future<void> get ready => _ready;

  @override
  ScheduleNotifyPrefs build() {
    ref.onDispose(() => _retry?.cancel());
    if (!isRemoteOnlyPlatform) {
      _ready = Future.value();
      return const ScheduleNotifyPrefs(loaded: true);
    }
    _ready = _load();
    return const ScheduleNotifyPrefs();
  }

  Future<void> _load() async {
    var prefs = const ScheduleNotifyPrefs(loaded: true);
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      if (raw != null) prefs = ScheduleNotifyPrefs.fromJson(jsonDecode(raw));
    } catch (_) {
      // No preferences backend (tests) or a corrupt entry: the defaults.
    }
    if (ref.mounted) state = prefs;
  }

  Future<void> setDefault(ScheduleNotify value) =>
      _set(ScheduleNotifyPrefs(fallback: value, tasks: state.tasks, loaded: true));

  /// [value] null: the task follows the default again.
  Future<void> setTask(String scheduleId, ScheduleNotify? value) {
    if (!_id.hasMatch(scheduleId)) return Future.value();
    final tasks = {...state.tasks}..remove(scheduleId);
    if (value != null && value != state.fallback) {
      if (tasks.length >= scheduleNotifyTasksMax) return Future.value();
      tasks[scheduleId] = value;
    }
    return _set(ScheduleNotifyPrefs(fallback: state.fallback, tasks: tasks, loaded: true));
  }

  Future<void> _set(ScheduleNotifyPrefs next) async {
    if (!isRemoteOnlyPlatform) return;
    await _ready;
    if (!ref.mounted) return;
    state = next;
    try {
      await (await SharedPreferences.getInstance()).setString(prefsKey, jsonEncode(next.toJson()));
    } catch (_) {}
    await sync();
  }

  /// Hands the whole choice to the paired bridge; false when it didn't get
  /// there. A network failure is tried again once. [ifChosen] (pairing,
  /// refresh): nothing to send while it is all the bridge's own default.
  Future<bool> sync({bool retry = true, bool ifChosen = false}) async {
    if (!isRemoteOnlyPlatform) return false;
    await _ready;
    if (ifChosen && state.isDefault) return false;
    final push = ref.read(pushProvider.notifier);
    await push.ready;
    if (!ref.mounted) return false;
    final pairing = ref.read(pushProvider).pairing;
    final base = pairing == null ? null : normalizeBridgeUrl(pairing.bridge);
    if (pairing == null || base == null) return false;
    String? token;
    try {
      token = await ref.read(secretStoreProvider).read(PushController.deviceTokenKey);
    } catch (_) {
      token = null;
    }
    if (token == null || !ref.mounted) return false;
    try {
      await ref.read(bridgeClientFactoryProvider)(base, pin: pairing.pin).putScheduleNotify(token, state.toJson());
      _retry?.cancel();
      return true;
    } on BridgeException catch (e) {
      if (e.code == 'network' && retry && ref.mounted) {
        _retry?.cancel();
        _retry = Timer(ref.read(scheduleNotifyRetryDelayProvider), () => unawaited(sync(retry: false)));
      }
      return false;
    }
  }
}

final scheduleNotifyProvider = NotifierProvider<ScheduleNotifyController, ScheduleNotifyPrefs>(
  ScheduleNotifyController.new,
);
