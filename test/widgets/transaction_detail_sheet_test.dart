// TransactionDetailSheet, and the shared ledger vocabulary it is built on.
//
// The five functions at the top of this file's subject are the reason it exists. The
// label, icon and sign maps were once written out three times over — in wallet_screen,
// wallet_history_screen and owner_wallet_screen — and all three copies were missing
// `escrow_release` and `escrow_received`, so a late cancellation, or an owner receiving a
// deposit, rendered as a bare "Transaction" with a generic arrow. The first group below
// is therefore a completeness sweep over the whole `txn_type` enum rather than a handful
// of spot checks: a thirteenth type added to the database and not to these maps has to
// fail here, not in a screenshot.
//
// The sign table has to match the backend exactly, because the consequence of getting it
// wrong is a receipt that says money arrived when it left. It is pinned as a set in both
// directions, so adding a type to the credit list without adding it here fails, and so
// does the reverse.
//
// Escrow is the sheet's other job. A booking payment is money held, not money spent, so
// it is renamed for the reader, coloured with the warning shade rather than the error
// one, and given the sentence that explains when the money comes back — while a
// tournament entry fee, which is the same ledger shape, keeps its own name because
// calling it a security deposit would be a lie.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/transaction_detail_sheet.dart';

import 'widget_harness.dart';

/// The `txn_type` enum in full: seven from `schema.sql`, two from migration 007 and
/// three from migration 019.
const _types = [
  'topup',
  'booking_payment',
  'security_deposit',
  'refund',
  'no_show_penalty',
  'owner_payout',
  'withdrawal',
  'escrow_release',
  'escrow_received',
  'tournament_entry',
  'tournament_commission',
  'tournament_prize',
];

