// 设置 › 主题 › 字体: the system sans, or 霞鹜文楷 (LXGW WenKai, OFL-1.1).
//
// WenKai is not in the app bundle (two weights are ~49 MB): it is downloaded
// the first time it is chosen, into Application Support/fonts/, checked
// against the SHA-256 pinned below, and from then on works offline. At launch,
// with WenKai chosen and its files in place, the files are read
// asynchronously and registered with the engine (FontLoader) under
// [FontRelease.family]; only then does the theme switch to it (one repaint).
// Missing or damaged files fall back to the system font and the setting says
// it needs downloading again.
//
// Code and terminal text keep JetBrains Mono either way (AppType.mono).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../update/downloader.dart';
import '../update/update_config.dart' show DownloadUrl;
import '../update/update_http.dart';

/// The text font the whole app uses (not code: that stays monospace).
enum AppFont { system, wenkai }

/// One font file of a release: its name, exact size and SHA-256 (lowercase hex).
class FontFileSpec {
  const FontFileSpec({required this.name, required this.bytes, required this.sha256});

  final String name;
  final int bytes;
  final String sha256;
}

/// Where a release's files can be fetched: [template] with `{file}` replaced
/// by the file name. All public, no credentials.
class FontSource {
  const FontSource(this.label, this.template);

  /// Shown in diagnostics ("GitHub", "ghfast.top").
  final String label;
  final String template;

  Uri url(String file) => Uri.parse(template.replaceAll('{file}', Uri.encodeComponent(file)));
}

/// A downloadable font family, pinned to one release.
class FontRelease {
  const FontRelease({
    required this.id,
    required this.family,
    required this.version,
    required this.files,
    required this.sources,
  });

  /// Directory name under fonts/, versioned: a new release never reads an old one's files.
  final String id;

  /// The family name it is registered under (ThemeData.fontFamily).
  final String family;
  final String version;
  final List<FontFileSpec> files;

  /// Tried in order for each file; everything is checked against the SHA-256.
  final List<FontSource> sources;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes);
}

const _wenKaiTag = 'v1.530';
const _wenKaiGithub = 'https://github.com/lxgw/LxgwWenKai/releases/download/$_wenKaiTag/{file}';

/// 霞鹜文楷 v1.530 (https://github.com/lxgw/LxgwWenKai/releases/tag/v1.530).
///
/// Regular (OS/2 weight 400) and Medium (500). The type ladder only asks for
/// 400 and 600 (AppType.textTheme): the engine matches 600 to the nearest
/// face, Medium, and does not synthesise bold for a 100 gap. w300 display
/// text lands on Regular.
///
/// Sizes and SHA-256 are the release assets' (GitHub's asset digests, and
/// re-hashed from every source listed). The accelerators answer the same
/// bytes; one that serves anything else fails the check and the next is tried.
const wenKaiRelease = FontRelease(
  id: 'lxgw-wenkai-1.530',
  family: 'LXGW WenKai',
  version: '1.530',
  files: [
    FontFileSpec(
      name: 'LXGWWenKai-Regular.ttf',
      bytes: 25928940,
      sha256: '2d73eea94ad808999d90c0000c239a84a33b09d4bc6ab6c5b8bbf1eda8a7fc8b',
    ),
    FontFileSpec(
      name: 'LXGWWenKai-Medium.ttf',
      bytes: 25800076,
      sha256: 'f4b8a34d1f838fe411540cb7c97b1c384ac9738a876c4104500bc42508b2312a',
    ),
  ],
  // Most people are in mainland China, where github.com is often slow or
  // unreachable: the public accelerators (the updater uses the same two,
  // update_config.dart) go first, GitHub itself after them.
  sources: [
    FontSource('ghfast.top', 'https://ghfast.top/$_wenKaiGithub'),
    FontSource('gh-proxy.com', 'https://gh-proxy.com/$_wenKaiGithub'),
    FontSource('GitHub', _wenKaiGithub),
    // SourceForge's automatic mirror of the GitHub releases.
    FontSource('SourceForge', 'https://downloads.sourceforge.net/project/lxgw-wenkai.mirror/$_wenKaiTag/{file}'),
  ],
);

