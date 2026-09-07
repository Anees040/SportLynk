// Scout wire model tests.
//
// The rule this file holds is the one the whole assistant is defended by: every
// bubble must be able to say where its answer came from, and nothing on screen
// may be a number the server did not send. So `ScoutSource` degrades to
// [ScoutSource.unknown] rather than dropping a message, an unrecognised card
// renders as text rather than blanking a reply, and `matchPct` stays null when no
// ranker scored the row — a coerced 0 would print "0% match" about a venue
// nobody ever scored.
//
// The money cards (`venue`, `slot_picker`, `confirm`, `booking`) are typed
// because a mis-read deposit is a wrong charge; the read-only cards go through
// [CardData], whose every getter is total.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';

void main() {
  group('ScoutSource', () {
    test('every wire value in the contract maps to its own case', () {
      expect(ScoutSource.from('live'), ScoutSource.live);
      expect(ScoutSource.from('policy'), ScoutSource.policy);
      expect(ScoutSource.from('model'), ScoutSource.model);
      expect(ScoutSource.from('kb'), ScoutSource.kb);
      expect(ScoutSource.from('menu'), ScoutSource.menu);
      expect(ScoutSource.from('escalated'), ScoutSource.escalated);
    });

    test('an unrecognised source degrades instead of throwing', () {
      expect(ScoutSource.from('llm'), ScoutSource.unknown);
      expect(ScoutSource.from(null), ScoutSource.unknown);
      expect(ScoutSource.from(7), ScoutSource.unknown);
      expect(ScoutSource.from('LIVE'), ScoutSource.unknown,
          reason: 'the match is exact; the database constraint is lower case');
    });

    test('the wire string round-trips, since it is also the audit column', () {
      for (final s in ScoutSource.values) {
        expect(ScoutSource.from(s.wire), s);
      }
    });

    test('every source can be shown to a user', () {
      for (final s in ScoutSource.values) {
        expect(s.label, isNotEmpty, reason: '${s.wire} has no pill wording');
        expect(s.gloss, isNotEmpty, reason: '${s.wire} has no explanation');
      }
    });
  });

  group('ScoutChip', () {
    test('args survive only as a map, so a malformed chip carries none', () {
      expect(ScoutChip.fromJson({'label': 'Book', 'action': 'confirm'}).args, isNull);
      expect(
        ScoutChip.fromJson({'label': 'Book', 'action': 'confirm', 'args': 'slot'}).args,
        isNull,
      );
      expect(
        ScoutChip.fromJson({
          'label': 'Book',
          'action': 'pick_slot',
          'args': {'slotId': 's1'},
        }).args!['slotId'],
        's1',
      );
    });

    test('a chip with no action or no label is dropped, never drawn dead', () {
      final chips = ScoutChip.listFrom([
        {'label': 'Book', 'action': 'confirm'},
        {'label': 'Nothing', 'action': ''},
        {'label': '', 'action': 'confirm'},
        'garbage',
        null,
      ]);
      expect(chips.length, 1);
      expect(chips.single.action, 'confirm');
    });

    test('a non-list chips block yields no chips', () {
      expect(ScoutChip.listFrom(null), isEmpty);
      expect(ScoutChip.listFrom('Book'), isEmpty);
    });
  });

  group('formatPkr', () {
    test('an absent amount reads as a dash, not as zero rupees', () {
      expect(formatPkr(null), '—');
    });

    test('thousands are grouped and paisa dropped', () {
      expect(formatPkr(0), 'PKR 0');
      expect(formatPkr(999), 'PKR 999');
      expect(formatPkr(2400), 'PKR 2,400');
      expect(formatPkr(2400.4), 'PKR 2,400');
      expect(formatPkr(1234567), 'PKR 1,234,567');
    });

    test('the sign sits inside the prefix, unlike the report formatter', () {
      expect(formatPkr(-2400), 'PKR -2,400');
    });
  });

  group('CardData', () {
    test('a non-map payload still gives a renderable, empty reader', () {
      final d = CardData.from('venue');
      expect(d.raw, isEmpty);
      expect(d.str('name', or: 'Ground'), 'Ground');
      expect(d.moneyOrNull('price'), isNull);
      expect(d.strings('reasons'), isEmpty);
      expect(d.buttons(), isEmpty);
      expect(d.rows('slots'), isEmpty);
    });

    test('str trims and falls back; strOrNull treats blank as absent', () {
      final d = CardData.from({'name': '  F-11 Arena  ', 'city': '   '});
      expect(d.str('name'), 'F-11 Arena');
      expect(d.str('missing', or: 'Ground'), 'Ground');
      expect(d.str('missing'), '');
      expect(d.strOrNull('city'), isNull);
      expect(d.strOrNull('name'), 'F-11 Arena');
    });

    test('money reads a pg decimal string; moneyOrNull keeps absence absent', () {
      final d = CardData.from({'price': '2400.00', 'rating': 0});
      expect(d.money('price'), 2400.0);
      expect(d.money('missing'), 0.0);
      expect(d.moneyOrNull('missing'), isNull);
      expect(d.moneyOrNull('rating'), 0.0,
          reason: 'a rated-zero and an unrated venue are different facts');
    });

    test('count and intOrNull differ on absence, not on parsing', () {
      final d = CardData.from({'totalReviews': '12', 'seats': 4.6});
      expect(d.count('totalReviews'), 12);
      expect(d.count('missing'), 0);
      expect(d.count('missing', or: 3), 3);
      expect(d.intOrNull('missing'), isNull);
      expect(d.intOrNull('seats'), 5);
    });

    test('flag requires a literal true', () {
      final d = CardData.from({'a': true, 'b': 'true', 'c': 1});
      expect(d.flag('a'), isTrue);
      expect(d.flag('b'), isFalse);
      expect(d.flag('c'), isFalse);
      expect(d.flag('missing'), isFalse);
    });

    test('pctOrNull stays null when nothing ranked the row', () {
      expect(CardData.from({}).pctOrNull, isNull);
      expect(CardData.from({'matchPct': null}).pctOrNull, isNull);
      expect(CardData.from({'matchPct': 87}).pctOrNull, 87);
      expect(CardData.from({'matchPct': '87'}).pctOrNull, 87);
      expect(CardData.from({'matchPct': 0}).pctOrNull, 0,
          reason: 'a scored zero is a real result');
    });

    test('has answers on presence, and a null value counts as absent', () {
      final d = CardData.from({'photo': null, 'name': 'X'});
      expect(d.has('name'), isTrue);
      expect(d.has('photo'), isFalse);
    });

    test('strings drops blanks and rejects a non-list', () {
      expect(CardData.from({'reasons': ['  near you ', '', '   ', 'cheap']}).strings('reasons'),
          ['near you', 'cheap']);
      expect(CardData.from({'reasons': 'near you'}).strings('reasons'), isEmpty);
    });

    test('rows skips non-map entries', () {
      final rows = CardData.from({
        'slots': [
          {'n': 1},
          'garbage',
          {'n': 2},
        ],
      }).rows('slots');
      expect(rows.length, 2);
      expect(rows.last.count('n'), 2);
    });

    test('label prefers the backend wording over formatting locally', () {
      expect(
        CardData.from({'totalLabel': 'PKR 2,400 for 1 hour', 'total': 2400})
            .label('totalLabel', 'total'),
        'PKR 2,400 for 1 hour',
      );
      expect(CardData.from({'total': 2400}).label('totalLabel', 'total'), 'PKR 2,400');
      expect(CardData.from({}).label('totalLabel', 'total'), '—');
    });
  });

  group('ScoutCard', () {
    test('the twelve declared types are all known', () {
      expect(ScoutCardType.all.length, 12);
      for (final t in ScoutCardType.all) {
        expect(ScoutCard(type: t, data: const CardData({})).isKnown, isTrue,
            reason: '$t is declared but not recognised');
      }
    });

    test('a card this build has no widget for is carried, marked unknown', () {
      final c = ScoutCard.fromJson({'type': 'leaderboard', 'data': {'x': 1}});
      expect(c.isKnown, isFalse);
      expect(c.data.count('x'), 1);
    });

    test('a typeless card is dropped, since nothing could render it', () {
      final cards = ScoutCard.listFrom([
        {'type': 'venue', 'data': {}},
        {'data': {}},
        'garbage',
      ]);
      expect(cards.length, 1);
      expect(cards.single.type, ScoutCardType.venue);
    });

    test('a missing data block yields an empty reader, not a null one', () {
      expect(ScoutCard.fromJson({'type': 'venue'}).data.raw, isEmpty);
    });
  });

  group('VenueCardData', () {
    test('prices, ratings and coordinates all arrive as pg strings', () {
      final v = VenueCardData.of(CardData.from({
        'id': 'v1',
        'name': 'F-11 Football Arena',
        'pricePerHour': '2400.00',
        'rating': '4.60',
        'totalReviews': '18',
        'lat': '33.6844',
        'lng': '73.0479',
      }));
      expect(v.pricePerHour, 2400.0);
      expect(v.rating, 4.6);
      expect(v.totalReviews, 18);
      expect(v.lat, 33.6844);
      expect(v.hasPin, isTrue);
    });

    test('an unrated venue keeps a null rating, never a 0.0 star line', () {
      final v = VenueCardData.of(CardData.from({'id': 'v1'}));
      expect(v.rating, isNull);
      expect(v.pricePerHour, isNull);
      expect(v.totalReviews, 0);
      expect(v.name, 'Ground');
    });

    test('a half-located venue draws no pin', () {
      expect(VenueCardData.of(CardData.from({'lat': 33.6})).hasPin, isFalse);
      expect(VenueCardData.of(CardData.from({'lng': 73.0})).hasPin, isFalse);
    });

    test('matchPct and reasons are absent unless the recommender ranked', () {
      final plain = VenueCardData.of(CardData.from({'id': 'v1'}));
      expect(plain.matchPct, isNull);
      expect(plain.reasons, isEmpty);

      final ranked = VenueCardData.of(CardData.from({
        'id': 'v1',
        'matchPct': 87,
        'reasons': ['near F-11', 'you book futsal'],
      }));
      expect(ranked.matchPct, 87);
      expect(ranked.reasons.length, 2);
    });
  });

  group('SlotOption', () {
    test('the label falls back to the two times joined', () {
      final s = SlotOption.of(CardData.from({
        'n': 2,
        'slotId': 's2',
        'startTime': '18:00',
        'endTime': '19:00',
      }));
      expect(s.label, '18:00–19:00');
      expect(s.n, 2);
    });

    test('the backend label wins when it sent one', () {
      final s = SlotOption.of(CardData.from({
        'startTime': '18:00',
        'endTime': '19:00',
        'label': '6:00 pm – 7:00 pm',
      }));
      expect(s.label, '6:00 pm – 7:00 pm');
    });

    test('priceLabel is formatted locally only when absent', () {
      expect(
        SlotOption.of(CardData.from({'price': '2400.00'})).priceLabel,
        'PKR 2,400',
      );
      expect(
        SlotOption.of(CardData.from({'price': 2400, 'priceLabel': 'PKR 2,400 / hour'}))
            .priceLabel,
        'PKR 2,400 / hour',
      );
      expect(SlotOption.of(CardData.from({})).priceLabel, '—');
    });
  });

  group('SlotPickerData', () {
    SlotPickerData picker() => SlotPickerData.of(CardData.from({
          'venueId': 'v1',
          'date': '2026-09-12',
          'slots': [
            {'n': 1, 'slotId': 's1', 'startTime': '17:00', 'endTime': '18:00'},
            {'n': 2, 'slotId': 's2', 'startTime': '18:00', 'endTime': '19:00'},
          ],
          'buttons': [
            {'label': '5 pm', 'action': 'pick_slot', 'args': {'slotId': 's1', 'n': 1}},
            {'label': '6 pm', 'action': 'pick_slot', 'args': {'slotId': 's2', 'n': 2}},
          ],
        }));

    test('the date label falls back to the raw date', () {
      final p = picker();
      expect(p.dateLabel, '2026-09-12');
      expect(p.venueName, 'Ground');
      expect(p.slots.length, 2);
    });

    test('chipFor returns the backend chip for that slot, not a rebuilt one', () {
      final p = picker();
      final chip = p.chipFor(p.slots.last);
      expect(chip, isNotNull);
      expect(chip!.args!['slotId'], 's2');
      expect(chip.label, '6 pm');
    });

    test('a slot the backend minted no chip for yields null, so nothing is faked', () {
      final p = SlotPickerData.of(CardData.from({
        'slots': [
          {'n': 1, 'slotId': 's1'},
        ],
      }));
      expect(p.chipFor(p.slots.single), isNull);
    });

    test('the ordinal is the fallback match when the chip carries no slotId', () {
      final p = SlotPickerData.of(CardData.from({
        'slots': [
          {'n': 2, 'slotId': 's2'},
        ],
        'buttons': [
          {'label': 'second', 'action': 'pick_slot', 'args': {'n': '2'}},
        ],
      }));
      expect(p.chipFor(p.slots.single)!.label, 'second');
    });
  });

  group('ConfirmLine', () {
    test('a labelled row keeps both halves for the table', () {
      final lines = ConfirmLine.listFrom([
        {'label': 'Day', 'value': 'Sat 30 Aug'},
        {'label': 'Refund to wallet', 'value': 'PKR 2,500 (100%)'},
      ]);
      expect(lines.length, 2);
      expect(lines.first.label, 'Day');
      expect(lines.last.value, 'PKR 2,500 (100%)');
    });

    test('a bare string still renders, as one unlabelled row', () {
      final lines = ConfirmLine.listFrom(['Cancelling within 24 hours']);
      expect(lines.single.label, '');
      expect(lines.single.value, 'Cancelling within 24 hours');
    });

    test('an entry with neither half is dropped rather than drawn blank', () {
      final lines = ConfirmLine.listFrom([
        {'label': '', 'value': '   '},
        '',
        null,
        {'label': 'Day', 'value': ''},
      ]);
      expect(lines.length, 1);
      expect(lines.single.label, 'Day');
    });

    test('a non-list lines block yields no rows', () {
      expect(ConfirmLine.listFrom(null), isEmpty);
      expect(ConfirmLine.listFrom('Day: Sat'), isEmpty);
    });
  });

  group('ConfirmData', () {
    test('the amounts come from the server and are not recomputed', () {
      final c = ConfirmData.of(CardData.from({
        'what': 'book',
        'title': 'Confirm booking',
        'total': '2400.00',
        'deposit': '480.00',
        'depositPct': 20,
        'totalLabel': 'PKR 2,400 for 1 hour',
      }));
      expect(c.total, 2400.0);
      expect(c.deposit, 480.0);
      expect(c.depositPct, 20);
      expect(c.totalLabel, 'PKR 2,400 for 1 hour',
          reason: 'the deposit share is quoted, never derived on the phone');
    });

    test('a missing amount reads as a dash, so no charge is implied', () {
      final c = ConfirmData.of(CardData.from({'what': 'cancel'}));
      expect(c.total, isNull);
      expect(c.deposit, isNull);
      expect(c.depositPct, isNull);
      expect(c.totalLabel, '—');
      expect(c.title, 'Confirm');
      expect(c.note, isNull);
    });

    test('isPayment separates the flow that spends money from a cancellation', () {
      expect(ConfirmData.of(CardData.from({'what': 'book'})).isPayment, isTrue);
      expect(ConfirmData.of(CardData.from({'what': 'rebook'})).isPayment, isTrue);
      expect(ConfirmData.of(CardData.from({'what': 'cancel'})).isPayment, isFalse);
      expect(ConfirmData.of(CardData.from({})).isPayment, isFalse);
    });
  });

  group('BookingCardData', () {
    test('the status is lower-cased so one comparison serves every screen', () {
      expect(BookingCardData.of(CardData.from({'status': 'CONFIRMED'})).status, 'confirmed');
      expect(BookingCardData.of(CardData.from({})).status, 'pending');
    });

    test('the time label falls back to the two times joined', () {
      final b = BookingCardData.of(CardData.from({
        'startTime': '18:00',
        'endTime': '19:00',
        'date': '2026-09-12',
      }));
      expect(b.timeLabel, '18:00–19:00');
      expect(b.dateLabel, '2026-09-12');
      expect(b.venueName, 'Ground');
    });

    test('the QR payload stays null until the booking has one', () {
      expect(BookingCardData.of(CardData.from({})).qr, isNull);
      expect(BookingCardData.of(CardData.from({'qr': ''})).qr, isNull);
      expect(BookingCardData.of(CardData.from({'qr': 'BK-1:abc'})).qr, 'BK-1:abc');
    });

    test('the total is read as a pg decimal string', () {
      final b = BookingCardData.of(CardData.from({'total': '2400.00', 'deposit': '480.00'}));
      expect(b.total, 2400.0);
      expect(b.deposit, 480.0);
      expect(b.totalLabel, 'PKR 2,400');
    });
  });

  group('ScoutFsm', () {
    test('every state maps from its wire value', () {
      expect(ScoutFsm.from('idle'), ScoutFsm.idle);
      expect(ScoutFsm.from('slot_filling'), ScoutFsm.slotFilling);
      expect(ScoutFsm.from('awaiting_choice'), ScoutFsm.awaitingChoice);
      expect(ScoutFsm.from('awaiting_confirm'), ScoutFsm.awaitingConfirm);
    });

    test('an unknown state falls back to idle, which blocks nothing', () {
      expect(ScoutFsm.from('awaiting_payment'), ScoutFsm.idle);
      expect(ScoutFsm.from(null), ScoutFsm.idle);
      expect(ScoutFsm.idle.isWaiting, isFalse);
      expect(ScoutFsm.awaitingConfirm.isWaiting, isTrue);
    });
  });
}
