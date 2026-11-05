// Where the iPad share sheet points (its popover's `sharePositionOrigin`).
//
// iPad shows the share sheet as a popover anchored to a rect in window
// coordinates; iPhone and Android ignore it. share_plus 13.3+ falls back to a
// 2×2 rect at the middle of the Flutter view when none is given (no exception
// any more), which is also what happens here without a usable [BuildContext]:
// a gone context, one not laid out, or one that is (nearly) the whole screen,
// where pointing at it says nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// [context]'s box in global coordinates, for the share popover on iPad; null
/// off iOS (the parameters stay exactly as before), or when the box can't
/// anchor anything (see the file comment): the sheet then centres.
Rect? shareOriginOf(BuildContext? context) {
  if (defaultTargetPlatform != TargetPlatform.iOS || context == null || !context.mounted) return null;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  if (rect.isEmpty) return null;
  final screen = MediaQuery.maybeSizeOf(context);
  if (screen != null && rect.width >= screen.width * 0.9 && rect.height >= screen.height * 0.6) return null;
  return rect;
}

/// [params] with [origin] as its `sharePositionOrigin` (one already set wins);
/// [params] itself when there is no origin.
ShareParams withShareOrigin(ShareParams params, Rect? origin) {
  if (origin == null || params.sharePositionOrigin != null) return params;
  return ShareParams(
    text: params.text,
    subject: params.subject,
    title: params.title,
    previewThumbnail: params.previewThumbnail,
    sharePositionOrigin: origin,
    uri: params.uri,
    files: params.files,
    fileNameOverrides: params.fileNameOverrides,
    downloadFallbackEnabled: params.downloadFallbackEnabled,
    mailToFallbackEnabled: params.mailToFallbackEnabled,
    excludedCupertinoActivities: params.excludedCupertinoActivities,
  );
}

/// The system share sheet with [params], popping over from [context] on iPad.
Future<ShareResult> shareFrom(BuildContext? context, ShareParams params) =>
    SharePlus.instance.share(withShareOrigin(params, shareOriginOf(context)));
