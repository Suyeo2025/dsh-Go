import 'dart:convert';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';

/// One saved direct host: a `dsh web` reachable at its own URL (started with
/// `--trusted-host <name>`, typically behind a TLS reverse proxy). Persisted as
/// JSON in SharedPreferences; the launch token and the session cookie live in
/// the [SecretStore] under [DirectSecrets] keys, never in this config.
class DirectHostConfig {
  const DirectHostConfig({required this.id, required this.name, required this.baseUrl, this.signInUrl});

  /// Stable id (`direct-<hex>`); also the secret-store namespace.
  final String id;

  /// What the person calls it.
  final String name;

  /// Normalized origin plus optional mount path, no query and no trailing
  /// slash (`https://dsh.example.com`), see [normalizeDirectBaseUrl].
  final String baseUrl;

  Uri get baseUri => Uri.parse(baseUrl);

  /// The Access-protected address that hands out a fresh launch token after a
  /// Google sign-in (`https://dsh.example.com`, see
  /// `direct_google_sign_in.dart`); null for a host set up by hand.
  final String? signInUrl;

  /// `dsh.example.com` (scheme dropped for https, kept for plain http).
  String get address {
    final uri = baseUri;
    final authority = uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)
        ? '${uri.host}:${uri.port}'
        : uri.host;
    final path = uri.path;
    return uri.scheme == 'https' ? '$authority$path' : 'http://$authority$path';
  }

  /// Changes that need a new connection (a rename doesn't).
  String get connectionKey => baseUrl;

  DirectHostConfig copyWith({String? name, String? baseUrl, String? Function()? signInUrl}) => DirectHostConfig(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    signInUrl: signInUrl != null ? signInUrl() : this.signInUrl,
  );

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl, 'signInUrl': ?signInUrl};

  static DirectHostConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['baseUrl'];
    if (id is! String || id.isEmpty || url is! String) return null;
    final base = normalizeDirectBaseUrl(url);
    if (base == null) return null;
    final name = raw['name'];
    final signIn = raw['signInUrl'];
    final config = DirectHostConfig(
      id: id,
      name: '',
      baseUrl: base.toString(),
      // Older entries have none; anything that isn't https is dropped.
      signInUrl: signIn is String ? normalizeSignInUrl(signIn)?.toString() : null,
    );
    return config.copyWith(name: name is String && name.trim().isNotEmpty ? name : config.address);
  }

  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'direct-$hex';
  }

  @override
  bool operator ==(Object other) =>
      other is DirectHostConfig &&
      other.id == id &&
      other.name == name &&
      other.baseUrl == baseUrl &&
      other.signInUrl == signInUrl;

  @override
  int get hashCode => Object.hash(id, name, baseUrl, signInUrl);
}

/// Secret material for one direct host, from the [SecretStore].
class DirectSecrets {
  const DirectSecrets({this.token, this.cookie});

  /// The `dsh web` launch token (changes on every restart of the server).
  final String? token;

  /// The session cookie the token bought (valid ~30 days, across restarts).
  final DshCookie? cookie;

  static String tokenKey(String hostId) => 'direct.$hostId.token';
  static String cookieKey(String hostId) => 'direct.$hostId.cookie';

  bool get hasToken => token != null && token!.isNotEmpty;

  static String encodeCookie(DshCookie cookie) => jsonEncode(cookie.toJson());

  /// Null for anything unreadable (a corrupt entry just means "log in again").
  static DshCookie? decodeCookie(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final cookie = DshCookie.fromJson(json);
      if (cookie.name.isEmpty || cookie.value.isEmpty || cookie.authority.isEmpty) return null;
      return cookie;
    } catch (_) {
      return null;
    }
  }
}

/// `dsh.example.com`, `https://dsh.example.com/`, `http://10.0.0.2:3080/dsh`
/// → `https://dsh.example.com`, `http://10.0.0.2:3080/dsh`. A missing scheme
/// means https. Null for anything that isn't a plain http(s) URL (user info,
/// another scheme, no host).
Uri? normalizeDirectBaseUrl(String text) {
  var t = text.trim();
  if (t.isEmpty) return null;
  if (!t.contains('://')) t = 'https://$t';
  final uri = Uri.tryParse(t);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(scheme: uri.scheme, host: uri.host.toLowerCase(), port: uri.hasPort ? uri.port : null, path: path);
}

/// A sign-in address: like [normalizeDirectBaseUrl], https only (the Google
/// sign-in runs in the system browser and hands back a token).
Uri? normalizeSignInUrl(String text) {
  final uri = normalizeDirectBaseUrl(text);
  return uri?.scheme == 'https' ? uri : null;
}

/// What the add-host form was given: the URL field and the token field may
/// each hold a whole `https://host/?token=…` launch link (or the `dsh web: …`
/// line); it is split into its base URL and token.
class DirectHostInput {
  const DirectHostInput(this.baseUri, this.token);

  final Uri baseUri;

  /// Null when none was given (an edit that keeps the saved one).
  final String? token;
}

enum DirectInputProblem { urlMissing, urlInvalid }

class DirectInputException implements Exception {
  const DirectInputException(this.problem);
  final DirectInputProblem problem;

  @override
  String toString() => 'DirectInputException(${problem.name})';
}

/// Throws [DirectInputException] when no usable base URL can be found.
DirectHostInput parseDirectHostInput({required String url, String token = ''}) {
  final fromUrl = DshLaunchUrl.tryParse(url);
  final fromToken = DshLaunchUrl.tryParse(token);
  final launch = fromUrl ?? fromToken;
  final urlText = fromUrl != null ? '' : url.trim();
  final tokenText = fromToken != null ? '' : token.trim();

  Uri? base;
  if (urlText.isNotEmpty) {
    base = normalizeDirectBaseUrl(urlText);
    if (base == null) throw const DirectInputException(DirectInputProblem.urlInvalid);
  } else if (launch != null) {
    base = normalizeDirectBaseUrl(launch.baseUri.toString());
  }
  if (base == null) throw const DirectInputException(DirectInputProblem.urlMissing);
  final secret = tokenText.isNotEmpty ? tokenText : launch?.token;
  return DirectHostInput(base, secret == null || secret.isEmpty ? null : secret);
}
