// Inline `code` in a finished reply that names a file the turn produced:
// `out/report.md` opens its preview, like the official Web client. Only an
// exact path or a basename that is unique among the session's artifacts counts;
// anything ambiguous stays plain code.

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'artifacts.dart';

/// Longest inline code that can still be a path.
const _maxCodeLength = 260;

/// A session's artifacts by path and by file name, for O(1) lookups while a
/// reply's inline code is built.
class ArtifactLinkIndex {
  const ArtifactLinkIndex._(this.byPath, this.byName, this._paths);

  /// No artifacts: nothing links.
  static const empty = ArtifactLinkIndex._({}, {}, []);

  /// The index of [artifacts] (later entries win over earlier ones with the
  /// same path). [baseDir]: when given, every path below it is also reachable
  /// by its relative form.
  factory ArtifactLinkIndex.of(Iterable<Artifact> artifacts, {String? baseDir}) {
    final latest = <String, Artifact>{};
    for (final a in artifacts) {
      final path = _norm(a.path);
      if (path.isNotEmpty) latest[path] = a;
    }
    if (latest.isEmpty) return empty;
    final prefix = _prefix(baseDir);
    final byPath = <String, Artifact>{};
    final byName = <String, List<Artifact>>{};
    for (final entry in latest.entries) {
      byPath[entry.key] = entry.value;
      if (prefix != null && entry.key.startsWith(prefix) && entry.key.length > prefix.length) {
        byPath.putIfAbsent(entry.key.substring(prefix.length), () => entry.value);
      }
      (byName[baseName(entry.key)] ??= []).add(entry.value);
    }
    return ArtifactLinkIndex._(byPath, byName, (latest.keys.toList()..sort()));
  }

  /// Artifacts by their path as declared, and by the path relative to the
  /// working directory when one was known.
  final Map<String, Artifact> byPath;

  /// Artifacts by file name; several entries mean the name is ambiguous.
  final Map<String, List<Artifact>> byName;

  final List<String> _paths;

  bool get isEmpty => byPath.isEmpty;

  /// Changes whenever the set of linkable paths does (a cheap rebuild key).
  int get version => Object.hashAll(_paths);

  /// The artifact the inline [code] names, or null: not a path, ambiguous, or
  /// not something the session produced.
  Artifact? resolve(String code, {String? baseDir}) {
    if (byPath.isEmpty) return null;
    final text = code.trim();
    if (text.isEmpty || text.length > _maxCodeLength) return null;
    if (text.contains('\n') || text.contains('\r') || text.contains('..')) return null;
    final path = _norm(text);
    if (path.isEmpty || path.endsWith('/')) return null;
    final exact = byPath[path];
    if (exact != null) return exact;
    final prefix = _prefix(baseDir);
    if (prefix != null && !path.startsWith('/')) {
      final under = byPath['$prefix$path'];
      if (under != null) return under;
    }
    final named = byName[baseName(path)];
    if (named == null) return null;
    // A bare name needs the only file of that name; a path with folders must
    // also be the tail of the file's path (`out/report.md` of `/w/out/report.md`).
    final hasDir = path.contains('/');
    Artifact? hit;
    for (final a in named) {
      if (hasDir && !_norm(a.path).endsWith('/$path')) continue;
      if (hit != null) return null;
      hit = a;
    }
    return hit;
  }

  @override
  bool operator ==(Object other) => other is ArtifactLinkIndex && listEquals(_paths, other._paths);

  @override
  int get hashCode => version;

  static String _norm(String path) {
    var p = path.trim().replaceAll('\\', '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    return p;
  }

  static String? _prefix(String? baseDir) {
    if (baseDir == null) return null;
    final d = _norm(baseDir);
    if (d.isEmpty) return null;
    return d.endsWith('/') ? d : '$d/';
  }
}

/// The linkable artifacts of one session, derived from [sessionArtifactsProvider]
/// (so it follows the list: a turn's files become clickable when it ends).
final artifactLinkIndexProvider = Provider.autoDispose.family<ArtifactLinkIndex, String>((ref, sessionId) {
  final turns = ref.watch(sessionArtifactsProvider(sessionId));
  return ArtifactLinkIndex.of([for (final t in turns) ...t.files]);
});
