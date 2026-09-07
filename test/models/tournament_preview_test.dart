// Tournament preview tests: the quote an owner reads before the tournament exists.
//
// This is the screen that stops an owner setting a fee that loses them money, so the
// rule it is defended by is that both ends of the range are quoted and neither is
// derived on the phone. A plan that only works at a full field is a plan that loses
// money the first time six teams turn up instead of eight, which is why
// [TournamentPreview.canRun] tests the *minimum* turnout and never the capacity one.
//
// The second rule is that the scheduler's attribution is honest in both directions.
// [SchedulingMeta.label] claims the demand model placed the fixtures only when
// `source == 'model'`; every fallback — ml-service down, breaker open, past the
// forecast horizon — reads as date order and names its reason.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/tournament.dart';

void main() {
  group('PreviewRound', () {
    test('the placement arrives as pg strings', () {
      final r = PreviewRound.fromJson({
        'round': '2',
        'label': 'Semi-final',
        'pick': 'off_peak',
        'date': '2026-03-14',
        'count': '2',
        'total': '2',
        'spansDays': true,
      });
      expect(r.round, 2);
      expect(r.label, 'Semi-final');
      expect(r.count, 2);
      expect(r.spansDays, isTrue);
      expect(r.date, '2026-03-14');
    });

    test('a round with nothing chosen is still numbered and headed', () {
      final r = PreviewRound.fromJson({});
      expect(r.round, 1);
      expect(r.label, 'Round');
      expect(r.pick, isNull);
      expect(r.pickLabel, '');
      expect(r.spansDays, isFalse);
    });

    test('the three published picks are worded', () {
      expect(PreviewRound.fromJson({'pick': 'off_peak'}).pickLabel, 'Off-peak');
      expect(PreviewRound.fromJson({'pick': 'peak'}).pickLabel, 'Peak');
      expect(PreviewRound.fromJson({'pick': 'any'}).pickLabel, 'Any hour');
    });

    test('an unrecognised pick is shown as sent rather than guessed at', () {
      expect(PreviewRound.fromJson({'pick': 'shoulder'}).pickLabel, 'shoulder');
    });

    test('spansDays requires a literal true', () {
      expect(PreviewRound.fromJson({'spansDays': 'true'}).spansDays, isFalse);
    });
  });

  group('ScheduleShortfall', () {
    test('the line names the round and both hour counts', () {
      final s = ScheduleShortfall.fromJson({
        'round': '2',
        'need': '4',
        'available': '1',
      });
      expect(s.line, 'Round 2 needs 4 hours, 1 open');
    });

    test('an unfilled shortfall still produces a readable line', () {
      expect(ScheduleShortfall.fromJson({}).line, 'Round 0 needs 0 hours, 0 open');
    });
  });

  group('PreviewPlan', () {
    test('the unknown constant schedules nothing and quotes no cost', () {
      const p = PreviewPlan.unknown;
      expect(p.schedulable, isFalse);
      expect(p.cost, isNull);
      expect(p.shortfall, isNull);
      expect(p.code, isNull);
      expect(p.message, isNull);
      expect(p.hasByes, isFalse);
      expect(p.rounds, isEmpty);
    });

    test('a plan that fits carries the real slot total and its rounds', () {
      final p = PreviewPlan.fromJson({
        'schedulable': true,
        'teams': '8',
        'fixtures': '7',
        'byes': '0',
        'hoursNeeded': '7',
        'hoursAvailable': '12',
        'slotTotal': '14000.00',
        'estimatedCost': '15400.00',
        'startDate': '2026-03-12',
        'endDate': '2026-03-14',
        'firstAt': '2026-03-12T13:00:00Z',
        'rounds': [
          {'round': 1, 'label': 'Quarter-final', 'pick': 'off_peak'},
        ],
      });
      expect(p.schedulable, isTrue);
      expect(p.teams, 8);
      expect(p.fixtures, 7);
      expect(p.hoursLine, '7 hours needed · 12 open');
      expect(p.hasByes, isFalse);
      expect(p.rounds.single.pickLabel, 'Off-peak');
      expect(p.firstAt!.isUtc, isFalse);
      expect(p.cost, 14000.0,
          reason: 'the priced slots are the quote; the estimate is only a fallback');
    });

    test('a plan that does not fit falls back to the list-price estimate', () {
      final p = PreviewPlan.fromJson({
        'schedulable': false,
        'code': 'NOT_ENOUGH_HOURS',
        'message': 'Not enough open hours at this venue for 8 teams',
        'estimatedCost': '15400.00',
        'shortfall': {'round': '3', 'need': '1', 'available': '0'},
      });
      expect(p.cost, 15400.0);
      expect(p.code, 'NOT_ENOUGH_HOURS');
      expect(p.shortfall!.line, 'Round 3 needs 1 hours, 0 open');
    });

    test('schedulable requires a literal true, so no plan is assumed to fit', () {
      expect(PreviewPlan.fromJson({'schedulable': 'true'}).schedulable, isFalse);
      expect(PreviewPlan.fromJson({'schedulable': 1}).schedulable, isFalse);
    });

    test('a non-map shortfall block is ignored rather than fatal', () {
      expect(PreviewPlan.fromJson({'shortfall': 'none'}).shortfall, isNull);
    });

    test('byes are reported so an odd field is not silently padded', () {
      expect(PreviewPlan.fromJson({'byes': '2'}).hasByes, isTrue);
      expect(PreviewPlan.fromJson({'byes': 0}).hasByes, isFalse);
    });
  });

  group('RecommendedFee', () {
    test('the recommendation carries the worst-turnout breakdown it was solved for', () {
      final r = RecommendedFee.fromJson({
        'entryFee': '4000.00',
        'minTeams': '4',
        'venueCost': '14000.00',
        'targetMarginPercent': '25',
        'targetMargin': '3500.00',
        'achievable': true,
        'roundedTo': '100',
        'atMinTeams': {'teams': '4', 'pool': '16000.00', 'prize': '1200.00'},
      });
      expect(r.entryFee, 4000.0);
      expect(r.minTeams, 4);
      expect(r.venueCost, 14000.0);
      expect(r.targetMargin, 3500.0);
      expect(r.achievable, isTrue);
      expect(r.atMinTeams.teams, 4,
          reason: 'the floor of what the owner is agreeing to, not the best case');
      expect(r.atMinTeams.prize, 1200.0);
    });

    test('the defaults are the platform policy, and no fee', () {
      const r = RecommendedFee.none;
      expect(r.entryFee, 0);
      expect(r.minTeams, 4);
      expect(r.targetMarginPercent, 25);
      expect(r.roundedTo, 100);
      expect(r.atMinTeams.isProjection, isTrue);
    });

    test('achievable requires a literal true, so an unsolvable target is not claimed', () {
      expect(RecommendedFee.fromJson({}).achievable, isFalse);
      expect(RecommendedFee.fromJson({'achievable': 'true'}).achievable, isFalse);
      expect(RecommendedFee.fromJson({'achievable': true}).achievable, isTrue);
    });
  });

  group('SchedulingMeta', () {
    test('the fallback default claims date order, not the model', () {
      const m = SchedulingMeta.none;
      expect(m.source, 'chronological');
      expect(m.fromModel, isFalse);
      expect(m.label, 'Placed in date order');
      expect(m.modelVersion, isNull);
      expect(m.coverage, isNull);
      expect(m.candidates, 0);
      expect(m.cached, isFalse);
      expect(m.picks, isEmpty);
    });

    test('a model run is attributed to the model, with its version and coverage', () {
      final m = SchedulingMeta.fromJson({
        'source': 'model',
        'modelVersion': 'demand-v1',
        'coverage': '0.86',
        'candidates': '48',
        'cached': true,
        'picks': [
          {'round': 1, 'pick': 'off_peak'},
        ],
      });
      expect(m.fromModel, isTrue);
      expect(m.label, "Placed in the venue's quietest hours by the demand model");
      expect(m.modelVersion, 'demand-v1');
      expect(m.coverage, 0.86);
      expect(m.candidates, 48);
      expect(m.cached, isTrue);
      expect(m.picks.single.pickLabel, 'Off-peak');
    });

    test('a fallback names its reason in the same line', () {
      final m = SchedulingMeta.fromJson({
        'source': 'chronological',
        'reason': 'ml-service unavailable',
      });
      expect(m.label, 'Placed in date order — ml-service unavailable');
      expect(m.fromModel, isFalse);
    });

    test('only the exact source claims the model, so no near miss can', () {
      expect(SchedulingMeta.fromJson({'source': 'ml'}).fromModel, isFalse);
      expect(SchedulingMeta.fromJson({'source': 'Model'}).fromModel, isFalse);
      expect(SchedulingMeta.fromJson({'source': 'model'}).fromModel, isTrue);
    });

    test('an unrecognised source still reads as date order rather than the model', () {
      final m = SchedulingMeta.fromJson({'source': 'heuristic'});
      expect(m.source, 'heuristic');
      expect(m.label, startsWith('Placed in date order'),
          reason: 'claiming the model ran is the one lie this block exists to prevent');
    });
  });

  group('TournamentPreview', () {
    test('the empty constant blocks the Create button on missing slots', () {
      const p = TournamentPreview.empty;
      expect(p.canRun, isFalse);
      expect(p.candidateHours, 0);
      expect(
        p.blocker,
        'This venue has no open slots in the scheduling window — add slots first',
      );
      expect(p.cappedByHours, isFalse);
      expect(p.config, isEmpty);
      expect(p.venue.display, 'The venue');
      expect(p.scheduling.fromModel, isFalse);
    });

    test('a runnable quote reads both ends of the range and its own economics', () {
      final p = TournamentPreview.fromJson({
        'venue': {'name': 'F-11 Arena', 'city': 'Islamabad'},
        'config': {'maxTeams': 8, 'minTeams': 4},
        'candidateHours': '18',
        'capacity': {'schedulable': true, 'teams': '8', 'slotTotal': '14000.00'},
        'minimum': {'schedulable': true, 'teams': '4', 'slotTotal': '7000.00'},
        'economics': {
          'atCapacity': {'pool': '24000.00', 'prize': '6000.00'},
          'atMinimum': {'pool': '12000.00', 'prize': '3000.00'},
        },
        'recommended': {'entryFee': '4000.00'},
        'meta': {
          'scheduling': {'source': 'model', 'modelVersion': 'demand-v1'},
        },
      });
      expect(p.canRun, isTrue);
      expect(p.blocker, isNull);
      expect(p.cappedByHours, isFalse);
      expect(p.venue.where, 'F-11 Arena · Islamabad');
      expect(p.config['maxTeams'], 8);
      expect(p.capacity.cost, 14000.0);
      expect(p.minimum.cost, 7000.0);
      expect(p.atCapacity.prize, 6000.0);
      expect(p.atMinimum.prize, 3000.0);
      expect(p.recommended.entryFee, 4000.0);
      expect(p.scheduling.fromModel, isTrue);
    });

    test('the minimum turnout decides whether it can run, never the full field', () {
      final p = TournamentPreview.fromJson({
        'candidateHours': '10',
        'capacity': {'schedulable': false, 'teams': '8'},
        'minimum': {'schedulable': true, 'teams': '4'},
      });
      expect(p.canRun, isTrue);
      expect(p.blocker, isNull);
      expect(p.cappedByHours, isTrue,
          reason: 'it can run, though not at the size the owner typed');
    });

    test('an unschedulable minimum blocks with the server wording', () {
      final p = TournamentPreview.fromJson({
        'candidateHours': '4',
        'minimum': {
          'schedulable': false,
          'teams': '4',
          'message': 'Round 2 needs 2 hours, 0 open',
        },
      });
      expect(p.canRun, isFalse);
      expect(p.blocker, 'Round 2 needs 2 hours, 0 open');
      expect(p.cappedByHours, isFalse);
    });

    test('a blocked plan with no message still names the turnout it failed at', () {
      final p = TournamentPreview.fromJson({
        'candidateHours': '4',
        'minimum': {'schedulable': false, 'teams': '6'},
      });
      expect(p.blocker, 'Not enough open hours at this venue for 6 teams');
    });

    test('no open slots is reported ahead of the hours arithmetic', () {
      final p = TournamentPreview.fromJson({
        'candidateHours': 0,
        'minimum': {'schedulable': false, 'message': 'Round 2 needs 2 hours, 0 open'},
      });
      expect(p.blocker, contains('add slots first'),
          reason: 'a venue with no slots is a different fix from a venue with too few');
    });

    test('the scheduling stamp is read out of its nested meta block', () {
      expect(TournamentPreview.fromJson({}).scheduling.source, 'chronological');
      expect(TournamentPreview.fromJson({'meta': 'x'}).scheduling.source, 'chronological');
      expect(
        TournamentPreview.fromJson({'meta': {'scheduling': 'model'}}).scheduling.source,
        'chronological',
        reason: 'a non-map stamp must not be read as a model run',
      );
    });

    test('the draft configuration is echoed verbatim, not re-read', () {
      final p = TournamentPreview.fromJson({
        'config': {'maxTeams': 8, 'format': 'knockout', 'entryFee': '3000.00'},
      });
      expect(p.config['format'], 'knockout');
      expect(p.config['entryFee'], '3000.00',
          reason: 'the create screen typed it; only the evidence binder reads it back');
    });
  });
}
