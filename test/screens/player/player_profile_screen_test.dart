// The player's profile: a spinner on mount, then a GET of `/users/me/player`. Issue 6
// removed the fabricated degrade — a failed load no longer funnels into `_setFromAuth`
// and invented stats (ELO 1000, trust 100). A load that returns no profile now renders
// the mandated error card with a Retry (player_profile_screen.dart:227), and identity
// is watched from `AuthProvider` so a background refresh repaints the loaded view.
//
// Mount note: the load reads `auth.token`; `FakeAuth` supplies it, so the request is
// actually issued. The avatar fixture is left null so the CircleAvatar draws its
// initial rather than reaching the network for an Image.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/player_profile_screen.dart';

import '../screen_harness.dart';

/// The profile endpoint, path-keyed under the fake.
const String kProfile = '/users/me/player';

/// The document `_load` reads from `data`. `elo_rating`/`trust_score` are rounded for
/// display; `sport_preferences` is filtered to the two allowed sports on the way in.
Map<String, dynamic> profile({
  String name = 'Bilal Ahmed',
  String email = 'bilal@example.com',
  num elo = 1200,
  num trust = 92,
  List<String> sports = const ['Football', 'Cricket'],
}) => {
  'name': name,
  'email': email,
  'phone': '+923001234567',
  'avatar_url': null,
  'created_at': '2025-01-15T00:00:00.000Z',
  'elo_rating': elo,
  'trust_score': trust,
  'sport_preferences': sports,
};

Future<RouteLog> pumpProfile(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const PlayerProfileScreen(),
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
    api.ok(kProfile, profile());
  });

  group('the profile as it loads', () {
    testWidgets('a spinner stands while the load is in flight', (tester) async {
      api.ok(kProfile, profile(), delay: const Duration(milliseconds: 300));
      await pumpProfile(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Bilal Ahmed'), findsOneWidget);
    });

    testWidgets('a loaded profile shows identity, ELO and trust', (
      tester,
    ) async {
      await pumpProfile(tester, api);
      await settleData(tester);

      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('bilal@example.com'), findsOneWidget);
      expect(find.text('1200'), findsOneWidget); // ELO, rounded
      expect(find.text('ELO Rating'), findsOneWidget);
      expect(find.text('92/100'), findsOneWidget); // trust
      expect(find.text('Trust Score'), findsOneWidget);
    });

    testWidgets('the loaded interests render as chips', (tester) async {
      await pumpProfile(tester, api);
      await settleData(tester);

      expect(find.text('Football'), findsOneWidget);
      expect(find.text('Cricket'), findsOneWidget);
    });

    testWidgets('the account actions are offered', (tester) async {
      await pumpProfile(tester, api);
      await settleData(tester);

      expect(find.text('Change Password'), findsOneWidget);
      expect(find.text('Help & Support'), findsOneWidget);
      expect(find.text('Log Out'), findsOneWidget);
    });
  });

  group('when the load fails', () {
    testWidgets('the profile shows the retry state, not invented stats', (
      tester,
    ) async {
      // Issue 6: a failed read no longer fabricates defaults (ELO 1000, trust 100).
      // With no profile to show, the screen renders the mandated error card and a
      // retry rather than an identity dressed in invented numbers.
      api.fail(kProfile, 'boom');
      await pumpProfile(tester, api);
      await settleData(tester);

      expect(find.text('Could not load profile'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget); // the error branch now renders
      expect(find.text('100/100'), findsNothing); // no fabricated trust
      expect(find.text('1000'), findsNothing); // no fabricated ELO
      expect(find.text('Bilal Ahmed'), findsNothing); // no identity header on failure
    });
  });

  group('editing and actions', () {
    testWidgets('the Edit action reveals the editable form', (tester) async {
      await pumpProfile(tester, api);
      await settleData(tester);

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Full Name'), findsOneWidget);
      expect(find.text('Email Address'), findsOneWidget);
      expect(find.text('Save Changes'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget); // the toggled app-bar action
    });

    testWidgets('the change-password tile opens its sheet', (tester) async {
      await pumpProfile(tester, api);
      await settleData(tester);

      await tester.tap(find.text('Change Password'));
      await tester.pumpAndSettle();

      // Fields unique to the sheet — its title and button both repeat the tile label.
      expect(find.text('Current Password'), findsOneWidget);
      expect(find.text('New Password'), findsOneWidget);
      expect(find.text('Confirm Password'), findsOneWidget);
    });
  });

  group('logging out', () {
    testWidgets('the log-out tile raises a confirm dialog', (tester) async {
      await pumpProfile(tester, api);
      await settleData(tester);

      await tester.tap(find.text('Log Out'));
      await tester.pumpAndSettle();

      expect(find.text('Log Out?'), findsOneWidget);
      expect(find.text('You will need to log in again.'), findsOneWidget);
    });

    testWidgets('cancelling keeps the user on the profile', (tester) async {
      final log = await pumpProfile(tester, api);
      await settleData(tester);

      await tester.tap(find.text('Log Out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Log Out?'), findsNothing);
      expect(log.sawRoute('/welcome'), isFalse);
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the identity present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpProfile(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Bilal Ahmed'), findsOneWidget);
    });
  });
}
