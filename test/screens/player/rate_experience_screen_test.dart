// Rate Experience (M24): the one screen among these that fetches nothing on mount.
// It is a form — a venue rating, an optional opponent rating for a captain, and one
// shared comment — and the network is touched only on submit, where each rating is a
// separate `POST /reviews` through `ReviewService`. The payoff is the sentiment
// verdict: the primary review carries the comment, the server scores it, and the
// response's `data.sentiment` animates in as a chip reading "Positive (92%)".
//
// Two consequences shape the tests below. First, there is no loading state to assert
// — the form is present on the first pump. Second, `pumpAndSettle` is safe here: the
// confirmation's entrance is a finite 600ms tween and nothing animates forever, which
// is the exception to the rule the networked screen tests follow. The one care needed
// is the success SnackBar, whose dismiss timer is drained with an explicit pump so it
// does not outlive the test.
//
// Mount note: submit reads `AuthProvider.token`; `FakeAuth` supplies it. The fake
// keys on the path `/reviews` and ignores the JSON body, so one stub answers the POST
// regardless of which rating produced it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/rate_experience_screen.dart';

import '../screen_harness.dart';

/// The write endpoint, `ApiConstants.reviews`, under the path-keyed fake.
const String kReviews = '/reviews';

/// A `POST /reviews` response body carrying a scored sentiment verdict. The screen
/// reads `data.sentiment`; `source == 'model'` with a non-null label is what makes
/// [SentimentChip] render the polarity and confidence rather than a pending pill.
Map<String, dynamic> scored({String label = 'positive', double score = 0.92}) =>
    {
      'sentiment': {
        'label': label,
        'score': score,
        'source': 'model',
        'flagged': false,
      },
    };

Future<RouteLog> pumpRate(
  WidgetTester tester,
  FakeApi api, {
  bool canReviewVenue = true,
  bool canReviewOpponent = false,
  String? venueName = 'Green Turf Arena',
  String? opponentTeamName,
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    RateExperienceScreen(
      bookingId: 'bk-1',
      venueName: venueName,
      opponentTeamName: opponentTeamName,
      canReviewVenue: canReviewVenue,
      canReviewOpponent: canReviewOpponent,
      dateLabel: '2026-09-20',
    ),
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
    api.ok(kReviews, scored());
  });

  group('the form as it renders', () {
    testWidgets('a venue-only entry shows the venue rating and a submit', (
      tester,
    ) async {
      await pumpRate(tester, api);
      await tester.pumpAndSettle();

      expect(find.text('Rate Experience'), findsOneWidget); // app-bar
      expect(find.text('Green Turf Arena'), findsOneWidget); // header
      expect(find.text('Rate the Venue'), findsOneWidget);
      expect(find.text('Submit Feedback'), findsOneWidget);
      // The opponent section is absent unless the entry point enables it.
      expect(find.text('Opponent Sportsmanship'), findsNothing);
    });

    testWidgets('a captain entry shows the opponent section and its badge', (
      tester,
    ) async {
      await pumpRate(
        tester,
        api,
        canReviewVenue: false,
        canReviewOpponent: true,
        venueName: null,
        opponentTeamName: 'Falcons FC',
      );
      await tester.pumpAndSettle();

      expect(find.text('Opponent Sportsmanship'), findsOneWidget);
      expect(find.text('Captain only'), findsOneWidget);
      // With the venue not offered, its section does not render.
      expect(find.text('Rate the Venue'), findsNothing);
    });
  });

  group('rating gates the submit', () {
    testWidgets('submit is withheld until a star is tapped', (tester) async {
      await pumpRate(tester, api);
      await tester.pumpAndSettle();

      // Before any star, the screen states why submit is inert.
      expect(
        find.text('Tap the stars to rate before submitting.'),
        findsOneWidget,
      );

      await tester.tap(find.bySemanticsLabel('Rate 5 stars'));
      await tester.pump();

      // The hint clears once a rating exists, and the word reflects the score.
      expect(
        find.text('Tap the stars to rate before submitting.'),
        findsNothing,
      );
      expect(find.text('Excellent'), findsOneWidget);
    });
  });

  group('submitting', () {
    testWidgets('a rated venue posts and the sentiment verdict animates in', (
      tester,
    ) async {
      await pumpRate(tester, api);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Rate 5 stars'));
      await tester.pump();
      await tester.tap(find.text('Submit Feedback'));
      await tester.pump(); // submit starts, the button enters its loading state
      await tester.pump(const Duration(milliseconds: 50)); // the POST resolves
      await tester.pump(
        const Duration(milliseconds: 700),
      ); // the confirmation tween

      expect(api.countTo(kReviews), 1);
      expect(find.text('Feedback submitted'), findsOneWidget);
      expect(find.text('Positive (92%)'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Done'), findsOneWidget);

      // Drain the success SnackBar's dismiss timer so it does not outlive the test.
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the venue section present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpRate(tester, api, textScale: 2.0);
      await tester.pumpAndSettle();

      expect(find.text('Rate the Venue'), findsOneWidget);
    });
  });
}
