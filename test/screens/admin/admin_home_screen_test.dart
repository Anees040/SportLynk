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

import 'package:flutter/material.dart';
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
}) => {
  'id': 'reg-1',
  'verification_status': status,
  'owner_name': ownerName,
  'ground_name': groundName,
  'city': city,
  'price_per_hour': price,
};

/// One pending venue, in the shape `_venueCard` reads (admin_home:688).
Map<String, dynamic> venue({
  String id = 'v-1',
  String name = 'Champions Ground',
}) => {
  'id': id,
  'name': name,
  'owner_name': 'Bilal Traders',
  'city': 'Lahore',
  'address': 'Main Boulevard',
};

/// Mounts the desk as the super admin (sees every tab and tile) whose token is null,
/// which is what keeps the bell's bootstrap — socket, push registration, deep-link
/// replay — from starting.
Future<RouteLog> pumpAdmin(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
  Size size = const Size(430, 915),
}) {
  return pumpScreen(
    tester,
    const AdminHomeScreen(),
    auth: FakeAuth(
      role: 'admin',
      id: 'admin-1',
      name: 'Ops',
      token: null,
      isSuperAdmin: true,
    ),
    textScale: textScale,
    size: size,
  );
}

/// Mounts the desk as a sub-admin holding exactly [permissions] — for the gating
/// tests, which assert that a surface it lacks is neither shown nor loaded.
Future<RouteLog> pumpSub(
  WidgetTester tester,
  FakeApi api,
  List<String> permissions,
) {
  return pumpScreen(
    tester,
    const AdminHomeScreen(),
    auth: FakeAuth(
      role: 'admin',
      id: 'sub-1',
      name: 'Helper',
      token: null,
      permissions: permissions,
    ),
  );
}

