// NotificationService: the feed's request shapes, and the two places where a wrong
// one is silent rather than loud.
//
// The first is the delete pair. `dismiss` and `clearRead` are both DELETEs but they
// are not the same operation: dismissing sets `dismissed_at` and keeps the row on
// disk, which is what makes "you were marked a no-show" evidence a user cannot erase,
// while clearing is a bounded hard delete of read rows only. The category on a clear
// rides in the QUERY STRING because that is where the route reads it — `ApiClient.delete`
// takes no `queryParams`, so the service appends it by hand, and a body would be sent
// to an endpoint that never opens one.
//
// The second is `savePrefs`. The response is the server's re-normalised copy, not an
// echo of the request: an unknown category or a malformed "25:99" is dropped on the
// far side, so the screen must render what came back. These tests therefore return a
// DIFFERENT payload from the one submitted and assert the returned object follows the
// response.
//
// `categories` and `unmutable` are server-owned facts derived from
// `notificationTypes.js`; `toBody` deliberately omits them, and that omission is
// asserted so a later "round-trip the whole object" refactor cannot start telling the
// server which categories exist.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/notification_service.dart';

import 'http_seam.dart';

const _prefs = NotificationPrefs(
  muteAll: false,
  push: {'booking': true, 'chat': false},
  inApp: {'booking': true},
  quietEnabled: true,
  quietStart: '22:00',
  quietEnd: '07:00',
  categories: ['booking', 'chat', 'system'],
  unmutable: ['system'],
);

