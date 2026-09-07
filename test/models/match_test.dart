// Unit tests for lib/models/match.dart.
//
// Two rules here have already been shipped wrong once and are cheap to pin. A match
// hangs off one of two anchors -- a booking for a friendly, a reserved fixture slot
// for a tournament -- and reading only `booking` made tournament fixtures claim they
// had no venue. Separately, ER2.1 makes a result submission one-shot, so the gate
// that offers the dialog has to close on four independent conditions.
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/match.dart';

Map<String, dynamic> side(String id) =>
    {'id': id, 'name': 'Team $id', 'elo': 1000};

MatchModel match({
  String status = MatchStatus.accepted,
  String? effectiveStatus,
  bool slotStarted = false,
  bool iSubmitted = false,
  String? myTeamId = 'a',
  Map<String, dynamic>? booking,
  Map<String, dynamic>? tournament,
}) =>
    MatchModel.fromJson({
      'id': 'm-1',
      'status': status,
      'effectiveStatus': effectiveStatus,
      'challenger': side('a'),
      'opponent': side('b'),
      'slotStarted': slotStarted,
      'iSubmitted': iSubmitted,
      'iAmChallenger': true,
      'myTeamId': myTeamId,
      'booking': booking,
      'tournament': tournament,
    });

void main() {
  group('MatchBooking.prettyTime', () {
    test('formats a wall-clock time column as 12-hour', () {
      expect(MatchBooking.prettyTime('20:00:00'), '8:00 PM');
      expect(MatchBooking.prettyTime('09:30:00'), '9:30 AM');
      expect(MatchBooking.prettyTime('18:45'), '6:45 PM');
    });

    test('handles both ends of the 12-hour wrap', () {
      expect(MatchBooking.prettyTime('12:00:00'), '12:00 PM');
      expect(MatchBooking.prettyTime('00:30:00'), '12:30 AM');
      expect(MatchBooking.prettyTime('00:00:00'), '12:00 AM');
      expect(MatchBooking.prettyTime('23:59:00'), '11:59 PM');
    });

    test('is empty for a missing time rather than printing a placeholder hour', () {
      expect(MatchBooking.prettyTime(null), '');
      expect(MatchBooking.prettyTime(''), '');
    });
  });

  group('where and when', () {
    final booking = {
      'id': 'b-1',
      'slotDate': '2026-09-05',
      'startTime': '20:00:00',
      'endTime': '21:00:00',
      'venueName': 'Arena One',
      'venueCity': 'Karachi',
    };
    final fixture = {
      'id': 'tr-1',
      'name': 'Ramadan Cup',
      'slotDate': '2026-09-06',
      'startTime': '17:00:00',
      'endTime': '18:00:00',
      'venueName': 'Pitch Two',
      'venueCity': 'Lahore',
      'round': 3,
      'label': 'Semi-final',
    };

    test('a friendly reads its venue and time off the booking', () {
      final m = match(booking: booking);
      expect(m.isTournamentMatch, isFalse);
      expect(m.venueName, 'Arena One');
      expect(m.venueCity, 'Karachi');
      expect(m.timeRange, '8:00 PM – 9:00 PM');
      expect(m.slotDateLabel, '5/9/2026');
      expect(m.hasNoSlot, isFalse);
    });

    // The regression: a fixture row was never missing, it was simply never a booking.
    test('a tournament fixture reads its own venue and time, not the booking', () {
      final m = match(tournament: fixture);
      expect(m.isTournamentMatch, isTrue);
      expect(m.venueName, 'Pitch Two');
      expect(m.timeRange, '5:00 PM – 6:00 PM');
      expect(m.slotDateLabel, '6/9/2026');
      expect(m.hasNoSlot, isFalse);
    });

    test('only a match with neither anchor counts as having no slot', () {
      final m = match();
      expect(m.venueName, isNull);
      expect(m.slotDate, isNull);
      expect(m.timeRange, '');
      expect(m.slotDateLabel, isNull);
      expect(m.hasNoSlot, isTrue);
    });
  });

  group('shownStatus', () {
    // A challenge past its deadline that the sweep has not reached yet must never
    // look answerable, so the server's computed status wins over the stored one.
    test('prefers the server-computed status over the stored one', () {
      final m = match(
        status: MatchStatus.challengeSent,
        effectiveStatus: MatchStatus.expired,
      );
      expect(m.shownStatus, MatchStatus.expired);
      expect(m.isPending, isFalse);
      expect(m.isDead, isTrue);
    });

    test('falls back to the stored status when none was computed', () {
      expect(match(status: MatchStatus.challengeSent).shownStatus,
          MatchStatus.challengeSent);
      expect(match(status: MatchStatus.challengeSent).isPending, isTrue);
    });

    test('accepted and awaiting_results are the same state to a screen', () {
      expect(match(status: MatchStatus.accepted).isAccepted, isTrue);
      expect(match(status: MatchStatus.awaitingResults).isAccepted, isTrue);
    });

    test('rejected and expired are both terminal', () {
      expect(match(status: MatchStatus.rejected).isDead, isTrue);
      expect(match(status: MatchStatus.expired).isDead, isTrue);
      expect(match(status: MatchStatus.completed).isDead, isFalse);
    });
  });

  group('canSubmitResult (ER2.1)', () {
    test('opens once the slot has started for a team in the match', () {
      expect(match(slotStarted: true).canSubmitResult, isTrue);
    });

    test('closes before kickoff', () {
      expect(match(slotStarted: false).canSubmitResult, isFalse);
    });

    test('closes for a viewer with no side, such as the venue owner', () {
      expect(match(slotStarted: true, myTeamId: null).canSubmitResult, isFalse);
    });

    test('a submission is one-shot, so having used it closes the gate', () {
      expect(match(slotStarted: true, iSubmitted: true).canSubmitResult, isFalse);
      expect(match(slotStarted: true, iSubmitted: true).waitingOnOpponent, isTrue);
    });

    test('closes in every state that is not accepted', () {
      for (final s in [
        MatchStatus.challengeSent,
        MatchStatus.awaitingOwner,
        MatchStatus.completed,
        MatchStatus.disputed,
        MatchStatus.expired,
      ]) {
        expect(match(status: s, slotStarted: true).canSubmitResult, isFalse,
            reason: 'must be closed in $s');
      }
    });
  });

  group('MatchTournament.stageLine', () {
    MatchTournament stage({String? name, int? round, String? label}) =>
        MatchTournament.fromJson(
            {'id': 't-1', 'name': name, 'round': round, 'label': label});

    test('joins the cup and the drawn stage label', () {
      expect(stage(name: 'Ramadan Cup', label: 'Semi-final').stageLine,
          'Ramadan Cup  ·  Semi-final');
    });

    test('falls back to the round number when the bracket has no labels', () {
      expect(stage(name: 'Ramadan Cup', round: 2).stageLine, 'Ramadan Cup  ·  Round 2');
    });

    test('prints the cup alone before the bracket is drawn', () {
      expect(stage(name: 'Ramadan Cup').stageLine, 'Ramadan Cup');
    });

    test('prints the stage alone when the cup has no name', () {
      expect(stage(label: 'Final').stageLine, 'Final');
      expect(stage().stageLine, '');
    });
  });

  group('MatchSubmission', () {
    test('accepts either key the API uses for the submitting team', () {
      expect(MatchSubmission.fromJson({'teamId': 'a'}).teamId, 'a');
      expect(MatchSubmission.fromJson({'submittedByTeam': 'b'}).teamId, 'b');
    });

    test('an unsubmitted side shows a dash rather than a zero score', () {
      expect(MatchSubmission.fromJson({'teamId': 'a'}).scoreline, '– – –');
      expect(
        MatchSubmission.fromJson(
            {'teamId': 'a', 'scoreChallenger': 2, 'scoreOpponent': 1}).scoreline,
        '2 – 1',
      );
    });
  });
}
