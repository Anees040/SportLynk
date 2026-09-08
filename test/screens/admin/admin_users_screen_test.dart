// Admin users: a searched, keyset-paged account list with a suspend/reinstate
// cascade behind a bottom sheet. Two things it does not decide are the point of
// several tests here — a reason is mandatory before a suspension is sent, and an
// admin or the current user cannot be suspended from this screen at all.
//
// Mount note: unlike the admin home, this screen has no `NotificationBell`, so the
// default authenticated session is correct. `_load` returns early on a null token
// (admin_users_screen.dart:75), so a null-token mount would hang on its spinner;
// the harness's default `test-token` is what lets the first load run.
//
// Read failures do not surface here. `AdminService.users` returns an empty page on
// any non-success (admin_service.dart:128), and `_load` has no catch of its own, so
// a failed search reads as "no accounts match" — a real state the screen shows and
// a defect (there is no distinct error-with-retry) pinned by the test below.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_users_screen.dart';

import '../screen_harness.dart';

/// The list endpoint, as `ApiConstants.adminUsers` resolves it. Suspension posts to
/// a per-user path built from this.
const String kUsers = '/admin/users';

/// One account row, in the shape `AdminUserRow.fromJson` reads (models/admin.dart:624):
/// the counts and wallet arrive nested.
Map<String, dynamic> user({
  String id = 'u-9',
  String name = 'Ayesha Khan',
  String role = 'player',
  String? email = 'ayesha@example.com',
  String? phone = '+923001234567',
  bool suspended = false,
  String? suspendedReason,
  int bookings = 5,
  int venues = 0,
  num balance = 1500,
  num frozen = 0,
}) =>
    {
      'id': id,
      'name': name,
      'role': role,
      'email': email,
      'phone': phone,
      'suspended': suspended,
      if (suspendedReason != null) 'suspendedReason': suspendedReason,
      'counts': {'bookings': bookings, 'venues': venues},
      'wallet': {'balance': balance, 'frozen': frozen},
    };

/// A one-page list payload, in the shape `AdminService.users` reads (admin_service.dart:131).
Map<String, dynamic> page(
  List<Map<String, dynamic>> items, {
  bool hasMore = false,
  String? nextCursor,
}) =>
    {'items': items, 'hasMore': hasMore, 'nextCursor': nextCursor};

/// Mounts the screen. The default id is `u-1`, so a row with any other id is a
/// different account and is suspendable; pass a matching id to make a row "me".
Future<RouteLog> pumpUsers(
  WidgetTester tester,
  FakeApi api, {
  String myId = 'u-1',
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const AdminUsersScreen(),
    auth: FakeAuth(role: 'admin', id: myId, name: 'Ops', token: 'admin-token'),
    textScale: textScale,
  );
}

