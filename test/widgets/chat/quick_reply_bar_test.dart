// QuickReplyBar: the suggested-reply row above the composer, and the badge it has to
// earn.
//
// The row is advisory by construction. A tap calls `onPick`, which fills the composer
// and nothing else; the send still goes through the ordinary message path. That is what
// makes a mis-tap a word in a text field rather than a message the other side has
// already read, so the tests below assert a pick reports the whole reply — its intent
// included — and that no other callback fires with it.
//
// The sparkle and the word "AI" are the part worth guarding. They appear only when the
// released classifier actually answered; when ml-service is unreachable the same three
// sentences arrive from a keyword table and the row must say "Suggested replies" with no
// sparkle. Both labels are pinned, because claiming a model that did not run is the one
// thing this project does not do.
//
// An absent or empty set collapses to nothing rather than drawing an empty bar: the row
// sits directly above the composer, and a blank strip there reads as a broken keyboard.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/chat_channel.dart';
import 'package:sportlynk/widgets/chat/quick_reply_bar.dart';

import '../widget_harness.dart';

QuickReplySet _set({String source = 'model', List<QuickReply>? suggestions}) =>
    QuickReplySet(
      source: source,
      intent: 'booking_reschedule',
      confidence: 0.91,
      suggestions: suggestions ??
          const [
            QuickReply(text: 'Yes, 7pm works', intent: 'confirm'),
            QuickReply(text: 'Can we make it 8?', intent: 'counter'),
            QuickReply(text: 'I will confirm tonight', intent: 'defer'),
          ],
    );

void main() {
  late List<QuickReply> picked;
  late int dismissals;

  setUp(() {
    picked = <QuickReply>[];
    dismissals = 0;
  });

  Future<void> pumpBar(WidgetTester tester,
          {QuickReplySet? set, bool loading = false, double textScale = 1.0}) =>
      pumpApp(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: QuickReplyBar(
              set: set,
              loading: loading,
              onPick: picked.add,
              onDismiss: () => dismissals++,
            ),
          ),
        ),
        textScale: textScale,
      );

  group('when there is nothing to suggest', () {
    testWidgets('an absent set draws no bar at all', (tester) async {
      await pumpBar(tester);
      expect(tester.getSize(find.byType(QuickReplyBar)), Size.zero);
    });

    testWidgets('a set that came back empty also collapses', (tester) async {
      await pumpBar(tester, set: _set(suggestions: const []));
      expect(tester.getSize(find.byType(QuickReplyBar)), Size.zero);
      expect(find.text('Suggested replies'), findsNothing);
    });

    // The spinner is indeterminate, so no test in this file may settle the tree.
    testWidgets('while the model is reading, the bar says so', (tester) async {
      await pumpBar(tester, loading: true);
      expect(find.text('Reading the message…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(InkWell), findsNothing, reason: 'nothing to pick yet');
    });
  });

  group('the provenance badge', () {
    testWidgets('a model answer earns the sparkle and says AI', (tester) async {
      await pumpBar(tester, set: _set());
      expect(find.text('AI suggested replies'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.auto_awesome)).color,
          AppColors.accent);
    });

    // ml-service unreachable: the same sentences, no claim about where they came from.
    testWidgets('a keyword fallback claims nothing', (tester) async {
      await pumpBar(tester, set: _set(source: 'lexicon'));
      expect(find.text('Suggested replies'), findsOneWidget);
      expect(find.text('AI suggested replies'), findsNothing);
      expect(find.byIcon(Icons.auto_awesome), findsNothing);
    });

    testWidgets('an unavailable source is treated as a fallback, not a model',
        (tester) async {
      await pumpBar(tester, set: _set(source: 'unavailable'));
      expect(find.text('Suggested replies'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsNothing);
    });
  });

  group('picking one', () {
    testWidgets('every suggestion is drawn, in the order it arrived', (tester) async {
      await pumpBar(tester, set: _set());
      expect(find.text('Yes, 7pm works'), findsOneWidget);
      expect(find.text('Can we make it 8?'), findsOneWidget);
      expect(find.text('I will confirm tonight'), findsOneWidget);
    });

    // The intent rides along with the text: the composer reports which suggestion was
    // taken, which is what makes the row measurable at all.
    testWidgets('a tap reports the whole reply and dismisses nothing', (tester) async {
      await pumpBar(tester, set: _set());
      await tester.tap(find.text('Can we make it 8?'));
      await tester.pump();
      expect(picked.single.text, 'Can we make it 8?');
      expect(picked.single.intent, 'counter');
      expect(dismissals, 0, reason: 'the row stays up until the caller closes it');
    });

    testWidgets('the close button is the only thing that dismisses', (tester) async {
      await pumpBar(tester, set: _set());
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(dismissals, 1);
      expect(picked, isEmpty);
    });

    // A suggestion is one line. The row scrolls sideways rather than wrapping, so a
    // long sentence is cut off instead of pushing the composer down the screen.
    testWidgets('a long suggestion is capped and ellipsised', (tester) async {
      await pumpBar(tester, set: _set(suggestions: const [
        QuickReply(
            text: 'That slot is taken but I can open the 9pm one if you would rather '
                'play later in the evening'),
      ]));
      final chip = tester.widget<Text>(find.textContaining('That slot is taken'));
      expect(chip.maxLines, 1);
      expect(chip.overflow, TextOverflow.ellipsis);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the row survives a doubled text scale', (tester) async {
      await pumpBar(tester, set: _set(), textScale: 2.0);
      expect(find.text('AI suggested replies'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
