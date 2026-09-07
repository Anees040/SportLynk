// PushService: the mute rule, which is the half of push delivery that runs without
// Firebase.
//
// Everything else in this service needs a live FCM registration — a token, a
// permission dialog, three platform streams — none of which exists in a unit test. The
// banner gate does not. `allowsBanner` decides whether a foreground message is drawn
// at all, and it is pure state plus a rule, so it is pinned here in full.
//
// The rule has two deliberate asymmetries, both of which are safety directions rather
// than conveniences. An absent category is allowed, matching the server, so a category
// added in a later release is not silently muted on an installed build that has never
// heard of it. And `system` is allowed whatever the stored preference says, because it
// carries the messages a user must not be able to switch off — the same unmutable set
// the server enforces, restated here so a tampered or stale preference map cannot
// suppress one locally.
//
// The service is a process singleton, so [PushService.applyPrefs] is state that
// outlives a test. Each case below sets the preferences it depends on rather than
// inheriting whatever ran before it.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/notification_service.dart';
import 'package:sportlynk/services/push_service.dart';

/// Preferences carrying only the `inApp` map, which is the only block the banner gate
/// reads. The rest is filled with the server's own defaults.
NotificationPrefs _prefs(Map<String, bool> inApp) => NotificationPrefs(
      muteAll: false,
      push: const {},
      inApp: inApp,
      quietEnabled: false,
      quietStart: '22:00',
      quietEnd: '07:00',
      categories: const ['booking', 'chat', 'social', 'system'],
      unmutable: const ['system'],
    );

void main() {
  late PushService push;

  setUp(() {
    push = PushService();
    push.applyPrefs(_prefs(const {}));
  });

  group('one registration per process', () {
    test('the service is the same instance wherever it is constructed', () {
      expect(PushService(), same(push));
    });

    test('nothing is registered before Firebase hands over a token', () {
      expect(push.deviceToken, isNull);
      expect(push.isReady, isFalse);
    });
  });

  group('the banner gate', () {
    // Absent means allowed, exactly as on the server: a category shipped after this
    // build must not arrive muted on it.
    test('a category the preferences have never heard of is allowed', () {
      expect(push.allowsBanner('tournament'), isTrue);
    });

    test('a muted category is refused', () {
      push.applyPrefs(_prefs(const {'chat': false}));
      expect(push.allowsBanner('chat'), isFalse);
    });

    test('an explicitly enabled category is allowed', () {
      push.applyPrefs(_prefs(const {'chat': true}));
      expect(push.allowsBanner('chat'), isTrue);
    });

    test('muting one category leaves the others alone', () {
      push.applyPrefs(_prefs(const {'chat': false}));
      expect(push.allowsBanner('booking'), isTrue);
      expect(push.allowsBanner('social'), isTrue);
      expect(push.allowsBanner('chat'), isFalse);
    });

    // A message with no category cannot be matched against a preference, and
    // dropping it silently would lose it. A banner too many, never a message lost.
    test('a message with no category is allowed', () {
      push.applyPrefs(_prefs(const {'chat': false}));
      expect(push.allowsBanner(null), isTrue);
      expect(push.allowsBanner(''), isTrue);
    });

    // The unmutable set is enforced on the server; restating it here is what stops a
    // stale or tampered preference map from suppressing one locally.
    test('system messages are drawn even when stored as muted', () {
      push.applyPrefs(_prefs(const {'system': false}));
      expect(push.allowsBanner('system'), isTrue);
    });

    test('a fresh preference set replaces the previous one entirely', () {
      push.applyPrefs(_prefs(const {'chat': false, 'booking': false}));
      expect(push.allowsBanner('chat'), isFalse);
      push.applyPrefs(_prefs(const {'chat': true}));
      expect(push.allowsBanner('chat'), isTrue);
      expect(push.allowsBanner('booking'), isTrue);
    });
  });

  group('the preferences the gate reads', () {
    // `applyPrefs` copies into an unmodifiable map, so a screen that keeps its own
    // reference cannot mutate the gate's copy from under it.
    test('the stored map cannot be written through afterwards', () {
      final mutable = <String, bool>{'chat': false};
      push.applyPrefs(_prefs(mutable));
      mutable['booking'] = false;
      expect(push.allowsBanner('booking'), isTrue);
      expect(push.allowsBanner('chat'), isFalse);
    });

    // Only the three keys the server reads are echoed back at it; `categories` and
    // `unmutable` are server-owned facts.
    test('a preference body carries the mute flags and nothing server-owned', () {
      final body = _prefs(const {'chat': false}).toBody();
      expect(body.keys, containsAll(<String>['muteAll', 'push', 'inApp']));
      expect(body.keys, isNot(contains('categories')));
      expect(body.keys, isNot(contains('unmutable')));
      expect(Map<String, bool>.from(body['inApp'] as Map)['chat'], isFalse);
    });
  });
}
