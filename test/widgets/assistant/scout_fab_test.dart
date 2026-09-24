// ScoutFab and ScoutAskBanner: the two ways into Scout, and what each one says when
// the animation is taken away.
//
// Scout is a floating button rather than a sixth tab, so in its collapsed form the
// only thing on screen is the mascot tile. That makes the semantics label the
// entire accessible name of the app's newest capability, and it is asserted on both
// forms rather than left to the art to imply.
//
// The halo breathes on a 2.4s cycle and is decoration only. Two frames are compared
// to prove the shadow moves, and the mascot, the face and the accessible name are
// then checked to be identical on both — a button that only reads as one
// mid-animation would be unusable with animations disabled.
//
// Both forms are the same tap. Each is pinned to the radius it draws: the collapsed
// face is the mascot's own squircle and the extended form a labelled pill. The
// controller repeats forever, so, as with `CustomLoader`, `pumpAndSettle` can never
// be used on a tree containing the FAB.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/assistant/scout_fab.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../widget_harness.dart';

/// Every [BoxDecoration] under [root], outermost first: for the FAB that is the halo
/// and then the face, and for the banner the card and then the icon tile.
List<BoxDecoration> decorations(WidgetTester tester, Finder root) => tester
    .widgetList<Container>(
        find.descendant(of: root, matching: find.byType(Container)))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .toList();

