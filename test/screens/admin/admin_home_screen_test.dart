// Admin home: a five-tab desk (dashboard, three registration queues, pending
// venues) that fires every one of its loads on mount — stats, the pending list,
// the venue list, the open-dispute count and the moderation-flag count — so a
// mounted screen touches five endpoints before the admin taps anything.
//
// Two mount facts decide how this pumps.
//
// The header carries a `NotificationBell`, and the bell's post-frame `_boot`
// attaches the notification socket, registers for push and replays a deep link the
// moment it sees a non-empty token (lib/widgets/notification_bell.dart:57). A test
// session must therefore mount with `token: null`, which makes `_boot` return before
// any of that starts; the screen's own `_token` getter reads `token ?? ''`
// (admin_home_screen.dart:66), so the loads still fire with an empty bearer, which
// the fake API serves by path regardless.
//
// The two desk counts are read through `AdminService`/`ReviewService`, both of which
// return empty rather than throw on a non-success (admin_service.dart:57,
// review_service.dart:111). An unstubbed dispute or flag endpoint is thus a quiet
// zero, not a crash — but the five are stubbed here so the loaded state is the real
// one and not a fallback.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_home_screen.dart';

import '../screen_harness.dart';

/// The five endpoints the screen reads, as `ApiConstants` resolves them. The
/// registrations path is stubbed once and serves all three status tabs, because the
/// fake matches on the path with its query stripped.
const String kStats = '/admin/stats';
const String kRegs = '/admin/registrations';
const String kVenues = '/admin/venues/pending';
const String kDisputes = '/admin/disputes';
const String kFlagged = '/admin/reviews/flagged';

/// A platform-stats payload with a distinct number per field, so a `find.text` on a
/// figure lands on exactly one card.
Map<String, dynamic> stats() => {
      'pendingRegistrations': 7,
      'approvedOwners': 42,
      'rejectedOwners': 3,
      'totalPlayers': 128,
      'activeVenues': 15,
      'activeBookings': 9,
    };

/// One owner registration row, in the shape `_regCard` reads (admin_home:541).
Map<String, dynamic> reg({
  String ownerName = 'Bilal Traders',
  String groundName = 'Green Turf Arena',
  String city = 'Lahore',
  dynamic price = 2500,
  String status = 'pending',
}) =>
    {
      'id': 'reg-1',
      'verification_status': status,
      'owner_name': ownerName,
      'ground_name': groundName,
      'city': city,
      'price_per_hour': price,
    };

/// One pending venue, in the shape `_venueCard` reads (admin_home:688).
Map<String, dynamic> venue({String id = 'v-1', String name = 'Champions Ground'}) =>
    {
      'id': id,
      'name': name,
      'owner_name': 'Bilal Traders',
      'city': 'Lahore',
      'address': 'Main Boulevard',
    };

/// Mounts the desk as an admin whose token is null, which is what keeps the bell's
/// bootstrap — socket, push registration, deep-link replay — from starting.
Future<RouteLog> pumpAdmin(WidgetTester tester, FakeApi api,
    {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const AdminHomeScreen(),
    auth: FakeAuth(role: 'admin', id: 'admin-1', name: 'Ops', token: null),
    textScale: textScale,
  );
}

