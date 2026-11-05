// 设置 › 界面 › 生成中发送: what tapping send does while a turn runs. The
// host's `ui-conversation.busyEnter` by default, or always one way.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/busy_send_state.dart';
import '../../state/settings_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

String _label(L10n l10n, BusySendOverride o) => switch (o) {
  BusySendOverride.followHost => l10n.busySendFollowHost,
  BusySendOverride.steer => l10n.busySendAlwaysSteer,
  BusySendOverride.queue => l10n.busySendAlwaysQueue,
};

/// The row: the choice in use; a tap opens the three.
class BusySendTile extends ConsumerWidget {
  const BusySendTile({super.key, required this.spot});

  final SettingSpot spot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(busySendOverrideProvider);
    return SettingsTile(
      spot: spot,
      value: Text(_label(context.l10n, current)),
      onTap: () => unawaited(
        showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const BusySendSheet()),
      ),
    );
  }
}

/// 跟随主机 / 总是插话 / 总是排队, each with a line on what it does.
class BusySendSheet extends ConsumerWidget {
  const BusySendSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final current = ref.watch(busySendOverrideProvider);
    final host = switch (ref.watch(hostBusyEnterProvider)) {
      'queue' => l10n.busySendHostQueue,
      'steer' => l10n.busySendHostSteer,
      _ => l10n.busySendHostUnknown,
    };
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.busySendTitle),
            SheetGroup(
              margin: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
              children: [
                for (final o in BusySendOverride.values)
                  Semantics(
                    checked: o == current,
                    inMutuallyExclusiveGroup: true,
                    child: SettingsTile(
                      key: ValueKey('busy-send-${o.name}'),
                      tinted: false,
                      chevron: false,
                      title: _label(l10n, o),
                      subtitle: switch (o) {
                        BusySendOverride.followHost => l10n.busySendFollowHostHint(host),
                        BusySendOverride.steer => l10n.busySendAlwaysSteerHint,
                        BusySendOverride.queue => l10n.busySendAlwaysQueueHint,
                      },
                      trailing: SizedBox.square(
                        dimension: 32,
                        child: Icon(
                          o == current ? AppIcons.radioOn : AppIcons.radioOff,
                          size: 24,
                          color: o == current ? Theme.of(context).colorScheme.primary : null,
                        ),
                      ),
                      onTap: () {
                        unawaited(ref.read(settingsProvider.notifier).setBusySendOverride(o));
                        Navigator.pop(context);
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
