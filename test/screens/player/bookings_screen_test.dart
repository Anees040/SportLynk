// My Bookings: two tabs over one request, and a cancel that is the only destructive
// action a player can reach without an owner's involvement.
//
// The screen fetches `/bookings/my` once and splits the result locally
// (lib/screens/player/bookings_screen.dart:79-88). That split is the contract worth
// pinning, because it is not the obvious one: a row lands in Upcoming only when its
// `slot_date` is today or later *and* its status is `confirmed` or `pending`, and the
// Past predicate is an independent `where` rather than the complement of the first. A
// row can therefore satisfy both — a confirmed booking today with a status the Past
// list also names — or neither. The tests below fix which rows land where, so a future
// change to either predicate cannot quietly move a paid booking out of the tab the
// player looks at.
//
// The four mandated states are all four. `_load` sets `_error` and renders a
// `NetworkErrorView` with a Retry when a fetch fails with nothing cached to fall
// back on, so a 500 and a dropped connection no longer borrow the empty state an
// account with no bookings shows — which they used to, leaving the app inviting the
// player to make another booking while unable to read the ones they have. Where a
// cache IS present the rows stay on screen under the offline strip instead.
//
// Those states are reached through the `FakeApi` fixture, not through the cache: the
// harness mocks `shared_preferences` to an empty store, so `OfflineCache` reads a
// miss in every test here and the cache path is exercised by its own unit tests
// rather than smuggled into these.
//
// The cancel path is asserted through the confirmation dialog rather than around it. A
// cancel that skipped the dialog, or that fired the PATCH on "Keep", would be a real
// refund taken on a mis-tap, so the tests assert that no request leaves until the
// destructive button is the one pressed, and that the list is refetched afterwards
// rather than mutated in place.
//
// Two details of the card are pinned because they are load-bearing and easy to lose:
// the whole card is a tap target routing to `/booking-detail` with the booking id in
// its arguments, and `_safeTime(null)` renders an em dash rather than "null".
//
// Nothing here settles: the loading state is a `CircularProgressIndicator`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/bookings_screen.dart';

import '../screen_harness.dart';

