// TournamentService, the write half: what each mutation puts on the wire, and why
// every refusal is forwarded rather than reduced to a boolean.
//
// These are money endpoints wearing list-edit clothes. `decide` refunds a held fee in
// the same transaction that rejects a team; `generate` releases every held fee, pays
// the venue cost and freezes the prize; `register` moves a captain's balance to frozen.
// None of them decides anything here — captaincy, ownership, wallet sufficiency and
// bracket state are all re-read server-side inside a locked transaction — so the
// assertions are about the request being exactly right and the refusal arriving whole.
//
// Two shapes are pinned because a wrong one is silent:
//
//   * `withdraw` is a DELETE that carries its team id in a BODY, because the route
//     reads `req.body.teamId`. Sent as a query string it would reach a handler that
//     withdraws nothing and still answers 200.
//   * `generate` always sends `useModel`, including when false. Omitted, the server
//     defaults to the model, so a demo asking for the chronological path would get
//     the model's placement stamped `chronological` by nothing at all.
//
// A walkover is deliberately not a 3-0. No game was played, so the fixture's K-factor
// is zero and no rating moves; a scoreline would hand the other side free rating
// points for a match that never happened. That is why it is a separate route from
// `enterResult` and why it carries a winner and no scores.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/tournament_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late TournamentService service;

  setUp(() {
    api = FakeApi();
    service = TournamentService();
  });

  tearDown(resetApiClient);

  group('creating a tournament', () {
    test('the five required fields are always sent', () async {
      api.ok(const {'id': 't1'}, status: 201);
      await api.run(() => service.create(
            'JWT',
            venueId: 'v1',
            name: 'Ramadan Cup',
            entryFee: 1500,
            maxTeams: 8,
            registrationDeadline: '2026-04-10',
          ));
      expect(api.endpoint(), '/tournaments');
      expect(api.method(), 'POST');
      expect(api.body(), {
        'venueId': 'v1',
        'name': 'Ramadan Cup',
        'entryFee': 1500,
        'maxTeams': 8,
        'registrationDeadline': '2026-04-10',
      });
    });

    test('the optional configuration is carried when the owner filled it in', () async {
      api.ok(const {'id': 't1'}, status: 201);
      await api.run(() => service.create(
            'JWT',
            venueId: 'v1',
            name: 'Ramadan Cup',
            entryFee: 1500,
            maxTeams: 8,
            registrationDeadline: '2026-04-10',
            description: '  Eight teams, knockout  ',
            sport: 'football',
            format: 'knockout',
            minTeams: 4,
            prizePercent: 60,
            winnerPercent: 70,
            runnerupPercent: 30,
            venueDiscountPercent: 10,
            slotMinutes: 90,
            startDate: '2026-04-12',
            requiresApproval: true,
          ));
      expect(api.body(), {
        'venueId': 'v1',
        'name': 'Ramadan Cup',
        'entryFee': 1500,
        'maxTeams': 8,
        'registrationDeadline': '2026-04-10',
        'description': 'Eight teams, knockout',
        'sport': 'football',
        'format': 'knockout',
        'minTeams': 4,
        'prizePercent': 60,
        'winnerPercent': 70,
        'runnerupPercent': 30,
        'venueDiscountPercent': 10,
        'slotMinutes': 90,
        'startDate': '2026-04-12',
        'requiresApproval': true,
      });
    });

    // A blank description and a blank start date are absences, not values: sent empty
    // they would overwrite the server's defaults with nothing.
    test('blank optional strings are dropped rather than sent empty', () async {
      api.ok(const {}, status: 201);
      await api.run(() => service.create(
            'JWT',
            venueId: 'v1',
            name: 'Cup',
            entryFee: 0,
            maxTeams: 4,
            registrationDeadline: '2026-04-10',
            description: '   ',
            sport: '',
            startDate: '',
          ));
      expect(api.body().keys, isNot(contains('description')));
      expect(api.body().keys, isNot(contains('sport')));
      expect(api.body().keys, isNot(contains('startDate')));
    });

    // A free tournament is a legal configuration, and `requiresApproval: false` is a
    // decision. Neither may be swallowed as "unset".
    test('a zero fee and a false approval flag are sent', () async {
      api.ok(const {}, status: 201);
      await api.run(() => service.create(
            'JWT',
            venueId: 'v1',
            name: 'Open Day',
            entryFee: 0,
            maxTeams: 4,
            registrationDeadline: '2026-04-10',
            requiresApproval: false,
          ));
      expect(api.body()['entryFee'], 0);
      expect(api.body()['requiresApproval'], false);
    });

    test('a bad team count is refused with the sentence naming the legal ones', () async {
      api.fail('Knockout needs a power of two: 2, 4, 8, 16 or 32', status: 400);
      final r = await api.run(() => service.create(
            'JWT',
            venueId: 'v1',
            name: 'Cup',
            entryFee: 100,
            maxTeams: 6,
            registrationDeadline: '2026-04-10',
          ));
      expect(r['success'], isFalse);
      expect(r['message'], 'Knockout needs a power of two: 2, 4, 8, 16 or 32');
      expect(r['statusCode'], 400);
    });

    // Ownership is re-checked server-side, and a venue belonging to somebody else is
    // indistinguishable from one that does not exist. That is the intended answer.
    test("another owner's venue reads as not found", () async {
      api.fail('Venue not found.', status: 404);
      final r = await api.run(() => service.create(
            'JWT',
            venueId: 'someone-elses',
            name: 'Cup',
            entryFee: 100,
            maxTeams: 8,
            registrationDeadline: '2026-04-10',
          ));
      expect(r['statusCode'], 404);
    });
  });

  group('deciding on an entered team', () {
    test('the tournament and the team are both path segments', () async {
      api.ok(const {});
      await api.run(() => service.decide('JWT', 't1', 'team-a', decision: 'approve'));
      expect(api.endpoint(), '/tournaments/t1/teams/team-a');
      expect(api.method(), 'PATCH');
      expect(api.body(), {'decision': 'approve'});
    });

    test('each of the three decisions is sent as given', () async {
      api.ok(const {});
      await api.run(() async {
        await service.decide('JWT', 't1', 'a', decision: 'approve');
        await service.decide('JWT', 't1', 'b', decision: 'reject');
        await service.decide('JWT', 't1', 'c', decision: 'remove');
      });
      expect(api.body(0)['decision'], 'approve');
      expect(api.body(1)['decision'], 'reject');
      expect(api.body(2)['decision'], 'remove');
    });

    // The reason reaches the captain in the refund notification, so a whitespace-only
    // one must not arrive as an empty explanation.
    test('a reason is trimmed, and a blank one is dropped', () async {
      api.ok(const {});
      await api.run(() async {
        await service.decide('JWT', 't1', 'a', decision: 'reject', reason: '  Squad too strong  ');
        await service.decide('JWT', 't1', 'b', decision: 'reject', reason: '   ');
      });
      expect(api.body(0), {'decision': 'reject', 'reason': 'Squad too strong'});
      expect(api.body(1), {'decision': 'reject'});
    });

    // This looks like a list edit and moves money: a reject refunds the held fee in the
    // same transaction, so the receipt has to reach the screen.
    test('the refund receipt is forwarded', () async {
      api.ok(const {'refunded': '1500.00', 'spotsLeft': 3});
      final r = await api.run(
          () => service.decide('JWT', 't1', 'a', decision: 'reject'));
      expect(r['success'], isTrue);
      expect((r['data'] as Map)['refunded'], '1500.00');
    });

    test('a decision after the draw is refused with its reason', () async {
      api.fail('The bracket is already drawn.', status: 409);
      final r = await api.run(
          () => service.decide('JWT', 't1', 'a', decision: 'remove'));
      expect(r['message'], 'The bracket is already drawn.');
      expect(r['statusCode'], 409);
    });
  });

  group('drawing the bracket', () {
    test('the draw defaults to the demand model', () async {
      api.ok(const {'fixtures': 7});
      await api.run(() => service.generate('JWT', 't1'));
      expect(api.endpoint(), '/tournaments/t1/generate');
      expect(api.method(), 'POST');
      expect(api.body(), {'useModel': true});
    });

    // The flag is always on the wire. Omitted, the server defaults to the model, so the
    // chronological path could not be requested at all.
    test('the chronological path is requested explicitly, not by omission', () async {
      api.ok(const {});
      await api.run(() => service.generate('JWT', 't1', useModel: false));
      expect(api.body(), {'useModel': false});
    });

    // The same tournament drawn both ways is what makes the provenance stamp evidence
    // rather than decoration.
    test('the two paths report different provenance', () async {
      api
        ..ok(const {
          'meta': {'scheduling': {'source': 'model'}},
        })
        ..ok(const {
          'meta': {'scheduling': {'source': 'chronological'}},
        });
      final both = await api.run(() async => [
            await service.generate('JWT', 't1'),
            await service.generate('JWT', 't1', useModel: false),
          ]);
      Map scheduling(Map<String, dynamic> r) =>
          ((r['data'] as Map)['meta'] as Map)['scheduling'] as Map;
      expect(scheduling(both[0])['source'], 'model');
      expect(scheduling(both[1])['source'], 'chronological');
    });

    test('too few teams is refused with the count', () async {
      api.fail('This tournament has 3 accepted teams and needs 4.', status: 409);
      final r = await api.run(() => service.generate('JWT', 't1'));
      expect(r['message'], 'This tournament has 3 accepted teams and needs 4.');
      expect(r['statusCode'], 409);
    });

    test('a venue short of hours is refused with the round that will not fit', () async {
      api.fail('Round 2 needs 4 hours and the venue has 3', status: 409);
      final r = await api.run(() => service.generate('JWT', 't1'));
      expect(r['message'], 'Round 2 needs 4 hours and the venue has 3');
    });

    test('a second draw is refused rather than redrawn', () async {
      api.fail('The bracket is already drawn.', status: 409);
      final r = await api.run(() => service.generate('JWT', 't1'));
      expect(r['success'], isFalse);
    });
  });

  group('settling a fixture', () {
    test('a score goes onto the fixture the organiser tapped', () async {
      api.ok(const {});
      await api.run(() => service.enterResult('JWT', 't1', 'f9', scoreA: 3, scoreB: 1));
      expect(api.endpoint(), '/tournaments/t1/fixtures/f9/result');
      expect(api.method(), 'PATCH');
      expect(api.body(), {'scoreA': 3, 'scoreB': 1});
    });

    // Scores are in the fixture's own A/B order, not the viewer's. A goalless draw is a
    // real result and both zeroes have to arrive.
    test('a nil-nil draw sends both zeroes', () async {
      api.ok(const {});
      await api.run(() => service.enterResult('JWT', 't1', 'f9', scoreA: 0, scoreB: 0));
      expect(api.body(), {'scoreA': 0, 'scoreB': 0});
    });

    // Both doors into the settle function are idempotent: the organiser typing a score
    // and a captain's submission the owner verified run the same Elo application.
    test('a fixture already settled is refused rather than settled twice', () async {
      api.fail('This fixture is already settled.', status: 409);
      final r = await api.run(
          () => service.enterResult('JWT', 't1', 'f9', scoreA: 3, scoreB: 1));
      expect(r['message'], 'This fixture is already settled.');
      expect(r['statusCode'], 409);
    });

    test('a fixture from another tournament is not found', () async {
      api.fail('Fixture not found.', status: 404);
      final r = await api.run(
          () => service.enterResult('JWT', 't1', 'elsewhere', scoreA: 1, scoreB: 0));
      expect(r['statusCode'], 404);
    });
  });

  group('a walkover', () {
    // The route is separate from `enterResult` and carries no scores at all: no game
    // was played, the K-factor is zero, and nobody's rating moves.
    test('a winner is named and no scoreline is invented', () async {
      api.ok(const {});
      await api.run(() =>
          service.walkover('JWT', 't1', 'f9', winnerTeamId: 'team-a'));
      expect(api.endpoint(), '/tournaments/t1/fixtures/f9/walkover');
      expect(api.method(), 'POST');
      expect(api.body(), {'winnerTeamId': 'team-a'});
      expect(api.body().keys, isNot(contains('scoreA')));
      expect(api.body().keys, isNot(contains('scoreB')));
    });

    test('a reason is trimmed, and a blank one is dropped', () async {
      api.ok(const {});
      await api.run(() async {
        await service.walkover('JWT', 't1', 'f9',
            winnerTeamId: 'team-a', reason: '  Bravo did not turn up  ');
        await service.walkover('JWT', 't1', 'f8', winnerTeamId: 'team-c', reason: '  ');
      });
      expect(api.body(0), {'winnerTeamId': 'team-a', 'reason': 'Bravo did not turn up'});
      expect(api.body(1), {'winnerTeamId': 'team-c'});
    });

    test('a winner who is not in the fixture is refused', () async {
      api.fail('That team is not in this fixture.', status: 400);
      final r = await api.run(
          () => service.walkover('JWT', 't1', 'f9', winnerTeamId: 'stranger'));
      expect(r['message'], 'That team is not in this fixture.');
      expect(r['statusCode'], 400);
    });
  });

  group('calling it off', () {
    test('a cancellation may carry no reason at all', () async {
      api.ok(const {});
      await api.run(() => service.cancel('JWT', 't1'));
      expect(api.endpoint(), '/tournaments/t1/cancel');
      expect(api.method(), 'POST');
      expect(api.body(), isEmpty);
    });

    test('a reason is trimmed, and a blank one leaves an empty body', () async {
      api.ok(const {});
      await api.run(() async {
        await service.cancel('JWT', 't1', reason: '  Pitch flooded  ');
        await service.cancel('JWT', 't2', reason: '   ');
      });
      expect(api.body(0), {'reason': 'Pitch flooded'});
      expect(api.body(1), isEmpty);
    });

    // Every held fee is refunded in the same transaction, so the count is the receipt
    // an owner needs to see.
    test('the refund count is forwarded', () async {
      api.ok(const {'refunded': 6, 'total': '9000.00'});
      final r = await api.run(() => service.cancel('JWT', 't1'));
      expect((r['data'] as Map)['refunded'], 6);
    });

    test('a cancellation after the draw is refused with its reason', () async {
      api.fail('The bracket is drawn; the venue hours are already paid for.', status: 409);
      final r = await api.run(() => service.cancel('JWT', 't1'));
      expect(r['message'], 'The bracket is drawn; the venue hours are already paid for.');
      expect(r['statusCode'], 409);
    });
  });

  group('a captain entering a team', () {
    test('the team rides in the body and the tournament in the path', () async {
      api.ok(const {}, status: 201);
      await api.run(() => service.register('JWT', 't1', teamId: 'team-a'));
      expect(api.endpoint(), '/tournaments/t1/register');
      expect(api.method(), 'POST');
      expect(api.body(), {'teamId': 'team-a'});
    });

    // The team is named by the client but the authority is not: `teams.captain_id` is
    // re-read inside the locked transaction, so somebody else's team id is a 403.
    test("another captain's team is refused, not entered", () async {
      api.fail('Only the captain can enter this team.', status: 403);
      final r = await api.run(() => service.register('JWT', 't1', teamId: 'not-mine'));
      expect(r['message'], 'Only the captain can enter this team.');
      expect(r['statusCode'], 403);
    });

    // The fee moves balance -> frozen, so the shortfall has to reach the captain as a
    // figure they can act on rather than a generic failure.
    test('an underfunded wallet is refused with the amount short', () async {
      api.fail('You are PKR 1,200 short of the entry fee.', status: 402);
      final r = await api.run(() => service.register('JWT', 't1', teamId: 'team-a'));
      expect(r['message'], 'You are PKR 1,200 short of the entry fee.');
      expect(r['statusCode'], 402);
    });

    // The capacity check is inside the transaction, which is why this is a race the
    // captain loses cleanly rather than a double entry.
    test('a tournament that filled while deciding is refused with that sentence', () async {
      api.fail('The last spot went while you were deciding.', status: 409);
      final r = await api.run(() => service.register('JWT', 't1', teamId: 'team-a'));
      expect(r['message'], 'The last spot went while you were deciding.');
      expect(r['statusCode'], 409);
    });

    test('a second entry for the same team is refused', () async {
      api.fail('This team is already entered.', status: 409);
      final r = await api.run(() => service.register('JWT', 't1', teamId: 'team-a'));
      expect(r['success'], isFalse);
    });

    test('a sport mismatch names both sports', () async {
      api.fail('This is a football tournament and Alpha plays cricket.', status: 400);
      final r = await api.run(() => service.register('JWT', 't1', teamId: 'team-a'));
      expect(r['message'], 'This is a football tournament and Alpha plays cricket.');
    });
  });

  group('a captain withdrawing', () {
    // A DELETE with a body, because the route reads `req.body.teamId`. Sent as a query
    // string it would reach a handler that withdraws nothing and still answers 200.
    test('the team id is carried in the body of a DELETE', () async {
      api.ok(const {});
      await api.run(() => service.withdraw('JWT', 't1', teamId: 'team-a'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/tournaments/t1/register');
      expect(api.body(), {'teamId': 'team-a'});
      expect(api.only.url.hasQuery, isFalse);
    });

    // Entry and withdrawal are the same path under two verbs, which is worth pinning:
    // a refactor that gave withdrawal its own route would pass every other assertion.
    test('withdrawal is the register path under a different verb', () async {
      api.ok(const {});
      await api.run(() async {
        await service.register('JWT', 't1', teamId: 'team-a');
        await service.withdraw('JWT', 't1', teamId: 'team-a');
      });
      expect(api.endpoint(0), api.endpoint(1));
      expect(api.method(0), 'POST');
      expect(api.method(1), 'DELETE');
    });

    test('the refund is forwarded', () async {
      api.ok(const {'refunded': '1500.00'});
      final r = await api.run(() => service.withdraw('JWT', 't1', teamId: 'team-a'));
      expect((r['data'] as Map)['refunded'], '1500.00');
    });

    // After the draw the fee has already paid for the venue's hours, so there is
    // nothing left to refund and the server says exactly that.
    test('withdrawal after the draw is refused with its reason', () async {
      api.fail('The bracket is drawn; the entry fee has already paid for the venue.',
          status: 409);
      final r = await api.run(() => service.withdraw('JWT', 't1', teamId: 'team-a'));
      expect(r['message'],
          'The bracket is drawn; the entry fee has already paid for the venue.');
      expect(r['statusCode'], 409);
    });

    test('a transport failure is a readable envelope, not a throw', () async {
      api.offline();
      final r = await api.run(() => service.withdraw('JWT', 't1', teamId: 'team-a'));
      expect(r['success'], isFalse);
      expect(r['message'], isA<String>());
    });
  });

  // Every mutation on this surface is authenticated. A route that lost its header would
  // read as "not the captain" or "not the owner" and be debugged as a permissions bug.
  test('every write carries the bearer token', () async {
    api.ok(const {});
    await api.run(() async {
      await service.create('JWT', venueId: 'v1', name: 'C', entryFee: 1,
          maxTeams: 4, registrationDeadline: '2026-04-10');
      await service.decide('JWT', 't1', 'a', decision: 'approve');
      await service.generate('JWT', 't1');
      await service.enterResult('JWT', 't1', 'f1', scoreA: 1, scoreB: 0);
      await service.walkover('JWT', 't1', 'f2', winnerTeamId: 'a');
      await service.cancel('JWT', 't1');
      await service.register('JWT', 't1', teamId: 'a');
      await service.withdraw('JWT', 't1', teamId: 'a');
    });
    expect(api.sent.length, 8);
    for (var i = 0; i < 8; i++) {
      expect(api.token(i), 'JWT', reason: 'request $i lost its Authorization header');
    }
  });
}
