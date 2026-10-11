// The owner home fans out into dashboard, match-queue, chat-badge and pricing
// reads, while its swipeable pages mount the dashboard eagerly and the other owner
// tabs on first swipe. Every request those tabs make is stubbed so the test
// exercises the dashboard rather than accidental 404 fallbacks.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportlynk/screens/owner/owner_home_screen.dart';

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
  );
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
      expect(find.text('WALLET BALANCE'), findsOneWidget);
      expect(find.text('PKR 5000'), findsOneWidget);
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
      expect(find.text('AI Suggested Price'), findsOneWidget);
    });

    testWidgets('a dashboard load that fails with no cache shows an error, not zeros', (
      tester,
    ) async {
      // Fixed: `_load` now records the failure and, with nothing cached, the
      // dashboard shows an error with a retry instead of rendering "PKR 0" across
      // the stat and wallet cards as though the figures were real.
      api.fail(kDashboard, 'dashboard unavailable');
      await pumpHome(tester, api);
      await settleHome(tester);

      expect(find.text('PKR 0'), findsNothing);
      expect(find.text('dashboard unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('navigation and scale', () {
    testWidgets('quick actions expose the owner routes', (tester) async {
      final log = await pumpHome(tester, api);
      await settleHome(tester);

      await tester.tap(find.text('Tournaments'));
      await tester.pumpAndSettle();
      expect(log.sawRoute('/owner-tournaments'), isTrue);
    });

    testWidgets('a doubled text scale keeps the dashboard actions present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpHome(tester, api, textScale: 2.0);
      await settleHome(tester);

      expect(find.text('Quick Actions'), findsOneWidget);
      expect(find.text('My Venue'), findsOneWidget);
      expect(find.text('Earnings Report'), findsOneWidget);
    });
  });
}
