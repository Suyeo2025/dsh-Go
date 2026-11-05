// 设置 › 主题 › 字体: the stored choice, and the download against a local
// server standing in for GitHub and its mirrors — a file whose SHA-256 is off
// is refused, a download cut off midway is retried and resumed, and a
// cancelled one leaves no temporary file behind.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/font_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A small stand-in for a TrueType file: the 1.0 tag, then noise.
List<int> _fakeFont(int seed, int length) {
  final random = Random(seed);
  return [0, 1, 0, 0, for (var i = 4; i < length; i++) random.nextInt(256)];
}

class _Fixture {
  _Fixture(this.root, this.server, this.regular, this.medium);

  final Directory root;
  final HttpServer server;
  final List<int> regular;
  final List<int> medium;

  /// What the server answers: (source, file name, request) → handled.
  Future<void> Function(String source, String name, HttpRequest request)? handler;
  final requests = <String>[];
  final registered = <List<String>>[];

  String get base => 'http://127.0.0.1:${server.port}';

  FontRelease get release => FontRelease(
    id: 'test-font-1.0',
    family: 'Test Kai',
    version: '1.0',
    files: [
      FontFileSpec(name: 'Kai-Regular.ttf', bytes: regular.length, sha256: sha256.convert(regular).toString()),
      FontFileSpec(name: 'Kai-Medium.ttf', bytes: medium.length, sha256: sha256.convert(medium).toString()),
    ],
    sources: [FontSource('a', '$base/a/{file}'), FontSource('b', '$base/b/{file}')],
  );

  Directory get fontDir => Directory('${root.path}/fonts/test-font-1.0');
  Directory get staging => Directory('${fontDir.path}/.download');

  List<int> bytesOf(String name) => name == 'Kai-Regular.ttf' ? regular : medium;

  FontEnvironment get env => FontEnvironment(
    release: release,
    directory: () async => Directory('${root.path}/fonts'),
    register: (family, files) async => registered.add([family, for (final f in files) f.uri.pathSegments.last]),
    connectTimeout: const Duration(seconds: 5),
    idleTimeout: const Duration(seconds: 5),
  );

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [fontEnvironmentProvider.overrideWithValue(env)]);
    addTearDown(c.dispose);
    return c;
  }

  /// Serves [name] whole (or from a Range).
  static Future<void> serve(HttpRequest request, List<int> bytes) async {
    final range = RegExp(r'bytes=(\d+)-').firstMatch(request.headers.value('range') ?? '');
    final start = range == null ? 0 : int.parse(range.group(1)!);
    final res = request.response;
    if (range != null) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set('content-range', 'bytes $start-${bytes.length - 1}/${bytes.length}');
    }
    res.contentLength = bytes.length - start;
    res.add(bytes.sublist(start));
    await res.close();
  }

  /// Copies the good files into place, as a finished download leaves them.
  void install() {
    fontDir.createSync(recursive: true);
    for (final f in release.files) {
      File('${fontDir.path}/${f.name}').writeAsBytesSync(bytesOf(f.name));
    }
  }
}

