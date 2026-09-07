// PricingService: what the owner's pricing card is allowed to claim, and the wire
// shapes that back each claim.
//
// This feature's whole risk is dishonesty. A suggestion carries its own provenance —
// which service produced it, how sure it is, what moved it, and how the model that
// produced it scored — because a heuristic dressed as a model, or a hardcoded
// `AUC 0.84` beside an artifact that measured 0.7628, is the one thing an examiner
// asks about twice. So the assertions below pin the honesty rules rather than the
// arithmetic: `modelCaption` and the confidence bar exist only when `source` is
// `model`, a chip with no measured impact renders no impact at all, and an
// unavailable forecast draws nothing instead of a row of zeroes.
//
// Two nulls that mean different things are kept apart throughout. A `null` return
// means the request failed and a retry is worth offering; a forecast with
// `available == false` means the model genuinely had no answer and carries the
// server's own sentence. Collapsing them would put a retry button under a
// permanent condition.
//
// `applyPrice` is the one method that returns the envelope raw, because the
// interesting answer is the partial one: the server classifies every slot as
// updated or skipped (`booked`, `locked`, `past`, `unchanged`, `not_found`) and the
// screen has to be able to say "applied to 6 of 8 — 2 are already booked" rather
// than a flat success.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/pricing_service.dart';

import 'http_seam.dart';

/// A model-sourced suggestion with every optional block present, so a test can
/// override one key and assert one behaviour.
Map<String, dynamic> _modelSuggestion([Map<String, dynamic> overrides = const {}]) => {
      'source': 'model',
      'basePrice': 2500,
      'suggestedPrice': 2800,
      'deltaPct': 12.0,
      'confidence': 0.84,
      'demand': 0.62,
      'demandLevel': 'high',
      'modelVersion': 'pricing-v1',
      'clamped': false,
      'atPolicyCap': false,
      'policyMaxRatio': 1.5,
      'topFactors': [
        {'key': 'hour', 'label': 'Peak hour', 'direction': 'up', 'impact': 0.12},
        {'key': 'weather', 'label': 'Rain forecast', 'direction': 'down', 'impact': 0.04},
      ],
      'modelMetrics': {
        'rocAuc': 0.7628,
        'prAuc': 0.61,
        'brier': 0.18,
        'brierSkill': 0.11,
        'rocAucCeiling': 0.777,
        'testRows': 4800,
        'trainedAt': '2026-02-11T09:00:00Z',
        'datasetSource': 'bookings_synthetic_v1.csv',
      },
      'venueId': 'v1',
      'slotDate': '2026-03-14',
      'startTime': '19:00',
      'hour': 19,
      'cached': false,
      ...overrides,
    };

