// TypingIndicator: the three bouncing dots that stand in for a message not yet sent.
//
// Nothing here is data. The bubble carries no name, because who is typing belongs in
// the app-bar subtitle where it does not shift the timeline every time somebody starts
// and stops; this widget only has to read as an incoming bubble that is not finished
// yet. It is therefore shaped like one: aligned left, white on the timeline's ground,
// and squared off at the top-left corner in the same way a real incoming bubble is.
//
// The three dots are driven by one repeating controller and offset by a fifth of its
// cycle each, which is what makes the row look like a wave rather than a blink. Both
// halves of that are asserted — the dots are at three different heights on the same
// frame, and they are somewhere else a moment later.
//
// The controller repeats forever, so, exactly as with `CustomLoader`, `pumpAndSettle`
// can never be used on a tree containing this widget: settling waits for the frame
// scheduler to go idle and a repeating animation never lets it. That is pinned below as
// a contract rather than discovered later as a screen test that hangs.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/chat/typing_indicator.dart';

import '../widget_harness.dart';

/// The vertical offset of each dot on the frame currently drawn. The three avatars are
/// a canonicalised const, so `byWidget` would match all three at once; each is reached
/// by position instead.
List<double> dotTops(WidgetTester tester) => List<double>.generate(
    3, (i) => tester.getTopLeft(find.byType(CircleAvatar).at(i)).dy);

void main() {
  Future<void> pumpIndicator(WidgetTester tester) =>
      pumpApp(tester, const Scaffold(body: TypingIndicator()));

  group('the bubble', () {
    testWidgets('it reads as an incoming bubble with three dots', (tester) async {
      await pumpIndicator(tester);
      expect(find.byType(CircleAvatar), findsNWidgets(3));
      expect(tester.widget<Align>(find.byType(Align)).alignment,
          Alignment.centerLeft);

      final dot = tester.widget<CircleAvatar>(find.byType(CircleAvatar).first);
      expect(dot.radius, 3.2);
      expect(dot.backgroundColor, AppColors.textSecondary);
    });

    // The squared top-left corner is what a real incoming bubble uses; a uniform
    // radius here would read as a pill floating beside the conversation.
    testWidgets('the corner nearest the sender is squared off', (tester) async {
      await pumpIndicator(tester);
      final box = tester
          .widgetList<Container>(find.byType(Container))
          .firstWhere((c) => c.decoration is BoxDecoration);
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, Colors.white);
      expect(decoration.borderRadius,
          const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(14),
          ));
      expect(decoration.border, Border.all(color: AppColors.border));
    });

    testWidgets('it stays on the left rather than filling the row', (tester) async {
      await pumpIndicator(tester);
      final bubble = sizeOf(tester, find.byType(TypingIndicator));
      expect(bubble.width, 800, reason: 'the Align occupies the row');
      final dots = tester.getRect(find.byType(Row));
      expect(dots.left, lessThan(60), reason: 'the bubble itself hugs the left edge');
    });
  });

  group('the wave', () {
    // A fifth of a cycle apart: on any one frame the dots are at three heights.
    testWidgets('the dots are staggered, not blinking in unison', (tester) async {
      await pumpIndicator(tester);
      final tops = dotTops(tester);
      expect(tops.length, 3);
      expect(tops.toSet().length, 3, reason: 'each dot is at its own point of the wave');
    });

    testWidgets('the dots have moved a moment later', (tester) async {
      await pumpIndicator(tester);
      final first = dotTops(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(dotTops(tester), isNot(first));
    });

    testWidgets('it never settles, by design', (tester) async {
      await pumpIndicator(tester);
      await expectLater(
        () => tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 2),
        ),
        throwsA(isA<FlutterError>()),
      );
    });

    // The indicator is removed the moment the message arrives, which happens while its
    // controller is mid-cycle; a controller left running there is a leak reported
    // against whichever test disposes the tree next.
    testWidgets('leaving the conversation disposes the controller cleanly',
        (tester) async {
      await pumpIndicator(tester);
      await pumpApp(tester, const Scaffold(body: SizedBox.shrink()));
      expect(find.byType(CircleAvatar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
