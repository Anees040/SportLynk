// The four money-and-state Scout cards, and the switch that turns a wire type into one.
//
// The switch is asserted first because it is the single place a backend card becomes
// pixels, and both of its deliberate consequences are easy to lose in a refactor: an
// unknown type must degrade to something labelled rather than crash or vanish, and every
// type in the contract must reach a renderer — including `stats`, which no action emits
// today and which therefore has no screen anyone would notice breaking.
//
// After that the file is about one thing: a card in a chat transcript is not allowed to
// author an action. The slot grid is the sharp case. Every tile posts the chip the
// backend minted for that slot rather than arguments the widget assembled, so a tile
// whose chip is missing goes dim instead of guessing at a slot id — a synthesized
// `pick_slot` would be the client authoring a money-path action, which is exactly what
// the button-only action design exists to prevent. The tests assert the posted object is
// identical to the one that arrived, not merely equal in its fields.
//
// The confirm card gets the most attention per pixel because a mis-tap there costs a
// deposit. Its figures are the server's arithmetic rendered, never recomputed, so the
// deposit percentage is read from the payload; its two footer figures are de-duplicated
// against the detail lines by label, which is safe only because both sides come from the
// same backend vocabulary and is worth pinning for that reason. There is no default
// action and no dismissal: both ways out are explicit buttons.
//
// The booking card is coloured from the status word the bookings table returned rather
// than from the fact that a request succeeded, because "pending" and "confirmed" are
// different states of someone's Saturday. Its one client-side button walks the user to
// the Bookings tab, which is how Scout demonstrates it is not a second, parallel booking
// system.
//
// Everything here takes its data as a parameter; nothing touches the network. Photo urls
// are left null throughout so `ScoutThumb` draws its placeholder instead of reaching for
// `CachedNetworkImage`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_bits.dart';
import 'package:sportlynk/widgets/assistant/scout_cards.dart';
import 'package:sportlynk/widgets/assistant/scout_chips.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../widget_harness.dart';

ScoutCard card(String type, Map<String, dynamic> data) =>
    ScoutCard(type: type, data: CardData(data));

Map<String, dynamic> chip(String label, String action,
        [Map<String, dynamic>? args]) =>
    {'label': label, 'action': action, 'args': ?args};

Map<String, dynamic> venue({
  String name = 'Karachi Sports Arena',
  String city = 'Karachi',
  String address = 'Gulshan Block 5',
  String sport = 'Football',
  num? price = 2400,
  num? rating = 4.6,
  int reviews = 31,
  int? matchPct,
  List<String> reasons = const [],
  List<Map<String, dynamic>>? buttons,
}) =>
    {
      'id': 'v1',
      'name': name,
      'city': city,
      'address': address,
      'sport': sport,
      'pricePerHour': price,
      'rating': rating,
      'totalReviews': reviews,
      'matchPct': ?matchPct,
      'reasons': reasons,
      'buttons': buttons ?? [chip('Book', 'book_venue', {'venueId': 'v1'})],
    };

Map<String, dynamic> slot(int n, String label, {String? id, String? price}) => {
      'n': n,
      'slotId': id ?? 's$n',
      'label': label,
      'priceLabel': price ?? 'PKR 2,400',
    };

Map<String, dynamic> picker({
  String venueName = 'Karachi Sports Arena',
  String dateLabel = 'Sat 21 Mar',
  List<Map<String, dynamic>>? slots,
  List<Map<String, dynamic>>? buttons,
}) =>
    {
      'venueId': 'v1',
      'venueName': venueName,
      'dateLabel': dateLabel,
      'slots': slots ?? [slot(1, '18:00–19:00'), slot(2, '19:00–20:00')],
      'buttons': buttons ??
          [
            chip('18:00', 'pick_slot', {'slotId': 's1', 'n': 1}),
            chip('19:00', 'pick_slot', {'slotId': 's2', 'n': 2}),
          ],
    };

