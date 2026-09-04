// Unit tests for lib/models/team_stats.dart.
//
// The rating rules are the reason this file is tested rather than the screens that
// print them: FR2.6 forbids showing the 1000 seed as a rating, and an unrated match
// must not be labelled with a movement it did not cause. Both are one-line getters
// that every ranking and profile surface depends on.
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/team_stats.dart';

RankedTeam team({
  bool ranked = false,
  int? displayElo,
  int wins = 0,
  int played = 0,
  int? movement,
}) =>
    RankedTeam(
      id: 't-1',
      name: 'Karachi Kings',
      sport: 'football',
      rank: 1,
      ranked: ranked,
      displayElo: displayElo,
      wins: wins,
      played: played,
      movement: movement,
    );

void main() {
  group('eloLabel (FR2.6)', () {
    test('an unranked team reads Unranked, never a number', () {
      expect(team(ranked: false, displayElo: 1000).eloLabel, 'Unranked');
      expect(team(ranked: false, displayElo: null).eloLabel, 'Unranked');
    });

    test('a ranked team with no display value still reads Unranked', () {
      expect(team(ranked: true, displayElo: null).eloLabel, 'Unranked');
    });

    test('a ranked team prints its rating with a thousands separator', () {
      expect(team(ranked: true, displayElo: 1240).eloLabel, '1,240');
      expect(team(ranked: true, displayElo: 950).eloLabel, '950');
      expect(team(ranked: true, displayElo: 1000).eloLabel, '1,000');
    });
  });

  group('movement', () {
    test('null means absent from the board, which is not the same as held', () {
      expect(team(movement: null).isNewEntry, isTrue);
      expect(team(movement: null).climbed, isFalse);
      expect(team(movement: null).fell, isFalse);
    });

    test('zero means the team held its place', () {
      expect(team(movement: 0).isNewEntry, isFalse);
      expect(team(movement: 0).climbed, isFalse);
      expect(team(movement: 0).fell, isFalse);
    });

    test('sign decides the arrow', () {
      expect(team(movement: 3).climbed, isTrue);
      expect(team(movement: -2).fell, isTrue);
    });
  });

  group('winRate', () {
    test('is zero rather than a division by zero before any match', () {
      expect(team(played: 0, wins: 0).winRate, 0);
    });

    test('is a rounded percentage of played', () {
      expect(team(played: 4, wins: 1).winRate, 25);
      expect(team(played: 3, wins: 2).winRate, 67);
      expect(team(played: 7, wins: 7).winRate, 100);
    });
  });

  group('RankedTeam.fromJson', () {
    test('parses the string-typed counts pg returns for aggregates', () {
      final t = RankedTeam.fromJson({
        'id': 9,
        'name': 'Lahore XI',
        'sport': 'cricket',
        'rank': '2',
        'wins': '5',
        'played': '8',
        'member_count': '11',
        'ranked': true,
        'display_elo': '1085',
      });
      expect(t.id, '9');
      expect(t.rank, 2);
      expect(t.wins, 5);
      expect(t.memberCount, 11);
      expect(t.displayElo, 1085);
      expect(t.eloLabel, '1,085');
    });

    test('a missing movement stays null instead of becoming zero', () {
      final t = RankedTeam.fromJson({'id': '1', 'name': 'A', 'sport': 'football'});
      expect(t.movement, isNull);
      expect(t.isNewEntry, isTrue);
      expect(t.ranked, isFalse);
      expect(t.eloLabel, 'Unranked');
    });
  });

  group('TeamStats.formSequence', () {
    // The API sends newest-first; a form row reads left to right in time order.
    test('reverses the stored run so it reads oldest to newest', () {
      const s = TeamStats(form: 'WWLDW');
      expect(s.formSequence, ['W', 'D', 'L', 'W', 'W']);
    });

    test('an empty run yields no cells rather than one blank cell', () {
      expect(const TeamStats().formSequence, isEmpty);
    });
  });

  group('EloPoint', () {
    EloPoint point({
      String result = 'win',
      int my = 2,
      int their = 1,
      bool rated = true,
      int? delta = 18,
    }) =>
        EloPoint.fromJson({
          'match_id': 'm-1',
          'result': result,
          'my_score': '$my',
          'their_score': '$their',
          'rated': rated,
          'elo_delta': delta,
        });

    test('headline names the outcome and keeps an en dash between scores', () {
      expect(point(result: 'win').headline, 'Won 2–1');
      expect(point(result: 'loss', my: 0, their: 3).headline, 'Lost 0–3');
      expect(point(result: 'draw', my: 1, their: 1).headline, 'Drew 1–1');
      expect(point(result: 'disputed').headline, 'Disputed 2–1');
      expect(point(result: 'anything-else', my: 1, their: 1).headline, 'Drew 1–1');
    });

    test('deltaLabel signs a real movement', () {
      expect(point(delta: 18).deltaLabel, '+18');
      expect(point(delta: -14).deltaLabel, '-14');
    });

    // An unrated or frozen match has no movement to report, and "+0" would read as a
    // rated draw that moved nothing.
    test('deltaLabel is null rather than +0 when nothing moved', () {
      expect(point(delta: 0).deltaLabel, isNull);
      expect(point(delta: null).deltaLabel, isNull);
      expect(point(rated: false, delta: 18).deltaLabel, isNull);
    });

    test('result predicates follow the parsed result string', () {
      expect(point(result: 'win').isWin, isTrue);
      expect(point(result: 'loss').isLoss, isTrue);
      expect(point(result: 'draw').isDraw, isTrue);
      expect(point(result: 'disputed').isWin, isFalse);
    });
  });
}
