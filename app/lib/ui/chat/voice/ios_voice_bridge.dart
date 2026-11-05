// Dictation where the Kotlin `dsh/voice` channel does not exist (iOS): no
// phone recognizer, only the recorder, whose canonical 16 kHz mono PCM16 WAV
// goes to the Host's `speech/transcribe` (voice_controller.dart's engine path).
// The `record` plugin captures raw PCM; the WAV header is written here, so the
// Host gets exactly the 44-byte canonical form its validator expects.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import 'voice_bridge.dart';

/// What the Host's speech providers take (speech_api.dart).
const iosVoiceSampleRate = 16000;

/// The microphone as [IosVoiceBridge] uses it (a seam for tests).
abstract interface class PcmRecorder {
  /// Asks for the microphone when it was never asked; false when refused.
  Future<bool> hasPermission();

  /// Mono PCM16 little-endian at [sampleRate].
  Future<Stream<Uint8List>> startPcm({required int sampleRate});

  Future<void> stop();
}

class _PluginPcmRecorder implements PcmRecorder {
  AudioRecorder? _recorder;

  AudioRecorder get _active => _recorder ??= AudioRecorder();

  @override
  Future<bool> hasPermission() => _active.hasPermission();

  @override
  Future<Stream<Uint8List>> startPcm({required int sampleRate}) =>
      _active.startStream(RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: sampleRate, numChannels: 1));

  @override
  Future<void> stop() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder == null) return;
    try {
      await recorder.stop();
    } finally {
      await recorder.dispose();
    }
  }
}

/// [VoiceBridge] over [PcmRecorder]: `recorder` only, `recognizer` never.
class IosVoiceBridge implements VoiceBridge {
  IosVoiceBridge({PcmRecorder? recorder, Future<bool> Function(Uri uri)? launch})
    : _recorder = recorder ?? _PluginPcmRecorder(),
      _launch = launch ?? launchUrl;

  final PcmRecorder _recorder;
  final Future<bool> Function(Uri uri) _launch;
  final _events = StreamController<VoiceEvent>.broadcast();

  StreamSubscription<Uint8List>? _pcm;
  BytesBuilder? _audio;
  Timer? _limit;
  int _maxBytes = 0;
  bool _limited = false;

  @override
  Future<VoiceCapabilities> capabilities() async => const VoiceCapabilities(recognizer: false, recorder: true);

  /// iOS asks once; after a refusal only Settings can turn it on.
  @override
  Future<VoicePermission> requestPermission() async =>
      await _recorder.hasPermission() ? VoicePermission.granted : VoicePermission.blocked;

  @override
  Future<void> openSettings() async {
    try {
      await _launch(Uri.parse('app-settings:'));
    } catch (_) {
      // Nothing to open.
    }
  }

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> startRecognizer({String? language}) async =>
      throw UnsupportedError('no phone recognizer on this platform');

  @override
  Future<void> startRecorder({required int maxSeconds}) async {
    await _release();
    final audio = _audio = BytesBuilder(copy: false);
    _maxBytes = maxSeconds * iosVoiceSampleRate * 2;
    _limited = false;
    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.startPcm(sampleRate: iosVoiceSampleRate);
    } catch (e) {
      _audio = null;
      // voice_controller.dart reads `audio` as a recorder failure.
      throw PlatformException(code: 'audio', message: '$e');
    }
    if (!identical(_audio, audio)) return;
    _pcm = stream.listen(
      (chunk) {
        if (!identical(_audio, audio) || _limited) return;
        final room = _maxBytes - audio.length;
        audio.add(chunk.length <= room ? chunk : Uint8List.sublistView(chunk, 0, math.max(0, room)));
        _events.add(VoiceLevel(pcmLevel(chunk)));
        if (audio.length >= _maxBytes) _hitLimit();
      },
      onError: (Object _) {
        if (identical(_audio, audio)) _events.add(const VoiceError(VoiceError.recorderFailed));
      },
    );
    _limit = Timer(Duration(seconds: maxSeconds), _hitLimit);
  }

  void _hitLimit() {
    if (_limited || _audio == null) return;
    _limited = true;
    _events.add(const VoiceLimit());
  }

  @override
  Future<Uint8List?> stop() async {
    final audio = _audio;
    await _release();
    if (audio == null) return null;
    return pcm16Wav(audio.takeBytes(), sampleRate: iosVoiceSampleRate);
  }

  @override
  Future<void> cancel() => _release();

  Future<void> _release() async {
    _limit?.cancel();
    _limit = null;
    _audio = null;
    final pcm = _pcm;
    _pcm = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped.
    }
    await pcm?.cancel();
  }
}

/// The canonical WAV around mono PCM16 little-endian [pcm]: a 44-byte header,
/// `RIFF`/`WAVE`, one `fmt ` chunk (PCM, 1 channel, 16 bits) and `data`.
Uint8List pcm16Wav(Uint8List pcm, {required int sampleRate}) {
  final length = pcm.length & ~1;
  final out = Uint8List(44 + length);
  final header = ByteData.sublistView(out, 0, 44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      out[at + i] = s.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  header.setUint32(4, 36 + length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, length, Endian.little);
  out.setRange(44, 44 + length, pcm);
  return out;
}

/// A 0–1 meter for one PCM16 chunk: its RMS on a 60 dB scale.
double pcmLevel(Uint8List chunk) {
  final samples = chunk.length ~/ 2;
  if (samples == 0) return 0;
  final data = ByteData.sublistView(chunk);
  var sum = 0.0;
  for (var i = 0; i < samples; i++) {
    final s = data.getInt16(i * 2, Endian.little) / 32768;
    sum += s * s;
  }
  final rms = math.sqrt(sum / samples);
  if (rms <= 0) return 0;
  final db = 20 * math.log(rms) / math.ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}
