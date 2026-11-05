import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

bool _visible(WidgetTester tester) =>
    tester
        .widget<AnimatedOpacity>(
          find.ancestor(of: find.byIcon(AppIcons.scrollToBottom), matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity ==
    1;

ScrollPosition _position(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;

Future<void> _open(WidgetTester tester) async {
  usePhoneView(tester);
  final harness = ChatHarness(
    session: 's1',
    states: {
      's1': ChatState(
        loading: false,
        items: [
          for (var i = 0; i < 40; i++)
            UserChatItem(
              seq: i,
              time: DateTime(2026),
              text: 'Message $i\nSecond line',
              images: const [],
              files: const [],
            ),
        ],
      ),
    },
  );
  await tester.pumpWidget(
    testApp(
      const Scaffold(body: ChatList(sessionId: 's1', topInset: 24, bottomInset: 6)),
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester);
}

Future<void> _distance(WidgetTester tester, double distance) async {
  final p = _position(tester);
  p.jumpTo(p.maxScrollExtent - distance);
  await tester.pump();
  expect(p.maxScrollExtent - p.pixels, closeTo(distance, 0.01));
}

/// 300 rows of uneven height: the lazy list's extent estimate is off until rows are built.
Future<ScrollPosition> _openLong(WidgetTester tester) async {
  usePhoneView(tester);
  final harness = ChatHarness(
    session: 's1',
    states: {
      's1': ChatState(
        loading: false,
        items: [
          for (var i = 0; i < 300; i++)
            UserChatItem(
              seq: i,
              time: DateTime(2026),
              text: List.filled(1 + (i * 7) % 13, 'Message $i line').join('\n'),
              images: const [],
              files: const [],
            ),
        ],
      ),
    },
  );
  await tester.pumpWidget(
    testApp(
      const Scaffold(body: ChatList(sessionId: 's1', topInset: 24, bottomInset: 6)),
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester);
  return _position(tester);
}

Future<void> _jumpLands(WidgetTester tester, ScrollPosition p) async {
  expect(_visible(tester), isTrue);
  await tester.tap(find.byIcon(AppIcons.scrollToBottom));
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(p.maxScrollExtent - p.pixels, lessThan(1));
  expect(_visible(tester), isFalse);
}

void main() {
  testWidgets('the visible jump button does not flicker around its show threshold', (tester) async {
    await _open(tester);
    expect(_visible(tester), isFalse);
    await _distance(tester, 161);
    expect(_visible(tester), isTrue);
    for (final distance in [159.0, 160.0, 161.0, 159.0]) {
      await _distance(tester, distance);
      expect(_visible(tester), isTrue, reason: 'Already shown at distance $distance');
    }
  });

  testWidgets('the jump button hides at pinned distance and waits for the show threshold again', (tester) async {
    await _open(tester);
    await _distance(tester, 161);
    await _distance(tester, 25);
    expect(_visible(tester), isTrue);
    await _distance(tester, 24);
    expect(_visible(tester), isFalse);
    for (final distance in [25.0, 159.0, 160.0]) {
      await _distance(tester, distance);
      expect(_visible(tester), isFalse);
    }
    await _distance(tester, 161);
    expect(_visible(tester), isTrue);
  });

  testWidgets('jump reaches the bottom of a long list after a tap on a row', (tester) async {
    final p = await _openLong(tester);
    // A tap on a row (no drag) marks the list as held by the user.
    await tester.tapAt(tester.getCenter(find.byType(CustomScrollView)));
    await pumpFrames(tester);
    p.jumpTo(p.minScrollExtent);
    await pumpFrames(tester);
    await _jumpLands(tester, p);
  });

  testWidgets('on iOS, jump lands at the bottom while a fling is still coasting', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final p = await _openLong(tester);
      await tester.fling(find.byType(CustomScrollView), const Offset(0, 900), 4000);
      // Still moving: the "N 项待确认" / jump key is tapped mid-momentum.
      await tester.pump(const Duration(milliseconds: 120));
      expect(p.isScrollingNotifier.value, isTrue);
      await _jumpLands(tester, p);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('tapping jump still returns to the bottom and immediately hides it', (tester) async {
    await _open(tester);
    await _distance(tester, 200);
    await pumpFrames(tester);
    await tester.tap(find.byIcon(AppIcons.scrollToBottom));
    await pumpFrames(tester);
    expect(_visible(tester), isFalse);
    final p = _position(tester);
    expect(p.pixels, p.maxScrollExtent);
  });
}
