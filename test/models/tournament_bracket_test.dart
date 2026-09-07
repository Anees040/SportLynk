// Bracket, standings, entry and economics model tests.
//
// The tournament wire models are split across two files; the entry-and-countdown
// half is in tournament_model_test.dart. What this file defends is the shape of the
// draw: a fixture with no teams yet is a placeholder that must still be drawn,
// because the shape of the bracket is itself the information a captain reads. So
// [Fixture.isTbd] and [Fixture.isBye] are kept apart — both are "not playable", for
// opposite reasons — and `nameA`/`nameB` always return something printable.
//
// The second rule is that the money waterfall reports its own mode. An
// [Economics] block is either a projection or a settlement, and
// [Economics.isUnderwater] must say out loud that the pool did not cover the venue
// rather than letting a silent "PKR 0 prize" stand in for it.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/tournament.dart';

void main() {
  group('Fixture', () {
    test('the wire values arrive as pg strings and are parsed, not cast', () {
      final f = Fixture.fromJson({
        'id': 'f1',
        'round': '2',
        'position': '3',
        'teamA': 't1',
        'teamAName': 'Alpha',
        'teamAElo': '1240',
        'teamB': 't2',
        'teamBName': 'Beta',
        'teamBElo': '1180',
        'scoreA': '3',
        'scoreB': '1',
        'slotPrice': '2400.00',
        'status': 'played',
      });
      expect(f.round, 2);
      expect(f.position, 3);
      expect(f.teamAElo, 1240);
      expect(f.teamBElo, 1180);
      expect(f.scoreA, 3);
      expect(f.scoreB, 1);
      expect(f.slotPrice, 2400.0);
    });

    test('an unplayed fixture defaults to upcoming, and settled covers both ways', () {
      expect(Fixture.fromJson({'id': 'f1'}).isUpcoming, isTrue);
      expect(Fixture.fromJson({'id': 'f1'}).isSettled, isFalse);
      expect(Fixture.fromJson({'id': 'f1', 'status': 'played'}).isSettled, isTrue);
      expect(Fixture.fromJson({'id': 'f1', 'status': 'walkover'}).isSettled, isTrue,
          reason: 'a walkover is a decided result, only without a scoreline');
      expect(Fixture.fromJson({'id': 'f1', 'status': 'cancelled'}).isSettled, isFalse);
    });

    test('a slot held for an undecided winner is TBD, not a bye', () {
      final tbd = Fixture.fromJson({'id': 'f1'});
      expect(tbd.isTbd, isTrue);
      expect(tbd.isPlayable, isFalse);
      expect(tbd.nameA, 'TBD');
      expect(tbd.nameB, 'TBD');
    });

    test('a bye is not TBD, and names itself on the empty side', () {
      final bye = Fixture.fromJson({
        'id': 'f1',
        'isBye': true,
        'teamA': 't1',
        'teamAName': 'Alpha',
      });
      expect(bye.isBye, isTrue);
      expect(bye.isTbd, isFalse, reason: 'a bye is decided, a TBD is not');
      expect(bye.isPlayable, isFalse);
      expect(bye.nameA, 'Alpha');
      expect(bye.nameB, 'Bye');
    });

    test('isBye requires a literal true', () {
      expect(Fixture.fromJson({'id': 'f1', 'isBye': 'true'}).isBye, isFalse);
      expect(Fixture.fromJson({'id': 'f1', 'isBye': 1}).isBye, isFalse);
    });

    test('a half-drawn fixture is neither playable nor TBD', () {
      final half = Fixture.fromJson({'id': 'f1', 'teamA': 't1', 'teamAName': 'Alpha'});
      expect(half.isTbd, isFalse);
      expect(half.isPlayable, isFalse);
      expect(half.nameB, 'TBD');
    });

    test('a named team with no id still shows its name', () {
      expect(Fixture.fromJson({'id': 'f1', 'teamAName': 'Alpha'}).nameA, 'Alpha');
    });

    test('the winner is matched by id, so a name collision cannot decide a tie', () {
      final f = Fixture.fromJson({
        'id': 'f1',
        'teamA': 't1',
        'teamB': 't2',
        'winner': 't2',
      });
      expect(f.aWon, isFalse);
      expect(f.bWon, isTrue);
    });

    test('an undecided fixture credits neither side', () {
      final f = Fixture.fromJson({'id': 'f1', 'teamA': 't1', 'teamB': 't2'});
      expect(f.aWon, isFalse);
      expect(f.bWon, isFalse);
    });
  });

  group('Fixture.when', () {
    test('the venue day and its wall clock are joined', () {
      final f = Fixture.fromJson({
        'id': 'f1',
        'slotDate': '2026-03-14',
        'startTime': '18:00:00',
      });
      expect(f.when, '14 Mar · 6:00 PM');
    });

    test('it degrades to whichever half exists', () {
      expect(Fixture.fromJson({'id': 'f1', 'startTime': '09:30:00'}).when, '9:30 AM');
      expect(Fixture.fromJson({'id': 'f1', 'slotDate': '2026-03-14'}).when, '14 Mar');
      expect(Fixture.fromJson({'id': 'f1'}).when, '');
    });

    test('an unparseable date is printed as it arrived rather than dropped', () {
      expect(
        Fixture.fromJson({'id': 'f1', 'slotDate': 'next Saturday', 'startTime': '18:00'})
            .when,
        'next Saturday · 6:00 PM',
      );
    });

    test('midnight and noon are not both printed as 12 AM', () {
      expect(Fixture.fromJson({'id': 'f1', 'startTime': '00:00:00'}).when, '12:00 AM');
      expect(Fixture.fromJson({'id': 'f1', 'startTime': '12:00:00'}).when, '12:00 PM');
    });
  });

  group('Fixture.favouriteLine', () {
    Fixture f(Map<String, dynamic> j) => Fixture.fromJson({
          'id': 'f1',
          'teamA': 't1',
          'teamAName': 'Alpha',
          'teamB': 't2',
          'teamBName': 'Beta',
          ...j,
        });

    test('the higher-rated side is named with its percentage', () {
      expect(
        f({'winProbabilityA': 0.72, 'winProbabilityB': 0.28}).favouriteLine,
        'Alpha favoured · 72%',
      );
    });

    test('the other side is named when it is the favoured one', () {
      expect(
        f({'winProbabilityA': '0.36', 'winProbabilityB': '0.64'}).favouriteLine,
        'Beta favoured · 64%',
      );
    });

    test('a near-even tie is called even rather than picking a favourite', () {
      expect(
        f({'winProbabilityA': 0.55, 'winProbabilityB': 0.45}).favouriteLine,
        'Even match · 55%',
        reason: 'a 55% edge is inside the noise, so naming a favourite overstates it',
      );
    });

    test('there is no line when there is nothing to say', () {
      expect(f({}).favouriteLine, isNull);
      expect(f({'winProbabilityA': 0.7}).favouriteLine, isNull,
          reason: 'one probability without the other cannot be compared');
      expect(
        Fixture.fromJson({
          'id': 'f1',
          'teamA': 't1',
          'isBye': true,
          'winProbabilityA': 0.7,
          'winProbabilityB': 0.3,
        }).favouriteLine,
        isNull,
        reason: 'a bye or a TBD has no matchup to forecast',
      );
    });
  });

  group('BracketRound', () {
    test('the counts arrive as pg strings and the fixtures are parsed', () {
      final r = BracketRound.fromJson({
        'round': '2',
        'label': 'Semi-final',
        'total': '2',
        'played': '1',
        'date': '2026-03-14',
        'fixtures': [
          {'id': 'f1', 'status': 'played'},
          {'id': 'f2'},
        ],
      });
      expect(r.round, 2);
      expect(r.label, 'Semi-final');
      expect(r.total, 2);
      expect(r.fixtures.length, 2);
      expect(r.date, '2026-03-14');
    });

    test('a round with no label is still headed, and numbered from one', () {
      final r = BracketRound.fromJson({});
      expect(r.label, 'Round');
      expect(r.round, 1);
      expect(r.date, isNull);
      expect(r.fixtures, isEmpty);
    });

    test('a round nothing has been played in is not complete', () {
      expect(BracketRound.fromJson({'total': 2, 'played': 0}).isComplete, isFalse);
      expect(BracketRound.fromJson({'total': 2, 'played': 2}).isComplete, isTrue);
    });

    test('an empty round is not complete, since there was nothing to finish', () {
      expect(BracketRound.fromJson({'total': 0, 'played': 0}).isComplete, isFalse,
          reason: 'a round with no fixtures would otherwise report itself done');
    });

    test('a walkover counted beyond the total still reads complete', () {
      expect(BracketRound.fromJson({'total': 2, 'played': 3}).isComplete, isTrue);
    });

    test('progress is the pair, so a stalled round is visible', () {
      expect(BracketRound.fromJson({'total': 4, 'played': 1}).progress, '1 / 4 played');
      expect(BracketRound.fromJson({}).progress, '0 / 0 played');
    });

    test('a non-map fixture entry is skipped rather than fatal', () {
      final r = BracketRound.fromJson({
        'fixtures': [
          {'id': 'f1'},
          'garbage',
          {'id': 'f2'},
        ],
      });
      expect(r.fixtures.length, 2);
      expect(r.fixtures.last.id, 'f2');
    });
  });

  group('Bracket', () {
    test('the pre-draw default claims no bracket exists', () {
      const b = Bracket.empty;
      expect(b.generated, isFalse);
      expect(b.rounds, 0);
      expect(b.size, isNull);
      expect(b.roundsList, isEmpty);
      expect(b.isKnockout, isTrue);
      expect(b.hasByes, isFalse);
      expect(b.progress, 0);
    });

    test('generated requires a literal true, so no grid is drawn on a truthy value', () {
      expect(Bracket.fromJson({'generated': true}).generated, isTrue);
      expect(Bracket.fromJson({'generated': 'true'}).generated, isFalse);
      expect(Bracket.fromJson({'generated': 1}).generated, isFalse);
    });

    test('the shape arrives as pg strings', () {
      final b = Bracket.fromJson({
        'format': 'knockout',
        'rounds': '3',
        'size': '8',
        'byes': '2',
        'total': '7',
        'played': '4',
        'generated': true,
        'roundsList': [
          {'round': 1, 'label': 'Quarter-final'},
          {'round': 2, 'label': 'Semi-final'},
        ],
      });
      expect(b.rounds, 3);
      expect(b.size, 8);
      expect(b.byes, 2);
      expect(b.hasByes, isTrue);
      expect(b.roundsList.length, 2);
      expect(b.progress, closeTo(4 / 7, 0.0001));
    });

    test('a round robin is not a knockout, and the format is read as sent', () {
      final b = Bracket.fromJson({'format': 'round_robin'});
      expect(b.isKnockout, isFalse);
      expect(b.format, 'round_robin');
    });

    test('progress on an empty draw is zero rather than a division by zero', () {
      expect(Bracket.fromJson({'total': 0, 'played': 0}).progress, 0);
    });
  });

  group('Standing', () {
    test('every column arrives as a pg string and is parsed', () {
      final s = Standing.fromJson({
        'teamId': 't1',
        'name': 'Alpha',
        'elo': '1240',
        'seed': '2',
        'played': '5',
        'wins': '3',
        'draws': '1',
        'losses': '1',
        'goalsFor': '11',
        'goalsAgainst': '6',
        'goalDiff': '5',
        'points': '10',
        'position': '1',
      });
      expect(s.elo, 1240);
      expect(s.seed, 2);
      expect(s.played, 5);
      expect(s.points, 10);
      expect(s.position, 1);
      expect(s.record, 'W 3 · D 1 · L 1');
      expect(s.goals, '11 : 6');
      expect(s.diff, '+5');
    });

    test('an unseeded team keeps a null seed, and the rating defaults to 1000', () {
      final s = Standing.fromJson({'teamId': 't1'});
      expect(s.seed, isNull);
      expect(s.elo, 1000);
      expect(s.name, 'Team');
      expect(s.record, 'W 0 · D 0 · L 0');
    });

    test('a negative difference keeps its sign and a zero carries none', () {
      expect(Standing.fromJson({'teamId': 't1', 'goalDiff': '-3'}).diff, '-3');
      expect(Standing.fromJson({'teamId': 't1', 'goalDiff': 0}).diff, '0',
          reason: 'a level difference is not an improvement, so it takes no plus');
    });
  });

  group('Registration', () {
    Registration reg(Map<String, dynamic> j) => Registration.fromJson({
          'registrationId': 'r1',
          'teamId': 't1',
          ...j,
        });

    test('the row arrives with pg numbers and a nested record', () {
      final r = reg({
        'teamName': 'Alpha',
        'city': 'Islamabad',
        'elo': '1240',
        'captainId': 'u1',
        'captainName': 'Ali',
        'status': 'accepted',
        'seed': '2',
        'paidAmount': '3000.00',
        'record': {'played': '12', 'wins': '8'},
      });
      expect(r.elo, 1240);
      expect(r.seed, 2);
      expect(r.paidAmount, 3000.0);
      expect(r.record.line, '12 played · 8 W');
      expect(r.label, 'Confirmed');
      expect(r.seedLabel, 'Seed 2');
    });

    test('an unseeded entry prints no seed line rather than "Seed null"', () {
      expect(reg({}).seed, isNull);
      expect(reg({}).seedLabel, '');
    });

    test('the two spot-holding states are kept apart, since only one is decided', () {
      expect(reg({'status': 'registered'}).isPending, isTrue);
      expect(reg({'status': 'registered'}).isAccepted, isFalse);
      expect(reg({'status': 'accepted'}).isAccepted, isTrue);
      expect(reg({'status': 'accepted'}).isPending, isFalse);
    });

    test('a withdrawn or rejected entry is out; an eliminated one is not', () {
      expect(reg({'status': 'withdrawn'}).isOut, isTrue);
      expect(reg({'status': 'rejected'}).isOut, isTrue);
      expect(reg({'status': 'eliminated'}).isOut, isFalse,
          reason: 'a knocked-out team still played, and stays on the list');
    });

    test('holdsASpot covers the three states that occupy the field', () {
      expect(reg({'status': 'registered'}).holdsASpot, isTrue);
      expect(reg({'status': 'accepted'}).holdsASpot, isTrue);
      expect(reg({'status': 'eliminated'}).holdsASpot, isTrue);
      expect(reg({'status': 'withdrawn'}).holdsASpot, isFalse);
      expect(reg({'status': 'rejected'}).holdsASpot, isFalse);
    });

    test('a bare row still renders, with a named team and a default rating', () {
      final r = reg({});
      expect(r.teamName, 'Team');
      expect(r.elo, 1000);
      expect(r.paidAmount, 0);
      expect(r.status, '');
      expect(r.label, '');
      expect(r.registeredAt, isNull);
      expect(r.record.line, '');
    });

    test('the three timestamps are separate facts, and are localised', () {
      final r = reg({
        'registeredAt': '2026-03-01T10:00:00Z',
        'approvedAt': '2026-03-02T10:00:00Z',
        'withdrawnAt': null,
      });
      expect(r.registeredAt, isNotNull);
      expect(r.approvedAt, isNotNull);
      expect(r.withdrawnAt, isNull);
      expect(r.registeredAt!.isUtc, isFalse,
          reason: 'tournament timestamps are converted on read, unlike the admin models');
    });
  });

  group('Economics', () {
    test('a settled waterfall reads every share as a pg string', () {
      final e = Economics.fromJson({
        'settled': true,
        'teams': '8',
        'entryFee': '3000.00',
        'pool': '24000.00',
        'venueCost': '14000.00',
        'prize': '6000.00',
        'prizePercent': '60',
        'winnerPercent': '70',
        'runnerupPercent': '30',
        'winnerShare': '4200.00',
        'runnerupShare': '1800.00',
        'margin': '4000.00',
        'ownerEarning': '18000.00',
      });
      expect(e.teams, 8);
      expect(e.pool, 24000.0);
      expect(e.venueCost, 14000.0);
      expect(e.prize, 6000.0);
      expect(e.winnerShare, 4200.0);
      expect(e.ownerEarning, 18000.0);
      expect(e.isProjection, isFalse);
      expect(e.hasPrize, isTrue);
      expect(e.isUnderwater, isFalse);
    });

    test('an unsettled block is a projection, and says so', () {
      expect(Economics.empty.isProjection, isTrue);
      expect(Economics.fromJson({'settled': 'true'}).isProjection, isTrue,
          reason: 'a truthy string must not be read as a settled tournament');
      expect(Economics.fromJson({'settled': true}).isProjection, isFalse);
    });

    test('the split percentages default to the platform policy', () {
      final e = Economics.empty;
      expect(e.prizePercent, 60);
      expect(e.winnerPercent, 70);
      expect(e.runnerupPercent, 30);
    });

    test('a pool that did not cover the venue is reported underwater', () {
      final e = Economics.fromJson({'pool': '8000.00', 'prize': 0});
      expect(e.isUnderwater, isTrue,
          reason: 'a silent "PKR 0 prize" would hide that the owner took the pool');
      expect(e.hasPrize, isFalse);
    });

    test('the server flag alone is enough to call it underwater', () {
      expect(Economics.fromJson({'underwater': true}).isUnderwater, isTrue);
      expect(Economics.fromJson({'underwater': 'true'}).isUnderwater, isFalse,
          reason: 'and no pool means nothing was collected to be short with');
    });

    test('an empty tournament is not underwater, only unstarted', () {
      expect(Economics.empty.isUnderwater, isFalse);
      expect(Economics.fromJson({'pool': 0, 'prize': 0}).isUnderwater, isFalse);
    });

    test('identityOk is a tri-state: unchecked is not the same as failed', () {
      expect(Economics.empty.identityOk, isNull);
      expect(Economics.fromJson({'identityOk': false}).identityOk, isFalse);
      expect(Economics.fromJson({'identityOk': true}).identityOk, isTrue);
      expect(Economics.fromJson({'identityOk': 'true'}).identityOk, isFalse);
    });

    test('the projection-only fields stay null on a settled block', () {
      final e = Economics.fromJson({'settled': true});
      expect(e.slotTotal, isNull);
      expect(e.venueDiscount, isNull);
      expect(e.retailValue, isNull);
      expect(e.uplift, isNull);
      expect(e.projectedFor, isNull);
      expect(e.hours, isNull);
      expect(e.listPrice, isNull);
    });

    test('perPlayer divides the fee, and a squad of none pays the whole fee', () {
      final e = Economics.fromJson({'entryFee': '3000.00'});
      expect(e.perPlayer(6), 500.0);
      expect(e.perPlayer(0), 3000.0,
          reason: 'an unknown squad size must not divide by zero');
      expect(e.perPlayer(-1), 3000.0);
    });
  });

  group('Economics.upliftLine', () {
    String money(num v) => 'PKR ${v.round()}';

    test('the comparison names both numbers and the percentage', () {
      final e = Economics.fromJson({
        'ownerEarning': '21200.00',
        'retailValue': '14000.00',
        'uplift': '7200.00',
        'upliftPercent': '51.4',
      });
      expect(
        e.upliftLine(money),
        'You earn PKR 21200 — PKR 7200 more than selling these hours at PKR 14000 (+51%)',
      );
    });

    test('a loss is stated as plainly as a gain', () {
      final e = Economics.fromJson({
        'ownerEarning': '9000.00',
        'retailValue': '14000.00',
        'uplift': '-5000.00',
        'upliftPercent': '-36',
      });
      expect(
        e.upliftLine(money),
        'You earn PKR 9000 — PKR 5000 less than selling these hours at PKR 14000 (-36%)',
      );
    });

    test('there is no line without a retail comparison to make', () {
      expect(Economics.empty.upliftLine(money), isNull);
      expect(
        Economics.fromJson({'retailValue': '14000.00'}).upliftLine(money),
        isNull,
        reason: 'a retail value with no uplift is half a comparison',
      );
      expect(
        Economics.fromJson({'retailValue': 0, 'uplift': '100'}).upliftLine(money),
        isNull,
        reason: 'nothing to sell means no percentage can be quoted',
      );
    });

    test('the percentage is dropped rather than invented when absent', () {
      final e = Economics.fromJson({
        'ownerEarning': '21200.00',
        'retailValue': '14000.00',
        'uplift': '7200.00',
      });
      expect(e.upliftLine(money), endsWith('at PKR 14000'));
    });
  });
}
