// The player's view of one booking: two loads on mount. The booking itself comes
// from a direct `GET /bookings/:id` (`_load`), and the venue chat room is resolved
// separately from `GET /chat/booking/:id` (`_loadChat`) so the "Message venue" button
// appears if and only if a room exists behind it.
//
// Unlike the player profile, the failure branch here is real: `_load` leaves
// `_booking` null on a non-200 or a thrown request, and the build renders "Booking
// not found" for that case. It is asserted below as a genuine reachable state, not
// pinned as unreachable.
//
// The body is a status machine — pending shows a waiting banner and a Cancel action,
// confirmed and checked-in show the QR, and checked-in adds the rate-experience
// invitation. The QR itself is a `QrImageView`; the tests assert the surrounding copy
// rather than the painted matrix.
//
// Mount note: `_load` reads `AuthProvider.token`; `FakeAuth` supplies it. The chat
// path is left unstubbed except where the button is under test, so it resolves to a
// 404, `channelForBooking` returns null, and no button renders — which is the default
// this screen is built to expect.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/player_booking_detail_screen.dart';

import '../screen_harness.dart';

/// The booking endpoint; the cancel path and the chat path are built from the id.
const String kBooking = '/bookings/bk-1';
const String kCancel = '/bookings/bk-1/cancel';
const String kChat = '/chat/booking/bk-1';

/// One booking document in the snake_case shape `_load` reads straight off `data`.
/// `security_deposit` drives the escrow figure; a fixed non-today `slot_date` keeps
/// the rendered date stable.
Map<String, dynamic> booking({
  String status = 'confirmed',
  String? qrCode = 'QR-PAYLOAD',
  String venueName = 'Green Turf Arena',
  num deposit = 500,
}) => {
  'status': status,
  'qr_code': qrCode,
  'venue_name': venueName,
  'city': 'Lahore',
  'slot_date': '2026-09-20',
  'start_time': '18:00:00',
  'end_time': '19:00:00',
  'security_deposit': deposit,
  'total_amount': 2000,
};

Future<RouteLog> pumpDetail(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const PlayerBookingDetailScreen(bookingId: 'bk-1'),
    auth: FakeAuth(
      role: 'player',
      id: 'u-1',
      name: 'Bilal Ahmed',
      token: 'test-token',
    ),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kBooking, booking());
  });

  group('the booking as it loads', () {
    testWidgets('a spinner stands while the load is in flight', (tester) async {
      api.ok(kBooking, booking(), delay: const Duration(milliseconds: 300));
      await pumpDetail(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Booking Confirmed'), findsOneWidget);
    });

    testWidgets('a confirmed booking shows its status, QR and details', (
      tester,
    ) async {
      await pumpDetail(tester, api);
      await settleData(tester);

      expect(find.text('Booking Confirmed'), findsOneWidget);
      expect(find.text('Show this QR to the venue owner'), findsOneWidget);
      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('PKR 500'), findsOneWidget); // amount held in escrow
    });

    testWidgets('a checked-in booking invites the review', (tester) async {
      api.ok(kBooking, booking(status: 'checked_in'));
      await pumpDetail(tester, api);
      await settleData(tester);

      expect(find.text('Checked In — Enjoy!'), findsOneWidget);
      expect(find.text('How was it?'), findsOneWidget);
      expect(find.text('Rate Your Experience'), findsOneWidget);
    });

    testWidgets(
      'a pending booking shows the waiting banner and a Cancel action',
      (tester) async {
        api.ok(kBooking, booking(status: 'pending', qrCode: null));
        await pumpDetail(tester, api);
        await settleData(tester);

        expect(find.text('Pending Approval'), findsOneWidget);
        expect(find.text('Waiting for venue owner approval'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      },
    );

    testWidgets('a failed load shows Booking not found', (tester) async {
      // A real reachable state: `_load` leaves `_booking` null on failure, and the
      // build renders the not-found card rather than degrading to a default.
      api.fail(kBooking, 'boom');
      await pumpDetail(tester, api);
      await settleData(tester);

      expect(find.text('Booking not found'), findsOneWidget);
    });
  });

  group('cancelling', () {
    testWidgets('the Cancel action raises a confirm dialog', (tester) async {
      api.ok(kBooking, booking(status: 'pending', qrCode: null));
      await pumpDetail(tester, api);
      await settleData(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel Booking?'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Keep Booking'), findsOneWidget);
    });

    testWidgets('keeping the booking sends nothing', (tester) async {
      api.ok(kBooking, booking(status: 'pending', qrCode: null));
      await pumpDetail(tester, api);
      await settleData(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Keep Booking'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel Booking?'), findsNothing);
      expect(api.countTo(kCancel), 0);
    });
  });

  group('the venue chat button', () {
    testWidgets('appears once a room is resolved for the booking', (
      tester,
    ) async {
      // With a channel behind it, `_loadChat` sets the id and the button renders.
      api.ok(kChat, const {'channelId': 'c-1'});
      await pumpDetail(tester, api);
      await settleData(tester);
      await tester.pump(); // the chat load resolves after the booking load

      expect(find.text('Message venue'), findsOneWidget);
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the venue present', (tester) async {
      ignoreOverflow();
      await pumpDetail(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Green Turf Arena'), findsOneWidget);
    });
  });
}