void main() {
  group('the floating button', () {
    Future<int> pumpFab(WidgetTester tester,
        {bool extended = false, double textScale = 1.0}) async {
      var taps = 0;
      await pumpApp(
        tester,
        ColoredBox(
          color: ScoutTheme.light.canvas,
          child: Center(
            child: ScoutFab(extended: extended, onTap: () => taps++),
          ),
        ),
        textScale: textScale,
      );
      return taps;
    }

    testWidgets('collapsed it is a mascot squircle, not a circle', (tester) async {
      await pumpFab(tester);
      // The face is the mascot art now, not a sparkle glyph.
      expect(
          find.descendant(
              of: find.byType(ScoutFab), matching: find.byType(Image)),
          findsOneWidget);
      expect(find.text('Ask Scout'), findsNothing, reason: 'the label is the tooltip');

      final face = decorations(tester, find.byType(ScoutFab))[1];
      // A rounded rect at the mascot's own radius rather than a circle: the face is
      // the art's launcher-style tile, and its fill is the one green that holds art.
      expect(face.borderRadius, BorderRadius.circular(18));
      expect(face.color, ScoutTheme.accentFill);
      expect(face.gradient, isNull, reason: 'the tile is a flat fill behind the art');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('extended it is a pill that names itself', (tester) async {
      await pumpFab(tester, extended: true);
      expect(find.text('Ask Scout'), findsOneWidget);
      // The mascot rides the pill in place of the old sparkle glyph.
      expect(
          find.descendant(
              of: find.byType(ScoutFab), matching: find.byType(Image)),
          findsOneWidget);
      final decos = decorations(tester, find.byType(ScoutFab));
      // Halo and pill share the pill radius; the inset mascot tile draws its own,
      // tighter one, so the two outer shapes are checked rather than the whole list.
      expect(decos.first.borderRadius, BorderRadius.circular(18),
          reason: 'the halo follows the pill');
      expect(decos[1].gradient, ScoutTheme.accentGradient,
          reason: 'the pill keeps the brand gradient behind the label');
      expect(decos[1].borderRadius, BorderRadius.circular(18));
      expectTapTarget(tester, find.byType(ScoutFab));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // The collapsed form is the mascot and nothing else, so this sentence is the
    // whole accessible name of the feature.
    testWidgets('a screen reader is told what the tile opens', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpFab(tester);
      // The mascot is the leaf; the enclosing node carries the button semantics.
      expect(
          tester.getSemantics(find.descendant(
              of: find.byType(ScoutFab), matching: find.byType(Image))),
          matchesSemantics(
            label: 'Ask Scout, the SportLynk assistant',
            isButton: true,
            hasTapAction: true,
            isFocusable: true,
            hasFocusAction: true,
          ));
      handle.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('both shapes report the tap', (tester) async {
      var taps = 0;
      for (final extended in [false, true]) {
        await pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.light.canvas,
            child: Center(
              child: ScoutFab(extended: extended, onTap: () => taps++),
            ),
          ),
        );
        await tester.tap(find.byType(ScoutFab));
      }
      expect(taps, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // The halo is the one part that moves, and nothing may depend on it.
  group('the breathing halo', () {
    Future<void> pumpFab(WidgetTester tester) => pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.light.canvas,
            child: Center(child: ScoutFab(onTap: () {})),
          ),
        );

    BoxShadow halo(WidgetTester tester) =>
        decorations(tester, find.byType(ScoutFab)).first.boxShadow!.single;

    testWidgets('the glow grows and fades while the button does not',
        (tester) async {
      await pumpFab(tester);
      final first = halo(tester);
      final face = decorations(tester, find.byType(ScoutFab))[1];
      expect(first.blurRadius, 14, reason: 'the cycle starts at its quietest');
      expect(first.spreadRadius, 1);
      expect(first.color.a, closeTo(0.20, 0.001));

      await tester.pump(const Duration(milliseconds: 600));
      final later = halo(tester);
      expect(later.blurRadius, greaterThan(first.blurRadius));
      expect(later.color.a, greaterThan(first.color.a));

      // Decoration only: the same mascot, the same face, the same footprint.
      expect(
          find.descendant(
              of: find.byType(ScoutFab), matching: find.byType(Image)),
          findsOneWidget);
      expect(decorations(tester, find.byType(ScoutFab))[1].color, face.color);
      expect(decorations(tester, find.byType(ScoutFab))[1].borderRadius,
          face.borderRadius);
      // The collapsed face is a 56px mascot tile — comfortably over the project's
      // 48px floor. The halo is a shadow, so it adds no layout size of its own.
      expect(tester.getSize(find.byType(ScoutFab)), const Size(56, 56));
      expectTapTarget(tester, find.byType(ScoutFab));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('it never settles, by design', (tester) async {
      await pumpFab(tester);
      await expectLater(
        () => tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 2),
        ),
        throwsA(isA<FlutterError>()),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // The FAB is removed on every navigation away from the player shell, always
    // mid-cycle; a controller left running there is reported against the next test.
    testWidgets('leaving the screen disposes the controller cleanly', (tester) async {
      await pumpFab(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(find.byType(ScoutFab), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // The banner is the same tap on the Home tab, a light accent-washed card so a new
  // capability is not invisible among the four white tiles that were already there.
  // It no longer previews a dark surface: Scout follows the system brightness now.
  group('the Home banner', () {
    Future<int> pumpBanner(WidgetTester tester, {double textScale = 1.0}) async {
      var taps = 0;
      await pumpApp(
        tester,
        ColoredBox(
          color: Colors.white,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 340,
              child: ScoutAskBanner(onTap: () => taps++),
            ),
          ),
        ),
        textScale: textScale,
      );
      return taps;
    }

    testWidgets('it is a light accent-washed card, not a dark preview',
        (tester) async {
      await pumpBanner(tester);
      final card = decorations(tester, find.byType(ScoutAskBanner)).first;
      expect(card.gradient, isNull);
      expect(card.color, ScoutTheme.accentFill.withValues(alpha: 0.06));
      expect(card.borderRadius, BorderRadius.circular(18));
      expect(card.border,
          Border.all(color: ScoutTheme.light.accent.withValues(alpha: 0.30)));
    });

    testWidgets('it says what Scout is for rather than only naming it',
        (tester) async {
      await pumpBanner(tester);
      expect(find.text('Ask Scout'), findsOneWidget);
      expect(
          find.text('Book a ground, find players, check your wallet — just say it.'),
          findsOneWidget);
      // The mascot tile stands in for the old sparkle glyph on the banner too.
      final mascot = find.descendant(
          of: find.byType(ScoutAskBanner), matching: find.byType(Image));
      expect(mascot, findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget,
          reason: 'the arrow is what marks it as a way out of Home');
      expect(
          tester.getSize(find.ancestor(
              of: mascot, matching: find.byType(Container)).first),
          const Size(46, 46),
          reason: 'the mascot sits in a tile, not loose beside the text');
    });

    testWidgets('the whole card is the target, not the arrow', (tester) async {
      var taps = 0;
      await pumpApp(
        tester,
        ColoredBox(
          color: Colors.white,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 340,
              child: ScoutAskBanner(onTap: () => taps++),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ask Scout'));
      await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
      expect(taps, 2);
      expectTapTarget(tester, find.byType(ScoutAskBanner));
    });

    // The subtitle is a full sentence in an `Expanded`, which is the arrangement that
    // has to hold when the sentence needs three lines instead of one.
    testWidgets('the sentence wraps at a doubled text scale', (tester) async {
      await pumpBanner(tester, textScale: 2.0);
      expect(
          find.text('Book a ground, find players, check your wallet — just say it.'),
          findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
