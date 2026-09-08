// Team Rankings: the leaderboard, and the one screen in the player role that gets
// stale data right.
//
// Three contracts are pinned here, and they are the reason this file is longer than
// the screen deserves at first glance.
//
// The first is FR2.6, stated on the client at lib/models/team_stats.dart:17: a team's
// `displayElo` is null until it has a verified match, and no screen may substitute the
// 1000 seed for it. `RatingDisplay.eloLabel` is the only string a screen may print for
// a rating, and it answers 'Unranked' rather than a number. A regression here does not
// throw — it prints a plausible 1,000 next to a team that has never played — so the
// tests drive both an unranked row and a `ranked: true` row with a null `display_elo`
// and assert the word.
//
// The second is that `movement == null` is "NEW", not zero (team_stats.dart:38, and
// MovementBadge at lib/widgets/team_stat_widgets.dart:84). Absent and unchanged are
// different facts about a team's week, and the badge renders 'NEW', a dash, and a
// signed number as three distinct things. This is the same null-vs-zero rule the trust
// screen turns on, applied to a different column.
//
// The third is the stale-board behaviour at lib/screens/player/team_rankings_screen.dart:61-71
// and :143, which is correct and worth protecting. A failed refresh sets `_error` but
// leaves `_page` alone, so the previous board stays on screen under a banner reading
// "Showing the last loaded board — pull down to retry." rather than blanking out. A
// first-load failure, where there is no previous board, shows the full error with a
// Try again. Those two paths look similar in the code and are easy to collapse into
// one; four tests hold them apart.
//
// The city chips are asserted through the `city` query parameter rather than the chip
// label, because "All cities" must send no `city` at all — `city=All cities` would
// match nothing and render an empty board that reads as "nobody has played here".
// `_chips` is also deliberately retained across a filtered fetch (:44), so the row a
// user just tapped does not vanish and return; one test pins that.
//
// Every fixture below is snake_case. The file header at team_stats.dart:6 warns that
// routes/teams.js returns SQL columns (`logo_url`, `display_elo`, `is_mine`) while
// routes/matches.js hand-shapes camelCase, and that parsing the wrong casing yields a
// screen full of zeroes with no exception. Getting the casing wrong in a fixture would
// make these tests assert the failure mode while appearing to pass.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/team_rankings_screen.dart';
import 'package:sportlynk/widgets/team_stat_widgets.dart';

import '../screen_harness.dart';

/// One leaderboard row, in the casing `GET /teams/rankings` actually emits.
Map<String, dynamic> rankedTeam({
  String id = 't-1',
  String name = 'Lahore Lions',
  String sport = 'football',
  int rank = 1,
  Object? displayElo = 1240,
  bool ranked = true,
  Object? movement = 0,
  bool isMine = false,
  bool eloFrozen = false,
  String? city = 'Lahore',
  String? logoUrl,
  int wins = 8,
  int losses = 2,
  int draws = 1,
  int played = 11,
}) =>
    {
      'id': id,
      'name': name,
      'sport': sport,
      'rank': rank,
      'display_elo': displayElo,
      'ranked': ranked,
      'movement': movement,
      'is_mine': isMine,
      'elo_frozen': eloFrozen,
      'city': city,
      'logo_url': logoUrl,
      'wins': wins,
      'losses': losses,
      'draws': draws,
      'played': played,
      'member_count': 7,
    };

