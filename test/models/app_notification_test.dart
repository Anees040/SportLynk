// Notification feed model tests.
//
// The feed rows are assembled server-side in `backend/src/utils/notificationFeed.js`,
// so the risk on this side is not arithmetic but tolerance: a row must stay
// renderable when a field is absent, when the server declined to compute a
// `deepLink`, and when `args` arrives as something other than a map. Each of
// those is a shape the API legitimately sends, and a throw in `fromJson` empties
// the whole list rather than one row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/app_notification.dart';

/// An ISO-8601 UTC timestamp the given duration in the past, in the form the
/// API sends it.
String ago(Duration d) =>
    DateTime.now().toUtc().subtract(d).toIso8601String();

void main() {
  group('AppNotification.fromJson tolerance', () {
    test('an empty payload yields a renderable row rather than throwing', () {
      final n = AppNotification.fromJson({});
      expect(n.id, '');
      expect(n.type, '');
      expect(n.category, 'system');
      expect(n.priority, 'normal');
      expect(n.iconName, 'notifications');
      expect(n.title, '');
      expect(n.body, '');
      expect(n.payload, isEmpty);
      expect(n.deepLink, isNull);
      expect(n.actor, isNull);
      expect(n.groupCount, 1);
      expect(n.isRead, isFalse);
      expect(n.isExpired, isFalse);
    });

    test('payload and deepLink are ignored unless they are maps', () {
      final n = AppNotification.fromJson({
        'payload': 'not-a-map',
        'deepLink': <String>['also', 'not', 'a', 'map'],
        'actor': 7,
      });
      expect(n.payload, isEmpty);
      expect(n.deepLink, isNull);
      expect(n.actor, isNull);
    });

    test('identifiers are stringified, so an int id does not throw', () {
      final n = AppNotification.fromJson({
        'id': 41,
        'entityId': 12,
        'bookingId': 99,
        'groupCount': 3,
      });
      expect(n.id, '41');
      expect(n.entityId, '12');
      expect(n.bookingId, '99');
      expect(n.groupCount, 3);
    });

    test('groupCount falls back to 1 for a non-numeric value', () {
      expect(AppNotification.fromJson({'groupCount': '3'}).groupCount, 1);
      expect(AppNotification.fromJson({'groupCount': null}).groupCount, 1);
    });

    test('isRead and isExpired require a literal true, not a truthy value', () {
      expect(AppNotification.fromJson({'isRead': 'true'}).isRead, isFalse);
      expect(AppNotification.fromJson({'isRead': 1}).isRead, isFalse);
      expect(AppNotification.fromJson({'isRead': true}).isRead, isTrue);
      expect(AppNotification.fromJson({'isExpired': true}).isExpired, isTrue);
    });

    test('createdAt stays in UTC so the feed sort is not timezone dependent', () {
      final n = AppNotification.fromJson({'createdAt': '2026-03-01T10:00:00.000Z'});
      expect(n.createdAt.isUtc, isTrue);
      expect(n.createdAt.hour, 10);
    });

    test('a missing createdAt falls back to now rather than null', () {
      final n = AppNotification.fromJson({});
      expect(
        DateTime.now().toUtc().difference(n.createdAt).inSeconds.abs(),
        lessThan(5),
      );
    });
  });

  group('AppNotification derived state', () {
    test('isActionable requires a link and a row that has not expired', () {
      final live = AppNotification.fromJson({
        'deepLink': {'route': '/match-detail', 'args': {'id': 'm1'}},
      });
      final dead = AppNotification.fromJson({
        'deepLink': {'route': '/match-detail', 'args': {'id': 'm1'}},
        'isExpired': true,
      });
      final linkless = AppNotification.fromJson({'isExpired': false});

      expect(live.isActionable, isTrue);
      expect(dead.isActionable, isFalse,
          reason: 'an expired row keeps its link but must not offer a tap');
      expect(linkless.isActionable, isFalse);
    });

    test('route reads through the deepLink and is null without one', () {
      expect(
        AppNotification.fromJson({'deepLink': {'route': '/chat'}}).route,
        '/chat',
      );
      expect(AppNotification.fromJson({}).route, isNull);
    });

    test('routeArgs is always a map, never null', () {
      expect(AppNotification.fromJson({}).routeArgs, isEmpty);
      expect(
        AppNotification.fromJson({'deepLink': {'route': '/chat'}}).routeArgs,
        isEmpty,
      );
      expect(
        AppNotification.fromJson(
            {'deepLink': {'route': '/chat', 'args': 'nope'}}).routeArgs,
        isEmpty,
      );
      expect(
        AppNotification.fromJson({
          'deepLink': {'route': '/chat', 'args': {'channelId': 'c1'}}
        }).routeArgs,
        {'channelId': 'c1'},
      );
    });

    test('age is terse and steps through seconds, minutes, hours and days', () {
      expect(AppNotification.fromJson({'createdAt': ago(const Duration(seconds: 5))}).age, 'now');
      expect(AppNotification.fromJson({'createdAt': ago(const Duration(seconds: 90))}).age, '1m');
      expect(AppNotification.fromJson({'createdAt': ago(const Duration(minutes: 5))}).age, '5m');
      expect(AppNotification.fromJson({'createdAt': ago(const Duration(hours: 3))}).age, '3h');
      expect(AppNotification.fromJson({'createdAt': ago(const Duration(days: 2))}).age, '2d');
    });

    test('age past a week reads as a date, not a growing day count', () {
      final when = DateTime.now().toUtc().subtract(const Duration(days: 30));
      final n = AppNotification.fromJson({'createdAt': when.toIso8601String()});
      final l = when.toLocal();
      expect(n.age, '${l.day}/${l.month}');
    });

    test('an unmapped icon name falls back to a bell instead of throwing', () {
      expect(AppNotification.fromJson({'icon': 'emoji_events'}).icon, Icons.emoji_events);
      expect(AppNotification.fromJson({'icon': 'no_such_icon'}).icon, Icons.notifications);
      expect(AppNotification.fromJson({}).icon, Icons.notifications);
    });
  });

  group('NotificationActor.initials', () {
    String initials(String? name) =>
        NotificationActor.fromJson({'id': 'u1', 'name': name}).initials;

    test('takes at most two letters, uppercased', () {
      expect(initials('Anees Khan'), 'AK');
      expect(initials('anees khan'), 'AK');
      expect(initials('Muhammad Anees Khan'), 'MA');
      expect(initials('Anees'), 'A');
    });

    test('collapses irregular whitespace', () {
      expect(initials('  Anees   Khan  '), 'AK');
    });

    test('falls back to a question mark rather than an empty avatar', () {
      expect(initials(null), '?');
      expect(initials(''), '?');
      expect(initials('   '), '?');
    });
  });

  group('NotificationSummary.fromJson', () {
    test('reads the badge, the chip counts and why the phone is quiet', () {
      final s = NotificationSummary.fromJson({
        'unread': 4,
        'byCategory': {'match': 2, 'booking': 1, 'social': 1},
        'push': {'configured': true},
      });
      expect(s.unread, 4);
      expect(s.byCategory, {'match': 2, 'booking': 1, 'social': 1});
      expect(s.pushConfigured, isTrue);
    });

    test('non-numeric category counts are dropped, not coerced', () {
      final s = NotificationSummary.fromJson({
        'byCategory': {'match': 2, 'booking': 'many', 'social': null},
      });
      expect(s.byCategory, {'match': 2});
    });

    test('an absent push block reads as unconfigured', () {
      expect(NotificationSummary.fromJson({}).pushConfigured, isFalse);
      expect(
        NotificationSummary.fromJson({'push': {'configured': false}}).pushConfigured,
        isFalse,
      );
      expect(NotificationSummary.fromJson({'push': true}).pushConfigured, isFalse);
    });

    test('a missing or non-numeric unread reads as zero', () {
      expect(NotificationSummary.fromJson({}).unread, 0);
      expect(NotificationSummary.fromJson({'unread': '4'}).unread, 0);
    });

    test('the empty constant is a usable zero state', () {
      expect(NotificationSummary.empty.unread, 0);
      expect(NotificationSummary.empty.byCategory, isEmpty);
      expect(NotificationSummary.empty.pushConfigured, isFalse);
    });
  });
}
