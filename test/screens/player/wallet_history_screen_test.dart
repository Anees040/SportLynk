// Transaction History: the one wallet surface that already has all four states, and
// therefore the one worth pinning as a reference rather than as a defect.
//
// The comment at lib/screens/player/wallet_history_screen.dart:39 records why: this
// screen used to call raw `http.get` with no timeout and fold every failure into an
// empty list, so a 401 and a dead server both rendered "No transactions found" — the
// same defect the rest of the player screens still carry. It was moved onto
// `ApiClient` and given an `_error` field, and the empty branch now switches on that
// field: `Icons.receipt_long_outlined` with "No transactions found" when the ledger is
// genuinely empty, `Icons.cloud_off` with the API's own message and a "Try again"
// button when the read failed (:94-:105).
//
// That distinction is the contract these tests exist to hold. Four of them drive the
// two branches apart — a server error, a dropped connection, an unauthenticated
// session and a genuinely empty ledger — and assert that only the failures offer a
// retry. If a later change collapses them back into one empty state, those four fail,
// which is the whole point of writing them down.
//
// The filter chips are asserted through the `type` query parameter rather than through
// `_filter`, because the contract with the backend is the request. "All" is the case
// that matters: it must send no `type` at all (:45), since `type=all` would match
// nothing and render an empty ledger that looks like a real answer.
//
// Nothing here settles: the loading state is a `CustomLoader`, which animates forever.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/wallet_history_screen.dart';

import '../screen_harness.dart';