void main() {
  late FakeApi api;
  late PricingService service;

  setUp(() {
    api = FakeApi();
    service = PricingService();
  });

  tearDown(resetApiClient);

  group('asking for one slot', () {
    // Omitting both parameters is a deliberate request for the server's own choice
    // of hour. Duplicating "which hour do we mean" on the client would be a second
    // answer to a question that already has one.
    test('the venue is a path segment and no date or hour is invented', () async {
      api.ok(_modelSuggestion());
      await api.run(() => service.suggestion('JWT', 'v1'));
      expect(api.endpoint(), '/owner/venues/v1/pricing');
      expect(api.method(), 'GET');
      expect(api.only.url.hasQuery, isFalse);
      expect(api.token(), 'JWT');
    });

    test('a date and an hour are sent under their own names', () async {
      api.ok(_modelSuggestion());
      await api.run(
          () => service.suggestion('JWT', 'v1', date: '2026-03-14', hour: 19));
      expect(api.query(), {'date': '2026-03-14', 'hour': '19'});
    });

    // Midnight is a legal hour and zero is a legal value for it, so the bound is
    // inclusive at both ends.
    test('midnight and 23:00 are both inside the accepted range', () async {
      api.ok(_modelSuggestion());
      await api.run(() async {
        await service.suggestion('JWT', 'v1', hour: 0);
        await service.suggestion('JWT', 'v1', hour: 23);
      });
      expect(api.query(0), {'hour': '0'});
      expect(api.query(1), {'hour': '23'});
    });

    test('an hour outside the day and a blank date are dropped', () async {
      api.ok(_modelSuggestion());
      await api.run(() async {
        await service.suggestion('JWT', 'v1', hour: 24);
        await service.suggestion('JWT', 'v1', hour: -1);
        await service.suggestion('JWT', 'v1', date: '');
      });
      expect(api.query(0), isEmpty);
      expect(api.query(1), isEmpty);
      expect(api.query(2), isEmpty);
    });
  });

  group('a model-sourced suggestion', () {
    test('every block on the wire reaches the card', () async {
      api.ok(_modelSuggestion());
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.isModel, isTrue);
      expect(s.isHeuristic, isFalse);
      expect(s.basePrice, 2500);
      expect(s.suggestedPrice, 2800);
      expect(s.deltaPct, 12.0);
      expect(s.confidence, 0.84);
      expect(s.demand, 0.62);
      expect(s.demandLevel, 'high');
      expect(s.modelVersion, 'pricing-v1');
      expect(s.policyMaxRatio, 1.5);
      expect(s.topFactors.length, 2);
      expect(s.modelMetrics!.testRows, 4800);
      expect(s.modelMetrics!.datasetSource, 'bookings_synthetic_v1.csv');
      expect(s.venueId, 'v1');
      expect(s.slotDate, '2026-03-14');
      expect(s.startTime, '19:00');
      expect(s.hour, 19);
      expect(s.cached, isFalse);
    });

    // The caption is built from the loaded artifact, never from a literal: a number
    // that does not match `pricing_metrics.json` is the kind of claim that gets
    // checked. 0.7628 of an achievable 0.777 is 98% of what is knowable.
    test('the caption reads the artifact, ceiling included', () async {
      api.ok(_modelSuggestion());
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.modelMetrics!.attainmentPct!.round(), 98);
      expect(s.modelCaption, 'Model pricing-v1 · AUC 0.76 · 98% of ceiling');
    });

    test('the delta and the confidence are labelled for display', () async {
      api.ok(_modelSuggestion());
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.deltaLabel, '+12%');
      expect(s.confidenceLabel, '84%');
      expect(s.isActionable, isTrue);
    });

    test('a negative delta is signed with a minus, not a hyphen', () async {
      api.ok(_modelSuggestion(
          const {'deltaPct': -4.4, 'suggestedPrice': 2390, 'confidence': 0.5}));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.deltaLabel, '−4%');
      expect(s.confidenceLabel, '50%');
    });

    test('a suggestion equal to the current price is not worth applying', () async {
      api.ok(_modelSuggestion(const {'suggestedPrice': 2500, 'deltaPct': 0}));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.deltaLabel, 'no change');
      expect(s.isActionable, isFalse);
    });

    test('a suggestion of zero is not applied over a real price', () async {
      api.ok(_modelSuggestion(const {'suggestedPrice': 0}));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.isActionable, isFalse);
    });

    // Both flags mean "the model wanted to go further", and both are worth showing:
    // one names the Node-side business guardrail, the other the training-time policy
    // cap the sweep sat on.
    test('the two ceilings the price can hit are reported separately', () async {
      api.ok(_modelSuggestion(const {'clamped': true, 'atPolicyCap': true}));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.clamped, isTrue);
      expect(s.atPolicyCap, isTrue);
    });

    test('a cached answer says so', () async {
      api.ok(_modelSuggestion(const {'cached': true}));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.cached, isTrue);
    });
  });

  // The heuristic path is what answers when the ML service is unreachable. It is a
  // legitimate answer and it must not borrow the model's clothes.
  group('a heuristic suggestion', () {
    test('no caption is offered for a suggestion the model did not make', () async {
      api.ok({
        'source': 'heuristic',
        'basePrice': 2500,
        'suggestedPrice': 2750,
        'deltaPct': 10.0,
        'reason': 'Peak hour on a weekend',
        'modelVersion': 'pricing-v1',
        'modelMetrics': {'rocAuc': 0.7628, 'rocAucCeiling': 0.777},
        'topFactors': [
          {'key': 'hour', 'label': 'Peak hour', 'direction': 'up'},
        ],
      });
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.isModel, isFalse);
      expect(s.isHeuristic, isTrue);
      expect(s.reason, 'Peak hour on a weekend');
      expect(s.modelCaption, isNull);
    });

    // A chip from the heuristic is a rule, not a measurement. Rendering `0.00 pts`
    // beside it would present a rule as a measured effect of zero, which is the same
    // lie in the other direction.
    test('a rule-based chip carries a label and no measured impact', () async {
      api.ok({
        'source': 'heuristic',
        'topFactors': [
          {'key': 'hour', 'label': 'Peak hour', 'direction': 'up'},
        ],
      });
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      final chip = s!.topFactors.single;
      expect(chip.label, 'Peak hour');
      expect(chip.isMeasured, isFalse);
      expect(chip.impactLabel, isNull);
    });

    test('an unavailable source is neither model nor heuristic', () async {
      api.ok({'source': 'unavailable', 'basePrice': 2500, 'suggestedPrice': 2500});
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.source, 'unavailable');
      expect(s.isModel, isFalse);
      expect(s.isHeuristic, isFalse);
      expect(s.isActionable, isFalse);
    });

    test('a payload with no source at all defaults to unavailable', () async {
      api.ok(const {'basePrice': 2500});
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.source, 'unavailable');
      expect(s.suggestedPrice, 0);
      expect(s.deltaPct, 0);
      expect(s.confidence, isNull);
      expect(s.confidenceLabel, isNull);
    });
  });

  group('the why chips', () {
    test('a measured chip is signed by its direction, in points', () async {
      api.ok(_modelSuggestion());
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.topFactors.first.impactLabel, '+12 pts');
      expect(s.topFactors.first.isUp, isTrue);
      expect(s.topFactors.last.impactLabel, '−4 pts');
      expect(s.topFactors.last.isUp, isFalse);
    });

    // An impact that rounds to zero point is measured but not worth a number: the
    // chip stays, its label does not claim an effect it cannot show.
    test('an impact too small to round to a point shows no number', () async {
      api.ok(_modelSuggestion(const {
        'topFactors': [
          {'key': 'x', 'label': 'Marginal', 'direction': 'up', 'impact': 0.002},
        ],
      }));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.topFactors.single.isMeasured, isTrue);
      expect(s.topFactors.single.impactLabel, isNull);
    });

    test('a chip with no label is dropped rather than rendered blank', () async {
      api.ok(_modelSuggestion(const {
        'topFactors': [
          {'key': 'a', 'label': '', 'direction': 'up', 'impact': 0.2},
          {'key': 'b', 'label': 'Weekend', 'direction': 'up', 'impact': 0.1},
          'not a chip',
        ],
      }));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.topFactors.map((f) => f.label), ['Weekend']);
    });

    // Only 'down' is a downward chip. Anything else — a typo, a null, a new value
    // this client does not know — reads as up, which is the direction the arrow
    // already points.
    test('any direction that is not down reads as up', () async {
      api.ok(_modelSuggestion(const {
        'topFactors': [
          {'key': 'a', 'label': 'Odd', 'direction': 'sideways', 'impact': 0.1},
        ],
      }));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.topFactors.single.direction, 'up');
      expect(s.topFactors.single.impactLabel, '+10 pts');
    });
  });

  group('the served model scores', () {
    test('attainment is the measured AUC against the achievable ceiling', () async {
      api.ok(_modelSuggestion());
      final m = (await api.run(() => service.suggestion('JWT', 'v1')))!.modelMetrics!;
      expect(m.rocAuc, 0.7628);
      expect(m.rocAucCeiling, 0.777);
      expect(m.attainmentPct, closeTo(98.17, 0.01));
      expect(m.brierSkill, 0.11);
      expect(m.trainedAt, '2026-02-11T09:00:00Z');
    });

    // A ceiling is a property of the generator's latent probabilities and is absent
    // for any model not measured against one. No ceiling means no attainment claim,
    // and the caption then stops at the AUC.
    test('no ceiling means no attainment and a shorter caption', () async {
      api.ok(_modelSuggestion(const {
        'modelMetrics': {'rocAuc': 0.7628},
      }));
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.modelMetrics!.attainmentPct, isNull);
      expect(s.modelCaption, 'Model pricing-v1 · AUC 0.76');
    });

    test('a zero ceiling is not divided by', () async {
      api.ok(_modelSuggestion(const {
        'modelMetrics': {'rocAuc': 0.7628, 'rocAucCeiling': 0},
      }));
      final m = (await api.run(() => service.suggestion('JWT', 'v1')))!.modelMetrics!;
      expect(m.attainmentPct, isNull);
    });

    // A model that scores above the estimated ceiling has beaten an estimate, not
    // exceeded what is knowable. The claim stops at 100%.
    test('attainment above the ceiling is capped at all of it', () async {
      api.ok(_modelSuggestion(const {
        'modelMetrics': {'rocAuc': 0.80, 'rocAucCeiling': 0.777},
      }));
      final m = (await api.run(() => service.suggestion('JWT', 'v1')))!.modelMetrics!;
      expect(m.attainmentPct, 100.0);
    });

    test('a version with no metrics still names the model', () async {
      api.ok({'source': 'model', 'modelVersion': 'pricing-v1'});
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.modelCaption, 'Model pricing-v1');
    });

    test('a model with nothing measured offers no caption at all', () async {
      api.ok(const {'source': 'model'});
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.modelCaption, isNull);
    });
  });

  // Postgres sends every NUMERIC as a String and Python emits a trailing `.0` only
  // sometimes, so an `as double` on an integral price would blank the whole card.
  group('numbers off the wire', () {
    test('a price sent as a string is still a price', () async {
      api.ok(const {
        'source': 'model',
        'basePrice': '2500',
        'suggestedPrice': '2800',
        'deltaPct': '12.0',
        'confidence': '0.84',
        'hour': '19',
      });
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.basePrice, 2500);
      expect(s.suggestedPrice, 2800);
      expect(s.deltaPct, 12.0);
      expect(s.confidence, 0.84);
      expect(s.hour, 19);
    });

    test('a fractional price is rounded to the rupee it will be charged at', () async {
      api.ok(const {
        'source': 'model',
        'basePrice': 2500.0,
        'suggestedPrice': '2800.6',
        'hour': 19.0,
      });
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.basePrice, 2500);
      expect(s.suggestedPrice, 2801);
      expect(s.hour, 19);
    });

    test('an unparseable number is absent rather than zero', () async {
      api.ok(const {
        'source': 'model',
        'confidence': 'high',
        'demand': '',
        'policyMaxRatio': 'n/a',
      });
      final s = await api.run(() => service.suggestion('JWT', 'v1'));
      expect(s!.confidence, isNull);
      expect(s.demand, isNull);
      expect(s.policyMaxRatio, isNull);
    });
  });

  group('a suggestion that did not arrive', () {
    test('a refused read is null, not an empty card', () async {
      api.fail('That venue is not yours.', status: 404);
      expect(await api.run(() => service.suggestion('JWT', 'someone-elses')), isNull);
    });

    test('a transport failure is null rather than a throw', () async {
      api.offline();
      expect(await api.run(() => service.suggestion('JWT', 'v1')), isNull);
    });

    // A success envelope carrying something that is not the suggestion object is a
    // server-side contract break, and an empty card is a better answer than a throw.
    test('a success envelope with no suggestion in it is null', () async {
      api.ok('not an object');
      expect(await api.run(() => service.suggestion('JWT', 'v1')), isNull);
    });

    // Pinned as it behaves, not as it should: `topFactors` is hard-cast to `List?`
    // while the chips inside it are guarded by `whereType<Map>()`, so a non-list
    // there escapes as a `TypeError` past the service's never-throw contract.
    // Recorded so that adding the missing guard surfaces here rather than silently.
    test('a wrong-typed chip block escapes as a TypeError', () async {
      api.ok(const {'source': 'model', 'topFactors': 'not a list'});
      await expectLater(
        api.run(() => service.suggestion('JWT', 'v1')),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
