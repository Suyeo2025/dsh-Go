// 设置 → 推送通知 (remote-only builds): pair this phone with the push bridge
// on the server, see where the pushes stand, unpair.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';
import '../ui/common/app_dialog.dart';
import '../ui/common/status_chip.dart';
import '../ui/phone/phone_widgets.dart';
import '../ui/providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../ui/settings/settings_widgets.dart';
import '../ui/shell/page_frame.dart';
import '../ui/theme/app_icons.dart';
import '../ui/theme/theme.dart';
import 'push_state.dart';

String pushHealthLabel(L10n l10n, PushHealth health) => switch (health) {
  PushHealth.off => l10n.pushStatusOff,
  PushHealth.needsPermission => l10n.pushStatusNeedsPermission,
  PushHealth.registering => l10n.pushStatusRegistering,
  PushHealth.on => l10n.pushStatusOn,
  PushHealth.tokenFailed => l10n.pushStatusTokenFailed,
  PushHealth.unreachable => l10n.pushStatusUnreachable,
  PushHealth.revoked => l10n.pushStatusRevoked,
};

StatusTone pushHealthTone(PushHealth health) => switch (health) {
  PushHealth.off => StatusTone.idle,
  PushHealth.registering => StatusTone.busy,
  PushHealth.on => StatusTone.ok,
  PushHealth.needsPermission || PushHealth.unreachable => StatusTone.warn,
  PushHealth.tokenFailed || PushHealth.revoked => StatusTone.error,
};

String pushPairProblemText(L10n l10n, PushPairException e) => switch (e.problem) {
  PushPairProblem.bridgeUrlInvalid => l10n.pushErrBridgeUrl,
  PushPairProblem.noDirectHost => l10n.pushErrNoHost,
  PushPairProblem.notSignedIn => l10n.pushErrNotSignedIn,
  PushPairProblem.notABridge => l10n.pushErrNotABridge,
  PushPairProblem.unreachable => l10n.pushErrUnreachable,
  PushPairProblem.badCertificate => l10n.pushErrCertificate,
  PushPairProblem.dshRejected => l10n.pushErrDshRejected,
  PushPairProblem.dshPairingOff => l10n.pushErrDshPairingOff,
  PushPairProblem.codeInvalid =>
    e.attemptsRemaining == null ? l10n.pushErrCodeInvalid : l10n.pushErrCodeInvalidLeft(e.attemptsRemaining!),
  PushPairProblem.codeExpired => l10n.pushErrCodeExpired,
  PushPairProblem.locked || PushPairProblem.rateLimited => l10n.pushErrLocked,
  PushPairProblem.failed => l10n.pushErrFailed,
};

/// The hub row: 推送通知 and where it stands.
class PushSettingsTile extends ConsumerWidget {
  const PushSettingsTile({super.key, this.tint = 3});

  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(pushProvider.select((s) => s.health));
    final colors = DshColors.of(context);
    final warn = health != PushHealth.off && health != PushHealth.on && health != PushHealth.registering;
    return SettingsTile(
      icon: AppIcons.notificationsOn,
      tint: tint,
      spot: SettingsIndex.entry(SettingsPageId.pushNotifications),
      value: Text(pushHealthLabel(context.l10n, health), style: warn ? TextStyle(color: colors.warning) : null),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PushSettingsPage())),
    );
  }
}

class PushSettingsPage extends ConsumerStatefulWidget {
  const PushSettingsPage({super.key});

  @override
  ConsumerState<PushSettingsPage> createState() => _PushSettingsPageState();
}

