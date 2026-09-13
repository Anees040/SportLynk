// The owner's tournament list is a typed read over /tournaments/mine. Its service
// intentionally returns an empty model on a failed read; that current behavior is
// held explicitly so a future error state can change the expectation deliberately.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_tournaments_screen.dart';

import '../screen_harness.dart';

const String kMine = '/tournaments/mine';

Map<String, dynamic> tournament({
  String id = 't-1',
  String name = 'Friday Night Cup',
  String status = 'open',
  int ownerEarning = 0,
}) => {
  'id': id,
  'name': name,
  'sport': 'Football',
  'format': 'knockout',
  'status': status,
  'venue': {'id': 'v-1', 'name': 'Green Turf Arena', 'city': 'Lahore'},
  'entryFee': 2000,
  'maxTeams': 8,
  'minTeams': 4,
  'teamsRegistered': 2,
  'teamsAccepted': 2,
  'teamsPending': 0,
  'spotsLeft': 6,
  'registrationOpen': status == 'open',
  'secondsToDeadline': 86400,
  'ownerEarning': ownerEarning,
  'venueCost': 6000,
  'prize': 1200,
};

Future<void> settleTournaments(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 120));
}

Future<RouteLog> pumpTournaments(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerTournamentsScreen(),
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
    api.ok(kMine, {
      'organising': [tournament()],
      'playing': const [],
    });
  });

  group('the list', () {
    testWidgets('shows a loading indicator before the mine call returns', (
      tester,
    ) async {
      api.ok(kMine, {
        'organising': [tournament()],
      }, delay: const Duration(milliseconds: 300));
      await pumpTournaments(tester, api);
      expectLoading(tester);

      await tester.pump(const Duration(milliseconds: 400));
      await settleTournaments(tester);
      expect(find.text('Friday Night Cup'), findsOneWidget);
    });

    testWidgets('a live tournament shows the earnings strip and facts', (
      tester,
    ) async {
      await pumpTournaments(tester, api);
      await settleTournaments(tester);

      expect(find.text('My tournaments'), findsOneWidget);
      expect(find.text('Friday Night Cup'), findsOneWidget);
      expect(find.text('Earned from finished tournaments'), findsOneWidget);
      expect(find.text('1 live · nothing has settled yet'), findsOneWidget);
      expect(find.text('PKR 2,000'), findsOneWidget);
    });

    testWidgets('an empty organising list offers the first-post action', (
      tester,
    ) async {
      api.ok(kMine, {'organising': const [], 'playing': const []});
      await pumpTournaments(tester, api);
      await settleTournaments(tester);

      expect(find.text('No tournaments yet'), findsOneWidget);
      expect(find.text('Post your first one'), findsOneWidget);
    });

    testWidgets('a failed mine call reads as the empty list, not an error', (
      tester,
    ) async {
      // Defect, pinned: TournamentService.mine returns MyTournaments.empty on any
      // non-success, so the screen cannot distinguish a failed read from no rows.
      api.fail(kMine, 'boom');
      await pumpTournaments(tester, api);
      await settleTournaments(tester);

      expect(find.text('No tournaments yet'), findsOneWidget);
    });
  });

  group('reach and scale', () {
    testWidgets('refresh asks for the mine page again', (tester) async {
      await pumpTournaments(tester, api);
      await settleTournaments(tester);
      expect(api.countTo(kMine), 1);

      await tester.fling(find.byType(ListView), const Offset(0, 300), 1200);
      await tester.pump(const Duration(seconds: 1));
      await settleTournaments(tester);

      expect(api.countTo(kMine), 2);
    });

    testWidgets('a doubled text scale keeps the tournament card present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpTournaments(tester, api, textScale: 2.0);
      await settleTournaments(tester);

      expect(find.text('Friday Night Cup'), findsOneWidget);
    });
  });
}
