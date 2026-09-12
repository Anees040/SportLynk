// Confirm booking: the last screen before money moves. It escrows the full slot
// price, holds twenty per cent of it at risk, and refuses to let the player pay more
// than their wallet holds — so the tests pin what the player is shown before they
// commit (the escrow breakdown and the cancellation policy), the wallet gate on the
// Pay button, and the one write (a POST carrying only the slot and venue ids).
//
// Mount note: the screen reads the session token with a bang in `_loadWallet` and
// `_confirmBooking`, so the session must carry a non-null token; the default
// `FakeAuth` does. There is no full-screen loading state — the summary and policy
// render immediately and the wallet fetch only augments them — so the Pay button
// starts disabled, because a zero balance cannot cover a paid slot, and enables once
// `/wallet/me` resolves. The wallet read and the booking write are both top-level
// `http` calls rather than `ApiClient`, so a dropped connection reaches the screen's
// own `catch` instead of the client's `{success:false}` translation.
//
// A successful booking does not pop; it `pushReplacement`s to a full success screen,
// so that path is asserted by the success screen's content appearing rather than by a
// host route reappearing.
//
// One behaviour is pinned as a defect (see the findings list): a failed or dropped
// `/wallet/me` is swallowed, leaving the Pay button disabled with no error and no
// retry — the screen is stuck with no way forward.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/confirm_booking_screen.dart';

import '../screen_harness.dart';

/// The wallet read fired in `initState`, and the booking write fired on Pay. Distinct
/// paths that do not collide by suffix.
const String kWallet = '/wallet/me';
const String kBookings = '/bookings';

/// A venue, in the shape the screen reads (`id`, `name`).
Map<String, dynamic> venue({String id = 'v-1', String name = 'Green Turf Arena'}) =>
    {'id': id, 'name': name};

/// A slot, in the shape the screen reads. The price drives every figure on the
/// screen: the escrowed amount equals it and the at-risk deposit is a fifth of it.
Map<String, dynamic> slot({
  String id = 's-1',
  dynamic price = 1500,
  String startTime = '18:00:00',
  String endTime = '19:00:00',
}) =>
    {'id': id, 'price': price, 'start_time': startTime, 'end_time': endTime};

/// Mounts the screen with a fixed date, so the summary reads a stable label.
Future<RouteLog> pumpConfirm(
  WidgetTester tester,
  FakeApi api, {
  Map<String, dynamic>? slotData,
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    ConfirmBookingScreen(
      venue: venue(),
      slot: slotData ?? slot(),
      selectedDate: DateTime(2026, 9, 20),
    ),
    textScale: textScale,
  );
}

/// The booking POSTs, method-filtered off the wallet GET. They are distinct paths, so
/// this is defensive rather than necessary.
Iterable<RecordedRequest> bookingWrites(FakeApi api) =>
    api.to(kBookings).where((r) => r.method == 'POST');

