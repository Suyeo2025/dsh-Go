// The iOS stand-ins for Android's native channels: recorder dictation for the
// Host's speech/transcribe, Quick Look and the Files app for artifacts, Photos
// for pictures and videos, and islands on direct hosts. `flutter test` reports
// Android, so each iOS test flips platform_caps.dart's switch back afterwards.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/media/gallery.dart';
import 'package:dsh_app/media/ios_gallery.dart';
import 'package:dsh_app/platform/platform_caps.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/ios_files_channel.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/voice/ios_voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/plugins/islands/island_gate.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';

import '../chat/support/composer_fakes.dart';

void _asIos() {
  debugRemoteOnlyOverride = true;
  debugAndroidNativeOverride = false;
  addTearDown(() {
    debugRemoteOnlyOverride = null;
    debugAndroidNativeOverride = null;
  });
}

class _FakeRecorder implements PcmRecorder {
  bool permission = true;
  bool failStart = false;
  int stops = 0;
  StreamController<Uint8List>? pcm;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> startPcm({required int sampleRate}) async {
    if (failStart) throw StateError('no input');
    return (pcm = StreamController<Uint8List>()).stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    await pcm?.close();
    pcm = null;
  }
}

class _FakeGal extends GalApi {
  _FakeGal({this.access = true, this.grant = true, this.fail});

  bool access;
  bool grant;
  GalExceptionType? fail;
  final saved = <String>[];

  @override
  Future<bool> hasAccess() async => access;

  @override
  Future<bool> requestAccess() async => grant;

  void _maybeFail() {
    if (fail case final type?) {
      throw GalException(
        type: type,
        platformException: PlatformException(code: type.code),
        stackTrace: StackTrace.current,
      );
    }
  }

  @override
  Future<void> putImageBytes(Uint8List bytes, {required String name}) async {
    _maybeFail();
    saved.add('image:$name:${bytes.length}');
  }

  @override
  Future<void> putVideo(String path) async {
    _maybeFail();
    saved.add('video:$path');
  }
}

