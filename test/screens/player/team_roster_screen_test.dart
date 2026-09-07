// Team Roster ("Group info"): the largest screen in the player role, and the only one
// that is simultaneously a public profile and an admin console. What a viewer sees is
// decided by the `role` field on the payload, re-checked by the backend on every write,
// so most of this file is about which affordances appear for which role.
//
// Five contracts are pinned.
//
// The first is FR2.6 again, and it is stated at lib/screens/player/team_roster_screen.dart:56:
// the header's rating comes from the `stats` block, which knows whether the team is
// ranked, and falls back to the team's own record only for the counts, never for the
// rating. `Team.elo` (lib/models/team.dart:82) defaults to the 1000 seed and has no way
// to say "Unranked", so printing it here showed every new team a confident 1000 it had
// not earned. Three tests drive an unranked stats block, a missing stats block, and a
// ranked one, and assert the three different things the tile prints.
//
// The second is role gating. A captain gets the edit action, the member sheet, the
// invite console, join requests and the suggested-players rail; a vice captain gets the
// invite console and requests but not the edit action or the member sheet; a member gets
// none of it and a Leave button; and a visitor arriving from the leaderboard gets no
// Leave button at all, because :661 records that offering one to a non-member is
// offering a button that can only fail. That is four viewers, and a regression that
// widens a check by one role is invisible without a test per role.
//
// The third is the suggested-players rail's three-way state (:51-57 and
// lib/widgets/reco_widgets.dart:407-425). It is kept out of the `Future.wait` that loads
// requests and invites for two stated reasons — it returns a typed model, and a slow ML
// round-trip must not hold the console hostage — and it distinguishes a genuine empty
// pool from a failed read from still loading. `_suggestFailed = s == null` at :178 is
// the whole mechanism: the service returns null for a failure and an empty list for
// "nobody to suggest", and collapsing those two would tell a captain there are no
// players near them when the ML service is simply down.
//
// The fourth is that `eloDelta` may not print "+0" (lib/models/team_stats.dart:260). A
// verified match can be unrated when the rating is frozen under ER2.3, which is not a
// dispute, and a "+0" beside it would imply a rated draw. The frozen notice at :625 is
// the same rule stated in words.
//
// The fifth is the error state, which this screen gets right: `_error` is set from the
// server's own message and rendered with a Try again that refetches (:537, :666). Two
// tests hold the retry, and one holds the missing-id path at :91, which is reachable
// because the screen takes a nullable `teamId`.
//
// Every fixture below is snake_case except the two keys the endpoint hand-shapes:
// `channelId` and the `homeCity` inside the suggested-players `team` block. The header
// at lib/models/team_stats.dart:6 warns that both conventions are live in this app and
// that reading the wrong one yields nulls with no exception, so the casing here is
// copied from each model's `fromJson` rather than guessed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/team_roster_screen.dart';
import 'package:sportlynk/widgets/team_stat_widgets.dart';

import '../screen_harness.dart';

/// One roster row, in the casing `GET /teams/:id` emits.
Map<String, dynamic> member({
  String id = 'u-2',
  String name = 'Usman Tariq',
  String role = 'member',
  Object? playerElo = 1120,
  String? avatarUrl,
  String? lastSeenAt,
}) =>
    {
      'id': id,
      'name': name,
      'role': role,
      'player_elo': playerElo,
      'avatar_url': avatarUrl,
      'trust_score': 82,
      'last_seen_at': lastSeenAt,
    };

/// The `stats` block. It exists precisely so the profile can say "Unranked".
Map<String, dynamic> stats({
  int wins = 8,
  int losses = 2,
  int draws = 1,
  int played = 11,
  int winRate = 73,
  bool ranked = true,
  Object? displayElo = 1240,
  bool eloFrozen = false,
  String form = 'WWLDW',
  int activity30d = 4,
  int activityWindowDays = 30,
  int rankedMinMatches = 1,
}) =>
    {
      'wins': wins,
      'losses': losses,
      'draws': draws,
      'played': played,
      'win_rate': winRate,
      'ranked': ranked,
      'display_elo': displayElo,
      'elo_frozen': eloFrozen,
      'form': form,
      'activity_30d': activity30d,
      'activity_window_days': activityWindowDays,
      'ranked_min_matches': rankedMinMatches,
    };