void main() {
  late FakeApi api;
  late NotificationService service;

  setUp(() {
    api = FakeApi();
    service = NotificationService();
  });

  tearDown(resetApiClient);

  group('the feed', () {
    test('the default read asks for a page size and nothing else', () async {
      api.ok({'items': const []});
      await api.run(() => service.list('JWT'));
      expect(api.endpoint(), '/notifications?limit=25');
      expect(api.query(), {'limit': '25'});
    });

    test('a cursor, a category and the unread filter are all sent', () async {
      api.ok({'items': const []});
      await api.run(() => service.list(
            'JWT',
            cursor: '2026-03-14T18:30:00.000Z~n9',
            category: 'booking',
            unreadOnly: true,
            limit: 50,
          ));
      expect(api.query(), {
        'limit': '50',
        'cursor': '2026-03-14T18:30:00.000Z~n9',
        'category': 'booking',
        'unreadOnly': 'true',
      });
    });

    // The unread filter is sent only when it is on: `unreadOnly=false` would be a
    // filter the route has to interpret, where an absent key already means "all".
    test('the unread filter is absent when off, as are empty strings', () async {
      api.ok({'items': const []});
      await api.run(() => service.list('JWT', cursor: '', category: ''));
      expect(api.query(), {'limit': '25'});
    });

    test('rows carry their deep link, actor and group count', () async {
      api.ok({
        'items': [
          {
            'id': 'n1',
            'type': 'booking_confirmed',
            'category': 'booking',
            'icon': 'event_available',
            'title': 'Booking confirmed',
            'body': 'Friday 18:00 at Arena One',
            'deepLink': {
              'route': '/booking',
              'args': {'id': 'b1'},
            },
            'groupCount': 3,
            'actor': {'id': 'u2', 'name': 'Rana Bilal'},
            'isRead': false,
            'createdAt': '2026-03-14T18:30:00.000Z',
          },
        ],
        'hasMore': true,
        'nextCursor': 'c2',
      });
      final page = await api.run(() => service.list('JWT'));
      final row = page.items.single;
      expect(row.type, 'booking_confirmed');
      expect(row.route, '/booking');
      expect(row.routeArgs, {'id': 'b1'});
      expect(row.isActionable, isTrue);
      expect(row.groupCount, 3);
      expect(row.actor!.initials, 'RB');
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'c2');
    });

    // An expired row keeps its link but must not be offered: the screen it opens has
    // nothing left to act on.
    test('an expired row is not actionable even though it kept its link', () async {
      api.ok({
        'items': [
          {
            'id': 'n1',
            'deepLink': {'route': '/match'},
            'isExpired': true,
          },
        ],
      });
      final page = await api.run(() => service.list('JWT'));
      expect(page.items.single.route, '/match');
      expect(page.items.single.isActionable, isFalse);
    });

    test('a failure is the empty page, never a throw', () async {
      api.offline();
      final page = await api.run(() => service.list('JWT'));
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
    });

    test('a wrong-typed data block is the empty page', () async {
      api.ok('nothing like a page');
      expect((await api.run(() => service.list('JWT'))).items, isEmpty);
    });
  });

  group('the badge summary', () {
    test('the unread count and its per-category split are parsed', () async {
      api.ok({
        'unread': 7,
        'byCategory': {'booking': 4, 'chat': 3, 'system': 'not a number'},
        'push': {'configured': true},
      });
      final s = await api.run(() => service.summary('JWT'));
      expect(api.endpoint(), '/notifications/summary');
      expect(s.unread, 7);
      expect(s.byCategory, {'booking': 4, 'chat': 3});
      expect(s.pushConfigured, isTrue);
    });

    // A bell must not put a dialog over the home screen, so the failure path is a
    // zero the caller can render.
    test('a failure is a zero badge with push reported unconfigured', () async {
      api.fail('Unauthorised.', status: 401);
      final s = await api.run(() => service.summary('JWT'));
      expect(s.unread, 0);
      expect(s.byCategory, isEmpty);
      expect(s.pushConfigured, isFalse);
    });
  });

  group('read marks', () {
    test('read and unread are two routes on the same row', () async {
      api.ok(null);
      await api.run(() async {
        await service.markRead('JWT', 'n1');
        await service.markUnread('JWT', 'n1');
      });
      expect(api.method(0), 'PATCH');
      expect(api.endpoint(0), '/notifications/n1/read');
      expect(api.body(0), isEmpty);
      expect(api.endpoint(1), '/notifications/n1/unread');
    });

    test('read-all with no category clears everything', () async {
      api.ok(null);
      await api.run(() => service.readAll('JWT'));
      expect(api.method(), 'POST');
      expect(api.endpoint(), '/notifications/read-all');
      expect(api.body(), isEmpty);
    });

    test('read-all can be scoped to one category, but not to a blank one', () async {
      api.ok(null);
      await api.run(() async {
        await service.readAll('JWT', category: 'chat');
        await service.readAll('JWT', category: '');
      });
      expect(api.body(0), {'category': 'chat'});
      expect(api.body(1), isEmpty);
    });
  });

  group('dismiss and clear', () {
    // Dismiss keeps the row: `dismissed_at` is set, the row leaves the feed and the
    // badge, and support can still see it. It is addressed at one id.
    test('a dismiss is a DELETE of one row', () async {
      api.ok(null);
      await api.run(() => service.dismiss('JWT', 'n1'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/notifications/n1');
    });

    test('clear-read is a DELETE of the collection, not of a row', () async {
      api.ok(null);
      await api.run(() => service.clearRead('JWT'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/notifications');
    });

    // The route reads `req.query.category`, so the category has to be in the query
    // string; ApiClient.delete has no queryParams argument and a body would go
    // unread.
    test('a scoped clear puts the category in the query string', () async {
      api.ok(null);
      await api.run(() => service.clearRead('JWT', category: 'booking'));
      expect(api.endpoint(), '/notifications?category=booking');
      expect(api.query(), {'category': 'booking'});
    });

    test('a category needing encoding is encoded, not sent raw', () async {
      api.ok(null);
      await api.run(() => service.clearRead('JWT', category: 'match results'));
      expect(api.query(), {'category': 'match results'});
      expect(api.only.url.query, 'category=match+results');
    });

    test('a blank category leaves the URL without a query at all', () async {
      api.ok(null);
      await api.run(() => service.clearRead('JWT', category: ''));
      expect(api.only.url.hasQuery, isFalse);
    });
  });

  group('preferences', () {
    test('the form is read from the nested prefs block', () async {
      api.ok({
        'prefs': {
          'muteAll': false,
          'push': {'booking': true, 'chat': false},
          'inApp': {'booking': true},
          'quietHours': {'enabled': true, 'start': '23:30', 'end': '06:45'},
        },
        'categories': ['booking', 'chat', 'system'],
        'unmutable': ['system'],
      });
      final p = await api.run(() => service.prefs('JWT'));
      expect(api.endpoint(), '/notifications/preferences');
      expect(p!.push, {'booking': true, 'chat': false});
      expect(p.inApp, {'booking': true});
      expect(p.quietEnabled, isTrue);
      expect(p.quietStart, '23:30');
      expect(p.quietEnd, '06:45');
      expect(p.categories, ['booking', 'chat', 'system']);
      expect(p.unmutable, ['system']);
    });

    // The quiet-hours default is the client's only hardcoded pair, and it stands in
    // for an absent block rather than for a disabled one.
    test('absent quiet hours fall back to the documented window, disabled', () async {
      api.ok({'prefs': const {}});
      final p = await api.run(() => service.prefs('JWT'));
      expect(p!.quietEnabled, isFalse);
      expect(p.quietStart, '22:00');
      expect(p.quietEnd, '07:00');
    });

    // `_flags` reads anything that is not literally false as on, so a category the
    // server sends as 1 or as a string is not silently muted.
    test('a flag is off only when it is literally false', () async {
      api.ok({
        'prefs': {
          'push': {'booking': false, 'chat': true, 'match': 1, 'social': null},
        },
      });
      final p = await api.run(() => service.prefs('JWT'));
      expect(p!.push, {'booking': false, 'chat': true, 'match': true, 'social': true});
    });

    test('a failed read is null so the screen can show its error state', () async {
      api.offline();
      expect(await api.run(() => service.prefs('JWT')), isNull);
    });

    test('a save sends only the three keys the server reads', () async {
      api.ok({'prefs': const {}});
      await api.run(() => service.savePrefs('JWT', _prefs));
      expect(api.method(), 'PUT');
      expect(api.endpoint(), '/notifications/preferences');
      expect(api.body(), {
        'muteAll': false,
        'push': {'booking': true, 'chat': false},
        'inApp': {'booking': true},
        'quietHours': {'enabled': true, 'start': '22:00', 'end': '07:00'},
      });
    });

    test('the server-owned catalogue is never echoed back at it', () async {
      api.ok({'prefs': const {}});
      await api.run(() => service.savePrefs('JWT', _prefs));
      expect(api.body().containsKey('categories'), isFalse);
      expect(api.body().containsKey('unmutable'), isFalse);
    });
  });

  group('preferences, the response is the truth', () {
    // What comes back is the re-normalised copy: an unknown category and a malformed
    // time are dropped on the far side, and showing the user their rejected input back
    // as if it stuck is the failure this prevents.
    test('the returned object follows the response, not the submitted form', () async {
      api.ok({
        'prefs': {
          'push': {'booking': true},
          'quietHours': {'enabled': false, 'start': '22:00', 'end': '07:00'},
        },
      });
      final saved = await api.run(
        () => service.savePrefs('JWT', _prefs.copyWith(quietStart: '25:99')),
      );
      expect(api.body()['quietHours'], {'enabled': true, 'start': '25:99', 'end': '07:00'});
      expect(saved!.quietEnabled, isFalse);
      expect(saved.quietStart, '22:00');
      expect(saved.push, {'booking': true});
    });

    test('a rejected save is null rather than a half-applied form', () async {
      api.fail('quietHours.start must be HH:MM.', status: 400);
      expect(await api.run(() => service.savePrefs('JWT', _prefs)), isNull);
    });

    test('copyWith keeps the server-owned lists it cannot recompute', () {
      final moved = _prefs.copyWith(muteAll: true);
      expect(moved.muteAll, isTrue);
      expect(moved.categories, _prefs.categories);
      expect(moved.unmutable, _prefs.unmutable);
      expect(moved.push, _prefs.push);
    });
  });

  group('devices', () {
    // FCM rotates tokens without warning, so this is called on login, on every
    // refresh and on app start; the device token is the payload's `token` key, not
    // the bearer.
    test('a registration names the FCM token and the platform', () async {
      api.ok(null, status: 201);
      await api.run(() => service.registerDevice(
            'JWT',
            fcmToken: 'fcm-abc',
            platform: 'android',
            appVersion: '1.4.0',
            label: 'Pixel 7',
          ));
      expect(api.method(), 'POST');
      expect(api.endpoint(), '/notifications/devices');
      expect(api.body(), {
        'token': 'fcm-abc',
        'platform': 'android',
        'appVersion': '1.4.0',
        'label': 'Pixel 7',
      });
      expect(api.token(), 'JWT');
    });

    test('the optional device fields are omitted, not sent as null', () async {
      api.ok(null, status: 201);
      await api.run(() => service.registerDevice('JWT', fcmToken: 'fcm-abc'));
      expect(api.body(), {'token': 'fcm-abc'});
    });

    // Revoking on logout is what stops the next person to hold this phone from
    // receiving the last person's pushes, and it is addressed by device token
    // because the server has no other handle on one device.
    test('a revoke is a DELETE carrying the device token in its body', () async {
      api.ok(null);
      await api.run(() => service.revokeDevice('JWT', 'fcm-abc'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/notifications/devices');
      expect(api.body(), {'token': 'fcm-abc'});
    });

    test('the test push takes no user id, so it cannot buzz another phone', () async {
      api.ok(null);
      await api.run(() => service.sendTest('JWT', title: 'Hello', body: 'From the API'));
      expect(api.endpoint(), '/notifications/test');
      expect(api.body(), {'title': 'Hello', 'body': 'From the API'});
    });

    test('the test push with no text sends an empty body', () async {
      api.ok(null);
      await api.run(() => service.sendTest('JWT'));
      expect(api.body(), isEmpty);
    });

    test('a refused test push in production keeps the server sentence', () async {
      api.fail('Test notifications are disabled in production.', status: 403);
      final r = await api.run(() => service.sendTest('JWT'));
      expect(r['success'], isFalse);
      expect(r['message'], 'Test notifications are disabled in production.');
    });
  });
}
