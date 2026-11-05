// The pet keeps out of the text, the keys and the capsules (docs/design/pets.md
// §2.2): it fades while the conversation scrolls behind it, a narrow pill is a
// keep-out area rather than a perch (it stands on the capsule below, beside
// it), a banner across the row still is a perch, and a chat list under a pet
// stage reports leaving its bottom.

import 'dart:math' as math;

import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/pets/pet_perch.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show ChatHarness, pumpFrames;
import 'support.dart';

late TestClock clock;
late ProviderContainer container;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> pumpHarness(WidgetTester tester, {ValueChanged<Offset>? onListTap}) async {
  usePhoneView(tester);
  await warmSheets(tester, deepy, [deepy.animFor(PetStateName.idle)]);
  await tester.pumpWidget(
    testApp(ChatBottomHarness(onListTap: onListTap), overrides: petOverrides(pack: deepy, clock: clock)),
  );
  container = ProviderScope.containerOf(tester.element(find.byType(ChatBottomHarness)));
  await _settle(tester);
}

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(of: find.byKey(const ValueKey('pet-body')), matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

/// The body's hit box on screen (idle).
Rect _hitBox(WidgetTester tester) {
  final s = petScaleOn(tester, deepy);
  final box = deepy.hitBoxFor(deepy.animFor(PetStateName.idle));
  final canvas = petCanvas(tester);
  return Rect.fromLTRB(
    canvas.left + box.left * s,
    canvas.top + box.top * s,
    canvas.left + box.right * s,
    canvas.top + math.min(box.bottom, deepy.baseline) * s,
  );
}

/// A pill (or a banner across the row) over a composer stand-in, as the chat
/// page stacks them, on a stage 400 wide.
class _BannerHarness extends StatelessWidget {
  const _BannerHarness({this.bannerWidth});

  /// Null: a banner across the row.
  final double? bannerWidth;

  @override
  Widget build(BuildContext context) {
    final banner = SizedBox(key: const ValueKey('banner'), width: bannerWidth ?? double.infinity, height: 32);
    return Scaffold(
      body: PetStage(
        child: Stack(
          children: [
            Positioned(
              left: 12,
              right: 12,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: PetPerch(kind: PerchKind.banner, child: banner),
                    ),
                  ),
                  const PetPerch(
                    kind: PerchKind.composer,
                    child: SizedBox(key: ValueKey('composer'), height: 56),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> pumpBanner(WidgetTester tester, {double? bannerWidth}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(800, 1600);
  addTearDown(tester.view.reset);
  await warmSheets(tester, deepy, [deepy.animFor(PetStateName.idle)]);
  await tester.pumpWidget(
    testApp(_BannerHarness(bannerWidth: bannerWidth), overrides: petOverrides(pack: deepy, clock: clock)),
  );
  container = ProviderScope.containerOf(tester.element(find.byType(_BannerHarness)));
  await _settle(tester);
}

double _footY(WidgetTester tester) => petCanvas(tester).top + deepy.baseline * petScaleOn(tester, deepy);

double _footX(WidgetTester tester) => petCanvas(tester).left + deepy.anchorX * petScaleOn(tester, deepy);

/// A chat list of 40 messages, under a pet stage's scope or not.
Future<ScrollPosition> pumpList(WidgetTester tester, {bool underPet = true, ValueNotifier<bool>? shown}) async {
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
  const chat = ChatList(sessionId: 's1', topInset: 24, bottomInset: 6);
  final list = shown == null
      ? chat
      : ValueListenableBuilder<bool>(valueListenable: shown, builder: (_, on, _) => on ? chat : const SizedBox());
  final registry = PerchRegistry();
  addTearDown(registry.dispose);
  await tester.pumpWidget(
    testApp(
      Scaffold(body: underPet ? PetPerchScope(registry: registry, child: list) : list),
      overrides: harness.overrides,
    ),
  );
  container = ProviderScope.containerOf(tester.element(find.byType(ChatList)));
  await pumpFrames(tester);
  return tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clock = TestClock();
    PetLayer.random = math.Random(7);
  });
  tearDown(PetSheets.instance.clear);

  group('the text scrolling behind it', () {
    test('any owner away from the bottom keeps the flag; each clears only its own', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final flag = c.read(petContentBehindProvider.notifier);
      final a = Object();
      final b = Object();
      expect(c.read(petContentBehindProvider), isFalse);
      flag.set(a, true);
      expect(c.read(petContentBehindProvider), isTrue);
      flag.set(b, false);
      expect(c.read(petContentBehindProvider), isTrue, reason: 'one true, one false');
      flag.set(b, true);
      flag.set(a, false);
      expect(c.read(petContentBehindProvider), isTrue, reason: 'b still away');
      flag.set(b, false);
      expect(c.read(petContentBehindProvider), isFalse);
    });

    testWidgets('it fades out and lets touches through; back at the bottom it returns', (tester) async {
      final list = <Offset>[];
      await pumpHarness(tester, onListTap: list.add);
      expect(container.read(petLayerShownProvider), isTrue);
      expect(_opacity(tester), 1);
      final headroom = container.read(petHeadroomProvider);
      expect(headroom, greaterThan(0));
      final body = _hitBox(tester);

      final owner = Object();
      container.read(petContentBehindProvider.notifier).set(owner, true);
      await _settle(tester);
      expect(container.read(petLayerShownProvider), isFalse);
      expect(_opacity(tester), 0);
      final registry = PetPerchScope.maybeOf(tester.element(find.byType(PetLayer)))!;
      expect(registry.occupied.value, isNull, reason: 'the strip may show its own whale');
      expect(registry.leading.value, isTrue);
      expect(
        container.read(petHeadroomProvider),
        headroom,
        reason: 'the list keeps its room: the lines being read do not shift',
      );
      await tester.tapAt(body.center);
      await tester.pump(const Duration(milliseconds: 500));
      expect(list, hasLength(1), reason: 'the faded pet takes no touches');

      // Another list at the bottom does not bring it back.
      container.read(petContentBehindProvider.notifier).set(Object(), false);
      await _settle(tester);
      expect(_opacity(tester), 0);

      container.read(petContentBehindProvider.notifier).set(owner, false);
      await _settle(tester);
      expect(container.read(petLayerShownProvider), isTrue);
      expect(_opacity(tester), 1);
      expect(registry.occupied.value, PerchKind.composer);
    });

    testWidgets('it does not walk while faded', (tester) async {
      await pumpHarness(tester);
      container.read(petContentBehindProvider.notifier).set(Object(), true);
      await _settle(tester);
      final before = petLayer(tester).foot;
      // Past the longest wait between walks (5 min).
      var walked = false;
      for (var i = 0; i < 330; i++) {
        await tester.pump(const Duration(seconds: 1));
        walked |= petLayer(tester).walking;
      }
      expect(walked, isFalse);
      expect(petLayer(tester).foot, before);
    });
  });

  group('narrow pills', () {
    testWidgets('a narrow pill is kept out of: it stands on the composer, beside the pill', (tester) async {
      await pumpBanner(tester, bannerWidth: 120);
      final pill = tester.getRect(find.byKey(const ValueKey('banner')));
      final composer = tester.getRect(find.byKey(const ValueKey('composer')));
      expect(pill.width, 120);
      expect(petLayer(tester).perch, PerchKind.composer);
      expect((_footY(tester) - composer.top).abs(), lessThanOrEqualTo(0.5));
      final keepOut = pill.inflate(PetMetrics.avoidGap);
      final x = _footX(tester);
      expect(x < keepOut.left || x > keepOut.right, isTrue, reason: 'foot $x, pill $keepOut');
      final s = petScaleOn(tester, deepy);
      final left = x - (deepy.anchorX - deepy.contentBox.left) * s;
      final right = x + (deepy.contentBox.right - deepy.anchorX) * s;
      expect(right <= keepOut.left + 0.5 || left >= keepOut.right - 0.5, isTrue, reason: 'body $left..$right');
    });

    testWidgets('a banner across the row is still a perch', (tester) async {
      await pumpBanner(tester);
      final banner = tester.getRect(find.byKey(const ValueKey('banner')));
      expect(banner.width, greaterThan(300));
      expect(petLayer(tester).perch, PerchKind.banner);
      expect((_footY(tester) - banner.top).abs(), lessThanOrEqualTo(0.5));
      expect(
        (_footX(tester) - (banner.left + banner.width * PetPrefs.defaultPosition)).abs(),
        lessThanOrEqualTo(0.5),
      );
    });
  });

  group('the chat list reports', () {
    testWidgets('scrolled up from the bottom: true; back at the bottom: false', (tester) async {
      final p = await pumpList(tester);
      expect(container.read(petContentBehindProvider), isFalse);
      p.jumpTo(p.maxScrollExtent - 400);
      await pumpFrames(tester);
      expect(container.read(petContentBehindProvider), isTrue);
      p.jumpTo(p.maxScrollExtent);
      await pumpFrames(tester);
      expect(container.read(petContentBehindProvider), isFalse);
    });

    testWidgets('leaving while scrolled up clears its flag', (tester) async {
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      final p = await pumpList(tester, shown: shown);
      p.jumpTo(p.maxScrollExtent - 400);
      await pumpFrames(tester);
      expect(container.read(petContentBehindProvider), isTrue);
      shown.value = false;
      await tester.pump();
      await tester.pump();
      expect(find.byType(ChatList), findsNothing);
      expect(container.read(petContentBehindProvider), isFalse);
    });

    testWidgets('a list without a pet over it does not report', (tester) async {
      final p = await pumpList(tester, underPet: false);
      p.jumpTo(p.maxScrollExtent - 400);
      await pumpFrames(tester);
      expect(container.read(petContentBehindProvider), isFalse);
    });
  });
}
