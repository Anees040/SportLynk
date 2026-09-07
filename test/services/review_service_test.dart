// ReviewService: the split between mutations that return the envelope and reads that
// return a typed model.
//
// The write half exists so a screen can drive a snackbar from the backend's own
// sentence — a 409 for an already-reviewed booking and a 400 for the wrong booking
// state are both ordinary outcomes, not errors to swallow. The read half returns a
// model or its `.empty` sentinel and never throws, so a profile screen can bind
// directly to the result.
//
// The blank-text rule is load-bearing: a stars-only review is valid and must arrive
// with no `text` key at all, because the server treats a present-but-empty string as
// a review body and would run sentiment over nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/review_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late ReviewService service;

  setUp(() {
    api = FakeApi();
    service = ReviewService();
  });

  tearDown(resetApiClient);

  group('submitReview', () {
    test('sends the booking, the type and the stars', () async {
      api.ok(null, status: 201);
      await api.run(() => service.submitReview(
            'JWT',
            bookingId: 'b1',
            reviewType: 'venue',
            stars: 4,
          ));
      expect(api.endpoint(), '/reviews');
      expect(api.method(), 'POST');
      expect(api.token(), 'JWT');
      expect(api.body(), {'bookingId': 'b1', 'reviewType': 'venue', 'stars': 4});
    });

    test('never sends a target id for an opponent review', () async {
      api.ok(null, status: 201);
      await api.run(() => service.submitReview(
            'JWT',
            bookingId: 'b1',
            reviewType: 'opponent',
            stars: 5,
          ));
      expect(api.body().keys, ['bookingId', 'reviewType', 'stars']);
    });

    test('a stars-only review omits the text key entirely', () async {
      api.ok(null, status: 201);
      await api.run(() => service.submitReview(
            'JWT',
            bookingId: 'b1',
            reviewType: 'venue',
            stars: 3,
            text: '   ',
          ));
      expect(api.body().containsKey('text'), isFalse);
    });

    test('text is trimmed before it is sent for sentiment', () async {
      api.ok(null, status: 201);
      await api.run(() => service.submitReview(
            'JWT',
            bookingId: 'b1',
            reviewType: 'venue',
            stars: 5,
            text: '  Great turf  ',
          ));
      expect(api.body()['text'], 'Great turf');
    });

    test('the live sentiment verdict is left in the envelope for the chip', () async {
      api.ok({
        'sentiment': {'label': 'positive', 'score': '0.91'},
      }, status: 201);
      final r = await api.run(() => service.submitReview(
            'JWT',
            bookingId: 'b1',
            reviewType: 'venue',
            stars: 5,
            text: 'Great turf',
          ));
      expect(((r['data'] as Map)['sentiment'] as Map)['label'], 'positive');
    });

    test('a duplicate review comes back as a message, not a throw', () async {
      api.fail('You have already reviewed this booking.', status: 409);
      final r = await api.run(() => service.submitReview(
            'JWT',
            bookingId: 'b1',
            reviewType: 'venue',
            stars: 4,
          ));
      expect(r['success'], isFalse);
      expect(r['message'], 'You have already reviewed this booking.');
    });
  });

  group('flagReview and moderate', () {
    test('a report with no reason sends an empty body', () async {
      api.ok(null);
      await api.run(() => service.flagReview('JWT', 'r1'));
      expect(api.endpoint(), '/reviews/r1/flag');
      expect(api.method(), 'POST');
      expect(api.body(), isEmpty);
    });

    test('a whitespace-only reason is dropped', () async {
      api.ok(null);
      await api.run(() => service.flagReview('JWT', 'r1', reason: '  '));
      expect(api.body(), isEmpty);
    });

    test('a reason is trimmed and sent', () async {
      api.ok(null);
      await api.run(() => service.flagReview('JWT', 'r1', reason: '  abusive  '));
      expect(api.body(), {'reason': 'abusive'});
    });

    test('a second report by the same caller reads as a message', () async {
      api.fail('You have already reported this review.', status: 409);
      final r = await api.run(() => service.flagReview('JWT', 'r1'));
      expect(r['message'], 'You have already reported this review.');
    });

    test('moderating patches the admin route with the action', () async {
      api.ok(null);
      await api.run(() => service.moderate('JWT', 'r1', 'hide'));
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/admin/reviews/r1');
      expect(api.body(), {'action': 'hide'});
    });

    test('restore and dismiss travel the same route', () async {
      api.ok(null);
      await api.run(() async {
        await service.moderate('JWT', 'r1', 'restore');
        await service.moderate('JWT', 'r2', 'dismiss');
      });
      expect(api.body(0), {'action': 'restore'});
      expect(api.endpoint(1), '/admin/reviews/r2');
      expect(api.body(1), {'action': 'dismiss'});
    });
  });

  group('venueReviews', () {
    test('pages default to the first twenty', () async {
      api.ok({'venueId': 'v1', 'reviews': []});
      await api.run(() => service.venueReviews('JWT', 'v1'));
      expect(api.endpoint(), '/venues/v1/reviews?page=1&limit=20');
    });

    test('an explicit page and limit are sent as strings', () async {
      api.ok({'venueId': 'v1', 'reviews': []});
      await api.run(() => service.venueReviews('JWT', 'v1', page: 3, limit: 5));
      expect(api.query(), {'page': '3', 'limit': '5'});
    });

    test('the venue aggregates come back parsed', () async {
      api.ok({
        'venueId': 'v1',
        'total': '12',
        'avgStars': '4.25',
        'starCounts': {'5': '6', '4': '4', '3': '1', '2': '1', '1': '0'},
        'reviews': [
          {'id': 'r1', 'stars': '5', 'text': 'Great turf'},
        ],
      });
      final page = await api.run(() => service.venueReviews('JWT', 'v1'));
      expect(page.total, 12);
      expect(page.avgStars, 4.25);
      // The wire sends the histogram as an object keyed by star, high to low; a
      // five-element list would not say which end is 5 stars.
      expect(page.starCounts, [6, 4, 1, 1, 0]);
      expect(page.reviews.single.stars, 5);
    });

    test('a failure is the empty sentinel, not a throw', () async {
      api.fail('Something went wrong on the server.', status: 500);
      final page = await api.run(() => service.venueReviews('JWT', 'v1'));
      expect(page.total, 0);
      expect(page.reviews, isEmpty);
    });

    test('a data block of the wrong type is the empty sentinel too', () async {
      api.ok(['not', 'an', 'object']);
      final page = await api.run(() => service.venueReviews('JWT', 'v1'));
      expect(page.reviews, isEmpty);
    });
  });

  group('userReviews', () {
    test('reads the user route with the same paging', () async {
      api.ok({'userId': 'u1', 'reviews': []});
      await api.run(() => service.userReviews('JWT', 'u1'));
      expect(api.endpoint(), '/users/u1/reviews?page=1&limit=20');
    });

    test('the stored trust breakdown is parsed alongside the reviews', () async {
      api.ok({
        'userId': 'u1',
        'total': '4',
        'avgStars': '4.5',
        'trust': {'score': '82', 'rating': '0.9', 'attendance': '0.75'},
        'reviews': [
          {'id': 'r1', 'stars': '4'},
        ],
      });
      final page = await api.run(() => service.userReviews('JWT', 'u1'));
      expect(page.trust.score, 82);
      expect(page.trust.rating, 0.9);
      expect(page.trust.disputes, isNull);
      expect(page.reviews.single.id, 'r1');
    });

    test('a failure is the empty sentinel', () async {
      api.offline();
      final page = await api.run(() => service.userReviews('JWT', 'u1'));
      expect(page.userId, isEmpty);
      expect(page.reviews, isEmpty);
    });
  });

  group('moderationQueue', () {
    test('parses the queue rows', () async {
      api.ok([
        {
          'id': 'r1',
          'stars': '1',
          'text': 'terrible',
          'openFlagCount': '2',
          'hidden': false,
          'flagged': true,
        },
        {'id': 'r2', 'stars': '5'},
      ]);
      final queue = await api.run(() => service.moderationQueue('JWT'));
      expect(api.endpoint(), '/admin/reviews/flagged');
      expect(queue.map((r) => r.id), ['r1', 'r2']);
      expect(queue.first.openFlagCount, 2);
      expect(queue.first.flagged, isTrue);
    });

    test('a failure is an empty queue, which the screen reads as nothing to do', () async {
      api.fail('You do not have permission to do that.', status: 403);
      expect(await api.run(() => service.moderationQueue('JWT')), isEmpty);
    });

    test('a data block that is not a list is an empty queue', () async {
      api.ok({'rows': []});
      expect(await api.run(() => service.moderationQueue('JWT')), isEmpty);
    });

    test('a non-map row is skipped', () async {
      api.ok([
        {'id': 'r1', 'stars': '1'},
        42,
      ]);
      final queue = await api.run(() => service.moderationQueue('JWT'));
      expect(queue.single.id, 'r1');
    });
  });
}
