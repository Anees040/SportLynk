// ScoutTyping: the wait, and the two things it admits as it gets longer.
//
// Three dots are enough for a normal answer, but [ApiClient] allows 45 seconds for a
// cold call and the first request after a lull can genuinely take most of it. Forty
// seconds of silent animation reads as a hang, so the caption escalates on its own
// clock: nothing at all, then "Thinking…", then a sentence that says why it is slow.
// The escalation is the contract, and each step is asserted at its boundary.
//
// The caption never claims to know what Scout is doing — only how long it has been
// doing it. That is why the third state names the cold start rather than inventing a
// stage ("searching venues", "reading your bookings") that no code here can know.
//
// Both timers belong to the widget and both must die with it: an answer that arrives in
// two seconds unmounts this widget while a three-second timer is still pending, and a
// timer that outlives its tree is reported as a leak. The unmount case is asserted
// directly. The controller repeats forever, so, as with `CustomLoader`, nothing here may
// be settled.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/assistant/scout_bits.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';
import 'package:sportlynk/widgets/assistant/scout_typing.dart';

import '../widget_harness.dart';

const String _coldStart =
    'Still working — the first request after a quiet spell takes longer.';

/// The live-region sentence a screen reader announces on the frame drawn.
String announced(WidgetTester tester) =>
    tester.getSemantics(find.byType(ScoutTyping)).label;

void main() {
  Future<void> pumpTyping(WidgetTester tester, {double textScale = 1.0}) => pumpApp(
        tester,
        const ColoredBox(
          color: ScoutTheme.canvas,
          child: Align(alignment: Alignment.topLeft, child: ScoutTyping()),
        ),
        textScale: textScale,
      );

  /// Unmounts the widget so its two timers are cancelled inside the test body.
  Future<void> close(WidgetTester tester) =>
      pumpApp(tester, const ColoredBox(color: ScoutTheme.canvas));

  group('what is drawn while waiting', () {
    testWidgets('three dots beside a thinking avatar, and no caption yet',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTyping(tester);
      expect(find.byType(ScoutAvatar), findsOneWidget);
      expect(tester.widget<ScoutAvatar>(find.byType(ScoutAvatar)).thinking, isTrue);
      expect(find.byType(Text), findsNothing, reason: 'silence for the first seconds');
      expect(announced(tester), 'Scout is typing');
      handle.dispose();
      await close(tester);
    });

    testWidgets('the dots are staggered and keep moving', (tester) async {
      await pumpTyping(tester);
      List<double> tops() => List<double>.generate(
          3,
          (i) => tester
              .getTopLeft(find
                  .byWidgetPredicate((w) =>
                      w is Container &&
                      w.constraints ==
                          const BoxConstraints.tightFor(width: 6.5, height: 6.5))
                  .at(i))
              .dy);
      final first = tops();
      expect(first.toSet().length, 3, reason: 'each dot is at its own point');
      await tester.pump(const Duration(milliseconds: 300));
      expect(tops(), isNot(first));
      await close(tester);
    });

    testWidgets('it never settles, by design', (tester) async {
      await pumpTyping(tester);
      await expectLater(
        () => tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 2),
        ),
        throwsA(isA<FlutterError>()),
      );
      await close(tester);
    });
  });

  group('the escalating caption', () {
    testWidgets('nothing is said for the first three seconds', (tester) async {
      await pumpTyping(tester);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.text('Thinking…'), findsNothing);
      await close(tester);
    });

    testWidgets('at three seconds it admits to thinking', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTyping(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Thinking…'), findsOneWidget);
      expect(announced(tester), contains('Thinking…'));
      handle.dispose();
      await close(tester);
    });

    // The cold-start sentence, not an invented stage: this widget knows the elapsed
    // time and nothing else.
    testWidgets('at nine seconds it explains why it is slow', (tester) async {
      await pumpTyping(tester);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text(_coldStart), findsOneWidget);
      expect(find.text('Thinking…'), findsNothing, reason: 'it replaces, not appends');
      await close(tester);
    });

    testWidgets('the caption does not escalate a third time', (tester) async {
      await pumpTyping(tester);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump(const Duration(seconds: 30));
      expect(find.text(_coldStart), findsOneWidget);
      await close(tester);
    });

    testWidgets('the caption fits beside the dots at a doubled text scale',
        (tester) async {
      await pumpTyping(tester, textScale: 2.0);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text(_coldStart), findsOneWidget);
      expectNoOverflow(tester);
      await close(tester);
    });
  });

  // An answer that arrives in two seconds unmounts this while both timers are pending.
  group('when the answer arrives first', () {
    testWidgets('unmounting cancels both timers', (tester) async {
      await pumpTyping(tester);
      await tester.pump(const Duration(seconds: 2));
      await close(tester);
      await tester.pump(const Duration(seconds: 20));
      expect(find.byType(ScoutTyping), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
