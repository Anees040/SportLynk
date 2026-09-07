// ChatComposer: the message bar, and the two behaviours that make chat feel right.
//
// The send button is a state, not a decoration. It is grey and inert until there is
// something to send, which is why an empty tap must be unreachable rather than merely
// ignored: a live-looking button that does nothing reads as a failed send. Whitespace
// counts as nothing, and the text that leaves is the trimmed text — a message padded
// with the spaces a phone keyboard inserts is still that message.
//
// Typing is announced on the first keystroke and withdrawn after a short lull, so the
// other side sees "typing…" appear and fade without a socket frame per character. Both
// halves are asserted: several keystrokes produce exactly one true, and the 1800 ms
// timer produces exactly one false. Clearing the field and sending both withdraw it
// immediately, because a composer that went quiet with "typing…" still showing on the
// other phone is the failure this timer exists to prevent.
//
// That timer is created by the widget, so each test that leaves one running advances the
// clock past it inside its own body; a timer still pending when the tree is disposed is
// reported as a leak against whichever test runs next.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/chat/chat_composer.dart';

import '../widget_harness.dart';

void main() {
  late TextEditingController controller;
  late List<String> sent;
  late List<bool> typing;
  late int photos;

  setUp(() {
    controller = TextEditingController();
    sent = <String>[];
    typing = <bool>[];
    photos = 0;
  });

  tearDown(() => controller.dispose());

  Future<void> pumpComposer(WidgetTester tester,
          {bool enabled = true, double textScale = 1.0}) =>
      pumpApp(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              controller: controller,
              enabled: enabled,
              onSend: sent.add,
              onPickImage: () => photos++,
              onTyping: typing.add,
            ),
          ),
        ),
        textScale: textScale,
      );

  double scale(WidgetTester tester) =>
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

  Color? sendColor(WidgetTester tester) => tester
      .widget<Material>(find
          .ancestor(of: find.byIcon(Icons.send_rounded), matching: find.byType(Material))
          .first)
      .color;

  /// Advances past the typing timer so nothing is left pending at teardown.
  Future<void> settleTyping(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 2));

  group('the send button', () {
    testWidgets('an empty composer offers nothing to press', (tester) async {
      await pumpComposer(tester);
      expect(sendColor(tester), AppColors.disabled);
      expect(scale(tester), 0.9);
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('a space is not a message', (tester) async {
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), '    ');
      await tester.pump();
      expect(sendColor(tester), AppColors.disabled);
      expect(typing, isEmpty, reason: 'nothing was typed as far as the room is aware');
    });

    testWidgets('text arms the button', (tester) async {
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'On my way');
      await tester.pump();
      expect(sendColor(tester), AppColors.accent);
      expect(scale(tester), 1);
      await settleTyping(tester);
    });

    testWidgets('the message that leaves is trimmed, and the field is cleared',
        (tester) async {
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), '  See you at 7  ');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(sent, ['See you at 7']);
      expect(controller.text, isEmpty);
      expect(sendColor(tester), AppColors.disabled, reason: 'back to nothing to send');
    });
  });

  group('announcing that someone is typing', () {
    // One frame per character would be a socket frame per character.
    testWidgets('a burst of keystrokes is announced once', (tester) async {
      await pumpComposer(tester);
      for (final text in ['O', 'On', 'On ', 'On m', 'On my way']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
      }
      expect(typing, [true]);
      await settleTyping(tester);
    });

    testWidgets('a lull withdraws it, and only once', (tester) async {
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'On my way');
      await tester.pump(const Duration(milliseconds: 1700));
      expect(typing, [true], reason: 'still within the lull');

      await tester.pump(const Duration(milliseconds: 200));
      expect(typing, [true, false]);

      await tester.pump(const Duration(seconds: 3));
      expect(typing, [true, false], reason: 'the timer does not repeat');
    });

    testWidgets('each keystroke pushes the lull back', (tester) async {
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'On');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.enterText(find.byType(TextField), 'On my');
      await tester.pump(const Duration(milliseconds: 1500));
      expect(typing, [true], reason: 'the second keystroke restarted the timer');
      await settleTyping(tester);
    });

    // Deleting the draft is a decision, not a pause: the other side stops seeing
    // "typing…" at once rather than 1.8 seconds later.
    testWidgets('clearing the draft withdraws it immediately', (tester) async {
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'On my way');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(typing, [true, false]);
    });

    testWidgets('sending withdraws it in the same breath', (tester) async {
      await pumpComposer(tester);
      await tester.enterText(find.byType(TextField), 'On my way');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(sent, ['On my way']);
      expect(typing, [true, false]);
    });
  });

  group('the photo button and the disabled bar', () {
    testWidgets('the photo button is labelled and reports its tap', (tester) async {
      await pumpComposer(tester);
      expect(find.byTooltip('Send a photo'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.image_outlined));
      await tester.pump();
      expect(photos, 1);
    });

    // A closed conversation: the bar stays visible so the history reads normally, but
    // nothing in it can be used.
    testWidgets('a disabled bar accepts neither a photo nor a message', (tester) async {
      controller.text = 'On my way';
      await pumpComposer(tester, enabled: false);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.image_outlined))
              .onPressed,
          isNull);

      await tester.tap(find.byIcon(Icons.send_rounded), warnIfMissed: false);
      await tester.pump();
      expect(sent, isEmpty);
      expect(photos, 0);
    });
  });

  group('the field itself', () {
    testWidgets('it grows to five lines and no further', (tester) async {
      await pumpComposer(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.minLines, 1);
      expect(field.maxLines, 5);
      expect(field.keyboardType, TextInputType.multiline);
      expect(field.textCapitalization, TextCapitalization.sentences);
      expect(find.text('Message'), findsOneWidget);
    });

    testWidgets('the bar survives a doubled text scale', (tester) async {
      await pumpComposer(tester, textScale: 2.0);
      await tester.enterText(find.byType(TextField), 'On my way to the ground now');
      await tester.pump();
      expectNoOverflow(tester);
      await settleTyping(tester);
    });
  });
}
