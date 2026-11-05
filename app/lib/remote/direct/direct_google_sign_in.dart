import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import 'direct_host_config.dart';

/// "用 Google 登录" for a direct host whose server sits behind an access gate
/// (Cloudflare Access + Google). The gate's `GET <sign-in>/__gate/app` sends a
/// signed-in browser to `dshgo-auth://auth?state=…&token=<launch token>&base=…`,
/// where `base` is the ungated address the app connects to. Google refuses
/// embedded web views, so the page opens in the system's web authentication
/// session (ASWebAuthenticationSession), which hands the callback URL back.

const directAuthCallbackScheme = 'dshgo-auth';
const directAuthCallbackHost = 'auth';
const directGatePath = '/__gate/app';

/// The native side of the system web authentication session (iOS).
const directWebAuthChannel = MethodChannel('dsh/web_auth');

enum DirectSignInFailure {
  /// The person closed the sign-in page.
  canceled,

  /// No web authentication session on this platform (Android, tests).
  unsupported,

  /// The session failed (network, the browser).
  failed,

  /// Something came back, but not a callback this request asked for.
  invalidCallback,
}

/// Never carries the token or the callback URL.
class DirectSignInException implements Exception {
  const DirectSignInException(this.kind);
  final DirectSignInFailure kind;

  /// One sentence for the UI; null for a cancel (nothing to say).
  String? get message => switch (kind) {
    DirectSignInFailure.canceled => null,
    DirectSignInFailure.unsupported => appL10n.directSignInUnsupported,
    DirectSignInFailure.failed => appL10n.directSignInFailed,
    DirectSignInFailure.invalidCallback => appL10n.directSignInBadReply,
  };

  @override
  String toString() => 'DirectSignInException(${kind.name})';
}

/// What a successful sign-in hands back.
class DirectSignInResult {
  const DirectSignInResult(this.baseUri, this.token);

  /// The ungated https address to connect to.
  final Uri baseUri;
  final String token;
}

/// Opens [url] in the system web authentication session and resolves with the
/// callback URL that ended it.
typedef WebAuthenticator = Future<String> Function(Uri url, String callbackScheme);

/// [WebAuthenticator] over [directWebAuthChannel].
Future<String> channelWebAuthenticator(Uri url, String callbackScheme) async {
  final String? callback;
  try {
    callback = await directWebAuthChannel.invokeMethod<String>('authenticate', {
      'url': url.toString(),
      'callbackScheme': callbackScheme,
      'ephemeral': false,
    });
  } on MissingPluginException {
    throw const DirectSignInException(DirectSignInFailure.unsupported);
  } on PlatformException catch (e) {
    throw DirectSignInException(e.code == 'CANCELED' ? DirectSignInFailure.canceled : DirectSignInFailure.failed);
  }
  if (callback == null || callback.isEmpty) throw const DirectSignInException(DirectSignInFailure.failed);
  return callback;
}

final directWebAuthenticatorProvider = Provider<WebAuthenticator>((ref) => channelWebAuthenticator);

/// 32 random bytes, base64url without padding (43 characters).
String newSignInState([math.Random? random]) {
  final r = random ?? math.Random.secure();
  return base64Url.encode(List.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
}

/// `<sign-in>/__gate/app?cb=dshgo-auth&state=<state>`.
Uri directSignInRequestUrl(Uri signIn, String state) => signIn.replace(
  path: '${signIn.path}$directGatePath',
  queryParameters: {'cb': directAuthCallbackScheme, 'state': state},
);

/// Checks the callback against the [state] this request sent; throws
/// [DirectSignInFailure.invalidCallback] for anything else.
DirectSignInResult parseSignInCallback(String callback, {required String state}) {
  const invalid = DirectSignInException(DirectSignInFailure.invalidCallback);
  final uri = Uri.tryParse(callback);
  if (uri == null || uri.scheme != directAuthCallbackScheme || uri.host != directAuthCallbackHost) throw invalid;
  final Map<String, List<String>> query;
  try {
    query = uri.queryParametersAll;
  } on FormatException {
    throw invalid;
  }
  String? single(String name) {
    final values = query[name];
    return values != null && values.length == 1 && values.single.isNotEmpty ? values.single : null;
  }

  final returned = single('state');
  if (returned == null || !_sameString(returned, state)) throw invalid;
  final token = single('token');
  final base = single('base');
  if (token == null || base == null) throw invalid;
  // Only an explicit https URL: no scheme-less guess for an address the
  // server picked.
  final baseUri = base.startsWith('https://') ? normalizeSignInUrl(base) : null;
  if (baseUri == null) throw invalid;
  return DirectSignInResult(baseUri, token);
}

/// Signs in at [signIn] (an https sign-in address) and returns the address and
/// launch token the gate handed back.
Future<DirectSignInResult> signInWithGoogle(
  Uri signIn, {
  required WebAuthenticator authenticate,
  math.Random? random,
}) async {
  final state = newSignInState(random);
  final callback = await authenticate(directSignInRequestUrl(signIn, state), directAuthCallbackScheme);
  return parseSignInCallback(callback, state: state);
}

/// Compares without stopping at the first difference.
bool _sameString(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
