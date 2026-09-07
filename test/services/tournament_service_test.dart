// TournamentService: the request shapes of Module 6, and the reason every refusal is
// forwarded word for word.
//
// This API's failures are rules, not faults. "Knockout needs a power of two: 2, 4, 8,
// 16 or 32", "the last spot went while you were deciding", "you are PKR 1,200 short"
// and "round 2 needs 4 hours and the venue has 3" are sentences somebody has to read
// to know what to do next, so every mutation returns the envelope untouched. The tests
// below therefore assert the message and the status code survive, not merely that the
// call reported failure.
//
// Three shapes are pinned because getting them wrong is silent rather than loud:
//
//   * `preview` is a POST that writes nothing. The quote depends on the whole draft —
//     format, both team counts, four percentages, the slot length and the deadline —
//     and a dozen fields in a query string would be worse than posting a read. It is
//     asserted as a POST with the draft in its body.
//   * `generate`'s `useModel` flag is what makes the scheduler's provenance stamp
//     mean something: the same tournament drawn both ways reports
//     `meta.scheduling.source` as `model` and `chronological`. The flag is always
//     sent, including when it is false, because absent would default to the model.
//   * `withdraw` is a DELETE carrying its team id in a BODY, since the route reads
//     `req.body.teamId`; a query string would leave the server withdrawing nothing.
//
// A walkover is deliberately not a 3-0. No game was played, so the fixture's K-factor
// is zero and no rating moves; recording it as a scoreline would hand the other side
// free rating points for a match that never happened. That is why `walkover` names a
// winner and carries no scores, and why it is a different route from `enterResult`.

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

  group('browse', () {
    test('the default read sends no filters at all', () async {
      api.ok({'tournaments': const []});
      await api.run(() => service.browse('JWT'));
      expect(api.endpoint(), '/tournaments');
      expect(api.only.url.hasQuery, isFalse);
    });

    test('every filter reaches the query string under its own name', () async {
      api.ok({'tournaments': const []});
      await api.run(() => service.browse(
            'JWT',
            sport: 'football',
            city: '  Lahore  ',
            startFrom: '2026-04-01',
            status: 'completed',
            q: '  ramadan cup  ',
            venueId: 'v1',
            ownerId: 'o1',
            openOnly: false,
            limit: 10,
          ));
      expect(api.query(), {
        'sport': 'football',
        'city': 'Lahore',
        'startFrom': '2026-04-01',
        'status': 'completed',
        'q': 'ramadan cup',
        'venueId': 'v1',
        'ownerId': 'o1',
        'openOnly': 'false',
        'limit': '10',
      });
    });

    // `openOnly` is a tri-state on this side: absent means "let the server default to
    // open", and false is a deliberate request for finished ones.
    test('openOnly false is sent, while an absent one is left to the server', () async {
      api.ok({'tournaments': const []});
      await api.run(() async {
        await service.browse('JWT', openOnly: false);
        await service.browse('JWT');
      });
      expect(api.query(0), {'openOnly': 'false'});
      expect(api.query(1), isEmpty);
    });

    test('blank and whitespace filters are dropped rather than sent empty', () async {
      api.ok({'tournaments': const []});
      await api.run(() => service.browse('JWT', sport: '', city: '   ', q: '  '));
      expect(api.only.url.hasQuery, isFalse);
    });

    test('rows are parsed with the nested venue and the money block', () async {
      api.ok({
        'tournaments': [
          {
            'id': 't1',
            'name': 'Ramadan Cup',
            'sport': 'football',
            'format': 'knockout',
            'status': 'open',
            'venue': {'id': 'v1', 'name': 'Arena One', 'city': 'Lahore'},
            'entryFee': '1500.00',
            'maxTeams': '8',
            'minTeams': '4',
            'teamsAccepted': '3',
            'spotsLeft': '5',
            'pool': '12000.00',
          },
        ],
      });
      final rows = await api.run(() => service.browse('JWT'));
      final t = rows.single;
      expect(t.name, 'Ramadan Cup');
      expect(t.venue.name, 'Arena One');
      expect(t.entryFee, 1500.0);
      expect(t.maxTeams, 8);
      expect(t.spotsLeft, 5);
      expect(t.pool, 12000.0);
    });


    test('a transport failure is an empty list rather than a throw', () async {
      api.offline();
      expect(await api.run(() => service.browse('JWT')), isEmpty);
    });

    // Pinned as it behaves, not as it should: `browse` hard-casts the `tournaments`
    // block, so a non-list there escapes as a `TypeError` past the service's own
    // never-throw contract. The rows inside are guarded by `whereType<Map>()`, the
    // container is not. Recorded so that adding the missing guard shows up here as a
    // failing expectation rather than passing unnoticed.
    test('a wrong-typed tournaments block escapes as a TypeError', () async {
      api.ok({'tournaments': 'not a list'});
      await expectLater(
        api.run(() => service.browse('JWT')),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('one tournament', () {
    test('the id is a path segment, not a filter', () async {
      api.ok(const {});
      await api.run(() => service.detail('JWT', 't1'));
      expect(api.endpoint(), '/tournaments/t1');
      expect(api.method(), 'GET');
    });

    test('a deleted id is the empty detail rather than a throw', () async {
      api.fail('Tournament not found.', status: 404);
      final d = await api.run(() => service.detail('JWT', 'gone'));
      expect(d.isEmpty, isTrue);
      expect(d.tournament, isNull);
      expect(d.counts.accepted, 0);
    });

    // `detailRaw` exists for the one screen that has to print the reason. The typed
    // form cannot: an empty detail and a refused one look identical to it.
    test('the raw form keeps the sentence the typed form discards', () async {
      api.fail('This tournament was cancelled.', status: 410);
      final r = await api.run(() => service.detailRaw('JWT', 't1'));
      expect(r['success'], isFalse);
      expect(r['message'], 'This tournament was cancelled.');
      expect(r['statusCode'], 410);
    });

    test('the payload is parsed into its four screens at once', () async {
      api.ok({
        'tournament': {'id': 't1', 'name': 'Ramadan Cup', 'status': 'ongoing'},
        'teams': [
          {'registrationId': 'r1', 'teamId': 'a', 'teamName': 'Alpha', 'status': 'accepted', 'seed': '1', 'paidAmount': '1500.00'},
          {'registrationId': 'r2', 'teamId': 'b', 'teamName': 'Bravo', 'status': 'withdrawn'},
        ],
        'counts': {'accepted': '1', 'withdrawn': '1', 'pending': '0'},
        'economics': {'pool': '3000.00', 'settled': true},
        'viewer': {
          'isCaptain': true,
          'myTeam': {'id': 'a', 'name': 'Alpha'},
          'walletBalance': '450.50',
          'canAfford': false,
        },
        'organiser': {'pendingApprovals': '2', 'canGenerate': false, 'unsettledFixtures': '0'},
      });
      final d = await api.run(() => service.detail('JWT', 't1'));
      expect(d.isEmpty, isFalse);
      expect(d.tournament!.name, 'Ramadan Cup');
      expect(d.teams.length, 2);
      expect(d.counts.accepted, 1);
      expect(d.economics.pool, 3000.0);
      expect(d.viewer.myTeamName, 'Alpha');
      expect(d.viewer.walletBalance, 450.5);
      expect(d.viewer.canAfford, isFalse);
      expect(d.organiser!.pendingApprovals, 2);
      expect(d.organiser!.hasWork, isTrue);
    });

    // The withdrawn row above reaches the organiser but must not be counted as part
    // of the field, or a half-empty tournament reads as full.
    test('a withdrawn entry is kept in teams but excluded from the field', () async {
      api.ok({
        'tournament': {'id': 't1'},
        'teams': [
          {'registrationId': 'r1', 'teamId': 'a', 'teamName': 'Alpha', 'status': 'accepted'},
          {'registrationId': 'r2', 'teamId': 'b', 'teamName': 'Bravo', 'status': 'withdrawn'},
          {'registrationId': 'r3', 'teamId': 'c', 'teamName': 'Cee', 'status': 'eliminated'},
        ],
      });
      final d = await api.run(() => service.detail('JWT', 't1'));
      expect(d.teams.length, 3);
      expect(d.field.map((t) => t.teamName), ['Alpha', 'Cee']);
    });

    // `organiser` absent is the signal, not a flag: it is how the detail screen knows
    // whether to draw the management panel at all.
    test('a viewer who does not own it gets no organiser block', () async {
      api.ok({
        'tournament': {'id': 't1'},
        'viewer': {'isOwner': false},
      });
      final d = await api.run(() => service.detail('JWT', 't1'));
      expect(d.organiser, isNull);
      expect(d.viewer.isOwner, isFalse);
    });
  });

  group('my tournaments', () {
    test('the limit is optional and omitted when absent', () async {
      api.ok(const {});
      await api.run(() async {
        await service.mine('JWT');
        await service.mine('JWT', limit: 5);
      });
      expect(api.endpoint(0), '/tournaments/mine');
      expect(api.query(0), isEmpty);
      expect(api.query(1), {'limit': '5'});
    });

    // Both roles arrive in one call because a user can organise one cup and play in
    // another, and the phone has a single tab for both.
    test('organising and playing are kept apart', () async {
      api.ok({
        'organising': [
          {'id': 't1', 'name': 'Ramadan Cup', 'status': 'open'},
        ],
        'playing': [
          {'id': 't2', 'name': 'Winter League', 'status': 'ongoing'},
          {'id': 't3', 'name': 'Summer Slam', 'status': 'completed'},
        ],
      });
      final m = await api.run(() => service.mine('JWT'));
      expect(m.organising.single.name, 'Ramadan Cup');
      expect(m.playing.map((t) => t.name), ['Winter League', 'Summer Slam']);
      expect(m.total, 3);
      expect(m.isEmpty, isFalse);
    });

    test('a failure is the empty pair, and it reports itself empty', () async {
      api.offline();
      final m = await api.run(() => service.mine('JWT'));
      expect(m.isEmpty, isTrue);
      expect(m.total, 0);
    });
  });

  group('the economics quote', () {
    test('the quote is a POST that writes nothing', () async {
      api.ok(const {});
      await api.run(() => service.previewRaw('JWT', venueId: 'v1'));
      expect(api.endpoint(), '/tournaments/preview');
      expect(api.method(), 'POST');
      expect(api.body(), {'venueId': 'v1'});
    });

    // The whole draft rides in the body. Eighteen fields would be unreadable in a
    // query string, and the ones the owner has not filled in yet must be absent so
    // the server applies its own defaults rather than receiving nulls.
    test('the whole draft is carried, and untouched fields are omitted', () async {
      api.ok(const {});
      await api.run(() => service.previewRaw(
            'JWT',
            venueId: 'v1',
            name: 'Ramadan Cup',
            description: 'Eight teams',
            format: 'knockout',
            maxTeams: 8,
            minTeams: 4,
            entryFee: 1500,
            prizePercent: 60,
            winnerPercent: 70,
            runnerupPercent: 30,
            venueDiscountPercent: 10,
            slotMinutes: 90,
            targetMarginPercent: 25,
            roundGapDays: 1,
            roundRestMinutes: 30,
            registrationDeadline: '2026-04-10',
            startDate: '2026-04-12',
            useModel: true,
          ));
      expect(api.body(), {
        'venueId': 'v1',
        'name': 'Ramadan Cup',
        'description': 'Eight teams',
        'format': 'knockout',
        'maxTeams': 8,
        'minTeams': 4,
        'entryFee': 1500,
        'prizePercent': 60,
        'winnerPercent': 70,
        'runnerupPercent': 30,
        'venueDiscountPercent': 10,
        'slotMinutes': 90,
        'targetMarginPercent': 25,
        'roundGapDays': 1,
        'roundRestMinutes': 30,
        'registrationDeadline': '2026-04-10',
        'startDate': '2026-04-12',
        'useModel': true,
      });
    });

    // A zero is a value, not an absence: `venueDiscountPercent: 0` means "no discount"
    // and `useModel: false` means "do not run the model". Both have to survive the
    // omission operator.
    test('a zero and a false are sent, not treated as unset', () async {
      api.ok(const {});
      await api.run(() => service.previewRaw(
            'JWT',
            venueId: 'v1',
            venueDiscountPercent: 0,
            prizePercent: 0,
            useModel: false,
          ));
      expect(api.body(), {
        'venueId': 'v1',
        'prizePercent': 0,
        'venueDiscountPercent': 0,
        'useModel': false,
      });
    });

    test('the typed quote reads both plans and the recommended fee', () async {
      api.ok({
        'venue': {'id': 'v1', 'name': 'Arena One'},
        'config': {'format': 'knockout', 'maxTeams': 8},
        'capacity': {
          'schedulable': true,
          'teams': '8',
          'fixtures': '7',
          'hoursNeeded': '11',
          'hoursAvailable': '14',
          'slotTotal': '9800.00',
        },
        'minimum': {'schedulable': true, 'teams': '4', 'fixtures': '3', 'slotTotal': '4200.00'},
        'economics': {
          'atCapacity': {'pool': '12000.00', 'ownerNet': '3400.00'},
          'atMinimum': {'pool': '6000.00', 'ownerNet': '900.00'},
        },
        'recommended': {'entryFee': '1600.00', 'minTeams': '4', 'venueCost': '4200.00', 'achievable': true},
        'candidateHours': '14',
        'meta': {
          'scheduling': {'source': 'model', 'modelVersion': 'demand-v1', 'coverage': '0.86', 'candidates': '14'},
        },
      });
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.venue.name, 'Arena One');
      expect(p.config['format'], 'knockout');
      expect(p.capacity.cost, 9800.0);
      expect(p.capacity.hoursLine, '11 hours needed · 14 open');
      expect(p.minimum.teams, 4);
      expect(p.atCapacity.pool, 12000.0);
      expect(p.atMinimum.pool, 6000.0);
      expect(p.recommended.entryFee, 1600.0);
      expect(p.candidateHours, 14);
      expect(p.canRun, isTrue);
      expect(p.blocker, isNull);
    });

    // The blocking condition is the worst legal turnout, not the full field: a
    // tournament that fits at four teams can run, capped, and the owner is told so
    // rather than blocked.
    test('a field that does not fit caps the tournament instead of blocking it', () async {
      api.ok({
        'capacity': {'schedulable': false, 'teams': '16', 'hoursNeeded': '20', 'hoursAvailable': '14'},
        'minimum': {'schedulable': true, 'teams': '4'},
        'candidateHours': '14',
      });
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.canRun, isTrue);
      expect(p.cappedByHours, isTrue);
      expect(p.blocker, isNull);
    });

    test('a venue with no open slots blocks with a sentence naming the fix', () async {
      api.ok({'candidateHours': '0', 'minimum': {'schedulable': false, 'teams': '4'}});
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.canRun, isFalse);
      expect(
        p.blocker,
        'This venue has no open slots in the scheduling window — add slots first',
      );
    });

    test('the server sentence is preferred over the generated one', () async {
      api.ok({
        'candidateHours': '9',
        'minimum': {
          'schedulable': false,
          'teams': '4',
          'message': 'Round 2 needs 4 hours and the venue has 3',
        },
      });
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.blocker, 'Round 2 needs 4 hours and the venue has 3');
    });

    test('an unschedulable minimum with no message falls back to team count', () async {
      api.ok({'candidateHours': '9', 'minimum': {'schedulable': false, 'teams': '4'}});
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.blocker, 'Not enough open hours at this venue for 4 teams');
    });
  });

  // The provenance stamp is the demo's evidence that the demand model ran. Both
  // labels have to be honest: claiming the model placed the fixtures when the breaker
  // was open is the one lie this block exists to prevent.
  group('scheduler provenance', () {
    test('a model-placed draw says so and names its version', () async {
      api.ok({
        'meta': {
          'scheduling': {'source': 'model', 'modelVersion': 'demand-v1', 'cached': true},
        },
      });
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.scheduling.fromModel, isTrue);
      expect(p.scheduling.modelVersion, 'demand-v1');
      expect(p.scheduling.cached, isTrue);
      expect(p.scheduling.label, "Placed in the venue's quietest hours by the demand model");
    });

    test('a fallback draw says date order and gives the reason', () async {
      api.ok({
        'meta': {
          'scheduling': {'source': 'chronological', 'reason': 'ml-service unreachable'},
        },
      });
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.scheduling.fromModel, isFalse);
      expect(p.scheduling.label, 'Placed in date order — ml-service unreachable');
    });

    // An absent block must not read as a model run. The default is the honest one.
    test('a missing scheduling block defaults to date order', () async {
      api.ok(const {});
      final p = await api.run(() => service.preview('JWT', venueId: 'v1'));
      expect(p!.scheduling.source, 'chronological');
      expect(p.scheduling.fromModel, isFalse);
      expect(p.scheduling.label, 'Placed in date order');
    });
  });

  group('a refused quote', () {
    // The typed form cannot carry a reason, which is why the create screen holds both:
    // null here means "read `previewRaw`'s message", not "an empty card".
    test('the typed form is null while the raw form keeps the sentence', () async {
      api.fail('Knockout needs a power of two: 2, 4, 8, 16 or 32', status: 400);
      expect(await api.run(() => service.preview('JWT', venueId: 'v1')), isNull);

      final raw = FakeApi()..fail('Knockout needs a power of two: 2, 4, 8, 16 or 32', status: 400);
      final r = await raw.run(() => service.previewRaw('JWT', venueId: 'v1'));
      expect(r['message'], 'Knockout needs a power of two: 2, 4, 8, 16 or 32');
      expect(r['statusCode'], 400);
    });

    test('a venue belonging to somebody else is a 404, not a quote', () async {
      api.fail('Venue not found.', status: 404);
      final r = await api.run(() => service.previewRaw('JWT', venueId: 'someone-elses'));
      expect(r['success'], isFalse);
      expect(r['statusCode'], 404);
    });

    test('a transport failure is a null quote rather than a throw', () async {
      api.offline();
      expect(await api.run(() => service.preview('JWT', venueId: 'v1')), isNull);
    });
  });
}
