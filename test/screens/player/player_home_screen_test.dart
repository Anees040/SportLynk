// Player Home is the shell for five kept-alive tabs. The shell opens its home
// surface immediately, while a signed-out fixture deliberately avoids the socket
// connection that the live chat badge would otherwise start during a widget test.
// The assertions cover the static home contract and the routes reachable from it.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/player_home_screen.dart';

import '../screen_harness.dart';

Future<RouteLog> pumpHome(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const PlayerHomeScreen(),
    // `_watchChat` calls `ensureConnected` for a real token. An empty token is
    // the screen's own signed-out branch and leaves the shell's local content
    // available without opening a socket in the test process.
    auth: FakeAuth(token: null),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi()..install();
  });

  group('the home surface', () {
    testWidgets('shows the greeting, quick actions and empty booking copy', (
      tester,
    ) async {
      await pumpHome(tester, api);
      await settleData(tester);

      expect(find.textContaining('Good '), findsOneWidget);
      expect(find.textContaining('👋'), findsOneWidget);
      expect(find.text('Quick Actions'), findsOneWidget);
      expect(find.text('Book Venue'), findsOneWidget);
      expect(find.text('Find Opponent'), findsOneWidget);
      expect(find.text('Tournaments'), findsOneWidget);
      expect(find.text('No upcoming bookings'), findsOneWidget);
    });

    testWidgets('the in-page search surface is gone from home', (
      tester,
    ) async {
      await pumpHome(tester, api);
      await settleData(tester);

      // The search field that used to redirect to a separate Find Venues screen
      // has been removed by design; Book Venue and Scout are the paths to venue
      // search now, so the field must no longer be present on the home surface.
      expect(find.textContaining('Find venues, sports'), findsNothing);
    });

    testWidgets('the Book Venue action routes to Find Venues', (tester) async {
      final log = await pumpHome(tester, api);
      await settleData(tester);

      await tapVisible(tester, find.text('Book Venue'));

      expect(log.sawRoute('/find-venues'), isTrue);
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the primary actions present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpHome(tester, api, textScale: 2.0);
      await settleData(tester);

      final quickActions = find.text('Quick Actions', skipOffstage: false);
      await tester.ensureVisible(quickActions);
      await tester.pump();

      expect(find.text('Quick Actions'), findsOneWidget);
      expect(find.text('Book Venue'), findsOneWidget);
    });
  });
}
