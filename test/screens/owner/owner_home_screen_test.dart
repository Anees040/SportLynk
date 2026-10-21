// The owner home fans out into dashboard, match-queue, chat-badge and pricing
// reads, while its swipeable pages mount the dashboard eagerly and the other owner
// tabs on first swipe. Every request those tabs make is stubbed so the test
// exercises the dashboard rather than accidental 404 fallbacks.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportlynk/screens/owner/owner_home_screen.dart';
import 'package:sportlynk/widgets/ai_price_suggestion_banner.dart';

import '../screen_harness.dart';

const String kDashboard = '/owner/dashboard';
const String kPending = '/matches/owner/pending';
const String kUnread = '/chat/unread-count';
const String kPricing = '/owner/venues/v-1/pricing';
const String kVenues = '/owner/venues';
const String kSlots = '/owner/slots';
const String kBookings = '/owner/bookings';
const String kSummary = '/notifications/summary';

Map<String, dynamic> dashboard() => {
  'stats': {'revenueToday': 12500, 'bookingsToday': 3, 'pendingCount': 1},
  'venue': {'id': 'v-1', 'name': 'Green Turf Arena'},
  'wallet': {'balance': 5000, 'frozen_balance': 1200},
  'pendingEscrow': 800,
  'upcomingBookings': [
    {
      'player_name': 'Ali Raza',
      'status': 'confirmed',
      'trust_score': 85,
      'start_time': '18:00:00',
      'end_time': '19:00:00',
    },
  ],
};

Map<String, dynamic> pricing() => {
  'source': 'heuristic',
  'basePrice': 2000,
  'suggestedPrice': 2200,
  'deltaPct': 10,
  'demand': 0.6,
  'demandLevel': 'medium',
  'reason': 'Peak hour.',
  'topFactors': const [],
};

Future<void> settleHome(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<RouteLog> pumpHome(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
  Size size = const Size(430, 915),
  bool resetPreferences = true,
}) {
  return pumpScreen(
    tester,
    const OwnerHomeScreen(),
    auth: FakeAuth(
      role: 'owner',
      id: 'o-1',
      name: 'Owner',
      token: 'owner-token',
    ),
    textScale: textScale,
    size: size,
    resetPreferences: resetPreferences,
  );
}

Future<void> revealHomeItem(WidgetTester tester, Finder item) async {
  await tester.scrollUntilVisible(
    item,
    150,
    scrollable: find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .first,
  );
  await tester.pump();
}

