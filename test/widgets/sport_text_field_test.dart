// SportTextField: the app's single text input, and the five arguments that change
// what it will accept.
//
// Every form in the product is built out of this widget, so the assertions below are
// about the states a form depends on rather than about its appearance: that the
// validator's sentence replaces the helper text rather than appearing beside it, that
// a read-only field still reports a tap (which is how the date and time pickers are
// opened), and that a disabled field reports nothing at all.
//
// The formatter argument is pinned because it is the only place where a keystroke is
// silently dropped. A field declared digits-only must reject letters at the input
// layer rather than in a validator, or the user sees their own typing appear and then
// be rejected on submit.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/sport_text_field.dart';

import 'widget_harness.dart';

Widget _framed(Widget field) =>
    Scaffold(body: Center(child: SizedBox(width: 320, child: field)));

void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  group('what is drawn', () {
    testWidgets('the hint and the prefix icon are always present', (tester) async {
      await pumpApp(
          tester,
          _framed(SportTextField(
              hint: 'Venue name', prefixIcon: Icons.place, controller: controller)));
      expect(find.text('Venue name'), findsOneWidget);
      expect(find.byIcon(Icons.place), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.place)).size, 20);
    });

    testWidgets('the label appears above the field only when given', (tester) async {
      await pumpApp(
          tester,
          _framed(SportTextField(
              label: 'Venue',
              hint: 'Venue name',
              prefixIcon: Icons.place,
              controller: controller)));
      expect(find.text('Venue'), findsOneWidget);

      await pumpApp(
          tester,
          _framed(SportTextField(
              hint: 'Venue name', prefixIcon: Icons.place, controller: controller)));
      expect(find.text('Venue'), findsNothing);
    });

    testWidgets('a helper line and a suffix widget both reach the field', (tester) async {
      await pumpApp(
          tester,
          _framed(SportTextField(
            hint: 'Price',
            prefixIcon: Icons.payments,
            controller: controller,
            helperText: 'Per hour, in rupees',
            suffix: const Icon(Icons.visibility),
          )));
      expect(find.text('Per hour, in rupees'), findsOneWidget);
      expect(find.byIcon(Icons.visibility), findsOneWidget);
    });

    testWidgets('an obscured field hides what is typed', (tester) async {
      await pumpApp(
          tester,
          _framed(SportTextField(
              hint: 'Password',
              prefixIcon: Icons.lock,
              controller: controller,
              obscure: true)));
      expect(tester.widget<EditableText>(find.byType(EditableText)).obscureText, isTrue);
    });
  });

  group('what it accepts', () {
    testWidgets('typing reaches the controller', (tester) async {
      await pumpApp(
          tester,
          _framed(SportTextField(
              hint: 'Venue name', prefixIcon: Icons.place, controller: controller)));
      await tester.enterText(find.byType(TextField), 'Arena One');
      expect(controller.text, 'Arena One');
    });

    // The formatter is the input layer, not a validator: letters must never appear.
    testWidgets('a digits-only field drops the letters as they arrive', (tester) async {
      await pumpApp(
          tester,
          _framed(SportTextField(
            hint: 'Price',
            prefixIcon: Icons.payments,
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          )));
      await tester.enterText(find.byType(TextField), 'ab2500x');
      expect(controller.text, '2500');
    });

    testWidgets('the keyboard type and line count are forwarded', (tester) async {
      await pumpApp(
          tester,
          _framed(SportTextField(
            hint: 'Notes',
            prefixIcon: Icons.notes,
            controller: controller,
            keyboardType: TextInputType.multiline,
            maxLines: 3,
          )));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.keyboardType, TextInputType.multiline);
      expect(field.maxLines, 3);
    });
  });

  // Read-only and disabled look similar and behave differently: one is a picker, the
  // other is a field that is not the user's to touch.
  group('read-only and disabled', () {
    testWidgets('a read-only field reports the tap that opens a picker', (tester) async {
      var taps = 0;
      await pumpApp(
          tester,
          _framed(SportTextField(
            hint: 'Pick a date',
            prefixIcon: Icons.event,
            controller: controller,
            readOnly: true,
            onTap: () => taps++,
          )));
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      await tester.tap(find.byType(TextField));
      expect(taps, 1);
    });

    testWidgets('a disabled field reports nothing', (tester) async {
      var taps = 0;
      await pumpApp(
          tester,
          _framed(SportTextField(
            hint: 'Pick a date',
            prefixIcon: Icons.event,
            controller: controller,
            enabled: false,
            onTap: () => taps++,
          )));
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await tester.tap(find.byType(TextField), warnIfMissed: false);
      expect(taps, 0);
    });
  });

  group('validation', () {
    testWidgets('the error replaces the helper line rather than joining it', (tester) async {
      final key = GlobalKey<FormState>();
      await pumpApp(
          tester,
          _framed(Form(
            key: key,
            child: SportTextField(
              hint: 'Venue name',
              prefixIcon: Icons.place,
              controller: controller,
              helperText: 'As players will see it',
              validator: (v) => (v == null || v.isEmpty) ? 'A name is required' : null,
            ),
          )));
      expect(find.text('As players will see it'), findsOneWidget);

      key.currentState!.validate();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('A name is required'), findsOneWidget);
      expect(find.text('As players will see it'), findsNothing);
    });

    testWidgets('a filled field validates clean', (tester) async {
      final key = GlobalKey<FormState>();
      await pumpApp(
          tester,
          _framed(Form(
            key: key,
            child: SportTextField(
              hint: 'Venue name',
              prefixIcon: Icons.place,
              controller: controller,
              validator: (v) => (v == null || v.isEmpty) ? 'A name is required' : null,
            ),
          )));
      await tester.enterText(find.byType(TextField), 'Arena One');
      expect(key.currentState!.validate(), isTrue);
      await tester.pump();
      expect(find.text('A name is required'), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('a label, a helper and an error all fit at a large font', (tester) async {
      final key = GlobalKey<FormState>();
      await pumpApp(
          tester,
          _framed(Form(
            key: key,
            child: SportTextField(
              label: 'Venue',
              hint: 'Venue name',
              prefixIcon: Icons.place,
              controller: controller,
              helperText: 'As players will see it',
              validator: (v) => 'A name is required',
            ),
          )),
          textScale: 2.0);
      key.currentState!.validate();
      await tester.pump();
      expectNoOverflow(tester);
      expect(find.text('A name is required'), findsOneWidget);
    });
  });
}
