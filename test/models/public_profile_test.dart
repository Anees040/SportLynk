// PublicProfile / ProfileTeam model tests (module 8c — profile visibility).
//
// The parsing has two jobs the screen trusts it to get right: the visibility flags
// (`isPublic`, `isSelf`, and the derived `isDetailVisible`) that decide what renders,
// and the honest-number rule shared with every other model — a null trust stays null,
// a missing ELO takes the documented 1000 seed, and a null/absent list is empty
// rather than invented. Pure JSON in, so no widget binding is needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/public_profile.dart';

PublicProfile parse(Map<String, dynamic> j) =>
    PublicProfile.fromJson({'id': 'u1', 'name': 'Sara', ...j});

void main() {
  group('PublicProfile visibility', () {
    test('a public profile is detail-visible', () {
      final p = parse({'isPublic': true, 'isSelf': false});
      expect(p.isPublic, true);
      expect(p.isSelf, false);
      expect(p.isDetailVisible, true);
    });

    test('a private profile is not detail-visible to a stranger', () {
      final p = parse({'isPublic': false, 'isSelf': false});
      expect(p.isPublic, false);
      expect(p.isDetailVisible, false);
    });

    test('a private profile IS detail-visible to its owner (isSelf wins)', () {
      final p = parse({'isPublic': false, 'isSelf': true});
      expect(p.isPublic, false);
      expect(p.isSelf, true);
      expect(p.isDetailVisible, true);
    });

    test('a missing isPublic flag reads as private, not a crash', () {
      // The server always sends it; the model must still not treat absence as public.
      final p = parse({});
      expect(p.isPublic, false);
    });
  });

  group('PublicProfile honest numbers', () {
    test('a null trust stays null (never a fabricated zero)', () {
      final p = parse({'trustScore': null});
      expect(p.trustScore, isNull);
    });

    test('a pg-numeric-string trust is parsed', () {
      expect(parse({'trustScore': '88'}).trustScore, 88);
    });

    test('a missing ELO takes the documented 1000 seed', () {
      expect(parse({}).eloRating, 1000);
      expect(parse({'eloRating': '1180'}).eloRating, 1180);
    });

    test('a null sports list is empty, not invented', () {
      expect(parse({'sports': null}).sports, isEmpty);
      expect(parse({'sports': ['football', 'cricket']}).sports, ['football', 'cricket']);
    });
  });

  group('ProfileTeam', () {
    test('a record with no matches reads "No matches yet"', () {
      final t = ProfileTeam.fromJson({'id': 't1', 'name': 'Falcons', 'sport': 'football'});
      expect(t.played, 0);
      expect(t.record, 'No matches yet');
      expect(t.elo, isNull);
    });

    test('wins/losses/draws and a pg-string elo parse, and the record formats', () {
      final t = ProfileTeam.fromJson({
        'id': 't1', 'name': 'Falcons', 'sport': 'football',
        'elo': '1230', 'wins': 5, 'losses': 2, 'draws': 1,
      });
      expect(t.elo, 1230);
      expect(t.played, 8);
      expect(t.record, '5W · 2L · 1D');
    });

    test('teams parse from the profile payload', () {
      final p = parse({
        'isPublic': true,
        'teams': [
          {'id': 't1', 'name': 'Falcons', 'sport': 'football', 'role': 'captain', 'wins': 3},
        ],
      });
      expect(p.teams.length, 1);
      expect(p.teams.first.name, 'Falcons');
      expect(p.teams.first.role, 'captain');
      expect(p.teams.first.wins, 3);
    });
  });
}
