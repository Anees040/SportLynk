// The owner's wallet: two GETs fired together on mount (`/wallet/me` and
// `/wallet/transactions` via `Future.wait`). Unlike the venue and booking queues,
// this screen has a genuine fourth state — a failed balance load shows an error card
// with a Retry button rather than a silent "PKR 0", and the screen's own comment
// (owner_wallet_screen.dart:38) says why: an owner seeing zero after a hiccup cannot
// otherwise tell that from losing money. Several assertions below exist to hold that.
//
// Mount note: the balance goes through `ApiClient`, so the token from `FakeAuth` is
// what carries `_load` past its null-token guard. Both requests are path-keyed; the
// `limit=5` on the transactions call is recorded but ignored for matching.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_wallet_screen.dart';

import '../screen_harness.dart';

/// The balance endpoint; the ledger comes from a second path.
const String kWallet = '/wallet/me';
const String kTxns = '/wallet/transactions';

/// The wallet document `_load` reads. `asNum` coerces these, so plain ints are fine.
Map<String, dynamic> wallet({num balance = 5000, num frozen = 1200}) => {
  'balance': balance,
  'frozen_balance': frozen,
};

Future<RouteLog> pumpWallet(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerWalletScreen(),
    auth: FakeAuth(
      role: 'owner',
      id: 'o-1',
      name: 'Owner',
      token: 'owner-token',
    ),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kWallet, wallet());
    api.ok(kTxns, const []);
  });

  group('the wallet as it loads', () {
    testWidgets('a spinner stands while the first load is in flight', (
      tester,
    ) async {
      api.ok(kWallet, wallet(), delay: const Duration(milliseconds: 300));
      api.ok(kTxns, const [], delay: const Duration(milliseconds: 300));
      await pumpWallet(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      // Balance shows twice — total and available — so two is the loaded signal.
      expect(find.text('PKR 5000'), findsNWidgets(2));
    });

    testWidgets('a loaded wallet shows balance, frozen funds and withdraw', (
      tester,
    ) async {
      await pumpWallet(tester, api);
      await settleData(tester);

      expect(find.text('PKR 5000'), findsNWidgets(2)); // total + available
      expect(find.text('PKR 1200'), findsOneWidget); // frozen
      expect(find.text('AVAILABLE FUNDS'), findsOneWidget);
      expect(find.text('FROZEN'), findsOneWidget);
      expect(find.text('Withdraw Funds'), findsOneWidget);
    });

    testWidgets('no transactions shows the empty ledger line', (tester) async {
      await pumpWallet(tester, api);
      await settleData(tester);

      expect(find.text('No transactions yet'), findsOneWidget);
    });
  });

  group('a failed balance load', () {
    testWidgets('surfaces the message with a retry, not a silent zero', (
      tester,
    ) async {
      api.fail(kWallet, 'Could not load your wallet.');
      await pumpWallet(tester, api);
      await settleData(tester);

      // The fourth state the screen deliberately keeps: the server's message shows,
      // a retry is offered, and the balance reads zero rather than a stale figure.
      expect(find.text('Could not load your wallet.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(find.text('PKR 0'), findsWidgets);
    });

    testWidgets('retry re-requests the balance', (tester) async {
      api.fail(kWallet, 'Could not load your wallet.');
      await pumpWallet(tester, api);
      await settleData(tester);
      expect(api.countTo(kWallet), 1, reason: 'one load on mount');

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await settleData(tester);

      expect(api.countTo(kWallet), 2, reason: 'retry issues a second request');
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the balance present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpWallet(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('PKR 5000'), findsNWidgets(2));
    });
  });
}
