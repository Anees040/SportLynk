// Unit tests for lib/utils/deep_link.dart.
//
// A notification tap is the one navigation the user cannot retry by hand, so the
// three payload shapes DeepLink.parse has to accept are pinned here. The FCM shape
// is the awkward one: data payloads are string-to-string, so `args` arrives as a
// JSON string rather than a map.
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/routes/app_routes.dart';
import 'package:sportlynk/utils/deep_link.dart';

void main() {
  // DeepLink.open reads navigatorKey.currentState, and a GlobalKey lookup needs the
  // widgets binding even when it resolves to null.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(DeepLink.clear);

  group('parse', () {
    test('accepts the map a feed row or socket frame sends', () {
      final out = DeepLink.parse({
        'route': '/booking-detail',
        'args': {'bookingId': 'b-1'},
      });
      expect(out?['route'], '/booking-detail');
      expect(out?['args'], {'bookingId': 'b-1'});
    });

    test('accepts a whole JSON string, the cold-start FCM shape', () {
      final out = DeepLink.parse('{"route":"/chat-thread","args":{"channelId":"c-9"}}');
      expect(out?['route'], '/chat-thread');
      expect(out?['args'], {'channelId': 'c-9'});
    });

    test('accepts a map whose args is still a JSON string', () {
      final out = DeepLink.parse({
        'route': '/match-center',
        'args': '{"matchId":"m-4"}',
      });
      expect(out?['args'], {'matchId': 'm-4'});
    });

    test('args is an empty map, never null, when absent or malformed', () {
      expect(DeepLink.parse({'route': '/chats'})?['args'], <String, dynamic>{});
      expect(DeepLink.parse({'route': '/chats', 'args': '{oops'})?['args'],
          <String, dynamic>{});
      expect(DeepLink.parse({'route': '/chats', 'args': 7})?['args'],
          <String, dynamic>{});
    });

    test('rejects a payload that cannot address a screen', () {
      expect(DeepLink.parse(null), isNull);
      expect(DeepLink.parse({'args': {'x': 1}}), isNull);
      expect(DeepLink.parse({'route': 'booking-detail'}), isNull);
      expect(DeepLink.parse('not json at all'), isNull);
      expect(DeepLink.parse('{"route":'), isNull);
    });
  });

  group('park and replay', () {
    test('a valid link is held for the cold-start replay', () {
      expect(DeepLink.hasPending, isFalse);
      DeepLink.park({'route': '/wallet'});
      expect(DeepLink.hasPending, isTrue);
    });

    test('an unusable link is not held, so nothing replays later', () {
      DeepLink.park({'route': 'wallet'});
      expect(DeepLink.hasPending, isFalse);
    });

    test('clear drops a parked link, which is what logout relies on', () {
      DeepLink.park({'route': '/notifications'});
      DeepLink.clear();
      expect(DeepLink.hasPending, isFalse);
    });
  });

  group('open without a navigator', () {
    // The cold-start path: the tap is handled before any widget is mounted, so open
    // must report success and leave the link parked rather than dropping it.
    test('parks the link and reports handled', () {
      expect(DeepLink.open({'route': '/team-roster', 'args': {'teamId': 't-1'}}), isTrue);
      expect(DeepLink.hasPending, isTrue);
    });

    test('reports unhandled for a payload it cannot address', () {
      expect(DeepLink.open({'route': 'team-roster'}), isFalse);
      expect(DeepLink.hasPending, isFalse);
    });
  });

  // A route in knownRoutes that is not registered throws on pushNamed, and it throws
  // on a screen the user reached by tapping a notification. This is the cheapest
  // place to catch a rename of either side.
  test('every known deep-link route is registered in AppRoutes.map', () {
    final missing =
        DeepLink.knownRoutes.where((r) => !AppRoutes.map.containsKey(r)).toList();
    expect(missing, isEmpty, reason: 'unregistered deep-link routes: $missing');
  });
}
