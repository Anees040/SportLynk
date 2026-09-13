// A team's Match Center (FR5.16): three tabs — Challenges, Upcoming, History —
// fed by one read on mount, `MatchService.center`, bucketed server-side. The screen
// also listens to the realtime `match:update` stream so a challenge the other side
// accepts lands without a manual refresh; the fake stream is never pushed here, so
// that path stays dormant and only the initial load is exercised.
//
// The failure branch is real and worth pinning: `center` collapses any failure to
// `MatchCenterData.empty`, whose `teamId` is empty, and the screen reads an empty
// `teamId` as "the read failed" (match_center_screen.dart:86) — a "Could not load
// matches" state with a pull to retry, distinct from a team that simply has no
// matches (a non-empty `teamId` with empty lists), which shows per-tab empty copy.
//
// The captain gate is visible in two places: the "Challenge" FAB and the Accept /
// Decline actions on an incoming card exist only when `myRole == 'captain'`, so a
// member is never offered an action the server would refuse.
//
// Timer note: an incoming or outgoing challenge card renders a `ChallengeCountdown`,
// which runs a `Timer.periodic`; the test that shows a card ends by unmounting the
// screen so `dispose` cancels it. The loading, failure and empty states render no
// countdown, so they need no unmount. No test uses `pumpAndSettle` — the countdown
// would hang it.
//
// Mount note: the load reads `AuthProvider.token`; `FakeAuth` supplies it. The fake
// keys on the path `/matches`, which the `team_id` query does not change.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/match_center_screen.dart';

import '../screen_harness.dart';

/// `MatchService.center`, as `ApiConstants.matches` resolves under the path-keyed
/// fake. The `team_id` query is recorded but ignored for matching.
const String kMatches = '/matches';

/// A `MatchSide` in the camelCase the matches API emits.
Map<String, dynamic> sideRow({
  String id = 'opp-1',
  String name = 'Karachi Kings',
  int elo = 1250,
}) => {
  'id': id,
  'name': name,
  'city': 'Karachi',
  'elo': elo,
  'ranked': true,
  'displayElo': elo,
  'played': 10,
  'wins': 6,
  'losses': 3,
  'draws': 1,
  'eloFrozen': false,
  'memberCount': 6,
};

/// One incoming challenge (`challenge_sent`, the other side is the challenger). A
/// future expiry keeps the countdown live rather than reading as expired.
Map<String, dynamic> incoming({String id = 'm-1'}) => {
  'id': id,
  'status': 'challenge_sent',
  'challenger': sideRow(id: 'opp-1', name: 'Karachi Kings'),
  'opponent': sideRow(id: 't-1', name: 'Lahore Lions', elo: 1240),
  'competitiveness': 82,
  'challengeExpiresAt': DateTime.now()
      .add(const Duration(hours: 20))
      .toIso8601String(),
  'isDraw': false,
  'eloApplied': false,
  'resultsLocked': false,
  'resultsIn': 0,
  'slotStarted': false,
  'iAmChallenger': false,
  'myTeamId': 't-1',
};

/// The `GET /matches` `data` block `MatchCenterData.fromJson` reads. A non-empty
/// `teamId` marks a successful load; the empty-list default is the "nothing yet"
/// state, not the failure one.
Map<String, dynamic> centerData({
  String myRole = 'captain',
  List<Map<String, dynamic>> incomingList = const [],
  List<Map<String, dynamic>> outgoing = const [],
  List<Map<String, dynamic>> upcoming = const [],
  List<Map<String, dynamic>> history = const [],
}) => {
  'teamId': 't-1',
  'myRole': myRole,
  'challenges': {'incoming': incomingList, 'outgoing': outgoing},
  'upcoming': upcoming,
  'history': history,
  'disputeWindowHours': 24,
};

Future<RouteLog> pumpCenter(WidgetTester tester, {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const MatchCenterScreen(teamId: 't-1', teamName: 'Lahore Lions'),
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
    api.ok(kMatches, centerData());
  });

  group('the center as it loads', () {
    testWidgets('a spinner stands while the load is in flight', (tester) async {
      api.ok(kMatches, centerData(), delay: const Duration(milliseconds: 300));
      await pumpCenter(tester);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Match Center'), findsOneWidget); // app-bar
    });

    testWidgets('the three tabs and the empty challenges copy render', (
      tester,
    ) async {
      await pumpCenter(tester);
      await settleData(tester);

      expect(find.text('Challenges'), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.textContaining('No open challenges'), findsOneWidget);
    });

    testWidgets('a failed load is a real error state, not an empty one', (
      tester,
    ) async {
      // `center` collapses failure to `MatchCenterData.empty` (empty teamId); the
      // screen reads that as the read having failed, distinct from "no matches".
      api.fail(kMatches, 'boom');
      await pumpCenter(tester);
      await settleData(tester);

      expect(
        find.text('Could not load matches. Pull down to try again.'),
        findsOneWidget,
      );
    });
  });

  group('the captain gate', () {
    testWidgets('a captain is offered the Challenge action', (tester) async {
      await pumpCenter(tester);
      await settleData(tester);

      expect(
        find.widgetWithText(FloatingActionButton, 'Challenge'),
        findsOneWidget,
      );
    });

    testWidgets('a member is not', (tester) async {
      api.ok(kMatches, centerData(myRole: 'member'));
      await pumpCenter(tester);
      await settleData(tester);

      expect(
        find.widgetWithText(FloatingActionButton, 'Challenge'),
        findsNothing,
      );
    });
  });

  group('an incoming challenge', () {
    testWidgets(
      'names the challenger and offers accept or decline to a captain',
      (tester) async {
        api.ok(kMatches, centerData(incomingList: [incoming()]));
        await pumpCenter(tester);
        await settleData(tester);

        expect(find.text('CHALLENGED YOU'), findsOneWidget);
        expect(find.text('Karachi Kings'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Decline'), findsOneWidget);

        // Cancel the countdown's periodic timer before the test ends.
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('a member sees the card but no actions', (tester) async {
      api.ok(
        kMatches,
        centerData(myRole: 'member', incomingList: [incoming()]),
      );
      await pumpCenter(tester);
      await settleData(tester);

      expect(find.text('Karachi Kings'), findsOneWidget);
      expect(find.text('A captain needs to answer this one.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the tabs present', (tester) async {
      ignoreOverflow();
      await pumpCenter(tester, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Challenges'), findsOneWidget);
    });
  });
}