Future<_Fixture> _fixture() async {
  final root = await Directory.systemTemp.createTemp('dsh-font-test');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final fixture = _Fixture(root, server, _fakeFont(1, 96 * 1024), _fakeFont(2, 80 * 1024));
  server.listen((request) async {
    final segments = request.uri.pathSegments;
    fixture.requests.add('${request.uri.path} ${request.headers.value('range') ?? '-'}');
    final handler = fixture.handler;
    if (handler == null) {
      await _Fixture.serve(request, fixture.bytesOf(segments.last));
    } else {
      await handler(segments.first, segments.last, request);
    }
  });
  addTearDown(() async {
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return fixture;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the stored choice', () {
    test('defaults to the system font', () async {
      final f = await _fixture();
      final c = f.container();
      await c.read(fontProvider.notifier).ready;
      final s = c.read(fontProvider);
      expect(s.chosen, AppFont.system);
      expect(s.phase, FontPhase.absent);
      expect(s.family, isNull);
      expect(c.read(appSansFamilyProvider), isNull);
    });

    test('WenKai chosen with its files in place: registered at launch, used by the theme', () async {
      final f = await _fixture();
      f.install();
      SharedPreferences.setMockInitialValues({FontController.prefKey: 'wenkai'});
      final c = f.container();
      await c.read(fontProvider.notifier).ready;
      expect(c.read(fontProvider).phase, FontPhase.ready);
      expect(c.read(appSansFamilyProvider), 'Test Kai');
      expect(f.registered, [
        ['Test Kai', 'Kai-Regular.ttf', 'Kai-Medium.ttf'],
      ]);
    });

    test('WenKai chosen but a file missing or cut short: the system font, and 需要重新下载', () async {
      final f = await _fixture();
      f.install();
      final medium = File('${f.fontDir.path}/Kai-Medium.ttf');
      medium.writeAsBytesSync(f.medium.sublist(0, 1000));
      SharedPreferences.setMockInitialValues({FontController.prefKey: 'wenkai'});
      final c = f.container();
      await c.read(fontProvider.notifier).ready;
      expect(c.read(fontProvider).chosen, AppFont.wenkai);
      expect(c.read(fontProvider).phase, FontPhase.broken);
      expect(c.read(appSansFamilyProvider), isNull);
      expect(f.registered, isEmpty);
    });

    test('a file that is the right size but not a font counts as damaged', () async {
      final f = await _fixture();
      f.install();
      File('${f.fontDir.path}/Kai-Regular.ttf').writeAsBytesSync(List.filled(f.regular.length, 0x41));
      SharedPreferences.setMockInitialValues({FontController.prefKey: 'wenkai'});
      final c = f.container();
      await c.read(fontProvider.notifier).ready;
      expect(c.read(fontProvider).phase, FontPhase.broken);
    });

    test('choosing is stored and read back by the next launch', () async {
      final f = await _fixture();
      f.install();
      final first = f.container();
      await first.read(fontProvider.notifier).choose(AppFont.wenkai);
      expect(first.read(appSansFamilyProvider), 'Test Kai');
      expect((await SharedPreferences.getInstance()).getString(FontController.prefKey), 'wenkai');

      final second = f.container();
      await second.read(fontProvider.notifier).ready;
      expect(second.read(fontProvider).chosen, AppFont.wenkai);
      expect(second.read(appSansFamilyProvider), 'Test Kai');

      await second.read(fontProvider.notifier).choose(AppFont.system);
      expect(second.read(appSansFamilyProvider), isNull);
      expect((await SharedPreferences.getInstance()).getString(FontController.prefKey), 'system');
      // The files stay: switching back needs no download.
      expect(second.read(fontProvider).phase, FontPhase.ready);
    });

    test('delete removes the files and goes back to the system font', () async {
      final f = await _fixture();
      f.install();
      final c = f.container();
      await c.read(fontProvider.notifier).choose(AppFont.wenkai);
      await c.read(fontProvider.notifier).delete();
      expect(c.read(fontProvider).phase, FontPhase.absent);
      expect(c.read(appSansFamilyProvider), isNull);
      expect(f.fontDir.existsSync(), isFalse);
      expect((await SharedPreferences.getInstance()).getString(FontController.prefKey), 'system');
    });
  });

  group('download', () {
    test('choosing WenKai downloads both files, checks them and switches', () async {
      final f = await _fixture();
      final c = f.container();
      await c.read(fontProvider.notifier).choose(AppFont.wenkai);
      final s = c.read(fontProvider);
      expect(s.phase, FontPhase.ready);
      expect(s.received, f.release.totalBytes);
      expect(c.read(appSansFamilyProvider), 'Test Kai');
      expect(File('${f.fontDir.path}/Kai-Regular.ttf').readAsBytesSync(), f.regular);
      expect(File('${f.fontDir.path}/Kai-Medium.ttf').readAsBytesSync(), f.medium);
      expect(f.staging.existsSync(), isFalse);
      expect((await SharedPreferences.getInstance()).getString(FontController.prefKey), 'wenkai');
    });

    test('a source that fails is skipped for the next, which the second file then starts from', () async {
      final f = await _fixture();
      f.handler = (source, name, request) async {
        if (source == 'a') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        } else {
          await _Fixture.serve(request, f.bytesOf(name));
        }
      };
      final c = f.container();
      await c.read(fontProvider.notifier).choose(AppFont.wenkai);
      expect(c.read(fontProvider).phase, FontPhase.ready);
      expect(f.requests, ['/a/Kai-Regular.ttf -', '/b/Kai-Regular.ttf -', '/b/Kai-Medium.ttf -']);
    });

    test('a SHA-256 mismatch from every source is refused, and the file deleted', () async {
      final f = await _fixture();
      // Right size, wrong bytes (a tampered or broken mirror).
      f.handler = (source, name, request) => _Fixture.serve(request, _fakeFont(9, f.bytesOf(name).length));
      final c = f.container();
      await c.read(fontProvider.notifier).choose(AppFont.wenkai);
      final s = c.read(fontProvider);
      expect(s.phase, FontPhase.failed);
      expect(s.failure, FontFailure.checksum);
      expect(s.chosen, AppFont.system);
      expect(c.read(appSansFamilyProvider), isNull);
      expect(File('${f.fontDir.path}/Kai-Regular.ttf').existsSync(), isFalse);
      final left = f.staging.existsSync() ? f.staging.listSync().map((e) => e.path).toList() : <String>[];
      expect(left, isEmpty);
      expect(f.registered, isEmpty);
    });

    test('cut off midway: fails, then a retry resumes from where it stopped', () async {
      final f = await _fixture();
      const cut = 40 * 1024;
      var healthy = false;
      var dropped = false;
      f.handler = (source, name, request) async {
        if (healthy) return _Fixture.serve(request, f.bytesOf(name));
        if (!dropped) {
          // The headers promise the whole file; the connection ends a part of the way in.
          dropped = true;
          final bytes = f.bytesOf(name);
          request.response.contentLength = bytes.length;
          final socket = await request.response.detachSocket();
          socket.add(bytes.sublist(0, cut));
          await socket.flush();
          await socket.close();
          return;
        }
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      };
      final c = f.container();
      final notifier = c.read(fontProvider.notifier);
      await notifier.choose(AppFont.wenkai);
      expect(c.read(fontProvider).phase, FontPhase.failed);
      expect(c.read(fontProvider).failure, FontFailure.unavailable);
      // What arrived is kept for the retry.
      expect(File('${f.staging.path}/Kai-Regular.ttf.part').lengthSync(), cut);

      healthy = true;
      f.requests.clear();
      await notifier.choose(AppFont.wenkai);
      expect(c.read(fontProvider).phase, FontPhase.ready);
      expect(c.read(appSansFamilyProvider), 'Test Kai');
      expect(f.requests.first, '/a/Kai-Regular.ttf bytes=$cut-');
      expect(File('${f.fontDir.path}/Kai-Regular.ttf').readAsBytesSync(), f.regular);
      expect(f.staging.existsSync(), isFalse);
    });

    test('cancel stops the download and deletes the temporary file', () async {
      final f = await _fixture();
      final started = Completer<void>();
      final hold = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      f.handler = (source, name, request) async {
        final bytes = f.bytesOf(name);
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 16 * 1024));
        await request.response.flush();
        if (!started.isCompleted) started.complete();
        // Never finishes on its own.
        await hold.future;
      };
      final c = f.container();
      final notifier = c.read(fontProvider.notifier);
      final run = notifier.choose(AppFont.wenkai);
      await started.future;
      // Let the first bytes reach the .part file.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.read(fontProvider).phase, FontPhase.downloading);
      expect(File('${f.staging.path}/Kai-Regular.ttf.part').existsSync(), isTrue);
      notifier.cancel();
      await run;
      final s = c.read(fontProvider);
      expect(s.phase, FontPhase.absent);
      expect(s.chosen, AppFont.system);
      expect(f.staging.existsSync(), isFalse);
      expect(File('${f.fontDir.path}/Kai-Regular.ttf').existsSync(), isFalse);
    });

    test('downloading again after 需要重新下载 puts the chosen font back in use', () async {
      final f = await _fixture();
      SharedPreferences.setMockInitialValues({FontController.prefKey: 'wenkai'});
      final c = f.container();
      final notifier = c.read(fontProvider.notifier);
      await notifier.ready;
      expect(c.read(fontProvider).phase, FontPhase.broken);
      await notifier.download();
      expect(c.read(fontProvider).phase, FontPhase.ready);
      expect(c.read(appSansFamilyProvider), 'Test Kai');
    });
  });

  test('the pinned WenKai release: two weights, sizes and SHA-256 written down, only public URLs', () {
    expect(wenKaiRelease.family, 'LXGW WenKai');
    expect(wenKaiRelease.files.map((f) => f.name), ['LXGWWenKai-Regular.ttf', 'LXGWWenKai-Medium.ttf']);
    for (final f in wenKaiRelease.files) {
      expect(f.bytes, greaterThan(20 * 1024 * 1024));
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    // Accelerators first (mainland China), then GitHub, then SourceForge.
    const github = 'https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKai-Regular.ttf';
    expect(wenKaiRelease.sources.map((s) => s.url('LXGWWenKai-Regular.ttf').toString()), [
      'https://ghfast.top/$github',
      'https://gh-proxy.com/$github',
      github,
      'https://downloads.sourceforge.net/project/lxgw-wenkai.mirror/v1.530/LXGWWenKai-Regular.ttf',
    ]);
    for (final s in wenKaiRelease.sources) {
      final url = s.url('LXGWWenKai-Regular.ttf');
      expect(url.scheme, 'https');
      expect(url.userInfo, isEmpty);
      expect(url.hasQuery, isFalse);
      expect(url.path, contains('v${wenKaiRelease.version}'));
    }
  });
}