/// The Pay button as an [ElevatedButton], so a test can read whether it is enabled.
ElevatedButton payButton(WidgetTester tester) => tester.widget<ElevatedButton>(
    find.widgetWithText(ElevatedButton, 'Pay PKR 1500'));

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // A funded wallet, resolving immediately, is the common precondition.
    api.ok(kWallet, {'balance': 5000});
  });

  group('the screen as it loads', () {
    testWidgets('the summary and escrow breakdown render before the wallet resolves',
        (tester) async {
      // The wallet read is held in flight; the content is built regardless.
      api.ok(kWallet, {'balance': 5000}, delay: const Duration(milliseconds: 300));
      await pumpConfirm(tester, api);

      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('Payment (held in escrow)'), findsOneWidget);
      expect(find.text('Slot price'), findsOneWidget);
      // The slot price and the escrowed amount are equal, so the figure shows twice.
      expect(find.text('PKR 1500'), findsNWidgets(2));
      expect(find.text('At-risk deposit (20%)'), findsOneWidget);
      expect(find.text('PKR 300'), findsOneWidget);
      // The wallet has not answered, so the balance still reads zero and the breakdown
      // box is absent.
      expect(find.text('Available: PKR 0'), findsOneWidget);
      expect(find.text('WALLET AFTER'), findsNothing);
    });

    testWidgets('the Pay button is disabled until the wallet covers the slot',
        (tester) async {
      api.ok(kWallet, {'balance': 5000}, delay: const Duration(milliseconds: 300));
      await pumpConfirm(tester, api);

      // Before the wallet resolves the balance is zero, so a paid slot cannot be
      // covered and the action is off.
      expect(payButton(tester).onPressed, isNull,
          reason: 'a zero balance cannot cover a paid slot');

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // Once the funded balance arrives the breakdown appears and the action enables.
      expect(find.text('Available: PKR 5000'), findsOneWidget);
      expect(find.text('WALLET AFTER'), findsOneWidget);
      expect(find.text('PKR 3500'), findsOneWidget);
      expect(payButton(tester).onPressed, isNotNull);
    });

    testWidgets('the cancellation policy states the window and the forfeit',
        (tester) async {
      await pumpConfirm(tester, api);
      await settleData(tester);

      expect(find.textContaining('Cancel at least 24 hours'), findsOneWidget);
      expect(find.textContaining('forfeits the 20% deposit'), findsOneWidget);
    });
  });

  group('wallet sufficiency', () {
    testWidgets('an insufficient balance disables Pay and warns', (tester) async {
      api.ok(kWallet, {'balance': 500});
      await pumpConfirm(tester, api);
      await settleData(tester);

      expect(find.text('Insufficient balance. Top up your wallet to proceed.'),
          findsOneWidget);
      // The wallet-after figure goes negative and the button stays off.
      expect(find.text('PKR -1000'), findsOneWidget);
      expect(payButton(tester).onPressed, isNull);
    });

    testWidgets('a failed wallet read leaves Pay disabled with no error or retry',
        (tester) async {
      // Defect, pinned rather than fixed: `_loadWallet` swallows a failed or dropped
      // `/wallet/me` in `catch (_) {}` (confirm_booking_screen.dart:52) and never sets
      // `_walletLoaded`, so the balance stays zero, the Pay button stays disabled, and
      // nothing on screen says why — the player is stuck with no error and no retry.
      api.offline(kWallet);
      await pumpConfirm(tester, api);
      await settleData(tester);

      expect(find.text('Available: PKR 0'), findsOneWidget);
      expect(find.text('WALLET AFTER'), findsNothing);
      expect(payButton(tester).onPressed, isNull);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('confirming the booking', () {
    testWidgets('a successful booking posts the slot and venue, then confirms',
        (tester) async {
      await pumpConfirm(tester, api);
      await settleData(tester);

      api.ok(kBookings, {'id': 'bk-9', 'qr_code': 'QR9'});
      await tester.tap(find.text('Pay PKR 1500'));
      await tester.pumpAndSettle();

      expect(bookingWrites(api).length, 1, reason: 'exactly one booking POST');
      final body = jsonDecode(bookingWrites(api).single.body!) as Map;
      expect(body['slotId'], 's-1');
      expect(body['venueId'], 'v-1');
      // The success path replaces the route with a full confirmation screen.
      expect(find.text('Slot Reserved!'), findsOneWidget);
      expect(find.text('PENDING OWNER APPROVAL'), findsOneWidget);
    });

    testWidgets('a refused booking surfaces the server message and stays put',
        (tester) async {
      await pumpConfirm(tester, api);
      await settleData(tester);

      api.fail(kBookings, 'That slot was just taken.');
      await tester.tap(find.text('Pay PKR 1500'));
      await tester.pumpAndSettle();

      expect(bookingWrites(api).length, 1);
      expect(find.text('That slot was just taken.'), findsOneWidget);
      // No navigation on failure, so the Pay button is still there to retry.
      expect(find.text('Pay PKR 1500'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('a dropped connection on booking shows the network error',
        (tester) async {
      await pumpConfirm(tester, api);
      await settleData(tester);

      api.offline(kBookings);
      await tester.tap(find.text('Pay PKR 1500'));
      await tester.pumpAndSettle();

      // The request was attempted, and the screen's own catch surfaces a readable
      // message rather than the raw exception.
      expect(bookingWrites(api).length, 1);
      expect(find.text('Network error. Please try again.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the Pay button present', (tester) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense row overflows at this scale in the harness alone; the contract is that
      // the content is still built.
      ignoreOverflow();
      await pumpConfirm(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Pay PKR 1500'), findsOneWidget);
    });
  });
}
