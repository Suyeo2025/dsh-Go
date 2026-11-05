// First run on a remote-only device (iOS): no engine here, so instead of
// 「DSH 在哪里运行？」 the one question is how to reach a DSH Host, with the
// Google sign-in (the server's access gate hands out the address and token)
// suggested, the direct URL by hand next.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../remote/direct_host_form.dart';
import '../remote/host_status.dart';
import '../theme/app_icons.dart';
import 'onboarding_scaffold.dart';
import 'runtime_choice.dart';

enum _Way { google, direct, other }

/// Three option cards and one 「继续」: Google sign-in or a direct host by hand
/// (the direct form opens, with only its Google block for the first; saving
/// makes it the active host and ends first run via [onConnected]), or the
/// other ways in (the host list, [onOther]).
class RemoteOnlySetupView extends ConsumerStatefulWidget {
  const RemoteOnlySetupView({super.key, required this.onOther, this.onConnected});

  final VoidCallback onOther;

  /// A direct host was added and picked. Null: back to [onOther]'s host list.
  final VoidCallback? onConnected;

  @override
  ConsumerState<RemoteOnlySetupView> createState() => _RemoteOnlySetupViewState();
}

class _RemoteOnlySetupViewState extends ConsumerState<RemoteOnlySetupView> {
  _Way _way = _Way.google;

  Future<void> _addDirect({bool google = false}) async {
    final saved = await Navigator.of(context)
        .push<DirectHostConfig>(MaterialPageRoute(builder: (_) => DirectHostFormPage(signInOnly: google)));
    if (saved == null || !mounted) return;
    ref.read(activeHostProvider.notifier).select(HostRef.direct(saved.id));
    (widget.onConnected ?? widget.onOther)();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return OnboardingScaffold(
      children: [
        const Spacer(),
        OnboardingHeader(
          icon: AppIcons.remoteHost,
          title: l10n.directOnboardingTitle,
          message: l10n.directOnboardingMessage,
        ),
        const SizedBox(height: 28),
        RuntimeOptionCard(
          key: const ValueKey('remote-only-google'),
          icon: AppIcons.account,
          title: l10n.directGoogleSignIn,
          detail: l10n.directOnboardingGoogleHint,
          recommended: true,
          selected: _way == _Way.google,
          onTap: () => setState(() => _way = _Way.google),
        ),
        const SizedBox(height: RuntimeOptionCard.gap),
        RuntimeOptionCard(
          key: const ValueKey('remote-only-direct'),
          icon: hostKindIcon(HostKind.direct),
          title: l10n.directSection,
          detail: l10n.directOnboardingAddHint,
          selected: _way == _Way.direct,
          onTap: () => setState(() => _way = _Way.direct),
        ),
        const SizedBox(height: RuntimeOptionCard.gap),
        RuntimeOptionCard(
          key: const ValueKey('remote-only-other'),
          icon: AppIcons.computer,
          title: l10n.remoteOtherMethods,
          detail: l10n.remoteConnectionMethods,
          selected: _way == _Way.other,
          onTap: () => setState(() => _way = _Way.other),
        ),
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('remote-only-continue'),
          onPressed: switch (_way) {
            _Way.google => () => _addDirect(google: true),
            _Way.direct => _addDirect,
            _Way.other => widget.onOther,
          },
          child: Text(l10n.commonContinue),
        ),
      ],
    );
  }
}