/// The reason/note field inside the open dialog, distinct from the search field
/// behind the barrier.
Finder dialogField() =>
    find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kUsers, page([user()]));
  });

  group('the list as it loads', () {
    testWidgets('a spinner stands while the first page is in flight',
        (tester) async {
      api.ok(kUsers, page([user()]), delay: const Duration(milliseconds: 300));
      await pumpUsers(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Ayesha Khan'), findsOneWidget);
    });

    testWidgets('a loaded account shows its name, role, contact and counts',
        (tester) async {
      await pumpUsers(tester, api);
      await settleData(tester);

      expect(find.text('Ayesha Khan'), findsOneWidget);
      // The role pill carries the server's own word; the filter chip says 'Players'.
      expect(find.text('player'), findsOneWidget);
      expect(find.text('ayesha@example.com · +923001234567'), findsOneWidget);
      expect(find.text('5 bookings'), findsOneWidget);
    });

    testWidgets('an empty result says no accounts match', (tester) async {
      api.ok(kUsers, page(const []));
      await pumpUsers(tester, api);
      await settleData(tester);

      expect(find.text('No accounts match this search.'), findsOneWidget);
    });

    testWidgets('a failed load reads as the empty state, not an error',
        (tester) async {
      // Defect, pinned rather than fixed: `AdminService.users` swallows a failure
      // into an empty page, so a 500 is indistinguishable from a genuinely empty
      // search. There is no error-with-retry state on this screen.
      api.fail(kUsers, 'boom');
      await pumpUsers(tester, api);
      await settleData(tester);

      expect(find.text('No accounts match this search.'), findsOneWidget);
    });
  });

  group('search and filters reach the query', () {
    testWidgets('typing reloads once, only after the debounce elapses',
        (tester) async {
      await pumpUsers(tester, api);
      await settleData(tester);
      expect(api.countTo(kUsers), 1, reason: 'one load on mount');

      await tester.enterText(find.byType(TextField).first, 'ali');
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.countTo(kUsers), 1, reason: 'still inside the 350ms debounce');

      await tester.pump(const Duration(milliseconds: 200));
      expect(api.countTo(kUsers), 2, reason: 'the debounce has fired one reload');
      expect(api.to(kUsers).last.param('q'), 'ali',
          reason: 'the typed text is sent as the q parameter');
    });

    testWidgets('a role chip sends that role on the next query', (tester) async {
      await pumpUsers(tester, api);
      await settleData(tester);

      await tester.tap(find.text('Owners'));
      await tester.pump();
      await tester.pump();

      expect(api.to(kUsers).last.param('role'), 'owner');
    });

    testWidgets('a status chip sends that status on the next query',
        (tester) async {
      await pumpUsers(tester, api);
      await settleData(tester);

      await tapVisible(tester, find.text('Suspended'));
      await tester.pump();
      await tester.pump();

      expect(api.to(kUsers).last.param('status'), 'suspended');
    });
  });

  group('paging', () {
    testWidgets('a further page is loaded on demand and appended',
        (tester) async {
      api.ok(kUsers, page([user(id: 'u-9', name: 'Ayesha Khan')],
          hasMore: true, nextCursor: 'c1'));
      await pumpUsers(tester, api);
      await settleData(tester);
      expect(find.text('Load more'), findsOneWidget);

      // The next page arrives on the same path (the fake ignores the cursor query),
      // so it is re-stubbed before the tap.
      api.ok(kUsers, page([user(id: 'u-2', name: 'Kaleem Raza')]));
      await tapVisible(tester, find.text('Load more'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Ayesha Khan'), findsOneWidget);
      expect(find.text('Kaleem Raza'), findsOneWidget);
      expect(find.text('Load more'), findsNothing,
          reason: 'the second page reports no more, so the control retires');
    });
  });

  group('the account sheet', () {
    testWidgets('a suspendable account offers to suspend', (tester) async {
      await pumpUsers(tester, api);
      await settleData(tester);

      await tester.tap(find.text('Ayesha Khan'));
      await tester.pumpAndSettle();

      expect(find.text('Suspend this account'), findsOneWidget);
    });

    testWidgets('the current user cannot be suspended from here', (tester) async {
      // Mounted as `u-9`, which is the row's id, so the card is "me".
      await pumpUsers(tester, api, myId: 'u-9');
      await settleData(tester);

      expect(find.text('you'), findsOneWidget,
          reason: 'the card marks the current admin');
      await tester.tap(find.text('Ayesha Khan'));
      await tester.pumpAndSettle();

      expect(find.text('You cannot suspend your own account.'), findsOneWidget);
      expect(find.text('Suspend this account'), findsNothing);
    });

    testWidgets('an admin account cannot be suspended from here', (tester) async {
      api.ok(kUsers, page([user(role: 'admin', name: 'Root Admin')]));
      await pumpUsers(tester, api);
      await settleData(tester);

      await tester.tap(find.text('Root Admin'));
      await tester.pumpAndSettle();

      expect(find.text('Admin accounts cannot be suspended from here.'),
          findsOneWidget);
      expect(find.text('Suspend this account'), findsNothing);
    });
  });

  group('suspending an account', () {
    Future<void> openSuspendDialog(WidgetTester tester) async {
      await tester.tap(find.text('Ayesha Khan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suspend this account'));
      await tester.pumpAndSettle();
    }

    testWidgets('an empty reason is refused in the client, costing no request',
        (tester) async {
      await pumpUsers(tester, api);
      await settleData(tester);
      await openSuspendDialog(tester);

      expect(find.text('Suspend Ayesha Khan?'), findsOneWidget);
      // Confirm with no reason: the dialog validates and sends nothing.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Suspend'));
      await tester.pump();

      expect(find.text('A reason is required — the user is told it.'),
          findsOneWidget);
      expect(api.countTo('/admin/users/u-9/suspend'), 0);
    });

    testWidgets('a reasoned suspension posts and surfaces the server receipt',
        (tester) async {
      api.on(
        '/admin/users/u-9/suspend',
        FakeResponse(
          200,
          jsonEncode({
            'success': true,
            'message': 'Ayesha Khan has been suspended.',
            'data': {'userId': 'u-9', 'suspended': true, 'name': 'Ayesha Khan'},
          }),
        ),
      );
      await pumpUsers(tester, api);
      await settleData(tester);
      await openSuspendDialog(tester);

      await tester.enterText(dialogField(), 'Repeated no-shows across venues.');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Suspend'));
      await tester.pumpAndSettle();

      expect(api.countTo('/admin/users/u-9/suspend'), 1);
      expect(find.text('Ayesha Khan has been suspended.'), findsOneWidget);
      final body =
          jsonDecode(api.to('/admin/users/u-9/suspend').single.body!) as Map;
      expect(body['reason'], 'Repeated no-shows across venues.');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('reach and scale', () {
    testWidgets('the refresh control names itself', (tester) async {
      await pumpUsers(tester, api);
      await settleData(tester);

      expect(find.byTooltip('Refresh'), findsOneWidget);
    });

    testWidgets('a doubled text scale keeps an account present', (tester) async {
      ignoreOverflow();
      await pumpUsers(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Ayesha Khan'), findsOneWidget);
    });
  });
}