void main() {
  group('the twelve ledger types', () {
    // The exact regression the one-copy rewrite was for.
    test('every type has a name of its own', () {
      for (final type in _types) {
        expect(txnLabel(type), isNot('Transaction'), reason: type);
      }
      expect(_types.map(txnLabel).toSet().length, _types.length,
          reason: 'no two types share a label');
    });

    test('every type has a glyph of its own', () {
      for (final type in _types) {
        expect(txnIcon(type), isNot(Icons.swap_horiz), reason: type);
      }
    });

    // Migration 007 and migration 019: the two batches the triplicated maps missed.
    test('the escrow pair and the tournament trio are named', () {
      expect(txnLabel('escrow_release'), 'Escrow Released');
      expect(txnLabel('escrow_received'), 'Escrow Received');
      expect(txnLabel('tournament_entry'), 'Tournament Entry');
      expect(txnLabel('tournament_commission'), 'Tournament Earnings');
      expect(txnLabel('tournament_prize'), 'Prize Money');
    });

    // A type this build has never heard of still has to render as a row.
    test('an unknown type falls back rather than blanking', () {
      expect(txnLabel('cashback_2027'), 'Transaction');
      expect(txnIcon('cashback_2027'), Icons.swap_horiz);
      expect(txnLabel(''), 'Transaction');
      expect(txnIcon(''), Icons.swap_horiz);
    });
  });

  group('which way the money went', () {
    test('the credit set is exactly the five the backend logs positive', () {
      expect(_types.where(isCreditTxn).toSet(), {
        'topup',
        'refund',
        'escrow_received',
        'tournament_commission',
        'tournament_prize',
      });
    });

    test('the held set is exactly the two that move into frozen', () {
      expect(_types.where(isHeldTxn).toSet(), {
        'booking_payment',
        'tournament_entry',
      });
    });

    // "Money in" and "held in escrow" are different sentences and different colours;
    // a type answering to both would render as one of them at random.
    test('nothing is both credited and held', () {
      for (final type in _types) {
        expect(isCreditTxn(type) && isHeldTxn(type), isFalse, reason: type);
      }
    });

    test('the arrows follow the money', () {
      expect(txnIcon('topup'), Icons.south_west);
      expect(txnIcon('escrow_received'), Icons.south_west);
      expect(txnIcon('withdrawal'), Icons.north_east);
      expect(txnIcon('booking_payment'), Icons.north_east);
    });
  });

  group('the ledger\'s name and the reader\'s name', () {
    test('a booking payment is presented as the deposit it is', () {
      expect(txnLabel('booking_payment'), 'Booking Payment');
      expect(txnRowLabel('booking_payment'), 'Security Deposit');
    });

    test('an entry fee keeps its own name', () {
      expect(txnRowLabel('tournament_entry'), 'Tournament Entry');
    });

    test('no other type is renamed', () {
      for (final type in _types.where((t) => t != 'booking_payment')) {
        expect(txnRowLabel(type), txnLabel(type), reason: type);
      }
    });
  });

  // The backend stores plain UTC and serialises it with a `Z`; these screens once showed
  // every time five hours behind because the conversion was left out.
  group('a timestamp', () {
    test('a UTC instant is shown in the phone\'s own zone', () {
      final local = DateTime.parse('2026-03-14T14:30:00Z').toLocal();
      final h = local.hour.toString().padLeft(2, '0');
      final min = local.minute.toString().padLeft(2, '0');
      expect(fmtTxnDate('2026-03-14T14:30:00Z'),
          '${local.day} Mar, ${local.year} • $h:$min');
    });

    test('the same instant written with an offset reads the same', () {
      expect(fmtTxnDate('2026-03-14T19:30:00+05:00'),
          fmtTxnDate('2026-03-14T14:30:00Z'));
    });

    test('a timestamp with no zone is taken as the wall clock it is', () {
      expect(fmtTxnDate('2026-03-14T14:30:00'), '14 Mar, 2026 • 14:30');
    });

    test('a missing or unparseable date is a dash, not a crash', () {
      expect(fmtTxnDate(null), '—');
      expect(fmtTxnDate('last Tuesday'), '—');
      expect(fmtSlotDate(null), '—');
    });

    // A date-only column carries no time, so none is invented for it.
    test('a slot date drops the clock', () {
      expect(fmtSlotDate('2026-03-20'), '20 Mar, 2026');
      expect(fmtTxnDate('2026-03-20'), '20 Mar, 2026 • 00:00');
    });

    test('a TIME column is trimmed to the hour and minute', () {
      expect(fmtSlotTime('18:00:00'), '18:00');
      expect(fmtSlotTime('18:00'), '18:00');
      expect(fmtSlotTime('9:0'), '9:0', reason: 'too short to trim, so it passes through');
      expect(fmtSlotTime(null), '');
    });
  });

  group('the receipt', () {
    Map<String, dynamic> txn({
      String type = 'topup',
      num amount = 2500,
      String? reference = 'TRX-9f3a1c22',
      String? createdAt = '2026-03-14T14:30:00Z',
      String? description,
      String? counterparty,
      String? venue,
      String? slotDate,
      String? start,
      String? end,
      num? balanceAfter,
    }) =>
        {
          'type': type,
          'amount': amount,
          'reference_id': reference,
          'created_at': createdAt,
          'description': description,
          'counterparty_name': counterparty,
          'venue_name': venue,
          'slot_date': slotDate,
          'start_time': start,
          'end_time': end,
          'balance_after': balanceAfter,
        };

    Future<void> pumpSheet(WidgetTester tester, Map<String, dynamic> row,
            {double textScale = 1.0}) =>
        pumpApp(
          tester,
          Scaffold(
            backgroundColor: Colors.white,
            body: TransactionDetailSheet(txn: row),
          ),
          textScale: textScale,
        );

    testWidgets('a top-up is money in, and carries no booking', (tester) async {
      await pumpSheet(tester, txn());
      expect(find.text('Wallet Top-up'), findsOneWidget);
      expect(find.text('Money in'), findsOneWidget);
      expect(find.text('+PKR 2500'), findsOneWidget);
      expect(tester.widget<Text>(find.text('+PKR 2500')).style!.color,
          AppColors.success);
      expect(tester.widget<Icon>(find.byIcon(Icons.south_west)).color,
          AppColors.success);
      expect(find.text('TRX-9f3a1c22'), findsOneWidget);
      for (final absent in ['Venue', 'Slot', 'Details', 'Counterparty',
          'Balance after']) {
        expect(find.text(absent), findsNothing,
            reason: 'a top-up has no $absent, so the row is left out entirely');
      }
      expect(find.byIcon(Icons.info_outline), findsNothing,
          reason: 'only escrow and withdrawal carry a note');
    });

    // Held, not spent: the rename, the warning shade and the lock all say the same thing.
    testWidgets('a booking payment reads as money held', (tester) async {
      await pumpSheet(tester, txn(type: 'booking_payment', amount: 1200));
      expect(find.text('Security Deposit'), findsOneWidget);
      expect(find.text('Booking Payment'), findsNothing,
          reason: 'the ledger\'s own name is not what the reader is shown');
      expect(find.text('Held in escrow'), findsOneWidget);
      expect(find.text('−PKR 1200'), findsOneWidget);
      expect(tester.widget<Text>(find.text('−PKR 1200')).style!.color,
          AppColors.warning);
      expect(tester.widget<Icon>(find.byIcon(Icons.lock_outline)).color,
          AppColors.warning,
          reason: 'the lock replaces the type\'s own arrow');
      expect(
          find.text('This amount is held in escrow, not spent. It is released when '
              'you check in at the venue.'),
          findsOneWidget);
    });

    testWidgets('a booking payment carries the venue and the slot it paid for',
        (tester) async {
      await pumpSheet(
          tester,
          txn(
            type: 'booking_payment',
            amount: 1200,
            venue: 'Arena One',
            slotDate: '2026-03-20',
            start: '18:00:00',
            end: '19:00:00',
          ));
      expect(find.text('Venue'), findsOneWidget);
      expect(find.text('Arena One'), findsOneWidget);
      expect(find.text('20 Mar, 2026, 18:00 – 19:00'), findsOneWidget);
    });

    testWidgets('a slot with no times is dated and nothing more', (tester) async {
      await pumpSheet(tester,
          txn(type: 'booking_payment', venue: 'Arena One', slotDate: '2026-03-20'));
      expect(find.text('20 Mar, 2026'), findsOneWidget);
    });

    // Reference and date are the two rows every receipt has, so they show a dash
    // rather than disappearing when the ledger row is missing one.
    testWidgets('a missing reference is a dash, not a gap', (tester) async {
      await pumpSheet(tester, txn(reference: null));
      expect(find.text('Reference'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('the optional rows appear only when the join carried them',
        (tester) async {
      await pumpSheet(
          tester,
          txn(
            description: 'Refund for cancelled booking',
            counterparty: 'Arena One',
            balanceAfter: 8300,
          ));
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Refund for cancelled booking'), findsOneWidget);
      expect(find.text('Counterparty'), findsOneWidget);
      expect(find.text('Balance after'), findsOneWidget);
      expect(find.text('PKR 8300'), findsOneWidget);
    });

    // The backend logs debits negative and credits positive; the sheet prints the sign
    // its type earns and the amount's own magnitude, so a row stored either way reads
    // the same.
    testWidgets('the sign comes from the type, not from the stored number',
        (tester) async {
      await pumpSheet(tester, txn(type: 'withdrawal', amount: -500));
      expect(find.text('−PKR 500'), findsOneWidget);
      expect(find.text('Money out'), findsOneWidget);
      expect(tester.widget<Text>(find.text('−PKR 500')).style!.color,
          AppColors.error);
    });

    testWidgets('prize money is credited despite being a tournament type',
        (tester) async {
      await pumpSheet(tester, txn(type: 'tournament_prize', amount: 15000));
      expect(find.text('Prize Money'), findsOneWidget);
      expect(find.text('+PKR 15000'), findsOneWidget);
      expect(find.text('Money in'), findsOneWidget);
      expect(find.byIcon(Icons.emoji_events_outlined), findsOneWidget);
    });

    group('the notes', () {
      testWidgets('an entry fee gets its own sentence, not the booking one',
          (tester) async {
        await pumpSheet(tester, txn(type: 'tournament_entry', amount: 3000));
        expect(find.text('Held in escrow'), findsOneWidget);
        expect(
            find.text('This entry fee is held, not spent. You get it back in full if '
                'you withdraw before the registration deadline, if the organiser '
                'turns your team down, or if the tournament is called off. Once '
                'the bracket is drawn it goes into the prize pool.'),
            findsOneWidget);
        expect(
            find.text('This amount is held in escrow, not spent. It is released when '
                'you check in at the venue.'),
            findsNothing);
      });

      testWidgets('a withdrawal says when the payout lands', (tester) async {
        await pumpSheet(tester, txn(type: 'withdrawal', amount: 500));
        expect(
            find.text('The amount left your available balance when you requested the '
                'withdrawal. Payout completes within 24 hours.'),
            findsOneWidget);
      });

      testWidgets('an organiser\'s earnings say what they cover', (tester) async {
        await pumpSheet(tester, txn(type: 'tournament_commission', amount: 4000));
        expect(
            find.text('This covers the venue hours your fixtures reserved, plus your '
                'margin on top. The prize money is held separately until the '
                'final is settled.'),
            findsOneWidget);
        expect(find.text('Money in'), findsOneWidget);
      });

      testWidgets('a refund needs no explanation', (tester) async {
        await pumpSheet(tester, txn(type: 'refund', amount: 1200));
        expect(find.byIcon(Icons.info_outline), findsNothing);
      });
    });

    // Pinned as it behaves, not as it should. The headline is a fixed 46px circle, an
    // `Expanded` holding the title, and an unflexed amount: at a doubled text scale the
    // amount keeps its full 326px of a 364px row, so the `Expanded` is starved to zero —
    // the title and "Held in escrow" render at no width at all — and the row still
    // overflows by the remainder. The detail rows are the same shape with the flex on the
    // other side, which is why "Balance after" squeezes its own figure down to a few
    // pixels instead of overflowing. Both are against the project's rule that text scales
    // without clipping; giving the amount a `Flexible` and the row labels a share of the
    // width is what would turn these expectations green.
    testWidgets('at a doubled text scale the headline starves its own title',
        (tester) async {
      useDeviceSurface(tester);
      await pumpSheet(
          tester,
          txn(
            type: 'booking_payment',
            amount: 1200,
            venue: 'Arena One',
            slotDate: '2026-03-20',
            start: '18:00:00',
            end: '19:00:00',
            balanceAfter: 8300,
          ),
          textScale: 2.0);
      expect(tester.getSize(find.text('Security Deposit')).width, 0,
          reason: 'the unflexed amount takes the row: transaction_detail_sheet.dart:229');
      expect(tester.getSize(find.text('Held in escrow')).width, 0);
      expect(
        tester.takeException().toString(),
        contains('overflowed'),
        reason: 'and the amount overflows what is left',
      );
    });
  });
}
