// MatchService: the endpoints and bodies of the matchmaking surface, and the reason
// every failure is forwarded verbatim.
//
// This API's failures are rules rather than faults. "That slot already has a match
// on it", "the slot has not started yet" and "results are locked" are sentences a
// captain has to read to know what to do next, so the mutation half returns the
// envelope untouched and a generic message is never substituted. The read half
// answers a model or its empty sentinel, so a 403 on someone else's team renders as
// an empty list with `canChallenge: false` rather than a crash.
//
// Two request shapes are pinned because getting either wrong is silent. Scores are
// always challenger-first regardless of which captain is submitting — the dialog
// relabels them for the viewer, and sending them in the viewer's order would record
// a reversed result that both submissions would then agree on. And the match list
// filters on `team_id` while the pairing reads take `teamId`; the backend is the
// authority on each spelling, so both are asserted as sent.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/match_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late MatchService service;

  setUp(() {
    api = FakeApi();
    service = MatchService();
  });

  tearDown(resetApiClient);

  group('opponents', () {
    test('the team is a query parameter, not a path segment', () async {
      api.ok({'opponents': [], 'canChallenge': true, 'preferredBand': '150'});
      await api.run(() => service.opponents('JWT', 't1'));
      expect(api.endpoint(), '/matches/opponents?teamId=t1');
    });

    test('a search term is trimmed, and a blank one is dropped', () async {
      api.ok({'opponents': []});
      await api.run(() => service.opponents('JWT', 't1', q: '  beta '));
      expect(api.query(), {'teamId': 't1', 'q': 'beta'});

      final blank = FakeApi()..ok({'opponents': []});
      await blank.run(() => service.opponents('JWT', 't1', q: '   '));
      expect(blank.query(), {'teamId': 't1'});
    });

    test('candidates, the band and the ranking source are parsed', () async {
      api.ok({
        'canChallenge': true,
        'preferredBand': '150',
        'myRole': 'captain',
        'ranking': {'available': true, 'modelVersion': 'reco-rank-v1'},
        'opponents': [
          {'id': 't2', 'name': 'Beta', 'elo': '1210', 'eloGap': '30', 'matchPct': '72'},
          {'id': 't3', 'name': 'Gamma', 'elo': '1180', 'eloGap': '60'},
        ],
      });
      final list = await api.run(() => service.opponents('JWT', 't1'));
      expect(list.canChallenge, isTrue);
      expect(list.preferredBand, 150);
      expect(list.myRole, 'captain');
      expect(list.opponents.map((o) => o.team.name), ['Beta', 'Gamma']);
      expect(list.opponents.first.eloGap, 30);
      expect(list.opponents.first.matchPct, 72);
      expect(list.opponents.last.matchPct, isNull, reason: 'no score computed is not a zero score');
      expect(list.ranking.available, isTrue);
    });

    test('a 403 on another captain\'s team is the empty list, not a crash', () async {
      api.fail('You are not a captain of this team.', status: 403);
      final list = await api.run(() => service.opponents('JWT', 't-someone-elses'));
      expect(list.opponents, isEmpty);
      expect(list.canChallenge, isFalse);
    });

    test('a data block of the wrong type is the empty list', () async {
      api.ok([]);
      expect((await api.run(() => service.opponents('JWT', 't1'))).opponents, isEmpty);
    });
  });

  group('preview', () {
    test('both teams travel as camel-cased query parameters', () async {
      api.ok({});
      await api.run(() => service.previewRaw('JWT', challengerTeam: 't1', opponentTeam: 't2'));
      expect(api.endpoint(), '/matches/preview?challengerTeam=t1&opponentTeam=t2');
    });

    test('the raw form keeps the refusal so the screen can say why', () async {
      api.fail('These teams play different sports.', status: 400);
      final r = await api.run(
        () => service.previewRaw('JWT', challengerTeam: 't1', opponentTeam: 't2'),
      );
      expect(r['message'], 'These teams play different sports.');
    });

    test('the typed form is null for a refused pairing', () async {
      api.fail('That team is private.', status: 403);
      expect(
        await api.run(() => service.preview('JWT', challengerTeam: 't1', opponentTeam: 't2')),
        isNull,
      );
    });

    test('a pairing that works comes back parsed', () async {
      api.ok({
        'competitiveness': '78',
        'headToHead': {'played': '3', 'challengerWins': '2'},
        'sentence': 'An even contest on recent form.',
      });
      final preview = await api.run(
        () => service.preview('JWT', challengerTeam: 't1', opponentTeam: 't2'),
      );
      expect(preview, isNotNull);
      expect(preview!.competitiveness, 78);
    });
  });

  group('linkableBookings', () {
    test('the team is the only filter', () async {
      api.ok([]);
      await api.run(() => service.linkableBookings('JWT', 't1'));
      expect(api.endpoint(), '/matches/linkable-bookings?teamId=t1');
    });

    test('bookings come back typed', () async {
      api.ok([
        {'id': 'b1', 'venueName': 'Rai Arena', 'slotStart': '2026-03-14T18:00:00Z'},
      ]);
      final rows = await api.run(() => service.linkableBookings('JWT', 't1'));
      expect(rows.single.id, 'b1');
    });

    test('a failure is an empty list', () async {
      api.offline();
      expect(await api.run(() => service.linkableBookings('JWT', 't1')), isEmpty);
    });
  });

  group('center', () {
    test('the list filters on the snake-cased team id the SQL column uses', () async {
      api.ok({'teamId': 't1'});
      await api.run(() => service.center('JWT', 't1'));
      expect(api.endpoint(), '/matches?team_id=t1');
    });

    test('the server buckets the matches and the client keeps its buckets', () async {
      api.ok({
        'teamId': 't1',
        'myRole': 'captain',
        'disputeWindowHours': '24',
        'challenges': {
          'incoming': [
            {'id': 'm1', 'status': 'pending'},
          ],
          'outgoing': [
            {'id': 'm2', 'status': 'pending'},
          ],
        },
        'upcoming': [
          {'id': 'm3', 'status': 'accepted'},
        ],
        'history': [
          {'id': 'm4', 'status': 'verified'},
          {'id': 'm5', 'status': 'verified'},
        ],
      });
      final data = await api.run(() => service.center('JWT', 't1'));
      expect(data.teamId, 't1');
      expect(data.incoming.single.id, 'm1');
      expect(data.outgoing.single.id, 'm2');
      expect(data.upcoming.single.id, 'm3');
      expect(data.history.length, 2);
      expect(data.disputeWindowHours, 24);
    });

    test('a failure is the empty center', () async {
      api.fail('Something went wrong on the server.', status: 500);
      final data = await api.run(() => service.center('JWT', 't1'));
      expect(data.incoming, isEmpty);
      expect(data.history, isEmpty);
    });
  });

  group('detail and the owner queue', () {
    test('one match is addressed by id', () async {
      api.ok({'id': 'm1', 'status': 'accepted'});
      final match = await api.run(() => service.detail('JWT', 'm1'));
      expect(api.endpoint(), '/matches/m1');
      expect(match!.id, 'm1');
    });

    test('a match the caller may not see is null', () async {
      api.fail('That was not found on the server.', status: 404);
      expect(await api.run(() => service.detail('JWT', 'm1')), isNull);
    });

    test('the owner queue is a list, empty on failure', () async {
      api.ok([
        {'id': 'm1', 'status': 'awaiting_owner'},
        {'id': 'm2', 'status': 'awaiting_owner'},
      ]);
      final queue = await api.run(() => service.ownerPending('JWT'));
      expect(api.endpoint(), '/matches/owner/pending');
      expect(queue.map((m) => m.id), ['m1', 'm2']);

      final failing = FakeApi()..offline();
      expect(await failing.run(() => service.ownerPending('JWT')), isEmpty);
    });
  });

  group('mutations', () {
    test('a challenge names both teams and the booking it is pinned to', () async {
      api.ok(null, status: 201);
      await api.run(() => service.challenge(
            'JWT',
            challengerTeam: 't1',
            opponentTeam: 't2',
            bookingId: 'b1',
          ));
      expect(api.endpoint(), '/matches/challenge');
      expect(api.method(), 'POST');
      expect(api.body(), {'challengerTeam': 't1', 'opponentTeam': 't2', 'bookingId': 'b1'});
    });

    test('a taken slot comes back as the sentence the captain has to read', () async {
      api.fail('That slot already has a match on it.', status: 409);
      final r = await api.run(() => service.challenge(
            'JWT',
            challengerTeam: 't1',
            opponentTeam: 't2',
            bookingId: 'b1',
          ));
      expect(r['success'], isFalse);
      expect(r['message'], 'That slot already has a match on it.');
      expect(r['statusCode'], 409);
    });

    test('accepting and rejecting are the same route with a different action', () async {
      api.ok(null);
      await api.run(() async {
        await service.respond('JWT', 'm1', 'accept');
        await service.respond('JWT', 'm2', 'reject');
      });
      expect(api.method(0), 'PATCH');
      expect(api.endpoint(0), '/matches/m1/respond');
      expect(api.body(0), {'action': 'accept'});
      expect(api.endpoint(1), '/matches/m2/respond');
      expect(api.body(1), {'action': 'reject'});
    });

    test('scores go out challenger-first whichever captain is submitting', () async {
      api.ok(null, status: 201);
      await api.run(() => service.submitResult(
            'JWT',
            'm1',
            scoreChallenger: 2,
            scoreOpponent: 3,
            winnerTeam: 't2',
          ));
      expect(api.endpoint(), '/matches/m1/result');
      expect(api.body(), {'scoreChallenger': 2, 'scoreOpponent': 3, 'winnerTeam': 't2'});
    });

    test('a draw omits the winner rather than sending an empty one', () async {
      api.ok(null, status: 201);
      await api.run(
        () => service.submitResult('JWT', 'm1', scoreChallenger: 2, scoreOpponent: 2),
      );
      expect(api.body(), {'scoreChallenger': 2, 'scoreOpponent': 2});
    });

    test('a locked result is reported verbatim, not as a generic failure', () async {
      api.fail('Results are locked for this match.', status: 409);
      final r = await api.run(
        () => service.submitResult('JWT', 'm1', scoreChallenger: 1, scoreOpponent: 0),
      );
      expect(r['message'], 'Results are locked for this match.');
    });

    test('the owner verification carries no score of its own', () async {
      api.ok(null);
      await api.run(() => service.verify('JWT', 'm1'));
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/matches/m1/verify');
      expect(api.body(), isEmpty);
    });

    test('a dispute sends the reason an admin will act on', () async {
      api.ok(null, status: 201);
      await api.run(() => service.dispute('JWT', 'm1', 'The score was 3-2, not 2-3.'));
      expect(api.endpoint(), '/matches/m1/dispute');
      expect(api.body(), {'reason': 'The score was 3-2, not 2-3.'});
    });

    test('a dispute outside the window reads as the window, not an error', () async {
      api.fail('The 24 hour dispute window has closed.', status: 400);
      final r = await api.run(() => service.dispute('JWT', 'm1', 'wrong score'));
      expect(r['message'], 'The 24 hour dispute window has closed.');
    });
  });
}
