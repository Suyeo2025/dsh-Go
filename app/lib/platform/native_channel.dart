import 'package:flutter/services.dart';

import 'platform_caps.dart';

/// A `dsh/*` event channel: the real one where the Kotlin layer exists
/// ([hasAndroidNativeLayer]), else one whose stream is empty.
///
/// Method calls without a native side already fail fast with
/// [MissingPluginException], which the channel wrappers turn into
/// "unsupported". Listening to an unregistered event channel instead reports
/// the missing plugin through FlutterError on every subscription, so event
/// streams are gated here.
EventChannel nativeEventChannel(String name) => hasAndroidNativeLayer ? EventChannel(name) : AbsentEventChannel(name);

/// An event channel with nothing behind it: like a native side that never
/// sends, its stream neither emits nor closes.
class AbsentEventChannel extends EventChannel {
  const AbsentEventChannel(super.name);

  @override
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) => Stream<dynamic>.multi((_) {}, isBroadcast: true);
}