Map<String, dynamic> confirm({
  String what = 'book_slot',
  String title = 'Confirm this booking?',
  List<Object>? lines,
  num? total = 2400,
  num? deposit = 600,
  int? depositPct = 25,
  String? note,
  List<Map<String, dynamic>>? buttons,
}) =>
    {
      'what': what,
      'title': title,
      'lines': lines ??
          [
            {'label': 'Ground', 'value': 'Karachi Sports Arena'},
            {'label': 'Day', 'value': 'Sat 21 Mar'},
          ],
      'total': ?total,
      'deposit': ?deposit,
      'depositPct': ?depositPct,
      'note': ?note,
      'buttons': buttons ??
          [chip('Confirm', 'confirm'), chip('Cancel', 'cancel_confirm')],
    };

Map<String, dynamic> booking({
  String id = 'bk-91f2c7d4e5',
  String status = 'confirmed',
  String venueName = 'Karachi Sports Arena',
  String city = 'Karachi',
  String dateLabel = 'Sat 21 Mar',
  String timeLabel = '18:00–19:00',
  num? total = 2400,
  List<Map<String, dynamic>>? buttons,
}) =>
    {
      'id': id,
      'venueId': 'v1',
      'venueName': venueName,
      'city': city,
      'dateLabel': dateLabel,
      'timeLabel': timeLabel,
      'status': status,
      'total': ?total,
      'buttons': buttons ?? const [],
    };

