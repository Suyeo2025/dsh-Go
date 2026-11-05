// [MediaChannel] where the Kotlin `dsh/media` side does not exist (iOS): the
// Photos library through `gal` (PHPhotoLibrary, add-only access, no album:
// an album needs full library access), pictures and videos alike.

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:url_launcher/url_launcher.dart';

import 'gallery.dart';

/// The calls [IosMediaChannel] makes into `gal` (a seam for tests).
class GalApi {
  const GalApi();

  Future<bool> hasAccess() => Gal.hasAccess();
  Future<bool> requestAccess() => Gal.requestAccess();
  Future<void> putImageBytes(Uint8List bytes, {required String name}) => Gal.putImageBytes(bytes, name: name);
  Future<void> putVideo(String path) => Gal.putVideo(path);
}

class IosMediaChannel extends MediaChannel {
  const IosMediaChannel({this.gal = const GalApi(), this.launch = launchUrl});

  final GalApi gal;
  final Future<bool> Function(Uri uri) launch;

  @override
  bool get savesVideos => true;

  @override
  Future<String> saveImage(Uint8List bytes, {required String name, required String mime}) async {
    await _access();
    final dot = name.lastIndexOf('.');
    await _put(() => gal.putImageBytes(bytes, name: dot > 0 ? name.substring(0, dot) : name));
    return name;
  }

  @override
  Future<String> saveVideo(String path) async {
    await _access();
    await _put(() => gal.putVideo(path));
    return path.split('/').last;
  }

  /// Asks for add-only access when it was never asked; a refusal is for good
  /// (only Settings turns it on), as `permission`.
  Future<void> _access() async {
    if (await gal.hasAccess()) return;
    if (!await gal.requestAccess()) throw PlatformException(code: 'permission');
  }

  /// `gal`'s errors as the codes [saveToGallery] reads.
  Future<void> _put(Future<void> Function() put) async {
    try {
      await put();
    } on GalException catch (e) {
      throw PlatformException(
        code: switch (e.type) {
          GalExceptionType.accessDenied => 'permission',
          GalExceptionType.notSupportedFormat => 'invalid',
          _ => 'failed',
        },
        message: e.type.message,
      );
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await launch(Uri.parse('app-settings:'));
    } catch (_) {
      return false;
    }
  }
}