/// 16-bit samples at a constant [value] (little-endian).
Uint8List _samples(int count, int value) {
  final out = ByteData(count * 2);
  for (var i = 0; i < count; i++) {
    out.setInt16(i * 2, value, Endian.little);
  }
  return out.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('providers pick the platform', () {
    test('Android keeps the Kotlin channels', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(filesChannelProvider), isNot(isA<IosFilesChannel>()));
      expect(container.read(mediaChannelProvider), isNot(isA<IosMediaChannel>()));
      expect(container.read(mediaChannelProvider).savesVideos, isFalse);
      expect(container.read(voiceBridgeProvider), isA<MethodChannelVoiceBridge>());
    });

    test('iOS gets the stand-ins', () {
      _asIos();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(filesChannelProvider), isA<IosFilesChannel>());
      expect(container.read(mediaChannelProvider), isA<IosMediaChannel>());
      expect(container.read(mediaChannelProvider).savesVideos, isTrue);
      expect(container.read(voiceBridgeProvider), isA<IosVoiceBridge>());
    });
  });

  group('recorder dictation', () {
    test('pcm16Wav writes the canonical 44-byte header', () {
      final wav = pcm16Wav(_samples(3, 1000), sampleRate: 16000);
      final header = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(header.getUint32(4, Endian.little), 36 + 6);
      expect(String.fromCharCodes(wav.sublist(8, 16)), 'WAVEfmt ');
      expect(header.getUint32(16, Endian.little), 16);
      expect(header.getUint16(20, Endian.little), 1, reason: 'PCM');
      expect(header.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint32(28, Endian.little), 32000);
      expect(header.getUint16(32, Endian.little), 2);
      expect(header.getUint16(34, Endian.little), 16);
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      expect(header.getUint32(40, Endian.little), 6);
      expect(wav.length, 50);
      expect(pcm16Wav(Uint8List(5), sampleRate: 16000).length, 48, reason: 'an odd byte is dropped');
    });

    test('pcmLevel: silence 0, full scale 1', () {
      expect(pcmLevel(_samples(100, 0)), 0);
      expect(pcmLevel(_samples(100, 32767)), closeTo(1, 0.001));
      expect(pcmLevel(_samples(100, 33)), lessThan(0.05));
    });

    test('records PCM into a WAV, meters it, says when the limit is hit', () async {
      final recorder = _FakeRecorder();
      final bridge = IosVoiceBridge(recorder: recorder);
      expect(await bridge.capabilities(), isA<VoiceCapabilities>().having((c) => c.recorder, 'recorder', isTrue));
      expect((await bridge.capabilities()).recognizer, isFalse);
      final events = <VoiceEvent>[];
      final sub = bridge.events.listen(events.add);
      addTearDown(sub.cancel);
      await bridge.startRecorder(maxSeconds: 1);
      recorder.pcm!.add(_samples(8000, 5000)); // half a second
      recorder.pcm!.add(_samples(12000, 5000)); // past the second: cut at 16000 samples
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<VoiceLevel>(), hasLength(2));
      expect(events.whereType<VoiceLimit>(), hasLength(1));
      final wav = await bridge.stop();
      expect(wav, isNotNull);
      expect(wav!.length, 44 + 16000 * 2);
      expect(recorder.stops, greaterThanOrEqualTo(1));
      expect(await bridge.stop(), isNull, reason: 'nothing recording any more');
    });

    test('cancel drops the recording; a failed start is a recorder failure', () async {
      final recorder = _FakeRecorder();
      final bridge = IosVoiceBridge(recorder: recorder);
      await bridge.startRecorder(maxSeconds: 10);
      recorder.pcm!.add(_samples(100, 1));
      await bridge.cancel();
      expect(await bridge.stop(), isNull);
      recorder.failStart = true;
      await expectLater(
        bridge.startRecorder(maxSeconds: 10),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'audio')),
      );
    });

    test('a refused microphone is blocked (only Settings turns it on)', () async {
      final launched = <Uri>[];
      final bridge = IosVoiceBridge(
        recorder: _FakeRecorder()..permission = false,
        launch: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      expect(await bridge.requestPermission(), VoicePermission.blocked);
      await bridge.openSettings();
      expect(launched.single.toString(), 'app-settings:');
    });

    testWidgets('iOS: a host whose model is not ready shows the mic and says so', (tester) async {
      _asIos();
      final client = DshClient.withCarrier(
        FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog(phase: 'unprepared')}),
      );
      final bridge = FakeVoiceBridge(caps: const VoiceCapabilities(recognizer: false, recorder: true));
      final input = TextEditingController();
      final voice = VoiceInputController(input: input, bridge: bridge, client: () => client, observeLifecycle: false);
      addTearDown(voice.dispose);
      addTearDown(input.dispose);
      final messages = <VoiceMessage>[];
      voice.onMessage = messages.add;
      await voice.refresh();
      expect(voice.available, isTrue);
      expect(voice.engineReady, isFalse);
      await voice.start();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(bridge.calls.where((c) => c.startsWith('recorder:')), isEmpty);
      expect(messages.single.text, '主机上的语音模型未就绪');
      expect(messages.single.change, isTrue);
    });

    testWidgets('Android: the same host keeps the mic hidden, as before', (tester) async {
      final client = DshClient.withCarrier(
        FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog(phase: 'unprepared')}),
      );
      final bridge = FakeVoiceBridge(caps: const VoiceCapabilities(recognizer: false, recorder: true));
      final input = TextEditingController();
      final voice = VoiceInputController(input: input, bridge: bridge, client: () => client, observeLifecycle: false);
      addTearDown(voice.dispose);
      addTearDown(input.dispose);
      await voice.refresh();
      expect(voice.available, isFalse);
    });

    testWidgets('iOS: a ready host model records as on Android', (tester) async {
      _asIos();
      final client = DshClient.withCarrier(FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog()}));
      final bridge = FakeVoiceBridge(caps: const VoiceCapabilities(recognizer: false, recorder: true));
      final input = TextEditingController();
      final voice = VoiceInputController(input: input, bridge: bridge, client: () => client, observeLifecycle: false);
      addTearDown(voice.dispose);
      addTearDown(input.dispose);
      await voice.refresh();
      expect(voice.engineReady, isTrue);
      await voice.start();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(bridge.calls.where((c) => c.startsWith('recorder:')), hasLength(1));
      expect(voice.phase, VoicePhase.listening);
      await voice.cancel();
    });
  });

  group('files on iOS', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('ios-files-'));
    tearDown(() => temp.delete(recursive: true));

    test('save copies into Documents under a free name', () async {
      final docs = Directory('${temp.path}/Documents');
      final channel = IosFilesChannel(documents: () async => docs);
      final source = File('${temp.path}/cache-report')..writeAsStringSync('pdf bytes');
      final first = await channel.saveToDownloads(source.path, name: 'report.pdf', mime: 'application/pdf');
      final second = await channel.saveToDownloads(source.path, name: 'report.pdf', mime: 'application/pdf');
      expect(File('${docs.path}/report.pdf').readAsStringSync(), 'pdf bytes');
      expect(File('${docs.path}/report (2).pdf').readAsStringSync(), 'pdf bytes');
      expect(first, endsWith('report.pdf'));
      expect(second, endsWith('report (2).pdf'));
      expect(first, contains('DSH Go'));
    });

    test('save refuses a missing file and keeps names inside Documents', () async {
      final channel = IosFilesChannel(documents: () async => temp);
      await expectLater(
        channel.saveToDownloads('${temp.path}/gone', name: 'x.txt', mime: 'text/plain'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'missing')),
      );
      expect(documentFileName('../../etc/passwd', '/tmp/a'), '.._.._etc_passwd');
      expect(documentFileName('', '/cache/abc/notes.md'), 'notes.md');
      expect(documentFileName('..', '/x'), 'file');
    });

    test('open: Quick Look errors map to artifact codes; a shown file returns', () async {
      Future<void> open(Future<OpenResult> Function() result) =>
          IosFilesChannel(quickLook: (_, {type}) => result()).open('/f', name: 'f', mime: 'application/pdf');

      await open(() async => OpenResult());
      await expectLater(
        open(() async => OpenResult(type: ResultType.fileNotFound)),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'missing')),
      );
      await expectLater(
        open(() async => OpenResult(type: ResultType.noAppToOpen)),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'no_app')),
      );
      // Quick Look answers only when closed: past the wait the call returns.
      final never = Completer<OpenResult>();
      await open(() => never.future).timeout(IosFilesChannel.answerWait * 3);
    });
  });

  group('Photos on iOS', () {
    test('pictures and videos go to Photos with add-only access', () async {
      final gal = _FakeGal(access: false);
      final media = IosMediaChannel(gal: gal);
      expect(await media.saveImage(Uint8List(3), name: 'cat.png', mime: 'image/png'), 'cat.png');
      expect(await media.saveVideo('/cache/clip.mp4'), 'clip.mp4');
      expect(gal.saved, ['image:cat:3', 'video:/cache/clip.mp4']);
    });

    test('refused access and Photos errors read as saveToGallery codes', () async {
      Matcher code(String c) => throwsA(isA<PlatformException>().having((e) => e.code, 'code', c));
      final refused = IosMediaChannel(gal: _FakeGal(access: false, grant: false));
      await expectLater(refused.saveImage(Uint8List(1), name: 'a.png', mime: 'image/png'), code('permission'));
      final denied = IosMediaChannel(gal: _FakeGal(fail: GalExceptionType.accessDenied));
      await expectLater(denied.saveVideo('/v.mp4'), code('permission'));
      final format = IosMediaChannel(gal: _FakeGal(fail: GalExceptionType.notSupportedFormat));
      await expectLater(format.saveImage(Uint8List(1), name: 'a.png', mime: 'image/png'), code('invalid'));
      final space = IosMediaChannel(gal: _FakeGal(fail: GalExceptionType.notEnoughSpace));
      await expectLater(space.saveVideo('/v.mp4'), code('failed'));
    });
  });

  group('islands on direct hosts', () {
    test('allowed like SSH; the page is the base URL without query', () {
      expect(islandHostAllowed(HostKind.direct), isTrue);
      expect(directIslandUri(Uri.parse('https://dsh.example.com')).toString(), 'https://dsh.example.com/');
      expect(directIslandUri(Uri.parse('http://10.0.0.2:3080/dsh')).toString(), 'http://10.0.0.2:3080/dsh');
    });
  });
}