/// Where the download stands.
enum FontPhase {
  /// Not on this phone.
  absent,
  downloading,

  /// All files in place (and checked when they were downloaded).
  ready,

  /// The last download failed ([FontState.failure]); a retry resumes it.
  failed,

  /// Chosen, but the files are missing or damaged: download again.
  broken,
}

/// Why a download or load failed.
enum FontFailure {
  /// No source could be reached, or every one kept dropping.
  network,

  /// Sources answered, but not with the file (404, 5xx).
  unavailable,

  /// The file arrived but its SHA-256 didn't match, from every source.
  checksum,

  /// Couldn't write the file (disk full).
  storage,

  /// The files are there but the engine couldn't load them.
  load,
}

class FontState {
  const FontState({
    this.chosen = AppFont.system,
    this.phase = FontPhase.absent,
    this.received = 0,
    this.failure,
    this.registered = false,
    this.loaded = false,
    this.release = wenKaiRelease,
  });

  /// The stored choice. WenKai can be chosen and still not shown ([family]
  /// null) while its files are missing.
  final AppFont chosen;
  final FontPhase phase;

  /// Bytes of WenKai on disk so far while [phase] is downloading.
  final int received;
  final FontFailure? failure;

  /// WenKai is registered with the engine in this run.
  final bool registered;

  /// The stored choice has been read.
  final bool loaded;

  /// The downloadable font ([wenKaiRelease]; tests use their own).
  final FontRelease release;

  /// The family the theme uses: null is the system sans.
  String? get family => chosen == AppFont.wenkai && phase == FontPhase.ready && registered ? release.family : null;

  /// 0–1 while downloading.
  double get progress => release.totalBytes == 0 ? 0 : (received / release.totalBytes).clamp(0.0, 1.0);

  FontState copyWith({
    AppFont? chosen,
    FontPhase? phase,
    int? received,
    FontFailure? failure,
    bool clearFailure = false,
    bool? registered,
    bool? loaded,
  }) => FontState(
    chosen: chosen ?? this.chosen,
    phase: phase ?? this.phase,
    received: received ?? this.received,
    failure: clearFailure ? null : failure ?? this.failure,
    registered: registered ?? this.registered,
    loaded: loaded ?? this.loaded,
    release: release,
  );
}

/// Registers [files] with the engine as [family].
typedef FontRegistrar = Future<void> Function(String family, List<File> files);

/// What [FontController] needs from the outside; tests replace it.
class FontEnvironment {
  const FontEnvironment({
    this.release = wenKaiRelease,
    this.directory = _fontsDirectory,
    this.http = IoUpdateHttp.new,
    this.register = registerFontFiles,
    this.hasher = sha256OfFile,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 20),
  });

  final FontRelease release;

  /// The fonts/ directory (created on demand).
  final Future<Directory> Function() directory;
  final UpdateHttp Function() http;
  final FontRegistrar register;
  final Sha256Hasher hasher;
  final Duration connectTimeout;

  /// No byte for this long: the source is given up for the next.
  final Duration idleTimeout;
}

Future<Directory> _fontsDirectory() async => Directory('${(await getApplicationSupportDirectory()).path}/fonts');

/// The engine keeps a registered family for the life of the process; one
/// registration per family is enough (a re-download is byte-identical).
final _registered = <String>{};

