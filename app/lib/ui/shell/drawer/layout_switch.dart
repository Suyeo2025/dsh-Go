// 按时间 / 工作区树 at the top of the drawer's list (it scrolls with the
// list). A status filter lists matches flat in either layout, so while one
// is on the switch is greyed and says why.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../common/segmented_pill.dart';

class DrawerLayoutSwitch extends ConsumerWidget {
  const DrawerLayoutSwitch({super.key});

  static const height = 32.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final layout = ref.watch(drawerViewProvider.select((v) => v.layout));
    final filtered = ref.watch(drawerFilterProvider) != DrawerFilter.all;
    final pill = SegmentedPill<DrawerLayout>(
      height: height,
      segments: [
        PillSegment(DrawerLayout.time, l10n.smUiLayoutTime),
        PillSegment(DrawerLayout.tree, l10n.smUiLayoutTree),
      ],
      selected: layout,
      onChanged: filtered ? null : (value) => ref.read(drawerViewProvider.notifier).setLayout(value),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      child: filtered ? Tooltip(message: l10n.smUiLayoutFilterHint, child: pill) : pill,
    );
  }
}