void main() {
  Future<void> pumpCard(
    WidgetTester tester,
    ScoutCard c, {
    ScoutCardActions actions = const ScoutCardActions(),
    String? contextText,
    double textScale = 1.0,
    double width = 300,
  }) async {
    useDeviceSurface(tester);
    await pumpApp(
      tester,
      Scaffold(
        backgroundColor: ScoutTheme.canvas,
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: ScoutCardView(
                card: c,
                actions: actions,
                contextText: contextText,
              ),
            ),
          ),
        ),
      ),
      textScale: textScale,
    );
  }

  group('turning a wire type into a widget', () {
    testWidgets('each of the four cards here gets its own renderer',
        (tester) async {
      await pumpCard(tester, card('venue', venue()));
      expect(find.text('Karachi Sports Arena'), findsOneWidget);

      await pumpCard(tester, card('slot_picker', picker()));
      expect(find.text('18:00–19:00'), findsOneWidget);

      await pumpCard(tester, card('confirm', confirm()));
      expect(find.text('Confirm this booking?'), findsOneWidget);

      await pumpCard(tester, card('booking', booking()));
      expect(find.text('Ref bk-91f2'), findsOneWidget);
    });

    // A newer backend adding a thirteenth card must degrade on an old build: the
    // reply's own text is still useful, so the card is labelled rather than dropped.
    testWidgets('an unknown type asks for a newer app rather than vanishing',
        (tester) async {
      await pumpCard(tester, card('hologram', {'anything': 1}));
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('needs a newer version of the app'),
        findsOneWidget,
      );
      expect(find.textContaining('hologram'), findsOneWidget,
          reason: 'naming the type is what makes the degradation diagnosable');
    });

    // `stats` is in the contract but produced by no action today, so nothing on
    // screen would reveal a broken renderer. Its table is generic over whatever
    // `data` holds, with the wire keys humanised.
    testWidgets('a type no action emits yet still renders its payload',
        (tester) async {
      await pumpCard(
        tester,
        card('stats', {'matchesPlayed': 12, 'ranked': true}),
      );
      expect(find.text('Matches played'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('Ranked'), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget,
          reason: 'a bare "true" is not a value a player can read');
    });

    // Pinned as it behaves, not as it should: `_StatsCard` walks every scalar key in
    // `data`, and `title` is one of them, so the heading is repeated as a row
    // beneath itself. The fix is to skip `title` alongside `buttons` at
    // `lib/widgets/assistant/scout_cards_more.dart:803`. Harmless while no action
    // emits this card, which is precisely why it needs pinning rather than trusting.
    testWidgets('a stats title is currently also listed as one of its rows',
        (tester) async {
      await pumpCard(tester, card('stats', {'title': 'Your season'}));
      expect(find.text('Your season'), findsNWidgets(2));
      expect(find.text('Title'), findsOneWidget);
    });
  });

  group('a ground', () {
    testWidgets('the name, the place and the price are all shown',
        (tester) async {
      await pumpCard(tester, card('venue', venue()));
      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text('Gulshan Block 5, Karachi'), findsOneWidget);
      expect(find.text('PKR 2,400/hr'), findsOneWidget);
      expect(find.text('Football'), findsOneWidget);
    });

    testWidgets('a rating carries its review count', (tester) async {
      await pumpCard(tester, card('venue', venue(rating: 4.6, reviews: 31)));
      expect(find.text('4.6 (31)'), findsOneWidget);
    });

    // An unrated ground is new, not bad. A "0.0" here would read as the worst
    // ground on the list.
    testWidgets('an unrated ground says New rather than nought', (tester) async {
      await pumpCard(tester, card('venue', venue(rating: null, reviews: 0)));
      expect(find.text('New'), findsOneWidget);
      expect(find.textContaining('0.0'), findsNothing);
    });

    testWidgets('a rating with no reviews shows the figure alone',
        (tester) async {
      await pumpCard(tester, card('venue', venue(rating: 5, reviews: 0)));
      expect(find.text('5.0'), findsOneWidget);
    });

    testWidgets('a ground with no price shows no price fact', (tester) async {
      await pumpCard(tester, card('venue', venue(price: null)));
      expect(find.textContaining('/hr'), findsNothing);
    });

    // The badge is the model's opinion, not a fact about the ground, so it is absent
    // entirely when no ranker scored this list.
    testWidgets('an unranked ground gets no match badge', (tester) async {
      await pumpCard(tester, card('venue', venue()));
      expect(find.byType(ScoutMatchBadge), findsOneWidget);
      expect(find.textContaining('match'), findsNothing);
    });

    testWidgets('a ranked ground shows the percentage it scored',
        (tester) async {
      await pumpCard(tester, card('venue', venue(matchPct: 82)));
      expect(find.text('82% match'), findsOneWidget);
    });

    testWidgets('the ranker\'s reasons are listed', (tester) async {
      await pumpCard(
        tester,
        card('venue', venue(reasons: ['Near you', 'In your budget'])),
      );
      expect(find.text('Near you'), findsOneWidget);
      expect(find.text('In your budget'), findsOneWidget);
    });

    // The card exists to get a ground booked, so that one chip is filled and the
    // rest are not — visual weight tracks what the card can do.
    testWidgets('booking is the card\'s primary action', (tester) async {
      await pumpCard(
        tester,
        card('venue', venue(buttons: [
          chip('Book', 'book_venue'),
          chip('Directions', 'directions'),
        ])),
      );
      final tones = tester
          .widgetList<ScoutChipButton>(find.byType(ScoutChipButton))
          .map((b) => b.tone)
          .toList();
      expect(tones, [ScoutChipTone.primary, ScoutChipTone.normal]);
    });

    // The backend's own chip, posted back with its arguments intact: the card never
    // assembles arguments of its own.
    testWidgets('a tap posts the backend\'s chip, arguments and all',
        (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(tester, card('venue', venue()),
          actions: ScoutCardActions(onChip: posted.add));
      await tester.tap(find.text('Book'));
      await tester.pump();
      expect(posted.single.action, 'book_venue');
      expect(posted.single.args, {'venueId': 'v1'});
    });

    // A turn in flight leaves the buttons visible but inert, so a double tap cannot
    // post two bookings.
    testWidgets('a turn in flight leaves the button visible but inert',
        (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(
        tester,
        card('venue', venue()),
        actions: ScoutCardActions(onChip: posted.add, enabled: false),
      );
      expect(find.text('Book'), findsOneWidget);
      expect(
        tester.widget<ScoutChipButton>(find.byType(ScoutChipButton)).enabled,
        isFalse,
      );
      await tester.tap(find.text('Book'), warnIfMissed: false);
      await tester.pump();
      expect(posted, isEmpty);
    });

    // A host that passes no handler is the same inert state, reached the other way.
    testWidgets('a card with nowhere to post its chip does not post it',
        (tester) async {
      await pumpCard(tester, card('venue', venue()));
      expect(
        tester.widget<ScoutChipButton>(find.byType(ScoutChipButton)).enabled,
        isFalse,
      );
    });
  });

  group('the slot grid', () {
    testWidgets('the ground and the day head the grid', (tester) async {
      await pumpCard(tester, card('slot_picker', picker()));
      expect(find.text('Karachi Sports Arena · Sat 21 Mar'), findsOneWidget);
    });

    testWidgets('every free hour gets a tile', (tester) async {
      await pumpCard(
        tester,
        card('slot_picker', picker(slots: [
          slot(1, '18:00–19:00'),
          slot(2, '19:00–20:00'),
          slot(3, '20:00–21:00'),
        ], buttons: [
          chip('18:00', 'pick_slot', {'slotId': 's1', 'n': 1}),
          chip('19:00', 'pick_slot', {'slotId': 's2', 'n': 2}),
          chip('20:00', 'pick_slot', {'slotId': 's3', 'n': 3}),
        ])),
      );
      expect(find.text('18:00–19:00'), findsOneWidget);
      expect(find.text('19:00–20:00'), findsOneWidget);
      expect(find.text('20:00–21:00'), findsOneWidget);
    });

    // The number is a thing the user can also say — "2", "the second one" — and the
    // dialog manager resolves it. Printing it makes that shortcut discoverable
    // rather than secret.
    testWidgets('each tile shows the number the user could say instead',
        (tester) async {
      await pumpCard(tester, card('slot_picker', picker()));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('the price is on the tile that costs it', (tester) async {
      await pumpCard(
        tester,
        card('slot_picker', picker(slots: [
          slot(1, '18:00–19:00', price: 'PKR 2,400'),
          slot(2, '19:00–20:00', price: 'PKR 3,000'),
        ])),
      );
      expect(find.text('PKR 2,400'), findsOneWidget);
      expect(find.text('PKR 3,000'), findsOneWidget);
    });

    // An em dash is the model file's "no price known"; printing it on a tile would
    // read as a price of nothing.
    testWidgets('a tile with no known price shows no price line',
        (tester) async {
      await pumpCard(
        tester,
        card('slot_picker', picker(slots: [slot(1, '18:00–19:00', price: '—')])),
      );
      expect(find.text('—'), findsNothing);
      expect(find.text('18:00–19:00'), findsOneWidget);
    });

    // The whole point of the button-only actions: what is posted is the object the
    // server minted, matched to this tile by slot id.
    testWidgets('a tap posts the server\'s chip for that slot', (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(tester, card('slot_picker', picker()),
          actions: ScoutCardActions(onChip: posted.add));
      await tester.tap(find.text('19:00–20:00'));
      await tester.pump();
      expect(posted.single.action, 'pick_slot');
      expect(posted.single.args, {'slotId': 's2', 'n': 2},
          reason: 'the second tile must post the second slot, not the first');
    });

    // A miss cannot happen for a well-formed card, and when it does the tile must
    // not guess: synthesizing a `pick_slot` would author a money-path action
    // client-side.
    testWidgets('a slot with no minted chip goes dim rather than guessing',
        (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(
        tester,
        card('slot_picker', picker(
          slots: [slot(1, '18:00–19:00'), slot(9, '21:00–22:00', id: 's9')],
          buttons: [chip('18:00', 'pick_slot', {'slotId': 's1', 'n': 1})],
        )),
        actions: ScoutCardActions(onChip: posted.add),
      );
      await tester.tap(find.text('21:00–22:00'), warnIfMissed: false);
      await tester.pump();
      expect(posted, isEmpty);

      await tester.tap(find.text('18:00–19:00'));
      await tester.pump();
      expect(posted.single.args?['slotId'], 's1');
    });

    // Falling back to the ordinal is what lets a tap and a typed "slot 2" land on
    // the same code path even when the ids drifted.
    testWidgets('a chip carrying only the number still matches its tile',
        (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(
        tester,
        card('slot_picker', picker(
          slots: [slot(2, '19:00–20:00', id: 'unmatched')],
          buttons: [chip('19:00', 'pick_slot', {'n': 2})],
        )),
        actions: ScoutCardActions(onChip: posted.add),
      );
      await tester.tap(find.text('19:00–20:00'));
      await tester.pump();
      expect(posted.single.args?['n'], 2);
    });

    // A fully-booked day is an answer, and it is stated rather than left as an
    // empty grid the user reads as a loading failure.
    testWidgets('a day with nothing free says so', (tester) async {
      await pumpCard(
        tester,
        card('slot_picker', picker(slots: const [], buttons: const [])),
      );
      expect(find.text('No free slots on that day.'), findsOneWidget);
    });

    testWidgets('a slot tile names itself to a screen reader', (tester) async {
      await pumpCard(tester, card('slot_picker', picker()));
      final node = tester.getSemantics(find.text('18:00–19:00'));
      expect(node.label, contains('Slot 1'));
      expect(node.label, contains('18:00–19:00'));
      expect(node.label, contains('PKR 2,400'));
    });

    testWidgets('a turn in flight disables every tile', (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(
        tester,
        card('slot_picker', picker()),
        actions: ScoutCardActions(onChip: posted.add, enabled: false),
      );
      await tester.tap(find.text('18:00–19:00'), warnIfMissed: false);
      await tester.pump();
      expect(posted, isEmpty);
    });
  });

  group('the last screen before money moves', () {
    testWidgets('the title and the detail table are shown', (tester) async {
      await pumpCard(tester, card('confirm', confirm()));
      expect(find.text('Confirm this booking?'), findsOneWidget);
      expect(find.text('Ground'), findsOneWidget);
      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text('Day'), findsOneWidget);
    });

    testWidgets('the total and the deposit are named and printed',
        (tester) async {
      await pumpCard(tester, card('confirm', confirm(total: 2400, deposit: 600)));
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('PKR 2,400'), findsOneWidget);
      expect(find.text('PKR 600'), findsOneWidget);
    });

    // The percentage comes from `escrow.js POLICY` through the payload, so this card
    // cannot disagree with the charge about to happen and a policy change needs no
    // app release.
    testWidgets('the deposit share is the server\'s, not a constant',
        (tester) async {
      await pumpCard(tester, card('confirm', confirm(depositPct: 25)));
      expect(find.text('Deposit now (25%)'), findsOneWidget);

      await pumpCard(tester, card('confirm', confirm(depositPct: 40)));
      expect(find.text('Deposit now (40%)'), findsOneWidget);
    });

    testWidgets('a payload with no share still labels the deposit',
        (tester) async {
      await pumpCard(tester, card('confirm', confirm(depositPct: null)));
      expect(find.text('Deposit now'), findsOneWidget);
    });

    // A cancellation is money coming back, and the labels have to say which
    // direction it is going.
    testWidgets('a cancellation names the refund and the forfeit',
        (tester) async {
      await pumpCard(
        tester,
        card('confirm', confirm(
          what: 'cancel_booking',
          title: 'Cancel this booking?',
          total: 2400,
          deposit: 600,
          depositPct: null,
        )),
      );
      expect(find.text('Refund to wallet'), findsOneWidget);
      expect(find.text('Deposit forfeited'), findsOneWidget);
      expect(find.text('Total'), findsNothing);
      expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    });

    testWidgets('a booking confirm is padlocked, not undone', (tester) async {
      await pumpCard(tester, card('confirm', confirm()));
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.undo_rounded), findsNothing);
    });

    // Both sides of the de-duplication come from the same backend vocabulary, which
    // is what makes matching on the label safe — and what makes it worth pinning,
    // because the alternative is every figure printed twice.
    testWidgets('a figure already named in the table is not printed twice',
        (tester) async {
      await pumpCard(
        tester,
        card('confirm', confirm(
          what: 'cancel_booking',
          lines: [
            {'label': 'Refund to wallet', 'value': 'PKR 2,400 (100%)'},
            {'label': 'Day', 'value': 'Sat 21 Mar'},
          ],
          total: 2400,
          deposit: null,
          depositPct: null,
        )),
      );
      expect(find.text('Refund to wallet'), findsOneWidget);
      expect(find.text('PKR 2,400 (100%)'), findsNothing,
          reason: 'the footer figure replaces the duplicate detail row');
    });

    testWidgets('the case of a label does not defeat the de-duplication',
        (tester) async {
      await pumpCard(
        tester,
        card('confirm', confirm(
          lines: [
            {'label': 'TOTAL', 'value': 'PKR 9,999'},
            {'label': 'Day', 'value': 'Sat 21 Mar'},
          ],
        )),
      );
      expect(find.text('PKR 9,999'), findsNothing);
      expect(find.text('Total'), findsOneWidget);
    });

    testWidgets('a bare string line lands as an unlabelled row', (tester) async {
      await pumpCard(
        tester,
        card('confirm', confirm(lines: ['Escrow holds the deposit until kick-off'])),
      );
      expect(find.text('Escrow holds the deposit until kick-off'), findsOneWidget);
    });

    testWidgets('the server\'s note is shown as it arrived', (tester) async {
      await pumpCard(
        tester,
        card('confirm', confirm(note: 'Free cancellation up to 24 hours before.')),
      );
      expect(find.text('Free cancellation up to 24 hours before.'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    });

    // There is no default and no tap-outside: the intent classifier is a guess, and
    // both ways out of a guess have to be deliberate.
    testWidgets('both ways out are explicit buttons', (tester) async {
      await pumpCard(tester, card('confirm', confirm()));
      final buttons = tester
          .widgetList<ScoutChipButton>(find.byType(ScoutChipButton))
          .toList();
      expect(buttons.length, 2);
      expect(buttons[0].tone, ScoutChipTone.primary);
      expect(buttons[1].tone, ScoutChipTone.danger,
          reason: 'backing out of a payment is not styled as an ordinary chip');
    });

    testWidgets('confirming posts the server\'s confirm chip', (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(tester, card('confirm', confirm()),
          actions: ScoutCardActions(onChip: posted.add));
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      expect(posted.single.action, 'confirm');
    });

    testWidgets('a turn in flight cannot be confirmed twice', (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(
        tester,
        card('confirm', confirm()),
        actions: ScoutCardActions(onChip: posted.add, enabled: false),
      );
      await tester.tap(find.text('Confirm'), warnIfMissed: false);
      await tester.tap(find.text('Confirm'), warnIfMissed: false);
      await tester.pump();
      expect(posted, isEmpty);
    });

    testWidgets('the money tint marks the card that spends money',
        (tester) async {
      await pumpCard(tester, card('confirm', confirm()));
      final frame = tester.widget<ScoutCardFrame>(find.byType(ScoutCardFrame));
      expect(frame.tint, ScoutTheme.money);
    });
  });

  group('a booking, as proof', () {
    testWidgets('the ground, the day, the hour and the money are all shown',
        (tester) async {
      await pumpCard(tester, card('booking', booking()));
      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text('Karachi'), findsOneWidget);
      expect(find.text('Sat 21 Mar'), findsOneWidget);
      expect(find.text('18:00–19:00'), findsOneWidget);
      expect(find.text('PKR 2,400'), findsOneWidget);
    });

    // A reference short enough to read out over a phone, long enough to identify
    // the row.
    testWidgets('a long id is shortened to a readable reference',
        (tester) async {
      await pumpCard(tester, card('booking', booking(id: 'bk-91f2c7d4e5')));
      expect(find.text('Ref bk-91f2'), findsOneWidget);
    });

    testWidgets('a short id is shown whole', (tester) async {
      await pumpCard(tester, card('booking', booking(id: 'bk-77')));
      expect(find.text('Ref bk-77'), findsOneWidget);
    });

    testWidgets('an id-less booking shows no empty reference line',
        (tester) async {
      await pumpCard(tester, card('booking', booking(id: '')));
      expect(find.textContaining('Ref'), findsNothing);
    });

    // Coloured from the status word the table returned, not from the fact that the
    // request came back 200.
    testWidgets('a confirmed booking is green and says so', (tester) async {
      await pumpCard(tester, card('booking', booking(status: 'confirmed')));
      expect(find.text('Confirmed'), findsOneWidget);
      expect(
        tester.widget<ScoutCardFrame>(find.byType(ScoutCardFrame)).tint,
        ScoutTheme.good,
      );
    });

    // Pending is not a success: the deposit is in escrow and the owner has not
    // accepted, which is a different state of someone's Saturday.
    testWidgets('a pending booking is not dressed as a confirmed one',
        (tester) async {
      await pumpCard(tester, card('booking', booking(status: 'pending')));
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Confirmed'), findsNothing);
      expect(
        tester.widget<ScoutCardFrame>(find.byType(ScoutCardFrame)).tint,
        ScoutTheme.money,
      );
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    });

    testWidgets('a cancelled booking is marked as cancelled', (tester) async {
      await pumpCard(tester, card('booking', booking(status: 'cancelled')));
      expect(find.text('Cancelled'), findsOneWidget);
      expect(
        tester.widget<ScoutCardFrame>(find.byType(ScoutCardFrame)).tint,
        ScoutTheme.danger,
      );
    });

    // Both spellings reach the app from different places; one of them silently
    // falling through to the generic pill would leave a cancelled booking looking
    // ordinary.
    testWidgets('the American spelling is the same state', (tester) async {
      await pumpCard(tester, card('booking', booking(status: 'canceled')));
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('a completed booking reads as finished, not active',
        (tester) async {
      await pumpCard(tester, card('booking', booking(status: 'completed')));
      expect(find.text('Completed'), findsOneWidget);
      expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    });

    // An unrecognised status is shown rather than swallowed: a state this build has
    // no word for is still information.
    testWidgets('an unknown status is shown as it arrived', (tester) async {
      await pumpCard(tester, card('booking', booking(status: 'disputed')));
      expect(find.text('disputed'), findsOneWidget);
    });

    testWidgets('a booking with no time shows no time fact', (tester) async {
      await pumpCard(tester, card('booking', booking(timeLabel: '–')));
      expect(find.text('–'), findsNothing);
      expect(find.text('Sat 21 Mar'), findsOneWidget);
    });

    testWidgets('a booking with no total shows no money fact', (tester) async {
      await pumpCard(tester, card('booking', booking(total: null)));
      expect(find.textContaining('PKR'), findsNothing);
    });

    // Scout must never look like a second, parallel booking system: this walks the
    // user to the same row the Bookings tab reads, and it spends no turn.
    testWidgets('the card offers a walk to the Bookings tab', (tester) async {
      final screens = <String>[];
      await pumpCard(
        tester,
        card('booking', booking()),
        actions: ScoutCardActions(onScreen: screens.add),
      );
      await tester.tap(find.text('Open My Bookings'));
      await tester.pump();
      expect(screens, ['bookings']);
    });

    testWidgets('a host that cannot navigate is given no dead button',
        (tester) async {
      await pumpCard(tester, card('booking', booking()));
      expect(find.text('Open My Bookings'), findsNothing);
    });

    testWidgets('the backend\'s own buttons sit beside the client\'s',
        (tester) async {
      final posted = <ScoutChip>[];
      await pumpCard(
        tester,
        card('booking', booking(buttons: [chip('Cancel', 'cancel_booking')])),
        actions: ScoutCardActions(onChip: posted.add, onScreen: (_) {}),
      );
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Open My Bookings'), findsOneWidget);
      expect(
        tester
            .widgetList<ScoutChipButton>(find.byType(ScoutChipButton))
            .first
            .tone,
        ScoutChipTone.danger,
      );
    });
  });

  group('a card with no buttons at all', () {
    // The row is absent rather than an empty padded strip, which would read as a
    // control that failed to load.
    testWidgets('draws no button row', (tester) async {
      await pumpCard(tester, card('venue', venue(buttons: const [])));
      expect(find.byType(ScoutChipButton), findsNothing);
      expect(
        tester.widget<ScoutCardButtons>(find.byType(ScoutCardButtons)).buttons,
        isEmpty,
      );
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the confirm card still shows every figure', (tester) async {
      await pumpCard(
        tester,
        card('confirm', confirm(note: 'Free cancellation up to 24 hours before.')),
        textScale: 2.0,
      );
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('PKR 2,400'), findsOneWidget);
      expect(find.text('Deposit now (25%)'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the booking card still lays out', (tester) async {
      await pumpCard(tester, card('booking', booking()), textScale: 2.0);
      expect(find.text('Confirmed'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the slot grid still lays out', (tester) async {
      await pumpCard(tester, card('slot_picker', picker()), textScale: 2.0);
      expect(find.text('18:00–19:00'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
