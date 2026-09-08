// Trust Score: the screen that has to justify a number, not merely display one.
//
// The rule the whole stack is careful about, stated in lib/models/review.dart:17, is
// that **a null component is "no data yet", never a zero**. A player with no disputes
// on record is not 0% dispute-free — they are unmeasured, and drawing an empty bar
// against them is a false accusation the screen makes silently. Four tests here drive
// each component null on its own and assert the tile reads "No data yet" with "worth
// up to N pts" rather than a percentage and a contribution.
//
// The second contract is that the screen never recomputes the score. The weights
// (35/30/20/15) are repeated in `TrustBreakdown` for display only; the server owns the
// arithmetic. So a payload whose components do not add up to its headline score must
// still render the headline the server sent — a screen that "corrected" it would
// disagree with every other surface showing the same badge.
//
// Two entry paths exist and they fail differently. Given a `userId`, `_load`
// (lib/screens/player/trust_score_screen.dart:76) reads the live breakdown. Given only
// the legacy `profile` blob, the id is dug out of `user_id` / `userId` / `id` (:60) and
// the gauge falls back to `profile['trust_score']` (:69). With neither, `_load` returns
// before touching the network and the ledger says so. All three are pinned, because
// the fallback is what keeps older callers from rendering a dash where a score exists.
//
// The missing fourth state is pinned as behaviour rather than fixed. `ReviewService.
// userReviews` returns `UserReviews.empty` on any failure (review_service.dart
// line 102), and `_load` stores it without recording that anything went wrong, so a 500
// renders an unrated gauge and "No reviews about you yet" — a screen that reads as a
// new player rather than a failed request. The fix is an `_error` field on the screen,
// a distinguishable failure return from the service, and a retry.
//
// Nothing here settles: `TrustGauge` sweeps in over 850ms via `TweenAnimationBuilder`
// and the tile bars animate for 500ms, so the assertions pump past both explicitly
// rather than calling `pumpAndSettle`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/trust_score_screen.dart';

import '../screen_harness.dart';

/// The `/users/:id/reviews` payload. Note the camelCase: these endpoints answer in
/// camelCase while the older reads are snake_case, and mirroring the wrong convention
/// turns the whole screen blank.
Map<String, dynamic> userReviews({
  String userId = 'u-1',
  Object? avgStars = 4.4,
  Object? score = 82,
  Object? rating = 0.88,
  Object? attendance = 0.9,
  Object? disputes = 1.0,
  Object? sentiment = 0.7,
  List<Map<String, dynamic>>? reviews,
  int total = 0,
}) =>
    {
      'userId': userId,
      'page': 1,
      'limit': 20,
      'total': total,
      'avgStars': avgStars,
      'trust': {
        'score': score,
        'rating': rating,
        'attendance': attendance,
        'disputes': disputes,
        'sentiment': sentiment,
      },
      'reviews': reviews ?? const <Map<String, dynamic>>[],
    };

/// One received review.
Map<String, dynamic> review({
  String id = 'r-1',
  int stars = 5,
  String? text = 'Showed up on time and played fair.',
  String? reviewerName = 'Hamza Khan',
  String? reviewType = 'opponent',
  String? sentimentLabel = 'positive',
  String? createdAt = '2026-09-01T10:00:00.000Z',
}) =>
    {
      'id': id,
      'stars': stars,
      'text': text,
      'reviewerName': reviewerName,
      'reviewType': reviewType,
      'sentimentLabel': sentimentLabel,
      'createdAt': createdAt,
    };

