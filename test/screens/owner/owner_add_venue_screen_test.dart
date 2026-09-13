// Owner venue registration is a two-step form. The image picker is a platform
// surface and is intentionally not opened here; the reachable validation and
// navigation contract remains testable without pretending a native picker works
// in a widget test.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_add_venue_screen.dart';

import '../screen_harness.dart';

const String kVenues = '/owner/venues';

Future<RouteLog> pumpAddVenue(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerAddVenueScreen(),
    auth: FakeAuth(
      role: 'owner',
      id: 'o-1',
      name: 'Owner',
      token: 'owner-token',
    ),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi()..install();
  });

  group('the first step', () {
    testWidgets('shows the ground form and its continue action', (
      tester,
    ) async {
      await pumpAddVenue(tester, api);

      expect(find.text('Your Ground'), findsOneWidget);
      expect(find.text('Ground Info'), findsOneWidget);
      expect(find.textContaining('Continue'), findsOneWidget);
      expect(find.text('Business / Ground Name *'), findsOneWidget);
    });

    testWidgets('an empty form names the required fields and sends nothing', (
      tester,
    ) async {
      await pumpAddVenue(tester, api);

      await tapVisible(tester, find.textContaining('Continue'));

      expect(find.text('Min 3 characters'), findsOneWidget);
      expect(find.text('City required'), findsOneWidget);
      expect(find.text('Min 10 characters'), findsOneWidget);
      expect(api.countTo(kVenues), 0);
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the first step usable', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpAddVenue(tester, api, textScale: 2.0);

      expect(find.text('Your Ground'), findsOneWidget);
      expect(find.textContaining('Continue'), findsOneWidget);
    });
  });
}