/// Switches to a named tab and lets the tab animation and the list load settle.
Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // Defaults for a clean loaded desk: real stats, one pending registration, no
    // venues, no disputes, no flags. Individual tests override the one path they
    // are about.
    api.ok(kStats, stats());
    api.ok(kRegs, [reg()]);
    api.ok(kVenues, <dynamic>[]);
    api.ok(kDisputes, {'items': <dynamic>[], 'nextCursor': null});
    api.ok(kFlagged, <dynamic>[]);
  });

  group('the dashboard as it loads', () {
    testWidgets('a spinner stands while the stats are in flight',
        (tester) async {
      api.ok(kStats, stats(), delay: const Duration(milliseconds: 300));
      await pumpAdmin(tester, api);

      // The dashboard body is gated on `_loadingStats`; the other four loads move
      // their own counters and never clear this spinner (admin_home:294).
      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('SportLynk Control Center'), findsOneWidget);
    });

    testWidgets('the loaded desk shows the banner, the stat cards and the counts',
        (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);

      expect(find.text('SportLynk Control Center'), findsOneWidget);
      expect(find.text('Platform Overview'), findsOneWidget);
      // The four stat cards, each figure distinct so the match is unambiguous.
      expect(find.text('Total Players'), findsOneWidget);
      expect(find.text('128'), findsOneWidget);
      expect(find.text('Active Venues'), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
      expect(find.text('Active Bookings'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      // The hero badges carry the approved and rejected owner counts.
      expect(find.text('Approved'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('Rejected'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('every quick action is present', (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);

      expect(find.text('Review Pending Registrations'), findsOneWidget);
      expect(find.text('Moderation Queue'), findsOneWidget);
      expect(find.text('Match Disputes'), findsOneWidget);
      expect(find.text('Users'), findsOneWidget);
      expect(find.text('Platform Settings'), findsOneWidget);
      expect(find.text('Platform Report'), findsOneWidget);
      expect(find.text('Refresh Stats'), findsOneWidget);
    });

    testWidgets('the five tabs are labelled', (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);

      expect(find.text('DASHBOARD'), findsOneWidget);
      expect(find.text('OWNERS (P)'), findsOneWidget);
      expect(find.text('OWNERS (A)'), findsOneWidget);
      expect(find.text('OWNERS (R)'), findsOneWidget);
      expect(find.text('VENUES'), findsOneWidget);
    });
  });

  group('when the stats fail to load', () {
    testWidgets('the failure is surfaced in a snackbar, not swallowed',
        (tester) async {
      api.fail(kStats, 'boom');
      await pumpAdmin(tester, api);
      await settleData(tester);

      // The screen names the reason rather than leaving a silent zeroed desk
      // (admin_home:83).
      expect(find.text('Failed to load stats: boom'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('the pending registrations tab', () {
    testWidgets('a registration renders its owner, ground, city and price',
        (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'OWNERS (P)');

      expect(find.text('Bilal Traders'), findsOneWidget);
      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('Lahore'), findsOneWidget);
      expect(find.text('PKR 2500/hr'), findsOneWidget);
      // The card's status chip is the verification status, upper-cased.
      expect(find.text('PENDING'), findsOneWidget);
    });

    testWidgets('an empty queue says so rather than showing a blank tab',
        (tester) async {
      api.ok(kRegs, <dynamic>[]);
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'OWNERS (P)');

      expect(find.text('No pending registrations'), findsOneWidget);
    });
  });

  group('the venues tab', () {
    testWidgets('an empty venue queue says so', (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'VENUES');

      expect(find.text('No pending venues'), findsOneWidget);
    });

    testWidgets('a pending venue can be approved and the result is confirmed',
        (tester) async {
      api.ok(kVenues, [venue()]);
      api.ok('/admin/venues/v-1/approve', <String, dynamic>{});
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'VENUES');

      expect(find.text('Champions Ground'), findsOneWidget);
      await tapVisible(tester, find.text('Approve Venue'));
      await tester.pump();
      await tester.pump();

      expect(api.countTo('/admin/venues/v-1/approve'), 1);
      expect(find.text('Venue approved and is now live!'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('navigation off the desk', () {
    testWidgets('the Users action pushes the users route', (tester) async {
      final routes = await pumpAdmin(tester, api);
      await settleData(tester);

      await tapVisible(tester, find.text('Users'));
      await tester.pumpAndSettle();

      expect(routes.sawRoute('/admin-users'), isTrue);
    });

    testWidgets('the Platform Settings action pushes the settings route',
        (tester) async {
      final routes = await pumpAdmin(tester, api);
      await settleData(tester);

      await tapVisible(tester, find.text('Platform Settings'));
      await tester.pumpAndSettle();

      expect(routes.sawRoute('/admin-settings'), isTrue);
    });
  });

  group('reach and scale', () {
    testWidgets('the header icon buttons carry their tooltips', (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);

      // Icon-only controls in the app bar name themselves for a screen reader.
      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(find.byTooltip('Moderation queue'), findsOneWidget);
      expect(find.byTooltip('Log out'), findsOneWidget);
    });

    testWidgets('a doubled text scale keeps the desk heading present',
        (tester) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense desk overflows at this scale in the harness alone; the contract is
      // that the content is still built.
      ignoreOverflow();
      await pumpAdmin(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('SportLynk Control Center'), findsOneWidget);
    });
  });
}
