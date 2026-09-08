// Admin disputes: a status-filtered, cursor-paged queue of matches whose two
// captains filed different results, ordered server-side by the rating at stake.
// The screen decides none of that order or severity — it renders what the queue
// sends — so the tests here pin the rendering, the status filter reaching the
// query, and the paging, not any client-side triage.
//
// Mount note: the screen embeds no `NotificationBell` and never calls
// `RealtimeService`, so the default authenticated session is correct. `_load`
// returns early on a null token but clears `_loading` first (admin_disputes_screen.dart:58),
// so a null-token mount would show the empty state rather than hang; the default
// `test-token` is what lets a populated queue load.
//
// Read failures do not surface here. `AdminService.disputes` returns an empty page
// on any non-success (admin_service.dart:58), and `_load` has no catch, so a failed
// queue read is indistinguishable from a genuinely empty one — a defect (there is no
// error-with-retry state) pinned by a test below rather than fixed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_disputes_screen.dart';

import '../screen_harness.dart';

/// The queue endpoint, as `ApiConstants.adminDisputes` resolves it.
const String kDisputes = '/admin/disputes';

/// One team side, in the shape `DisputeTeam.fromJson` reads (models/admin.dart:62).
Map<String, dynamic> team({
  String id = 't-1',
  String name = 'Lahore Qalandars',
  int elo = 1200,
  bool frozen = false,
}) =>
    {'id': id, 'name': name, 'elo': elo, 'frozen': frozen};

/// One queue row, in the shape `DisputeRow.fromJson` reads (models/admin.dart:170):
/// the match, both teams, the raiser and the ruled score arrive nested.
Map<String, dynamic> dispute({
  String id = 'd-1',
  String status = 'open',
  int severityElo = 28,
  int ageHours = 3,
  String? reason = 'The opponent left at half time and we claimed the win.',
  bool bothSidesDisputed = false,
  bool eloApplied = false,
  bool isFixture = false,
  String? tournamentName,
  String? raisedByTeamName,
  String? ruling,
  int resultsIn = 1,
  String? scoreline,
  String challengerName = 'Lahore Qalandars',
  String opponentName = 'Karachi Kings',
  int challengerElo = 1200,
  int opponentElo = 1180,
  bool opponentFrozen = false,
}) =>
    {
      'id': id,
      'matchId': 'm-1',
      'status': status,
      'reason': reason,
      'ageHours': ageHours,
      'severityElo': severityElo,
      'bothSidesDisputed': bothSidesDisputed,
      if (ruling != null) 'ruling': ruling,
      'match': {
        'status': 'disputed',
        'resultsIn': resultsIn,
        if (scoreline != null) 'scoreline': scoreline,
        'eloApplied': eloApplied,
        'isFixture': isFixture,
        if (tournamentName != null) 'tournamentName': tournamentName,
      },
      'challenger': team(id: 't-1', name: challengerName, elo: challengerElo),
      'opponent': team(
          id: 't-2', name: opponentName, elo: opponentElo, frozen: opponentFrozen),
      if (raisedByTeamName != null)
        'raisedBy': {'teamName': raisedByTeamName, 'captainName': 'Ali'},
    };

/// A page payload, in the shape `AdminService.disputes` reads (admin_service.dart:60):
/// `hasMore` is derived from the cursor's presence, not sent as a flag.
Map<String, dynamic> page(
  List<Map<String, dynamic>> items, {
  String? nextCursor,
}) =>
    {'items': items, 'nextCursor': nextCursor};

