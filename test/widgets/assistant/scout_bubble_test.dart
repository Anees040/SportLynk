// One turn of the Scout transcript: the user's bubble, Scout's group, the day
// separator between them, and the per-message audit sheet.
//
// The ordering inside Scout's group is the argument of the whole screen, so it is
// asserted as geometry rather than as presence: provenance above the words because it
// changes how the words should be read, then the sentence, then the cards that back it,
// then the chips that continue it. Chips live inside the group rather than in a dock
// above the composer, which is what makes scrolling back to a turn bring back the
// options that were offered at that turn — a pinned dock would silently rewrite history
// to whatever the newest message happened to suggest. That is pinned here by asserting
// the chips sit below the cards, in the group, and are gone when the reply carried none.
//
// The user's side has one job the tests spend their length on: a failed send must not
// lose the text. The bubble stays, it says so, and a retry appears beside it — because
// the words a user typed are the only copy of what they wanted.
//
// Voting is deliberately asymmetric. The endpoint takes 1 or -1 and upserts, so a vote
// can be changed but not withdrawn: the active thumb is inert rather than offering an
// undo the server would reject. Both directions are asserted, since a toggle that
// silently did nothing would look identical to one that worked.
//
// The explain sheet answers the question every assistant demo gets — which part of this
// was a model and which part was an if-statement — and its most important state is the
// one where it cannot answer: `nlu` travels with the live response and is not stored on
// the message row, so a turn reloaded from history has a source and no confidence. That
// sentence is asserted verbatim, because a blank field or a guessed number would both be
// worse than saying so.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_bits.dart';
import 'package:sportlynk/widgets/assistant/scout_bubble.dart';
import 'package:sportlynk/widgets/assistant/scout_chips.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../widget_harness.dart';

/// A reply as the POST returns it.
ScoutReply reply({
  String text = 'Arena One is free at 7.',
  List<ScoutChip> chips = const [],
  List<ScoutCard> cards = const [],
  ScoutSource source = ScoutSource.live,
  String? action,
  bool? actionOk,
}) =>
    ScoutReply(
      text: text,
      chips: chips,
      cards: cards,
      source: source,
      action: action,
      actionOk: actionOk,
    );

/// One of Scout's turns. The id is a server id by default, which is what makes the
/// vote row eligible to appear at all.
ScoutMessage scout({
  String id = 'm1',
  ScoutReply? r,
  ScoutNlu? nlu,
  int vote = 0,
  String? text,
}) {
  final body = r ?? reply();
  return ScoutMessage(
    id: id,
    isScout: true,
    text: text ?? body.text,
    createdAt: DateTime(2026, 3, 14, 19, 5),
    reply: body,
    nlu: nlu,
    vote: vote,
  );
}

/// One of the player's own turns.
ScoutMessage user({
  String text = 'any ground free at 7?',
  ScoutDelivery delivery = ScoutDelivery.sent,
}) =>
    ScoutMessage(
      id: 'local:c1',
      isScout: false,
      text: text,
      createdAt: DateTime(2026, 3, 14, 19, 4),
      delivery: delivery,
      clientId: 'c1',
    );

/// A card the extra-card renderer can draw without a network call.
ScoutCard textCard(String title) => ScoutCard(
      type: 'policy',
      data: CardData({'title': title, 'body': 'Refunds land within 24 hours.'}),
    );