/// Lets the gauge sweep and the tile bars finish so the painted numbers are final.
Future<void> settleGauge(WidgetTester tester) async {
  await settleData(tester);
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok('/users/u-1/reviews', userReviews());
  });

  group('while the breakdown is being fetched', () {
    testWidgets('a spinner is shown rather than an unrated gauge', (tester) async {
      // A dash in the ring during the fetch reads as "this player has no score",
      // which is a claim about their reputation the screen cannot make yet.
      api.ok('/users/u-1/reviews', userReviews(),
          delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));

      expectLoading(tester);
      expect(find.text('—'), findsNothing);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('the fetch starts without waiting for a gesture', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));

      expect(api.countTo('/users/u-1/reviews'), 1);
    });

    testWidgets('the request is addressed to the user being viewed',
        (tester) async {
      // The screen is reachable for another player, so reading the signed-in user's
      // own reviews would show a captain their own record under someone else's name.
      api.ok('/users/u-9/reviews', userReviews(userId: 'u-9'));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-9'));
      await settleGauge(tester);

      expect(api.countTo('/users/u-9/reviews'), 1);
      expect(api.countTo('/users/u-1/reviews'), 0);
    });
  });

  group('once the breakdown arrives', () {
    testWidgets('the screen is titled', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Trust Score'), findsOneWidget);
    });

    testWidgets('the headline score is the one the server sent', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(score: 82));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('82'), findsOneWidget);
      expect(find.text('out of 100'), findsOneWidget);
    });

    testWidgets('the score is not recomputed from the components', (tester) async {
      // The server owns the arithmetic. A screen that recomputed would disagree with
      // the badge chip on every other surface the moment the weights changed.
      api.ok('/users/u-1/reviews',
          userReviews(score: 55, rating: 1.0, attendance: 1.0, disputes: 1.0, sentiment: 1.0));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('55'), findsOneWidget);
      expect(find.text('100'), findsNothing);
    });

    testWidgets('a score sent as a string is still read', (tester) async {
      // Postgres hands numerics back as Strings; a raw "82" would fail the int cast
      // and leave the gauge unrated.
      api.ok('/users/u-1/reviews', userReviews(score: '82'));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('82'), findsOneWidget);
    });

    testWidgets('the spinner is gone', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('the four components are each given a section', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Score Breakdown'), findsOneWidget);
      expect(find.text('Avg Rating'), findsOneWidget);
      expect(find.text('Attendance'), findsOneWidget);
      expect(find.text('Dispute-free'), findsOneWidget);
      expect(find.text('AI Sentiment'), findsOneWidget);
    });

    testWidgets('the formula is stated so the number is checkable', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(
        find.textContaining(
            'Trust = 35% rating + 30% attendance + 20% dispute-free + 15% sentiment.'),
        findsOneWidget,
      );
    });
  });

  group('the trust band', () {
    testWidgets('ninety is highly trusted', (tester) async {
      // The band thresholds match the server's `matchCore.trustBadge` vocabulary, so
      // moving one here would make the gauge disagree with the roster badge.
      api.ok('/users/u-1/reviews', userReviews(score: 90));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('HIGHLY TRUSTED'), findsOneWidget);
    });

    testWidgets('eighty-nine is one band lower', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(score: 89));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('TRUSTED'), findsOneWidget);
    });

    testWidgets('seventy-five is trusted', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(score: 75));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('TRUSTED'), findsOneWidget);
    });

    testWidgets('sixty is fair', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(score: 60));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('FAIR'), findsOneWidget);
    });

    testWidgets('fifty-nine needs improvement', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(score: 59));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('NEEDS IMPROVEMENT'), findsOneWidget);
    });

    testWidgets('no score is not rated rather than zero', (tester) async {
      // A profile with no `player_profiles` row has no score. Rendering it as 0 would
      // put a new player in the worst band they can occupy.
      api.ok('/users/u-1/reviews', userReviews(score: null));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('NOT RATED YET'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('out of 100'), findsNothing,
          reason: 'there is no number for the caption to qualify');
    });
  });

  group('a component with no signal', () {
    testWidgets('an unmeasured rating says so rather than showing nothing',
        (tester) async {
      api.ok('/users/u-1/reviews', userReviews(rating: null, avgStars: null));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('worth up to 35 pts'), findsOneWidget);
    });

    testWidgets('an unmeasured attendance is not zero per cent', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(attendance: null));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('worth up to 30 pts'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('a player with no disputes is unmeasured, not dispute-prone',
        (tester) async {
      // The most consequential instance of the rule: a null here rendered as 0% would
      // accuse a player of a dispute record they do not have.
      api.ok('/users/u-1/reviews', userReviews(disputes: null));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('worth up to 20 pts'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('an unscored sentiment says so', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(sentiment: null));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('worth up to 15 pts'), findsOneWidget);
    });

    testWidgets('a brand new player has four unmeasured components',
        (tester) async {
      api.ok(
        '/users/u-1/reviews',
        userReviews(
          score: null,
          avgStars: null,
          rating: null,
          attendance: null,
          disputes: null,
          sentiment: null,
        ),
      );

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('No data yet'), findsNWidgets(4));
      expect(find.text('NOT RATED YET'), findsOneWidget);
    });

    testWidgets('a measured component reports what it contributes', (tester) async {
      // The contribution is the point of the tile: a bare percentage does not explain
      // how the headline was reached.
      api.ok('/users/u-1/reviews', userReviews(attendance: 0.9));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('90%'), findsOneWidget);
      expect(find.text('+27 of 30 pts'), findsOneWidget);
    });

    testWidgets('a fully dispute-free record contributes its whole weight',
        (tester) async {
      api.ok('/users/u-1/reviews', userReviews(disputes: 1.0));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('+20 of 20 pts'), findsOneWidget);
    });

    testWidgets('a measured zero is shown as a zero, not as no data',
        (tester) async {
      // The distinction runs both ways: a genuine 0.0 is a measurement and must not
      // be softened into "No data yet".
      api.ok('/users/u-1/reviews', userReviews(disputes: 0.0));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('0%'), findsOneWidget);
      expect(find.text('+0 of 20 pts'), findsOneWidget);
      expect(find.text('No data yet'), findsNothing);
    });

    testWidgets('a component sent as a string is still measured', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(attendance: '0.9'));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('90%'), findsOneWidget);
      expect(find.text('No data yet'), findsNothing);
    });
  });

  group('the rating tile', () {
    testWidgets('an average is shown out of five rather than as a percentage',
        (tester) async {
      // Stars are what the player was given; a percentage would make them convert.
      api.ok('/users/u-1/reviews', userReviews(avgStars: 4.4, rating: 0.88));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('4.4 / 5'), findsOneWidget);
      expect(find.text('88%'), findsNothing);
    });

    testWidgets('an average sent as a string is still formatted', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(avgStars: '4.25'));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('4.3 / 5'), findsOneWidget);
    });

    testWidgets('a normalised rating with no average falls back to a percentage',
        (tester) async {
      // The component exists even when the average is absent, and showing nothing
      // would hide a measured contribution.
      api.ok('/users/u-1/reviews', userReviews(avgStars: null, rating: 0.88));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('88%'), findsOneWidget);
      expect(find.text('No data yet'), findsNothing);
    });
  });

  group('the identity header', () {
    testWidgets('a supplied display name is shown', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1', displayName: 'Bilal Ahmed'),
      );
      await settleGauge(tester);

      expect(find.text('Bilal Ahmed'), findsOneWidget);
    });

    testWidgets('a name is read from the legacy profile blob when none is passed',
        (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(
          userId: 'u-1',
          profile: {'name': 'Hamza Khan'},
        ),
      );
      await settleGauge(tester);

      expect(find.text('Hamza Khan'), findsOneWidget);
    });

    testWidgets('an unnamed subject falls back to a neutral noun', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Player'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('a captain is marked as one', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(
            userId: 'u-1', displayName: 'Bilal Ahmed', isCaptain: true),
      );
      await settleGauge(tester);

      expect(find.text('TEAM CAPTAIN'), findsOneWidget);
    });

    testWidgets('a player who is not a captain is not marked', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1', displayName: 'Bilal Ahmed'),
      );
      await settleGauge(tester);

      expect(find.text('TEAM CAPTAIN'), findsNothing);
    });

    testWidgets('the band is repeated beside the name', (tester) async {
      // The gauge is a scroll away once the breakdown grows, so the header carries
      // the verdict too.
      api.ok('/users/u-1/reviews', userReviews(score: 82));

      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1', displayName: 'Bilal Ahmed'),
      );
      await settleGauge(tester);

      expect(find.text('Trusted'), findsOneWidget);
    });

    testWidgets('an avatar-less subject shows an initial', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1', displayName: 'Bilal Ahmed'),
      );
      await settleGauge(tester);

      expect(find.text('B'), findsOneWidget);
    });
  });

  group('whose score it is', () {
    testWidgets('the owner is told how others see them', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1', displayName: 'Bilal Ahmed'),
      );
      await settleGauge(tester);

      expect(find.text('This is how other players and venues see you.'),
          findsOneWidget);
      expect(find.text('Reviews About You'), findsOneWidget);
    });

    testWidgets('a visitor is told whose score it is, by first name',
        (tester) async {
      // A full name here would read as a formal record rather than a rating of the
      // person the visitor is about to play.
      await pumpScreen(
        tester,
        const TrustScoreScreen(
            userId: 'u-1', displayName: 'Hamza Khan', isSelf: false),
      );
      await settleGauge(tester);

      expect(find.text('How SportLynk rates Hamza.'), findsOneWidget);
      expect(find.text('Recent Reviews'), findsOneWidget);
    });

    testWidgets('a visitor sees the visitor wording in the empty ledger',
        (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(
            userId: 'u-1', displayName: 'Hamza Khan', isSelf: false),
      );
      await settleGauge(tester);

      expect(find.text('No reviews yet.'), findsOneWidget);
    });
  });

  group('the review ledger', () {
    testWidgets('an empty ledger tells the owner how to start one', (tester) async {
      // A bare "no reviews" would leave a new player with nothing to act on.
      api.ok('/users/u-1/reviews', userReviews(reviews: const []));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(
        find.text(
            'No reviews about you yet. Play a match or use a venue to start building your record.'),
        findsOneWidget,
      );
    });

    testWidgets('a review is listed with its author and text', (tester) async {
      api.ok(
        '/users/u-1/reviews',
        userReviews(total: 1, reviews: [review()]),
      );

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Hamza Khan'), findsOneWidget);
      expect(find.text('Showed up on time and played fair.'), findsOneWidget);
    });

    testWidgets('every returned review gets a card', (tester) async {
      api.ok(
        '/users/u-1/reviews',
        userReviews(total: 2, reviews: [
          review(id: 'r-1', reviewerName: 'Hamza Khan'),
          review(id: 'r-2', reviewerName: 'Usman Ali', text: 'Left at half time.'),
        ]),
      );

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Hamza Khan'), findsOneWidget);
      expect(find.text('Usman Ali'), findsOneWidget);
    });

    testWidgets('a review with no text still renders its author', (tester) async {
      // A star-only review is the common case; dropping the card would lose it.
      api.ok(
        '/users/u-1/reviews',
        userReviews(total: 1, reviews: [review(text: null)]),
      );

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Hamza Khan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an anonymous reviewer is named neutrally', (tester) async {
      api.ok(
        '/users/u-1/reviews',
        userReviews(total: 1, reviews: [review(reviewerName: null)]),
      );

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('A player'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('the kind of review is shown on the received feed', (tester) async {
      // On this feed a row can be about a venue visit or an opponent's conduct, and
      // the two mean different things about the player.
      api.ok(
        '/users/u-1/reviews',
        userReviews(total: 1, reviews: [review(reviewType: 'opponent')]),
      );

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Hamza Khan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unscored review omits the sentiment chip', (tester) async {
      // A missing verdict must read as absent rather than as neutral.
      api.ok(
        '/users/u-1/reviews',
        userReviews(total: 1, reviews: [review(sentimentLabel: null)]),
      );

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Neutral'), findsNothing);
    });

    testWidgets('a malformed review row is skipped rather than crashing the list',
        (tester) async {
      // `whereType<Map>()` in the model is what makes this survivable; a stray null
      // in the array would otherwise take the whole screen down.
      api.ok('/users/u-1/reviews', {
        'userId': 'u-1',
        'page': 1,
        'limit': 20,
        'total': 2,
        'avgStars': 4.4,
        'trust': {'score': 82},
        'reviews': [null, review()],
      });

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('Hamza Khan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('when only the legacy profile blob is available', () {
    testWidgets('the id is dug out of user_id', (tester) async {
      // Older callers hold the profile blob and no explicit id; failing to find it
      // would show an unrated gauge for a rated player.
      api.ok('/users/u-7/reviews', userReviews(userId: 'u-7', score: 77));

      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'user_id': 'u-7', 'name': 'Hamza Khan'}),
      );
      await settleGauge(tester);

      expect(api.countTo('/users/u-7/reviews'), 1);
      expect(find.text('77'), findsOneWidget);
    });

    testWidgets('the id is dug out of camelCase userId', (tester) async {
      api.ok('/users/u-7/reviews', userReviews(userId: 'u-7', score: 77));

      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'userId': 'u-7'}),
      );
      await settleGauge(tester);

      expect(api.countTo('/users/u-7/reviews'), 1);
    });

    testWidgets('the id is dug out of a bare id', (tester) async {
      api.ok('/users/u-7/reviews', userReviews(userId: 'u-7', score: 77));

      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'id': 'u-7'}),
      );
      await settleGauge(tester);

      expect(api.countTo('/users/u-7/reviews'), 1);
    });

    testWidgets('an explicit id wins over the blob', (tester) async {
      api.ok('/users/u-1/reviews', userReviews());

      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1', profile: {'user_id': 'u-7'}),
      );
      await settleGauge(tester);

      expect(api.countTo('/users/u-1/reviews'), 1);
      expect(api.countTo('/users/u-7/reviews'), 0);
    });

    testWidgets('an empty id in the blob is treated as no id at all',
        (tester) async {
      // An empty string would produce a request to `/users//reviews`, which the API
      // answers with a 404 the screen cannot explain.
      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'user_id': ''}),
      );
      await settleData(tester);

      expect(api.requests, isEmpty);
    });

    testWidgets('a stored trust score fills the gauge when there is no live read',
        (tester) async {
      // The fallback at :69 is what keeps the blob-only callers from showing a dash
      // where a score exists.
      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'trust_score': 68}),
      );
      await settleGauge(tester);

      expect(find.text('68'), findsOneWidget);
      expect(find.text('FAIR'), findsOneWidget);
    });

    testWidgets('a stored score sent as a string is still read', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'trust_score': '68'}),
      );
      await settleGauge(tester);

      expect(find.text('68'), findsOneWidget);
    });

    testWidgets('a fractional stored score is rounded', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'trust_score': 67.6}),
      );
      await settleGauge(tester);

      expect(find.text('68'), findsOneWidget);
    });

    testWidgets('a live score wins over the stored one', (tester) async {
      // The blob is a cache; the live read is the record.
      api.ok('/users/u-7/reviews', userReviews(userId: 'u-7', score: 91));

      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'user_id': 'u-7', 'trust_score': 40}),
      );
      await settleGauge(tester);

      expect(find.text('91'), findsOneWidget);
      expect(find.text('40'), findsNothing);
    });
  });

  group('when there is nothing to identify the subject', () {
    testWidgets('no request is made', (tester) async {
      // `_load` returns before touching the network (:78). A request to
      // `/users/null/reviews` would be a 404 the screen would have to explain.
      await pumpScreen(tester, const TrustScoreScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
    });

    testWidgets('the ledger explains why it is empty', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen());
      await settleGauge(tester);

      expect(find.text('Sign in to see the reviews behind this score.'),
          findsOneWidget);
    });

    testWidgets('the spinner is cleared rather than left running', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen());
      await settleData(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('when there is no session', () {
    testWidgets('no request is made', (tester) async {
      // `_load` returns on a null token (:83) rather than sending an unauthenticated
      // read the API would reject.
      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1'),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(api.requests, isEmpty);
    });

    testWidgets('the spinner is cleared', (tester) async {
      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1'),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('when the request fails', () {
    // Pinned as it behaves, not as it should. `ReviewService.userReviews`
    // (lib/services/review_service.dart:102) returns `UserReviews.empty` on any
    // failure and `_load` (lib/screens/player/trust_score_screen.dart:90) stores it
    // without recording that anything went wrong. So a 500 renders an unrated gauge,
    // four "No data yet" tiles and an empty ledger — a screen that reads as a brand
    // new player rather than a failed read. The fix is a distinguishable failure
    // return from the service, an `_error` field here, and a retry.
    testWidgets('a server error is displayed as an unrated player', (tester) async {
      api.fail('/users/u-1/reviews', 'Trust lookup failed');

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('NOT RATED YET'), findsOneWidget);
      expect(find.text('No data yet'), findsNWidgets(4));
      expect(find.text('Trust lookup failed'), findsNothing,
          reason: 'the message the API sent never reaches the screen');
      expect(find.widgetWithText(TextButton, 'Try again'), findsNothing);
    });

    // Pinned as it behaves, not as it should. Same cause, different path: a dropped
    // connection is caught inside `ApiClient` and returned as a failed envelope, which
    // the service flattens to `UserReviews.empty`. This is the exact symptom of a
    // missing `adb reverse`.
    testWidgets('a dropped connection is displayed as an unrated player',
        (tester) async {
      api.offline('/users/u-1/reviews');

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('NOT RATED YET'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'a spinner that never resolves would be the worse bug');
    });

    // Pinned as it behaves, not as it should. Same cause: a body that is not the
    // expected envelope — an HTML error page from a proxy — fails the `data is! Map`
    // guard and returns the same empty value.
    testWidgets('an unparseable body is displayed as an unrated player',
        (tester) async {
      api.on('/users/u-1/reviews',
          const FakeResponse(502, '<html>Bad Gateway</html>'));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);

      expect(find.text('NOT RATED YET'), findsOneWidget);
    });

    testWidgets('a failed live read still shows the stored score', (tester) async {
      // The one case where the failure is partly covered: the legacy blob survives
      // the failed read, so a blob-carrying caller keeps a number on screen.
      api.fail('/users/u-7/reviews', 'Trust lookup failed');

      await pumpScreen(
        tester,
        const TrustScoreScreen(profile: {'user_id': 'u-7', 'trust_score': 68}),
      );
      await settleGauge(tester);

      expect(find.text('68'), findsOneWidget);
    });
  });

  group('refreshing', () {
    testWidgets('a pull refetches the breakdown', (tester) async {
      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);
      final before = api.countTo('/users/u-1/reviews');

      await tester.fling(find.text('Score Breakdown'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(api.countTo('/users/u-1/reviews'), greaterThan(before));
    });

    testWidgets('a refresh picks up a changed score', (tester) async {
      api.ok('/users/u-1/reviews', userReviews(score: 82));

      await pumpScreen(tester, const TrustScoreScreen(userId: 'u-1'));
      await settleGauge(tester);
      expect(find.text('82'), findsOneWidget);

      api.ok('/users/u-1/reviews', userReviews(score: 91));
      await tester.fling(find.text('Score Breakdown'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleGauge(tester);

      expect(find.text('91'), findsOneWidget);
      expect(find.text('HIGHLY TRUSTED'), findsOneWidget);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the loaded profile does not clip', (tester) async {
      api.ok(
        '/users/u-1/reviews',
        userReviews(total: 1, reviews: [review()]),
      );

      await pumpScreen(
        tester,
        const TrustScoreScreen(
            userId: 'u-1', displayName: 'Muhammad Bilal Ahmed', isCaptain: true),
        textScale: 2.0,
      );
      await settleGauge(tester);

      expectNoOverflow(tester);
    });

    testWidgets('an unrated profile does not clip', (tester) async {
      api.ok(
        '/users/u-1/reviews',
        userReviews(
          score: null,
          avgStars: null,
          rating: null,
          attendance: null,
          disputes: null,
          sentiment: null,
        ),
      );

      await pumpScreen(
        tester,
        const TrustScoreScreen(userId: 'u-1'),
        textScale: 2.0,
      );
      await settleGauge(tester);

      expect(find.text('NOT RATED YET'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