Future<RouteLog> pumpDisputes(WidgetTester tester, FakeApi api,
    {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const AdminDisputesScreen(),
    auth: FakeAuth(role: 'admin', id: 'admin-1', name: 'Ops', token: 'admin-token'),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kDisputes, page([dispute()]));
  });

  group('the queue as it loads', () {
    testWidgets('a spinner stands while the first page is in flight',
        (tester) async {
      api.ok(kDisputes, page([dispute()]),
          delay: const Duration(milliseconds: 300));
      await pumpDisputes(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Lahore Qalandars'), findsOneWidget);
    });

    testWidgets('a loaded row shows the stake, age, teams, tally and reason',
        (tester) async {
      await pumpDisputes(tester, api);
      await settleData(tester);

      expect(find.text('28 pts at stake'), findsOneWidget);
      expect(find.text('3h'), findsOneWidget);
      expect(find.text('Lahore Qalandars'), findsOneWidget);
      expect(find.text('Karachi Kings'), findsOneWidget);
      // No scoreline was filed, so the centre reads the placeholder, and the tally
      // shows one of two captains filed.
      expect(find.text('vs'), findsOneWidget);
      expect(find.text('1/2 filed'), findsOneWidget);
      expect(
          find.text('The opponent left at half time and we claimed the win.'),
          findsOneWidget);
    });

    testWidgets('an empty open queue says every result has been ruled',
        (tester) async {
      api.ok(kDisputes, page(const []));
      await pumpDisputes(tester, api);
      await settleData(tester);

      expect(find.textContaining('No open disputes.'), findsOneWidget);
    });

    testWidgets('a failed load reads as the empty state, not an error',
        (tester) async {
      // Defect, pinned rather than fixed: `AdminService.disputes` swallows a
      // failure into an empty page, so a 500 is indistinguishable from an empty
      // queue. There is no error-with-retry state on this screen.
      api.fail(kDisputes, 'boom');
      await pumpDisputes(tester, api);
      await settleData(tester);

      expect(find.textContaining('No open disputes.'), findsOneWidget);
    });
  });

  group('the status filter reaches the query', () {
    testWidgets('a non-open filter with no rows shows its own empty copy',
        (tester) async {
      // Stubbed empty so both the open and the resolved reads return nothing; the
      // empty copy is chosen by the active status, not by the payload.
      api.ok(kDisputes, page(const []));
      await pumpDisputes(tester, api);
      await settleData(tester);
      expect(find.textContaining('No open disputes.'), findsOneWidget);

      await tester.tap(find.text('Resolved'));
      await settleData(tester);

      expect(find.text('Nothing with this status.'), findsOneWidget);
      expect(api.to(kDisputes).last.param('status'), 'resolved');
    });

    testWidgets('the All filter sends that status on the next query',
        (tester) async {
      await pumpDisputes(tester, api);
      await settleData(tester);

      await tester.tap(find.text('All'));
      await settleData(tester);

      expect(api.to(kDisputes).last.param('status'), 'all');
    });
  });

  group('the severity and evidence chips', () {
    testWidgets('an already-rated, both-sides, fixture dispute is flagged',
        (tester) async {
      api.ok(
        kDisputes,
        page([
          dispute(
            eloApplied: true,
            bothSidesDisputed: true,
            isFixture: true,
            tournamentName: 'City Cup',
            raisedByTeamName: 'Lahore Qalandars',
          )
        ]),
      );
      await pumpDisputes(tester, api);
      await settleData(tester);

      expect(find.text('Already rated'), findsOneWidget);
      expect(find.text('Both sides disputed'), findsOneWidget);
      expect(find.text('City Cup'), findsOneWidget);
      expect(find.text('Raised by Lahore Qalandars'), findsOneWidget);
    });

    testWidgets('a frozen team carries the frozen marker beside its rating',
        (tester) async {
      api.ok(kDisputes, page([dispute(opponentFrozen: true, opponentElo: 1180)]));
      await pumpDisputes(tester, api);
      await settleData(tester);

      // The rating is held still while the case is open, so the ruling would move
      // no points; the screen must say so before the admin rules.
      expect(find.text('1180 · frozen'), findsOneWidget);
    });

    testWidgets('a resolved dispute shows the ruling it closed on',
        (tester) async {
      // A resolved row renders on any status query because the fake ignores the
      // status param; the "Ruled" chip is gated on the row's own fields.
      api.ok(kDisputes, page([dispute(status: 'resolved', ruling: 'rule_challenger')]));
      await pumpDisputes(tester, api);
      await settleData(tester);

      expect(find.text('Ruled: rule_challenger'), findsOneWidget);
    });
  });

  group('paging', () {
    testWidgets('a further page is loaded on demand and appended',
        (tester) async {
      api.ok(kDisputes,
          page([dispute(id: 'd-1', challengerName: 'Alpha')], nextCursor: 'c1'));
      await pumpDisputes(tester, api);
      await settleData(tester);
      expect(find.text('Load more'), findsOneWidget);

      // The next page arrives on the same path (the fake ignores the cursor query),
      // so it is re-stubbed with no cursor before the tap, ending the list.
      api.ok(kDisputes, page([dispute(id: 'd-2', challengerName: 'Bravo')]));
      await tapVisible(tester, find.text('Load more'));
      await settleData(tester);

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('Load more'), findsNothing,
          reason: 'the second page reports no cursor, so the control retires');
    });
  });

  group('reach and scale', () {
    testWidgets('the refresh control names itself', (tester) async {
      await pumpDisputes(tester, api);
      await settleData(tester);

      expect(find.byTooltip('Refresh'), findsOneWidget);
    });

    testWidgets('a doubled text scale keeps a queue row present', (tester) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense card overflows at this scale in the harness alone; the contract is that
      // the content is still built.
      ignoreOverflow();
      await pumpDisputes(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Lahore Qalandars'), findsOneWidget);
    });
  });
}