/// Reads [files] off the UI thread (async file IO) and hands them to the
/// engine under [family].
Future<void> registerFontFiles(String family, List<File> files) async {
  if (_registered.contains(family)) return;
  final loader = FontLoader(family);
  for (final file in files) {
    loader.addFont(file.readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
  _registered.add(family);
}

final fontEnvironmentProvider = Provider<FontEnvironment>((ref) => const FontEnvironment());

class FontController extends Notifier<FontState> {
  static const prefKey = 'appearance.font';

  late Future<void> _loaded;
  late FontEnvironment _env;
  CancelToken? _cancel;
  Future<void>? _download;

  /// Switch to WenKai when the running download finishes (the person picked it
  /// and hasn't picked the system font since).
  bool _switchWhenDone = false;

  FontRelease get release => _env.release;

  /// Completes once the stored choice is read (and WenKai, if chosen and in
  /// place, registered).
  Future<void> get ready => _loaded;

  @override
  FontState build() {
    _env = ref.watch(fontEnvironmentProvider);
    ref.onDispose(() => _cancel?.cancel());
    _loaded = _load();
    return FontState(release: _env.release);
  }

  Future<Directory> _dir() async => Directory('${(await _env.directory()).path}/${release.id}');

  Future<void> _load() async {
    var chosen = AppFont.system;
    try {
      final prefs = await SharedPreferences.getInstance();
      chosen = AppFont.values.asNameMap()[prefs.getString(prefKey)] ?? AppFont.system;
    } catch (_) {
      // No preferences backend (tests): the system font.
    }
    var installed = false;
    try {
      installed = await _installed();
      unawaited(_dropOtherReleases());
    } catch (_) {
      // No support directory: as if not downloaded.
    }
    final phase = installed ? FontPhase.ready : (chosen == AppFont.wenkai ? FontPhase.broken : FontPhase.absent);
    state = state.copyWith(chosen: chosen, phase: phase, loaded: true);
    if (installed && chosen == AppFont.wenkai) await _register();
  }

  /// Every file there, at its size, starting like a TrueType font. The full
  /// SHA-256 is checked once, when it is downloaded: hashing ~49 MB on every
  /// launch would cost more than the switch it guards.
  Future<bool> _installed() async {
    final dir = await _dir();
    for (final spec in release.files) {
      if (!await fontFileLooksIntact(File('${dir.path}/${spec.name}'), spec)) return false;
    }
    return true;
  }

  /// Earlier releases' directories (a version bump downloads afresh).
  Future<void> _dropOtherReleases() async {
    try {
      final root = await _env.directory();
      if (!await root.exists()) return;
      final prefix = release.id.replaceFirst(RegExp(r'-[^-]*$'), '-');
      await for (final entity in root.list()) {
        final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (name.startsWith(prefix) && name != release.id) await entity.delete(recursive: true);
      }
    } catch (_) {
      // Next launch.
    }
  }

  Future<bool> _register() async {
    if (state.registered) return true;
    try {
      final dir = await _dir();
      await _env.register(release.family, [for (final f in release.files) File('${dir.path}/${f.name}')]);
      state = state.copyWith(registered: true);
      return true;
    } catch (_) {
      state = state.copyWith(phase: FontPhase.broken, failure: FontFailure.load);
      return false;
    }
  }

  Future<void> _persist(AppFont font) async {
    try {
      await (await SharedPreferences.getInstance()).setString(prefKey, font.name);
    } catch (_) {
      // Kept for this run only.
    }
  }

  /// Picks [font]. WenKai not yet on the phone is downloaded first and
  /// switched to once it is in place; the system font applies at once.
  Future<void> choose(AppFont font) async {
    await _loaded;
    if (font == AppFont.system) {
      _switchWhenDone = false;
      state = state.copyWith(chosen: AppFont.system);
      await _persist(AppFont.system);
      return;
    }
    _switchWhenDone = true;
    if (state.phase == FontPhase.ready) {
      if (await _register()) {
        state = state.copyWith(chosen: AppFont.wenkai);
        await _persist(AppFont.wenkai);
      }
      return;
    }
    await download();
  }

  /// Registers WenKai when it is downloaded but not in use, so the picker can
  /// draw its sample in it.
  Future<void> preview() async {
    await _loaded;
    if (state.phase == FontPhase.ready) await _register();
  }

  /// Downloads WenKai (resuming what an earlier try left). One at a time.
  Future<void> download() => _download ??= _run().whenComplete(() => _download = null);

  /// Stops a running download and deletes what it had fetched.
  void cancel() => _cancel?.cancel();

  /// Deletes the downloaded files (switching to the system font first if
  /// WenKai was in use).
  Future<void> delete() async {
    await _loaded;
    _switchWhenDone = false;
    _cancel?.cancel();
    await _download;
    if (state.chosen == AppFont.wenkai) await _persist(AppFont.system);
    state = state.copyWith(chosen: AppFont.system, phase: FontPhase.absent, received: 0, clearFailure: true);
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Whatever is left is overwritten by the next download.
    }
  }

  Future<void> _run() async {
    await _loaded;
    final cancel = _cancel = CancelToken();
    state = state.copyWith(phase: FontPhase.downloading, received: 0, clearFailure: true);
    final Directory dir;
    final Directory staging;
    try {
      dir = await _dir();
      staging = Directory('${dir.path}/.download');
      await staging.create(recursive: true);
    } catch (_) {
      _fail(FontFailure.storage);
      return;
    }
    final downloader = ApkDownloader(
      http: _env.http(),
      directory: staging,
      hasher: _env.hasher,
      connectTimeout: _env.connectTimeout,
      idleTimeout: _env.idleTimeout,
    );
    var sources = [...release.sources];
    var done = 0;
    for (final spec in release.files) {
      final target = File('${dir.path}/${spec.name}');
      // In place from an earlier, interrupted run (moved there only once checked).
      if (await fontFileLooksIntact(target, spec)) {
        done += spec.bytes;
        state = state.copyWith(received: done);
        continue;
      }
      final base = done;
      final outcome = await downloader.download(
        fileName: spec.name,
        sha256: spec.sha256,
        expectedSize: spec.bytes,
        urls: [for (final s in sources) DownloadUrl(s.url(spec.name), mirrorId: s.label, label: s.label)],
        onProgress: (p) {
          if (!cancel.isCancelled) state = state.copyWith(received: base + p.received);
        },
        cancel: cancel,
      );
      switch (outcome) {
        case DownloadDone(file: final file, :final from):
          try {
            // Checked: only now does it get its real name.
            await file.rename(target.path);
          } on FileSystemException {
            _fail(FontFailure.storage);
            return;
          }
          // The next file starts where this one came from.
          if (from != null) {
            sources = [...sources.where((s) => s.label == from.label), ...sources.where((s) => s.label != from.label)];
          }
          done += spec.bytes;
          state = state.copyWith(received: done);
        case DownloadCancelled():
          await _deleteQuietly(staging);
          state = state.copyWith(
            phase: state.chosen == AppFont.wenkai ? FontPhase.broken : FontPhase.absent,
            received: 0,
            clearFailure: true,
          );
          return;
        case DownloadFailed(:final failure):
          // The partial file stays for the retry to resume.
          _fail(switch (failure) {
            DownloadFailure.network => FontFailure.network,
            DownloadFailure.unavailable => FontFailure.unavailable,
            DownloadFailure.checksum => FontFailure.checksum,
            DownloadFailure.storage => FontFailure.storage,
          });
          return;
      }
    }
    await _deleteQuietly(staging);
    state = state.copyWith(phase: FontPhase.ready, received: release.totalBytes, clearFailure: true);
    // Picked during this download, or chosen before and downloaded again ("需要重新下载").
    if ((_switchWhenDone || state.chosen == AppFont.wenkai) && await _register()) {
      state = state.copyWith(chosen: AppFont.wenkai);
      await _persist(AppFont.wenkai);
    }
  }

  void _fail(FontFailure failure) => state = state.copyWith(phase: FontPhase.failed, failure: failure);

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Overwritten next time.
    }
  }
}

/// [file] is [spec]'s size and starts with a TrueType / OpenType tag.
Future<bool> fontFileLooksIntact(File file, FontFileSpec spec) async {
  try {
    if (!await file.exists() || await file.length() != spec.bytes) return false;
    final raf = await file.open();
    try {
      final head = await raf.read(4);
      if (head.length < 4) return false;
      final tag = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
      return tag == 0x00010000 || tag == 0x4F54544F || tag == 0x74727565; // 1.0, 'OTTO', 'true'
    } finally {
      await raf.close();
    }
  } on FileSystemException {
    return false;
  }
}

final fontProvider = NotifierProvider<FontController, FontState>(FontController.new);

/// The sans family the theme uses: null is the system font.
final appSansFamilyProvider = Provider<String?>((ref) => ref.watch(fontProvider.select((s) => s.family)));
