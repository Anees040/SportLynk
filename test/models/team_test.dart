// Team and roster model tests.
//
// `lib/models/team.dart` carries its own `asNum` rather than importing
// `lib/utils/num_util.dart`, and the two are not equivalent: this one parses with
// `num.tryParse` and so rejects the thousands separators and currency prefixes
// the shared helper strips. The tests below pin the behaviour the teams layer
// actually depends on, and record the divergence.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/team.dart';

Team team(Map<String, dynamic> j) => Team.fromJson({'id': 't1', ...j});

void main() {
  group('asNum', () {
    test('real numbers pass through untouched', () {
      expect(asNum(1240), 1240);
      expect(asNum(12.5), 12.5);
      expect(asNum(0), 0);
    });

    test('pg numeric strings are parsed', () {
      expect(asNum('1240'), 1240);
      expect(asNum('1000.00'), 1000.0);
      expect(asNum('-3'), -3);
    });

    test('unparseable input takes the fallback', () {
      expect(asNum(null), 0);
      expect(asNum(''), 0);
      expect(asNum('unrated'), 0);
      expect(asNum(null, 1000), 1000);
      expect(asNum('n/a', 1000), 1000);
    });

    test('separators are not stripped here, unlike num_util.asNum', () {
      expect(asNum('1,240'), 0);
      expect(asNum('PKR 1200'), 0);
    });
  });

  group('TeamMember', () {
    test('the roster role ladder, distinct from the chat role', () {
      TeamMember member(String role) =>
          TeamMember.fromJson({'id': 'u1', 'role': role});
      expect(member('captain').isCaptain, isTrue);
      expect(member('captain').isAdmin, isTrue);
      expect(member('vice_captain').isViceCaptain, isTrue);
      expect(member('vice_captain').isAdmin, isTrue);
      expect(member('vice_captain').isCaptain, isFalse);
      expect(member('member').isAdmin, isFalse);
      expect(member('admin').isAdmin, isFalse,
          reason: 'admin is the chat role; the team ladder does not use it');
    });

    test('the id falls back to user_id, which is what a join sends', () {
      expect(TeamMember.fromJson({'user_id': 'u9'}).id, 'u9');
      expect(TeamMember.fromJson({'id': 'u1', 'user_id': 'u9'}).id, 'u1');
    });

    test('a partial row still renders', () {
      final m = TeamMember.fromJson({'id': 'u1'});
      expect(m.name, 'Player');
      expect(m.role, 'member');
      expect(m.elo, 0);
      expect(m.trustScore, 0);
      expect(m.joinedAt, isNull);
      expect(m.lastSeenAt, isNull);
    });

    test('string-typed elo and trust score are parsed', () {
      final m = TeamMember.fromJson({
        'id': 'u1',
        'player_elo': '1085',
        'trust_score': '4.50',
      });
      expect(m.elo, 1085);
      expect(m.trustScore, 4.5);
    });
  });

  group('Team record arithmetic', () {
    test('winRate reads 0 before a team has played, never NaN', () {
      final fresh = team({});
      expect(fresh.played, 0);
      expect(fresh.winRate, 0);
    });

    test('winRate is a rounded percentage of games with a result', () {
      expect(team({'wins': 2, 'losses': 1, 'draws': 0}).winRate, 67);
      expect(team({'wins': 1, 'losses': 2, 'draws': 0}).winRate, 33);
      expect(team({'wins': 5, 'losses': 5, 'draws': 0}).winRate, 50);
      expect(team({'wins': 3, 'losses': 0, 'draws': 0}).winRate, 100);
    });

    test('draws count towards games played but not towards wins', () {
      final t = team({'wins': 1, 'losses': 1, 'draws': 2});
      expect(t.played, 4);
      expect(t.winRate, 25);
    });

    test('string-typed counters from pg are parsed before the arithmetic', () {
      final t = team({'wins': '2', 'losses': '1', 'draws': '0'});
      expect(t.played, 3);
      expect(t.winRate, 67);
    });
  });

  group('Team.fromJson', () {
    test('an absent elo seeds at 1000, not 0', () {
      expect(team({}).elo, 1000);
      expect(team({'elo': '1085'}).elo, 1085);
      expect(team({'elo': 0}).elo, 0,
          reason: 'an explicit zero is a value, not an absence');
    });

    test('defaults keep a partial row renderable', () {
      final t = team({});
      expect(t.name, 'Team');
      expect(t.sport, '');
      expect(t.visibility, 'public');
      expect(t.isPublic, isTrue);
      expect(t.roster, isEmpty);
      expect(t.memberCount, 0);
      expect(t.createdAt, isNull);
    });

    test('the channel id arrives under either key depending on the route', () {
      expect(team({'channel_id': 'c1'}).channelId, 'c1',
          reason: 'GET /mine sends snake case');
      expect(team({'channelId': 'c2'}).channelId, 'c2',
          reason: 'POST / and GET /:id send camel case');
      expect(team({}).channelId, isNull);
    });

    test('my role in the team drives the two permission getters', () {
      expect(team({'role': 'captain'}).amCaptain, isTrue);
      expect(team({'role': 'captain'}).amAdmin, isTrue);
      expect(team({'role': 'vice_captain'}).amAdmin, isTrue);
      expect(team({'role': 'vice_captain'}).amCaptain, isFalse);
      expect(team({'role': 'member'}).amAdmin, isFalse);
      expect(team({}).amAdmin, isFalse,
          reason: 'a team listed without a role is one I do not belong to');
    });

    test('visibility other than public is private', () {
      expect(team({'visibility': 'private'}).isPublic, isFalse);
      expect(team({'visibility': 'invite_only'}).isPublic, isFalse);
    });

    test('the roster is parsed and non-map entries are skipped', () {
      final t = team({
        'roster': [
          {'id': 'u1', 'role': 'captain'},
          {'user_id': 'u2'},
          'garbage',
          null,
        ]
      });
      expect(t.roster.length, 2);
      expect(t.roster.first.isCaptain, isTrue);
      expect(t.roster.last.id, 'u2');
    });

    test('tournament counters are whole numbers even from decimal strings', () {
      final t = team({
        'tournament_played': '4',
        'tournament_wins': '9',
        'finals_reached': '2.0',
        'titles': 1,
      });
      expect(t.tournamentPlayed, 4);
      expect(t.tournamentWins, 9);
      expect(t.finalsReached, 2);
      expect(t.titles, 1);
    });

    test('absent tournament counters read as zero, not as unknown', () {
      final t = team({});
      expect(t.tournamentPlayed, 0);
      expect(t.tournamentWins, 0);
      expect(t.finalsReached, 0);
      expect(t.titles, 0);
    });

    test('createdAt is parsed to local time when present', () {
      final t = team({'created_at': '2026-03-01T10:00:00.000Z'});
      expect(t.createdAt, isNotNull);
      expect(t.createdAt!.isUtc, isFalse);
    });
  });
}
