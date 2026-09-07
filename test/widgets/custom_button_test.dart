// CustomButton: the loading state, which is the only behaviour in this widget, and
// the two variants it has to look right in.
//
// The button is the app's single primary action, so the one failure that matters is
// a double submission: a player who taps Book twice while the first request is in
// flight creates two bookings against one slot. `isLoading` is what prevents that,
// and it prevents it by passing a null `onPressed` rather than by drawing something
// over the top — so the assertions below tap a loading button and require that the
// callback did not fire, not merely that a spinner appeared.
//
// The fixed `height: 52` is asserted in both variants because it is what keeps the
// button above the project's 48-pixel tap-target floor at every text scale; the
// label is inside that box, so a larger system font makes the text grow while the
// target stays the same size rather than the reverse.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/custom_button.dart';

import 'widget_harness.dart';

/// The button at a realistic width, since `double.infinity` only means something
/// inside a bounded parent.
Widget _framed(Widget button) =>
    Scaffold(body: Center(child: SizedBox(width: 300, child: button)));

void main() {
  group('a button that can be pressed', () {
    testWidgets('the label is drawn and a tap reaches the callback', (tester) async {
      var taps = 0;
      await pumpApp(tester, _framed(CustomButton(text: 'Book now', onPressed: () => taps++)));
      expect(find.text('Book now'), findsOneWidget);
      await tester.tap(find.byType(ElevatedButton));
      expect(taps, 1);
    });

    testWidgets('an absent callback leaves the button disabled', (tester) async {
      await pumpApp(tester, _framed(const CustomButton(text: 'Book now')));
      expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed, isNull);
    });

    testWidgets('an icon is drawn beside the label, and omitted when absent', (tester) async {
      await pumpApp(tester,
          _framed(const CustomButton(text: 'Add slot', icon: Icons.add, onPressed: null)));
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.add)).size, 20);

      await pumpApp(tester, _framed(const CustomButton(text: 'Add slot')));
      expect(find.byType(Icon), findsNothing);
    });
  });

  // The guard against a double submission. A spinner that appears while the tap
  // still fires would be worse than no spinner at all, because it looks handled.
  group('a button that is loading', () {
    testWidgets('the label is replaced by a spinner of a fixed size', (tester) async {
      await pumpApp(tester,
          _framed(CustomButton(text: 'Book now', isLoading: true, onPressed: () {})));
      expect(find.text('Book now'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(sizeOf(tester, find.byType(CircularProgressIndicator)), const Size(22, 22));
    });

    testWidgets('a tap while loading does not reach the callback', (tester) async {
      var taps = 0;
      await pumpApp(tester,
          _framed(CustomButton(text: 'Book now', isLoading: true, onPressed: () => taps++)));
      await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
      expect(taps, 0);
      expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed, isNull);
    });

    testWidgets('the outlined variant is disabled the same way', (tester) async {
      var taps = 0;
      await pumpApp(
          tester,
          _framed(CustomButton(
              text: 'Cancel', variant: 'outlined', isLoading: true, onPressed: () => taps++)));
      await tester.tap(find.byType(OutlinedButton), warnIfMissed: false);
      expect(taps, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('the two variants', () {
    testWidgets('filled is an elevated button and outlined is not', (tester) async {
      await pumpApp(tester, _framed(const CustomButton(text: 'Go')));
      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);

      await pumpApp(tester, _framed(const CustomButton(text: 'Go', variant: 'outlined')));
      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
    });

    // Any unrecognised variant is the filled one: a typo in a screen must produce
    // the app's primary button rather than an invisible one.
    testWidgets('an unknown variant falls back to filled', (tester) async {
      await pumpApp(tester, _framed(const CustomButton(text: 'Go', variant: 'ghost')));
      expect(find.byType(ElevatedButton), findsOneWidget);
    });

    testWidgets('the outline is the accent colour at two logical pixels', (tester) async {
      await pumpApp(tester, _framed(const CustomButton(text: 'Go', variant: 'outlined')));
      final side = tester
          .widget<OutlinedButton>(find.byType(OutlinedButton))
          .style!
          .side!
          .resolve(const <WidgetState>{})!;
      expect(side.color, AppColors.accent);
      expect(side.width, 2);
    });
  });

  group('the tap target', () {
    testWidgets('both variants fill their width at a 52-pixel height', (tester) async {
      await pumpApp(tester, _framed(const CustomButton(text: 'Go')));
      expect(sizeOf(tester, find.byType(ElevatedButton)), const Size(300, 52));

      await pumpApp(tester, _framed(const CustomButton(text: 'Go', variant: 'outlined')));
      expect(sizeOf(tester, find.byType(OutlinedButton)), const Size(300, 52));
    });

    // The floor the project sets, checked at the largest text scale a phone offers:
    // the box must not grow or shrink with the system font.
    testWidgets('the height holds above the 48-pixel floor at a large font', (tester) async {
      await pumpApp(tester, _framed(const CustomButton(text: 'Book now')),
          textScale: 2.0);
      expectTapTarget(tester, find.byType(ElevatedButton));
      expect(sizeOf(tester, find.byType(ElevatedButton)).height, 52);
    });
  });
}
