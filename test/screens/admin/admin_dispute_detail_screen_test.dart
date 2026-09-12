// Admin dispute detail: the case file for one disputed match, and the ruling bar
// that overrules two captains. The screen decides nothing — severity, whether a
// correction is even possible, which submissions exist, all of it arrives from
// `GET /admin/disputes/:id` — so the tests pin the four load states, the ruling
// bar's server-driven gating, the mandatory note, and the two write bodies (a
// dismiss that carries no scores, a custom scoreline that carries both).
//
// Mount note: this screen embeds no `NotificationBell` and never calls
// `RealtimeService`, so a plain authenticated session is correct. But its `_load`
// returns early on a null token WITHOUT clearing `_loading`
// (admin_dispute_detail_screen.dart:57-59), so a null-token mount hangs on the
// spinner forever; the session must carry a non-null token.
//
// A failed load reads as an honest error here, not a swallowed empty:
// `AdminService.disputeCase` returns null on any non-success (admin_service.dart:79),
// and a null case renders "This case could not be loaded." — a real state, asserted
// as correct rather than pinned as a defect (unlike the queue screens, whose services
// swallow a failure into an empty list).
//
// FakeApi keys stubs by PATH, not method (screen_harness.dart), and the load GET and
// the rule PATCH share the one path `/admin/disputes/d-1`, so the write is asserted by
// method-filtering the recorded requests.
//
// The two ruling success paths call `Navigator.pop`. Popping the root route of a
// `MaterialApp` is not a state the screen is built for, so those tests mount over a
// host route (`_Host`): the pop becomes an ordinary one and the host reappearing
// proves the screen was dismissed. The load GET carries no delay, so the loading
// spinner is transient and a full settle after the host push is safe.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_dispute_detail_screen.dart';

import '../screen_harness.dart';

/// The case endpoint, as `ApiConstants.adminDispute('d-1')` resolves it. Both the
/// load GET and the rule PATCH land here.
const String kCase = '/admin/disputes/d-1';

const FakeAuth _admin =
    FakeAuth(role: 'admin', id: 'admin-1', name: 'Ops', token: 'admin-token');

/// One team side, in the shape `DisputeTeam.fromJson` reads (models/admin.dart).
Map<String, dynamic> team({
  String id = 't-1',
  String name = 'Lahore Qalandars',
  int elo = 1200,
  bool frozen = false,
}) =>
    {'id': id, 'name': name, 'elo': elo, 'frozen': frozen};

/// One `match_results` row, in the shape `DisputeSubmission.fromJson` reads
/// (models/admin.dart:235). A scoreline with equal halves and matching score
/// integers is what makes a case a drawn one to adopt.
Map<String, dynamic> submission({
  String teamId = 't-1',
  String? captainName = 'Ali',
  String? scoreline = '2-1',
  int? scoreChallenger,
  int? scoreOpponent,
}) =>
    {
      'teamId': teamId,
      if (captainName != null) 'captainName': captainName,
      if (scoreline != null) 'scoreline': scoreline,
      if (scoreChallenger != null) 'scoreChallenger': scoreChallenger,
      if (scoreOpponent != null) 'scoreOpponent': scoreOpponent,
    };

/// The dispute row, in the shape `DisputeRow.fromJson` reads (models/admin.dart):
/// the match, both teams and the raiser arrive nested.
Map<String, dynamic> disputeRow({
  String status = 'open',
  int severityElo = 28,
  int ageHours = 3,
  int resultsIn = 1,
  String? reason = 'The opponent left at half time and we claimed the win.',
  bool eloApplied = false,
  bool isFixture = false,
  String? scoreline,
  bool challengerFrozen = false,
  bool opponentFrozen = false,
}) =>
    {
      'id': 'd-1',
      'matchId': 'm-1',
      'status': status,
      'reason': reason,
      'ageHours': ageHours,
      'severityElo': severityElo,
      'bothSidesDisputed': false,
      'match': {
        'status': 'disputed',
        'resultsIn': resultsIn,
        if (scoreline != null) 'scoreline': scoreline,
        'eloApplied': eloApplied,
        'isFixture': isFixture,
      },
      'challenger': team(id: 't-1', name: 'Lahore Qalandars', elo: 1200, frozen: challengerFrozen),
      'opponent': team(id: 't-2', name: 'Karachi Kings', elo: 1180, frozen: opponentFrozen),
    };

