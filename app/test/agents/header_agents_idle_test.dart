// The agents capsule in the chat header asks for no frames once none of its
// agents runs (iOS heat report: a hidden breathing dot kept a finished
// conversation with subagents at 60 fps).

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/ui/agents/header_agents.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../support/frame_counter.dart';

Future<void> _pump(WidgetTester tester, HeaderAgents agents, {bool reduced = false}) async {
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: Scaffold(
            body: Center(
              child: HeaderAgentsKey(sessionId: 's1', agents: agents),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a finished conversation with subagents: no frames at rest', (tester) async {
    await _pump(tester, const HeaderAgents(children: 3));
    expect(await framesOver(tester, const Duration(seconds: 2)), 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('one running: the dot breathes, at a low rate', (tester) async {
    await _pump(tester, const HeaderAgents(children: 3, running: 1));
    expect(find.byType(StatusDot), findsOneWidget);
    final frames = await framesOver(tester, const Duration(seconds: 2));
    expect(frames, inInclusiveRange(1, 24), reason: 'about 8 a second, not one per vsync');
  });

  testWidgets('one running, animations off: no frames', (tester) async {
    await _pump(tester, const HeaderAgents(children: 3, running: 1), reduced: true);
    expect(await framesOver(tester, const Duration(seconds: 2)), 0);
  });
}
