import 'package:flutter/foundation.dart';

/// Platform capability switches for the iOS port.
///
/// iOS cannot run the bundled Linux engine (no PRoot, no exec of downloaded
/// binaries), so the iOS build is a remote-only client: it talks to a DSH Host
/// over SSH, the relay, or a direct `dsh web` URL, and every Android-only
/// native layer (runtime, phone control, pet overlay, APK update, launcher
/// icons, …) is hidden or no-ops.
///
/// Both follow [defaultTargetPlatform], which `flutter test` reports as
/// Android: existing channel tests keep exercising the Android path. A test
/// switches to the iOS behaviour with `debugDefaultTargetPlatformOverride =
/// TargetPlatform.iOS`, or more narrowly with [debugRemoteOnlyOverride] /
/// [debugAndroidNativeOverride].

/// True when the on-device engine is unavailable and the app must only
/// connect to remote Hosts.
bool get isRemoteOnlyPlatform => debugRemoteOnlyOverride ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

/// True when the Kotlin native layer (all `dsh/*` platform channels) exists.
bool get hasAndroidNativeLayer =>
    debugAndroidNativeOverride ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

@visibleForTesting
bool? debugRemoteOnlyOverride;

@visibleForTesting
bool? debugAndroidNativeOverride;
