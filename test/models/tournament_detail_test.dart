// Tournament detail payload tests: the viewer's permissions, the organiser's panel,
// and the one payload that four screens read.
//
// The rule this file holds is that a flag may only ever *withhold* an action. Entry
// is authorised server-side inside a locked transaction, so a stale
// `canRegister: true` costs a readable error message; a stale `canWithdraw: true`
// would offer to spend a team's frozen fee. Every boolean therefore requires a
// literal `true`, and [TournamentViewer.canWithdraw] is derived from the entry's own
// state rather than trusted from the wire.
//
// The second rule is that the public field is who holds a spot.
// [TournamentDetail.field] filters the roster, because withdrawn and rejected rows
// reach the organiser only and printing them would misreport how many teams are in.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/tournament.dart';

void main() {
  group('EligibleTeam', () {
    test('the rating arrives as a pg string and defaults to the ladder floor', () {
      final t = EligibleTeam.fromJson({'id': 't1', 'name': 'Alpha', 'elo': '1240'});
      expect(t.elo, 1240);
      expect(t.name, 'Alpha');
      expect(EligibleTeam.fromJson({'id': 't1'}).elo, 1000);
      expect(EligibleTeam.fromJson({'id': 't1'}).name, 'Team');
      expect(EligibleTeam.fromJson({'id': 't1'}).logoUrl, isNull);
    });
  });

  group('TournamentViewer', () {
    test('the pre-read default permits nothing', () {
      const v = TournamentViewer.none;
      expect(v.isOwner, isFalse);
      expect(v.isCaptain, isFalse);
      expect(v.canRegister, isFalse);
      expect(v.isEntered, isFalse);
      expect(v.canWithdraw, isFalse);
      expect(v.myTeamId, isNull);
      expect(v.eligibleTeams, isEmpty);
      expect(v.walletBalance, isNull);
      expect(v.canAfford, isNull);
    });

    test('every permission flag requires a literal true', () {
      TournamentViewer v(Map<String, dynamic> j) => TournamentViewer.fromJson(j);
      expect(v({'canRegister': 'true'}).canRegister, isFalse);
      expect(v({'canRegister': 1}).canRegister, isFalse);
      expect(v({'canRegister': true}).canRegister, isTrue);
      expect(v({'isOwner': 'true'}).isOwner, isFalse);
      expect(v({'isCaptain': 'true'}).isCaptain, isFalse);
    });

    test('canAfford is a tri-state, since an unread wallet is not an empty one', () {
      expect(TournamentViewer.fromJson({}).canAfford, isNull);
      expect(TournamentViewer.fromJson({'canAfford': false}).canAfford, isFalse);
      expect(TournamentViewer.fromJson({'canAfford': true}).canAfford, isTrue);
      expect(TournamentViewer.fromJson({'canAfford': 'true'}).canAfford, isFalse);
    });

    test('my team is read out of its nested block', () {
      final v = TournamentViewer.fromJson({
        'myTeam': {'id': 't1', 'name': 'Alpha'},
        'walletBalance': '5400.00',
      });
      expect(v.myTeamId, 't1');
      expect(v.myTeamName, 'Alpha');
      expect(v.walletBalance, 5400.0);
    });

    test('a non-map team or entry block leaves the viewer unentered', () {
      final v = TournamentViewer.fromJson({'myTeam': 't1', 'myRegistration': 'r1'});
      expect(v.myTeamId, isNull);
      expect(v.myRegistration, isNull);
      expect(v.isEntered, isFalse);
    });

    test('an entered viewer carries the entry, and can withdraw while it holds', () {
      final v = TournamentViewer.fromJson({
        'myRegistration': {
          'registrationId': 'r1',
          'teamId': 't1',
          'status': 'accepted',
        },
      });
      expect(v.isEntered, isTrue);
      expect(v.canWithdraw, isTrue);
    });

    test('an awaiting-approval entry can still be withdrawn', () {
      final v = TournamentViewer.fromJson({
        'myRegistration': {'registrationId': 'r1', 'teamId': 't1', 'status': 'registered'},
      });
      expect(v.canWithdraw, isTrue);
    });

    test('a knocked-out or withdrawn entry cannot be withdrawn again', () {
      TournamentViewer v(String status) => TournamentViewer.fromJson({
            'myRegistration': {
              'registrationId': 'r1',
              'teamId': 't1',
              'status': status,
            },
          });
      expect(v('eliminated').canWithdraw, isFalse,
          reason: 'the fee is spent once the team has played');
      expect(v('withdrawn').canWithdraw, isFalse);
      expect(v('rejected').canWithdraw, isFalse);
      expect(v('eliminated').isEntered, isTrue,
          reason: 'a knocked-out team is still in the tournament it played');
    });

    test('the eligible squads are parsed and non-map entries skipped', () {
      final v = TournamentViewer.fromJson({
        'eligibleTeams': [
          {'id': 't1', 'name': 'Alpha'},
          'garbage',
          {'id': 't2'},
        ],
      });
      expect(v.eligibleTeams.length, 2);
      expect(v.eligibleTeams.last.name, 'Team');
    });
  });

  group('OrganiserView', () {
    test('a quiet panel has no work and offers nothing', () {
      const o = OrganiserView();
      expect(o.hasWork, isFalse);
      expect(o.canGenerate, isFalse);
      expect(o.canCancel, isFalse);
      expect(o.deadlinePassed, isFalse);
      expect(o.pendingApprovals, 0);
    });

    test('the counters arrive as pg strings', () {
      final o = OrganiserView.fromJson({
        'pendingApprovals': '3',
        'unsettledFixtures': '2',
        'canGenerate': true,
        'canCancel': true,
        'deadlinePassed': true,
      });
      expect(o.pendingApprovals, 3);
      expect(o.unsettledFixtures, 2);
      expect(o.hasWork, isTrue);
    });

    test('each of the three kinds of work counts on its own', () {
      expect(OrganiserView.fromJson({'pendingApprovals': 1}).hasWork, isTrue);
      expect(OrganiserView.fromJson({'canGenerate': true}).hasWork, isTrue);
      expect(OrganiserView.fromJson({'unsettledFixtures': 1}).hasWork, isTrue);
    });

    test('a cancellable tournament with nothing pending is not work', () {
      expect(OrganiserView.fromJson({'canCancel': true}).hasWork, isFalse,
          reason: 'being able to cancel is not a task the badge should nag about');
      expect(OrganiserView.fromJson({'deadlinePassed': true}).hasWork, isFalse);
    });

    test('every flag requires a literal true', () {
      expect(OrganiserView.fromJson({'canGenerate': 'true'}).canGenerate, isFalse);
      expect(OrganiserView.fromJson({'canCancel': 1}).canCancel, isFalse);
      expect(OrganiserView.fromJson({'deadlinePassed': 'yes'}).deadlinePassed, isFalse);
    });
  });

  group('TournamentCounts', () {
    test('the five counters arrive as pg strings', () {
      final c = TournamentCounts.fromJson({
        'holding': '6',
        'accepted': '4',
        'pending': '2',
        'withdrawn': '1',
        'rejected': '1',
      });
      expect(c.holding, 6);
      expect(c.accepted, 4);
      expect(c.pending, 2);
      expect(c.withdrawn, 1);
      expect(c.rejected, 1);
    });

    test('the zero constant counts nothing', () {
      expect(TournamentCounts.zero.holding, 0);
      expect(TournamentCounts.fromJson({}).holding, 0);
    });

    test('holding is the capacity number, not accepted', () {
      final c = TournamentCounts.fromJson({'holding': 6, 'accepted': 4, 'pending': 2});
      expect(c.holding, c.accepted + c.pending,
          reason: 'a frozen fee has already taken the spot');
    });
  });

  group('TournamentDetail', () {
    test('the pre-read default is empty and draws no panel', () {
      const d = TournamentDetail.empty;
      expect(d.isEmpty, isTrue);
      expect(d.tournament, isNull);
      expect(d.organiser, isNull);
      expect(d.teams, isEmpty);
      expect(d.field, isEmpty);
      expect(d.fixtures, isEmpty);
      expect(d.standings, isEmpty);
      expect(d.bracket.generated, isFalse);
      expect(d.counts.holding, 0);
      expect(d.economics.isProjection, isTrue);
      expect(d.viewer.canRegister, isFalse);
    });

    test('every nested block is read, and the tournament makes it non-empty', () {
      final d = TournamentDetail.fromJson({
        'tournament': {'id': 'tr1', 'name': 'Ramadan Cup'},
        'teams': [
          {'registrationId': 'r1', 'teamId': 't1', 'status': 'accepted'},
        ],
        'counts': {'holding': '1'},
        'bracket': {'generated': true, 'rounds': '2'},
        'fixtures': [
          {'id': 'f1'},
        ],
        'standings': [
          {'teamId': 't1'},
        ],
        'economics': {'settled': true},
        'viewer': {'isCaptain': true},
        'organiser': {'pendingApprovals': '1'},
      });
      expect(d.isEmpty, isFalse);
      expect(d.tournament!.name, 'Ramadan Cup');
      expect(d.counts.holding, 1);
      expect(d.bracket.rounds, 2);
      expect(d.fixtures.length, 1);
      expect(d.standings.length, 1);
      expect(d.economics.isProjection, isFalse);
      expect(d.viewer.isCaptain, isTrue);
      expect(d.organiser!.pendingApprovals, 1);
    });

    test('a non-map tournament or organiser block leaves both absent', () {
      final d = TournamentDetail.fromJson({'tournament': 'tr1', 'organiser': true});
      expect(d.isEmpty, isTrue);
      expect(d.organiser, isNull,
          reason: 'no management panel is drawn for a viewer who is not the organiser');
    });

    test('the public field is only the entries holding a spot', () {
      final d = TournamentDetail.fromJson({
        'teams': [
          {'registrationId': 'r1', 'teamId': 't1', 'status': 'accepted'},
          {'registrationId': 'r2', 'teamId': 't2', 'status': 'registered'},
          {'registrationId': 'r3', 'teamId': 't3', 'status': 'eliminated'},
          {'registrationId': 'r4', 'teamId': 't4', 'status': 'withdrawn'},
          {'registrationId': 'r5', 'teamId': 't5', 'status': 'rejected'},
        ],
      });
      expect(d.teams.length, 5, reason: 'the organiser still sees every row');
      expect(d.field.map((t) => t.teamId).toList(), ['t1', 't2', 't3']);
    });

    test('nextFixtureFor finds my next playable fixture, on either side', () {
      final d = TournamentDetail.fromJson({
        'fixtures': [
          {'id': 'f1', 'teamA': 't1', 'teamB': 't2', 'status': 'played'},
          {'id': 'f2', 'teamA': 't9', 'teamB': 't1'},
          {'id': 'f3', 'teamA': 't1', 'teamB': 't3'},
        ],
      });
      expect(d.nextFixtureFor('t1')!.id, 'f2');
      expect(d.nextFixtureFor('t3')!.id, 'f3');
    });

    test('a half-drawn or bye fixture is not offered as a next match', () {
      final d = TournamentDetail.fromJson({
        'fixtures': [
          {'id': 'f1', 'teamA': 't1', 'isBye': true},
          {'id': 'f2', 'teamA': 't1'},
        ],
      });
      expect(d.nextFixtureFor('t1'), isNull,
          reason: 'there is no opponent yet, so there is nothing to announce');
    });

    test('a viewer with no team, or no fixture of their own, gets nothing', () {
      final d = TournamentDetail.fromJson({
        'fixtures': [
          {'id': 'f1', 'teamA': 't1', 'teamB': 't2'},
        ],
      });
      expect(d.nextFixtureFor(null), isNull);
      expect(d.nextFixtureFor('t9'), isNull);
    });
  });

  group('MyTournaments', () {
    test('the empty constant reports both roles empty', () {
      const m = MyTournaments.empty;
      expect(m.isEmpty, isTrue);
      expect(m.total, 0);
      expect(m.organiserTodo, 0);
    });

    test('both roles are parsed, and the total spans them', () {
      final m = MyTournaments.fromJson({
        'organising': [
          {'id': 'tr1'},
          {'id': 'tr2'},
        ],
        'playing': [
          {'id': 'tr3'},
        ],
      });
      expect(m.organising.length, 2);
      expect(m.playing.length, 1);
      expect(m.total, 3);
      expect(m.isEmpty, isFalse);
    });

    test('playing alone is not empty, since a member is not an organiser', () {
      final m = MyTournaments.fromJson({
        'playing': [
          {'id': 'tr1'},
        ],
      });
      expect(m.isEmpty, isFalse);
      expect(m.organiserTodo, 0);
    });

    test('non-map entries are skipped rather than fatal', () {
      final m = MyTournaments.fromJson({
        'organising': [
          {'id': 'tr1'},
          'garbage',
        ],
      });
      expect(m.organising.length, 1);
    });

    test('the badge counts open tournaments with approvals waiting or a full field', () {
      final m = MyTournaments.fromJson({
        'organising': [
          {'id': 'tr1', 'status': 'open', 'teamsPending': '2'},
          {'id': 'tr2', 'status': 'open', 'isFull': true},
          {'id': 'tr3', 'status': 'open', 'spotsLeft': '3'},
        ],
      });
      expect(m.organiserTodo, 2);
    });

    test('a tournament already under way is not counted, whatever is pending', () {
      final m = MyTournaments.fromJson({
        'organising': [
          {'id': 'tr1', 'status': 'active', 'teamsPending': '2'},
          {'id': 'tr2', 'status': 'completed', 'isFull': true},
          {'id': 'tr3', 'status': 'cancelled', 'teamsPending': '5'},
        ],
      });
      expect(m.organiserTodo, 0,
          reason: 'the badge is about entries to decide, not about a running bracket');
    });

    test('fullness is the spots the server counted, not the capacity numbers', () {
      final m = MyTournaments.fromJson({
        'organising': [
          {'id': 'tr1', 'status': 'open', 'spotsLeft': '0'},
        ],
      });
      expect(m.organiserTodo, 1,
          reason: 'a full field is a bracket waiting to be drawn');

      final counted = MyTournaments.fromJson({
        'organising': [
          {'id': 'tr2', 'status': 'open', 'maxTeams': '4', 'teamsRegistered': '4'},
        ],
      });
      expect(counted.organiserTodo, 1,
          reason: 'an absent spotsLeft reads as none left, which the server always sends');
    });
  });
}
