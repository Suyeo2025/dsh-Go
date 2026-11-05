// Voice input: the platform bridge (a seam for tests).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_caps.dart';
import '../ui/chat/voice/ios_voice_bridge.dart';
import '../ui/chat/voice/voice_bridge.dart';

/// Android: the Kotlin `dsh/voice` channel. Elsewhere (iOS): the recorder for
/// the Host's speech/transcribe.
final voiceBridgeProvider = Provider<VoiceBridge>(
  (ref) => hasAndroidNativeLayer ? MethodChannelVoiceBridge() : IosVoiceBridge(),
);

/// Dictation into the composer is on (starting, listening or transcribing).
/// The chat page reports it; what waits for a quiet moment reads it.
class VoiceInputActiveController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool active) {
    if (ref.mounted && active != state) state = active;
  }
}

final voiceInputActiveProvider = NotifierProvider<VoiceInputActiveController, bool>(VoiceInputActiveController.new);
