// My Wallet: the screen that reports real money, and the one where a wrong number is
// not a cosmetic bug.
//
// Two figures are shown side by side and they come from different columns —
// `balance` and `frozen_balance` (lib/screens/player/wallet_screen.dart:179 and :207).
// The tests below fix which column feeds which tile, because the failure mode of
// swapping them is silent: a player with 5,000 spendable and 2,500 held would be shown
// a plausible pair of numbers that happen to be the wrong way round. Both go through
// `asNum`, which matters because Postgres returns `NUMERIC` as a String — a raw
// "2500.00" on the balance card, or a crash on `toStringAsFixed`, is the class of
// failure `lib/utils/num_util.dart` exists to end.
//
// The four mandated states are, again, three. `_load` (:43) sets `_wallet = null` when
// the envelope reports failure and `catch (_)` (:49) clears the spinner without
// recording anything, and because the balance is rendered as `asNum(_wallet?['balance'])`
// the screen answers a failed read with **PKR 0** — not an empty state, not an error,
// but a confident and wrong statement about the player's money. That is the most
// serious instance of the missing-error-state defect found so far, and four tests pin
// it as behaviour with the line and the fix named.
//
// The top-up path is asserted through the request it posts rather than the sheet's
// private state. Validation lives in the sheet's button (:405) and rejects anything
// outside PKR 100–50,000, so the tests drive the boundary values: 99 and 50,001 must
// send nothing, 100 and 50,000 must send. `_topUp` also opens a three-second
// simulation dialog (:59) before posting, which means every top-up test has to advance
// the clock past it — a test that pumped only `settleData` would assert on a screen
// still showing "Initializing secure gateway...".
//
// Nothing here settles: both the screen's loading state and the simulation dialog are
// `CircularProgressIndicator`s, and the dialog's own status text advances on three
// chained delays.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/wallet_screen.dart';

import '../screen_harness.dart';

/// The `/wallet/me` payload.
Map<String, dynamic> wallet({Object? balance = 5000, Object? frozen = 2500}) => {
      'id': 'w-1',
      'user_id': 'u-1',
      'balance': balance,
      'frozen_balance': frozen,
    };

