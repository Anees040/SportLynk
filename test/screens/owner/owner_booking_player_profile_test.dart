import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_booking_requests_screen.dart';
import 'package:sportlynk/screens/player/trust_score_screen.dart';
import 'package:sportlynk/screens/shared/public_profile_screen.dart';
import 'package:sportlynk/widgets/trust_widgets.dart';

import '../screen_harness.dart';

const profilePath = '/owner/bookings/booking-1/player-profile';

Map<String, dynamic> profile({bool isPublic = true}) => {
  'id': 'actual-player', 'name': 'Sara Ali', 'isPublic': isPublic,
  'isSelf': false, 'trustScore': '88', 'eloRating': 1180,
  'memberSince': '2025-01-01T00:00:00Z',
  if (isPublic) ...{
    'bio': 'Weekend football player.', 'sports': ['football'],
    'bookings30d': 3, 'teams': [],
  },
};

Future<void> openBookings(WidgetTester tester, FakeApi api, {String? playerId}) async {
  // Older cached responses can lack player_id. The booking still resolves its player.
  api.ok('/owner/bookings', [{
    'id': 'booking-1', 'player_name': 'Sara Ali', 'trust_score': '88',
    'player_id': ?playerId,
    'sport_preferences': ['Football'], 'slot_date': '2026-10-21',
    'start_time': '18:00:00', 'end_time': '19:00:00', 'total_amount': 2000,
  }]);
  await pumpScreen(tester, const OwnerBookingRequestsScreen(),
    auth: FakeAuth(role: 'owner', id: 'venue-owner', token: 'owner-token'));
  await settleData(tester);
}

void main() {
  late FakeApi api;
  setUp(() { api = FakeApi()..install(); });

  for (final tab in ['Pending (1)', 'Confirmed', 'Rejected']) {
    testWidgets('$tab opens a read-only player profile and trust breakdown', (tester) async {
      api.ok(profilePath, profile());
      api.ok('/users/actual-player/reviews', {
        'userId': 'actual-player', 'trust': {'score': 88}, 'reviews': [],
      });
      await openBookings(tester, api);
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View player profile'));
      await tester.pumpAndSettle();

      expect(api.countTo(profilePath), 1);
      expect(find.byType(PublicProfileScreen), findsOneWidget);
      expect(find.text('Sara Ali'), findsOneWidget);
      expect(find.text('88/100'), findsOneWidget);
      expect(find.text('Trust score'), findsOneWidget);
      expect(find.text('Weekend football player.'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      expect(find.text('Edit Profile'), findsNothing);
      expect(api.requests.every((r) => r.method == 'GET'), isTrue);

      await tester.tap(find.text('Trust score'));
      await tester.pumpAndSettle();
      final trustScreen = tester.widget<TrustScoreScreen>(find.byType(TrustScoreScreen));
      expect(trustScreen.userId, 'actual-player');
      expect(trustScreen.isSelf, isFalse);
      expect(tester.widget<TrustGauge>(find.byType(TrustGauge)).score, 88);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('View player profile'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Approve'),
          tab.startsWith('Pending') ? findsOneWidget : findsNothing);
      expect(api.requests.every((r) => r.method == 'GET'), isTrue);
    });
  }

  testWidgets('private profiles still show the player and trust score', (tester) async {
    api.ok(profilePath, profile(isPublic: false));
    await openBookings(tester, api);
    await tester.tap(find.text('View player profile'));
    await tester.pumpAndSettle();
    expect(find.text('Sara Ali'), findsOneWidget);
    expect(find.text('88/100'), findsOneWidget);
    expect(find.text('This profile is private'), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('a failed player profile can be retried without losing the booking', (tester) async {
    api.fail(profilePath, 'Unable to load profile');
    await openBookings(tester, api);
    await tester.tap(find.text('View player profile'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load profile'), findsOneWidget);
    expect(find.text('Unable to load profile'), findsOneWidget);
    expect(find.text('Check your connection and try again.'), findsNothing);
    api.ok(profilePath, profile());
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('88/100'), findsOneWidget);
    expect(api.countTo(profilePath), 2);
  });

  testWidgets('confirmed bookings load the public profile on an older backend', (tester) async {
    api.fail(profilePath, 'Route not found', status: 404);
    api.ok('/users/actual-player/public-profile', profile());
    await openBookings(tester, api, playerId: 'actual-player');
    await tester.tap(find.text('Confirmed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View player profile'));
    await tester.pumpAndSettle();

    expect(find.text('Sara Ali'), findsOneWidget);
    expect(find.text('Weekend football player.'), findsOneWidget);
    expect(find.text('88/100'), findsOneWidget);
    expect(find.text('Could not load profile'), findsNothing);
    expect(api.countTo(profilePath), 1);
    expect(api.countTo('/users/actual-player/public-profile'), 1);
    expect(api.requests.every((r) => r.method == 'GET'), isTrue);
  });

  for (final failure in [
    (status: 401, message: 'Token expired. Please log in again.'),
    (status: 403, message: 'Access denied'),
    (status: 404, message: 'Booking not found.'),
    (status: 500, message: 'Internal server error'),
  ]) {
    testWidgets('${failure.status} shows the API error without bypassing the booking lookup', (tester) async {
      api.fail(profilePath, failure.message, status: failure.status);
      await openBookings(tester, api, playerId: 'actual-player');
      await tester.tap(find.text('View player profile'));
      await tester.pumpAndSettle();

      expect(find.text(failure.message), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsNothing);
      expect(api.countTo('/users/actual-player/public-profile'), 0);
    });
  }

  testWidgets('a missing route without a cached player ID reports server unavailability', (tester) async {
    api.fail(profilePath, 'Route not found', status: 404);
    await openBookings(tester, api);
    await tester.tap(find.text('View player profile'));
    await tester.pumpAndSettle();
    expect(find.text('Player profiles are unavailable on the server. Please try again later.'), findsOneWidget);
    expect(api.requests.any((r) => r.path.contains('/users/')), isFalse);
  });

  testWidgets('a malformed profile stops loading and can be retried', (tester) async {
    api.ok(profilePath, {...profile(), 'teams': false});
    await openBookings(tester, api);
    await tester.tap(find.text('View player profile'));
    await tester.pumpAndSettle();
    expect(find.text('The server returned an invalid player profile. Please try again.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    api.ok(profilePath, profile());
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Sara Ali'), findsOneWidget);
  });
}