/// The whole payload. The chips come from the same query as the rows, which is why
/// this is an object and not a bare list.
Map<String, dynamic> rankingsPage({
  List<Map<String, dynamic>>? teams,
  List<Map<String, dynamic>>? cities,
  int rankedMinMatches = 1,
  int movementWindowDays = 7,
  String? city,
}) =>
    {
      'teams': teams ?? [rankedTeam()],
      'cities': cities ??
          [
            {'city': 'Lahore', 'teams': 4},
            {'city': 'Karachi', 'teams': 2},
          ],
      'rankedMinMatches': rankedMinMatches,
      'movementWindowDays': movementWindowDays,
      'city': city,
    };

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('while the board is loading', () {
    testWidgets('it shows a spinner', (tester) async {
      api.ok('/teams/rankings', rankingsPage(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TeamRankingsScreen());

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('it is titled before any data arrives', (tester) async {
      api.ok('/teams/rankings', rankingsPage(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TeamRankingsScreen());

      expect(find.text('Rankings'), findsOneWidget);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('it shows no city chips yet', (tester) async {
      // The chips come from the response, so a row of them before the first load
      // would mean they were invented locally.
      api.ok('/teams/rankings', rankingsPage(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TeamRankingsScreen());

      expect(find.text('All cities'), findsNothing);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('it asks the ranked-only endpoint once', (tester) async {
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(api.countTo('/teams/rankings'), 1);
    });

    testWidgets('the first load sends no city filter', (tester) async {
      // `_city` starts null, and the service omits the parameter entirely rather
      // than sending an empty string.
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(api.to('/teams/rankings').single.param('city'), isNull);
    });
  });

  group('once the board arrives', () {
    testWidgets('the top team is the hero card', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(name: 'Lahore Lions', rank: 1),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2, displayElo: 1180),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Lahore Lions'), findsNWidgets(2),
          reason: 'the leader appears in the hero and again in the list');
      expect(find.text('Karachi Kings'), findsOneWidget);
    });

    testWidgets('the hero states the sport it leads', (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(sport: 'football')]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.textContaining('#1 FOOTBALL'), findsOneWidget);
    });

    testWidgets('the leaderboard is headed and counted', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2),
        rankedTeam(id: 't-3', name: 'Multan Sultans', rank: 3),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Leaderboard'), findsOneWidget);
      expect(find.text('3 ranked'), findsOneWidget);
    });

    testWidgets('the movement column is explained rather than left to guesswork',
        (tester) async {
      // A signed number in a column of ratings is unreadable without the window it
      // is measured against, and the window comes from the server.
      api.ok('/teams/rankings', rankingsPage(movementWindowDays: 7));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Movement vs 7 days ago'), findsOneWidget);
    });

    testWidgets('the movement window is read from the response, not hardcoded',
        (tester) async {
      api.ok('/teams/rankings', rankingsPage(movementWindowDays: 30));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Movement vs 30 days ago'), findsOneWidget);
    });

    testWidgets('the top three rows are medals rather than numbers',
        (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2),
        rankedTeam(id: 't-3', name: 'Multan Sultans', rank: 3),
        rankedTeam(id: 't-4', name: 'Quetta Gladiators', rank: 4),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('🥇'), findsOneWidget);
      expect(find.text('🥈'), findsOneWidget);
      expect(find.text('🥉'), findsOneWidget);
      expect(find.text('#4'), findsOneWidget);
    });

    testWidgets('a row past third shows its number', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 12, name: 'Sialkot Stallions'),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('#12'), findsOneWidget);
    });

    testWidgets('a row states its record and win rate', (tester) async {
      // 8 of 11 is 73%, computed on the client by `RankedTeam.winRate` rather than
      // sent, so the arithmetic is worth one assertion.
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(wins: 8, losses: 2, draws: 1, played: 11, city: 'Lahore'),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(
        find.textContaining('W 8  L 2  D 1  ·  73%  ·  football'),
        findsOneWidget,
      );
    });

    testWidgets('a row without a city omits the separator rather than trailing one',
        (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(city: null, played: 0, wins: 0, losses: 0, draws: 0)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.textContaining('·  football'), findsOneWidget);
      expect(find.textContaining('football  ·'), findsNothing);
    });

    testWidgets('a played-nothing row reports zero rather than dividing by zero',
        (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(wins: 0, losses: 0, draws: 0, played: 0),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.textContaining('·  0%  ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the joining rule is stated', (tester) async {
      api.ok('/teams/rankings', rankingsPage(rankedMinMatches: 1));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(
        find.textContaining('A team joins the rankings after its first verified match'),
        findsOneWidget,
      );
    });

    testWidgets('the joining rule pluralises from the server threshold',
        (tester) async {
      // The threshold is FR2.6's, held on the server. Hardcoding "first match" here
      // would state a rule the backend no longer enforces.
      api.ok('/teams/rankings', rankingsPage(rankedMinMatches: 3));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(
        find.textContaining('A team joins the rankings after 3 verified matches'),
        findsOneWidget,
      );
    });

    testWidgets('a frozen rating is flagged', (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(eloFrozen: true)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.byIcon(Icons.ac_unit), findsOneWidget);
    });

    testWidgets('an unfrozen rating carries no flag', (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(eloFrozen: false)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.byIcon(Icons.ac_unit), findsNothing);
    });
  });

  group('the rating column, which may not invent a number', () {
    testWidgets('a ranked team shows its rating with a thousands separator',
        (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(ranked: true, displayElo: 1240)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('1,240'), findsNWidgets(2),
          reason: 'the hero and the row both print it');
    });

    testWidgets('an unranked team is called unranked, not seeded to 1000',
        (tester) async {
      // FR2.6. The 1000 seed exists in the database and must never reach a screen;
      // a regression prints a plausible number for a team that has never played.
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(ranked: false, displayElo: null),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Unranked'), findsNWidgets(2));
      expect(find.text('1,000'), findsNothing);
      expect(find.text('1000'), findsNothing);
    });

    testWidgets('a ranked flag with no rating is still unranked', (tester) async {
      // `eloLabel` requires both. Trusting the flag alone would print 'null' or
      // throw on the first inconsistent row the server sends.
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(ranked: true, displayElo: null),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Unranked'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a four-digit rating is separated and a three-digit one is not',
        (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1, displayElo: 1240),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2, displayElo: 980),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('1,240'), findsNWidgets(2));
      expect(find.text('980'), findsOneWidget);
    });
  });

  group('the movement badge, where absent is not zero', () {
    testWidgets('a team new to the board reads NEW', (tester) async {
      // team_stats.dart:38 — null means the team was not on the board a week ago,
      // which is a different fact from having held its place.
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(movement: null)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('NEW'), findsNWidgets(2));
    });

    testWidgets('a team that held its place reads as a dash, not a zero',
        (tester) async {
      // team_stat_widgets.dart:88 — "a zero next to a number column reads as a
      // score".
      api.ok('/teams/rankings', rankingsPage(teams: [rankedTeam(movement: 0)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('–'), findsNWidgets(2));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a climb shows the places gained and an up arrow', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [rankedTeam(movement: 3)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('3'), findsNWidgets(2));
      expect(find.byIcon(Icons.arrow_drop_up), findsNWidgets(2));
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    });

    testWidgets('a fall shows the magnitude without a minus sign', (tester) async {
      // The arrow carries the direction, so a '-2' beside a down arrow would say it
      // twice and read as a negative rating.
      api.ok('/teams/rankings', rankingsPage(teams: [rankedTeam(movement: -2)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('2'), findsNWidgets(2));
      expect(find.text('-2'), findsNothing);
      expect(find.byIcon(Icons.arrow_drop_down), findsNWidgets(2));
    });

    testWidgets('every row carries a badge', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1, movement: 2),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2, movement: null),
        rankedTeam(id: 't-3', name: 'Multan Sultans', rank: 3, movement: 0),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.byType(MovementBadge), findsNWidgets(4),
          reason: 'three rows plus the hero');
    });
  });

  group('the viewer own team', () {
    testWidgets('the leader being yours is said on the hero', (tester) async {
      // `is_mine` comes from the server, which is the only side that knows the
      // viewer. The badge could never appear when it was guessed from a `role`
      // field this endpoint does not send.
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(isMine: true)]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('YOUR TEAM'), findsOneWidget);
    });

    testWidgets('a row further down is badged YOU', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2, isMine: true),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('YOU'), findsOneWidget);
      expect(find.text('YOUR TEAM'), findsNothing,
          reason: 'the hero is not the viewer team here');
    });

    testWidgets('no team of yours means no badge anywhere', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('YOU'), findsNothing);
      expect(find.text('YOUR TEAM'), findsNothing);
    });
  });

  group('the city chips', () {
    testWidgets('a chip is offered per city that holds ranked teams',
        (tester) async {
      // Built from the response, so a chip can never lead to an empty board.
      api.ok('/teams/rankings', rankingsPage(cities: [
        {'city': 'Lahore', 'teams': 4},
        {'city': 'Karachi', 'teams': 2},
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('All cities'), findsOneWidget);
      expect(find.text('Lahore (4)'), findsOneWidget);
      expect(find.text('Karachi (2)'), findsOneWidget);
    });

    testWidgets('no cities means no chip row at all', (tester) async {
      api.ok('/teams/rankings', rankingsPage(cities: const []));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('All cities'), findsNothing);
    });

    testWidgets('picking a city sends it as a query parameter', (tester) async {
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      await tester.tap(find.text('Lahore (4)'));
      await tester.pump();
      await settleData(tester);

      expect(api.countTo('/teams/rankings'), 2);
      expect(api.to('/teams/rankings').last.param('city'), 'Lahore');
    });

    testWidgets('the chip label is not what is sent', (tester) async {
      // '(4)' is a count for the reader. Sending 'Lahore (4)' would match no row.
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      await tester.tap(find.text('Lahore (4)'));
      await tester.pump();
      await settleData(tester);

      expect(api.to('/teams/rankings').last.param('city'), isNot(contains('(')));
    });

    testWidgets('clearing back to all cities sends no city at all', (tester) async {
      // `city=All cities` would match nothing and render an empty board that reads
      // as "nobody has played here".
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);
      await tester.tap(find.text('Lahore (4)'));
      await tester.pump();
      await settleData(tester);

      await tester.tap(find.text('All cities'));
      await tester.pump();
      await settleData(tester);

      expect(api.countTo('/teams/rankings'), 3);
      expect(api.to('/teams/rankings').last.param('city'), isNull);
    });

    testWidgets('tapping the city already chosen refetches nothing',
        (tester) async {
      // `_pickCity` returns early on an unchanged value (:78), which keeps a
      // double tap from firing a second request and a second spinner.
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      await tester.tap(find.text('All cities'));
      await tester.pump();
      await settleData(tester);

      expect(api.countTo('/teams/rankings'), 1);
    });

    testWidgets('a filtered fetch keeps the chip row in place', (tester) async {
      // :44 — the chips are held from the last good load so the row a user just
      // tapped does not disappear and come back.
      api.ok('/teams/rankings', rankingsPage(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);
      await settleData(tester);

      await tester.tap(find.text('Karachi (2)'));
      await tester.pump();

      expect(find.text('Karachi (2)'), findsOneWidget,
          reason: 'still there while the filtered board is in flight');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await settleData(tester);
      await settleData(tester);
    });

    testWidgets('a filtered board with no teams says which city is empty',
        (tester) async {
      // Two different empty boards, because they need two different answers
      // (:264). "Nobody has played yet" is not "nobody in Karachi has".
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      api.ok('/teams/rankings', rankingsPage(teams: const []));
      await tester.tap(find.text('Karachi (2)'));
      await tester.pump();
      await settleData(tester);

      expect(find.textContaining('No ranked teams in Karachi yet.'), findsOneWidget);
      expect(find.text('Show all cities'), findsOneWidget);
    });

    testWidgets('the empty-city escape clears the filter', (tester) async {
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);
      api.ok('/teams/rankings', rankingsPage(teams: const []));
      await tester.tap(find.text('Karachi (2)'));
      await tester.pump();
      await settleData(tester);

      api.ok('/teams/rankings', rankingsPage());
      await tester.tap(find.text('Show all cities'));
      await tester.pump();
      await settleData(tester);

      expect(api.to('/teams/rankings').last.param('city'), isNull);
      expect(find.text('Lahore Lions'), findsNWidgets(2));
    });
  });

  group('when nobody has played yet', () {
    testWidgets('the empty board explains how to get on it', (tester) async {
      // Only teams with a verified match appear, so an empty board is the expected
      // first state of the product rather than an error.
      api.ok('/teams/rankings',
          rankingsPage(teams: const [], cities: const []));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(
        find.textContaining(
            'A team appears here after its first verified match — challenge someone and be the first.'),
        findsOneWidget,
      );
    });

    testWidgets('the empty board pluralises from the server threshold',
        (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: const [], cities: const [], rankedMinMatches: 3));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.textContaining('after 3 verified matches'), findsOneWidget);
    });

    testWidgets('an empty board is not an error', (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: const [], cities: const []));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.byIcon(Icons.emoji_events_outlined), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('the empty board can still be pulled to refresh', (tester) async {
      // `_message` uses AlwaysScrollableScrollPhysics so the gesture works with
      // nothing to scroll; without it the only way off an empty board is to leave.
      api.ok('/teams/rankings',
          rankingsPage(teams: const [], cities: const []));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(api.countTo('/teams/rankings'), greaterThan(1));
    });
  });

  group('when the first load fails', () {
    testWidgets('a server error is shown with a retry', (tester) async {
      api.fail('/teams/rankings', 'Rankings are unavailable.');

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Could not load rankings.'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a dropped connection is shown with a retry', (tester) async {
      // The symptom of a missing `adb reverse`, and the one a player is most likely
      // to hit. It must not read as an empty board.
      api.offline('/teams/rankings');

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('Could not load rankings.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a failure is not dressed up as an empty board', (tester) async {
      api.fail('/teams/rankings', 'boom');

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.textContaining('No ranked teams yet.'), findsNothing);
      expect(find.byIcon(Icons.emoji_events_outlined), findsNothing);
    });

    testWidgets('the retry refetches and can succeed', (tester) async {
      api.fail('/teams/rankings', 'boom');

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      api.ok('/teams/rankings', rankingsPage());
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await settleData(tester);

      expect(api.countTo('/teams/rankings'), 2);
      expect(find.text('Lahore Lions'), findsNWidgets(2));
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('the retry shows a spinner while it is in flight', (tester) async {
      api.fail('/teams/rankings', 'boom');

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      api.ok('/teams/rankings', rankingsPage(),
          delay: const Duration(milliseconds: 300));
      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await settleData(tester);
      await settleData(tester);
    });

    testWidgets('a failed first load shows no chip row', (tester) async {
      api.fail('/teams/rankings', 'boom');

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      expect(find.text('All cities'), findsNothing);
    });
  });

  group('when a refresh fails over a board already on screen', () {
    testWidgets('the previous board is kept rather than blanked', (tester) async {
      // :61-71 — null means the request failed, which is not the same as an empty
      // board. Losing the rows on a flaky connection is the regression this holds.
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      api.fail('/teams/rankings', 'boom');
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(find.text('Lahore Lions'), findsNWidgets(2));
    });

    testWidgets('a banner says the board is the last one loaded', (tester) async {
      // :143 — showing week-old ranks silently as though they were live is the
      // failure this banner exists to prevent.
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      api.fail('/teams/rankings', 'boom');
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(
        find.text('Showing the last loaded board — pull down to retry.'),
        findsOneWidget,
      );
    });

    testWidgets('the full-screen error does not replace the board', (tester) async {
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      api.fail('/teams/rankings', 'boom');
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(find.text('Could not load rankings.'), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a later success clears the stale banner', (tester) async {
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);
      api.fail('/teams/rankings', 'boom');
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);
      await tester.pump(const Duration(seconds: 1));

      api.ok('/teams/rankings', rankingsPage());
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text('Showing the last loaded board — pull down to retry.'),
        findsNothing,
      );
    });

    testWidgets('the chips survive a failed refresh', (tester) async {
      // :69-70 guards the assignment so a failed request cannot empty the row.
      api.ok('/teams/rankings', rankingsPage());

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      api.fail('/teams/rankings', 'boom');
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleData(tester);

      expect(find.text('Lahore (4)'), findsOneWidget);
      expect(find.text('Karachi (2)'), findsOneWidget);
    });
  });

  group('opening a team', () {
    testWidgets('tapping the hero pushes its roster', (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: [rankedTeam(name: 'Lahore Lions')]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      await tester.tap(find.text('Lahore Lions').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Lahore Lions'), findsWidgets,
          reason: 'the roster screen carries the name through');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row is a large enough target', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen());
      await settleData(tester);

      final size = tester.getSize(find.text('Karachi Kings'));
      expect(size.height, greaterThan(0));
      expectTapTarget(tester, find.ancestor(
        of: find.text('Karachi Kings'),
        matching: find.byType(InkWell),
      ).first);
    });
  });

  group('without a session', () {
    testWidgets('it sends an empty token rather than throwing', (tester) async {
      // :52 reads `token ?? ''`, unlike the screens that bang the token and crash
      // before first paint. The request goes out and comes back rejected.
      api.fail('/teams/rankings', 'Unauthorized', status: 401);

      await pumpScreen(
        tester,
        const TeamRankingsScreen(),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Could not load rankings.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the board does not clip', (tester) async {
      api.ok('/teams/rankings', rankingsPage(teams: [
        rankedTeam(rank: 1, name: 'Lahore Lions United FC', movement: 12),
        rankedTeam(id: 't-2', name: 'Karachi Kings', rank: 2, isMine: true),
      ]));

      await pumpScreen(tester, const TeamRankingsScreen(), textScale: 2.0);
      await settleData(tester);

      expectNoOverflow(tester);
    });

    testWidgets('the empty board does not clip', (tester) async {
      api.ok('/teams/rankings',
          rankingsPage(teams: const [], cities: const []));

      await pumpScreen(tester, const TeamRankingsScreen(), textScale: 2.0);
      await settleData(tester);

      expectNoOverflow(tester);
    });

    testWidgets('the error state does not clip', (tester) async {
      api.fail('/teams/rankings', 'boom');

      await pumpScreen(tester, const TeamRankingsScreen(), textScale: 2.0);
      await settleData(tester);

      expectNoOverflow(tester);
    });
  });
}