/// One `/wallet/transactions` row.
Map<String, dynamic> txn({
  String id = 't-1',
  String type = 'topup',
  Object? amount = 1000,
  String? createdAt = '2026-03-04T09:15:00.000Z',
  String? description,
}) =>
    {
      'id': id,
      'type': type,
      'amount': amount,
      'created_at': createdAt,
      'description': description,
      'reference_id': 'TRX-abc12345',
    };

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // Two independent requests on every load. Both are stubbed by default so a test
    // that says nothing about one is not silently asserting against a 404.
    api.ok('/wallet/me', wallet());
    api.ok('/wallet/transactions', <dynamic>[]);
    // The balance card packs the fixed label "AVAILABLE FUNDS" into a half-width tile
    // (lib/screens/player/wallet_screen.dart:175). Under the test font, whose glyphs are
    // square ems roughly twice the width of the app's Poppins, that label does not fit
    // the tile at phone width and the card reports a RenderFlex overflow the app never
    // shows in Poppins. The card is drawn by every loaded-state test here, so the
    // harness artifact is absorbed once for the file rather than case by case.
    ignoreOverflow();
  });

  /// Advances past the three-second payment simulation and the POST that follows.
  Future<void> settleTopUp(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await settleData(tester);
  }

  group('while the wallet is being fetched', () {
    testWidgets('a spinner is shown rather than a zero balance', (tester) async {
      // A balance card drawn during the fetch would read "PKR 0", which is a claim
      // about the player's money the screen cannot make yet.
      api.ok('/wallet/me', wallet(), delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const WalletScreen());

      expectLoading(tester);
      expect(find.text('PKR 0'), findsNothing);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('the fetch starts without waiting for a gesture', (tester) async {
      await pumpScreen(tester, const WalletScreen());

      expect(api.countTo('/wallet/me'), 1);
    });

    testWidgets('both requests are made on one load', (tester) async {
      // The balance and the recent rows are separate endpoints; a screen that fetched
      // only one would render half a wallet.
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(api.countTo('/wallet/me'), 1);
      expect(api.countTo('/wallet/transactions'), 1);
    });

    testWidgets('the recent transactions are asked for in a short page',
        (tester) async {
      // This screen shows a preview and links out to the full history, so it must not
      // pull the whole ledger (:37).
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(api.to('/wallet/transactions').first.param('limit'), '5');
    });
  });

  group('once the wallet arrives', () {
    testWidgets('the total balance is shown', (tester) async {
      api.ok('/wallet/me', wallet(balance: 5000, frozen: 2500));

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('TOTAL BALANCE'), findsOneWidget);
      // The same figure feeds the headline and the available tile (:160 and :179).
      expect(find.text('PKR 5000'), findsNWidgets(2));
    });

    testWidgets('the frozen balance comes from its own column', (tester) async {
      // The failure this prevents is a silent swap: two plausible numbers in the
      // wrong tiles would misreport what the player can actually spend.
      api.ok('/wallet/me', wallet(balance: 5000, frozen: 2500));

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('FROZEN'), findsOneWidget);
      expect(find.text('PKR 2500'), findsOneWidget);
    });

    testWidgets('the available tile is labelled', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('AVAILABLE FUNDS'), findsOneWidget);
    });

    testWidgets('a balance sent as a string is still formatted', (tester) async {
      // Postgres returns NUMERIC as a String. Without `asNum` this renders
      // "PKR 5000.00" at best and throws on `toStringAsFixed` at worst.
      api.ok('/wallet/me', wallet(balance: '5000.00', frozen: '2500.00'));

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 5000'), findsNWidgets(2));
      expect(find.text('PKR 2500'), findsOneWidget);
      expect(find.textContaining('5000.00'), findsNothing);
    });

    testWidgets('a fractional balance is rounded to whole rupees', (tester) async {
      api.ok('/wallet/me', wallet(balance: 5000.75, frozen: 0));

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 5001'), findsNWidgets(2));
    });

    testWidgets('a missing frozen column reads as nothing held', (tester) async {
      // A wallet row written before the escrow migration has no `frozen_balance`;
      // "PKR null" on a money card would be worse than a zero.
      api.ok('/wallet/me', {'id': 'w-1', 'user_id': 'u-1', 'balance': 1200});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 0'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('the spinner is gone', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('both actions are offered', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.widgetWithText(ElevatedButton, 'Top Up Wallet'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Withdraw'), findsOneWidget);
    });
  });

  group('when the wallet cannot be read', () {
    // Pinned as it behaves, not as it should. `_load`
    // (lib/screens/player/wallet_screen.dart:43) sets `_wallet = null` when the
    // envelope reports failure, and the balance is rendered as
    // `asNum(_wallet?['balance'])` (:160) — which is 0. So a failed read is displayed
    // as a wallet containing nothing, with no error and no retry. The fix is an
    // `_error` field, an error branch replacing the balance card, and a Retry that
    // calls `_load`.
    testWidgets('a server error is displayed as a zero balance', (tester) async {
      api.fail('/wallet/me', 'Wallet lookup failed');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 0'), findsNWidgets(3),
          reason: 'headline, available and frozen all read zero');
      expect(find.text('Wallet lookup failed'), findsNothing,
          reason: 'the message the API sent never reaches the screen');
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    });

    // Pinned as it behaves, not as it should. Same cause, different path: a dropped
    // connection throws and `catch (_)`
    // (lib/screens/player/wallet_screen.dart:49) discards it, leaving `_wallet` null.
    // This is the exact symptom of a missing `adb reverse`, and the screen reports it
    // as an empty wallet.
    testWidgets('a dropped connection is displayed as a zero balance',
        (tester) async {
      api.offline('/wallet/me');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 0'), findsNWidgets(3));
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'a spinner that never resolves would be the worse bug');
    });

    // Pinned as it behaves, not as it should. Same cause: `jsonDecode` throws on a
    // body that is not JSON — an HTML error page from a proxy — and the same bare
    // catch swallows it.
    testWidgets('an unparseable body is displayed as a zero balance',
        (tester) async {
      api.on('/wallet/me', const FakeResponse(502, '<html>Bad Gateway</html>'));

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 0'), findsNWidgets(3));
    });

    // Pinned as it behaves, not as it should. The consequence worth stating on its
    // own: the actions stay live over an unknown balance, so a player can open the
    // withdraw sheet against a figure the screen never actually read.
    testWidgets('a failed read leaves the actions enabled', (tester) async {
      api.fail('/wallet/me', 'server down');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      final topUp = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      expect(topUp.onPressed, isNotNull);
      final withdraw = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Withdraw'));
      expect(withdraw.onPressed, isNotNull);
    });

    testWidgets('a failed transaction list still renders the balance',
        (tester) async {
      // The correct degradation, and the one thing the error handling here gets
      // right: the two requests are independent, so a failed ledger does not take the
      // balance with it.
      api.ok('/wallet/me', wallet(balance: 5000, frozen: 0));
      api.fail('/wallet/transactions', 'ledger unavailable');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 5000'), findsNWidgets(2));
      expect(find.text('No transactions yet'), findsOneWidget);
    });
  });

  group('the recent transactions', () {
    testWidgets('an empty ledger says so', (tester) async {
      api.ok('/wallet/transactions', <dynamic>[]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('No transactions yet'), findsOneWidget);
    });

    testWidgets('a top-up is labelled and signed as money in', (tester) async {
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('Wallet Top-up'), findsOneWidget);
      expect(find.text('+PKR 1000'), findsOneWidget,
          reason: 'credits carry a leading plus (:306)');
    });

    testWidgets('a booking payment is called a deposit and worded as held',
        (tester) async {
      // The rename is deliberate: the ledger calls it a payment, the player is told
      // it is a deposit, because the money is in escrow rather than spent.
      api.ok('/wallet/transactions', [
        txn(type: 'booking_payment', amount: -2500),
      ]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('Security Deposit'), findsOneWidget);
      expect(find.text('Frozen 2500'), findsOneWidget,
          reason: 'a held row is worded "Frozen", not "money out" (:306)');
    });

    testWidgets('a tournament entry is held without being renamed',
        (tester) async {
      // An entry fee has the same ledger shape as a deposit but must keep its own
      // name: calling it a security deposit would be a lie.
      api.ok('/wallet/transactions', [
        txn(type: 'tournament_entry', amount: -500),
      ]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('Tournament Entry'), findsOneWidget);
      expect(find.text('Frozen 500'), findsOneWidget);
    });

    testWidgets('a debit carries no sign', (tester) async {
      api.ok('/wallet/transactions', [
        txn(type: 'withdrawal', amount: -3000),
      ]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 3000'), findsOneWidget);
      expect(find.text('+PKR 3000'), findsNothing);
    });

    testWidgets('a negative amount is shown as a magnitude', (tester) async {
      // The sign is carried by the wording and the colour, not by a minus in front
      // of the figure (:306 takes `.abs()`).
      api.ok('/wallet/transactions', [
        txn(type: 'no_show_penalty', amount: -750),
      ]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('PKR 750'), findsOneWidget);
      expect(find.textContaining('-750'), findsNothing);
    });

    testWidgets('a refund is signed as money in', (tester) async {
      api.ok('/wallet/transactions', [txn(type: 'refund', amount: 2500)]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('Refund'), findsOneWidget);
      expect(find.text('+PKR 2500'), findsOneWidget);
    });

    testWidgets('an amount sent as a string is still formatted', (tester) async {
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: '1000.00')]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('+PKR 1000'), findsOneWidget);
    });

    testWidgets('an unknown type falls back to a neutral label', (tester) async {
      // A type added by a backend migration must not render as a blank row.
      api.ok('/wallet/transactions', [
        txn(type: 'some_future_type', amount: 100),
      ]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('Transaction'), findsOneWidget);
    });

    testWidgets('a row with no timestamp renders a dash', (tester) async {
      api.ok('/wallet/transactions', [txn(createdAt: null)]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('every returned row gets a tile', (tester) async {
      api.ok('/wallet/transactions', [
        txn(id: 't-1', type: 'topup', amount: 1000),
        txn(id: 't-2', type: 'refund', amount: 500),
        txn(id: 't-3', type: 'withdrawal', amount: -200),
      ]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(find.text('Wallet Top-up'), findsOneWidget);
      expect(find.text('Refund'), findsOneWidget);
      expect(find.text('Withdrawal'), findsOneWidget);
    });

    testWidgets('tapping a row opens the receipt', (tester) async {
      // The sheet needs no second request — the list response already carries every
      // field it shows — so the tap must pass the row it was built from.
      api.ok('/wallet/transactions', [txn(type: 'topup', amount: 1000)]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);
      final before = api.requests.length;

      await tester.tap(find.text('Wallet Top-up'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('TRX-abc12345'), findsOneWidget);
      expect(api.requests.length, before,
          reason: 'the receipt must not cost another request');
    });
  });

  group('the frozen breakdown', () {
    testWidgets('tapping the frozen tile opens the escrow sheet', (tester) async {
      // A bare number here is the most-asked-about figure in the app, so it has to be
      // explainable rather than merely displayed.
      api.ok('/wallet/me', wallet(balance: 5000, frozen: 2500));
      api.ok('/wallet/frozen', {'total': 2500, 'items': <dynamic>[]});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.text('FROZEN'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(api.countTo('/wallet/frozen'), 1);
    });

    testWidgets('the frozen tile advertises that it opens something',
        (tester) async {
      // Without the chevron the tile reads as a static figure and the breakdown is
      // never found (:203).
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expect(
        find.descendant(
          of: find.byType(InkWell),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsWidgets,
      );
    });
  });

  group('topping up', () {
    testWidgets('the button opens a sheet with the preset amounts',
        (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Top Up Wallet'), findsWidgets);
      expect(find.text('PKR 500'), findsOneWidget);
      expect(find.text('PKR 1000'), findsOneWidget);
      expect(find.text('PKR 2000'), findsOneWidget);
      expect(find.text('PKR 5000'), findsWidgets);
    });

    testWidgets('opening the sheet sends nothing', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);
      final before = api.countTo('/wallet/topup');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.countTo('/wallet/topup'), before);
    });

    testWidgets('submitting with nothing selected is refused', (tester) async {
      // A zero-amount POST would create a ledger row for nothing.
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Enter amount between PKR 100 and 50,000'), findsOneWidget);
      expect(api.countTo('/wallet/topup'), 0);
    });

    testWidgets('an amount under the floor is refused', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '99');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Enter amount between PKR 100 and 50,000'), findsOneWidget);
      expect(api.countTo('/wallet/topup'), 0);
    });

    testWidgets('an amount over the ceiling is refused', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '50001');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Enter amount between PKR 100 and 50,000'), findsOneWidget);
      expect(api.countTo('/wallet/topup'), 0);
    });

    testWidgets('unparseable text is refused', (tester) async {
      // `double.tryParse` returns null (:403) and the guard catches it; a NaN amount
      // reaching the API would be a corrupt ledger row.
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Enter amount between PKR 100 and 50,000'), findsOneWidget);
      expect(api.countTo('/wallet/topup'), 0);
    });

    testWidgets('the floor itself is accepted', (tester) async {
      // The comparison is `< 100` (:405), so 100 is inside the range. An off-by-one
      // here would reject the smallest legitimate top-up.
      api.ok('/wallet/topup', {'balance': 5100});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '100');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      expect(api.countTo('/wallet/topup'), 1);
    });

    testWidgets('the ceiling itself is accepted', (tester) async {
      api.ok('/wallet/topup', {'balance': 55000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '50000');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      expect(api.countTo('/wallet/topup'), 1);
    });

    testWidgets('a preset amount is posted as the amount chosen', (tester) async {
      // The body is the contract: a sheet that displayed one figure and posted
      // another would take the wrong sum.
      api.ok('/wallet/topup', {'balance': 7000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      final sent = api.to('/wallet/topup');
      expect(sent, hasLength(1));
      expect(sent.first.method, 'POST');
      expect(sent.first.body, contains('2000'));
    });

    testWidgets('typing a custom amount clears a chosen preset', (tester) async {
      // `onChanged` nulls the selection (:378) so the typed figure wins; without it
      // the preset would silently override what the player typed.
      api.ok('/wallet/topup', {'balance': 8000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 500'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '3000');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      final sent = api.to('/wallet/topup');
      expect(sent, hasLength(1));
      expect(sent.first.body, contains('3000'));
      expect(sent.first.body, isNot(contains('500')));
    });

    testWidgets('choosing a preset clears typed text', (tester) async {
      // The reverse direction (:358): the last thing the player touched is what is
      // charged.
      api.ok('/wallet/topup', {'balance': 6000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '7777');
      await tester.pump();
      await tester.tap(find.text('PKR 1000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      final sent = api.to('/wallet/topup');
      expect(sent, hasLength(1));
      expect(sent.first.body, contains('1000'));
      expect(sent.first.body, isNot(contains('7777')));
    });

    testWidgets('a payment progress dialog is shown before the request',
        (tester) async {
      api.ok('/wallet/topup', {'balance': 7000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Initializing secure gateway...'), findsOneWidget);
      expect(api.countTo('/wallet/topup'), 0,
          reason: 'the POST is deferred until the simulation finishes (:59)');
      await settleTopUp(tester);
    });

    testWidgets('the progress dialog advances through its stages', (tester) async {
      api.ok('/wallet/topup', {'balance': 7000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));

      expect(find.text('Verifying bank details...'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.text('Processing payment...'), findsOneWidget);

      await settleTopUp(tester);
    });

    testWidgets('a successful top-up confirms the amount added', (tester) async {
      api.ok('/wallet/topup', {'balance': 7000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      expect(find.text('PKR 2000 added to wallet!'), findsOneWidget);
    });

    testWidgets('a successful top-up refetches the balance', (tester) async {
      // The new balance is not applied locally (:70), so the refetch is the only
      // thing that makes the money appear.
      api.ok('/wallet/topup', {'balance': 7000});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);
      final before = api.countTo('/wallet/me');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);
      await settleData(tester);

      expect(api.countTo('/wallet/me'), greaterThan(before));
    });

    testWidgets('a rejected top-up surfaces the message the API sent',
        (tester) async {
      // A refused top-up that said nothing would read as the money having vanished
      // between the gateway and the wallet.
      api.fail('/wallet/topup', 'Daily top-up limit reached');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      expect(find.text('Daily top-up limit reached'), findsOneWidget);
    });

    testWidgets('a rejected top-up does not refetch the balance', (tester) async {
      api.fail('/wallet/topup', 'Daily top-up limit reached');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);
      final before = api.countTo('/wallet/me');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      expect(api.countTo('/wallet/me'), before,
          reason: 'a refetch after a failure would imply the top-up worked');
    });

    testWidgets('the progress dialog is dismissed after a failure', (tester) async {
      // A modal spinner left over a failed top-up would strand the player on a
      // barrier they cannot dismiss (`barrierDismissible: false` at :56).
      api.fail('/wallet/topup', 'Daily top-up limit reached');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Processing payment...'), findsNothing);
      expect(find.text('Payment successful!'), findsNothing);
    });

    testWidgets('a dropped connection during a top-up is reported', (tester) async {
      // Money is involved, so this is the one error path on this screen that does
      // surface: `catch (e)` (:75) closes the dialog and shows the error.
      api.offline('/wallet/topup');

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Top Up Wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('PKR 2000'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add to Wallet'));
      await tester.pump();
      await settleTopUp(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Error:'), findsOneWidget);
    });
  });

  group('withdrawing', () {
    testWidgets('the button opens the withdraw sheet', (tester) async {
      api.ok('/wallet/withdrawals', {'pending': null, 'minAmount': 200, 'settleMinutes': 1440});

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Withdraw'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(api.countTo('/wallet/withdrawals'), 1);
    });
  });

  group('the help affordance', () {
    testWidgets('the help button explains what the wallet is for',
        (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
          find.text(
              'Wallet balance is used to book venues. Top up via the button below.'),
          findsOneWidget);
    });

    testWidgets('the help button is a large enough target', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      expectTapTarget(tester, find.widgetWithIcon(IconButton, Icons.help_outline));
    });
  });

  group('navigating to the full history', () {
    testWidgets('View All opens the history screen', (tester) async {
      // The preview is capped at five rows, so this is the only route to the rest of
      // the ledger.
      api.ok('/wallet/transactions', [txn()]);

      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);

      await tester.tap(find.text('View All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(find.text('Transaction History'), findsOneWidget);
    });
  });

  group('refreshing', () {
    testWidgets('a pull refetches both requests', (tester) async {
      await pumpScreen(tester, const WalletScreen());
      await settleData(tester);
      final wallets = api.countTo('/wallet/me');
      final txns = api.countTo('/wallet/transactions');

      await tester.fling(find.text('TOTAL BALANCE'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(api.countTo('/wallet/me'), greaterThan(wallets));
      expect(api.countTo('/wallet/transactions'), greaterThan(txns));
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the loaded wallet keeps its figures present', (tester) async {
      api.ok('/wallet/me', wallet(balance: 125000, frozen: 47500));

      await pumpScreen(tester, const WalletScreen(), textScale: 2.0);
      await settleData(tester);

      // Overflow at this scale is the test font's doing, not the screen's, and is
      // absorbed in setUp; the contract is that the money is still rendered. The figure
      // feeds both the headline and the available tile (:160 and :179).
      expect(find.text('TOTAL BALANCE'), findsOneWidget);
      expect(find.text('PKR 125000'), findsNWidgets(2));
    });

    testWidgets('the empty ledger still says so', (tester) async {
      api.ok('/wallet/transactions', <dynamic>[]);

      await pumpScreen(tester, const WalletScreen(), textScale: 2.0);
      await settleData(tester);

      expect(find.text('No transactions yet'), findsOneWidget);
    });
  });
}
