// The two sheets that decide a match: submitting a score, and flagging one that was
// already decided.
//
// Both are one-shot writes with consequences the user cannot undo, and that is the
// reason they are tested together and tested this closely. A submission cannot be
// amended; a dispute freezes a rating platform-wide. Each sheet therefore carries a
// warning that has to read identically wherever it is opened from, and the exact
// sentences are pinned here rather than paraphrased — a warning that drifts between two
// screens is the same fault as a warning that is wrong on one.
//
// The contract most worth protecting has no pixels at all. Scores are stored
// challenger-first, because that is the only orientation in which two captains'
// submissions are comparable; the rows are re-ordered for whoever is looking, and the
// numbers are not. So the tests drive the sheet from the opponent's seat as well as the
// challenger's and assert on the POST body, not on the display: a mirrored payload would
// look perfectly correct on screen and would silently record the match backwards.
//
// The stated winner is asserted alongside it. The server derives the winner itself and
// rejects a submission that disagrees, which makes this field a cross-check rather than
// a source of truth — and makes a wrong one a rejected submission for a captain who has
// only one. A draw omits the key entirely rather than sending null, and that too is
// pinned, because the service builds the body with a null-aware entry and the difference
// between an absent key and a null one has bitten this API before.
//
// The three outcomes of a successful submission are the other half. The backend answers
// with the status the match landed in, and the captain has to be told which of the three
// happened in the backend's own terms: the pair is still incomplete, the pair agreed and
// the owner is next, or the pair disagreed and the match is frozen as disputed. Showing
// a cheerful success for the third is the regression these cases exist to catch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/match.dart';
import 'package:sportlynk/widgets/match_result_dialog.dart';

import '../services/http_seam.dart';
import 'widget_harness.dart';

/// One side of a match, with only the fields these two sheets read given values.
///
/// `logoUrl` is left null throughout: [TeamCrest] hands a non-empty url to
/// `CachedNetworkImageProvider`, which would reach the network from a test.
MatchSide side({String id = 't1', String name = 'Lahore Lions'}) => MatchSide(
      id: id,
      name: name,
      elo: 1000,
      ranked: true,
      played: 4,
      wins: 2,
      losses: 1,
      draws: 1,
      eloFrozen: false,
    );

/// A match ready for a result, seen from a seat the caller chooses.
MatchModel match({
  String id = 'm1',
  bool iAmChallenger = true,
  String status = MatchStatus.awaitingResults,
}) =>
    MatchModel(
      id: id,
      status: status,
      challenger: side(id: 'tc', name: 'Lahore Lions'),
      opponent: side(id: 'to', name: 'Karachi Kings'),
      isDraw: false,
      eloApplied: false,
      resultsLocked: false,
      resultsIn: 0,
      slotStarted: true,
      myTeamId: iAmChallenger ? 'tc' : 'to',
      iAmChallenger: iAmChallenger,
      iAmVenueOwner: false,
    );

