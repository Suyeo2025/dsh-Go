// 「DeepSeek API Key」 on a remote host: write or clear the key the host keeps
// in its own credential store (`credentials/set` / `credentials/unset`).
// The value is typed into the sheet's field and goes to the host, nowhere
// else: it is not logged, shown again or kept by the app.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/models_state.dart';
import '../engine_settings/field_sheets.dart' show showSecretSheet;

const _deepSeekRef = 'DEEPSEEK_API_KEY';

/// What the active remote host says about its DeepSeek key
/// (`credentials/describe`): configured, and whether it is writable (not when
/// the launch environment supplies it). Null on the local engine, while
/// disconnected and on a host without `credentials/*`: the row then stays
/// read-only.
final remoteDeepSeekCredentialProvider = FutureProvider.autoDispose<CredentialStatus?>((ref) async {
  final conn = ref.watch(activeConnectionProvider).value;
  if (conn == null || conn.isLocal) return null;
  final client = conn.client;
  final sub = client.hostEvents.listen((event) {
    if (event is CredentialUpdatedEvent && ref.mounted) ref.invalidateSelf();
  });
  ref.onDispose(() => unawaited(sub.cancel()));
  try {
    return (await client.describeCredentials(const [_deepSeekRef]))[_deepSeekRef];
  } catch (_) {
    return null;
  }
});

/// Opens the key sheet for the active remote host. Does nothing when the host
/// has no credential store ([remoteDeepSeekCredentialProvider] is null).
Future<void> showRemoteDeepSeekKeySheet(BuildContext context, WidgetRef ref) async {
  final client = ref.read(activeConnectionProvider).value?.client;
  final status = ref.read(remoteDeepSeekCredentialProvider).value;
  if (client == null || status == null) return;
  // The card may be rebuilt away while the sheet is open: refresh through the
  // container, not the card's ref.
  final container = ProviderScope.containerOf(context, listen: false);
  void refresh() {
    container.invalidate(modelCatalogProvider);
    container.invalidate(remoteDeepSeekCredentialProvider);
  }

  await showSecretSheet(
    context,
    title: context.l10n.hostParityDeepSeekKeyTitle,
    configured: status.configured,
    writable: status.writable,
    onSave: (value) async {
      await client.setProviderKey(value, ref: _deepSeekRef);
      refresh();
    },
    onClear: () async {
      await client.clearProviderKey(ref: _deepSeekRef);
      refresh();
    },
  );
}
