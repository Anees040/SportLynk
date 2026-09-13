// The owner's booking queue: three status tabs loaded on mount, an approve that
// posts straight away, and a reject gated behind a confirm dialog. The fake keys on
// path and ignores the query string, so all three tab fetches (`/owner/bookings?
// status=...`) resolve to the one stub — the tests exercise one dataset across the
// tabs rather than three, which is enough to reach every card state.
//
// As with the venue list, a failed load has no distinct state: `_loadAll` catches
// into `_loading = false` with the lists left empty, so a server failure reads as
// "no pending bookings". That is pinned below, not asserted away.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_booking_requests_screen.dart';

import '../screen_harness.dart';

/// The list endpoint. The per-booking approve/reject paths are built from the id.
const String kBookings = '/owner/bookings';

/// One booking row, in the shape `_bookingCard` reads. Trust 85 renders the
/// HIGH TRUST pill; the date is a fixed non-today value so `_fmtDate` prints a
/// day/month rather than "Today".
Map<String, dynamic> booking({
  String id = 'b-1',
  String name = 'Ali Raza',
  num trust = 85,
  num amount = 2000,
}) => {
  'id': id,
  'player_name': name,
  'trust_score': trust,
  'sport_preferences': const ['Football', 'Cricket'],
  'slot_date': '2026-09-20',
  'start_time': '18:00:00',
  'end_time': '19:00:00',
  'total_amount': amount,
};

Future<RouteLog> pumpBookings(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerBookingRequestsScreen(),
    auth: FakeAuth(
      role: 'owner',
      id: 'o-1',
      name: 'Owner',
      token: 'owner-token',
    ),
    textScale: textScale,
  );
}

/// The load fans out three sequential GETs that resolve on the microtask queue;
/// `settleData` drains them, and one extra pump renders the selected tab.
Future<void> settleTabs(WidgetTester tester) async {
  await settleData(tester);
  await tester.pump();
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kBookings, [booking()]);
  });

  group('the queue as it loads', () {
    testWidgets('a spinner stands while the first load is in flight', (
      tester,
    ) async {
      api.ok(kBookings, [booking()], delay: const Duration(milliseconds: 100));
      await pumpBookings(tester, api);

      expectLoading(tester);

      // Three sequential 100ms fetches; advance past all of them.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('Ali Raza'), findsOneWidget);
    });

    testWidgets(
      'a loaded pending booking shows the player, amount and actions',
      (tester) async {
        await pumpBookings(tester, api);
        await settleTabs(tester);

        expect(find.text('Ali Raza'), findsOneWidget);
        expect(find.text('PKR 2000'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'Approve'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Reject'), findsOneWidget);
      },
    );

    testWidgets('an empty queue says there are no pending bookings', (
      tester,
    ) async {
      api.ok(kBookings, const []);
      await pumpBookings(tester, api);
      await settleTabs(tester);

      expect(find.text('No pending bookings'), findsOneWidget);
    });

    testWidgets('a failed load reads as the empty state, not an error', (
      tester,
    ) async {
      // Defect, pinned: `_loadAll` swallows a failure into empty lists, so a 500 is
      // indistinguishable from an empty queue. No error-with-retry state exists.
      api.fail(kBookings, 'boom');
      await pumpBookings(tester, api);
      await settleTabs(tester);

      expect(find.text('No pending bookings'), findsOneWidget);
    });

    testWidgets('the three status tabs show, with a live pending count', (
      tester,
    ) async {
      await pumpBookings(tester, api);
      await settleTabs(tester);

      expect(find.text('Pending (1)'), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text('Rejected'), findsOneWidget);
    });
  });

  group('acting on a request', () {
    testWidgets('approving posts to the approve path and confirms', (
      tester,
    ) async {
      api.ok('/owner/bookings/b-1/approve', const {});
      await pumpBookings(tester, api);
      await settleTabs(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(api.countTo('/owner/bookings/b-1/approve'), 1);
      expect(find.text('Booking approved! Player notified.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('rejecting is gated behind a confirm dialog, then posts', (
      tester,
    ) async {
      api.ok('/owner/bookings/b-1/reject', const {});
      await pumpBookings(tester, api);
      await settleTabs(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
      await tester.pumpAndSettle();
      // The dialog is up; nothing has been sent yet.
      expect(find.text('Reject Booking?'), findsOneWidget);
      expect(api.countTo('/owner/bookings/b-1/reject'), 0);

      await tester.tap(find.widgetWithText(TextButton, 'Reject'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(api.countTo('/owner/bookings/b-1/reject'), 1);
      expect(find.text('Booking rejected. Player refunded.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('dismissing the reject dialog sends nothing', (tester) async {
      await pumpBookings(tester, api);
      await settleTabs(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(api.countTo('/owner/bookings/b-1/reject'), 0);
      expect(find.text('Ali Raza'), findsOneWidget);
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps a booking present', (tester) async {
      ignoreOverflow();
      await pumpBookings(tester, api, textScale: 2.0);
      await settleTabs(tester);

      expect(find.text('Ali Raza'), findsOneWidget);
    });
  });
}