void main() {
  tearDown(resetApiClient);

  /// Pumps a modal route's entrance out. A single `pump` leaves the sheet part-way
  /// through its transition, and a tap on a widget short of its final offset derives an
  /// off-screen hit-test point and misses without failing.
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Opens the result sheet the way the match list does, recording what it resolved to.
  Future<List<bool?>> openResult(
    WidgetTester tester, {
    MatchModel? m,
    String token = 'tok-1',
    double textScale = 1.0,
  }) async {
    final results = <bool?>[];
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          backgroundColor: AppColors.background,
          body: Center(
            child: ElevatedButton(
              onPressed: () async => results.add(
                await showMatchResultSheet(context,
                    match: m ?? match(), token: token),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      textScale: textScale,
    );
    await tester.tap(find.text('open'));
    await settleSheet(tester);
    return results;
  }

  /// Opens the dispute sheet, recording what it resolved to.
  Future<List<bool?>> openDispute(
    WidgetTester tester, {
    MatchModel? m,
    String token = 'tok-1',
    int windowHours = 24,
    double textScale = 1.0,
  }) async {
    final results = <bool?>[];
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          backgroundColor: AppColors.background,
          body: Center(
            child: ElevatedButton(
              onPressed: () async => results.add(
                await showMatchDisputeSheet(
                  context,
                  match: m ?? match(status: MatchStatus.completed),
                  token: token,
                  windowHours: windowHours,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      textScale: textScale,
    );
    await tester.tap(find.text('open'));
    await settleSheet(tester);
    return results;
  }

  /// The step button carrying [icon] on stepper [row] — 0 is the viewer's own team,
  /// which is always drawn first.
  InkWell stepButton(WidgetTester tester, IconData icon, int row) =>
      tester.widget<InkWell>(
        find
            .ancestor(of: find.byIcon(icon).at(row), matching: find.byType(InkWell))
            .first,
      );

  group('the result sheet as it opens', () {
    testWidgets('the two teams are named, the viewer\'s first', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        expect(find.text('Submit final score'), findsOneWidget);
        expect(find.text('Lahore Lions vs Karachi Kings'), findsOneWidget);
        final mine = tester.getTopLeft(find.text('Your team')).dy;
        final theirs = tester.getTopLeft(find.text('Opponent')).dy;
        expect(mine, lessThan(theirs),
            reason: 'the captain reads their own score first');
      });
    });

    // The viewer sits in the opponent's seat: the rows swap, and the point of the next
    // group is that the payload does not.
    testWidgets('the opponent\'s captain sees their own team first',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester, m: match(iAmChallenger: false));
        expect(find.text('Karachi Kings vs Lahore Lions'), findsOneWidget);
        final own = tester.getTopLeft(find.text('Karachi Kings')).dy;
        final other = tester.getTopLeft(find.text('Lahore Lions')).dy;
        expect(own, lessThan(other));
      });
    });

    testWidgets('both scores start at zero and the verdict is a draw',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        expect(find.text('0'), findsNWidgets(2));
        expect(find.text('Draw'), findsOneWidget);
        expect(find.text('Submit 0 – 0'), findsOneWidget);
      });
    });

    testWidgets('the one-shot warning is shown in full', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        expect(
          find.text('You can submit once. If the other captain reports a different '
              'score the match is frozen as disputed and no ratings move until an '
              'admin resolves it.'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.lock_clock), findsOneWidget);
      });
    });

    testWidgets('nothing is sent by opening the sheet', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        expect(api.sent, isEmpty);
      });
    });
  });

  group('counting the goals', () {
    testWidgets('the plus raises one score and leaves the other alone',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.pump();
        expect(find.text('1'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
        expect(find.text('Submit 1 – 0'), findsOneWidget);
      });
    });

    testWidgets('the minus is dead at zero', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        expect(stepButton(tester, Icons.remove, 0).onTap, isNull,
            reason: 'a negative score is not a score');
        expect(stepButton(tester, Icons.add, 0).onTap, isNotNull);
      });
    });

    testWidgets('the minus comes alive once there is something to take away',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.pump();
        expect(stepButton(tester, Icons.remove, 0).onTap, isNotNull);
        await tester.tap(find.byIcon(Icons.remove).at(0));
        await tester.pump();
        expect(find.text('0'), findsNWidgets(2));
      });
    });

    testWidgets('the verdict names the leader by name', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.byIcon(Icons.add).at(1));
        await tester.pump();
        expect(find.text('Karachi Kings wins'), findsOneWidget);
        expect(find.text('Draw'), findsNothing);
      });
    });

    testWidgets('a level score goes back to being a draw', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.tap(find.byIcon(Icons.add).at(1));
        await tester.pump();
        expect(find.text('Draw'), findsOneWidget);
        expect(find.text('Submit 1 – 1'), findsOneWidget);
      });
    });
  });

  // The orientation contract. The rows follow the viewer; the payload never does.
  group('which score belongs to which side', () {
    testWidgets('the challenger\'s captain sends their goals as the challenger\'s',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester, m: match(iAmChallenger: true));
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.tap(find.byIcon(Icons.add).at(1));
        await tester.pump();
        await tester.tap(find.text('Submit 2 – 1'));
        await tester.pump();
        expect(api.body()['scoreChallenger'], 2);
        expect(api.body()['scoreOpponent'], 1);
      });
    });

    // The same taps from the other seat have to produce the mirror payload, or the
    // match is recorded backwards while the screen looks right.
    testWidgets('the opponent\'s captain sends theirs as the opponent\'s',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester, m: match(iAmChallenger: false));
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.tap(find.byIcon(Icons.add).at(1));
        await tester.pump();
        await tester.tap(find.text('Submit 2 – 1'));
        await tester.pump();
        expect(api.body()['scoreOpponent'], 2,
            reason: 'the viewer\'s two goals belong to the opponent side of the record');
        expect(api.body()['scoreChallenger'], 1);
      });
    });

    testWidgets('the stated winner is the challenger when the challenger leads',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester, m: match(iAmChallenger: true));
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.pump();
        await tester.tap(find.text('Submit 1 – 0'));
        await tester.pump();
        expect(api.body()['winnerTeam'], 'tc');
      });
    });

    testWidgets('and the opponent when the opponent does, whoever is looking',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester, m: match(iAmChallenger: false));
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.pump();
        await tester.tap(find.text('Submit 1 – 0'));
        await tester.pump();
        expect(api.body()['winnerTeam'], 'to',
            reason: 'the winner is a team id, not a seat');
      });
    });

    // An absent key and a null one are not the same thing to this API, and the service
    // builds the body with a null-aware entry precisely so a draw omits it.
    testWidgets('a draw states no winner at all', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        expect(api.body().containsKey('winnerTeam'), isFalse);
        expect(api.body()['scoreChallenger'], 0);
        expect(api.body()['scoreOpponent'], 0);
      });
    });

    testWidgets('the submission goes to this match\'s own result route',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester, m: match(id: 'm-99'));
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        expect(api.endpoint(), '/matches/m-99/result');
        expect(api.method(), 'POST');
        expect(api.token(), 'tok-1');
      });
    });
  });

  // One submission, three possible landings, and the captain is told which in the
  // backend's own terms.
  group('what the captain is told afterwards', () {
    testWidgets('a first submission says the other captain is still to come',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        final results = await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Result submitted. Waiting for the other captain.'),
            findsOneWidget);
        expect(results.single, isTrue);
      });
    });

    testWidgets('an agreed pair hands the match to the venue owner',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingOwner});
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(
          find.text('Both captains agree. The venue owner will verify the result.'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.check_circle), findsOneWidget);
      });
    });

    // The write succeeded and the news is bad. Reporting this as a plain success is the
    // regression worth catching: the captain would learn about the dispute later, from
    // somewhere else.
    testWidgets('a disagreement is reported as a dispute, not as a success',
        (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.disputed});
      await api.run(() async {
        final results = await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(
          find.text('Your result does not match your opponent\'s. The match is now '
              'disputed and an admin will review it.'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.error_outline), findsOneWidget,
            reason: 'the error tone is what separates this from the agreed case');
        expect(results.single, isTrue,
            reason: 'the submission itself landed, so the caller still reloads');
      });
    });

    testWidgets('a reply with no status falls back to the neutral sentence',
        (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Result submitted. Waiting for the other captain.'),
            findsOneWidget);
      });
    });

    testWidgets('a reply whose data is not an object is survived', (tester) async {
      final api = FakeApi()..ok('done');
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Result submitted. Waiting for the other captain.'),
            findsOneWidget);
      });
    });
  });

  group('when the submission is refused', () {
    testWidgets('the server\'s reason is shown and the sheet stays open',
        (tester) async {
      final api = FakeApi()..fail('Your team has already submitted a result.');
      await api.run(() async {
        final results = await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Your team has already submitted a result.'),
            findsOneWidget);
        expect(find.text('Submit final score'), findsOneWidget,
            reason: 'a refused submission must not look like a completed one');
        expect(results, isEmpty);
      });
    });

    testWidgets('an unreachable server gets the sheet\'s own sentence',
        (tester) async {
      final api = FakeApi()..offline();
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Could not submit the result.'), findsOneWidget);
      });
    });

    testWidgets('the scores survive the failure', (tester) async {
      final api = FakeApi()..fail('Try again.');
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.tap(find.byIcon(Icons.add).at(0));
        await tester.pump();
        await tester.tap(find.text('Submit 2 – 0'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Submit 2 – 0'), findsOneWidget,
            reason: 'a captain who counted the goals should not count them twice');
      });
    });

    testWidgets('a second attempt is allowed', (tester) async {
      final api = FakeApi()
        ..fail('Try again.')
        ..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        final results = await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        await tester.pump();
        expect(api.sent.length, 2);
        expect(results.single, isTrue);
      });
    });
  });

  group('while the submission is in flight', () {
    testWidgets('the button becomes a spinner and refuses a second press',
        (tester) async {
      final api = FakeApi()..hang();
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        expect(find.text('Submit 0 – 0'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        final submit = tester.widget<FilledButton>(find.byType(FilledButton));
        expect(submit.onPressed, isNull,
            reason: 'a double tap would use up the one submission twice');
      });
    });

    testWidgets('cancel is locked out too', (tester) async {
      final api = FakeApi()..hang();
      await api.run(() async {
        await openResult(tester);
        await tester.tap(find.text('Submit 0 – 0'));
        await tester.pump();
        final cancel = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
        expect(cancel.onPressed, isNull,
            reason: 'leaving mid-write would hide the outcome of a one-shot action');
      });
    });
  });

  group('backing out of the result sheet', () {
    testWidgets('cancel resolves false and sends nothing', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        final results = await openResult(tester);
        await tester.tap(find.text('Cancel'));
        await settleSheet(tester);
        expect(results.single, isFalse);
        expect(api.sent, isEmpty);
      });
    });

    testWidgets('a drag down resolves null', (tester) async {
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        final results = await openResult(tester);
        await tester.drag(find.text('Submit final score'), const Offset(0, 600));
        await settleSheet(tester);
        await settleSheet(tester);
        expect(results.single, isNull,
            reason: 'null and false both mean "nothing was recorded"');
        expect(api.sent, isEmpty);
      });
    });
  });

  group('the dispute sheet as it opens', () {
    testWidgets('the window is stated in hours, from the caller', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester, windowHours: 24);
        expect(find.text('Flag this result'), findsOneWidget);
        expect(
          find.text('A result can be flagged within 24 hours of being verified. Say '
              'what was wrong — an admin reads this and nothing else.'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.gavel), findsOneWidget);
      });
    });

    // The window is server policy, so a changed policy must reach the sentence rather
    // than being hardcoded beside it.
    testWidgets('a different window changes the sentence', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester, windowHours: 48);
        expect(find.textContaining('within 48 hours'), findsOneWidget);
      });
    });

    testWidgets('the freeze warning is shown in full', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester);
        expect(
          find.text('Disputing repeatedly gets a team\'s rating frozen platform-wide. '
              'Use this when the result is genuinely wrong.'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.ac_unit), findsOneWidget);
      });
    });

    testWidgets('the hint shows the shape of a usable reason', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester);
        expect(
          find.text('e.g. The final score was 2–1, not 3–1. Second goal was disallowed.'),
          findsOneWidget,
        );
      });
    });

    testWidgets('the reason is capped so it cannot be a novel', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.maxLength, 500);
        expect(field.maxLines, 4);
      });
    });
  });

  // The floor is mirrored from the backend so a captain finds out while typing rather
  // than after a round trip that costs them the attempt.
  group('the reason has to be actionable', () {
    testWidgets('the flag button is dead on an empty field', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester);
        expect(find.text('At least 10 characters so it can be acted on'),
            findsOneWidget);
        final flag = tester.widget<FilledButton>(find.byType(FilledButton));
        expect(flag.onPressed, isNull);
      });
    });

    testWidgets('nine characters are still not enough', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester);
        await tester.enterText(find.byType(TextField), 'wrong sco');
        await tester.pump();
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull);
      });
    });

    testWidgets('ten unlock it and the helper says so', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester);
        await tester.enterText(find.byType(TextField), 'wrong score');
        await tester.pump();
        expect(find.text('Ready to send'), findsOneWidget);
        expect(find.text('At least 10 characters so it can be acted on'),
            findsNothing);
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNotNull);
      });
    });

    testWidgets('spaces do not count towards the floor', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester);
        await tester.enterText(find.byType(TextField), '            ');
        await tester.pump();
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
            reason: 'twelve spaces are not a reason an admin can act on');
      });
    });
  });

  group('filing the dispute', () {
    testWidgets('the reason goes to this match\'s dispute route, trimmed',
        (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester, m: match(id: 'm-7', status: MatchStatus.completed));
        await tester.enterText(
            find.byType(TextField), '  The second goal was disallowed.  ');
        await tester.pump();
        await tester.tap(find.text('Flag'));
        await tester.pump();
        expect(api.endpoint(), '/matches/m-7/dispute');
        expect(api.method(), 'POST');
        expect(api.token(), 'tok-1');
        expect(api.body()['reason'], 'The second goal was disallowed.');
      });
    });

    testWidgets('the sheet closes and says what happens to the ratings',
        (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        final results = await openDispute(tester);
        await tester.enterText(find.byType(TextField), 'The score was 2-1, not 3-1.');
        await tester.pump();
        await tester.tap(find.text('Flag'));
        await tester.pump();
        await tester.pump();
        expect(
          find.text('Flagged for review. Ratings from this match stay frozen until '
              'an admin decides.'),
          findsOneWidget,
        );
        expect(results.single, isTrue);
      });
    });

    testWidgets('the button becomes a spinner and refuses a second press',
        (tester) async {
      final api = FakeApi()..hang();
      await api.run(() async {
        await openDispute(tester);
        await tester.enterText(find.byType(TextField), 'The score was wrong.');
        await tester.pump();
        await tester.tap(find.text('Flag'));
        await tester.pump();
        expect(find.text('Flag'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull);
        expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
            isNull);
      });
    });

    testWidgets('a refusal keeps the sheet and the typed reason', (tester) async {
      final api = FakeApi()..fail('The 24 hour window has closed.');
      await api.run(() async {
        final results = await openDispute(tester);
        await tester.enterText(find.byType(TextField), 'The score was 2-1, not 3-1.');
        await tester.pump();
        await tester.tap(find.text('Flag'));
        await tester.pump();
        await tester.pump();
        expect(find.text('The 24 hour window has closed.'), findsOneWidget);
        expect(find.text('Flag this result'), findsOneWidget);
        expect(find.text('The score was 2-1, not 3-1.'), findsOneWidget,
            reason: 'the captain should not have to write the reason again');
        expect(results, isEmpty);
      });
    });

    testWidgets('an unreachable server gets the sheet\'s own sentence',
        (tester) async {
      final api = FakeApi()..offline();
      await api.run(() async {
        await openDispute(tester);
        await tester.enterText(find.byType(TextField), 'The score was wrong.');
        await tester.pump();
        await tester.tap(find.text('Flag'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Could not file the dispute.'), findsOneWidget);
      });
    });

    testWidgets('cancel resolves false and files nothing', (tester) async {
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        final results = await openDispute(tester);
        await tester.enterText(find.byType(TextField), 'The score was wrong.');
        await tester.pump();
        await tester.tap(find.text('Cancel'));
        await settleSheet(tester);
        expect(results.single, isFalse);
        expect(api.sent, isEmpty);
      });
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the result sheet still lays out', (tester) async {
      useDeviceSurface(tester);
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester, textScale: 2.0);
        expect(find.text('Submit final score'), findsOneWidget);
        expectNoOverflow(tester);
      });
    });

    testWidgets('the dispute sheet still lays out', (tester) async {
      useDeviceSurface(tester);
      final api = FakeApi()..ok(<String, dynamic>{});
      await api.run(() async {
        await openDispute(tester, textScale: 2.0);
        expect(find.text('Flag this result'), findsOneWidget);
        expectNoOverflow(tester);
      });
    });

    testWidgets('both footer buttons clear the tap-target floor', (tester) async {
      useDeviceSurface(tester);
      final api = FakeApi()..ok({'status': MatchStatus.awaitingResults});
      await api.run(() async {
        await openResult(tester);
        expectTapTarget(tester, find.byType(FilledButton));
        expectTapTarget(tester, find.byType(OutlinedButton));
      });
    });
  });
}
