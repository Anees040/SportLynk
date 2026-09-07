// Recommender wire model tests.
//
// One rule governs this file, and most of the assertions below exist to hold it:
// a percentage is shown only when the ranking service produced it.
// `ranking.available == false` means "no percentages exist", not "show zero
// percent", and a null component means the input did not exist for that
// candidate rather than that the candidate scored nothing. Collapsing either
// distinction would have the UI state a number the server never computed.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/reco.dart';

void main() {
  group('ScoreComponent', () {
    test('known separates a measured block from an absent one', () {
      expect(const ScoreComponent(key: 'elo', value: 0.0, weight: 0.3).known, isTrue);
      expect(const ScoreComponent(key: 'elo', value: null, weight: 0.3).known, isFalse);
    });

    test('percent scales the 0..1 value and clamps out-of-range input', () {
      expect(const ScoreComponent(key: 'fit', value: 0.85, weight: 0.3).percent, 85);
      expect(const ScoreComponent(key: 'fit', value: 0, weight: 0.3).percent, 0);
      expect(const ScoreComponent(key: 'fit', value: 1, weight: 0.3).percent, 100);
      expect(const ScoreComponent(key: 'fit', value: 1.4, weight: 0.3).percent, 100);
      expect(const ScoreComponent(key: 'fit', value: -0.2, weight: 0.3).percent, 0);
    });

    test('an unknown block reports 0 percent but must be drawn as unknown', () {
      const c = ScoreComponent(key: 'fit', value: null, weight: 0.3);
      expect(c.percent, 0);
      expect(c.known, isFalse,
          reason: 'percent alone cannot tell the caller there was nothing to measure');
    });

    test('weightPercent is clamped the same way', () {
      expect(const ScoreComponent(key: 'fit', value: 1, weight: 0.35).weightPercent, 35);
      expect(const ScoreComponent(key: 'fit', value: 1, weight: 2).weightPercent, 100);
      expect(const ScoreComponent(key: 'fit', value: 1, weight: 0).weightPercent, 0);
    });

    test('contribution is null for an unknown block, not a substituted number', () {
      expect(
        const ScoreComponent(key: 'elo', value: 0.8, weight: 0.25).contribution,
        closeTo(0.2, 0.0001),
      );
      expect(const ScoreComponent(key: 'elo', value: null, weight: 0.25).contribution, isNull);
      expect(const ScoreComponent(key: 'elo', value: 0, weight: 0.25).contribution, 0);
    });

    test('every published key has a label, an explanation and an unknown note', () {
      for (final key in ['fit', 'elo', 'activity', 'zone', 'trust']) {
        final c = ScoreComponent(key: key, value: 0.5, weight: 0.2);
        expect(c.label, isNot(key), reason: '$key has no wording');
        expect(c.explain, isNotEmpty, reason: '$key has no explanation');
        expect(c.unknownNote, contains('not counted against them'),
            reason: '$key must say the gap was not held against the candidate');
      }
    });

    test('an unrecognised key degrades to the key itself rather than throwing', () {
      const c = ScoreComponent(key: 'novelty', value: 0.5, weight: 0.2);
      expect(c.label, 'novelty');
      expect(c.explain, '');
      expect(c.unknownNote, 'Not known — not counted against them');
    });

    test('the level block is worded to hold for both recommenders', () {
      const c = ScoreComponent(key: 'elo', value: 0.5, weight: 0.2);
      expect(c.label, 'Level match');
    });
  });

  group('RankingInfo', () {
    test('the pre-read default claims no scorer and no numbers', () {
      const r = RankingInfo.none;
      expect(r.source, 'unavailable');
      expect(r.available, isFalse);
      expect(r.label, 'Basic ordering');
      expect(r.weights, isEmpty);
      expect(r.componentOrder, isEmpty);
      expect(r.considered, isNull);
      expect(r.specTag, isNull);
    });

    test('available requires a literal true, so a truthy value cannot open the gate', () {
      expect(RankingInfo.fromJson({'available': true}).available, isTrue);
      expect(RankingInfo.fromJson({'available': 'true'}).available, isFalse);
      expect(RankingInfo.fromJson({'available': 1}).available, isFalse);
      expect(RankingInfo.fromJson({}).available, isFalse);
    });

    test('the attribution line never says AI, only which ordering ran', () {
      expect(RankingInfo.fromJson({'available': true}).label, 'SportLynk ranking');
      expect(RankingInfo.fromJson({'available': false}).label, 'Basic ordering');
    });

    test('weights parse from strings and drop unusable entries', () {
      final r = RankingInfo.fromJson({
        'weights': {'fit': 0.35, 'elo': '0.25', 'zone': null},
      });
      expect(r.weights['fit'], 0.35);
      expect(r.weights['elo'], 0.25);
      expect(r.weights.containsKey('zone'), isFalse);
    });

    test('a non-map weights block yields no weights rather than throwing', () {
      expect(RankingInfo.fromJson({'weights': 'none'}).weights, isEmpty);
      expect(RankingInfo.weightsFrom(null), isEmpty);
      expect(RankingInfo.weightsFrom(<String>['fit']), isEmpty);
    });

    test('the activity window defaults to 30 days', () {
      expect(RankingInfo.fromJson({}).activityWindowDays, 30);
      expect(RankingInfo.fromJson({'activityWindowDays': '14'}).activityWindowDays, 14);
    });

    test('considered stays null when the endpoint does not send it', () {
      expect(RankingInfo.fromJson({}).considered, isNull);
      expect(RankingInfo.fromJson({'considered': 0}).considered, 0);
      expect(RankingInfo.fromJson({'considered': '48'}).considered, 48);
    });

    test('specTag pairs the version with a short fingerprint', () {
      expect(
        RankingInfo.fromJson({
          'specVersion': 'reco-rank-v1',
          'specFingerprint': '1a6c5f39bf5a2c56',
        }).specTag,
        'reco-rank-v1 · 1a6c5f39',
      );
    });

    test('specTag degrades cleanly without a fingerprint or a version', () {
      expect(RankingInfo.fromJson({'specVersion': 'reco-rank-v1'}).specTag, 'reco-rank-v1');
      expect(RankingInfo.fromJson({'specFingerprint': 'abc'}).specTag, isNull);
      expect(
        RankingInfo.fromJson({'specVersion': 'v1', 'specFingerprint': 'abc'}).specTag,
        'v1 · abc',
        reason: 'a fingerprint shorter than the cut is kept whole, not padded',
      );
    });
  });

  group('RankingInfo.componentsFrom', () {
    test('a null block stays null, which is what hides the breakdown row', () {
      expect(RankingInfo.componentsFrom(null), isNull);
      expect(RankingInfo.componentsFrom('none'), isNull);
      expect(RankingInfo.componentsFrom(<String, dynamic>{}), isNull);
    });

    test('a component present as null is preserved, not dropped', () {
      final c = RankingInfo.componentsFrom({'fit': 0.9, 'elo': null});
      expect(c, isNotNull);
      expect(c!.containsKey('elo'), isTrue);
      expect(c['elo'], isNull);
      expect(c['fit'], 0.9);
    });

    test('string values are parsed', () {
      expect(RankingInfo.componentsFrom({'fit': '0.9'})!['fit'], 0.9);
    });
  });

  group('RankingInfo.breakdown', () {
    const ranking = RankingInfo(
      source: 'ranked',
      available: true,
      weights: {'fit': 0.35, 'elo': 0.25, 'zone': 0.2},
      componentOrder: ['fit', 'elo', 'zone'],
    );

    test('nothing to explain yields an empty list, not blank bars', () {
      expect(ranking.breakdown(null), isEmpty);
      expect(ranking.breakdown(const {}), isEmpty);
      expect(RankingInfo.none.breakdown(const {'fit': 0.9}), isNotEmpty,
          reason: 'the fallback path can still carry components if the server sent them');
    });

    test('rows follow the published order, not the map order', () {
      final rows = ranking.breakdown(const {'zone': 0.4, 'fit': 0.9, 'elo': 0.7});
      expect(rows.map((r) => r.key).toList(), ['fit', 'elo', 'zone']);
    });

    test('a key the candidate has no value for is skipped', () {
      final rows = ranking.breakdown(const {'fit': 0.9, 'zone': 0.4});
      expect(rows.map((r) => r.key).toList(), ['fit', 'zone']);
    });

    test('each row carries its own weight from the spec', () {
      final rows = ranking.breakdown(const {'fit': 0.9});
      expect(rows.single.weight, 0.35);
      expect(rows.single.weightPercent, 35);
    });

    test('a component missing from the published order is dropped entirely', () {
      expect(ranking.breakdown(const {'trust': 0.9}), isEmpty,
          reason: 'a block the server scores but does not list has no row to draw');
    });

    test('a component in the order but not the weights contributes nothing', () {
      const r = RankingInfo(
        source: 'ranked',
        available: true,
        weights: {'fit': 0.35},
        componentOrder: ['fit', 'trust'],
      );
      final rows = r.breakdown(const {'fit': 0.9, 'trust': 0.8});
      expect(rows.map((c) => c.key).toList(), ['fit', 'trust']);
      expect(rows.last.weight, 0);
      expect(rows.last.contribution, 0);
      expect(rows.last.weightPercent, 0);
    });

    test('without a published order the map order is used', () {
      const r = RankingInfo(source: 'ranked', available: true, weights: {'fit': 0.5});
      final rows = r.breakdown(const {'fit': 0.9, 'elo': 0.7});
      expect(rows.map((k) => k.key).toList(), ['fit', 'elo']);
    });

    test('an unknown component becomes a row that reports itself unknown', () {
      final rows = ranking.breakdown(const {'fit': null});
      expect(rows.single.known, isFalse);
      expect(rows.single.contribution, isNull);
    });
  });

  group('PlayerSuggestion', () {
    PlayerSuggestion player(Map<String, dynamic> j) =>
        PlayerSuggestion.fromJson({'userId': 'u1', 'name': 'Ali Raza', ...j});

    test('defaults keep an unscored candidate renderable', () {
      final p = PlayerSuggestion.fromJson({'userId': 'u1'});
      expect(p.name, 'Player');
      expect(p.sports, isEmpty);
      expect(p.bookingsLast30d, 0);
      expect(p.hasHomeArea, isFalse);
      expect(p.matchPct, isNull);
      expect(p.score, isNull);
      expect(p.components, isNull);
      expect(p.reasons, isEmpty);
    });

    test('matchPct is null on the fallback path so no number is drawn', () {
      expect(player({}).matchPct, isNull);
      expect(player({'matchPct': 0}).matchPct, 0,
          reason: 'a scored zero is a real result and must be distinguishable');
      expect(player({'matchPct': '73'}).matchPct, 73);
    });

    test('the initial is the first letter, ignoring leading space', () {
      expect(player({'name': 'Ali Raza'}).initial, 'A');
      expect(player({'name': '  ali'}).initial, 'A');
      expect(player({'name': ''}).initial, '?');
    });

    test('sportsLabel names an unfilled profile rather than showing nothing', () {
      expect(player({'sports': []}).sportsLabel, 'No sports listed');
      expect(player({}).sportsLabel, 'No sports listed');
      expect(player({'sports': ['Football']}).sportsLabel, 'Football');
      expect(player({'sports': ['Football', 'Cricket']}).sportsLabel, 'Football · Cricket');
    });

    test('the sports list is trimmed and blank entries dropped', () {
      expect(player({'sports': ['  Football  ', '', '   ', 'Cricket']}).sports,
          ['Football', 'Cricket']);
    });

    test('activityLabel pluralises and names the empty case', () {
      expect(player({'bookingsLast30d': 0}).activityLabel, 'No recent bookings');
      expect(player({'bookingsLast30d': 1}).activityLabel, '1 booking · 30d');
      expect(player({'bookingsLast30d': 5}).activityLabel, '5 bookings · 30d');
      expect(player({'bookingsLast30d': '12'}).activityLabel, '12 bookings · 30d');
    });

    test('eloSourceNote says which input the level bar was measured from', () {
      expect(
        player({'eloSource': 'team_elo'}).eloSourceNote,
        'Level taken from the rating of the team they play for',
      );
      expect(
        player({'eloSource': 'trust_proxy'}).eloSourceNote,
        'No team yet — their trust score stood in for a rating',
      );
    });

    test('an absent or unrecognised elo source adds no footnote', () {
      expect(player({}).eloSourceNote, isNull);
      expect(player({'eloSource': 'something_new'}).eloSourceNote, isNull);
    });

    test('hasHomeArea requires a literal true', () {
      expect(player({'hasHomeArea': true}).hasHomeArea, isTrue);
      expect(player({'hasHomeArea': 'true'}).hasHomeArea, isFalse);
    });

    test('components preserve a null block for the breakdown to explain', () {
      final p = player({'components': {'fit': 0.9, 'elo': null}});
      expect(p.components, isNotNull);
      expect(p.components!['elo'], isNull);
      expect(p.components!.containsKey('elo'), isTrue);
    });

    test('trust fields stay null rather than reading as an unrated zero', () {
      final p = player({});
      expect(p.trustScore, isNull);
      expect(p.trustBand, isNull);
      expect(p.trustLabel, isNull);
      expect(player({'trustScore': '72', 'trustBand': 'high'}).trustScore, 72);
    });
  });

  group('SuggestedPlayers', () {
    test('the pre-read default is empty and claims no ranking', () {
      const s = SuggestedPlayers.empty;
      expect(s.isEmpty, isTrue);
      expect(s.suggestions, isEmpty);
      expect(s.ranking.available, isFalse);
      expect(s.teamId, isNull);
    });

    test('the team block is read out of its nested object', () {
      final s = SuggestedPlayers.fromJson({
        'team': {'id': 't1', 'sport': 'football', 'city': 'Lahore', 'homeCity': 'Lahore'},
      });
      expect(s.teamId, 't1');
      expect(s.sport, 'football');
      expect(s.city, 'Lahore');
      expect(s.homeCity, 'Lahore');
    });

    test('a missing or non-map team block leaves the context null', () {
      expect(SuggestedPlayers.fromJson({}).teamId, isNull);
      expect(SuggestedPlayers.fromJson({'team': 't1'}).teamId, isNull);
    });

    test('the ranking block falls back to none rather than null', () {
      expect(SuggestedPlayers.fromJson({}).ranking.available, isFalse);
      expect(SuggestedPlayers.fromJson({'ranking': 'x'}).ranking.source, 'unavailable');
      expect(
        SuggestedPlayers.fromJson({'ranking': {'source': 'ranked', 'available': true}})
            .ranking
            .available,
        isTrue,
      );
    });

    test('rows are parsed and non-map entries skipped', () {
      final s = SuggestedPlayers.fromJson({
        'suggestions': [
          {'userId': 'u1', 'name': 'Ali'},
          'garbage',
          {'userId': 'u2'},
        ],
      });
      expect(s.suggestions.length, 2);
      expect(s.isEmpty, isFalse);
      expect(s.suggestions.last.name, 'Player');
    });
  });
}