/// A whole case file, in the shape `DisputeCase.fromJson` reads (models/admin.dart:536).
/// The capabilities knobs decide the ruling bar: `canRule` shows it at all, and
/// `needsCorrection` without `correctionAvailable` blocks every result-changing action
/// while leaving Dismiss (which changes no result) available.
Map<String, dynamic> caseJson({
  Map<String, dynamic>? dispute,
  bool canRule = true,
  bool needsCorrection = false,
  bool correctionAvailable = false,
  String? correctionBlockedBy,
  Map<String, dynamic>? challengerSubmission,
  Map<String, dynamic>? opponentSubmission,
  bool agree = false,
  int count = 1,
  List<Map<String, dynamic>> challengerRoster = const [],
  List<Map<String, dynamic>> opponentRoster = const [],
}) =>
    {
      'dispute': dispute ?? disputeRow(),
      'capabilities': {
        'canRule': canRule,
        'needsCorrection': needsCorrection,
        'correctionAvailable': correctionAvailable,
        if (correctionBlockedBy != null) 'correctionBlockedBy': correctionBlockedBy,
      },
      'submissions': {
        'challenger': challengerSubmission ?? submission(),
        if (opponentSubmission != null) 'opponent': opponentSubmission,
        'agree': agree,
        'count': count,
      },
      'rosters': {'challenger': challengerRoster, 'opponent': opponentRoster},
      'chat': {'messages': const [], 'truncated': false},
      'eloHistory': const [],
      'otherDisputes': const [],
    };

/// Mounts the screen as the root route. Correct for every path that does not pop.
Future<RouteLog> pumpCase(WidgetTester tester, FakeApi api,
    {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const AdminDisputeDetailScreen(disputeId: 'd-1'),
    auth: _admin,
    textScale: textScale,
  );
}

/// Mounts the screen over a host route, so a ruling's `Navigator.pop` is an ordinary
/// pop back to the host. The load GET has no delay, so the loading spinner is
/// transient and a full settle after the push is safe.
Future<RouteLog> pumpCaseHosted(WidgetTester tester, FakeApi api) async {
  final log = await pumpScreen(
    tester,
    const _Host(child: AdminDisputeDetailScreen(disputeId: 'd-1')),
    auth: _admin,
  );
  await tester.pumpAndSettle();
  return log;
}

/// The single note field inside the confirm dialog (or the note plus two score
/// fields when the action needs a scoreline), matched inside the open dialog.
Finder dialogFields() =>
    find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

