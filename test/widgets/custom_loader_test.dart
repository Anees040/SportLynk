// CustomLoader: the branded spinner, and the one fact about it that every screen
// test downstream has to know.
//
// The controller is started with `repeat()` and never stops, which is correct for a
// loader and is also the reason `pumpAndSettle` cannot be used anywhere this widget
// is on screen: settling waits for the frame scheduler to go idle, and an animation
// that repeats forever never lets it. That is asserted below as a contract rather
// than discovered later as a ten-minute timeout in a screen test.
//
// The three layers are sized as fractions of one `size` argument — ring at 1.0,
// spinner at 0.7, dot at 0.25 — so a caller that shrinks the loader to fit inside a
// card gets a proportional loader rather than a clipped one. Both the default and a
// shrunk instance are measured for that reason.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/custom_loader.dart';

import 'widget_harness.dart';

/// The outer pulsing ring: the first `Container` in the stack.
final Finder _ring = find.byType(Container).first;

/// The solid centre dot: the last `Container` in the stack.
final Finder _dot = find.byType(Container).last;

double _borderWidth(WidgetTester tester) =>
    ((tester.widget<Container>(_ring).decoration! as BoxDecoration).border!.top).width;

void main() {
  group('the three layers', () {
    testWidgets('the default loader measures 48 across all three', (tester) async {
      await pumpApp(tester, const Scaffold(body: CustomLoader()));
      expect(sizeOf(tester, _ring), const Size(48, 48));
      expect(sizeOf(tester, find.byType(CircularProgressIndicator)).width, closeTo(33.6, 0.01));
      expect(sizeOf(tester, _dot), const Size(12, 12));
    });

    testWidgets('a shrunk loader scales every layer with it', (tester) async {
      await pumpApp(tester, const Scaffold(body: CustomLoader(size: 34)));
      expect(sizeOf(tester, _ring), const Size(34, 34));
      expect(sizeOf(tester, find.byType(CircularProgressIndicator)).width, closeTo(23.8, 0.01));
      expect(sizeOf(tester, _dot).width, closeTo(8.5, 0.01));
    });

    testWidgets('the colour defaults to the accent and is overridable', (tester) async {
      await pumpApp(tester, const Scaffold(body: CustomLoader()));
      expect((tester.widget<Container>(_dot).decoration! as BoxDecoration).color,
          AppColors.accent);

      await pumpApp(tester, const Scaffold(body: CustomLoader(color: AppColors.error)));
      expect((tester.widget<Container>(_dot).decoration! as BoxDecoration).color,
          AppColors.error);
    });
  });

  // The ring's border thins as the cycle advances (`3 * (1 - value)`), which makes
  // it the readable proof that the controller is actually running rather than
  // sitting at its initial value.
  group('the animation', () {
    testWidgets('the ring thins as the cycle advances', (tester) async {
      await pumpApp(tester, const Scaffold(body: CustomLoader()));
      expect(_borderWidth(tester), 3.0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_borderWidth(tester), closeTo(1.5, 0.01));
    });

    testWidgets('the cycle restarts rather than stopping at the end', (tester) async {
      await pumpApp(tester, const Scaffold(body: CustomLoader()));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(_borderWidth(tester), 3.0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_borderWidth(tester), closeTo(1.5, 0.01));
    });

    // Pinned deliberately: a screen showing this loader can never be settled, so a
    // test for such a screen has to pump a fixed duration instead.
    testWidgets('it never settles, by design', (tester) async {
      await pumpApp(tester, const Scaffold(body: CustomLoader()));
      await expectLater(
        () => tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 2),
        ),
        throwsA(isA<FlutterError>()),
      );
    });

    // A ticker left running past the widget's life is reported by the test binding
    // as a leak, so a clean removal is what proves `dispose` cancelled it.
    testWidgets('removing the loader disposes its controller', (tester) async {
      await pumpApp(tester, const Scaffold(body: CustomLoader()));
      await tester.pump(const Duration(milliseconds: 300));
      await pumpApp(tester, const Scaffold(body: SizedBox.shrink()));
      expect(find.byType(CustomLoader), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
