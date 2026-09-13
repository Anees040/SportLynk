// Opponent discovery (FR5.3 – FR5.5): the one player screen whose list is always
// relative to one of *my* teams, so it opens with two sequential loads —
// `TeamService.mine` to learn which teams I have, then `MatchService.opponents`
// for the chosen one. The first paint is a spinner while `mine` is in flight, and
// the team picked is the first one I captain, because landing on a team whose
// Challenge buttons are all disabled would read as the feature being broken.
//
// Three outcomes are worth pinning apart. A player in no team is sent to create
// one — matchmaking has nothing to compare against without a team. A genuine read
// failure is distinguishable here, unlike on the sibling teams list: any failure
// collapses to `OpponentList.empty`, whose `myTeam` is null, and the screen reads a
// null `myTeam` as "the read failed" (find_opponents_screen.dart:103) rather than
// "nobody to play", showing "Could not load opponents" with a pull to retry. That
// is a real, reachable error state. An empty-but-successful list is the third case
// and shows a different sentence.
//
// The challenge affordance is gated by the payload's `canChallenge`, not by the
// local team role: a non-captain sees every row carrying a "Captains only" button
// and the notice that explains why, so no button fails with a 403 after the tap.
//
// Mount note: both loads read `AuthProvider.token`; `FakeAuth` supplies it. The
// fake keys on the path, so `/matches/opponents` answers regardless of the
// `teamId`/`q` query it carries. Challenge is asserted present but never tapped —
// the tap pushes `MatchChallengeScreen`, which is another screen's test.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/find_opponents_screen.dart';

import '../screen_harness.dart';

/// `TeamService.mine` and `MatchService.opponents` under the path-keyed fake.
const String kMine = '/teams/mine';
const String kOpponents = '/matches/opponents';

/// One row of `GET /teams/mine`, in the snake_case that endpoint emits. `role`
/// decides which team `_bootstrap` defaults to — the first captained one.
Map<String, dynamic> teamRow({
  String id = 't-1',
  String name = 'Lahore Lions',
  String sport = 'football',
  String? role = 'captain',
  Object elo = 1240,
  Object wins = 8,
  Object losses = 2,
  Object draws = 1,
}) => {
  'id': id,
  'name': name,
  'sport': sport,
  'visibility': 'public',
  'role': role,
  'elo': elo,
  'wins': wins,
  'losses': losses,
  'draws': draws,
  'channel_id': 'c-1',
  'member_count': 7,
  'logo_url': null,
  'tournament_played': 0,
  'tournament_wins': 0,
  'finals_reached': 0,
  'titles': 0,
};

/// A `MatchSide` in the camelCase the pairing endpoints emit — used for the
/// `myTeam` echo and, with the candidate fields folded in by [opponent], for each
/// row. A ranked side so the ELO pill and the "N apart" chip both render.
Map<String, dynamic> side({
  String id = 'opp-1',
  String name = 'Karachi Kings',
  int elo = 1250,
  bool ranked = true,
}) => {
  'id': id,
  'name': name,
  'city': 'Karachi',
  'elo': elo,
  'ranked': ranked,
  'displayElo': ranked ? elo : null,
  'played': 10,
  'wins': 6,
  'losses': 3,
  'draws': 1,
  'eloFrozen': false,
  'memberCount': 6,
  'trustScore': 80,
  'trustBand': 'trusted',
  'trustLabel': 'Trusted',
};

/// One `OpponentCandidate`: a [side] carrying the pairing-only fields the row
/// reads (`OpponentCandidate.fromJson` builds its team from the same map).
Map<String, dynamic> opponent({
  String id = 'opp-1',
  String name = 'Karachi Kings',
  int eloGap = 10,
  bool withinBand = true,
  int? competitiveness = 82,
}) => {
  ...side(id: id, name: name),
  'eloGap': eloGap,
  'withinBand': withinBand,
  'competitiveness': competitiveness,
  'matchesLast30d': 3,
  'reasons': const <String>[],
};