/// A date [days] from today, in the `yyyy-MM-dd` form `slot_date` carries.
String slotDate(int days) {
  final d = DateTime.now().add(Duration(days: days));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// One booking row, in the shape `/bookings/my` returns.
Map<String, dynamic> booking({
  String id = 'b-1',
  String venue = 'Karachi Sports Arena',
  String status = 'confirmed',
  String? date,
  String? start = '18:00:00',
  String? end = '19:00:00',
  String city = 'Karachi',
  num amount = 2500,
}) =>
    {
      'id': id,
      'venue_name': venue,
      'status': status,
      'slot_date': date ?? slotDate(3),
      'start_time': start,
      'end_time': end,
      'city': city,
      'total_amount': amount,
    };

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  /// Moves to the Past tab and lets the page transition finish. A single pump leaves
  /// the view mid-slide with both children on screen.
  Future<void> openPastTab(WidgetTester tester) async {
    await tester.tap(find.text('Past'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('while the bookings are being fetched', () {
    testWidgets('a spinner is shown rather than an empty list', (tester) async {
      api.ok('/bookings/my', <dynamic>[],
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const BookingsScreen());

      expectLoading(tester);
      expect(find.text('No upcoming bookings'), findsNothing);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('the fetch starts without waiting for a gesture', (tester) async {
      api.ok('/bookings/my', <dynamic>[]);

      await pumpScreen(tester, const BookingsScreen());

      expect(api.countTo('/bookings/my'), 1);
    });

    testWidgets('the tabs are already usable', (tester) async {
      // The tab bar lives in the AppBar rather than the body, so it must render
      // before the request resolves.
      api.ok('/bookings/my', <dynamic>[],
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const BookingsScreen());

      expect(find.text('Upcoming'), findsOneWidget);
      expect(find.text('Past'), findsOneWidget);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });
  });

  group('how a fetched row is sorted into a tab', () {
    testWidgets('a confirmed booking in the future is upcoming', (tester) async {
      api.ok('/bookings/my', [
        booking(venue: 'Clifton Futsal Park', status: 'confirmed', date: slotDate(5)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Clifton Futsal Park'), findsOneWidget);
      expect(find.text('No upcoming bookings'), findsNothing);
    });

    testWidgets('a pending booking in the future is upcoming', (tester) async {
      // Pending is an owner-approval state, not a failure: the player is still
      // expecting to play, so hiding it in Past would lose it.
      api.ok('/bookings/my', [
        booking(venue: 'Gulshan Cricket Ground', status: 'pending', date: slotDate(2)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Gulshan Cricket Ground'), findsOneWidget);
    });

    testWidgets('a booking today is upcoming rather than past', (tester) async {
      // The comparison is against midnight (:81), not against the current instant,
      // so an 18:00 slot booked at 20:00 still counts as today.
      api.ok('/bookings/my', [
        booking(venue: 'Today Arena', status: 'confirmed', date: slotDate(0)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Today Arena'), findsOneWidget);
      expect(find.text('No upcoming bookings'), findsNothing);
    });

    testWidgets('a cancelled booking in the future is not upcoming', (tester) async {
      // The status filter (:82) is what keeps a cancelled slot out of the tab the
      // player treats as their schedule.
      api.ok('/bookings/my', [
        booking(venue: 'Cancelled Arena', status: 'cancelled', date: slotDate(4)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('No upcoming bookings'), findsOneWidget);
    });

    testWidgets('a cancelled booking in the future is past', (tester) async {
      api.ok('/bookings/my', [
        booking(venue: 'Cancelled Arena', status: 'cancelled', date: slotDate(4)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      await openPastTab(tester);

      expect(find.text('Cancelled Arena'), findsOneWidget);
    });

    testWidgets('a confirmed booking in the past is past', (tester) async {
      api.ok('/bookings/my', [
        booking(venue: 'Last Week Arena', status: 'confirmed', date: slotDate(-7)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      await openPastTab(tester);

      expect(find.text('Last Week Arena'), findsOneWidget);
    });

    testWidgets('a row with an unparseable date is past', (tester) async {
      // `DateTime.tryParse` returns null (:85) and the Past predicate accepts null
      // explicitly, so a malformed row is still reachable rather than dropped.
      api.ok('/bookings/my', [
        booking(venue: 'Malformed Arena', status: 'confirmed', date: 'not-a-date'),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      await openPastTab(tester);

      expect(find.text('Malformed Arena'), findsOneWidget);
    });

    testWidgets('a checked-in booking today appears in both tabs', (tester) async {
      // Pinned as it behaves. The two predicates (:79 and :84) are independent
      // `where` calls rather than complements, and `checked_in` is named by the Past
      // list while a today date and a non-terminal status also satisfy Upcoming — so
      // one row is counted twice. The fix is to make Past the complement of Upcoming
      // rather than a second list of statuses.
      api.ok('/bookings/my', [
        booking(venue: 'Checked In Arena', status: 'checked_in', date: slotDate(0)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('No upcoming bookings'), findsOneWidget,
          reason: 'checked_in is not in the Upcoming status list');

      await openPastTab(tester);
      expect(find.text('Checked In Arena'), findsOneWidget);
    });

    testWidgets('both tabs are populated from the one request', (tester) async {
      // One fetch, two lists: a second request per tab would double the cost of
      // opening the screen.
      api.ok('/bookings/my', [
        booking(id: 'b-1', venue: 'Future Arena', date: slotDate(3)),
        booking(id: 'b-2', venue: 'Old Arena', date: slotDate(-3)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Future Arena'), findsOneWidget);
      expect(api.countTo('/bookings/my'), 1);

      await openPastTab(tester);
      expect(find.text('Old Arena'), findsOneWidget);
      expect(api.countTo('/bookings/my'), 1);
    });
  });

  group('when there is genuinely nothing to show', () {
    testWidgets('the upcoming tab explains itself and offers a way out',
        (tester) async {
      api.ok('/bookings/my', <dynamic>[]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('No upcoming bookings'), findsOneWidget);
      expect(find.byIcon(Icons.event_busy), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Find Venues'), findsOneWidget);
    });

    testWidgets('the past tab offers no way out', (tester) async {
      // Nothing can be done about an empty history, so a call to action there would
      // be noise (:161 gates it on `upcoming`).
      api.ok('/bookings/my', <dynamic>[]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      await openPastTab(tester);

      expect(find.text('No past bookings'), findsOneWidget);
      expect(find.text('Find Venues'), findsNothing);
    });

    testWidgets('the empty upcoming call to action navigates to find venues',
        (tester) async {
      api.ok('/bookings/my', <dynamic>[]);

      final log = await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      await tester.tap(find.text('Find Venues'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.last, '/find-venues');
    });
  });

  group('when the request fails', () {
    // These four used to pin the defect rather than the fix, and said so: `_load`
    // cleared the spinner, left both lists at their initial empty value and had no
    // `_error` field, so a 500 and a dropped connection both reached the same empty
    // state an account with no bookings does — the app inviting the player to make
    // another booking while unable to read the ones they have. The named fix (an
    // `_error` field, an error branch above the `items.isEmpty` one, and a Retry
    // that calls `_load`) has landed, so they now pin the fix.
    //
    // The empty state is still correct for a SUCCESSFUL empty response, and the
    // group above covers that; what changed is that a failure no longer borrows it.
    testWidgets('a server error is reported as a failure, not as no bookings',
        (tester) async {
      api.fail('/bookings/my', 'Could not read your bookings');

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('No upcoming bookings'), findsNothing,
          reason: 'a failed read must not be dressed up as an empty schedule');
      expect(find.text('Could not read your bookings'), findsOneWidget,
          reason: 'the message the API sent reaches the screen');
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
    });

    testWidgets('a dropped connection is reported as a failure', (tester) async {
      // The exact symptom of a sleeping Render instance or a missing `adb reverse`.
      api.offline('/bookings/my');

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('No upcoming bookings'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'a spinner that never resolves would be the worse bug');
    });

    testWidgets('an unparseable body is reported as a failure', (tester) async {
      // An HTML error page from a proxy. `ApiClient` cannot decode it and
      // substitutes its own sentence for the status rather than throwing.
      api.on('/bookings/my', const FakeResponse(502, '<html>Bad Gateway</html>'));

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('No upcoming bookings'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
    });

    testWidgets('a failure offers a retry rather than a new booking',
        (tester) async {
      // The consequence that made this worth fixing: the one button on screen
      // after a failed read used to start a NEW booking instead of retrying the
      // read.
      api.fail('/bookings/my', 'server down');

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.widgetWithText(ElevatedButton, 'Find Venues'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
    });

    testWidgets('the retry refetches and renders the rows on success',
        (tester) async {
      // The error state has to be escapable without leaving the screen, which is
      // the whole reason a Retry is required rather than just a message.
      api.fail('/bookings/my', 'server down');

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      api.ok('/bookings/my', [booking(venue: 'Recovered Arena', date: slotDate(2))]);
      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Retry'));
      await settleData(tester);

      expect(find.text('Recovered Arena'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsNothing);
    });
  });

  group('what a booking card shows', () {
    testWidgets('the venue name and the status are both on the card',
        (tester) async {
      api.ok('/bookings/my', [
        booking(venue: 'Karachi Sports Arena', status: 'confirmed'),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text('CONFIRMED'), findsOneWidget,
          reason: 'the status is upper-cased for the badge (:223)');
    });

    testWidgets('the slot times are shown as a range', (tester) async {
      api.ok('/bookings/my', [booking(start: '18:00:00', end: '19:30:00')]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('18:00 – 19:30'), findsOneWidget,
          reason: 'seconds are trimmed by _safeTime (:189)');
    });

    testWidgets('a missing time renders a dash rather than null', (tester) async {
      // A seeded row with no times is common, and "null – null" on a card the player
      // paid for is worse than an honest placeholder.
      api.ok('/bookings/my', [booking(start: null, end: null)]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('— – —'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('a short time string is passed through unchanged', (tester) async {
      // `_safeTime` only substrings when the value is long enough (:189), so a
      // backend that sends "18:00" rather than "18:00:00" is not truncated.
      api.ok('/bookings/my', [booking(start: '18:00', end: '19:00')]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('18:00 – 19:00'), findsOneWidget);
    });

    testWidgets('the amount is shown in rupees with no decimals', (tester) async {
      api.ok('/bookings/my', [booking(amount: 2500)]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('PKR 2500'), findsOneWidget);
    });

    testWidgets('an amount sent as a string is still formatted', (tester) async {
      // The API sends numeric columns as strings on some rows; `asNum` absorbs that
      // (:241) and a raw "2500.00" on the card would be a regression.
      api.ok('/bookings/my', [
        {
          'id': 'b-1',
          'venue_name': 'Karachi Sports Arena',
          'status': 'confirmed',
          'slot_date': slotDate(3),
          'start_time': '18:00:00',
          'end_time': '19:00:00',
          'city': 'Karachi',
          'total_amount': '2500.00',
        },
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('PKR 2500'), findsOneWidget);
    });

    testWidgets('a row with no venue name falls back to a placeholder',
        (tester) async {
      api.ok('/bookings/my', [
        {
          'id': 'b-1',
          'status': 'confirmed',
          'slot_date': slotDate(3),
          'start_time': '18:00:00',
          'end_time': '19:00:00',
          'city': 'Karachi',
          'total_amount': 2500,
        },
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Venue'), findsOneWidget);
    });

    testWidgets('the city is shown on the card', (tester) async {
      api.ok('/bookings/my', [booking(city: 'Lahore')]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Lahore'), findsOneWidget);
    });

    testWidgets('every row in the response gets a card', (tester) async {
      api.ok('/bookings/my', [
        booking(id: 'b-1', venue: 'Arena One', date: slotDate(1)),
        booking(id: 'b-2', venue: 'Arena Two', date: slotDate(2)),
        booking(id: 'b-3', venue: 'Arena Three', date: slotDate(3)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.text('Arena One'), findsOneWidget);
      expect(find.text('Arena Two'), findsOneWidget);
      expect(find.text('Arena Three'), findsOneWidget);
    });
  });

  group('opening a booking', () {
    testWidgets('tapping a card routes to the detail screen with its id',
        (tester) async {
      // The whole card is the target (:196), and the id in the arguments is what the
      // detail screen fetches by — a card that navigated without it would open blank.
      api.ok('/bookings/my', [booking(id: 'bk-42', venue: 'Karachi Sports Arena')]);

      final log = await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      await tester.tap(find.text('Karachi Sports Arena'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.last, '/booking-detail');
    });

    testWidgets('a past booking is still openable', (tester) async {
      // History is where a player looks for a receipt, so the card must stay a target
      // after the slot has gone.
      api.ok('/bookings/my', [
        booking(id: 'bk-9', venue: 'Old Arena', date: slotDate(-5)),
      ]);

      final log = await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      await openPastTab(tester);

      await tester.tap(find.text('Old Arena'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.last, '/booking-detail');
    });
  });

  group('cancelling a booking', () {
    testWidgets('a confirmed upcoming booking offers a cancel', (tester) async {
      api.ok('/bookings/my', [booking(status: 'confirmed', date: slotDate(3))]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
    });

    testWidgets('a pending booking offers no cancel', (tester) async {
      // The action is gated on `confirmed` (:243): a pending booking has taken no
      // money yet, so there is nothing to refund.
      api.ok('/bookings/my', [booking(status: 'pending', date: slotDate(3))]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsNothing);
    });

    testWidgets('a past booking offers no cancel', (tester) async {
      api.ok('/bookings/my', [
        booking(status: 'confirmed', date: slotDate(-3)),
      ]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      await openPastTab(tester);

      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsNothing);
    });

    testWidgets('a cancel asks before it acts', (tester) async {
      // The refund is real money moving; a cancel that fired on the first tap would
      // make a mis-scroll expensive.
      api.ok('/bookings/my', [booking(status: 'confirmed', date: slotDate(3))]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Cancel Booking?'), findsOneWidget);
      // The dialog used to promise "a full refund" unconditionally, which is only
      // true at least 24 hours before the slot — inside that window the policy
      // keeps the 20% deposit for the venue. What is asserted now is that both
      // halves of the rule are stated before the player commits.
      expect(
        find.textContaining('At least 24 hours before the slot this is a full refund'),
        findsOneWidget,
      );
      expect(
        find.textContaining('the venue keeps the 20% deposit'),
        findsOneWidget,
      );
      expect(api.countTo('/cancel'), 0,
          reason: 'nothing may leave until the destructive button is pressed');
    });

    testWidgets('keeping the booking sends no request', (tester) async {
      api.ok('/bookings/my', [booking(status: 'confirmed', date: slotDate(3))]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Keep'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.countTo('/cancel'), 0);
      expect(find.text('Cancel Booking?'), findsNothing);
    });

    testWidgets('confirming sends the cancel for that booking', (tester) async {
      // The id in the path is what decides which slot is refunded, so it is the one
      // part of this request worth asserting on.
      api.ok('/bookings/my', [
        booking(id: 'bk-77', status: 'confirmed', date: slotDate(3)),
      ]);
      api.ok('/bookings/bk-77/cancel', {'refunded': 2500});

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Cancel Booking'));
      await settleData(tester);

      final sent = api.to('/cancel');
      expect(sent, isNotEmpty);
      expect(sent.last.uri.path, contains('bk-77'));
      expect(sent.last.method, 'PATCH');
    });

    testWidgets('a successful cancel refetches the list', (tester) async {
      // The row is not mutated locally (:119), so the refetch is the only thing that
      // moves the booking out of Upcoming.
      api.ok('/bookings/my', [
        booking(id: 'bk-77', status: 'confirmed', date: slotDate(3)),
      ]);
      api.ok('/bookings/bk-77/cancel', {'refunded': 2500});

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      final before = api.countTo('/bookings/my');

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Cancel Booking'));
      await settleData(tester);
      await settleData(tester);

      expect(api.countTo('/bookings/my'), greaterThan(before));
    });

    testWidgets('a rejected cancel surfaces the message the API sent',
        (tester) async {
      // A cancel refused because the slot is inside the cutoff window must say so;
      // a silent no-op would read as the button being broken.
      api.ok('/bookings/my', [
        booking(id: 'bk-77', status: 'confirmed', date: slotDate(3)),
      ]);
      api.fail('/bookings/bk-77/cancel', 'Too late to cancel this booking');

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Cancel Booking'));
      await settleData(tester);

      expect(find.text('Too late to cancel this booking'), findsOneWidget);
    });

    testWidgets('a rejected cancel leaves the booking in place', (tester) async {
      api.ok('/bookings/my', [
        booking(
            id: 'bk-77',
            venue: 'Karachi Sports Arena',
            status: 'confirmed',
            date: slotDate(3)),
      ]);
      api.fail('/bookings/bk-77/cancel', 'Too late to cancel this booking');

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      final before = api.countTo('/bookings/my');

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Cancel Booking'));
      await settleData(tester);

      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(api.countTo('/bookings/my'), before,
          reason: 'a failed cancel must not refetch and imply it worked');
    });

    // A dropped connection during a cancel used to produce no snackbar and no state
    // change — the player tapped the destructive button, confirmed it, and nothing
    // at all happened, because `_cancel` ended in a bare `catch (_) {}`. The named
    // fix (surface the error) has landed.
    testWidgets('a dropped connection during a cancel is reported', (tester) async {
      api.ok('/bookings/my', [
        booking(
            id: 'bk-77',
            venue: 'Karachi Sports Arena',
            status: 'confirmed',
            date: slotDate(3)),
      ]);
      api.offline('/bookings/bk-77/cancel');

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Cancel Booking'));
      await settleData(tester);

      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'a destructive tap that did nothing must say why');
      expect(find.text('Karachi Sports Arena'), findsOneWidget,
          reason: 'and the booking stays, since nothing was cancelled');
    });

    testWidgets('the cancel button is a large enough target', (tester) async {
      api.ok('/bookings/my', [booking(status: 'confirmed', date: slotDate(3))]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      final size = tester.getSize(find.widgetWithText(OutlinedButton, 'Cancel'));
      expect(size.height, greaterThanOrEqualTo(40),
          reason: 'a refund button under 40 logical pixels tall is a mis-tap risk');
    });
  });

  group('refreshing', () {
    testWidgets('a pull refetches the list', (tester) async {
      api.ok('/bookings/my', [booking(venue: 'Karachi Sports Arena')]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);
      final before = api.countTo('/bookings/my');

      await tester.fling(
          find.text('Karachi Sports Arena'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(api.countTo('/bookings/my'), greaterThan(before));
    });

    testWidgets('reloadNow refetches unconditionally', (tester) async {
      // The staleness guard (:62) would let a refresh five seconds after the last one
      // be skipped, and a booking the assistant just made missing from the list is
      // not an acceptable cache miss — hence the separate entry point.
      api.ok('/bookings/my', <dynamic>[]);

      final key = GlobalKey<BookingsScreenState>();
      await pumpScreen(tester, BookingsScreen(key: key));
      await settleData(tester);
      final before = api.countTo('/bookings/my');

      await key.currentState!.reloadNow();
      await settleData(tester);

      expect(api.countTo('/bookings/my'), greaterThan(before));
    });

    testWidgets('refreshIfNeeded skips a fetch made moments ago', (tester) async {
      // The guard exists so that switching tabs back and forth does not put a
      // request on the wire per tap.
      api.ok('/bookings/my', <dynamic>[]);

      final key = GlobalKey<BookingsScreenState>();
      await pumpScreen(tester, BookingsScreen(key: key));
      await settleData(tester);
      final before = api.countTo('/bookings/my');

      key.currentState!.refreshIfNeeded();
      await settleData(tester);

      expect(api.countTo('/bookings/my'), before);
    });

    testWidgets('a refresh shows the spinner again', (tester) async {
      // `_load` sets `_loading = true` first (:68), which replaces the whole body —
      // so a refresh is visible rather than silent.
      api.ok('/bookings/my', <dynamic>[]);

      final key = GlobalKey<BookingsScreenState>();
      await pumpScreen(tester, BookingsScreen(key: key));
      await settleData(tester);

      api.ok('/bookings/my', <dynamic>[],
          delay: const Duration(milliseconds: 300));
      key.currentState!.reloadNow();
      await tester.pump();

      expectLoading(tester);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });
  });

  group('the request itself', () {
    testWidgets('the bookings are read from the caller-scoped endpoint',
        (tester) async {
      // `/bookings/my` rather than `/bookings?user_id=` — the server decides whose
      // rows these are from the token, so no identifier is sent.
      api.ok('/bookings/my', <dynamic>[]);

      await pumpScreen(tester, const BookingsScreen());
      await settleData(tester);

      final sent = api.to('/bookings/my');
      expect(sent, hasLength(1));
      expect(sent.first.method, 'GET');
      expect(sent.first.uri.query, isEmpty);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the empty state does not clip', (tester) async {
      api.ok('/bookings/my', <dynamic>[]);

      await pumpScreen(tester, const BookingsScreen(), textScale: 2.0);
      await settleData(tester);

      expect(find.text('No upcoming bookings'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the tab labels remain readable', (tester) async {
      api.ok('/bookings/my', <dynamic>[]);

      await pumpScreen(tester, const BookingsScreen(), textScale: 2.0);
      await settleData(tester);

      expect(find.text('Upcoming'), findsOneWidget);
      expect(find.text('Past'), findsOneWidget);
    });
  });
}
