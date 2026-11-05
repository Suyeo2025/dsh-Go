// A generated video played in the app (iOS, where there is no Android
// "open with" to hand it to): downloaded once into the artifact cache like any
// Host file, then AVPlayer through video_player. Tap toggles play/pause; the
// bar under it scrubs. Share and 「保存到相册」 sit top right, as in the
// picture viewer.

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../l10n/l10n.dart';
import '../../../platform/platform_caps.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../shell/page_frame.dart' show GlassIconButton;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'media_card.dart';

/// Builds the player for a downloaded file (a seam for tests).
typedef VideoControllerFactory = VideoPlayerController Function(File file);

final videoControllerFactoryProvider = Provider<VideoControllerFactory>((ref) => VideoPlayerController.file);

/// 「播放」 a generated video: in the app where Android's "open with" does not
/// exist ([hasAndroidNativeLayer] false), else [openMediaElsewhere] as before.
Future<void> playMediaVideo(BuildContext context, WidgetRef ref, String sessionId, MediaItem item) {
  if (hasAndroidNativeLayer) return openMediaElsewhere(context, ref, sessionId, item);
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: AppMotion.of(context, AppMotion.standard),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
      pageBuilder: (context, animation, _) => FadeTransition(
        opacity: animation,
        child: MediaVideoPage(sessionId: sessionId, item: item),
      ),
    ),
  );
}

class MediaVideoPage extends ConsumerStatefulWidget {
  const MediaVideoPage({super.key, required this.sessionId, required this.item});

  final String sessionId;
  final MediaItem item;

  @override
  ConsumerState<MediaVideoPage> createState() => _MediaVideoPageState();
}

class _MediaVideoPageState extends ConsumerState<MediaVideoPage> {
  VideoPlayerController? _controller;
  Object? _error;
  double? _progress;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final file = await ref
          .read(artifactFilesProvider)
          .materialize(
            widget.sessionId,
            Artifact(path: widget.item.path, origin: ArtifactOrigin.linked, turn: 0),
            onProgress: (p) {
              if (mounted) setState(() => _progress = p);
            },
          );
      if (!mounted) return;
      final controller = ref.read(videoControllerFactoryProvider)(file);
      await controller.initialize();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      await controller.setLooping(false);
      setState(() => _controller = controller);
      unawaited(controller.play());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _toggle() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (value.isPlaying) {
      unawaited(controller.pause());
    } else {
      final ended = value.duration > Duration.zero && value.position >= value.duration;
      if (ended) unawaited(controller.seekTo(Duration.zero));
      unawaited(controller.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controller = _controller;
    final Widget body;
    if (_error case final error?) {
      body = Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          artifactErrorText(error),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    } else if (controller == null) {
      body = SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(value: _progress, strokeWidth: 3, color: Colors.white70),
      );
    } else {
      body = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(controller),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => AnimatedOpacity(
                    opacity: value.isPlaying ? 0 : 1,
                    duration: AppMotion.of(context, AppMotion.quick),
                    child: const Icon(AppIcons.playVideo, size: 64, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: Center(child: body)),
            Positioned(
              left: 12,
              top: 12,
              child: GlassIconButton(
                icon: AppIcons.back,
                tooltip: l10n.commonBack,
                grouped: false,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            Positioned(
              right: 12,
              top: 12,
              child: Row(
                children: [
                  GlassIconButton(
                    icon: AppIcons.save,
                    tooltip: l10n.commonSave,
                    grouped: false,
                    onPressed: () => unawaited(saveMediaItems(context, ref, widget.sessionId, [widget.item])),
                  ),
                  const SizedBox(width: 12),
                  Builder(
                    builder: (button) => GlassIconButton(
                      icon: AppIcons.share,
                      tooltip: l10n.commonShare,
                      grouped: false,
                      onPressed: () => unawaited(shareMediaItems(button, ref, widget.sessionId, [widget.item])),
                    ),
                  ),
                ],
              ),
            ),
            if (controller != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
