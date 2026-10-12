// PasswordStrengthBar: the five checks behind the word the user reads, and the
// character set that decides whether a symbol counts.
//
// The label is the only feedback the sign-up screen gives about password quality, so
// the mapping from score to word is asserted at every boundary: a bar that says
// "Good" for a password the server will reject, or "Weak" for a strong one, trains
// the user to ignore it. The bar's width is the same score as a fraction of the
// available width, which is why it is measured inside a parent of a known size.
//
// Only five checks are shown, and all five are what the forms actually enforce (min
// 8 + character variety). A sixth "12+ chars" chip used to sit here, but nothing
// enforces 12, so it only ever read as an unmet requirement on an accepted password;
// it was removed and these tests pin the five-check behaviour that replaced it.
//
// The symbol check is worth reading closely. Its set is
// `[!@#$%^&*(),.?":{}|<>]`, which omits the hyphen, the underscore, the plus and the
// equals sign among others — so `Str0ng-Pass` scores no symbol point while
// `Str0ng.Pass` does. Both are pinned below: the behaviour is a deliberate set, not
// a general "contains punctuation" test, and a screen that promises otherwise in its
// helper text would be lying.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/password_strength_bar.dart';

import 'widget_harness.dart';

/// The bar itself: the first `AnimatedContainer`, before any chip.
final Finder _bar = find.byType(AnimatedContainer).first;

Widget _framed(String password) => Scaffold(
      body: Center(
        child: SizedBox(width: 300, child: PasswordStrengthBar(password: password)),
      ),
    );

Color? _barColour(WidgetTester tester) =>
    (tester.widget<AnimatedContainer>(_bar).decoration! as BoxDecoration).color;

void main() {
  group('an empty field', () {
    testWidgets('draws nothing but a zero-width bar', (tester) async {
      await pumpApp(tester, _framed(''));
      expect(sizeOf(tester, _bar), const Size(0, 4));
      expect(find.text('Weak'), findsNothing);
      expect(find.text('8+ chars'), findsNothing);
      expect(find.byType(AnimatedContainer), findsOneWidget);
    });
  });

  // Every boundary of `_getLevel`: five checks map ≤1 Weak, 2 Fair, 3–4 Good, 5 Strong.
  group('the word the user reads', () {
    testWidgets('one satisfied check is Weak', (tester) async {
      await pumpApp(tester, _framed('a'));
      expect(find.text('Weak'), findsOneWidget);
      expect(_barColour(tester), AppColors.error);
    });

    testWidgets('two satisfied checks are Fair', (tester) async {
      await pumpApp(tester, _framed('abcdefgh'));
      expect(find.text('Fair'), findsOneWidget);
      expect(_barColour(tester), AppColors.warning);
    });

    testWidgets('three and four satisfied checks are Good', (tester) async {
      await pumpApp(tester, _framed('Abcdefgh'));
      expect(find.text('Good'), findsOneWidget);
      await pumpApp(tester, _framed('Abcdefg1'));
      expect(find.text('Good'), findsOneWidget);
      expect(_barColour(tester), AppColors.accent);
    });

    testWidgets('all five is Strong', (tester) async {
      await pumpApp(tester, _framed('Abcdefg1!'));
      expect(find.text('Strong'), findsOneWidget);
      expect(_barColour(tester), AppColors.success);
    });
  });

  group('the five chips', () {
    testWidgets('all five are listed once the field is not empty', (tester) async {
      await pumpApp(tester, _framed('a'));
      for (final label in const ['8+ chars', 'A-Z', 'a-z', '0-9', '!@#']) {
        expect(find.text(label), findsOneWidget, reason: 'missing the $label chip');
      }
    });

    testWidgets('a met check is ticked and an unmet one is not', (tester) async {
      await pumpApp(tester, _framed('abcdefgh'));
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byIcon(Icons.circle_outlined), findsNWidgets(3));
    });

    // The set is explicit, not "any punctuation": a hyphen earns nothing.
    testWidgets('a hyphen is not a symbol while a full stop is', (tester) async {
      await pumpApp(tester, _framed('Abcdefg1-'));
      expect(find.byIcon(Icons.check_circle), findsNWidgets(4));
      await pumpApp(tester, _framed('Abcdefg1.'));
      expect(find.byIcon(Icons.check_circle), findsNWidgets(5));
    });

    testWidgets('the fifth class, a symbol, separates Good from Strong', (tester) async {
      await pumpApp(tester, _framed('Abcdefg1'));
      expect(find.text('Good'), findsOneWidget);
      await pumpApp(tester, _framed('Abcdefg1!'));
      expect(find.text('Strong'), findsOneWidget);
    });
  });

  group('the bar', () {
    testWidgets('its width is the score as a fraction of the field', (tester) async {
      await pumpApp(tester, _framed('Abcdefgh'));
      expect(sizeOf(tester, _bar).width, closeTo(180, 0.01));
    });

    // The width is animated, so the honest reading is the one after the transition
    // has run; a screen that measured it on the first frame would read the old score.
    testWidgets('a stronger password grows the bar over its transition', (tester) async {
      await pumpApp(tester, _framed('a'));
      expect(sizeOf(tester, _bar).width, closeTo(60, 0.01));
      await pumpApp(tester, _framed('Abcdefg1!'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(sizeOf(tester, _bar).width, closeTo(300, 0.01));
    });

    testWidgets('the chips wrap rather than overflow at a large font', (tester) async {
      await pumpApp(tester, _framed('Abcdefg1!'), textScale: 2.0);
      expectNoOverflow(tester);
      expect(find.text('!@#'), findsOneWidget);
    });
  });
}
