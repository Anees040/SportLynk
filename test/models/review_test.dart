// Reviews and Trust 2.0 model tests.
//
// Two rules carry the weight here. First, these endpoints answer in camelCase
// while the older reads are snake_case, so a key read under the wrong convention
// silently blanks a populated screen. Second, and the reason most of the null
// assertions below exist: **a null trust component means "no signal yet", never
// zero.** A user with no disputes on record must not render an empty bar that
// reads as "0% dispute-free".

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/review.dart';

Review review(Map<String, dynamic> j) =>
    Review.fromJson({'id': 'r1', 'stars': 5, ...j});

Review aged(Duration since) => review({
      'createdAt': DateTime.now().subtract(since).toIso8601String(),
    });

void main() {
  group('ReviewSentiment', () {
    test('scoredByModel needs both the model source and a label', () {
      expect(
        ReviewSentiment.fromJson({'source': 'model', 'label': 'positive'}).scoredByModel,
        isTrue,
      );
      expect(ReviewSentiment.fromJson({'source': 'model'}).scoredByModel, isFalse);
      expect(
        ReviewSentiment.fromJson({'source': 'unavailable', 'label': 'positive'}).scoredByModel,
        isFalse,
      );
      expect(ReviewSentiment.empty.scoredByModel, isFalse);
    });

    test('pending marks the "sentiment added shortly" state', () {
      expect(ReviewSentiment.fromJson({'source': 'unavailable'}).pending, isTrue);
      expect(ReviewSentiment.fromJson({'source': 'model'}).pending, isFalse);
      expect(ReviewSentiment.empty.pending, isFalse,
          reason: 'no text to score is not the same as the server being down');
    });

    test('percent reports magnitude, so a negative score is not shown negative', () {
      expect(ReviewSentiment.fromJson({'score': 0.92}).percent, 92);
      expect(ReviewSentiment.fromJson({'score': -0.87}).percent, 87);
      expect(ReviewSentiment.fromJson({'score': '0.5'}).percent, 50);
      expect(ReviewSentiment.fromJson({'score': 0}).percent, 0);
    });

    test('percent is null when nothing was scored, not zero', () {
      expect(ReviewSentiment.fromJson({}).percent, isNull);
      expect(ReviewSentiment.fromJson({'score': null}).percent, isNull);
      expect(ReviewSentiment.fromJson({'score': 'n/a'}).percent, isNull);
    });

    test('percent is clamped to the display range', () {
      expect(ReviewSentiment.fromJson({'score': 1.4}).percent, 100);
      expect(ReviewSentiment.fromJson({'score': -2}).percent, 100);
    });

    test('flagged requires a literal true', () {
      expect(ReviewSentiment.fromJson({'flagged': true}).flagged, isTrue);
      expect(ReviewSentiment.fromJson({'flagged': 'true'}).flagged, isFalse);
      expect(ReviewSentiment.fromJson({}).flagged, isFalse);
    });

    test('an empty label or source string reads as absent', () {
      final s = ReviewSentiment.fromJson({'label': '', 'source': ''});
      expect(s.label, isNull);
      expect(s.source, isNull);
    });
  });

  group('Review', () {
    test('stars parse from a pg string and text empties to null', () {
      final r = review({'stars': '4', 'text': '', 'reviewerName': ''});
      expect(r.stars, 4);
      expect(r.text, isNull);
      expect(r.reviewerName, isNull);
    });

    test('isOpponent distinguishes the two feeds', () {
      expect(review({'reviewType': 'opponent'}).isOpponent, isTrue);
      expect(review({'reviewType': 'venue'}).isOpponent, isFalse);
      expect(review({}).isOpponent, isFalse,
          reason: 'a venue feed omits reviewType entirely');
    });

    test('relativeTime steps through every unit it supports', () {
      expect(aged(const Duration(seconds: 30)).relativeTime, 'just now');
      expect(aged(const Duration(minutes: 5)).relativeTime, '5m ago');
      expect(aged(const Duration(hours: 3)).relativeTime, '3h ago');
      expect(aged(const Duration(days: 2)).relativeTime, '2d ago');
      expect(aged(const Duration(days: 10)).relativeTime, '1w ago');
      expect(aged(const Duration(days: 60)).relativeTime, '2mo ago');
      expect(aged(const Duration(days: 400)).relativeTime, '1y ago');
    });

    test('relativeTime is empty rather than wrong when there is no date', () {
      expect(review({}).relativeTime, '');
    });
  });

  group('SentimentDistribution', () {
    test('total excludes unscored reviews by construction', () {
      final d = SentimentDistribution.fromJson({'positive': 6, 'neutral': 2, 'negative': 2});
      expect(d.total, 10);
      expect(d.isEmpty, isFalse);
    });

    test('counts parse from pg strings', () {
      final d = SentimentDistribution.fromJson({'positive': '6', 'neutral': '2', 'negative': '2'});
      expect(d.total, 10);
    });

    test('fractions divide by the total and sum to one', () {
      final d = SentimentDistribution.fromJson({'positive': 6, 'neutral': 2, 'negative': 2});
      expect(d.positiveFraction, closeTo(0.6, 0.0001));
      expect(d.neutralFraction, closeTo(0.2, 0.0001));
      expect(d.negativeFraction, closeTo(0.2, 0.0001));
      expect(d.positiveFraction + d.neutralFraction + d.negativeFraction,
          closeTo(1.0, 0.0001));
    });

    test('an empty distribution yields zero fractions, not NaN', () {
      const d = SentimentDistribution.empty;
      expect(d.isEmpty, isTrue);
      expect(d.total, 0);
      expect(d.positiveFraction, 0);
      expect(d.neutralFraction, 0);
      expect(d.negativeFraction, 0);
    });
  });

  group('VenueReviews', () {
    test('paging fields fall back to the first page of twenty', () {
      final v = VenueReviews.fromJson({'venueId': 'v1'});
      expect(v.page, 1);
      expect(v.limit, 20);
      expect(v.total, 0);
    });

    test('avgStars stays null for a venue with no reviews', () {
      expect(VenueReviews.fromJson({'venueId': 'v1'}).avgStars, isNull);
      expect(VenueReviews.fromJson({'venueId': 'v1', 'avgStars': '4.25'}).avgStars, 4.25);
    });

    test('starCounts reads the map high to low', () {
      final v = VenueReviews.fromJson({
        'venueId': 'v1',
        'starCounts': {'5': 10, '4': 4, '3': 2, '2': 1, '1': '3'},
      });
      expect(v.starCounts, [10, 4, 2, 1, 3]);
    });

    test('an absent starCounts map degrades to five zeros', () {
      expect(VenueReviews.fromJson({'venueId': 'v1'}).starCounts, [0, 0, 0, 0, 0]);
      expect(
        VenueReviews.fromJson({'venueId': 'v1', 'starCounts': 'none'}).starCounts,
        [0, 0, 0, 0, 0],
      );
    });

    test('maxStarCount never returns zero, so the histogram cannot divide by it', () {
      expect(VenueReviews.empty.maxStarCount, 1);
      final v = VenueReviews.fromJson({
        'venueId': 'v1',
        'starCounts': {'5': 10, '4': 4},
      });
      expect(v.maxStarCount, 10);
    });

    test('hasMore compares the page window against the venue-wide total', () {
      VenueReviews page(int p, int total) =>
          VenueReviews.fromJson({'venueId': 'v1', 'page': p, 'limit': 20, 'total': total});
      expect(page(1, 45).hasMore, isTrue);
      expect(page(2, 45).hasMore, isTrue);
      expect(page(3, 45).hasMore, isFalse);
      expect(page(1, 20).hasMore, isFalse);
      expect(page(1, 0).hasMore, isFalse);
    });

    test('the sentiment block falls back to empty rather than null', () {
      expect(VenueReviews.fromJson({'venueId': 'v1'}).sentiment.isEmpty, isTrue);
      expect(VenueReviews.fromJson({'venueId': 'v1', 'sentimentDistribution': 'x'})
          .sentiment.isEmpty, isTrue);
    });

    test('rows are parsed and non-map entries skipped', () {
      final v = VenueReviews.fromJson({
        'venueId': 'v1',
        'reviews': [
          {'id': 'r1', 'stars': 5},
          'garbage',
          {'id': 'r2', 'stars': '3'},
        ],
      });
      expect(v.reviews.length, 2);
      expect(v.reviews.last.stars, 3);
    });

    test('the empty constant is a usable zero state', () {
      expect(VenueReviews.empty.total, 0);
      expect(VenueReviews.empty.avgStars, isNull);
      expect(VenueReviews.empty.reviews, isEmpty);
      expect(VenueReviews.empty.hasMore, isFalse);
    });
  });

  group('TrustBreakdown', () {
    test('an absent component is null, never zero', () {
      const t = TrustBreakdown.empty;
      expect(t.score, isNull);
      expect(t.rating, isNull);
      expect(t.attendance, isNull);
      expect(t.disputes, isNull);
      expect(t.sentiment, isNull);
    });

    test('a profile with no player_profiles row has a null score', () {
      expect(TrustBreakdown.fromJson({}).score, isNull);
      expect(TrustBreakdown.fromJson({'score': null}).score, isNull);
      expect(TrustBreakdown.fromJson({'score': 0}).score, 0,
          reason: 'an explicit zero is a real score and must survive');
    });

    test('components parse from pg decimal strings', () {
      final t = TrustBreakdown.fromJson({
        'score': '72',
        'rating': '0.85',
        'attendance': '0.9',
        'disputes': '1.0',
        'sentiment': '0.62',
      });
      expect(t.score, 72);
      expect(t.rating, 0.85);
      expect(t.attendance, 0.9);
      expect(t.disputes, 1.0);
      expect(t.sentiment, 0.62);
    });

    test('a component present as zero is distinguishable from absent', () {
      final t = TrustBreakdown.fromJson({'disputes': '0.00'});
      expect(t.disputes, 0.0);
      expect(t.disputes, isNotNull);
      expect(t.attendance, isNull);
    });

    test('the published display weights sum to 100', () {
      expect(
        TrustBreakdown.wRating +
            TrustBreakdown.wAttendance +
            TrustBreakdown.wDisputes +
            TrustBreakdown.wSentiment,
        100,
      );
    });
  });

  group('UserReviews', () {
    test('paging falls back to the first page of twenty', () {
      final u = UserReviews.fromJson({'userId': 'u1'});
      expect(u.page, 1);
      expect(u.limit, 20);
      expect(u.total, 0);
      expect(u.hasMore, isFalse);
    });

    test('the trust block falls back to empty rather than null', () {
      expect(UserReviews.fromJson({'userId': 'u1'}).trust.score, isNull);
      expect(UserReviews.fromJson({'userId': 'u1', 'trust': 'none'}).trust.score, isNull);
      expect(
        UserReviews.fromJson({'userId': 'u1', 'trust': {'score': '72'}}).trust.score,
        72,
      );
    });

    test('hasMore drives the infinite list', () {
      expect(
        UserReviews.fromJson({'userId': 'u1', 'page': 1, 'limit': 20, 'total': 25}).hasMore,
        isTrue,
      );
      expect(
        UserReviews.fromJson({'userId': 'u1', 'page': 2, 'limit': 20, 'total': 25}).hasMore,
        isFalse,
      );
    });
  });

  group('FlaggedReview', () {
    FlaggedReview flagged(Map<String, dynamic> j) =>
        FlaggedReview.fromJson({'id': 'r1', 'stars': 2, ...j});

    test('a manual report is recognised from either the list or the count', () {
      expect(flagged({'flags': [{'reason': 'abuse'}]}).hasManualReports, isTrue);
      expect(flagged({'openFlagCount': 2}).hasManualReports, isTrue);
      expect(flagged({'openFlagCount': '2'}).hasManualReports, isTrue);
      expect(flagged({}).hasManualReports, isFalse);
    });

    test('isAutoFlagged means the model raised it and no human did', () {
      expect(flagged({'flagged': true}).isAutoFlagged, isTrue);
      expect(flagged({'flagged': true, 'openFlagCount': 1}).isAutoFlagged, isFalse);
      expect(flagged({'flagged': true, 'hidden': true}).isAutoFlagged, isFalse,
          reason: 'an already-hidden review is resolved, not queued');
      expect(flagged({'flagged': false}).isAutoFlagged, isFalse);
    });

    test('subjectLabel names the player for a conduct review and the venue otherwise', () {
      expect(
        flagged({'reviewType': 'opponent', 'reviewedUserName': 'Ali Raza'}).subjectLabel,
        'Ali Raza',
      );
      expect(
        flagged({'reviewType': 'venue', 'venueName': 'Astro Turf'}).subjectLabel,
        'Astro Turf',
      );
    });

    test('subjectLabel falls back to a generic noun rather than an empty line', () {
      expect(flagged({'reviewType': 'opponent'}).subjectLabel, 'a player');
      expect(flagged({'reviewType': 'venue'}).subjectLabel, 'a venue');
      expect(flagged({}).subjectLabel, 'a venue');
      expect(flagged({'reviewType': 'opponent', 'reviewedUserName': ''}).subjectLabel,
          'a player');
    });

    test('the flag list is parsed and non-map entries skipped', () {
      final f = flagged({
        'flags': [
          {'reason': 'abuse', 'flaggedByName': 'Ali'},
          'garbage',
        ]
      });
      expect(f.flags.length, 1);
      expect(f.flags.first.reason, 'abuse');
      expect(f.flags.first.flaggedByName, 'Ali');
    });
  });
}
