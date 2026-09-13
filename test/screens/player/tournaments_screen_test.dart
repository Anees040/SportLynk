// Tournaments separates a server-filtered browse list from the user's own cups.
// The fixtures use the browse endpoint's nested `tournaments` payload and the
// mine endpoint's two lists, matching TournamentService rather than a local model.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/tournaments_screen.dart';

import '../screen_harness.dart';

const String kTournaments = '/tournaments';
const String kMine = '/tournaments/mine';

Map<String, dynamic> tournament({
  String id = 't-1',
  String name = 'Lahore Sunday Cup',
  String sport = 'Football',
}) => {
  'id': id,
  'name': name,
  'sport': sport,
  'format': 'knockout',
  'status': 'open',
  'entryFee': 2000,
  'maxTeams': 8,
  'minTeams': 4,
  'teamsRegistered': 3,
  'teamsAccepted': 2,
  'teamsPending': 1,
  'spotsLeft': 5,
  'registrationDeadline': '2026-09-20T18:00:00Z',
  'startDate': '2026-09-25',
  'slotMinutes': 60,
  'secondsToDeadline': 3600,
  'registrationOpen': true,
  'isFull': false,
  'venue': {
    'id': 'v-1',
    'name': 'Green Turf Arena',
    'city': 'Lahore',
    'sportType': 'football',
  },
};

Map<String, dynamic> mine() => {
  'organising': <Map<String, dynamic>>[],
  'playing': <Map<String, dynamic>>[],
};

Future<RouteLog> pumpTournaments(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const TournamentsScreen(),
    auth: FakeAuth(token: 'tournament-token'),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi()..install();
    api.ok(kTournaments, {
      'tournaments': [tournament()],
    });
    api.ok(kMine, mine());
  });

  group('the browse list', () {
    testWidgets('shows a loader while the browse request is in flight', (
      tester,
    ) async {
      api.ok(kTournaments, {
        'tournaments': [tournament()],
      }, delay: const Duration(milliseconds: 300));
      await pumpTournaments(tester, api);

      expectLoading(tester);
      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Lahore Sunday Cup'), findsOneWidget);
    });

    testWidgets('renders the tournament card and its entry facts', (
      tester,
    ) async {
      await pumpTournaments(tester, api);
      await settleData(tester);

      expect(find.text('Lahore Sunday Cup'), findsOneWidget);
      expect(find.text('FOOTBALL'), findsOneWidget);
      expect(find.text('PKR 2,000'), findsOneWidget);
      expect(find.text('5 spots left'), findsOneWidget);
      expect(find.text('Enter'), findsOneWidget);
    });

    testWidgets('an empty browse result explains that no tournaments exist', (
      tester,
    ) async {
      api.ok(kTournaments, {'tournaments': <Map<String, dynamic>>[]});
      await pumpTournaments(tester, api);
      await settleData(tester);

      expect(find.text('No tournaments yet'), findsOneWidget);
      expect(
        find.textContaining('Venue owners post tournaments here'),
        findsOneWidget,
      );
    });

    testWidgets('a failed browse reads as the empty state, not a retry state', (
      tester,
    ) async {
      // Defect, pinned rather than fixed: TournamentService converts a failed
      // response into an empty list, so `_error` never receives a value and the
      // screen cannot distinguish an outage from a genuinely empty browse page.
      api.fail(kTournaments, 'tournament service unavailable');
      await pumpTournaments(tester, api);
      await settleData(tester);

      expect(find.text('No tournaments yet'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });

  testWidgets('selecting a sport sends the server filter', (tester) async {
    await pumpTournaments(tester, api);
    await settleData(tester);
    final before = api.countTo(kTournaments);

    await tapVisible(tester, find.text('Cricket'));
    await settleData(tester);

    expect(api.countTo(kTournaments), before + 1);
    expect(api.to(kTournaments).last.param('sport'), 'Cricket');
  });

  testWidgets('the My cups tab explains an empty membership', (tester) async {
    await pumpTournaments(tester, api);
    await settleData(tester);

    await tester.tap(find.text('My cups'));
    await tester.pumpAndSettle();

    expect(find.text('You are not in a tournament yet'), findsOneWidget);
    expect(find.text('Browse tournaments'), findsOneWidget);
  });

  testWidgets('a doubled text scale keeps the card title present', (
    tester,
  ) async {
    ignoreOverflow();
    await pumpTournaments(tester, api, textScale: 2.0);
    await settleData(tester);

    expect(find.text('Lahore Sunday Cup'), findsOneWidget);
  });
}
