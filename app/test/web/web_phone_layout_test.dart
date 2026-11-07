// dsh_web_phone.js and DSH Web's own narrow drawer (0.2.1-rc.5): when the
// page folds its sidebar into a drawer of its own, the script stands down —
// it never expands the official sidebar (which put rc.5's mask over
// everything) and tells the app "official"; a page without one gets the
// app's drawer as before ("app"). Run against a page model under node
// (test/web/support/phone_layout_harness.mjs). Needs `node` on PATH; skipped
// without it.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/web/web_view_page.dart' show WebLayoutReport;
import 'package:flutter_test/flutter_test.dart';

String? _node() {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isNotEmpty && File('$dir/node').existsSync()) return '$dir/node';
  }
  return null;
}

void main() {
  final node = _node();
  final skip = node == null ? 'node is not installed' : null;

  Future<Map<String, Object?>> run(Map<String, Object?> scenario) async {
    final result = await Process.run(node!, [
      'test/web/support/phone_layout_harness.mjs',
      'assets/web/dsh_web_phone.js',
      jsonEncode(scenario),
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final out = jsonDecode(result.stdout as String) as Map<String, Object?>;
    expect(out['thrown'], isNull, reason: '${out['thrown']}');
    return out;
  }

  test("a page with its own drawer: left alone, and the app is told so", () async {
    final out = await run({'official': true});
    expect(out['reports'], [WebLayoutReport.official]);
    expect(out['clicks'], isEmpty, reason: 'the official sidebar is never expanded by the app');
    expect(out['officialExpanded'], false);
    expect(out['appDrawer'], false);
    expect(out['layout'], WebLayoutReport.official);
  }, skip: skip);

  test('the frame saying it is a drawer a moment after it is drawn still counts', () async {
    final out = await run({'official': true, 'frameAt': 300, 'officialAt': 500});
    expect(out['reports'], [WebLayoutReport.official]);
    expect(out['clicks'], isEmpty);
  }, skip: skip);

  test("a page without one (an older DSH): the app's drawer, the official sidebar expanded under it", () async {
    final out = await run({'official': false});
    expect(out['reports'], [WebLayoutReport.app]);
    expect(out['clicks'], ['toggle']);
    expect(out['officialExpanded'], true);
  }, skip: skip);

  test('the official layout (tablets): nothing reported, nothing pressed', () async {
    final out = await run({'official': false, 'layout': 'desktop'});
    expect(out['reports'], isEmpty);
    expect(out['clicks'], isEmpty);
  }, skip: skip);
}