/// Opens a sidebar destination and lets the drawer close and the list load settle.
/// The five-tab header became a navigation drawer, so a destination is reached by
/// opening the drawer and tapping its row rather than tapping a tab.
Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await tester.pumpAndSettle();
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
    testWidgets('a spinner stands while the stats are in flight', (
      tester,
    ) async {
      api.ok(kStats, stats(), delay: const Duration(milliseconds: 300));
      await pumpAdmin(tester, api);

      // The dashboard body is gated on `_loadingStats`; the other four loads move
      // their own counters and never clear this spinner (admin_home:294).
      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('SportLynk Control Center'), findsOneWidget);
    });

    testWidgets(
      'the loaded desk shows the banner, the stat cards and the counts',
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
      },
    );

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

    testWidgets('the sidebar lists the owner destinations', (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);

      // The destinations live in the navigation drawer now, not a tab bar.
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('Owners'), findsOneWidget);
      expect(find.text('Owners · Pending'), findsNothing);
      expect(find.text('Owners · Approved'), findsNothing);
      expect(find.text('Owners · Rejected'), findsNothing);
      expect(find.text('Venues'), findsOneWidget);
    });
  });

  group('when the stats fail to load', () {
    testWidgets(
      'a failed first load shows an error with a retry, not a zeroed desk',
      (tester) async {
        // Fixed: a failed stats load with nothing cached now shows an error-with-retry
        // instead of a desk reading zero across the board plus a transient
        // raw-exception snackbar (admin_home_screen.dart).
        api.fail(kStats, 'boom');
        await pumpAdmin(tester, api);
        await settleData(tester);

        expect(find.text('Failed to load stats: boom'), findsNothing);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('boom'), findsOneWidget);
      },
    );
  });

  group('the pending registrations tab', () {
    testWidgets(
      'one Owners destination filters all three registration statuses',
      (tester) async {
        await pumpAdmin(tester, api);
        await settleData(tester);
        await openTab(tester, 'Owners');

        expect(find.byType(ChoiceChip), findsNWidgets(3));
        expect(api.to(kRegs).last.param('status'), 'pending');

        api.ok(kRegs, [reg(ownerName: 'Approved Owner', status: 'approved')]);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Approved'));
        await settleData(tester);
        expect(api.to(kRegs).last.param('status'), 'approved');
        expect(find.text('Approved Owner'), findsOneWidget);
        expect(find.text('APPROVED'), findsOneWidget);

        api.ok(kRegs, [reg(ownerName: 'Rejected Owner', status: 'rejected')]);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Rejected'));
        await settleData(tester);
        expect(api.to(kRegs).last.param('status'), 'rejected');
        expect(find.text('Rejected Owner'), findsOneWidget);
        expect(find.text('REJECTED'), findsOneWidget);

        api.ok(kRegs, [reg()]);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Pending'));
        await settleData(tester);
        expect(api.to(kRegs).last.param('status'), 'pending');
        expect(find.text('Bilal Traders'), findsOneWidget);
        expectNoOverflow(tester);
      },
    );

    testWidgets(
      'owner filtering is retained when returning from the dashboard',
      (tester) async {
        await pumpAdmin(tester, api);
        await settleData(tester);
        await openTab(tester, 'Owners');

        api.ok(kRegs, [reg(ownerName: 'Approved Owner', status: 'approved')]);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Approved'));
        await settleData(tester);
        await openTab(tester, 'Dashboard');
        await openTab(tester, 'Owners');

        expect(api.to(kRegs).last.param('status'), 'approved');
        expect(find.text('Approved Owner'), findsOneWidget);
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Approved'))
              .selected,
          isTrue,
        );
      },
    );

    testWidgets('pending review shortcut opens the pending filter explicitly', (
      tester,
    ) async {
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'Owners');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Approved'));
      await settleData(tester);
      await openTab(tester, 'Dashboard');
      await tapVisible(tester, find.text('Review Pending Registrations'));
      await settleData(tester);

      expect(api.to(kRegs).last.param('status'), 'pending');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Pending'))
            .selected,
        isTrue,
      );
    });

    testWidgets('a registration renders its owner, ground, city and price', (
      tester,
    ) async {
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'Owners');

      expect(find.text('Bilal Traders'), findsOneWidget);
      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('Lahore'), findsOneWidget);
      expect(find.text('PKR 2500/hr'), findsOneWidget);
      // The card's status chip is the verification status, upper-cased.
      expect(find.text('PENDING'), findsOneWidget);
    });

    testWidgets('an empty queue says so rather than showing a blank tab', (
      tester,
    ) async {
      api.ok(kRegs, <dynamic>[]);
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'Owners');

      expect(find.text('No pending registrations'), findsOneWidget);
    });
  });

  group('the venues tab', () {
    testWidgets('an empty venue queue says so', (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'Venues');

      expect(find.text('No pending venues'), findsOneWidget);
    });

    testWidgets('a pending venue can be approved and the result is confirmed', (
      tester,
    ) async {
      api.ok(kVenues, [venue()]);
      api.ok('/admin/venues/v-1/approve', <String, dynamic>{});
      await pumpAdmin(tester, api);
      await settleData(tester);
      await openTab(tester, 'Venues');

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

    testWidgets('the Platform Settings action pushes the settings route', (
      tester,
    ) async {
      final routes = await pumpAdmin(tester, api);
      await settleData(tester);

      await tapVisible(tester, find.text('Platform Settings'));
      await tester.pumpAndSettle();

      expect(routes.sawRoute('/admin-settings'), isTrue);
    });
  });

  group('reach and scale', () {
    for (final size in [
      const Size(280, 653),
      const Size(320, 568),
      const Size(390, 844),
      const Size(844, 390),
      const Size(768, 1024),
      const Size(1440, 900),
    ]) {
      testWidgets('two cards per row at $size, including large text', (
        tester,
      ) async {
        await pumpAdmin(tester, api, size: size, textScale: 2);
        await settleData(tester);
        for (final pair in [
          ['Total Players', 'Active Venues'],
          ['Active Bookings', 'Pending Review'],
          ['Review Pending Registrations', 'Moderation Queue'],
          ['Match Disputes', 'Booking Disputes'],
        ]) {
          final left = tester.getRect(
            find.byKey(ValueKey('admin-card-${pair[0]}')),
          );
          final right = tester.getRect(
            find.byKey(ValueKey('admin-card-${pair[1]}')),
          );
          expect(left.top, right.top);
          expect(left.width, closeTo(right.width, 0.01));
          expect(left.height, right.height);
          expect(left.right, lessThan(right.left));
          expect(right.right, lessThanOrEqualTo(size.width));
        }
        expect(find.text('ADMIN'), findsNothing);
        expectNoOverflow(tester);
      });
    }

    testWidgets('the header icon buttons carry their tooltips', (tester) async {
      await pumpAdmin(tester, api);
      await settleData(tester);

      // Icon-only controls in the app bar name themselves for a screen reader. Log
      // out moved into the navigation drawer, so the bar carries the notification
      // bell, the moderation queue and the drawer's own menu button.
      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(find.byTooltip('Moderation queue'), findsOneWidget);
      expect(find.byTooltip('Open navigation menu'), findsOneWidget);

      // Log out is reachable from the drawer.
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Log out'), findsOneWidget);
    });

    testWidgets('a doubled text scale keeps the desk heading present', (
      tester,
    ) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense desk overflows at this scale in the harness alone; the contract is
      // that the content is still built.
      await pumpAdmin(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('SportLynk Control Center'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('permission gating', () {
    testWidgets('overview data cannot open without its permission', (
      tester,
    ) async {
      await pumpSub(tester, api, const ['user_management']);
      await settleData(tester);
      await tester.tap(find.byKey(const ValueKey('admin-card-Active Venues')));
      await settleData(tester);
      expect(api.countTo('/admin/venues/active'), 0);
      expect(find.text('SportLynk Control Center'), findsOneWidget);
    });
    testWidgets('the super admin sees the Manage Admins action', (
      tester,
    ) async {
      await pumpAdmin(tester, api);
      await settleData(tester);
      expect(find.text('Manage Admins'), findsOneWidget);
    });

    testWidgets('a sub-admin sees only its granted tile and no owner tabs', (
      tester,
    ) async {
      await pumpSub(tester, api, const ['user_management']);
      await settleData(tester);

      // The one granted surface is offered...
      expect(find.text('Users'), findsOneWidget);
      // ...and nothing it was not granted, including the super-admin-only tile.
      expect(find.text('Match Disputes'), findsNothing);
      expect(find.text('Platform Settings'), findsNothing);
      expect(find.text('Review Pending Registrations'), findsNothing);
      expect(find.text('Manage Admins'), findsNothing);
      // The dashboard itself still renders.
      expect(find.text('SportLynk Control Center'), findsOneWidget);

      // Without owner_approvals the sidebar offers no owner destinations either.
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Owners'), findsNothing);
      expect(find.text('Venues'), findsNothing);
    });

    testWidgets(
      'a sub-admin without review_moderation has no moderation icon',
      (tester) async {
        await pumpSub(tester, api, const ['user_management']);
        await settleData(tester);
        expect(find.byTooltip('Moderation queue'), findsNothing);
      },
    );

    testWidgets('a sub-admin never calls the endpoints it cannot use', (
      tester,
    ) async {
      await pumpSub(tester, api, const ['user_management']);
      await settleData(tester);
      // Stats is open to any admin; the gated reads must not fire.
      expect(api.countTo('/admin/stats'), 1);
      expect(api.countTo('/admin/disputes'), 0);
      expect(api.countTo('/admin/reviews/flagged'), 0);
      expect(api.countTo('/admin/registrations'), 0);
      expect(api.countTo('/admin/venues/pending'), 0);
    });
  });

  testWidgets('overview cards open the matching records', (tester) async {
    api.ok('/admin/users', {
      'items': [
        {'id': 'player-1', 'name': 'Ayesha Khan'},
      ],
      'nextCursor': null,
    });
    api.ok('/admin/venues/active', {
      'items': [venue(name: 'Live Ground')],
      'nextCursor': null,
    });
    api.ok('/admin/bookings/active', {
      'items': [
        {
          'id': 'booking-1',
          'venue_name': 'Booked Ground',
          'player_name': 'Ayesha Khan',
          'status': 'confirmed',
          'slot_date': '2026-10-21',
          'start_time': '18:00:00',
          'end_time': '19:00:00',
          'total_amount': '2500.00',
        },
      ],
      'nextCursor': null,
    });
    await pumpAdmin(tester, api);
    await settleData(tester);
    for (final entry in [
      ['Total Players', 'Ayesha Khan'],
      ['Active Venues', 'Live Ground'],
      ['Active Bookings', 'Booked Ground'],
    ]) {
      final card = find.byKey(ValueKey('admin-card-${entry[0]}'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text(entry[1]), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    expect(api.to('/admin/users').single.param('role'), 'player');
    expect(api.to('/admin/users').single.param('status'), 'all');
    final pending = find.byKey(const ValueKey('admin-card-Pending Review'));
    await tester.ensureVisible(pending);
    await tester.tap(pending);
    await tester.pumpAndSettle();
    expect(find.text('Bilal Traders'), findsOneWidget);
    expect(api.to(kRegs).last.param('status'), 'pending');
  });
}