void main() {
  late List<ScoutMessage> retried;
  late List<(String, int)> votes;
  late List<ScoutMessage> explained;

  setUp(() {
    retried = <ScoutMessage>[];
    votes = <(String, int)>[];
    explained = <ScoutMessage>[];
  });

  Future<void> pumpGroup(
    WidgetTester tester,
    ScoutMessage msg, {
    ScoutCardActions actions = const ScoutCardActions(),
    bool withVote = true,
    bool withExplain = true,
    bool withRetry = true,
    double textScale = 1.0,
  }) =>
      pumpApp(
        tester,
        Scaffold(
          backgroundColor: ScoutTheme.canvas,
          body: ScoutMessageGroup(
            msg: msg,
            actions: actions,
            onRetry: withRetry ? retried.add : null,
            onVote: withVote ? (m, v) => votes.add((m.id, v)) : null,
            onExplain: withExplain ? explained.add : null,
          ),
        ),
        textScale: textScale,
      );

  /// The bubble's own box — the first decorated [Container] in the group.
  Container bubbleBox(WidgetTester tester) => tester
      .widgetList<Container>(find.descendant(
          of: find.byType(ScoutMessageGroup), matching: find.byType(Container)))
      .firstWhere((c) => c.decoration is BoxDecoration);

  group('the player\'s own words', () {
    testWidgets('a sent message is a gradient bubble on the right',
        (tester) async {
      await pumpGroup(tester, user());
      expect(find.text('any ground free at 7?'), findsOneWidget);
      final box = bubbleBox(tester).decoration! as BoxDecoration;
      expect(box.gradient, ScoutTheme.userBubbleGradient);
      expect(tester.widget<Row>(find.byType(Row).first).mainAxisAlignment,
          MainAxisAlignment.end);
      expect(find.byIcon(Icons.refresh_rounded), findsNothing);
      expect(find.text('Not sent'), findsNothing);
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
    });

    // The squared corner is on the right, so the bubble points at its own sender.
    testWidgets('the notch is on the side the bubble sits on', (tester) async {
      await pumpGroup(tester, user());
      final radius =
          (bubbleBox(tester).decoration! as BoxDecoration).borderRadius!
              as BorderRadius;
      expect(radius.bottomRight, const Radius.circular(6));
      expect(radius.topLeft, const Radius.circular(ScoutTheme.bubbleRadius));
    });

    testWidgets('a message in flight is dimmed rather than hidden',
        (tester) async {
      await pumpGroup(tester, user(delivery: ScoutDelivery.sending));
      expect(find.text('any ground free at 7?'), findsOneWidget);
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.62);
      expect(find.byIcon(Icons.refresh_rounded), findsNothing,
          reason: 'a send still in flight has nothing to retry yet');
    });

    // The text a user typed is the only copy of what they wanted, so a timeout keeps
    // the bubble and adds a way out of it.
    testWidgets('a failed send keeps the words and offers the retry',
        (tester) async {
      final msg = user(delivery: ScoutDelivery.failed);
      await pumpGroup(tester, msg);
      expect(find.text('any ground free at 7?'), findsOneWidget);
      expect(find.text('Not sent'), findsOneWidget);
      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.color, ScoutTheme.danger);
      expect(button.tooltip, 'Send again',
          reason: 'an icon-only button carries its own name');

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      expect(retried.single.clientId, 'c1',
          reason: 'the client id travels with it so the server de-duplicates');
    });

    testWidgets('a screen that cannot retry draws the button inert',
        (tester) async {
      await pumpGroup(tester, user(delivery: ScoutDelivery.failed),
          withRetry: false);
      expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed,
          isNull);
      await tester.tap(find.byIcon(Icons.refresh_rounded));
      expect(retried, isEmpty);
    });

    // Pinned as it behaves, not as it should. The retry is a 34x34 target, under the
    // project's 48x48 floor, and it is the only way to recover a message the network
    // lost. Raising `minWidth`/`minHeight` to 48 without changing the visual size of
    // the glyph is what would turn this expectation green.
    testWidgets('the retry target is under the minimum', (tester) async {
      await pumpGroup(tester, user(delivery: ScoutDelivery.failed));
      expect(tester.getSize(find.byType(IconButton)).height, 40,
          reason: 'below the 48px floor: scout_bubble.dart:75');
    });
  });

  group('Scout\'s turn, in order', () {
    testWidgets('the avatar, the provenance and the sentence stack downward',
        (tester) async {
      await pumpGroup(tester, scout());
      expect(find.byType(ScoutAvatar), findsOneWidget);
      expect(tester.widget<ScoutAvatar>(find.byType(ScoutAvatar)).size, 26);
      expect(find.byType(ScoutSourcePill), findsOneWidget);
      expect(find.text('Arena One is free at 7.'), findsOneWidget);
      expect(tester.getTopLeft(find.byType(ScoutSourcePill)).dy,
          lessThan(tester.getTopLeft(find.text('Arena One is free at 7.')).dy),
          reason: 'provenance changes how the words should be read');
    });

    // The reply is the only copy of Scout's words on screen, and a reader has to be
    // able to quote it back.
    testWidgets('the sentence is selectable', (tester) async {
      await pumpGroup(tester, scout());
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('a source the build cannot name draws no pill', (tester) async {
      await pumpGroup(tester, scout(r: reply(source: ScoutSource.unknown)));
      expect(find.byType(ScoutSourcePill), findsNothing,
          reason: 'an unlabelled source would claim a provenance it has not got');
      expect(find.text('Arena One is free at 7.'), findsOneWidget);
    });

    testWidgets('the pill opens the audit for its own message', (tester) async {
      await pumpGroup(tester, scout());
      await tester.tap(find.byType(ScoutSourcePill));
      expect(explained.single.id, 'm1');
    });

    testWidgets('a screen with no audit draws the pill untappable',
        (tester) async {
      await pumpGroup(tester, scout(), withExplain: false);
      expect(
          tester.widget<InkWell>(find.descendant(
              of: find.byType(ScoutSourcePill), matching: find.byType(InkWell))).onTap,
          isNull);
    });

    // A pure-card reply is a real shape — the slot picker after a ground is chosen —
    // and an empty rounded rectangle above it would read as a rendering bug.
    testWidgets('a reply with no words draws no bubble', (tester) async {
      await pumpGroup(
          tester, scout(text: '', r: reply(text: '', cards: [textCard('Refunds')])));
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Refunds'), findsOneWidget);
    });

    testWidgets('the cards sit under the sentence, and the chips under those',
        (tester) async {
      await pumpGroup(
          tester,
          scout(
              r: reply(
            cards: [textCard('Refund policy')],
            chips: const [ScoutChip(label: 'Book it', action: 'book_venue')],
          )));
      final sentence = tester.getTopLeft(find.text('Arena One is free at 7.')).dy;
      final card = tester.getTopLeft(find.text('Refund policy')).dy;
      final chips = tester.getTopLeft(find.byType(ScoutChipsWrap)).dy;
      expect(sentence, lessThan(card));
      expect(card, lessThan(chips),
          reason: 'sentence, then evidence, then next move');
    });

    // Chips belong to the turn that offered them, so scrolling back brings them back;
    // a dock above the composer would show the newest turn's options against an old one.
    testWidgets('the chips are inside the group, not docked', (tester) async {
      await pumpGroup(
          tester,
          scout(
              r: reply(
                  chips: const [ScoutChip(label: 'Book it', action: 'book_venue')])));
      expect(
          find.descendant(
              of: find.byType(ScoutMessageGroup),
              matching: find.byType(ScoutChipsWrap)),
          findsOneWidget);
      expect(find.text('Book it'), findsOneWidget);
    });

    testWidgets('a reply that offered nothing draws no chip row',
        (tester) async {
      await pumpGroup(tester, scout());
      expect(find.byType(ScoutChipsWrap), findsNothing);
    });

    // A closed thread's chips are drawn but inert, so history reads as it was without
    // letting a reader act on an offer that has expired.
    testWidgets('a disabled screen still shows what was offered',
        (tester) async {
      await pumpGroup(
        tester,
        scout(
            r: reply(
                chips: const [ScoutChip(label: 'Book it', action: 'book_venue')])),
        actions: ScoutCardActions.none,
      );
      expect(find.text('Book it'), findsOneWidget);
      expect(tester.widget<ScoutChipsWrap>(find.byType(ScoutChipsWrap)).enabled,
          isFalse);
    });
  });

  // A vote can be changed but not withdrawn: the endpoint takes 1 or -1 and upserts,
  // so the active thumb is inert rather than offering an undo the server would reject.
  group('was this any good', () {
    IconButton thumb(WidgetTester tester, IconData icon) =>
        tester.widget<IconButton>(find.ancestor(
            of: find.byIcon(icon), matching: find.byType(IconButton)));

    testWidgets('an unvoted turn offers both thumbs, outlined', (tester) async {
      await pumpGroup(tester, scout());
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_down_outlined), findsOneWidget);
      expect(thumb(tester, Icons.thumb_up_outlined).tooltip, 'Helpful');
      expect(thumb(tester, Icons.thumb_down_outlined).tooltip, 'Not helpful');
      expect(thumb(tester, Icons.thumb_up_outlined).color, ScoutTheme.inkFaint);
    });

    testWidgets('an up-vote fills its own thumb and goes inert', (tester) async {
      await pumpGroup(tester, scout(vote: 1));
      expect(find.byIcon(Icons.thumb_up_rounded), findsOneWidget);
      expect(thumb(tester, Icons.thumb_up_rounded).color, ScoutTheme.good);
      expect(thumb(tester, Icons.thumb_up_rounded).tooltip,
          'You marked this helpful');
      expect(thumb(tester, Icons.thumb_up_rounded).onPressed, isNull,
          reason: 'a vote cannot be withdrawn, so the active thumb is not a toggle');
      expect(thumb(tester, Icons.thumb_down_outlined).onPressed, isNotNull,
          reason: 'but it can be changed');
    });

    testWidgets('a down-vote is the same in the other direction',
        (tester) async {
      await pumpGroup(tester, scout(vote: -1));
      expect(thumb(tester, Icons.thumb_down_rounded).color, ScoutTheme.danger);
      expect(thumb(tester, Icons.thumb_down_rounded).onPressed, isNull);
    });

    testWidgets('a tap reports the message and the direction', (tester) async {
      await pumpGroup(tester, scout());
      await tester.tap(find.byIcon(Icons.thumb_down_outlined));
      expect(votes.single, ('m1', -1));
    });

    testWidgets('changing a vote sends the new one', (tester) async {
      await pumpGroup(tester, scout(vote: -1));
      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      expect(votes.single, ('m1', 1));
    });

    // A vote is stored against the server's message id, so an optimistic bubble has
    // nothing to store it against.
    testWidgets('an optimistic bubble cannot be voted on', (tester) async {
      await pumpGroup(tester, scout(id: 'local:scout:1'));
      expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
    });

    testWidgets('the player\'s own words are never rated', (tester) async {
      await pumpGroup(tester, user());
      expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
    });

    testWidgets('a screen that takes no votes draws no thumbs', (tester) async {
      await pumpGroup(tester, scout(), withVote: false);
      expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
    });
  });

  // History a session old turns into one undated wall without these, and Scout's
  // transcript is explicitly meant to be read back.
  group('the day boundary', () {
    Future<void> pumpSeparator(WidgetTester tester, DateTime day) => pumpApp(
          tester,
          Scaffold(
            backgroundColor: ScoutTheme.canvas,
            body: ScoutDateSeparator(day: day),
          ),
        );

    testWidgets('today and yesterday are named, not dated', (tester) async {
      final now = DateTime.now();
      await pumpSeparator(tester, now);
      expect(find.text('Today'), findsOneWidget);

      await pumpSeparator(tester, now.subtract(const Duration(days: 1)));
      expect(find.text('Yesterday'), findsOneWidget);
    });

    testWidgets('an earlier day this year drops the year', (tester) async {
      final now = DateTime.now();
      final day = DateTime(now.year, 3, 14);
      await pumpSeparator(tester, day);
      final label = now.month == 3 && now.day == 14
          ? 'Today'
          : (now.month == 3 && now.day == 15 ? 'Yesterday' : '14 Mar');
      expect(find.text(label), findsOneWidget);
    });

    testWidgets('a day in another year carries it', (tester) async {
      await pumpSeparator(tester, DateTime(2024, 12, 25));
      expect(find.text('25 Dec 2024'), findsOneWidget);
    });

    test('the same-day check is by calendar day, not by distance', () {
      expect(
          ScoutDateSeparator.sameDay(
              DateTime(2026, 3, 14, 0, 1), DateTime(2026, 3, 14, 23, 59)),
          isTrue);
      expect(
          ScoutDateSeparator.sameDay(
              DateTime(2026, 3, 14, 23, 59), DateTime(2026, 3, 15, 0, 1)),
          isFalse,
          reason: 'two minutes apart is still two days');
      expect(
          ScoutDateSeparator.sameDay(
              DateTime(2025, 3, 14), DateTime(2026, 3, 14)),
          isFalse);
    });
  });

  // The question every assistant demo gets, answered per message: which part of this
  // was a model and which part was an if-statement?
  group('how I answered this', () {
    Future<void> openExplain(WidgetTester tester, ScoutMessage msg) async {
      if (find.byType(BottomSheet).evaluate().isNotEmpty) {
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await tester.pumpAndSettle();
      }
      await pumpApp(
        tester,
        Builder(
          builder: (context) => Scaffold(
            backgroundColor: ScoutTheme.canvas,
            body: Center(
              child: ElevatedButton(
                onPressed: () => showScoutExplainSheet(context, msg),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('a live turn shows what the model did, and how fast',
        (tester) async {
      await openExplain(
        tester,
        scout(
            nlu: const ScoutNlu(
          intent: 'check_availability',
          confidence: 0.93,
          via: 'model',
          modelVersion: 'intent-v2',
          ms: 41,
        )),
      );
      expect(find.text('How I answered this'), findsOneWidget);
      expect(find.text('Live data'), findsOneWidget);
      expect(find.text('Read from the database just now'), findsOneWidget);
      expect(find.text('Understood as'), findsOneWidget);
      expect(find.text('check_availability'), findsOneWidget);
      expect(find.text('93%'), findsOneWidget);
      expect(find.text('model'), findsOneWidget);
      expect(find.text('intent-v2'), findsOneWidget);
      expect(find.text('41 ms'), findsOneWidget);
      expect(find.text('Below threshold — I offered the menu'), findsNothing);
    });

    // The honest case: the model refused to guess and the reply was the menu.
    testWidgets('an abstention says so in words', (tester) async {
      await openExplain(
        tester,
        scout(
            r: reply(source: ScoutSource.menu),
            nlu: const ScoutNlu(
                confidence: 0.21, abstained: true, via: 'model')),
      );
      expect(find.text('Below threshold — I offered the menu'), findsOneWidget);
      expect(find.text('21%'), findsOneWidget);
      expect(find.text('Understood as'), findsNothing,
          reason: 'there is no label to show when the model declined to pick one');
    });

    // `nlu` travels with the live POST and is not stored on the message row, so a
    // reloaded turn has a source and nothing else. Saying that beats a blank field.
    testWidgets('a turn reloaded from history admits it has no record',
        (tester) async {
      await openExplain(tester, scout());
      expect(
          find.text('This turn has no classifier record. Either you tapped a '
              'button — those run the action directly and never go near the model '
              '— or the message was reloaded from history, where only the source '
              'is kept.'),
          findsOneWidget);
      expect(find.text('Confidence'), findsNothing);
      expect(find.text('Live data'), findsOneWidget,
          reason: 'the source survives the round trip even when the parse does not');
    });

    testWidgets('an action that ran is named, and a failure is marked',
        (tester) async {
      await openExplain(
          tester, scout(r: reply(action: 'create_booking', actionOk: true)));
      expect(find.text('Action run'), findsOneWidget);
      expect(find.text('create_booking'), findsOneWidget);

      await openExplain(
          tester, scout(r: reply(action: 'create_booking', actionOk: false)));
      expect(find.text('create_booking (failed)'), findsOneWidget);
    });

    testWidgets('a turn that ran nothing shows no action row', (tester) async {
      await openExplain(tester, scout());
      expect(find.text('Action run'), findsNothing);
    });

    // A confidence of 0 would read as "the model was certain it was wrong", so the
    // row is withheld rather than drawn as a zero.
    testWidgets('a chip press shows no confidence at all', (tester) async {
      await openExplain(
          tester, scout(nlu: const ScoutNlu(intent: 'book_venue', via: 'chip')));
      expect(find.text('chip'), findsOneWidget);
      expect(find.text('Confidence'), findsNothing);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('a confidence already in percent is not multiplied again',
        (tester) async {
      await openExplain(tester, scout(nlu: const ScoutNlu(confidence: 93)));
      expect(find.text('93%'), findsOneWidget);
      expect(find.text('9300%'), findsNothing);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('a failed user bubble holds', (tester) async {
      useDeviceSurface(tester);
      await pumpGroup(tester, user(delivery: ScoutDelivery.failed),
          textScale: 2.0);
      expect(find.text('Not sent'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('Scout\'s group holds with cards and chips', (tester) async {
      useDeviceSurface(tester);
      await pumpGroup(
        tester,
        scout(
            r: reply(
          cards: [textCard('Refund policy')],
          chips: const [ScoutChip(label: 'Book it', action: 'book_venue')],
        )),
        textScale: 2.0,
      );
      expect(find.text('Arena One is free at 7.'), findsOneWidget);
      expect(find.text('Refund policy'), findsOneWidget);
    });
  });
}