void main() {
  late FakeApi api;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    api = FakeApi()..install();
    api.ok(kDashboard, dashboard());
    api.ok(kPending, const []);
    api.ok(kUnread, {'total': 0, 'rooms': 0});
    api.ok(kPricing, pricing());
    // The swipeable child tabs mount on first view; stubbed so a swipe to one in a
    // later test lands on a fixture rather than a 404.
    api.ok(kVenues, const []);
    api.ok(kSlots, const []);
    api.ok(kBookings, const []);
    api.ok(kSummary, {'unread': 0, 'byCategory': {}, 'pushConfigured': false});
  });

  group('the dashboard', () {
    testWidgets(
      'pull to refresh leaves the header and dashboard content fixed',
      (tester) async {
        await pumpHome(tester, api);
        await settleHome(tester);
        final header = tester.getTopLeft(find.text('Dashboard'));
        final revenue = tester.getTopLeft(find.text('REVENUE TODAY'));
        final requests = api.countTo(kDashboard);
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('REVENUE TODAY')),
        );
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 360));
        await tester.pump();

        expect(tester.getTopLeft(find.text('Dashboard')), header);
        expect(tester.getTopLeft(find.text('REVENUE TODAY')), revenue);
        expect(find.byType(StretchingOverscrollIndicator), findsNothing);

        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await settleHome(tester);
        expect(api.countTo(kDashboard), requests + 1);
        expectNoOverflow(tester);
      },
    );

    testWidgets('expired bookings are removed while future bookings remain', (
      tester,
    ) async {
      final data = dashboard();
      data['upcomingBookings'] = [
        {
          ...(data['upcomingBookings'] as List).first as Map,
          'player_name': 'Past Player',
          'slot_date': '2020-01-01',
        },
        {
          ...(data['upcomingBookings'] as List).first as Map,
          'player_name': 'Future Player',
          'slot_date': DateTime.now()
              .add(const Duration(days: 1))
              .toIso8601String()
              .substring(0, 10),
        },
      ];
      api.ok(kDashboard, data);
      await pumpHome(tester, api);
      await settleHome(tester);
      await revealHomeItem(tester, find.text('Future Player'));

      expect(find.text('Past Player'), findsNothing);
      expect(find.text('Future Player'), findsOneWidget);
    });

    testWidgets('details open the full price explanation without applying it', (
      tester,
    ) async {
      await pumpHome(tester, api);
      await settleHome(tester);
      await revealHomeItem(tester, find.byType(AiPriceSuggestionBanner));
      expect(find.text('Peak hour.'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();

      expect(find.text('Peak hour.'), findsOneWidget);
      expect(find.text('RULE-BASED'), findsOneWidget);
      expect(api.countTo('/owner/venues/v-1/slots/price'), 0);
    });

    testWidgets(
      'closing a suggestion snoozes it across reopening the dashboard',
      (tester) async {
        await pumpHome(tester, api);
        await settleHome(tester);
        await revealHomeItem(tester, find.byType(AiPriceSuggestionBanner));
        await tester.tap(
          find.byTooltip('Dismiss price suggestion for 6 hours'),
        );
        await tester.pump();
        await settleHome(tester);
        expect(find.byType(AiPriceSuggestionBanner), findsNothing);
        final prefs = await SharedPreferences.getInstance();
        final until = prefs.getInt('owner_price_snooze_v1:o-1:v-1');
        expect(until, greaterThan(DateTime.now().millisecondsSinceEpoch));

        await tester.pumpWidget(const SizedBox.shrink());
        await pumpHome(tester, api, resetPreferences: false);
        await settleHome(tester);
        expect(find.byType(AiPriceSuggestionBanner), findsNothing);
      },
    );

    testWidgets('swiping a suggestion dismisses it without changing prices', (
      tester,
    ) async {
      await pumpHome(tester, api);
      await settleHome(tester);
      await revealHomeItem(tester, find.byType(AiPriceSuggestionBanner));
      await tester.drag(
        find.byType(AiPriceSuggestionBanner),
        const Offset(-700, 0),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AiPriceSuggestionBanner), findsNothing);
      expect(api.countTo('/owner/venues/v-1/slots/price'), 0);
    });

    testWidgets('an expired snooze allows suggestions to return', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'owner_price_snooze_v1:o-1:v-1': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      });
      await pumpHome(tester, api, resetPreferences: false);
      await settleHome(tester);
      await revealHomeItem(tester, find.byType(AiPriceSuggestionBanner));
      expect(find.byType(AiPriceSuggestionBanner), findsOneWidget);
    });

    testWidgets('shows a spinner while dashboard data is in flight', (
      tester,
    ) async {
      api.ok(kDashboard, dashboard(), delay: const Duration(milliseconds: 300));
      await pumpHome(tester, api);
      expectLoading(tester);

      await tester.pump(const Duration(milliseconds: 400));
      await settleHome(tester);
      expect(find.text('Green Turf Arena'), findsOneWidget);
    });

    testWidgets('renders the owner greeting, stats, wallet and booking', (
      tester,
    ) async {
      await pumpHome(tester, api);
      await settleHome(tester);

      expect(find.textContaining('Good '), findsOneWidget);
      expect(find.text('REVENUE TODAY'), findsOneWidget);
      expect(find.text('PKR 12500'), findsOneWidget);
      // The stat card and the kept-alive bottom tab both carry this label.
      expect(find.text('BOOKINGS'), findsNWidgets(2));
      await tester.scrollUntilVisible(
        find.text('Ali Raza'),
        500,
        // The shell body is now a horizontal PageView, itself a Scrollable, so the
        // vertical dashboard list has to be named by its axis rather than taken as
        // the first Scrollable in the tree.
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      expect(find.text('Ali Raza'), findsOneWidget);
      await revealHomeItem(tester, find.text('WALLET BALANCE'));
      expect(find.text('WALLET BALANCE'), findsOneWidget);
      expect(find.text('PKR 5000'), findsOneWidget);
      await revealHomeItem(tester, find.byType(AiPriceSuggestionBanner));
      expect(find.text('AI Suggested Price'), findsOneWidget);
    });

    testWidgets(
      'a dashboard load that fails with no cache shows an error, not zeros',
      (tester) async {
        // Fixed: `_load` now records the failure and, with nothing cached, the
        // dashboard shows an error with a retry instead of rendering "PKR 0" across
        // the stat and wallet cards as though the figures were real.
        api.fail(kDashboard, 'dashboard unavailable');
        await pumpHome(tester, api);
        await settleHome(tester);

        expect(find.text('PKR 0'), findsNothing);
        expect(find.text('dashboard unavailable'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
      },
    );
  });

  group('navigation and scale', () {
    testWidgets('quick actions expose the owner routes', (tester) async {
      final log = await pumpHome(tester, api);
      await settleHome(tester);

      await revealHomeItem(tester, find.text('Tournaments'));
      await tester.tap(find.text('Tournaments'));
      await tester.pumpAndSettle();
      expect(log.sawRoute('/owner-tournaments'), isTrue);
    });

    for (final layout in [
      (const Size(320, 568), 1.0),
      (const Size(360, 800), 1.0),
      (const Size(390, 844), 1.0),
      (const Size(844, 390), 1.0),
      (const Size(768, 1024), 1.0),
      (const Size(320, 568), 2.0),
      (const Size(430, 915), 2.0),
    ]) {
      testWidgets('quick actions fit ${layout.$1} at ${layout.$2} text scale', (
        tester,
      ) async {
        await pumpHome(tester, api, size: layout.$1, textScale: layout.$2);
        await settleHome(tester);

        await revealHomeItem(tester, find.text('Quick Actions'));
        expect(find.text('Quick Actions'), findsOneWidget);
        if (layout.$2 == 1.0) {
          final scan = tester.getCenter(
            find.descendant(
              of: find.widgetWithText(InkWell, 'Scan QR'),
              matching: find.byIcon(Icons.qr_code_scanner_rounded),
            ),
          );
          final requests = tester.getCenter(
            find.byIcon(Icons.pending_actions_rounded),
          );
          final venue = tester.getCenter(find.byIcon(Icons.stadium_rounded));
          expect(scan.dy, requests.dy);
          expect(requests.dy, venue.dy);
          expect(scan.dx, lessThan(requests.dx));
          expect(requests.dx, lessThan(venue.dx));
        }
        await revealHomeItem(tester, find.text('My Venue'));
        expect(find.text('My Venue'), findsOneWidget);
        await revealHomeItem(tester, find.text('Earnings Report'));
        expect(find.text('Earnings Report'), findsOneWidget);
        expectNoOverflow(tester);
      });
    }
  });
}
