// AdminService: the request shapes of the moderation surface, and the reason a
// write's envelope is forwarded rather than reduced to a boolean.
//
// Every decision on this surface belongs to the server. This class computes no
// severity, holds no copy of the settings catalogue and does not judge which ruling
// actions are legal, so the assertions here are about two things only: that the
// request carries exactly what the backend expects, and that a refusal arrives with
// the sentence the admin has to act on — a 409 `sport_has_bookings` naming the
// counts, a self-suspension refused, a ruling blocked because Elo is already
// applied. A screen that turned any of those into "Something went wrong" would
// leave an admin with no idea which of their inputs to change.
//
// Two pagination contracts are pinned because they differ. The dispute queue's
// `hasMore` is derived from the presence of a cursor, since the queue is ordered by
// what is at stake rather than by age and the cursor is the only thing that can
// continue it; the user list's `hasMore` is the server's own flag. A test that read
// them as the same field would pass while the disputes queue silently lost its last
// page.
//
// The cursor itself is opaque on purpose — a `"<severityElo>~<createdAt>~<id>"`
// triple — so it is asserted as round-tripped verbatim and never parsed.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/admin_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late AdminService service;

  setUp(() {
    api = FakeApi();
    service = AdminService();
  });

  tearDown(resetApiClient);

  group('the dispute queue', () {
    test('the default read asks for the open queue and a page size', () async {
      api.ok({'items': const []});
      await api.run(() => service.disputes('JWT'));
      expect(api.endpoint().split('?').first, '/admin/disputes');
      expect(api.query(), {'status': 'open', 'limit': '25'});
    });

    test('a status and a limit are sent as given', () async {
      api.ok({'items': const []});
      await api.run(() => service.disputes('JWT', status: 'resolved', limit: 50));
      expect(api.query(), {'status': 'resolved', 'limit': '50'});
    });

    test('an empty cursor is dropped rather than sent as a blank filter', () async {
      api.ok({'items': const []});
      await api.run(() => service.disputes('JWT', cursor: ''));
      expect(api.query().containsKey('cursor'), isFalse);
    });

    // The cursor is a severity/age/id triple the client is not allowed to
    // interpret; the only correct handling is to hand it back exactly as received.
    test('a cursor is round-tripped verbatim, separators and all', () async {
      api.ok({'items': const []});
      const cursor = '48~2026-03-14T18:30:00.000Z~d9';
      await api.run(() => service.disputes('JWT', cursor: cursor));
      expect(api.query()['cursor'], cursor);
    });

    test('rows are parsed with their nested match and both teams', () async {
      api.ok({
        'items': [
          {
            'id': 'd1',
            'matchId': 'm1',
            'status': 'open',
            'reason': 'The score was 3-2.',
            'ageHours': 30,
            'severityElo': 48,
            'bothSidesDisputed': true,
            'match': {'status': 'disputed', 'sport': 'football', 'eloApplied': true},
            'challenger': {'id': 't1', 'name': 'Alpha', 'elo': '1240'},
            'opponent': {'id': 't2', 'name': 'Bravo', 'elo': '1198'},
            'raisedBy': {'teamName': 'Alpha', 'captainName': 'Rana'},
          },
        ],
        'nextCursor': 'next',
      });
      final page = await api.run(() => service.disputes('JWT'));
      final row = page.items.single;
      expect(row.id, 'd1');
      expect(row.severityElo, 48);
      expect(row.bothSidesDisputed, isTrue);
      expect(row.challenger.name, 'Alpha');
      expect(row.opponent.elo, 1198);
      expect(row.match.eloApplied, isTrue);
      expect(row.raisedByCaptainName, 'Rana');
      expect(row.ageLabel, '1d 6h');
    });

    // The queue reports a count and a cursor but no `hasMore` flag, so "more" has
    // to be read from the cursor; taking the absent flag at face value would end
    // the list a page early.
    test('more pages are inferred from the cursor, not from a hasMore flag', () async {
      api.ok({'items': const [], 'nextCursor': 'c2', 'count': 40});
      final page = await api.run(() => service.disputes('JWT'));
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'c2');
    });

    test('the last page has no cursor and reports no more', () async {
      api.ok({'items': const [], 'nextCursor': null});
      final page = await api.run(() => service.disputes('JWT'));
      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
    });

    test('an empty cursor string is not a next page either', () async {
      api.ok({'items': const [], 'nextCursor': ''});
      expect((await api.run(() => service.disputes('JWT'))).hasMore, isFalse);
    });

    test('a failure is an empty page, never a throw', () async {
      api.fail('Admin only.', status: 403);
      final page = await api.run(() => service.disputes('JWT'));
      expect(page.isEmpty, isTrue);
      expect(page.hasMore, isFalse);
    });

    test('a wrong-typed data block is an empty page', () async {
      api.ok(const []);
      expect((await api.run(() => service.disputes('JWT'))).isEmpty, isTrue);
    });
  });

  group('the case file', () {
    test('the case is addressed by dispute id', () async {
      api.ok({'dispute': {'id': 'd1'}, 'capabilities': {'canRule': true}});
      final c = await api.run(() => service.disputeCase('JWT', 'd1'));
      expect(api.endpoint(), '/admin/disputes/d1');
      expect(c!.dispute.id, 'd1');
      expect(c.capabilities.canRule, isTrue);
    });

    // A side that never filed is evidence in itself, so the absent submission stays
    // null rather than being defaulted to 0-0.
    test('a side that never filed is null, not a nil scoreline', () async {
      api.ok({
        'dispute': {'id': 'd1'},
        'capabilities': const {},
        'submissions': {
          'challenger': {'teamId': 't1', 'scoreChallenger': 3, 'scoreOpponent': 2},
          'count': 1,
          'agree': false,
        },
      });
      final c = await api.run(() => service.disputeCase('JWT', 'd1'));
      expect(c!.challengerSubmission!.scoreChallenger, 3);
      expect(c.opponentSubmission, isNull);
      expect(c.submissionCount, 1);
      expect(c.submissionsAgree, isFalse);
    });

    test('the rosters, the booking, the archive and the Elo trail all come through', () async {
      api.ok({
        'dispute': {'id': 'd1'},
        'capabilities': const {},
        'rosters': {
          'challenger': [
            {'userId': 'u1', 'name': 'Rana', 'role': 'captain'},
          ],
          'opponent': [
            {'userId': 'u2', 'name': 'Bilal', 'role': 'member'},
          ],
        },
        'booking': {'id': 'b1', 'status': 'confirmed', 'totalAmount': '2500.00'},
        'chat': {
          'channelId': 'c1',
          'messages': [
            {'id': 'msg1', 'kind': 'text', 'body': 'we won 3-2'},
          ],
          'truncated': true,
        },
        'eloHistory': [
          {'teamId': 't1', 'before': 1240, 'after': 1256, 'delta': 16, 'kFactor': '32'},
        ],
      });
      final c = await api.run(() => service.disputeCase('JWT', 'd1'));
      expect(c!.challengerRoster.single.isCaptain, isTrue);
      expect(c.opponentRoster.single.name, 'Bilal');
      expect(c.booking!.totalAmount, 2500.0);
      expect(c.chatChannelId, 'c1');
      expect(c.chat.single.body, 'we won 3-2');
      expect(c.chatTruncated, isTrue);
      expect(c.eloHistory.single.delta, 16);
    });

    test('a case that cannot be loaded is null', () async {
      api.fail('That was not found on the server.', status: 404);
      expect(await api.run(() => service.disputeCase('JWT', 'd1')), isNull);
    });
  });

  group('ruling on a dispute', () {
    // The server adopts a team's own submission for the two `rule_*` team forms, so
    // sending scores with one would be the client deciding the result.
    test('ruling for a side sends the action alone', () async {
      api.ok(null);
      await api.run(() => service.ruleDispute('JWT', 'd1', action: 'rule_challenger'));
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/admin/disputes/d1');
      expect(api.body(), {'action': 'rule_challenger'});
    });

    test('a custom ruling carries both scores', () async {
      api.ok(null);
      await api.run(() => service.ruleDispute(
            'JWT',
            'd1',
            action: 'rule_custom',
            scoreChallenger: 3,
            scoreOpponent: 2,
            note: 'Owner confirmed the scoreline.',
          ));
      expect(api.body(), {
        'action': 'rule_custom',
        'scoreChallenger': 3,
        'scoreOpponent': 2,
        'note': 'Owner confirmed the scoreline.',
      });
    });

    test('a zero score is a score and is sent, unlike an absent one', () async {
      api.ok(null);
      await api.run(() => service.ruleDispute(
            'JWT',
            'd1',
            action: 'rule_custom',
            scoreChallenger: 0,
            scoreOpponent: 0,
          ));
      expect(api.body(), {'action': 'rule_custom', 'scoreChallenger': 0, 'scoreOpponent': 0});
    });

    test('a whitespace-only note is dropped and a real one is trimmed', () async {
      api.ok(null);
      await api.run(() async {
        await service.ruleDispute('JWT', 'd1', action: 'dismiss', note: '   ');
        await service.ruleDispute('JWT', 'd2', action: 'dismiss', note: '  no evidence  ');
      });
      expect(api.body(0), {'action': 'dismiss'});
      expect(api.body(1), {'action': 'dismiss', 'note': 'no evidence'});
    });

    test('a ruling blocked by an applied Elo exchange keeps the server sentence', () async {
      api.fail('Elo has already been applied for this match.', status: 409);
      final r = await api.run(() => service.ruleDispute('JWT', 'd1', action: 'rule_draw'));
      expect(r['success'], isFalse);
      expect(r['message'], 'Elo has already been applied for this match.');
      expect(r['statusCode'], 409);
    });
  });

  group('the user list', () {
    test('the default read asks for every status', () async {
      api.ok({'items': const []});
      await api.run(() => service.users('JWT'));
      expect(api.query(), {'status': 'all', 'limit': '25'});
    });

    test('a search term is trimmed and a blank one is not sent', () async {
      api.ok({'items': const []});
      await api.run(() async {
        await service.users('JWT', q: '  rana  ');
        await service.users('JWT', q: '   ');
      });
      expect(api.query(0)['q'], 'rana');
      expect(api.query(1).containsKey('q'), isFalse);
    });

    test('a role and a status narrow the same request', () async {
      api.ok({'items': const []});
      await api.run(() => service.users('JWT', role: 'owner', status: 'suspended'));
      expect(api.query(), {'status': 'suspended', 'limit': '25', 'role': 'owner'});
    });

    test('rows carry the suspension trail and the nested counts', () async {
      api.ok({
        'items': [
          {
            'id': 'u1',
            'name': 'Rana',
            'role': 'player',
            'suspended': true,
            'suspendedReason': 'Repeated no-shows.',
            'suspendedByName': 'Admin',
            'counts': {'bookings': '12', 'venues': '0'},
            'wallet': {'balance': '450.50', 'frozen': '100.00'},
          },
        ],
        'hasMore': true,
        'nextCursor': 'c2',
      });
      final page = await api.run(() => service.users('JWT'));
      final row = page.items.single;
      expect(row.suspended, isTrue);
      expect(row.suspendedReason, 'Repeated no-shows.');
      expect(row.bookings, 12);
      expect(row.walletBalance, 450.5);
      expect(row.walletFrozen, 100.0);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'c2');
    });

    // Unlike the dispute queue, this list ships its own flag, so a cursor without it
    // is not another page.
    test('this list trusts the server flag rather than the cursor', () async {
      api.ok({'items': const [], 'nextCursor': 'c2'});
      expect((await api.run(() => service.users('JWT'))).hasMore, isFalse);
    });

    test('a failure is an empty page', () async {
      api.offline();
      expect((await api.run(() => service.users('JWT'))).isEmpty, isTrue);
    });
  });

  group('suspend and reinstate', () {
    // The reason is shown to the suspended user in their notification, which is why
    // the server requires it and why it is trimmed rather than sent as typed.
    test('a suspension carries the trimmed reason the user will read', () async {
      api.ok(null);
      await api.run(
        () => service.suspend('JWT', 'u1', reason: '  Repeated no-shows.  '),
      );
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/admin/users/u1/suspend');
      expect(api.body(), {'reason': 'Repeated no-shows.'});
    });

    test('the cascade receipt comes back on the envelope', () async {
      api.ok({
        'cascade': {
          'bookingsCancelled': [
            {'id': 'b1'},
          ],
          'venuesDeactivated': [
            {'id': 'v1'},
          ],
        },
      });
      final r = await api.run(() => service.suspend('JWT', 'u1', reason: 'x'));
      expect(r['success'], isTrue);
      expect((r['data'] as Map)['cascade'], isA<Map>());
    });

    test('a refused self-suspension is reported as the server put it', () async {
      api.fail('An admin cannot suspend their own account.', status: 400);
      final r = await api.run(() => service.suspend('JWT', 'me', reason: 'x'));
      expect(r['message'], 'An admin cannot suspend their own account.');
    });

    test('reinstating without a note sends an empty body', () async {
      api.ok(null);
      await api.run(() => service.reinstate('JWT', 'u1'));
      expect(api.method(), 'PATCH');
      expect(api.endpoint(), '/admin/users/u1/reinstate');
      expect(api.body(), isEmpty);
    });

    test('a reinstatement note is trimmed, and a blank one is omitted', () async {
      api.ok(null);
      await api.run(() async {
        await service.reinstate('JWT', 'u1', note: '  appeal upheld  ');
        await service.reinstate('JWT', 'u2', note: '  ');
      });
      expect(api.body(0), {'note': 'appeal upheld'});
      expect(api.body(1), isEmpty);
    });
  });

  group('platform settings', () {
    test('the catalogue is rendered from the sections the server sends', () async {
      api.ok({
        'sections': [
          {
            'key': 'money',
            'label': 'Money',
            'fields': [
              {
                'key': 'commission_pct',
                'label': 'Commission',
                'type': 'number',
                'unit': '%',
                'min': 0,
                'max': 100,
                'step': 0.5,
                'pairsWith': 'deposit_pct',
                'value': 12.5,
                'default': 10,
                'isOverridden': true,
              },
            ],
          },
        ],
        'overrides': ['commission_pct'],
        'appliesImmediately': false,
        'cacheTtlSeconds': 120,
      });
      final catalog = await api.run(() => service.settings('JWT'));
      expect(api.endpoint(), '/admin/settings');
      final field = catalog.field('commission_pct')!;
      expect(field.unit, '%');
      expect(field.max, 100);
      expect(field.step, 0.5);
      expect(field.pairsWith, 'deposit_pct');
      expect(field.value, 12.5);
      expect(field.defaultValue, 10);
      expect(field.isOverridden, isTrue);
      expect(catalog.overrides, ['commission_pct']);
      expect(catalog.appliesImmediately, isFalse);
      expect(catalog.cacheTtlSeconds, 120);
    });

    test('a key the catalogue does not carry is null, not an invented field', () async {
      api.ok({'sections': const []});
      final catalog = await api.run(() => service.settings('JWT'));
      expect(catalog.field('nothing_like_this'), isNull);
    });

    test('a failure is the empty catalogue', () async {
      api.fail('Admin only.', status: 403);
      final catalog = await api.run(() => service.settings('JWT'));
      expect(catalog.sections, isEmpty);
      expect(catalog.cacheTtlSeconds, 60);
    });

    // Only the keys that moved are sent: a full-catalogue PUT would rewrite an
    // override another admin had just saved.
    test('a save is a PUT of only the keys that changed', () async {
      api.ok(null);
      await api.run(() => service.saveSettings('JWT', {'commission_pct': 12.5}));
      expect(api.method(), 'PUT');
      expect(api.endpoint(), '/admin/settings');
      expect(api.body(), {
        'settings': {'commission_pct': 12.5},
      });
    });

    test('a save note is trimmed, and a blank one is omitted', () async {
      api.ok(null);
      await api.run(() async {
        await service.saveSettings('JWT', const {'a': 1}, note: '  quarterly review  ');
        await service.saveSettings('JWT', const {'a': 1}, note: '   ');
      });
      expect(api.body(0)['note'], 'quarterly review');
      expect(api.body(1).containsKey('note'), isFalse);
    });

    test('a sports map is sent as a map, not flattened to a list', () async {
      api.ok(null);
      await api.run(() => service.saveSettings('JWT', {
            'sports_enabled': {'football': true, 'cricket': false},
          }));
      expect((api.body()['settings'] as Map)['sports_enabled'],
          {'football': true, 'cricket': false});
    });

    test('an out-of-range value comes back with the range named', () async {
      api.fail('commission_pct must be between 0 and 100.', status: 400);
      final r = await api.run(
        () => service.saveSettings('JWT', const {'commission_pct': 250}),
      );
      expect(r['message'], 'commission_pct must be between 0 and 100.');
    });

    test('disabling a sport with future bookings keeps the 409 and its counts', () async {
      api.json({
        'success': false,
        'message': 'cricket has 4 confirmed bookings in the future.',
        'code': 'sport_has_bookings',
      }, status: 409);
      final r = await api.run(() => service.saveSettings('JWT', {
            'sports_enabled': {'cricket': false},
          }));
      expect(r['statusCode'], 409);
      expect(r['code'], 'sport_has_bookings');
      expect(r['message'], 'cricket has 4 confirmed bookings in the future.');
    });

    test('a reset posts the keys to drop', () async {
      api.ok(null);
      await api.run(() => service.resetSettings('JWT', const ['commission_pct', 'deposit_pct']));
      expect(api.method(), 'POST');
      expect(api.endpoint(), '/admin/settings/reset');
      expect(api.body(), {
        'keys': ['commission_pct', 'deposit_pct'],
      });
    });

    test('every admin write carries the bearer token', () async {
      api.ok(null);
      await api.run(() async {
        await service.ruleDispute('JWT', 'd1', action: 'dismiss');
        await service.suspend('JWT', 'u1', reason: 'x');
        await service.reinstate('JWT', 'u1');
        await service.saveSettings('JWT', const {'a': 1});
        await service.resetSettings('JWT', const ['a']);
      });
      for (var i = 0; i < 5; i++) {
        expect(api.token(i), 'JWT', reason: 'request $i');
      }
    });
  });
}