/// The `GET /matches/opponents` payload. `ranking` is omitted, so the fallback
/// (rating-gap) ordering is in force and no percentage is drawn.
Map<String, dynamic> opponentList({
  bool canChallenge = true,
  String myRole = 'captain',
  List<Map<String, dynamic>> opponents = const [],
}) => {
  'myTeam': side(id: 't-1', name: 'Lahore Lions', elo: 1240),
  'myRole': myRole,
  'canChallenge': canChallenge,
  'preferredBand': 400,
  'opponents': opponents,
};

Future<RouteLog> pumpFind(WidgetTester tester, {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const FindOpponentsScreen(),
    auth: FakeAuth(
      role: 'player',
      id: 'u-1',
      name: 'Bilal Ahmed',
      token: 'test-token',
    ),
    textScale: textScale,
  );
}

/// The screen chains two loads (`mine`, then the `opponents` load it triggers);
/// one `settleData` drains the first and a second drains the one it schedules.
Future<void> settleBoot(WidgetTester tester) async {
  await settleData(tester);
  await settleData(tester);
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('the teams gate', () {
    testWidgets('a spinner stands while the team load is in flight', (
      tester,
    ) async {
      api.ok(kMine, [teamRow()], delay: const Duration(milliseconds: 300));
      api.ok(kOpponents, opponentList(opponents: [opponent()]));
      await pumpFind(tester);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      await settleData(tester);
      expect(
        find.text('Lahore Lions'),
        findsOneWidget,
      ); // the "playing as" strip
    });

    testWidgets('a player in no team is sent to create one', (tester) async {
      api.ok(kMine, const []);
      await pumpFind(tester);
      await settleData(tester);

      expect(
        find.textContaining('Matchmaking works team-to-team.'),
        findsOneWidget,
      );
      expect(find.text('Create a team'), findsOneWidget);
    });
  });

  group('the opponent list', () {
    testWidgets('a loaded row is named and offers a challenge', (tester) async {
      api.ok(kMine, [teamRow()]);
      api.ok(
        kOpponents,
        opponentList(opponents: [opponent(name: 'Karachi Kings')]),
      );
      await pumpFind(tester);
      await settleBoot(tester);

      expect(find.text('Find Opponents'), findsOneWidget); // app-bar
      expect(find.text('Karachi Kings'), findsOneWidget);
      expect(find.text('Challenge'), findsOneWidget);
    });

    testWidgets('a failed read is a real error state, not an empty one', (
      tester,
    ) async {
      // `opponents` collapses failure to `OpponentList.empty` (myTeam null); the
      // screen reads that as the read having failed, distinct from "nobody to play".
      api.ok(kMine, [teamRow()]);
      api.fail(kOpponents, 'boom');
      await pumpFind(tester);
      await settleBoot(tester);

      expect(
        find.text('Could not load opponents. Pull down to try again.'),
        findsOneWidget,
      );
    });

    testWidgets('a successful but empty list says nobody is available', (
      tester,
    ) async {
      api.ok(kMine, [teamRow()]);
      api.ok(kOpponents, opponentList(opponents: const []));
      await pumpFind(tester);
      await settleBoot(tester);

      expect(
        find.textContaining(
          'No public teams available to challenge right now.',
        ),
        findsOneWidget,
      );
    });
  });

  group('the challenge gate', () {
    testWidgets('a non-captain sees the notice and a locked button', (
      tester,
    ) async {
      // The team is joined as a member, and the payload confirms `canChallenge`
      // is false, so the row carries "Captains only" rather than "Challenge".
      api.ok(kMine, [teamRow(role: 'member')]);
      api.ok(
        kOpponents,
        opponentList(
          canChallenge: false,
          myRole: 'member',
          opponents: [opponent()],
        ),
      );
      await pumpFind(tester);
      await settleBoot(tester);

      expect(
        find.text(
          'Only a captain can send challenges. You can still scout who is out there.',
        ),
        findsOneWidget,
      );
      expect(find.text('Captains only'), findsOneWidget);
      expect(find.text('Challenge'), findsNothing);
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps a row present', (tester) async {
      ignoreOverflow();
      api.ok(kMine, [teamRow()]);
      api.ok(kOpponents, opponentList(opponents: [opponent()]));
      await pumpFind(tester, textScale: 2.0);
      await settleBoot(tester);

      expect(find.text('Karachi Kings'), findsOneWidget);
    });
  });
}
