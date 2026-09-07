// PricingService, the forecast and the Apply mutation. Split from
// `pricing_service_test.dart` to keep both files inside the size rule; the
// suggestion read and its honesty rules live there.
//
// The forecast has one rule above all others: it draws nothing rather than
// something wrong. A point with no probability, no hour or no timestamp is dropped
// instead of rendered, because a zero-height bar at an unknown hour reads as "no
// demand" — a claim the model never made. For the same reason `available == false`
// is a first-class answer carrying the server's own sentence, and it is not the same
// thing as a `null` return: one is a permanent condition, the other invites a retry,
// and only one of them deserves a retry button.
//
// The bucketing thresholds travel with the bars. They are anchored on the training
// set's measured unconditional booking rate rather than on taste, and sending them
// alongside the points is what stops the legend and the chart from disagreeing after
// a retrain moves them.
//
// `applyPrice` returns the envelope raw. The owner's Apply is an explicit act on a
// set of slots, and the server answers per slot: updated, or skipped as `booked`,
// `locked`, `past`, `unchanged` or `not_found`. A boolean would throw away the only
// part of that answer worth reading aloud.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/pricing_service.dart';

import 'http_seam.dart';

/// One hour of the forecast, as the route sends it.
Map<String, dynamic> _point(int hour, double p,
        {String date = '2026-03-14', String? level}) =>
    {
      'ts': '${date}T${hour.toString().padLeft(2, '0')}:00:00+05:00',
      'slotDate': date,
      'hour': hour,
      'bookProbability': p,
      if (level != null) 'level': level,
    };