/// One `/wallet/transactions` row, in the shape this screen parses.
Map<String, dynamic> txn({
  String id = 't-1',
  String type = 'topup',
  Object? amount = 1000,
  String? createdAt = '2026-03-04T09:15:00.000Z',
  String? counterparty,
  String? reference = 'TRX-abc12345',
}) =>
    {
      'id': id,
      'type': type,
      'amount': amount,
      'created_at': createdAt,
      'counterparty_name': counterparty,
      'reference_id': reference,
      'description': 'Wallet movement',
    };

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok('/wallet/transactions', <dynamic>[]);
  });

  group('while the ledger is being fetched', () {
    testWidgets('a loader is shown rather than an empty ledger', (tester) async {
      // An empty state drawn during the fetch reads as "you have no transactions",
      // which is a claim the screen cannot make yet.
      api.ok('/wallet/transactions', [txn()],
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const WalletHistoryScreen());

      expectLoading(tester);
      expect(find.text('No transactions found'), findsNothing);
    });

    testWidgets('the fetch starts without waiting for a gesture', (tester) async {
      await pumpScreen(tester, const WalletHistoryScreen());

      expect(api.countTo('/wallet/transactions'), 1);
    });

    testWidgets('a full page is asked for', (tester) async {
      // This is the full-history screen, unlike the five-row preview on the wallet
      // itself (:44).
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(api.to('/wallet/transactions').first.param('limit'), '50');
    });
  });

  group('once the ledger arrives', () {
    testWidgets('the screen is titled', (tester) async {
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Transaction History'), findsOneWidget);
    });

    testWidgets('a top-up is labelled and signed as money in', (tester) async {
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Wallet Top-up'), findsOneWidget);
      expect(find.text('+PKR 1000'), findsOneWidget);
    });

    testWidgets('a booking payment is called a deposit and worded as held',
        (tester) async {
      // The ledger calls it a payment; the player is told it is a deposit, because
      // the money is in escrow rather than spent (`txnRowLabel`).
      api.ok('/wallet/transactions', [
        txn(type: 'booking_payment', amount: -2500),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Security Deposit'), findsOneWidget);
      expect(find.text('Frozen 2500'), findsOneWidget);
    });

    testWidgets('an escrow release is labelled, not shown as an unknown type',
        (tester) async {
      // The header records that this screen's old private copy of the label table was
      // missing the escrow types; a released deposit rendered as "Transaction".
      api.ok('/wallet/transactions', [
        txn(type: 'escrow_release', amount: -2500),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Transaction'), findsNothing);
      expect(find.text('PKR 2500'), findsOneWidget);
    });

    testWidgets('an escrow receipt is signed as money in', (tester) async {
      api.ok('/wallet/transactions', [
        txn(type: 'escrow_received', amount: 2500),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Escrow Received'), findsOneWidget);
      expect(find.text('+PKR 2500'), findsOneWidget);
    });

    testWidgets('a debit carries no sign', (tester) async {
      api.ok('/wallet/transactions', [
        txn(type: 'withdrawal', amount: -3000),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('PKR 3000'), findsOneWidget);
      expect(find.text('+PKR 3000'), findsNothing);
    });

    testWidgets('a negative amount is shown as a magnitude', (tester) async {
      // The direction is carried by the wording and the colour, not by a minus in
      // front of the figure (:156 takes `.abs()`).
      api.ok('/wallet/transactions', [
        txn(type: 'no_show_penalty', amount: -750),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('PKR 750'), findsOneWidget);
      expect(find.textContaining('-750'), findsNothing);
    });

    testWidgets('an amount sent as a string is still formatted', (tester) async {
      // Postgres returns NUMERIC as a String; without `asNum` this renders
      // "PKR 1000.00" or throws on `toStringAsFixed`.
      api.ok('/wallet/transactions', [txn(amount: '1000.00')]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('+PKR 1000'), findsOneWidget);
      expect(find.textContaining('1000.00'), findsNothing);
    });

    testWidgets('a row with no type falls back rather than throwing',
        (tester) async {
      // `(t['type'] ?? '').toString()` at :123 is the reason this does not crash the
      // way the wallet preview screen does on the same row.
      api.ok('/wallet/transactions', [
        {'id': 't-1', 'amount': 100, 'created_at': '2026-03-04T09:15:00.000Z'},
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Transaction'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row with no timestamp renders a dash', (tester) async {
      api.ok('/wallet/transactions', [txn(createdAt: null)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('the reference is shown without its prefix', (tester) async {
      // The TRX- prefix is on every row, so repeating it costs width that the label
      // beside it needs.
      api.ok('/wallet/transactions', [txn(reference: 'TRX-abc12345')]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('#abc12345'), findsOneWidget);
    });

    testWidgets('a row with no reference omits the line', (tester) async {
      api.ok('/wallet/transactions', [txn(reference: null)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.textContaining('#'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a counterparty is named on the row', (tester) async {
      api.ok('/wallet/transactions', [
        txn(type: 'booking_payment', amount: -2500, counterparty: 'Clifton Futsal Park'),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Clifton Futsal Park'), findsOneWidget);
    });

    testWidgets('every returned row gets a card', (tester) async {
      api.ok('/wallet/transactions', [
        txn(id: 't-1', type: 'topup', amount: 1000),
        txn(id: 't-2', type: 'refund', amount: 500),
        txn(id: 't-3', type: 'withdrawal', amount: -200),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Wallet Top-up'), findsOneWidget);
      expect(find.text('Refund'), findsOneWidget);
      expect(find.text('Withdrawal'), findsOneWidget);
    });

    testWidgets('the loader is gone', (tester) async {
      api.ok('/wallet/transactions', [txn()]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == 'CustomLoader'),
        findsNothing,
      );
    });

    testWidgets('tapping a row opens the receipt without another request',
        (tester) async {
      // The list response already carries every field the sheet shows.
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);
      final before = api.requests.length;

      await tester.tap(find.text('Wallet Top-up'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('TRX-abc12345'), findsOneWidget);
      expect(api.requests.length, before);
    });
  });

  group('when the ledger is genuinely empty', () {
    testWidgets('the empty state says there is nothing, not that something failed',
        (tester) async {
      api.ok('/wallet/transactions', <dynamic>[]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('No transactions found'), findsOneWidget);
      expect(find.byIcon(Icons.receipt_long_outlined), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsNothing);
    });

    testWidgets('an empty ledger offers no retry', (tester) async {
      // Nothing failed, so a "Try again" here would be a button that cannot change
      // the answer.
      api.ok('/wallet/transactions', <dynamic>[]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Try again'), findsNothing);
    });
  });

  group('when the request fails', () {
    testWidgets('a server error surfaces the message the API sent', (tester) async {
      // The distinction this screen gets right and its siblings do not: a failed read
      // is reported as a failure (:54), not as an empty ledger.
      api.fail('/wallet/transactions', 'Ledger temporarily unavailable');

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('Ledger temporarily unavailable'), findsOneWidget);
      expect(find.text('No transactions found'), findsNothing);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    });

    testWidgets('a failure offers a retry', (tester) async {
      api.fail('/wallet/transactions', 'Ledger temporarily unavailable');

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.widgetWithText(TextButton, 'Try again'), findsOneWidget);
    });

    testWidgets('the retry refetches and can succeed', (tester) async {
      // The failure that matters is a Retry wired to nothing: the button appears, the
      // player taps it, and the same error stays on screen.
      api.fail('/wallet/transactions', 'Ledger temporarily unavailable');

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);
      expect(find.text('Try again'), findsOneWidget);

      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);
      await tester.tap(find.text('Try again'));
      await settleData(tester);

      expect(api.countTo('/wallet/transactions'), 2);
      expect(find.text('Wallet Top-up'), findsOneWidget);
      expect(find.text('Ledger temporarily unavailable'), findsNothing);
    });

    testWidgets('a dropped connection is reported as a failure, not as emptiness',
        (tester) async {
      // This is the exact symptom of a missing `adb reverse`. Every other player
      // screen renders it as an empty state; this one names it and offers a retry,
      // which is what the shared `ApiClient` catch is for.
      api.offline('/wallet/transactions');

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.text('No transactions found'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('an unparseable body is reported as a failure', (tester) async {
      // An HTML error page from a proxy, rather than the envelope the screen expects.
      api.on('/wallet/transactions',
          const FakeResponse(502, '<html>Bad Gateway</html>'));

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the error state clears the loader', (tester) async {
      // A loader left spinning over a failure is the worse bug of the two.
      api.fail('/wallet/transactions', 'Ledger temporarily unavailable');

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == 'CustomLoader'),
        findsNothing,
      );
    });
  });

  group('when there is no session', () {
    testWidgets('the screen asks the player to log in again without a request',
        (tester) async {
      // `_load` returns before touching the network when the token is null (:35).
      // Sending an unauthenticated request would produce a 401 the screen would then
      // have to translate back into this same sentence.
      await pumpScreen(
        tester,
        const WalletHistoryScreen(),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(find.text('Please log in again to see your history.'), findsOneWidget);
      expect(api.countTo('/wallet/transactions'), 0);
    });

    testWidgets('a missing session offers a retry', (tester) async {
      await pumpScreen(
        tester,
        const WalletHistoryScreen(),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('the filter chips', () {
    testWidgets('all four filters are offered', (tester) async {
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Top-ups'), findsOneWidget);
      expect(find.text('Bookings'), findsOneWidget);
      expect(find.text('Refunds'), findsOneWidget);
    });

    testWidgets('the default filter sends no type parameter', (tester) async {
      // `type=all` would match no ledger row and render an empty history that reads
      // as a real answer (:45).
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      expect(api.to('/wallet/transactions').first.param('type'), isNull);
    });

    testWidgets('choosing top-ups filters the request', (tester) async {
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      await tester.tap(find.text('Top-ups'));
      await settleData(tester);

      expect(api.to('/wallet/transactions').last.param('type'), 'topup');
    });

    testWidgets('choosing bookings sends the ledger type, not the chip label',
        (tester) async {
      // The label reads "Bookings"; the column stores `booking_payment`. Sending the
      // label would return nothing.
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      await tester.tap(find.text('Bookings'));
      await settleData(tester);

      expect(api.to('/wallet/transactions').last.param('type'), 'booking_payment');
    });

    testWidgets('choosing refunds filters the request', (tester) async {
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      await tester.tap(find.text('Refunds'));
      await settleData(tester);

      expect(api.to('/wallet/transactions').last.param('type'), 'refund');
    });

    testWidgets('returning to all drops the type parameter again', (tester) async {
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      await tester.tap(find.text('Refunds'));
      await settleData(tester);
      expect(api.to('/wallet/transactions').last.param('type'), 'refund');

      await tester.tap(find.text('All'));
      await settleData(tester);

      expect(api.to('/wallet/transactions').last.param('type'), isNull,
          reason: 'the filter was cleared on screen but not in the query');
    });

    testWidgets('each chip change costs exactly one request', (tester) async {
      // A `setState` that also triggered a rebuild-driven fetch would double every
      // tap (:76).
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);
      final before = api.countTo('/wallet/transactions');

      await tester.tap(find.text('Top-ups'));
      await settleData(tester);

      expect(api.countTo('/wallet/transactions'), before + 1);
    });

    testWidgets('a filter is refetched rather than filtered locally',
        (tester) async {
      // The page is capped at 50 rows, so filtering the loaded list would hide
      // matches that never arrived.
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      api.ok('/wallet/transactions', [txn(id: 't-9', type: 'refund', amount: 500)]);
      await tester.tap(find.text('Refunds'));
      await settleData(tester);

      expect(find.text('Refund'), findsOneWidget);
      expect(find.text('Wallet Top-up'), findsNothing);
    });

    testWidgets('a filter that returns nothing shows the empty state, not an error',
        (tester) async {
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      api.ok('/wallet/transactions', <dynamic>[]);
      await tester.tap(find.text('Refunds'));
      await settleData(tester);

      expect(find.text('No transactions found'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a filter that fails clears the previously loaded rows',
        (tester) async {
      // Leaving the old rows under a failed filter would present them as the result
      // of a filter that never ran (:53).
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);
      expect(find.text('Wallet Top-up'), findsOneWidget);

      api.fail('/wallet/transactions', 'Ledger temporarily unavailable');
      await tester.tap(find.text('Refunds'));
      await settleData(tester);

      expect(find.text('Wallet Top-up'), findsNothing);
      expect(find.text('Ledger temporarily unavailable'), findsOneWidget);
    });

    testWidgets('a chip is a wide enough target to hit', (tester) async {
      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);

      final size = tester.getSize(find.text('Bookings'));
      expect(size.width, greaterThan(0));
    });
  });

  group('refreshing', () {
    testWidgets('a pull refetches the ledger', (tester) async {
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);
      final before = api.countTo('/wallet/transactions');

      await tester.fling(find.text('Wallet Top-up'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(api.countTo('/wallet/transactions'), greaterThan(before));
    });

    testWidgets('a pull keeps the active filter', (tester) async {
      // A refresh that silently dropped the filter would replace what the player
      // asked for with the full ledger.
      api.ok('/wallet/transactions', [txn(id: 't-9', type: 'refund', amount: 500)]);

      await pumpScreen(tester, const WalletHistoryScreen());
      await settleData(tester);
      await tester.tap(find.text('Refunds'));
      await settleData(tester);

      await tester.fling(find.text('Refund'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleData(tester);

      expect(api.to('/wallet/transactions').last.param('type'), 'refund');
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the loaded ledger does not clip', (tester) async {
      api.ok('/wallet/transactions', [
        txn(
          type: 'booking_payment',
          amount: -125000,
          counterparty: 'Karachi Sports Arena, Block 4 Clifton',
        ),
      ]);

      await pumpScreen(tester, const WalletHistoryScreen(), textScale: 2.0);
      await settleData(tester);

      expectNoOverflow(tester);
    });

    testWidgets('the empty state does not clip', (tester) async {
      api.ok('/wallet/transactions', <dynamic>[]);

      await pumpScreen(tester, const WalletHistoryScreen(), textScale: 2.0);
      await settleData(tester);

      expect(find.text('No transactions found'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the error state does not clip', (tester) async {
      api.fail('/wallet/transactions', 'Ledger temporarily unavailable');

      await pumpScreen(tester, const WalletHistoryScreen(), textScale: 2.0);
      await settleData(tester);

      expect(find.text('Try again'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
