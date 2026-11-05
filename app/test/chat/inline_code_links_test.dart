import 'package:dsh_app/state/artifact_links.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Artifact _a(String path, {int turn = 1}) => Artifact(path: path, origin: ArtifactOrigin.delivered, turn: turn);

class _Files extends Notifier<List<TurnArtifacts>> {
  @override
  List<TurnArtifacts> build() => const [];

  void set(List<TurnArtifacts> files) => state = files;
}

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

/// The code span of [text] (a [CodeTextSpan] in the rendered paragraphs).
TextSpan? _codeSpan(WidgetTester tester, String text) {
  TextSpan? found;
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text == text && span.recognizer != null) found = span;
      if (span.text == text && found == null) found ??= span;
      span.children?.forEach(visit);
    }
  }

  for (final rich in tester.allWidgets.whereType<RichText>()) {
    visit(rich.text);
  }
  return found;
}

void main() {
  group('ArtifactLinkIndex.resolve', () {
    final index = ArtifactLinkIndex.of([
      _a('/w/out/report.md'),
      _a('/w/src/a/util.dart'),
      _a('/w/src/b/util.dart'),
      _a('/w/notes.txt'),
    ], baseDir: '/w');

    test('exact path, as declared and relative to the base directory', () {
      expect(index.resolve('/w/out/report.md')?.path, '/w/out/report.md');
      expect(index.resolve('  out/report.md ')?.path, '/w/out/report.md');
      expect(index.resolve('./out/report.md')?.path, '/w/out/report.md');
      expect(index.resolve('src/a/util.dart')?.path, '/w/src/a/util.dart');
    });

    test('a unique basename', () {
      expect(index.resolve('report.md')?.path, '/w/out/report.md');
      expect(index.resolve('notes.txt')?.path, '/w/notes.txt');
    });

    test('an ambiguous basename links nothing', () {
      expect(index.resolve('util.dart'), isNull);
    });

    test('a folder that does not match the file links nothing', () {
      expect(index.resolve('docs/report.md'), isNull);
      expect(index.resolve('b/report.md'), isNull);
      expect(index.resolve('missing.md'), isNull);
    });

    test('too long, multi-line or parent-escaping code links nothing', () {
      expect(index.resolve('${'a/' * 100}report.md'), isNull);
      expect(index.resolve('out/\nreport.md'), isNull);
      expect(index.resolve('../w/out/report.md'), isNull);
      expect(index.resolve('out/..'), isNull);
      expect(index.resolve(''), isNull);
      expect(index.resolve('out/'), isNull);
    });

    test('the same file named by two turns is not ambiguous', () {
      final twice = ArtifactLinkIndex.of([_a('/w/a.md'), _a('/w/a.md', turn: 2)]);
      expect(twice.resolve('a.md')?.turn, 2);
    });
  });

  group('inline code in a reply', () {
    final theme = buildLightTheme();
    const files = [
      TurnArtifacts(
        turn: 1,
        endSeq: 3,
        files: [Artifact(path: '/w/out/report.md', origin: ArtifactOrigin.delivered, turn: 1)],
      ),
    ];

    Widget app(_Routes observer, {bool streaming = false, bool scoped = true, bool session = true, bool reply = true}) {
      Widget body = MarkdownBody(
        text: 'Wrote `out/report.md` and `other.md`.',
        streaming: streaming,
        selectable: false,
        repairBareViews: reply,
      );
      if (session) body = MarkdownImageScope(sessionId: 's1', baseDir: '/w', child: body);
      final home = MaterialApp(
        theme: theme,
        navigatorObservers: [observer],
        home: Scaffold(body: body),
      );
      return scoped
          ? ProviderScope(overrides: [sessionArtifactsProvider('s1').overrideWith((ref) => files)], child: home)
          : home;
    }

    testWidgets('a finished reply opens the file preview', (tester) async {
      final observer = _Routes();
      await tester.pumpWidget(app(observer));
      final span = _codeSpan(tester, 'out/report.md')!;
      expect(span.recognizer, isA<TapGestureRecognizer>());
      expect(span.semanticsLabel, contains('out/report.md'));
      expect(_codeSpan(tester, 'other.md')!.recognizer, isNull);
      final count = observer.pushed.length;
      (span.recognizer! as TapGestureRecognizer).onTap!();
      expect(observer.pushed.length, count + 1);
      final route = observer.pushed.last as MaterialPageRoute<void>;
      final page = route.builder(tester.element(find.byType(MarkdownBody))) as ArtifactPreviewPage;
      expect(page.sessionId, 's1');
      expect(page.artifact.path, '/w/out/report.md');
      // Unmount before the preview builds.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a streaming reply does not link', (tester) async {
      await tester.pumpWidget(app(_Routes(), streaming: true));
      expect(_codeSpan(tester, 'out/report.md')!.recognizer, isNull);
    });

    testWidgets('without a ProviderScope nothing links', (tester) async {
      await tester.pumpWidget(app(_Routes(), scoped: false));
      expect(_codeSpan(tester, 'out/report.md')!.recognizer, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a previewed document does not link', (tester) async {
      await tester.pumpWidget(app(_Routes(), reply: false));
      expect(_codeSpan(tester, 'out/report.md')!.recognizer, isNull);
    });

    testWidgets('without a session scope nothing links', (tester) async {
      await tester.pumpWidget(app(_Routes(), session: false));
      expect(_codeSpan(tester, 'out/report.md')!.recognizer, isNull);
    });

    testWidgets('files that arrive after the reply make its code tappable', (tester) async {
      final late = NotifierProvider<_Files, List<TurnArtifacts>>(_Files.new);
      final container = ProviderContainer(
        overrides: [sessionArtifactsProvider('s1').overrideWith((ref) => ref.watch(late))],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: MarkdownImageScope(
                sessionId: 's1',
                baseDir: '/w',
                child: MarkdownBody(text: 'See `out/report.md`.', selectable: false, repairBareViews: true),
              ),
            ),
          ),
        ),
      );
      expect(_codeSpan(tester, 'out/report.md')!.recognizer, isNull);
      container.read(late.notifier).set(files);
      await tester.pump();
      expect(_codeSpan(tester, 'out/report.md')!.recognizer, isNotNull);
    });
  });
}
