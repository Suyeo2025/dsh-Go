// The pet at rest asks for no frames (iOS heat report: an idle pet kept the
// chat page at 60 fps). Left alone in a quiet state it plays its loop for a
// while, then holds a still frame; anything that happens to it (a new state,
// a tap) plays again, and the busy states play on as before.

import 'dart:math' as math;

import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/pets/pet_sprite.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/frame_counter.dart';
import 'support.dart';

late TestClock clock;

Future<ProviderContainer> _pumpPet(WidgetTester tester, {Iterable<String> warm = const []}) async {
  usePhoneView(tester);
  await warmSheets(tester, deepy, [deepy.animFor(PetStateName.idle), for (final a in warm) deepy.animations[a]!]);
  await tester.pumpWidget(
    testApp(
      const ChatBottomHarness(),
      overrides: petOverrides(pack: deepy, clock: clock),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
  return ProviderScope.containerOf(tester.element(find.byType(ChatBottomHarness)));
}

PetSpriteState _sprite(WidgetTester tester) => tester.state(find.byType(PetSprite));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clock = TestClock();
    PetLayer.random = math.Random(7);
  });
  tearDown(PetSheets.instance.clear);

  testWidgets('an empty conversation with the pet: it plays, then rests without frames', (tester) async {
    await _pumpPet(tester);
    expect(petLayer(tester).playing?.name, 'idle');
    // It does play on arrival.
    expect(await framesOver(tester, const Duration(seconds: 1)), greaterThan(10));
    // Then, left alone, it settles on a still frame.
    await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 4));
    expect(await framesOver(tester, const Duration(seconds: 5)), 0);
    expect(tester.binding.transientCallbackCount, 0);
    expect(_sprite(tester).resting, isTrue);
  });

  testWidgets('a tap wakes it: the reaction plays, then it rests again', (tester) async {
    await _pumpPet(tester, warm: ['react-left', 'react-right']);
    await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 4));
    expect(_sprite(tester).resting, isTrue);
    await tester.tapAt(petCanvas(tester).center);
    expect(await framesOver(tester, const Duration(seconds: 1)), greaterThan(10));
    await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 6));
    expect(await framesOver(tester, const Duration(seconds: 3)), 0);
  });

  group('something waits for you (notification)', () {
    Future<ProviderContainer> ringing(WidgetTester tester) async {
      final container = await _pumpPet(tester, warm: ['notification']);
      container
          .read(testSignalsProvider.notifier)
          .set(
            PetSignals(
              lastInteraction: clock.now,
              pending: const [PetPending(host: HostRef.local, sessionId: 'waits', key: 'e1')],
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(petLayer(tester).playing?.name, 'notification');
      return container;
    }

    testWidgets('it rings for a while, then holds still: still the reminder, no frames', (tester) async {
      await ringing(tester);
      expect(await framesOver(tester, const Duration(seconds: 1)), greaterThan(10));
      await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 4));
      expect(await framesOver(tester, const Duration(seconds: 5)), 0);
      expect(petLayer(tester).playing?.name, 'notification', reason: 'the reminder stands');
      expect(_sprite(tester).resting, isTrue);
    });

    testWidgets('a touch rings it again, then it holds still again', (tester) async {
      final container = await ringing(tester);
      await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 4));
      expect(_sprite(tester).resting, isTrue);
      // The page's clock has moved on since the last touch (one a second counts).
      clock.advance(const Duration(seconds: 20));
      container.read(petInteractionProvider.notifier).touch();
      await tester.pump();
      expect(_sprite(tester).resting, isFalse);
      expect(await framesOver(tester, const Duration(seconds: 1)), greaterThan(10));
      await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 4));
      expect(await framesOver(tester, const Duration(seconds: 3)), 0);
    });
  });

  testWidgets('several runs at once (juggling): plays a while, then holds still', (tester) async {
    final container = await _pumpPet(tester, warm: ['music', 'conducting']);
    container
        .read(testSignalsProvider.notifier)
        .set(
          PetSignals(
            lastInteraction: clock.now,
            focus: const PetFocus(host: HostRef.local, sessionId: 'a', activity: PetActivity.working),
            runs: const [
              PetRun(HostRef.local, 'a'),
              PetRun(HostRef.local, 's1', subagent: true, root: 'a'),
            ],
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(petLayer(tester).playing?.name, 'music');
    await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 4));
    expect(await framesOver(tester, const Duration(seconds: 5)), 0);
  });

  testWidgets('working: plays on, it never rests', (tester) async {
    final container = await _pumpPet(tester, warm: ['typing']);
    container
        .read(testSignalsProvider.notifier)
        .set(
          PetSignals(
            lastInteraction: clock.now,
            focus: const PetFocus(host: HostRef.local, sessionId: 'a', activity: PetActivity.working),
            runs: const [PetRun(HostRef.local, 'a')],
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(petLayer(tester).playing?.name, 'typing');
    await framesOver(tester, PetSprite.restAfter + const Duration(seconds: 4));
    expect(await framesOver(tester, const Duration(seconds: 2)), greaterThan(20));
    expect(_sprite(tester).resting, isFalse);
  });
}