/// One point on the rating chart, which is also one row of the match history.
Map<String, dynamic> eloPoint({
  String matchId = 'm-1',
  int eloAt = 1240,
  String? at = '2026-08-01T18:00:00Z',
  bool verified = true,
  bool disputed = false,
  bool rated = true,
  String? opponentName = 'Karachi Kings',
  int myScore = 2,
  int theirScore = 1,
  String result = 'win',
  Object? eloDelta = 18,
}) =>
    {
      'match_id': matchId,
      'elo_at': eloAt,
      'at': at,
      'status': 'verified',
      'verified': verified,
      'disputed': disputed,
      'rated': rated,
      'opponent_id': 't-9',
      'opponent_name': opponentName,
      'opponent_logo': null,
      'my_score': myScore,
      'their_score': theirScore,
      'result': result,
      'elo_delta': eloDelta,
    };

/// The whole `GET /teams/:id` payload: the team row, plus the two stat blocks that
/// cannot live on [Team].
Map<String, dynamic> teamDetail({
  String id = 't-1',
  String name = 'Lahore Lions',
  String sport = 'football',
  String visibility = 'public',
  String? role = 'captain',
  String? bio,
  String? city = 'Lahore',
  List<Map<String, dynamic>>? roster,
  Map<String, dynamic>? statsBlock,
  List<Map<String, dynamic>>? eloHistory,
}) =>
    {
      'id': id,
      'name': name,
      'sport': sport,
      'visibility': visibility,
      'role': role,
      'bio': bio,
      'logo_url': null,
      'city': city,
      'elo': 1000,
      'wins': 8,
      'losses': 2,
      'draws': 1,
      'channelId': 'c-1',
      'captain_id': 'u-1',
      'member_count': 2,
      'roster': roster ??
          [
            member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain', playerElo: 1300),
            member(),
          ],
      'stats': statsBlock ?? stats(),
      'eloHistory': eloHistory ?? [eloPoint()],
    };

/// One pending join request.
Map<String, dynamic> joinRequest({
  String id = 'r-1',
  String name = 'Hamza Sheikh',
  Object? playerElo = 1080,
  String message = 'Left winger, free on weekends.',
}) =>
    {
      'id': id,
      'name': name,
      'player_elo': playerElo,
      'avatar_url': null,
      'message': message,
    };

/// One live invite link.
Map<String, dynamic> invite({
  String id = 'inv-1',
  String tokenPrefix = 'A1B2',
  String? expiresAt = '2026-09-30T12:00:00Z',
}) =>
    {
      'id': id,
      'token_prefix': tokenPrefix,
      'expires_at': expiresAt,
    };

/// The suggested-players payload. `homeCity` is camelCase because the server
/// hand-shapes this block.
Map<String, dynamic> suggested({
  List<Map<String, dynamic>>? suggestions,
  bool available = true,
  String? fallbackNote,
  int? considered = 12,
}) =>
    {
      'team': {
        'id': 't-1',
        'sport': 'football',
        'city': 'Lahore',
        'homeCity': 'Lahore',
      },
      'ranking': {
        'source': available ? 'reco-rank-v1' : 'unavailable',
        'available': available,
        'considered': considered,
        'fallbackNote': fallbackNote,
      },
      'suggestions': suggestions ?? const [],
    };

/// Registers the three admin-console fixtures so an admin viewer does not fall through
/// to a 404 that would read as an empty console.
void stubAdminExtras(FakeApi api, {
  List<Map<String, dynamic>> requests = const [],
  List<Map<String, dynamic>> invites = const [],
  Map<String, dynamic>? suggestions,
}) {
  api.ok('/teams/t-1/requests', requests);
  api.ok('/teams/t-1/invites', invites);
  api.ok('/teams/t-1/suggested-players', suggestions ?? suggested());
}

