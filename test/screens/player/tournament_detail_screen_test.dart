// Tournament Detail consumes one raw payload so its overview, draw, table, teams
// and money tabs cannot drift apart. These cases exercise the loading, not-found and
// minimal loaded branches with the exact nested keys TournamentDetail.fromJson reads.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/tournament_detail_screen.dart';

import '../screen_harness.dart';

const String kDetail = '/tournaments/t-1';

Map<String, dynamic> tournament() => {
  'id': 't-1',
  'name': 'Lahore Sunday Cup',
  'sport': 'Football',
  'format': 'knockout',
  'status': 'open',
  'entryFee': 2000,
  'maxTeams': 8,
  'minTeams': 4,
  'teamsRegistered': 2,
  'teamsAccepted': 2,
  'spotsLeft': 6,
  'registrationOpen': true,
  'secondsToDeadline': 3600,
  'venue': {'id': 'v-1', 'name': 'Green Turf Arena', 'city': 'Lahore'},
};

Map<String, dynamic> detail({Map<String, dynamic>? viewer}) => {
  'tournament': tournament(),
  'teams': <Map<String, dynamic>>[],
  'counts': <String, dynamic>{},
  'bracket': <String, dynamic>{},
  'fixtures': <Map<String, dynamic>>[],
  'standings': <Map<String, dynamic>>[],
  'economics': <String, dynamic>{},
  'viewer': viewer ?? <String, dynamic>{},
};

Future<RouteLog> pumpDetail(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const TournamentDetailScreen(tournamentId: 't-1'),
    auth: FakeAuth(token: 'tournament-token'),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi()..install();
    api.ok(kDetail, detail());
  });

  group('the detail as it loads', () {
    testWidgets('shows a loader until the detail payload arrives', (
      tester,
    ) async {
      api.ok(kDetail, detail(), delay: const Duration(milliseconds: 300));
      await pumpDetail(tester, api);

      expectLoading(tester);
      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Lahore Sunday Cup'), findsOneWidget);
    });

    testWidgets('renders the overview and its draw-not-ready explanation', (
      tester,
    ) async {
      await pumpDetail(tester, api);
      await settleData(tester);

      expect(find.text('Lahore Sunday Cup'), findsOneWidget);
      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Rules'), findsOneWidget);

      await tester.tap(find.text('Fixtures'));
      await tester.pumpAndSettle();
      expect(find.text('The draw is not out yet'), findsOneWidget);
    });

    testWidgets(
      'a failed detail load shows the server message and retry-free state',
      (tester) async {
        api.fail(kDetail, 'This tournament was removed.');
        await pumpDetail(tester, api);
        await settleData(tester);

        expect(find.text('Tournament not found'), findsOneWidget);
        expect(find.text('This tournament was removed.'), findsOneWidget);
      },
    );
  });

  testWidgets('a captain who can register receives the server-gated action', (
    tester,
  ) async {
    api.ok(
      kDetail,
      detail(
        viewer: {
          'isCaptain': true,
          'canRegister': true,
          'canAfford': true,
          'walletBalance': 5000,
          'eligibleTeams': [
            {'id': 'team-1', 'name': 'Lahore Lions', 'elo': 1200},
          ],
        },
      ),
    );
    await pumpDetail(tester, api);
    await settleData(tester);

    expect(find.text('Enter for PKR 2,000'), findsOneWidget);
  });

  testWidgets('a doubled text scale keeps the tournament title present', (
    tester,
  ) async {
    ignoreOverflow();
    await pumpDetail(tester, api, textScale: 2.0);
    await settleData(tester);

    expect(find.text('Lahore Sunday Cup'), findsOneWidget);
  });
}
