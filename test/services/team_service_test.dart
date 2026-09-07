// TeamService: the endpoints and bodies the teams surface sends, and the two places
// where a failure and an empty result must not look the same.
//
// [TeamService.rankings] and [TeamService.suggestedPlayers] answer null for a failed
// request and an empty model for a genuinely empty result, because the leaderboard
// and the suggestion rail show different sentences for the two — "could not load"
// invites a retry, "no ranked teams yet" invites a challenge. Collapsing them would
// show the wrong one every time the server is down, so both halves of that
// distinction are pinned here.
//
// The list reads are the opposite: they flatten a failure to an empty list on
// purpose, so a screen binds straight to the result. That is only safe while every
// one of those screens has its own error state, which is why the flattening is
// asserted rather than assumed.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/team_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late TeamService service;

  setUp(() {
    api = FakeApi();
    service = TeamService();
  });

  tearDown(resetApiClient);

  group('mine', () {
    test('parses the roster of teams and carries the token', () async {
      api.ok([
        {'id': 't1', 'name': 'Alpha', 'sport': 'futsal', 'elo': '1240', 'role': 'captain'},
        {'id': 't2', 'name': 'Beta', 'sport': 'cricket'},
      ]);
      final teams = await api.run(() => service.mine('JWT'));
      expect(api.endpoint(), '/teams/mine');
      expect(api.token(), 'JWT');
      expect(teams.map((t) => t.name), ['Alpha', 'Beta']);
      expect(teams.first.elo, 1240);
      expect(teams.first.amCaptain, isTrue);
    });

    test('flattens a failure to an empty list', () async {
      api.fail('Your session has expired. Please log in again.', status: 401);
      expect(await api.run(() => service.mine('STALE')), isEmpty);
    });

    test('flattens an unreachable server to an empty list', () async {
      api.offline();
      expect(await api.run(() => service.mine('JWT')), isEmpty);
    });

    test('a success with no data block is an empty list, not an error', () async {
      api.json({'success': true});
      expect(await api.run(() => service.mine('JWT')), isEmpty);
    });

    test('a non-map row is skipped rather than crashing the list', () async {
      api.ok([
        {'id': 't1', 'name': 'Alpha'},
        'not a team',
      ]);
      final teams = await api.run(() => service.mine('JWT'));
      expect(teams.single.id, 't1');
    });
  });

  group('rankings', () {
    test('a failure is null so the board can offer a retry', () async {
      api.fail('Something went wrong on the server.', status: 500);
      expect(await api.run(() => service.rankings('JWT')), isNull);
    });

    test('an unreachable server is null too', () async {
      api.offline();
      expect(await api.run(() => service.rankings('JWT')), isNull);
    });

    test('an empty board is an empty page, not null', () async {
      api.ok({'teams': [], 'cities': []});
      final page = await api.run(() => service.rankings('JWT'));
      expect(page, isNotNull);
      expect(page!.isEmpty, isTrue);
    });

    test('rows and chips come from the one response', () async {
      api.ok({
        'teams': [
          {'id': 't1', 'name': 'Alpha', 'elo': '1310'},
          {'id': 't2', 'name': 'Beta', 'elo': '1180'},
        ],
        'cities': [
          {'city': 'Lahore', 'count': '4'},
        ],
        'sport': 'futsal',
        'rankedMinMatches': '3',
      });
      final page = await api.run(() => service.rankings('JWT', sport: 'futsal'));
      expect(api.endpoint(), '/teams/rankings?sport=futsal');
      expect(page!.teams.length, 2);
      expect(page.cities.single.city, 'Lahore');
      expect(page.rankedMinMatches, 3);
    });

    test('a success with a data block of the wrong type still yields a page', () async {
      api.ok('not an object');
      final page = await api.run(() => service.rankings('JWT'));
      expect(page!.isEmpty, isTrue);
    });

    test('no filters means no query string at all', () async {
      api.ok({'teams': []});
      await api.run(() => service.rankings('JWT'));
      expect(api.endpoint(), '/teams/rankings');
    });

    test('a blank sport and a whitespace city are both dropped', () async {
      api.ok({'teams': []});
      await api.run(() => service.rankings('JWT', sport: '', city: '   '));
      expect(api.query(), isEmpty);
    });

    test('a city is trimmed before it reaches the query', () async {
      api.ok({'teams': []});
      await api.run(() => service.rankings('JWT', city: '  Lahore  '));
      expect(api.query(), {'city': 'Lahore'});
    });
  });

  group('discover', () {
    test('a trimmed search term and a sport travel together', () async {
      api.ok([]);
      await api.run(() => service.discover('JWT', q: '  alpha ', sport: 'futsal'));
      expect(api.endpoint(), '/teams/discover?q=alpha&sport=futsal');
    });

    test('a whitespace-only term is dropped rather than searched for', () async {
      api.ok([]);
      await api.run(() => service.discover('JWT', q: '   '));
      expect(api.query(), isEmpty);
    });

    test('results are typed teams', () async {
      api.ok([
        {'id': 't9', 'name': 'Gamma', 'visibility': 'private'},
      ]);
      final teams = await api.run(() => service.discover('JWT'));
      expect(teams.single.isPublic, isFalse);
    });
  });

  group('detail', () {
    test('forwards the whole envelope so a 403 stays distinguishable', () async {
      api.fail('This team is private.', status: 403);
      final r = await api.run(() => service.detail('JWT', 't1'));
      expect(api.endpoint(), '/teams/t1');
      expect(r['statusCode'], 403);
      expect(r['message'], 'This team is private.');
    });

    test('passes the nested stats and history blocks through untouched', () async {
      api.ok({
        'id': 't1',
        'stats': {'wins': '3'},
        'eloHistory': [
          {'elo': '1200'},
        ],
      });
      final r = await api.run(() => service.detail('JWT', 't1'));
      expect((r['data'] as Map)['stats'], {'wins': '3'});
      expect((r['data'] as Map)['eloHistory'], isA<List>());
    });
  });

  group('suggestedPlayers', () {
    test('a failure is null so the rail can offer a retry', () async {
      api.fail('You do not have permission to do that.', status: 403);
      expect(await api.run(() => service.suggestedPlayers('JWT', 't1')), isNull);
    });

    test('an empty pool is an empty model, not null', () async {
      api.ok({'team': {'id': 't1'}, 'suggestions': []});
      final s = await api.run(() => service.suggestedPlayers('JWT', 't1'));
      expect(api.endpoint(), '/teams/t1/suggested-players');
      expect(s, isNotNull);
      expect(s!.suggestions, isEmpty);
      expect(s.teamId, 't1');
    });
  });

  group('create and update', () {
    test('a public team is sent as a visibility, not a flag', () async {
      api.ok(null);
      await api.run(() => service.create('JWT', name: 'Alpha', sport: 'futsal', isPublic: true));
      expect(api.endpoint(), '/teams');
      expect(api.method(), 'POST');
      expect(api.body(), {'name': 'Alpha', 'sport': 'futsal', 'visibility': 'public'});
    });

    test('a private team sends the other visibility', () async {
      api.ok(null);
      await api.run(() => service.create('JWT', name: 'Alpha', sport: 'futsal', isPublic: false));
      expect(api.body()['visibility'], 'private');
    });

    test('an absent bio and logo are omitted rather than sent as null', () async {
      api.ok(null);
      await api.run(() => service.create('JWT', name: 'Alpha', sport: 'futsal', isPublic: true));
      expect(api.body().containsKey('bio'), isFalse);
      expect(api.body().containsKey('logo'), isFalse);
    });

    test('a bio and a logo are carried when given', () async {
      api.ok(null);
      await api.run(() => service.create(
            'JWT',
            name: 'Alpha',
            sport: 'futsal',
            isPublic: true,
            bio: 'Weekend squad',
            logo: 'data:image/png;base64,AAA',
          ));
      expect(api.body()['bio'], 'Weekend squad');
      expect(api.body()['logo'], 'data:image/png;base64,AAA');
    });

    test('an edit that changes nothing sends an empty patch', () async {
      api.ok(null);
      await api.run(() => service.update('JWT', 't1'));
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/teams/t1');
      expect(api.body(), isEmpty);
    });

    test('visibility appears only when the switch was actually moved', () async {
      api.ok(null);
      await api.run(() => service.update('JWT', 't1', city: 'Lahore'));
      expect(api.body().containsKey('visibility'), isFalse);
      expect(api.body()['city'], 'Lahore');
    });

    test('turning a team private patches the visibility', () async {
      api.ok(null);
      await api.run(() => service.update('JWT', 't1', isPublic: false));
      expect(api.body(), {'visibility': 'private'});
    });
  });

  group('invites', () {
    test('minting an invite with no note sends an empty body', () async {
      api.ok(null);
      await api.run(() => service.invite('JWT', 't1'));
      expect(api.endpoint(), '/teams/t1/invites');
      expect(api.method(), 'POST');
      expect(api.body(), isEmpty);
    });

    test('a note names the player the link was minted for', () async {
      api.ok(null);
      await api.run(() => service.invite('JWT', 't1', note: 'for Ayaan'));
      expect(api.body(), {'note': 'for Ayaan'});
    });

    test('the invite list is a plain read', () async {
      api.ok([]);
      await api.run(() => service.invitesList('JWT', 't1'));
      expect(api.method(), 'GET');
      expect(api.endpoint(), '/teams/t1/invites');
    });

    test('revoking one is a DELETE on the invite itself', () async {
      api.ok(null);
      await api.run(() => service.revokeInvite('JWT', 't1', 'i9'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/teams/t1/invites/i9');
    });

    test('previewing a link reads the public token route', () async {
      api.ok(null);
      await api.run(() => service.previewInvite('JWT', 'tok-abc'));
      expect(api.endpoint(), '/teams/invites/tok-abc');
    });

    test('joining posts the token in the path, not the body', () async {
      api.ok(null);
      await api.run(() => service.joinByToken('JWT', 'tok-abc'));
      expect(api.endpoint(), '/teams/join/tok-abc');
      expect(api.body(), isEmpty);
    });
  });

  group('join requests and membership', () {
    test('a join request with no message sends an empty body', () async {
      api.ok(null);
      await api.run(() => service.joinRequest('JWT', 't1'));
      expect(api.endpoint(), '/teams/t1/join-request');
      expect(api.body(), isEmpty);
    });

    test('an empty message is dropped rather than sent blank', () async {
      api.ok(null);
      await api.run(() => service.joinRequest('JWT', 't1', message: ''));
      expect(api.body(), isEmpty);
    });

    test('a message reaches the captain', () async {
      api.ok(null);
      await api.run(() => service.joinRequest('JWT', 't1', message: 'Keeper, free Sundays'));
      expect(api.body(), {'message': 'Keeper, free Sundays'});
    });

    test('the pending list is a read on the team', () async {
      api.ok([]);
      await api.run(() => service.requests('JWT', 't1'));
      expect(api.endpoint(), '/teams/t1/requests');
    });

    test('deciding a request patches the request itself', () async {
      api.ok(null);
      await api.run(() => service.decideRequest('JWT', 't1', 'r5', 'accept'));
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/teams/t1/requests/r5');
      expect(api.body(), {'action': 'accept'});
    });

    test('a role change patches the member', () async {
      api.ok(null);
      await api.run(() => service.memberAction('JWT', 't1', 'u7', 'vice_captain'));
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/teams/t1/members/u7');
      expect(api.body(), {'action': 'vice_captain'});
    });

    test('removing a member is the same route with a different action', () async {
      api.ok(null);
      await api.run(() => service.memberAction('JWT', 't1', 'u7', 'remove'));
      expect(api.body(), {'action': 'remove'});
    });

    test('leaving deletes the caller, addressed as me', () async {
      api.ok(null);
      await api.run(() => service.leave('JWT', 't1'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/teams/t1/members/me');
    });

    test('every mutation carries the bearer token', () async {
      api.ok(null);
      await api.run(() async {
        await service.create('JWT', name: 'A', sport: 'futsal', isPublic: true);
        await service.update('JWT', 't1', city: 'Lahore');
        await service.invite('JWT', 't1');
        await service.revokeInvite('JWT', 't1', 'i1');
        await service.joinRequest('JWT', 't1');
        await service.decideRequest('JWT', 't1', 'r1', 'accept');
        await service.memberAction('JWT', 't1', 'u1', 'remove');
        await service.leave('JWT', 't1');
      });
      expect(api.sent.length, 8);
      for (var i = 0; i < api.sent.length; i++) {
        expect(api.token(i), 'JWT', reason: 'request $i went out unauthenticated');
      }
    });
  });
}
