// Admin dispute-queue and case-file model tests.
//
// A ruling moves rating points and can move money, so the rule this file holds is
// that the screen offers only what the server said it may: [DisputeCapabilities]
// decides which buttons exist, and no assertion here reconstructs that decision
// from the match. The second rule is that absence stays absent — a side that never
// filed a scoreline has a null submission rather than a 0–0 one, and an unrated
// player has a null trust score rather than a bad one, because both would read as
// evidence the admin does not actually have.
//
// Note that `_date` in this file's subject leaves timestamps in UTC: admin models
// parse and convert at the point of display, unlike the chat and team models.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/admin.dart';

void main() {
  group('DisputeTeam', () {
    test('a frozen rating is flagged, since a ruling on it moves no points', () {
      final t = DisputeTeam.fromJson({
        'id': 't1',
        'name': 'Islamabad United',
        'elo': '1240',
        'frozen': true,
        'raisedThis': true,
      });
      expect(t.elo, 1240);
      expect(t.frozen, isTrue);
      expect(t.raisedThis, isTrue);
    });

    test('both flags require a literal true', () {
      final t = DisputeTeam.fromJson({'frozen': 'true', 'raisedThis': 1});
      expect(t.frozen, isFalse);
      expect(t.raisedThis, isFalse);
    });

    test('an unnamed side is named rather than left blank, and starts at 1000', () {
      final t = DisputeTeam.fromJson({});
      expect(t.name, 'Unknown team');
      expect(t.elo, 1000);
      expect(t.id, '');
      expect(t.logoUrl, isNull);
    });
  });

  group('DisputeMatchInfo', () {
    test('resultsIn of one is the case with nothing to compare against', () {
      final m = DisputeMatchInfo.fromJson({
        'status': 'disputed',
        'sport': 'football',
        'resultsIn': 1,
        'scoreline': '3-1',
      });
      expect(m.resultsIn, 1);
      expect(m.eloApplied, isFalse);
      expect(m.winnerTeam, isNull);
    });

    test('an already-rated fixture carries both facts a ruling turns on', () {
      final m = DisputeMatchInfo.fromJson({
        'status': 'completed',
        'eloApplied': true,
        'isFixture': true,
        'tournamentId': 'tr1',
        'tournamentName': 'Ramadan Cup',
        'resultsIn': '2',
      });
      expect(m.eloApplied, isTrue);
      expect(m.isFixture, isTrue);
      expect(m.tournamentName, 'Ramadan Cup');
      expect(m.resultsIn, 2);
    });

    test('a missing status reads as unknown rather than as an empty pill', () {
      expect(DisputeMatchInfo.fromJson({}).status, 'unknown');
      expect(DisputeMatchInfo.fromJson({'status': '   '}).status, 'unknown');
    });
  });

  group('DisputeRow', () {
    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
          'id': 'd1',
          'matchId': 'm1',
          'status': 'open',
          'match': {'status': 'disputed'},
          'challenger': {'id': 't1', 'name': 'A'},
          'opponent': {'id': 't2', 'name': 'B'},
          ...extra,
        };

    test('the triage numbers are read from the server, never derived here', () {
      final d = DisputeRow.fromJson(row({
        'ageHours': '30',
        'severityElo': '32',
        'bothSidesDisputed': true,
        'reason': 'wrong scoreline',
        'createdAt': '2026-09-04T07:00:00Z',
      }));
      expect(d.ageHours, 30);
      expect(d.severityElo, 32);
      expect(d.bothSidesDisputed, isTrue);
      expect(d.isOpen, isTrue);
      expect(d.createdAt!.isUtc, isTrue,
          reason: 'admin timestamps are converted at display, not at parse');
    });

    test('ageLabel reads as triage, and rounds nothing away', () {
      expect(DisputeRow.fromJson(row({'ageHours': 0})).ageLabel, 'just now');
      expect(DisputeRow.fromJson(row({'ageHours': 3})).ageLabel, '3h');
      expect(DisputeRow.fromJson(row({'ageHours': 23})).ageLabel, '23h');
      expect(DisputeRow.fromJson(row({'ageHours': 24})).ageLabel, '1d');
      expect(DisputeRow.fromJson(row({'ageHours': 52})).ageLabel, '2d 4h');
    });

    test('an unruled dispute has no ruled scoreline at all, not a 0-0 one', () {
      final d = DisputeRow.fromJson(row());
      expect(d.ruling, isNull);
      expect(d.ruledScoreChallenger, isNull);
      expect(d.ruledScoreOpponent, isNull);
      expect(d.resolvedAt, isNull);
      expect(d.resolvedByName, isNull);
    });

    test('a ruled 0-0 draw is a real result and survives the null test', () {
      final d = DisputeRow.fromJson(row({
        'status': 'resolved',
        'ruling': 'rule_draw',
        'ruledScore': {'challenger': 0, 'opponent': 0},
        'resolvedByName': 'Admin',
      }));
      expect(d.isOpen, isFalse);
      expect(d.ruledScoreChallenger, 0);
      expect(d.ruledScoreOpponent, 0);
      expect(d.resolvedByName, 'Admin');
    });

    test('the nested blocks are lifted out of raisedBy for the queue row', () {
      final d = DisputeRow.fromJson(row({
        'raisedBy': {'teamName': 'A', 'captainName': 'Ali Raza'},
      }));
      expect(d.raisedByTeamName, 'A');
      expect(d.raisedByCaptainName, 'Ali Raza');
    });

    test('a missing status defaults to open, which is the only actionable one', () {
      expect(DisputeRow.fromJson({}).status, 'open');
      expect(DisputeRow.fromJson({}).isOpen, isTrue);
    });

    test('a row with no nested blocks still renders both sides', () {
      final d = DisputeRow.fromJson({'id': 'd1'});
      expect(d.challenger.name, 'Unknown team');
      expect(d.opponent.name, 'Unknown team');
      expect(d.match.status, 'unknown');
      expect(d.severityElo, 0);
    });
  });

  group('DisputeSubmission', () {
    test('a side that never filed keeps null scores, which is itself evidence', () {
      final s = DisputeSubmission.fromJson({'teamId': 't1', 'teamName': 'A'});
      expect(s.scoreChallenger, isNull);
      expect(s.scoreOpponent, isNull);
      expect(s.winnerTeam, isNull);
      expect(s.submittedAt, isNull);
    });

    test('a filed 0-0 is distinguishable from never having filed', () {
      final s = DisputeSubmission.fromJson({
        'teamId': 't1',
        'scoreChallenger': 0,
        'scoreOpponent': 0,
        'scoreline': '0-0',
        'submittedAt': '2026-09-04T07:00:00Z',
      });
      expect(s.scoreChallenger, 0);
      expect(s.scoreOpponent, 0);
      expect(s.scoreline, '0-0');
      expect(s.submittedAt, isNotNull);
    });
  });

  group('RosterMember', () {
    test('an unrated player keeps a null trust score, never a bad one', () {
      final m = RosterMember.fromJson({'userId': 'u1', 'name': 'Ali'});
      expect(m.trustScore, isNull);
      expect(m.role, 'member');
      expect(m.suspended, isFalse);
    });

    test('a rated zero is a real score and must not read as unrated', () {
      expect(RosterMember.fromJson({'trustScore': 0}).trustScore, 0.0);
      expect(RosterMember.fromJson({'trustScore': '72.5'}).trustScore, 72.5);
    });

    test('the two roles that can file a result are both named', () {
      expect(RosterMember.fromJson({'role': 'captain'}).isCaptain, isTrue);
      expect(RosterMember.fromJson({'role': 'vice_captain'}).isViceCaptain, isTrue);
      expect(RosterMember.fromJson({'role': 'member'}).isCaptain, isFalse);
    });

    test('an unnamed member is named rather than left blank', () {
      expect(RosterMember.fromJson({}).name, 'Unknown');
    });
  });

  group('CaseBooking', () {
    test('the check-in stamp is kept whole, and the date trimmed of its time', () {
      final b = CaseBooking.fromJson({
        'id': 'b1',
        'status': 'completed',
        'slotDate': '2026-09-04T00:00:00.000Z',
        'startTime': '18:00',
        'endTime': '19:00',
        'checkedInAt': '2026-09-04T13:02:00Z',
        'hadQr': true,
        'totalAmount': '2400.00',
        'depositAmount': '480.00',
        'venue': {'name': 'F-11 Arena', 'city': 'Islamabad'},
        'owner': {'name': 'Owner', 'phone': '+92300'},
      });
      expect(b.slotDate, '2026-09-04');
      expect(b.checkedInAt, isNotNull);
      expect(b.hadQr, isTrue);
      expect(b.totalAmount, 2400.0);
      expect(b.depositAmount, 480.0);
      expect(b.venueName, 'F-11 Arena');
      expect(b.ownerPhone, '+92300');
    });

    test('no check-in means the strongest evidence is simply absent', () {
      final b = CaseBooking.fromJson({'id': 'b1', 'status': 'cancelled'});
      expect(b.checkedInAt, isNull);
      expect(b.noShowAt, isNull);
      expect(b.hadQr, isFalse);
      expect(b.venueName, isNull);
      expect(b.totalAmount, 0);
    });
  });

  group('ArchiveMessage', () {
    test('a withdrawn message survives as a tombstone, not as a gap', () {
      final m = ArchiveMessage.fromJson({
        'id': 'msg1',
        'senderId': 'u1',
        'senderName': 'Ali',
        'teamId': 't1',
        'deleted': true,
        'createdAt': '2026-09-04T13:00:00Z',
      });
      expect(m.deleted, isTrue);
      expect(m.body, isNull);
      expect(m.senderName, 'Ali');
      expect(m.createdAt, isNotNull);
    });

    test('a system pill has no sender and belongs to no side', () {
      final m = ArchiveMessage.fromJson({
        'id': 'msg2',
        'system': true,
        'kind': 'system',
        'body': 'Result submitted',
      });
      expect(m.system, isTrue);
      expect(m.senderId, isNull);
      expect(m.teamId, isNull);
      expect(m.kind, 'system');
    });

    test('a plain line defaults to text and carries no media', () {
      final m = ArchiveMessage.fromJson({'id': 'msg3', 'body': 'we won 3-1'});
      expect(m.kind, 'text');
      expect(m.hasMedia, isFalse);
      expect(m.mediaMime, isNull);
      expect(m.deleted, isFalse);
    });
  });

  group('EloHistoryEntry', () {
    test('a movement already on the record is what makes a ruling a correction', () {
      final e = EloHistoryEntry.fromJson({
        'teamId': 't1',
        'teamName': 'A',
        'before': '1240',
        'after': '1272',
        'delta': '32',
        'kFactor': '32.0',
        'reason': 'match_result',
      });
      expect(e.before, 1240);
      expect(e.after, 1272);
      expect(e.delta, 32);
      expect(e.kFactor, 32.0);
      expect(e.reason, 'match_result');
    });

    test('a negative movement keeps its sign', () {
      expect(EloHistoryEntry.fromJson({'delta': -18}).delta, -18);
    });

    test('an entry with no numbers reads as unknown, not as a zero movement', () {
      final e = EloHistoryEntry.fromJson({'teamId': 't1'});
      expect(e.before, isNull);
      expect(e.after, isNull);
      expect(e.delta, isNull);
      expect(e.kFactor, 0);
    });
  });

  group('DisputeCapabilities', () {
    test('nothing is offered until the server says it may be', () {
      const c = DisputeCapabilities();
      expect(c.canRule, isFalse);
      expect(c.canChangeResult, isFalse);
      expect(c.correctionBlockedBy, isNull);
    });

    test('an unrated match can be ruled without a correction', () {
      final c = DisputeCapabilities.fromJson({'canRule': true});
      expect(c.needsCorrection, isFalse);
      expect(c.canChangeResult, isTrue);
    });

    test('a rated match can only be overturned where the correction exists', () {
      final blocked = DisputeCapabilities.fromJson({
        'canRule': true,
        'needsCorrection': true,
        'correctionAvailable': false,
        'correctionBlockedBy': 'migrations/023_elo_correction.sql',
      });
      expect(blocked.canChangeResult, isFalse,
          reason: 'a disabled button with a reason beats a submit that fails');
      expect(blocked.correctionBlockedBy, contains('023'));

      final open = DisputeCapabilities.fromJson({
        'canRule': true,
        'needsCorrection': true,
        'correctionAvailable': true,
      });
      expect(open.canChangeResult, isTrue);
    });

    test('a closed case can never be ruled, correction or not', () {
      final c = DisputeCapabilities.fromJson({
        'canRule': false,
        'needsCorrection': false,
        'correctionAvailable': true,
      });
      expect(c.canChangeResult, isFalse);
    });

    test('every flag requires a literal true', () {
      final c = DisputeCapabilities.fromJson({
        'canRule': 'true',
        'needsCorrection': 1,
        'correctionAvailable': 'yes',
      });
      expect(c.canRule, isFalse);
      expect(c.needsCorrection, isFalse);
      expect(c.correctionAvailable, isFalse);
    });
  });

  group('RelatedDispute', () {
    test('a sibling dispute is parsed as its own five keys, not as a queue row', () {
      final r = RelatedDispute.fromJson({
        'id': 'd2',
        'teamId': 't2',
        'teamName': 'B',
        'status': 'open',
        'reason': 'they left early',
      });
      expect(r.id, 'd2');
      expect(r.teamName, 'B');
      expect(r.status, 'open');
    });

    test('a missing status defaults to open', () {
      expect(RelatedDispute.fromJson({'id': 'd2'}).status, 'open');
      expect(RelatedDispute.fromJson({'id': 'd2'}).teamId, isNull);
    });
  });

  group('DisputeCase', () {
    Map<String, dynamic> file([Map<String, dynamic> extra = const {}]) => {
          'dispute': {
            'id': 'd1',
            'matchId': 'm1',
            'match': {'status': 'disputed'},
            'challenger': {'id': 't1', 'name': 'A'},
            'opponent': {'id': 't2', 'name': 'B'},
          },
          'capabilities': {'canRule': true},
          ...extra,
        };

    test('two conflicting scorelines are a different case from an agreed one', () {
      final c = DisputeCase.fromJson(file({
        'submissions': {
          'challenger': {'teamId': 't1', 'scoreChallenger': 3, 'scoreOpponent': 1},
          'opponent': {'teamId': 't2', 'scoreChallenger': 1, 'scoreOpponent': 3},
          'agree': false,
          'count': 2,
        },
      }));
      expect(c.submissionsAgree, isFalse);
      expect(c.submissionCount, 2);
      expect(c.challengerSubmission!.scoreChallenger, 3);
      expect(c.opponentSubmission!.scoreOpponent, 3);
    });

    test('a side that never filed has no submission object at all', () {
      final c = DisputeCase.fromJson(file({
        'submissions': {
          'challenger': {'teamId': 't1', 'scoreChallenger': 3, 'scoreOpponent': 1},
          'count': 1,
        },
      }));
      expect(c.challengerSubmission, isNotNull);
      expect(c.opponentSubmission, isNull);
      expect(c.submissionCount, 1);
    });

    test('rule-a-draw is offerable only when a drawn scoreline was filed', () {
      expect(DisputeCase.fromJson(file()).hasDrawnSubmission, isFalse);
      expect(
        DisputeCase.fromJson(file({
          'submissions': {
            'challenger': {'teamId': 't1', 'scoreChallenger': 3, 'scoreOpponent': 1},
          },
        })).hasDrawnSubmission,
        isFalse,
      );
      expect(
        DisputeCase.fromJson(file({
          'submissions': {
            'opponent': {'teamId': 't2', 'scoreChallenger': 2, 'scoreOpponent': 2},
          },
        })).hasDrawnSubmission,
        isTrue,
      );
    });

    test('a submission with no scores cannot pass as a drawn one', () {
      final c = DisputeCase.fromJson(file({
        'submissions': {
          'challenger': {'teamId': 't1'},
        },
      }));
      expect(c.hasDrawnSubmission, isFalse,
          reason: 'null equals null, and two absences are not a 0-0');
    });

    test('the chat archive is read out of its own block, truncation included', () {
      final c = DisputeCase.fromJson(file({
        'chat': {
          'channelId': 'ch1',
          'truncated': true,
          'messages': [
            {'id': 'msg1', 'body': 'we won'},
            'garbage',
          ],
        },
      }));
      expect(c.chatChannelId, 'ch1');
      expect(c.chatTruncated, isTrue);
      expect(c.chat.length, 1);
    });

    test('both rosters are read out of the rosters block', () {
      final c = DisputeCase.fromJson(file({
        'rosters': {
          'challenger': [
            {'userId': 'u1', 'name': 'Ali', 'role': 'captain'},
          ],
          'opponent': [
            {'userId': 'u2', 'name': 'Bilal'},
            {'userId': 'u3', 'name': 'Kamran'},
          ],
        },
      }));
      expect(c.challengerRoster.single.isCaptain, isTrue);
      expect(c.opponentRoster.length, 2);
    });

    test('a case with no booking, chat or history is still renderable', () {
      final c = DisputeCase.fromJson(file());
      expect(c.booking, isNull);
      expect(c.chat, isEmpty);
      expect(c.chatChannelId, isNull);
      expect(c.eloHistory, isEmpty);
      expect(c.otherDisputes, isEmpty);
      expect(c.challengerRoster, isEmpty);
      expect(c.submissionCount, 0);
      expect(c.capabilities.canRule, isTrue);
    });

    test('an empty payload yields a case that renders instead of throwing', () {
      final c = DisputeCase.fromJson({});
      expect(c.dispute.status, 'open');
      expect(c.capabilities.canRule, isFalse);
      expect(c.booking, isNull);
    });

    test('sibling disputes are listed so one ruling closes them visibly', () {
      final c = DisputeCase.fromJson(file({
        'otherDisputes': [
          {'id': 'd2', 'teamName': 'B', 'status': 'open'},
        ],
        'eloHistory': [
          {'teamId': 't1', 'delta': 32},
        ],
      }));
      expect(c.otherDisputes.single.id, 'd2');
      expect(c.eloHistory.single.delta, 32);
    });
  });
}
