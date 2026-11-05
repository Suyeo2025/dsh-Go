import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshCookie;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Hands a direct host's session cookie to the WebView cookie store, so the
/// 网页版 opens the host's DSH Web already signed in, without a launch token
/// in any URL (the token may be stale while the cookie still works).
typedef DirectWebCookieSink = Future<void> Function(Uri baseUri, DshCookie cookie);

Future<void> _setWebViewCookie(Uri baseUri, DshCookie cookie) async {
  try {
    await WebViewCookieManager().setCookie(
      WebViewCookie(name: cookie.name, value: cookie.value, domain: baseUri.host, path: '/'),
    );
  } catch (_) {
    // No WebView on this platform (tests, desktop): the page signs in itself.
  }
}

final directWebCookieSinkProvider = Provider<DirectWebCookieSink>((ref) => _setWebViewCookie);
