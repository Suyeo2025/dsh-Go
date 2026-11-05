// 设置 › 主题 › 字体: the row (the font in use) and the sheet with the two
// choices, each drawn in its own font.
//
// ╭──────────────────────────────────────────╮
// │ 字体                                     │
// │ ┌──────────────────────────────────────┐ │
// │ │ ◉ 系统默认                            │ │
// │ │   落霞与孤鹜齐飞 The quick brown fox   │ │  in the system sans
// │ └──────────────────────────────────────┘ │
// │ ┌──────────────────────────────────────┐ │
// │ │ ○ 霞鹜文楷                            │ │
// │ │   落霞与孤鹜齐飞 The quick brown fox   │ │  in WenKai once it is on the phone
// │ │   约 49 MB，首次使用需下载              │ │  / progress + 取消 / reason + 重试 /
// │ └──────────────────────────────────────┘ │    已下载 · 删除
// │ 霞鹜文楷用于整个 App 的文字…              │
// ╰──────────────────────────────────────────╯

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/font_state.dart';
import '../../common/app_sheet.dart';
import '../../common/pressable.dart';
import '../../common/sheet_title_bar.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../settings_widgets.dart';

/// The 字体 row on 设置 › 主题: the font in use, or where its download stands.
class FontEntryTile extends ConsumerWidget {
  const FontEntryTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = ref.watch(fontProvider);
    final value = switch (s) {
      FontState(phase: FontPhase.downloading) => l10n.fontDownloading(_percent(s)),
      FontState(chosen: AppFont.wenkai, phase: FontPhase.broken || FontPhase.failed) =>
        '${l10n.fontWenKai} · ${l10n.fontNeedsDownload}',
      FontState(chosen: AppFont.wenkai) => l10n.fontWenKai,
      _ => l10n.fontSystem,
    };
    return SettingsTile(spot: Spots.font, value: Text(value), onTap: () => unawaited(showFontSheet(context)));
  }
}

Future<void> showFontSheet(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const FontSheet());

String _percent(FontState s) => (s.progress * 100).floor().toString();

class FontSheet extends ConsumerStatefulWidget {
  const FontSheet({super.key});

  @override
  ConsumerState<FontSheet> createState() => _FontSheetState();
}

class _FontSheetState extends ConsumerState<FontSheet> {
  @override
  void initState() {
    super.initState();
    // Downloaded but not in use: load it so its sample shows in it.
    unawaited(ref.read(fontProvider.notifier).preview());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final s = ref.watch(fontProvider);
    final notifier = ref.read(fontProvider.notifier);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.fontTitle),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 6, kSheetGutter, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FontOption(
                    key: const ValueKey('font-system'),
                    name: l10n.fontSystem,
                    selected: s.chosen == AppFont.system,
                    sample: systemSampleStyle(context),
                    onTap: () => unawaited(notifier.choose(AppFont.system)),
                  ),
                  const SizedBox(height: 10),
                  FontOption(
                    key: const ValueKey('font-wenkai'),
                    name: l10n.fontWenKai,
                    selected: s.chosen == AppFont.wenkai,
                    sample: s.phase == FontPhase.ready && s.registered
                        ? systemSampleStyle(context)
                              .copyWith(fontFamily: notifier.release.family, fontFamilyFallback: AppType.sansFallback)
                        : systemSampleStyle(context),
                    onTap: s.phase == FontPhase.downloading ? null : () => unawaited(notifier.choose(AppFont.wenkai)),
                    status: _WenKaiStatus(state: s),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 16),
                    child: Text(
                      l10n.fontFooter,
                      style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sample line in the system sans, whatever the app's font: a style that
/// doesn't inherit the ambient (possibly WenKai) family.
TextStyle systemSampleStyle(BuildContext context) {
  final theme = Theme.of(context);
  return AppType.textTheme.bodyLarge!.copyWith(
    inherit: false,
    fontSize: 17,
    color: theme.colorScheme.onSurface,
    locale: theme.textTheme.bodyLarge?.locale,
    textBaseline: TextBaseline.alphabetic,
  );
}

/// One choice: the radio mark, its name, a sample in [sample], and [status]
/// under it (WenKai's download).
class FontOption extends StatelessWidget {
  const FontOption({
    super.key,
    required this.name,
    required this.selected,
    required this.sample,
    required this.onTap,
    this.status,
  });

  final String name;
  final bool selected;
  final TextStyle sample;
  final VoidCallback? onTap;
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Pressable(
        onTap: onTap,
        child: GlassSurface(
          tier: GlassTier.card,
          borderRadius: AppShape.radiusLg,
          padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  selected ? AppIcons.radioOn : AppIcons.radioOff,
                  size: 22,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(l10n.fontSample, style: sample),
                    if (status case final status?) ...[const SizedBox(height: 8), status],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WenKaiStatus extends ConsumerWidget {
  const _WenKaiStatus({required this.state});

  final FontState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final notifier = ref.read(fontProvider.notifier);
    final small = theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary);
    final mb = (notifier.release.totalBytes / (1024 * 1024)).round().toString();
    Widget action(String label, VoidCallback onPressed, {Key? key}) => TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label),
    );
    Widget line(Widget text, Widget button) => Row(
      children: [
        Expanded(child: text),
        const SizedBox(width: 8),
        button,
      ],
    );
    return switch (state.phase) {
      FontPhase.absent => Text(l10n.fontDownloadSize(mb), style: small),
      FontPhase.downloading => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: state.progress),
          const SizedBox(height: 4),
          line(
            Text(l10n.fontDownloading(_percent(state)), style: small),
            action(l10n.commonCancel, notifier.cancel, key: const ValueKey('font-cancel')),
          ),
        ],
      ),
      FontPhase.failed => line(
        Text(_failure(l10n, state.failure), style: small?.copyWith(color: colors.danger)),
        action(l10n.commonRetry, () => unawaited(notifier.choose(AppFont.wenkai)), key: const ValueKey('font-retry')),
      ),
      FontPhase.broken => line(
        Text(
          state.failure == FontFailure.load ? l10n.fontFailLoad : l10n.fontNeedsDownload,
          style: small?.copyWith(color: colors.danger),
        ),
        action(
          l10n.fontDownload,
          () => unawaited(notifier.choose(AppFont.wenkai)),
          key: const ValueKey('font-redownload'),
        ),
      ),
      FontPhase.ready => line(
        Text(l10n.fontDownloaded, style: small),
        action(l10n.commonDelete, () => unawaited(notifier.delete()), key: const ValueKey('font-delete')),
      ),
    };
  }
}

String _failure(L10n l10n, FontFailure? failure) => switch (failure) {
  FontFailure.unavailable => l10n.fontFailUnavailable,
  FontFailure.checksum => l10n.fontFailChecksum,
  FontFailure.storage => l10n.fontFailStorage,
  FontFailure.load => l10n.fontFailLoad,
  FontFailure.network || null => l10n.fontFailNetwork,
};
