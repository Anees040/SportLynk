// The slot calendar chains an owner-venue read into a date-scoped slot read. The
// fake matches by path, while the tests still inspect the visible status labels and
// the exact mutation paths the screen builds.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_slot_calendar_screen.dart';
import 'package:sportlynk/widgets/assistant/scout_bits.dart';

import '../screen_harness.dart';

const String kVenues = '/owner/venues';
const String kSlots = '/owner/slots';

Map<String, dynamic> venue() => {'id': 'v-1', 'name': 'Green Turf Arena'};

String today() {
  // Keep the fixture in the future regardless of the wall clock when the suite runs.
  // The calendar is intentionally date-scoped, but the fake ignores query strings;
  // using tomorrow lets the row exercise the available/blockable branch all day.
  final d = DateTime.now().add(const Duration(days: 1));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> slot({String status = 'available'}) => {
  'id': 's-1',
  'slot_date': today(),
  'start_time': '18:00:00',
  'end_time': '19:00:00',
  'status': status,
  'effective_status': status,
};

Future<void> settleCalendar(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<RouteLog> pumpCalendar(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerSlotCalendarScreen(),
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
    api = FakeApi()..install();
    api.ok(kVenues, [venue()]);
    api.ok(kSlots, [slot()]);
  });

  group('the calendar as it loads', () {
    testWidgets('past booked slots retain their booking history', (tester) async {
      api.ok(kSlots, [{...slot(status: 'booked'), 'slot_date': '2020-01-01'}]);
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('PAST'), findsOneWidget);
      expect(find.text('WAS BOOKED'), findsOneWidget);
      expect(find.text('BOOKED'), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });

    testWidgets('future booked slots remain booked rather than past', (tester) async {
      api.ok(kSlots, [slot(status: 'booked')]);
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('BOOKED'), findsOneWidget);
      expect(find.text('PAST'), findsNothing);
      expect(find.text('WAS BOOKED'), findsNothing);
    });

    testWidgets('shows a spinner while venues and slots are chained', (
      tester,
    ) async {
      api.ok(kVenues, [venue()], delay: const Duration(milliseconds: 250));
      await pumpCalendar(tester, api);
      expectLoading(tester);

      await settleCalendar(tester);
      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('18:00 – 19:00'), findsOneWidget);
    });

    testWidgets('renders an available slot and the selected date', (
      tester,
    ) async {
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('SELECTED'), findsOneWidget);
      expect(find.text('AVAILABLE'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('an empty day says there are no slots', (tester) async {
      api.ok(kSlots, const []);
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('No slots for this date'), findsOneWidget);
    });

    testWidgets('a failed slot read with no cache shows an error with a retry', (
      tester,
    ) async {
      // Fixed: a failed load now shows an error-with-retry instead of "No slots for
      // this date", which would wrongly invite the owner to regenerate slots that
      // already exist but could not be read.
      api.fail(kSlots, 'boom');
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('No slots for this date'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('slot actions', () {
    testWidgets('blocking a free slot uses the per-slot PATCH path', (
      tester,
    ) async {
      api.on(
        '/owner/slots/s-1/block',
        FakeResponse(
          200,
          jsonEncode({'success': true, 'message': 'Slot blocked.', 'data': {}}),
        ),
      );
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      await tester.tap(find.byIcon(Icons.lock_outline));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(api.countTo('/owner/slots/s-1/block'), 1);
    });

    testWidgets('generation animates Scout, prevents duplicate taps and shows completion', (
      tester,
    ) async {
      api.on(
        '/owner/slots/generate',
        FakeResponse(
          200,
          jsonEncode({'success': true, 'message': 'Generated.', 'data': {}}),
          delay: const Duration(seconds: 2),
        ),
      );
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      await tester.tap(find.byTooltip('Generate Slots for 7 Days'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Building...'), findsOneWidget);
      expect(tester.widget<ScoutAvatar>(find.byType(ScoutAvatar)).thinking, isTrue);
      expect(find.text('AVAILABLE'), findsOneWidget);
      await tester.tap(find.byTooltip('Generate Slots for 7 Days'));
      expect(api.countTo('/owner/slots/generate'), 1);
      expect(jsonDecode(api.to('/owner/slots/generate').single.body!)['venueId'], 'v-1');

      await tester.pump(const Duration(seconds: 2));
      await settleCalendar(tester);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Auto-fill'), findsOneWidget);
    });

    testWidgets('failed generation keeps the schedule visible and allows retry', (tester) async {
      api.fail('/owner/slots/generate', 'Please try again');
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      await tester.tap(find.text('Auto-fill'));
      await settleCalendar(tester);
      expect(find.text('Please try again'), findsOneWidget);
      expect(find.text('AVAILABLE'), findsOneWidget);
      expect(find.text('Ready'), findsNothing);
      await tester.tap(find.text('Auto-fill'));
      await settleCalendar(tester);
      expect(api.countTo('/owner/slots/generate'), 2);
    });
  });

  testWidgets('a doubled text scale keeps the slot visible', (tester) async {
    ignoreOverflow();
    await pumpCalendar(tester, api, textScale: 2.0);
    await settleCalendar(tester);
    expect(find.text('AVAILABLE'), findsOneWidget);
  });
}