class _PushSettingsPageState extends ConsumerState<PushSettingsPage> {
  final _bridge = TextEditingController();
  AppLifecycleListener? _lifecycle;
  String? _hostId;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Back from iOS Settings: the permission may have changed.
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(pushProvider.notifier).refresh()));
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _bridge.dispose();
    super.dispose();
  }

  /// The chosen direct host: the picked one, else the active one if it is a
  /// direct host, else the first.
  DirectHostConfig? _host(List<DirectHostConfig> hosts) {
    if (hosts.isEmpty) return null;
    final active = ref.read(activeHostProvider);
    final wanted = _hostId ?? (active.kind == HostKind.direct ? active.id : null);
    return hosts.where((h) => h.id == wanted).firstOrNull ?? hosts.first;
  }

  Future<void> _run(Future<void> Function() pair) async {
    setState(() => _error = null);
    try {
      await pair();
    } on PushPairException catch (e) {
      if (mounted) setState(() => _error = pushPairProblemText(appL10n, e));
    }
  }

  Future<void> _pairWithDsh(DirectHostConfig host) =>
      _run(() => ref.read(pushProvider.notifier).pairWithDsh(_bridge.text, host.id));

  Future<void> _pairWithLink(DirectHostConfig host) async {
    final l10n = context.l10n;
    final field = TextEditingController();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text?.contains('dshwatch://pair') ?? false) field.text = clip!.text!.trim();
    if (!mounted) return;
    final text = await showAppDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pushLinkTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.pushLinkHint),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('push-link-field'),
              controller: field,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'dshwatch://pair?…'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, field.text), child: Text(l10n.pushLinkPair)),
        ],
      ),
    );
    field.dispose();
    if (text == null || text.trim().isEmpty) return;
    await _run(() => ref.read(pushProvider.notifier).pairWithLink(text, host.id));
  }

  Future<void> _unpair() async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pushUnpairConfirmTitle),
        content: Text(l10n.pushUnpairConfirmText),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.pushUnpair)),
        ],
      ),
    );
    if (ok != true) return;
    final told = await ref.read(pushProvider.notifier).unpair();
    if (!told && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(appL10n.pushUnpairOffline)));
    }
  }

  Future<void> _openSystem() async {
    try {
      await launchUrl(Uri.parse('app-settings:'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(pushProvider);
    final hosts = ref.watch(hostsProvider.select((s) => s.direct));
    return AppPage.list(
      title: l10n.pushTitle,
      subtitle: Text(l10n.pushDescription),
      children: state.pairing == null ? _unpaired(l10n, state, hosts) : _paired(l10n, state, hosts),
    );
  }

  List<Widget> _unpaired(L10n l10n, PushState state, List<DirectHostConfig> hosts) {
    final host = _host(hosts);
    final theme = Theme.of(context);
    final mono = AppType.mono(size: 15, color: theme.colorScheme.onSurface, height: 1.4);
    if (host == null) {
      return [PhoneNote(icon: AppIcons.info, text: l10n.pushNoDirectHost, margin: const EdgeInsets.fromLTRB(16, 0, 16, 24))];
    }
    final busy = state.busy;
    return [
      SettingsSection(
        footer: Text(l10n.pushEnableFooter),
        children: [
          FormFieldGroup(
            children: [
              FormFieldBlock(
                label: l10n.pushBridgeLabel,
                error: _error,
                child: TextField(
                  key: const ValueKey('push-bridge-url'),
                  controller: _bridge,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.go,
                  style: mono,
                  onSubmitted: busy ? null : (_) => unawaited(_pairWithDsh(host)),
                  decoration: InputDecoration(
                    hintText: l10n.pushBridgeHint,
                    error: _error == null ? null : const SizedBox.shrink(),
                  ),
                ),
              ),
              if (hosts.length > 1)
                FormFieldBlock(
                  label: l10n.pushHostLabel,
                  child: DropdownButton<String>(
                    key: const ValueKey('push-host'),
                    isExpanded: true,
                    value: host.id,
                    items: [for (final h in hosts) DropdownMenuItem(value: h.id, child: Text(h.name))],
                    onChanged: busy ? null : (id) => setState(() => _hostId = id),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  key: const ValueKey('push-enable'),
                  onPressed: busy ? null : () => unawaited(_pairWithDsh(host)),
                  icon: busy
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(AppIcons.notificationsOn, size: 18),
                  label: Text(l10n.pushEnable),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextButton(
                  key: const ValueKey('push-use-link'),
                  onPressed: busy ? null : () => unawaited(_pairWithLink(host)),
                  child: Text(l10n.pushUseLink),
                ),
              ),
            ],
          ),
        ],
      ),
    ];
  }

  List<Widget> _paired(L10n l10n, PushState state, List<DirectHostConfig> hosts) {
    final pairing = state.pairing!;
    final hostName = hosts.where((h) => h.id == pairing.hostId).firstOrNull?.name ?? pairing.hostId;
    final bridge = Uri.tryParse(pairing.bridge)?.host ?? pairing.bridge;
    final health = state.health;
    final Widget? note = switch (health) {
      PushHealth.needsPermission => PhoneNote(
        tone: NoteTone.warn,
        icon: AppIcons.notificationsOff,
        text: l10n.pushPermissionText,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        action: TextButton(
          key: const ValueKey('push-open-system'),
          onPressed: () => unawaited(_openSystem()),
          child: Text(l10n.pushOpenSystem),
        ),
      ),
      PushHealth.revoked => PhoneNote(
        tone: NoteTone.danger,
        icon: AppIcons.notificationsOff,
        text: l10n.pushRevokedText,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      ),
      _ => null,
    };
    final canRetry = health == PushHealth.tokenFailed || health == PushHealth.unreachable;
    return [
      ?note,
      SettingsSection(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(child: Text(l10n.pushStatusLabel)),
                StatusChip(tone: pushHealthTone(health), label: pushHealthLabel(l10n, health)),
              ],
            ),
          ),
          InfoRow(label: l10n.pushBridgeRow, value: bridge, mono: true),
          InfoRow(label: l10n.pushHostRow, value: hostName),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            if (canRetry)
              OutlinedButton(
                key: const ValueKey('push-retry'),
                onPressed: state.busy ? null : () => unawaited(ref.read(pushProvider.notifier).retry()),
                child: Text(l10n.pushRetry),
              ),
            OutlinedButton(
              key: const ValueKey('push-unpair'),
              style: OutlinedButton.styleFrom(foregroundColor: DshColors.of(context).danger),
              onPressed: state.busy ? null : () => unawaited(_unpair()),
              child: Text(l10n.pushUnpair),
            ),
          ],
        ),
      ),
    ];
  }
}
