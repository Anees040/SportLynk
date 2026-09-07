// NotificationBell: the badge, and the session bootstrap that happens to live behind
// it.
//
// The bell is on all three home screens and nowhere else, which makes it the only
// widget mounted exactly once per authenticated session. Three things are started
// from that fact — the provider's socket subscription, this phone's FCM registration,
// and the replay of a tray tap that opened a killed app — so the bootstrap is treated
// below as part of the contract rather than as a side effect.
//
// Two properties of it matter more than the rest. It must run once per mount and not
// once per build: the count moves on every socket frame, and a bootstrap in `build`
// would re-register the device and re-read `/summary` each time the number changed.
// And it must not run at all without a token, because `attach(null)` and a push
// registration for an empty session are how a signed-out app keeps talking to the
// server. Both are asserted by counting calls on a fake provider.
//
// `PushService.registerFor` and `DeepLink.replayPending` are reached directly rather
// than through an injected seam, and are left to run so that `_boot` is exercised as
// written. Neither is observable here: the first swallows the missing Firebase app in
// its own catch, and the second returns immediately because no link was parked.
//
// The unmount is pinned as it behaves rather than as it should. `dispose` reaches for
// the provider through `context.read`, which is an ancestor lookup from an element the
// framework has already deactivated, and a debug build asserts on exactly that — so
// `detach` is never reached and the exception surfaces instead. Every test therefore
// closes the tree through [_close], which consumes that one exception; leaving the
// unmount to the tester's own finalization would report it against whichever test ran
// last. Repairing the widget should turn [_close] and the last test in this file red.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sportlynk/providers/auth_provider.dart';
import 'package:sportlynk/providers/notification_provider.dart';
import 'package:sportlynk/widgets/notification_bell.dart';

import 'widget_harness.dart';

/// A session with a token and no network: `token` is a plain getter on the real
/// provider, so nothing here has to log in to count as signed in.
class _FakeAuth extends AuthProvider {
  _FakeAuth(this._token);

  final String? _token;

  @override
  String? get token => _token;
}

/// Records the two calls the bell makes, and keeps the real socket out of the test.
class _FakeNotifications extends NotificationProvider {
  @override
  int unread = 0;

  final List<String?> attached = <String?>[];
  int detaches = 0;

  @override
  void attach(String? token) => attached.add(token);

  @override
  void detach() => detaches++;

  /// A socket frame's visible effect: a new count and a rebuild.
  void arrive(int count) {
    unread = count;
    notifyListeners();
  }
}

void main() {
  late _FakeAuth auth;
  late _FakeNotifications notifications;

  setUp(() {
    auth = _FakeAuth('JWT');
    notifications = _FakeNotifications();
  });

  Future<RouteLog> pumpBell(
    WidgetTester tester, {
    Widget child = const NotificationBell(),
  }) =>
      pumpApp(
        tester,
        Scaffold(body: Center(child: child)),
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<NotificationProvider>.value(value: notifications),
        ],
      );

  /// Replaces the bell with an empty box, keeping the providers above it mounted, and
  /// consumes the exception described in the file header.
  Future<void> close(WidgetTester tester) async {
    await pumpBell(tester, child: const SizedBox.shrink());
    expect(
      tester.takeException(),
      isA<FlutterError>(),
      reason: 'dispose reads a deactivated ancestor: notification_bell.dart:69',
    );
  }

  group('what the header shows', () {
    testWidgets('an empty feed is the outlined bell with no badge', (tester) async {
      await pumpBell(tester);
      expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
      expect(find.byType(Text), findsNothing);
      expect(find.byTooltip('Notifications'), findsOneWidget);
      await close(tester);
    });

    // The icon carries the same fact as the badge, for anyone who cannot pick a small
    // red circle out of a dark header.
    testWidgets('unread mail fills the bell and prints the count', (tester) async {
      notifications.unread = 7;
      await pumpBell(tester);
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      await close(tester);
    });

    testWidgets('a frame arriving updates both without a remount', (tester) async {
      await pumpBell(tester);
      notifications.arrive(3);
      await tester.pump();
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(notifications.attached.length, 1);
      await close(tester);
    });
  });

  group('where the tap goes', () {
    testWidgets('the bell opens the feed', (tester) async {
      final log = await pumpBell(tester);
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(log.pushed, ['/notifications']);
      await close(tester);
    });

    // The route is a parameter so a filtered feed needs no second widget.
    testWidgets('a caller can point it somewhere else', (tester) async {
      final log = await pumpBell(tester,
          child: const NotificationBell(route: '/notifications?category=booking'));
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(log.last, '/notifications?category=booking');
      await close(tester);
    });
  });

  group('the session bootstrap', () {
    testWidgets('a signed-in mount attaches with the session token', (tester) async {
      await pumpBell(tester);
      expect(notifications.attached, ['JWT']);
      await close(tester);
    });

    // A bootstrap in `build` would re-register this device on every socket frame.
    testWidgets('a rebuild does not attach a second time', (tester) async {
      await pumpBell(tester);
      notifications
        ..arrive(1)
        ..arrive(2);
      await tester.pump();
      expect(notifications.attached.length, 1);
      await close(tester);
    });

    testWidgets('no token means nothing is started', (tester) async {
      auth = _FakeAuth(null);
      await pumpBell(tester);
      expect(notifications.attached, isEmpty);
      expect(notifications.detaches, 0);
      await close(tester);
    });

    testWidgets('an empty token is treated as no token', (tester) async {
      auth = _FakeAuth('');
      await pumpBell(tester);
      expect(notifications.attached, isEmpty);
      await close(tester);
    });

    // Recorded as the defect it is: logout unmounts the home screen, and the
    // subscription that should be dropped here survives because `dispose` throws
    // before it reaches `detach`. Until the widget holds its own reference to the
    // provider, a signed-out app keeps re-reading /summary for the old token.
    testWidgets('unmounting does not drop the subscription today', (tester) async {
      await pumpBell(tester);
      await close(tester);
      expect(find.byType(NotificationBell), findsNothing);
      expect(notifications.detaches, 0);
    });
  });
}