/// The rule PATCHes recorded against the case path, method-filtered off the load GET.
Iterable<RecordedRequest> rulings(FakeApi api) =>
    api.to(kCase).where((r) => r.method == 'PATCH');

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kCase, caseJson());
  });

  group('the case as it loads', () {
    testWidgets('a spinner stands while the case is in flight', (tester) async {
      api.ok(kCase, caseJson(), delay: const Duration(milliseconds: 300));
      await pumpCase(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('28 pts at stake'), findsOneWidget);
    });

    testWidgets('the loaded case shows the stake, tally, cards and reason',
        (tester) async {
      await pumpCase(tester, api);
      await settleData(tester);

      // The header pills carry the server's own severity and the match's filed count.
      expect(find.text('28 pts at stake'), findsOneWidget);
      expect(find.text('1/2 filed'), findsOneWidget);
      // The two evidence cards render by title, and the one-sided hint follows the
      // submission count.
      expect(find.text('What each side filed'), findsOneWidget);
      expect(find.text('Only one side filed a result.'), findsOneWidget);
      expect(find.text('Rosters'), findsOneWidget);
      // Neither roster has members on record, so both blocks say so.
      expect(find.text('No members on record.'), findsNWidgets(2));
      expect(
          find.text('The opponent left at half time and we claimed the win.'),
          findsOneWidget);
    });

    testWidgets('a failed load reads as an honest could-not-load state',
        (tester) async {
      // `AdminService.disputeCase` returns null on non-success, and a null case is a
      // real, distinct state — the screen says so rather than showing a blank file.
      api.fail(kCase, 'boom');
      await pumpCase(tester, api);
      await settleData(tester);

      expect(find.text('This case could not be loaded.'), findsOneWidget);
    });
  });

  group('the ruling bar', () {
    testWidgets('a blocked correction disables ruling but keeps Dismiss',
        (tester) async {
      // The rating was already applied and the correction columns are missing, so the
      // server can reverse nothing; every result-changing action is off, and only
      // Dismiss — which changes no result — remains.
      api.ok(
        kCase,
        caseJson(
          needsCorrection: true,
          correctionAvailable: false,
          correctionBlockedBy: 'migration 022',
        ),
      );
      await pumpCase(tester, api);
      await settleData(tester);

      expect(find.textContaining('Only Dismiss is available.'), findsOneWidget);
      final rule = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Rule this dispute'));
      expect(rule.onPressed, isNull,
          reason: 'a blocked correction disables the ruling action');
      final dismiss = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Dismiss'));
      expect(dismiss.onPressed, isNotNull,
          reason: 'dismiss changes no result, so it stays available');
    });

    testWidgets('the bar is absent once the dispute is resolved', (tester) async {
      // The bar exists only while the case is open; a resolved case shows its record
      // instead, with no way to rule again.
      api.ok(kCase, caseJson(dispute: disputeRow(status: 'resolved')));
      await pumpCase(tester, api);
      await settleData(tester);

      expect(find.widgetWithText(ElevatedButton, 'Rule this dispute'),
          findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Dismiss'), findsNothing);
    });
  });

  group('dismissing', () {
    testWidgets('an empty note is refused in the client, costing no request',
        (tester) async {
      await pumpCase(tester, api);
      await settleData(tester);

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Dismiss this dispute'), findsOneWidget);

      // Confirm with no note: the dialog validates and sends nothing.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Dismiss it'));
      await tester.pump();

      expect(find.textContaining('A note is required'), findsOneWidget);
      expect(rulings(api).length, 0);
    });

    testWidgets('a dismiss patches the note without scores, then dismisses',
        (tester) async {
      await pumpCaseHosted(tester, api);

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Dismiss'));
      await tester.pumpAndSettle();
      await tester.enterText(
          dialogFields(), 'Left at half time; the walkover claim stands.');

      // The rule PATCH shares the case path; re-stub it to a success receipt. The
      // success path does not reload, so a bare envelope is safe here.
      api.on(kCase,
          FakeResponse(200, jsonEncode({'success': true, 'message': 'Ruling saved.'})));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Dismiss it'));
      await tester.pumpAndSettle();

      expect(rulings(api).length, 1, reason: 'exactly one rule PATCH');
      final body = jsonDecode(rulings(api).single.body!) as Map;
      expect(body['action'], 'dismiss');
      expect(body['note'], 'Left at half time; the walkover claim stands.');
      // A dismiss changes no result, so no scores travel — the null-aware body omits
      // the keys entirely rather than sending nulls.
      expect(body.containsKey('scoreChallenger'), isFalse);
      expect(body.containsKey('scoreOpponent'), isFalse);
      expect(find.text('Ruling saved.'), findsOneWidget);
      expect(find.text('host'), findsOneWidget,
          reason: 'the screen popped back to the host route');

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('ruling a custom scoreline', () {
    testWidgets('the sheet, the scores and the note reach the write body',
        (tester) async {
      await pumpCaseHosted(tester, api);

      // The ruling sheet offers the four result-changing actions; "your own" is always
      // available and asks for a scoreline.
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Rule this dispute'));
      await tester.pumpAndSettle();
      expect(find.text('Which result stands?'), findsOneWidget);

      await tester.tap(find.text('A scoreline of your own'));
      await tester.pumpAndSettle();
      expect(find.text('Rule your own scoreline'), findsOneWidget);

      // Two score fields (challenger, opponent) then the note, in tree order.
      expect(dialogFields(), findsNWidgets(3));
      await tester.enterText(dialogFields().at(0), '2');
      await tester.enterText(dialogFields().at(1), '1');
      await tester.enterText(dialogFields().at(2),
          'Both submissions were incomplete; recording it as played.');

      api.on(
          kCase,
          FakeResponse(
              200, jsonEncode({'success': true, 'message': 'Ruling saved. Ratings applied.'})));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Rule it'));
      await tester.pumpAndSettle();

      expect(rulings(api).length, 1);
      final body = jsonDecode(rulings(api).single.body!) as Map;
      expect(body['action'], 'rule_custom');
      expect(body['scoreChallenger'], 2);
      expect(body['scoreOpponent'], 1);
      expect(body['note'],
          'Both submissions were incomplete; recording it as played.');
      expect(find.text('Ruling saved. Ratings applied.'), findsOneWidget);
      expect(find.text('host'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('a side that never filed cannot be adopted', (tester) async {
      // The opponent filed nothing, so adopting their result is offered but disabled;
      // the sheet says why rather than letting the round trip fail.
      await pumpCase(tester, api);
      await settleData(tester);

      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Rule this dispute'));
      await tester.pumpAndSettle();

      // The challenger filed a scoreline and the opponent did not, so the "never
      // filed" copy belongs to the opponent's tile alone; find it by that copy rather
      // than by the curly-apostrophe title.
      expect(find.text('They never filed a scoreline'), findsOneWidget);
      final adoptOpponent = tester.widget<ListTile>(
          find.widgetWithText(ListTile, 'They never filed a scoreline'));
      expect(adoptOpponent.enabled, isFalse,
          reason: 'a side that never filed has nothing to adopt');
    });
  });

  group('reach and scale', () {
    testWidgets('the refresh control names itself', (tester) async {
      await pumpCase(tester, api);
      await settleData(tester);

      expect(find.byTooltip('Refresh'), findsOneWidget);
    });

    testWidgets('a doubled text scale keeps the stake pill present',
        (tester) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense card overflows at this scale in the harness alone; the contract is that
      // the content is still built.
      ignoreOverflow();
      await pumpCase(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('28 pts at stake'), findsOneWidget);
    });
  });
}

/// A base route beneath the screen under test. A ruling ends in `Navigator.pop`, and
/// popping the root route of a `MaterialApp` is not a state the screen is built for;
/// a host route makes that pop an ordinary one and lets a test confirm the screen was
/// dismissed by the host reappearing.
class _Host extends StatefulWidget {
  const _Host({required this.child});

  final Widget child;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => widget.child));
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('host')));
}