void main() {
  late FakeApi api;
  late PricingService service;

  setUp(() {
    api = FakeApi();
    service = PricingService();
  });

  tearDown(resetApiClient);

  group('asking for the forecast', () {
    test('the window is 72 hours unless another is named', () async {
      api.ok(const {'available': true});
      await api.run(() => service.forecast('JWT', 'v1'));
      expect(api.endpoint().split('?').first, '/owner/venues/v1/forecast');
      expect(api.query(), {'hours': '72'});
      expect(api.method(), 'GET');
      expect(api.token(), 'JWT');
    });

    test('a shorter window is sent as asked', () async {
      api.ok(const {'available': true});
      await api.run(() => service.forecast('JWT', 'v1', hours: 24));
      expect(api.query(), {'hours': '24'});
    });
  });

  group('a forecast that arrived', () {
    test('the points, the thresholds and the provenance are all read', () async {
      api.ok({
        'source': 'model',
        'available': true,
        'modelVersion': 'pricing-v1',
        'cached': true,
        'levels': {'high': 0.5, 'low': 0.2, 'baseRate': 0.31},
        'modelMetrics': {'rocAuc': 0.7628, 'rocAucCeiling': 0.777},
        'points': [
          _point(18, 0.41, level: 'medium'),
          _point(19, 0.62, level: 'high'),
          _point(20, 0.55, level: 'high'),
        ],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.source, 'model');
      expect(f.available, isTrue);
      expect(f.isEmpty, isFalse);
      expect(f.points.length, 3);
      expect(f.points.first.hourLabel, '18:00');
      expect(f.points.first.ts, '2026-03-14T18:00:00+05:00');
      expect(f.levels.high, 0.5);
      expect(f.levels.low, 0.2);
      expect(f.levels.baseRate, 0.31);
      expect(f.modelVersion, 'pricing-v1');
      expect(f.modelMetrics!.attainmentPct!.round(), 98);
      expect(f.cached, isTrue);
    });

    test('the peak hour is the highest, not the last', () async {
      api.ok({
        'available': true,
        'points': [_point(18, 0.41), _point(19, 0.62), _point(20, 0.55)],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.peak!.hour, 19);
      expect(f.maxProbability, 0.62);
    });

    test('the high hours are counted from the level the server assigned', () async {
      api.ok({
        'available': true,
        'points': [
          _point(18, 0.41, level: 'medium'),
          _point(19, 0.62, level: 'high'),
          _point(20, 0.55, level: 'high'),
          _point(21, 0.10, level: 'low'),
        ],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.highCount, 2);
    });

    // The chart labels day boundaries rather than all 72 hours, so it needs the days
    // in the order they were sent and each one once.
    test('the days are distinct and stay in wire order', () async {
      api.ok({
        'available': true,
        'points': [
          _point(22, 0.3, date: '2026-03-14'),
          _point(23, 0.3, date: '2026-03-14'),
          _point(0, 0.2, date: '2026-03-15'),
          _point(1, 0.2, date: '2026-03-15'),
          _point(0, 0.2, date: '2026-03-16'),
        ],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.days, ['2026-03-14', '2026-03-15', '2026-03-16']);
      expect(f.points.first.hourLabel, '22:00');
      expect(f.points[2].hourLabel, '00:00');
    });

    test('thresholds absent from the payload fall back to the trained anchors', () async {
      api.ok({'available': true, 'points': [_point(19, 0.62)]});
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.levels.high, 0.448);
      expect(f.levels.low, 0.154);
      expect(f.levels.baseRate, 0.28);
    });
  });

  // A bar the model cannot stand behind is worse than a gap in the chart, so the
  // parser drops a point rather than defaulting any part of it.
  group('a point that cannot be drawn honestly', () {
    test('no probability, no hour, no timestamp: each one is dropped', () async {
      api.ok({
        'available': true,
        'points': [
          {'ts': '2026-03-14T18:00:00+05:00', 'slotDate': '2026-03-14', 'hour': 18},
          {'ts': '2026-03-14T19:00:00+05:00', 'slotDate': '2026-03-14', 'bookProbability': 0.62},
          {'slotDate': '2026-03-14', 'hour': 20, 'bookProbability': 0.55},
          {'ts': '', 'slotDate': '2026-03-14', 'hour': 21, 'bookProbability': 0.3},
          _point(22, 0.44, level: 'medium'),
        ],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.points.map((p) => p.hour), [22]);
    });

    test('an entry that is not an object is dropped with the rest', () async {
      api.ok({
        'available': true,
        'points': ['19:00', 42, _point(19, 0.62)],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.points.single.hour, 19);
    });

    test('a probability sent as a string is still drawable', () async {
      api.ok({
        'available': true,
        'points': [
          {
            'ts': '2026-03-14T19:00:00+05:00',
            'slotDate': '2026-03-14',
            'hour': '19',
            'bookProbability': '0.62',
          },
        ],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.points.single.hour, 19);
      expect(f.points.single.bookProbability, 0.62);
    });

    test('a point with no day named still draws, with no day label', () async {
      api.ok({
        'available': true,
        'points': [
          {'ts': '2026-03-14T19:00:00+05:00', 'hour': 19, 'bookProbability': 0.62},
        ],
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.points.single.slotDate, isEmpty);
      expect(f.days, isEmpty);
    });
  });

  // `available == false` and a `null` return are different sentences on screen:
  // "forecast unavailable" is a condition to state, "could not reach the server" is
  // an invitation to retry. Only the second one gets a retry button.
  group('a forecast with no answer in it', () {
    test('an unavailable forecast is an answer, and it says why', () async {
      api.ok(const {
        'source': 'unavailable',
        'available': false,
        'reason': 'The demand model is not loaded on this server.',
      });
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f, isNotNull);
      expect(f!.available, isFalse);
      expect(f.isEmpty, isTrue);
      expect(f.reason, 'The demand model is not loaded on this server.');
      expect(f.peak, isNull);
      expect(f.maxProbability, 0);
      expect(f.highCount, 0);
    });

    test('a missing available flag is read as unavailable', () async {
      api.ok(const {'source': 'model'});
      final f = await api.run(() => service.forecast('JWT', 'v1'));
      expect(f!.available, isFalse);
      expect(f.source, 'model');
    });

    test('a refused read is null so the screen can offer a retry', () async {
      api.fail('That venue is not yours.', status: 404);
      expect(await api.run(() => service.forecast('JWT', 'someone-elses')), isNull);
    });

    test('a transport failure is null rather than a throw', () async {
      api.offline();
      expect(await api.run(() => service.forecast('JWT', 'v1')), isNull);
    });

    test('a success envelope with no forecast in it is null', () async {
      api.ok(const []);
      expect(await api.run(() => service.forecast('JWT', 'v1')), isNull);
    });

    // Pinned as it behaves, not as it should: the `points` block is hard-cast to
    // `List?` while the entries inside are guarded, so a non-list there escapes as a
    // `TypeError` past the never-throw contract. The same one-line omission as
    // `topFactors` in the suggestion and `tournaments` in `TournamentService.browse`.
    test('a wrong-typed points block escapes as a TypeError', () async {
      api.ok(const {'available': true, 'points': 'not a list'});
      await expectLater(
        api.run(() => service.forecast('JWT', 'v1')),
        throwsA(isA<TypeError>()),
      );
    });
  });

  // Apply is the owner's explicit act. Nothing above it in this file changes what a
  // player pays; this is the only method here that writes.
  group('applying a price', () {
    test('the slots and the price go out together on a PATCH', () async {
      api.ok(const {'updated': 8});
      await api.run(() => service.applyPrice('JWT', 'v1',
          slotIds: const ['s1', 's2'], price: 2800));
      expect(api.endpoint(), '/owner/venues/v1/slots/price');
      expect(api.method(), 'PATCH');
      expect(api.body(), {
        'slotIds': ['s1', 's2'],
        'price': 2800,
      });
      expect(api.token(), 'JWT');
    });

    test('a fractional price is sent as sent, not rounded on the client', () async {
      api.ok(const {'updated': 1});
      await api.run(() => service.applyPrice('JWT', 'v1',
          slotIds: const ['s1'], price: 2799.5));
      expect(api.body()['price'], 2799.5);
    });

    // An empty selection is refused by the server, which owns that rule. Sending it
    // is what surfaces the server's sentence instead of inventing a second one here.
    test('an empty selection is still sent so the server can refuse it', () async {
      api.fail('Select at least one slot.', status: 400);
      final r = await api.run(
          () => service.applyPrice('JWT', 'v1', slotIds: const [], price: 2800));
      expect(api.body()['slotIds'], isEmpty);
      expect(r['message'], 'Select at least one slot.');
    });

    // The partial answer is the whole reason this method returns the envelope raw:
    // "applied to 6 of 8 — 2 are already booked" cannot be reconstructed from a
    // boolean, and each skip reason is a different thing to tell the owner.
    test('a partial apply keeps every per-slot reason', () async {
      api.ok(const {
        'updated': 6,
        'requested': 8,
        'skipped': [
          {'slotId': 's7', 'reason': 'booked'},
          {'slotId': 's8', 'reason': 'locked'},
        ],
      }, extra: const {'message': 'Applied to 6 of 8 slots.'});
      final r = await api.run(() => service.applyPrice('JWT', 'v1',
          slotIds: const ['s1', 's2', 's3', 's4', 's5', 's6', 's7', 's8'],
          price: 2800));
      expect(r['success'], isTrue);
      expect(r['message'], 'Applied to 6 of 8 slots.');
      final data = Map<String, dynamic>.from(r['data'] as Map);
      expect(data['updated'], 6);
      expect(data['requested'], 8);
      expect((data['skipped'] as List).length, 2);
    });

    test('a refusal is forwarded with its status code intact', () async {
      api.fail('That venue is not yours.', status: 403);
      final r = await api.run(() => service.applyPrice('JWT', 'someone-elses',
          slotIds: const ['s1'], price: 2800));
      expect(r['success'], isFalse);
      expect(r['message'], 'That venue is not yours.');
      expect(r['statusCode'], 403);
    });

    test('a transport failure is a readable envelope, not a throw', () async {
      api.offline('Connection refused');
      final r = await api.run(() => service.applyPrice('JWT', 'v1',
          slotIds: const ['s1'], price: 2800));
      expect(r['success'], isFalse);
      expect(r['statusCode'], 0);
      expect(r['message'], 'Could not reach the server. Make sure it is running.');
    });
  });
}