/// The console loads in three hops — detail, then the requests/invites pair, then the
/// rail — so a single [settleData] leaves the tree half-built.
Future<void> settleConsole(WidgetTester tester) async {
  await settleData(tester);
  await settleData(tester);
  await settleData(tester);
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('while the team is loading', () {
    testWidgets('it shows a spinner', (tester) async {
      api.ok('/teams/t-1', teamDetail(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('the title is present before the team arrives', (tester) async {
      api.ok('/teams/t-1', teamDetail(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));

      expect(find.text('Group info'), findsOneWidget);
    });

    testWidgets('the edit action is withheld until the role is known',
        (tester) async {
      // `_team?.amCaptain == true` at :475 uses a null-safe read for this reason: an
      // edit button offered before the role arrives could be tapped by a visitor.
      api.ok('/teams/t-1', teamDetail(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));

      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets('it asks for the team once', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(api.countTo('/teams/t-1'), 1);
    });
  });

  group('once the team arrives', () {
    testWidgets('the header names the team', (tester) async {
      api.ok('/teams/t-1', teamDetail(name: 'Lahore Lions', role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Lahore Lions'), findsOneWidget);
    });

    testWidgets('the sport and visibility are stated as chips', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(sport: 'football', visibility: 'public', role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('FOOTBALL'), findsOneWidget);
      expect(find.text('PUBLIC'), findsOneWidget);
    });

    testWidgets('a private team says so rather than staying silent',
        (tester) async {
      // Visibility decides whether a stranger can request to join at all, so it is
      // not decoration.
      api.ok('/teams/t-1', teamDetail(visibility: 'private', role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('PRIVATE'), findsOneWidget);
      expect(find.text('PUBLIC'), findsNothing);
    });

    testWidgets('a city is shown and an absent one draws no empty chip',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(city: null, role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('LAHORE'), findsNothing);
      expect(find.text('FOOTBALL'), findsOneWidget);
    });

    testWidgets('the record comes from the stats block', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(wins: 8, losses: 2, draws: 1, winRate: 73)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Won'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text('Lost'), findsOneWidget);
      expect(find.text('Drew'), findsOneWidget);
      expect(find.text('73%'), findsOneWidget);
    });

    testWidgets('a bio is shown when there is one', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', bio: 'Weekend five-a-side, Gulberg.'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Weekend five-a-side, Gulberg.'), findsOneWidget);
    });

    testWidgets('an empty bio draws no empty card', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', bio: ''));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Members (2)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the roster is listed and counted', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
        member(id: 'u-3', name: 'Hamza Sheikh', role: 'vice_captain'),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Members (3)'), findsOneWidget);
      expect(find.text('Usman Tariq'), findsOneWidget);
      expect(find.text('Hamza Sheikh'), findsOneWidget);
    });

    testWidgets('each role is badged distinctly', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
        member(id: 'u-3', name: 'Hamza Sheikh', role: 'vice_captain'),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('CAPTAIN'), findsOneWidget);
      expect(find.text('VICE'), findsOneWidget);
      expect(find.text('MEMBER'), findsOneWidget);
    });

    testWidgets('the viewer own row is marked', (tester) async {
      // The default FakeAuth id is u-1, which is the captain in these fixtures.
      api.ok('/teams/t-1', teamDetail(role: 'member', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Bilal Ahmed (You)'), findsOneWidget);
      expect(find.text('Usman Tariq'), findsOneWidget);
    });

    testWidgets('a member rating is shown per row', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', roster: [
        member(id: 'u-2', name: 'Usman Tariq', playerElo: 1120),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('ELO 1120'), findsOneWidget);
    });
  });

  group('the rating tile, which may not print the seed', () {
    testWidgets('a ranked team shows its rating under an ELO label',
        (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(ranked: true, displayElo: 1240)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('ELO'), findsOneWidget);
      expect(find.text('1,240'), findsOneWidget);
    });

    testWidgets('an unranked team is relabelled and says Unranked',
        (tester) async {
      // FR2.6. The team row still carries `elo: 1000`; printing it here showed every
      // new team a confident 1000 it had not earned (:596).
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(ranked: false, displayElo: null)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Rating'), findsOneWidget);
      expect(find.text('Unranked'), findsOneWidget);
      expect(find.text('1,000'), findsNothing);
      expect(find.text('1000'), findsNothing);
    });

    testWidgets('a missing stats block draws a dash rather than the seed',
        (tester) async {
      // `_stats == null` is the pre-migration payload. A dash says "not known here";
      // falling through to `t.elo` would say 1000.
      api.ok('/teams/t-1', {
        ...teamDetail(role: 'member'),
        'stats': null,
      });

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('—'), findsOneWidget);
      expect(find.text('1000'), findsNothing);
    });

    testWidgets('a ranked flag with no rating is still unranked', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(ranked: true, displayElo: null)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Unranked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a frozen rating is explained rather than left a mystery',
        (tester) async {
      // ER2.3 — a team over the dispute ratio keeps playing but stops moving. :624
      // records that saying so is the difference between a rule and a mystery.
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(eloFrozen: true)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(
        find.textContaining('Rating frozen — too many disputed results.'),
        findsOneWidget,
      );
      expect(find.textContaining('Matches still count'), findsOneWidget);
    });

    testWidgets('an unfrozen rating carries no notice', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(eloFrozen: false)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.textContaining('Rating frozen'), findsNothing);
    });
  });

  group('the form card', () {
    testWidgets('the last five results are drawn as pills', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(form: 'WWLDW')));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Last 5'), findsOneWidget);
      expect(find.byType(FormRow), findsOneWidget);
      expect(find.text('W'), findsNWidgets(3));
      expect(find.text('L'), findsOneWidget);
      expect(find.text('D'), findsOneWidget);
    });

    testWidgets('a run of identical results keeps every pill', (tester) async {
      // lib/widgets/team_stat_widgets.dart:150 — the loop is indexed rather than
      // comparing by value, because "WWWWW" collapsed to pills with no gaps.
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(form: 'WWWWW')));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('W'), findsNWidgets(5));
    });

    testWidgets('no form yet says so instead of drawing nothing', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', statsBlock: stats(form: '')));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('No matches yet'), findsOneWidget);
    });

    testWidgets('the activity window comes from the server', (tester) async {
      api.ok(
          '/teams/t-1',
          teamDetail(
              role: 'member',
              statsBlock: stats(activity30d: 4, activityWindowDays: 30)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('4 matches in the last 30 days'), findsOneWidget);
    });

    testWidgets('a single match is not pluralised', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(activity30d: 1)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('1 match in the last 30 days'), findsOneWidget);
    });

    testWidgets('an idle team is told it is idle', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', statsBlock: stats(activity30d: 0)));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('No matches in the last 30 days'), findsOneWidget);
    });
  });

  group('the rating history', () {
    testWidgets('one point cannot make a line, and the chart says so',
        (tester) async {
      // lib/widgets/team_stat_widgets.dart:454 — an empty frame looks broken, so the
      // chart states what is missing.
      api.ok('/teams/t-1',
          teamDetail(role: 'member', eloHistory: [eloPoint()]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(
        find.text('One rated match so far. The chart needs two to draw a trend.'),
        findsOneWidget,
      );
    });

    testWidgets('no history at all is a different sentence', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', eloHistory: const []));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(
        find.text(
            'No rated matches yet — the chart appears once a result is verified.'),
        findsOneWidget,
      );
    });

    testWidgets('the recent-matches section appears only with history',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', eloHistory: const []));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Rating history'), findsOneWidget);
      expect(find.textContaining('Recent matches'), findsNothing);
    });

    testWidgets('a match row states the opponent and the result', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', eloHistory: [
        eloPoint(opponentName: 'Karachi Kings', myScore: 2, theirScore: 1, result: 'win'),
        eloPoint(matchId: 'm-2', opponentName: 'Multan Sultans', myScore: 0, theirScore: 3, result: 'loss', eloDelta: -14),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Recent matches (2)'), findsOneWidget);
      expect(find.text('Karachi Kings'), findsOneWidget);
      expect(find.text('Won 2–1'), findsOneWidget);
      expect(find.text('Lost 0–3'), findsOneWidget);
    });

    testWidgets('the history is newest first', (tester) async {
      // :705 — a list is read from the top and a chart from the left, so the two
      // orders are deliberately opposite.
      api.ok('/teams/t-1', teamDetail(role: 'member', eloHistory: [
        eloPoint(matchId: 'm-1', opponentName: 'Oldest Opponent'),
        eloPoint(matchId: 'm-2', opponentName: 'Newest Opponent'),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      final newest = tester.getTopLeft(find.text('Newest Opponent')).dy;
      final oldest = tester.getTopLeft(find.text('Oldest Opponent')).dy;
      expect(newest, lessThan(oldest));
    });

    testWidgets('a rated result shows its signed change', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', eloHistory: [
        eloPoint(rated: true, eloDelta: 18),
        eloPoint(matchId: 'm-2', rated: true, eloDelta: -14, result: 'loss'),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.textContaining('+18'), findsOneWidget);
      expect(find.textContaining('-14'), findsOneWidget);
    });

    testWidgets('an unrated result shows no change at all, never a plus zero',
        (tester) async {
      // lib/models/team_stats.dart:260 — a frozen or disputed match has no delta,
      // and "+0" would imply a rated draw.
      api.ok('/teams/t-1', teamDetail(role: 'member', eloHistory: [
        eloPoint(rated: false, eloDelta: 0),
        eloPoint(matchId: 'm-2', rated: false, eloDelta: null),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.textContaining('+0'), findsNothing);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a disputed result is labelled rather than scored',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member', eloHistory: [
        eloPoint(result: 'disputed', disputed: true, rated: false, eloDelta: null),
      ]));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Disputed 2–1'), findsOneWidget);
    });
  });

  group('what a captain can do', () {
    testWidgets('the edit action is offered', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    });

    testWidgets('the invite console is offered', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Invite'), findsOneWidget);
      expect(find.text('Create invite link'), findsOneWidget);
    });

    testWidgets('a member row offers management', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.byIcon(Icons.more_vert), findsOneWidget,
          reason: 'one other member, and never the viewer own row');
    });

    testWidgets('the member sheet offers the promotions that apply',
        (tester) async {
      // The three role actions are each gated on the member current role, so a
      // captain is never offered "Make captain" for someone who already is one.
      api.ok('/teams/t-1', teamDetail(role: 'captain', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Make captain'), findsOneWidget);
      expect(find.text('Make vice captain'), findsOneWidget);
      expect(find.text('Make member'), findsNothing,
          reason: 'this player already is one');
      expect(find.text('Remove from team'), findsOneWidget);
    });

    testWidgets('promoting a member sends the action the server expects',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));
      stubAdminExtras(api);
      api.ok('/teams/t-1/members/u-2', {'ok': true});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Make vice captain'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleConsole(tester);

      final write = api.to('/teams/t-1/members/u-2').last;
      expect(write.method, 'PATCH');
      expect(write.body, contains('vice_captain'));
    });

    testWidgets('removing a member is confirmed before it is sent',
        (tester) async {
      // Removal drops the player out of the team chat, which is not recoverable by
      // the player, so the confirmation is the last stop.
      api.ok('/teams/t-1', teamDetail(role: 'captain', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Remove from team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Remove Usman Tariq?'), findsOneWidget);
      expect(find.text('They will lose access to the team chat.'), findsOneWidget);
      expect(api.countTo('/teams/t-1/members/u-2'), 0,
          reason: 'nothing is sent until the captain confirms');

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.countTo('/teams/t-1/members/u-2'), 0);
    });

    testWidgets('a confirmed removal is sent', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));
      stubAdminExtras(api);
      api.ok('/teams/t-1/members/u-2', {'ok': true});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Remove from team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleConsole(tester);

      expect(api.to('/teams/t-1/members/u-2').last.body, contains('remove'));
    });
  });

  group('what a vice captain can do', () {
    testWidgets('the invite console is offered', (tester) async {
      // `amAdmin` is captain or vice captain (lib/models/team.dart:100), so this half
      // of the console is shared.
      api.ok('/teams/t-1', teamDetail(role: 'vice_captain'));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Create invite link'), findsOneWidget);
    });

    testWidgets('the edit action is withheld', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'vice_captain'));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets('member management is withheld', (tester) async {
      // `canManage` is `amCaptain && !isMe`, not `amAdmin`, so a vice captain cannot
      // reorder the roles above them.
      api.ok('/teams/t-1', teamDetail(role: 'vice_captain', roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'vice_captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });

  group('what a member and a visitor can do', () {
    testWidgets('a member is offered no console', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Create invite link'), findsNothing);
      expect(find.text('Suggested players'), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets('a member can leave', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Leave team'), findsOneWidget);
    });

    testWidgets('a visitor from the leaderboard is offered no leave button',
        (tester) async {
      // :661 — the screen is reachable from the rankings, so a visitor would
      // otherwise be offered a button that can only fail.
      api.ok('/teams/t-1', teamDetail(role: null));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Leave team'), findsNothing);
      expect(find.text('Lahore Lions'), findsOneWidget,
          reason: 'the profile is still readable');
    });

    testWidgets('a member is not fetched an admin console they cannot see',
        (tester) async {
      // A non-admin viewer must not spend two round-trips on lists the server would
      // refuse anyway.
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(api.countTo('/teams/t-1/requests'), 0);
      expect(api.countTo('/teams/t-1/invites'), 0);
      expect(api.countTo('/teams/t-1/suggested-players'), 0);
    });

    testWidgets('leaving is confirmed before it is sent', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Leave team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Leave Lahore Lions?'), findsOneWidget);
      expect(
        find.text('You will stop receiving this team\'s messages.'),
        findsOneWidget,
      );
      expect(api.countTo('/teams/t-1/members/me'), 0);
    });

    testWidgets('a captain leaving is warned about the succession',
        (tester) async {
      // A team with no captain cannot approve a request or mint an invite, so this
      // sentence is the only warning before that state.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Leave team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('If you are the only captain, promote someone else first.'),
        findsOneWidget,
      );
    });

    testWidgets('a confirmed leave sends a delete', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member'));
      api.ok('/teams/t-1/members/me', {'ok': true});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Leave team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Leave'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleConsole(tester);

      expect(api.to('/teams/t-1/members/me').last.method, 'DELETE');
    });
  });

  group('join requests', () {
    testWidgets('a pending request is shown with its count', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, requests: [joinRequest()]);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Requests to join (1)'), findsOneWidget);
      expect(find.text('Hamza Sheikh'), findsOneWidget);
      expect(find.text('ELO 1080'), findsOneWidget);
    });

    testWidgets('the applicant own words are quoted', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api,
          requests: [joinRequest(message: 'Left winger, free on weekends.')]);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('"Left winger, free on weekends."'), findsOneWidget);
    });

    testWidgets('an empty message draws no empty quote', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, requests: [joinRequest(message: '   ')]);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('""'), findsNothing);
      expect(find.text('Hamza Sheikh'), findsOneWidget);
    });

    testWidgets('no requests draws no section at all', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.textContaining('Requests to join'), findsNothing);
    });

    testWidgets('approving sends the approve action', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, requests: [joinRequest(id: 'r-1')]);
      api.ok('/teams/t-1/requests/r-1', {'ok': true});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Approve'));
      await tester.pump();
      await settleConsole(tester);

      final write = api.to('/teams/t-1/requests/r-1').last;
      expect(write.method, 'PATCH');
      expect(write.body, contains('approve'));
    });

    testWidgets('declining sends the reject action', (tester) async {
      // The two buttons sit side by side and differ by one word in the body, which is
      // exactly the pair a copy-paste error swaps.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, requests: [joinRequest(id: 'r-1')]);
      api.ok('/teams/t-1/requests/r-1', {'ok': true});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Decline'));
      await tester.pump();
      await settleConsole(tester);

      expect(api.to('/teams/t-1/requests/r-1').last.body, contains('reject'));
    });

    testWidgets('a decision refetches the team', (tester) async {
      // The roster and the request list both change, so the screen re-reads rather
      // than editing its local copy.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, requests: [joinRequest(id: 'r-1')]);
      api.ok('/teams/t-1/requests/r-1', {'ok': true});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Approve'));
      await tester.pump();
      await settleConsole(tester);

      expect(api.countTo('/teams/t-1'), greaterThan(1));
    });

    testWidgets('a rejected decision surfaces the server message',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, requests: [joinRequest(id: 'r-1')]);
      api.fail('/teams/t-1/requests/r-1', 'That player already left.');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Approve'));
      await tester.pump();
      await settleConsole(tester);

      expect(find.text('That player already left.'), findsOneWidget);
    });
  });

  group('the invite console', () {
    testWidgets('a live invite is listed with its code', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, invites: [invite(tokenPrefix: 'A1B2')]);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Code A1B2…'), findsOneWidget);
      expect(find.text('Revoke'), findsOneWidget);
    });

    testWidgets('an invite with no expiry reads as active', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, invites: [invite(expiresAt: null)]);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Active'), findsOneWidget);
    });

    testWidgets('minting a link posts to the invites endpoint', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);
      api.ok('/teams/t-1/invites', {
        'link': 'https://sportlynk.app/join/A1B2C3',
        'token': 'A1B2C3',
        'expires_at': '2026-09-30T12:00:00Z',
      });

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Create invite link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.to('/teams/t-1/invites').any((r) => r.method == 'POST'), isTrue);
    });

    testWidgets('the minted link is shown to be copied', (tester) async {
      // The schema has no per-user invite (:747), so the captain sends the link
      // themselves and must be able to read it.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);
      api.ok('/teams/t-1/invites', {
        'link': 'https://sportlynk.app/join/A1B2C3',
        'token': 'A1B2C3',
      });

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Create invite link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Invite link'), findsOneWidget);
      expect(find.text('https://sportlynk.app/join/A1B2C3'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('the dialog explains what the recipient does with the link',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);
      api.ok('/teams/t-1/invites', {'link': 'https://x.test/join/A', 'token': 'A'});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Create invite link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('Teams → "Join with link" and paste it'),
        findsOneWidget,
      );
    });

    testWidgets('a failed mint says so rather than opening an empty dialog',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api);
      api.fail('/teams/t-1/invites', 'Too many active invites.');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Create invite link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Invite link'), findsNothing);
      expect(find.text('Too many active invites.'), findsOneWidget);
    });

    testWidgets('revoking deletes the invite by id', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api, invites: [invite(id: 'inv-1')]);
      api.ok('/teams/t-1/invites/inv-1', {'ok': true});

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.tap(find.text('Revoke'));
      await tester.pump();
      await settleConsole(tester);

      expect(api.to('/teams/t-1/invites/inv-1').last.method, 'DELETE');
    });
  });

  group('the suggested players rail', () {
    testWidgets('it shows its own spinner while the model is thinking',
        (tester) async {
      // :168 — the rail is loaded apart from the requests and invites so a slow ML
      // round-trip does not hold the rest of the console hostage.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      api.ok('/teams/t-1/requests', const []);
      api.ok('/teams/t-1/invites', [invite()]);
      api.ok('/teams/t-1/suggested-players', suggested(),
          delay: const Duration(milliseconds: 400));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleData(tester);
      await settleData(tester);

      expect(find.text('Code A1B2…'), findsOneWidget,
          reason: 'the console is already usable');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await settleConsole(tester);
    });

    testWidgets('a failed read is not reported as an empty pool',
        (tester) async {
      // :178 — the service answers null for a failure and an empty list for "nobody
      // to suggest". Collapsing the two tells a captain there is nobody near them
      // when the ML service is down.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      api.ok('/teams/t-1/requests', const []);
      api.ok('/teams/t-1/invites', const []);
      api.fail('/teams/t-1/suggested-players', 'scorer unavailable');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Could not load suggestions.'), findsOneWidget);
      expect(find.textContaining('No players to suggest yet'), findsNothing);
    });

    testWidgets('a dropped connection is also a failure, not an empty pool',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      api.ok('/teams/t-1/requests', const []);
      api.ok('/teams/t-1/invites', const []);
      api.offline('/teams/t-1/suggested-players');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Could not load suggestions.'), findsOneWidget);
    });

    testWidgets('the rail retry refetches only the rail', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      api.ok('/teams/t-1/requests', const []);
      api.ok('/teams/t-1/invites', const []);
      api.fail('/teams/t-1/suggested-players', 'scorer unavailable');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);
      final detailReads = api.countTo('/teams/t-1');

      api.ok('/teams/t-1/suggested-players', suggested());
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await settleConsole(tester);

      expect(api.countTo('/teams/t-1/suggested-players'), 2);
      expect(api.countTo('/teams/t-1'), detailReads,
          reason: 'the team itself did not change');
    });

    testWidgets('a genuinely empty pool explains where suggestions come from',
        (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api,
          suggestions: suggested(suggestions: const [], available: true));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(
        find.textContaining('No players to suggest yet.'),
        findsOneWidget,
      );
      expect(find.textContaining('football venues near Lahore'), findsOneWidget);
    });

    testWidgets('an unavailable scorer states its own reason', (tester) async {
      // The two endpoints degrade differently (lib/models/reco.dart:130), so the
      // note is written by the server rather than guessed here.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api,
          suggestions: suggested(
              suggestions: const [],
              available: false,
              fallbackNote: 'Ranking is offline; suggestions resume shortly.'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(
        find.text('Ranking is offline; suggestions resume shortly.'),
        findsOneWidget,
      );
      expect(find.textContaining('No players to suggest yet'), findsNothing);
    });
  });

  group('when the team cannot be read', () {
    testWidgets('a server message is surfaced with a retry', (tester) async {
      api.fail('/teams/t-1', 'This team is private.', status: 403);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('This team is private.'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a dropped connection falls back to a generic message',
        (tester) async {
      // The symptom of a missing `adb reverse`. It must not read as an empty team.
      api.offline('/teams/t-1');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Members (2)'), findsNothing);
    });

    testWidgets('the retry refetches and can succeed', (tester) async {
      api.fail('/teams/t-1', 'boom');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      api.ok('/teams/t-1', teamDetail(role: 'member'));
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await settleConsole(tester);

      expect(api.countTo('/teams/t-1'), 2);
      expect(find.text('Lahore Lions'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsNothing);
    });

    testWidgets('a failed load offers no roster and no leave button',
        (tester) async {
      api.fail('/teams/t-1', 'boom');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      expect(find.text('Leave team'), findsNothing);
      expect(find.textContaining('Members'), findsNothing);
    });

    testWidgets('no team id at all says so without a request', (tester) async {
      // :91 — the widget takes a nullable `teamId`, so this path is reachable from
      // a deep link with a missing segment.
      await pumpScreen(tester, const TeamRosterScreen());
      await settleConsole(tester);

      expect(find.text('Team not found.'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('an empty team id is treated the same', (tester) async {
      await pumpScreen(tester, const TeamRosterScreen(teamId: ''));
      await settleConsole(tester);

      expect(find.text('Team not found.'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('a missing id still offers a retry, which stays put',
        (tester) async {
      // Pinned as it behaves, not as it should.
      // lib/screens/player/team_roster_screen.dart:677 wires the "Team not found."
      // error view's Try again to `_load`, which for a null id returns immediately
      // without a request, so the button appears actionable but cannot ever change
      // the screen. The fix is to omit the action when the id is missing, since
      // retrying cannot supply one; this test should then assert no retry is offered.
      await pumpScreen(tester, const TeamRosterScreen());
      await settleConsole(tester);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await settleConsole(tester);

      expect(api.requests, isEmpty);
      expect(find.text('Team not found.'), findsOneWidget);
    });
  });

  group('without a session', () {
    testWidgets('it sends an empty token rather than throwing', (tester) async {
      // :74 reads `token ?? ''`, unlike the screens that bang the token and crash
      // before first paint. The request goes out and comes back rejected.
      api.fail('/teams/t-1', 'Unauthorized', status: 401);

      await pumpScreen(
        tester,
        const TeamRosterScreen(teamId: 't-1'),
        auth: FakeAuth(token: null),
      );
      await settleConsole(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Unauthorized'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('nobody is marked as the viewer when there is no viewer',
        (tester) async {
      // `_myId` falls back to an empty string, which must not match a real id and
      // label a stranger's row "(You)".
      api.ok('/teams/t-1', teamDetail(role: null, roster: [
        member(id: 'u-1', name: 'Bilal Ahmed', role: 'captain'),
        member(id: 'u-2', name: 'Usman Tariq'),
      ]));

      await pumpScreen(
        tester,
        const TeamRosterScreen(teamId: 't-1'),
        auth: FakeAuth(token: 'test-token', id: ''),
      );
      await settleConsole(tester);

      expect(find.textContaining('(You)'), findsNothing);
    });
  });

  group('refreshing', () {
    testWidgets('a pull refetches the team', (tester) async {
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleConsole(tester);

      expect(api.countTo('/teams/t-1'), greaterThan(1));
    });

    testWidgets('a failed refresh keeps the team on screen', (tester) async {
      // `_refresh` writes nothing when the envelope fails, so the profile a member
      // is reading does not vanish on a flaky connection.
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      api.fail('/teams/t-1', 'boom');
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleConsole(tester);

      expect(find.text('Lahore Lions'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsNothing);
    });

    testWidgets('a refresh that drops the stats block keeps the chart section',
        (tester) async {
      // `_absorbStats` is called from both `_load` and `_refresh` (:118) so the two
      // paths cannot end up reading different keys and silently dropping the chart.
      api.ok('/teams/t-1', teamDetail(role: 'member'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'));
      await settleConsole(tester);

      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await settleConsole(tester);

      expect(find.text('Rating history'), findsOneWidget);
      expect(find.text('Last 5'), findsOneWidget);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('a member profile does not clip', (tester) async {
      api.ok('/teams/t-1',
          teamDetail(role: 'member', bio: 'Weekend five-a-side in Gulberg, Lahore.'));

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'),
          textScale: 2.0);
      await settleConsole(tester);

      expectNoOverflow(tester);
    });

    testWidgets('the captain console does not clip', (tester) async {
      // The five StatTiles share one Row and the request card puts two buttons side
      // by side, which is where a scaled label would clip if anywhere.
      api.ok('/teams/t-1', teamDetail(role: 'captain'));
      stubAdminExtras(api,
          requests: [joinRequest()], invites: [invite()]);

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'),
          textScale: 2.0);
      await settleConsole(tester);

      expectNoOverflow(tester);
    });

    testWidgets('the error view does not clip', (tester) async {
      api.fail('/teams/t-1', 'This team is private and you are not a member.');

      await pumpScreen(tester, const TeamRosterScreen(teamId: 't-1'),
          textScale: 2.0);
      await settleConsole(tester);

      expectNoOverflow(tester);
    });
  });
}
