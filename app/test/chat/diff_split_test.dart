// 左右对比: pairing a unified diff into old | new rows (pairDiffLines), and
// the change page's 对比方式 key — side by side from 840 wide, unified on
// phones, a switch that holds across files and pages.
//
//   flutter test test/chat/diff_split_test.dart

import 'package:dsh_app/ui/chat/diff_page.dart';
import 'package:dsh_app/ui/chat/render/diff_view.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

DiffLine _c(String t) => DiffLine(DiffLineKind.context, ' $t');
DiffLine _d(String t) => DiffLine(DiffLineKind.del, '-$t');
DiffLine _a(String t) => DiffLine(DiffLineKind.add, '+$t');
DiffLine _h(String t) => DiffLine(DiffLineKind.hunk, t);

/// The pairs as (left text, right text), null for an empty side.
List<(String?, String?)> _texts(List<DiffLine> lines) => [
  for (final p in pairDiffLines(lines)) (p.left?.text, p.right?.text),
];

FileChange _file(String path, String before, String after, {int start = 10}) {
  final lines = computeLineDiff(before, after);
  final added = lines.where((l) => l.kind == DiffLineKind.add).length;
  final removed = lines.where((l) => l.kind == DiffLineKind.del).length;
  return FileChange(
    path: '/root/workspace/$path',
    created: false,
    added: added,
    removed: removed,
    lines: lines,
    edits: 1,
    hunks: [DiffHunk(lines: lines, edit: 1, oldStart: start, newStart: start)],
  );
}

final _files = [
  _file('lib/a.dart', 'one\ntwo\nthree\nfour', 'one\nTWO\nthree\nfour\nfive'),
  _file('lib/b.dart', 'alpha\nbeta', 'alpha\ngamma\ndelta', start: 3),
];

void _window(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width, 800) * 2;
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
  tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
}

Future<void> _pumpPage(WidgetTester tester, double width) async {
  _window(tester, width);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(ChangeDiffPage(files: _files)));
  await pumpFrames(tester, 4);
}

final _split = find.byKey(const ValueKey('diff-split'));
final _unified = find.byKey(const ValueKey('diff-unified'));
final _toggle = find.byKey(const ValueKey('diff-split-toggle'));

void main() {
  group('pairDiffLines', () {
    test('context only: each line on both sides', () {
      expect(_texts([_c('a'), _c('b')]), [(' a', ' a'), (' b', ' b')]);
    });

    test('a deletion followed by as many additions: row by row', () {
      expect(_texts([_c('a'), _d('b'), _d('c'), _a('B'), _a('C'), _c('d')]), [
        (' a', ' a'),
        ('-b', '+B'),
        ('-c', '+C'),
        (' d', ' d'),
      ]);
    });

    test('more deleted than added: the extra old lines face blanks', () {
      expect(_texts([_d('b'), _d('c'), _d('e'), _a('B')]), [('-b', '+B'), ('-c', null), ('-e', null)]);
    });

    test('more added than deleted: the extra new lines face blanks', () {
      expect(_texts([_d('b'), _a('B'), _a('C'), _a('D'), _c('z')]), [
        ('-b', '+B'),
        (null, '+C'),
        (null, '+D'),
        (' z', ' z'),
      ]);
    });

    test('a lone addition sits on the right, a lone deletion on the left', () {
      expect(_texts([_c('a'), _a('new'), _c('b'), _d('old'), _c('c')]), [
        (' a', ' a'),
        (null, '+new'),
        (' b', ' b'),
        ('-old', null),
        (' c', ' c'),
      ]);
      // Additions then deletions: two blocks, not one.
      expect(_texts([_a('x'), _d('y')]), [(null, '+x'), ('-y', null)]);
    });

    test('hunk and meta lines span both sides and close a block', () {
      final meta = DiffLine(DiffLineKind.meta, '--- a/x');
      expect(_texts([meta, _h('@@ -1,2 +1,2 @@'), _d('a'), _h('@@ -9 +9 @@'), _a('b')]), [
        ('--- a/x', '--- a/x'),
        ('@@ -1,2 +1,2 @@', '@@ -1,2 +1,2 @@'),
        ('-a', null),
        ('@@ -9 +9 @@', '@@ -9 +9 @@'),
        (null, '+b'),
      ]);
    });

    test('the same lines, not copies', () {
      final del = _d('a');
      final add = _a('b');
      expect(pairDiffLines([del, add]), [DiffPair(left: del, right: add)]);
    });
  });

  testWidgets('DiffView split: two columns, old on the left, new on the right', (tester) async {
    _window(tester, 1024);
    await tester.pumpWidget(
      testApp(Scaffold(body: DiffView(lines: [_c('same'), _d('gone'), _a('came')], split: true))),
    );
    expect(find.byKey(const ValueKey('diff-view-split')), findsOneWidget);
    expect(find.text(' same'), findsNWidgets(2));
    final gone = tester.getRect(find.text('-gone'));
    final came = tester.getRect(find.text('+came'));
    expect(gone.left, lessThan(512));
    expect(came.left, greaterThan(512));
    expect(gone.top, came.top);
  });

  // The page's choice lives for the run: these go in order.
  group('ChangeDiffPage', () {
    testWidgets('1024 wide: side by side by default, old numbers left, new right', (tester) async {
      await _pumpPage(tester, 1024);
      expect(_split, findsOneWidget);
      expect(_unified, findsNothing);
      expect(_toggle, findsOneWidget);
      // two → TWO on one row: the old line left of the middle, the new right.
      final old = tester.getRect(find.text('two'));
      final fresh = tester.getRect(find.text('TWO'));
      expect(old.top, fresh.top);
      expect(old.right, lessThan(512));
      expect(fresh.left, greaterThan(512));
      // Line 11 on both sides (old and new numbering), each once.
      expect(find.text('11'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('390 wide: unified, and no key to switch', (tester) async {
      await _pumpPage(tester, 390);
      expect(_unified, findsOneWidget);
      expect(_split, findsNothing);
      expect(_toggle, findsNothing);
    });

    testWidgets('the switch: takes effect, holds across files and the next page', (tester) async {
      await _pumpPage(tester, 1024);
      await tester.tap(_toggle);
      await pumpFrames(tester, 4);
      expect(_unified, findsOneWidget);
      expect(_split, findsNothing);

      // The second file.
      await tester.tap(find.text('b.dart').first);
      await pumpFrames(tester, 8);
      expect(find.text('gamma'), findsOneWidget);
      expect(_unified, findsOneWidget);
      expect(_split, findsNothing);

      // A new page this run.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(testApp(ChangeDiffPage(files: _files)));
      await pumpFrames(tester, 4);
      expect(_unified, findsOneWidget);

      // Back to side by side, then without wrapping: the columns scroll
      // sideways on their own.
      await tester.tap(_toggle);
      await pumpFrames(tester, 4);
      expect(_split, findsOneWidget);
      await tester.tap(find.byTooltip('不换行'));
      await pumpFrames(tester, 4);
      expect(_split, findsOneWidget);
      expect(
        find.descendant(
          of: _split,
          matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
        ),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);

      // A phone still gets the unified view.
      await tester.pumpWidget(const SizedBox());
      _window(tester, 390);
      await tester.pumpWidget(testApp(ChangeDiffPage(files: _files)));
      await pumpFrames(tester, 4);
      expect(_unified, findsOneWidget);
      expect(_split, findsNothing);
    });
  });
}
