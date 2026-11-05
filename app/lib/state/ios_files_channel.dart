// [FilesChannel] where the Kotlin `dsh/files` side does not exist (iOS).
//
// * open / 打开方式: Quick Look over the file (open_filex's
//   UIDocumentInteractionController), whose share button offers the other apps;
// * 保存: a copy in the app's Documents folder, which the Files app shows as
//   「我的 iPhone › DSH Go」 (Info.plist UIFileSharingEnabled +
//   LSSupportsOpeningDocumentsInPlace);
// * PDF pages: none here; the preview hands the PDF to Quick Look instead
//   (artifact_preview.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import 'artifacts.dart';

/// Presents [path] in Quick Look (or the open-in menu); see [OpenFilex.open].
typedef QuickLook = Future<OpenResult> Function(String path, {String? type});

Future<OpenResult> _openFilex(String path, {String? type}) => OpenFilex.open(path, type: type);

class IosFilesChannel extends FilesChannel {
  IosFilesChannel({QuickLook? quickLook, Future<Directory> Function()? documents})
    : _quickLook = quickLook ?? _openFilex,
      _documents = documents ?? getApplicationDocumentsDirectory;

  final QuickLook _quickLook;
  final Future<Directory> Function() _documents;

  /// How long an early answer (a missing file, nothing to show it with) is
  /// waited for. Quick Look answers only once it is closed, and the open-in
  /// menu not at all when no app takes the file: past this the file is on
  /// screen and the call returns.
  static const answerWait = Duration(milliseconds: 1500);

  @override
  Future<String?> resolveGuest(String path) async => null;

  @override
  Future<List<PhoneOutput>> listOutputs({int depth = 3}) async => const [];

  @override
  Future<void> open(String hostPath, {required String name, required String mime, bool chooser = false}) async {
    final shown = _quickLook(hostPath, type: mime.isEmpty ? null : mime);
    final OpenResult? result;
    try {
      result = await shown.timeout(answerWait);
    } on TimeoutException {
      return;
    }
    switch (result.type) {
      case ResultType.done:
        return;
      case ResultType.fileNotFound:
        throw PlatformException(code: 'missing', message: result.message);
      case ResultType.noAppToOpen:
        throw PlatformException(code: 'no_app', message: result.message);
      case ResultType.permissionDenied:
        throw PlatformException(code: 'permission', message: result.message);
      case ResultType.error:
        throw PlatformException(code: 'failed', message: result.message);
    }
  }

  /// Copies the file into Documents under a free name (`report (2).pdf`);
  /// returns where the Files app shows it.
  @override
  Future<String> saveToDownloads(String hostPath, {required String name, required String mime}) async {
    final source = File(hostPath);
    if (!source.existsSync()) throw PlatformException(code: 'missing');
    final dir = await _documents();
    await dir.create(recursive: true);
    final target = await _freeFile(dir, documentFileName(name, hostPath));
    try {
      await source.copy(target.path);
    } catch (_) {
      // A half-written copy must not stay behind under the reserved name.
      if (target.existsSync()) await target.delete().catchError((Object _) => target);
      rethrow;
    }
    return appL10n.fileSavedIosFiles(target.uri.pathSegments.last);
  }

  @override
  Future<List<({int width, int height})>> pdfInfo(String hostPath) =>
      throw MissingPluginException('pdfInfo: Quick Look shows PDFs on this platform');

  @override
  Future<Uint8List> pdfPage(String hostPath, int page, int width) =>
      throw MissingPluginException('pdfPage: Quick Look shows PDFs on this platform');

  @override
  Future<void> pdfClose() async {}
}

/// [name] as a Documents file name: no path separators or control characters,
/// the source file's name when [name] is empty.
String documentFileName(String name, String sourcePath) {
  var base = name.trim();
  if (base.isEmpty) base = sourcePath.split('/').last;
  base = base.replaceAll(RegExp(r'[\x00-\x1f/\\:]'), '_').trim();
  if (base.isEmpty || base == '.' || base == '..') base = 'file';
  return base;
}

/// Reserves a name in [dir] that no file has yet: [name], then `stem (2).ext`…
/// Created exclusively, so two saves at once never share a name.
Future<File> _freeFile(Directory dir, String name) async {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var n = 1; n < 1000; n++) {
    final file = File('${dir.path}/${n == 1 ? name : '$stem ($n)$ext'}');
    try {
      await file.create(exclusive: true);
      return file;
    } on FileSystemException {
      continue;
    }
  }
  throw PlatformException(code: 'failed', message: 'no free name for $name');
}
