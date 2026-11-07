// dsh_web_phone.css against DSH 0.2.1-rc.5's own narrow drawer: rc.5 lays a
// full-frame mask (AppFrame `_drawerMask`, z-index 70) over a narrow frame
// whenever its sidebar is expanded, which is how the app's drawer keeps it.
// Above the drawer's column (z-index 60) it took every touch on the drawer:
// the conversation list couldn't be scrolled on iOS (device report: 「切换为
// 网页版 侧边栏无法刷动」). Found by hit-testing the page in a phone-sized
// Chromium: the point over the list was the mask before the fix and a
// session row after it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _css = File('assets/web/dsh_web_phone.css').readAsStringSync();

/// The declarations of the rule for exactly [selector].
String? _rule(String selector) {
  final at = _css.indexOf('$selector {');
  if (at < 0) return null;
  final open = _css.indexOf('{', at);
  return _css.substring(open + 1, _css.indexOf('}', open));
}

void main() {
  test("the drawer layout takes rc.5's own drawer mask out", () {
    final rule = _rule(
      ':root[data-dsh-app-layout="drawer"] [data-slot="root"] > [class*="_frame"] > [class*="_drawerMask"]',
    );
    expect(rule, isNotNull, reason: 'anchored to the frame, only in the drawer layout');
    expect(rule, contains('display: none !important'));
  });

  test('the mask is the only official layer the drawer hides besides the resize handle', () {
    final hidden = RegExp(r'([^{}]+)\{[^}]*display:\s*none\s*!important[^}]*\}')
        .allMatches(_css)
        .map((m) => m.group(1)!.trim())
        .where((s) => s.contains('[data-slot="root"] > [class*="_frame"] >'))
        .toList();
    expect(hidden, hasLength(2));
    expect(hidden.where((s) => s.endsWith('[class*="_handle"]')), hasLength(1));
    expect(hidden.where((s) => s.endsWith('[class*="_drawerMask"]')), hasLength(1));
  });

  test('the app drawer still has a scrim of its own beside it', () {
    expect(
      _css,
      contains('[data-slot="root"] > [class*="_frame"][data-dsh-app-drawer] > [class*="_sidebarCol"]::after'),
    );
  });
}
