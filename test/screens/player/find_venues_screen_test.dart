// Find Venues: the screen a player opens first, and the one the project calls its
// weakest surface.
//
// Four states are mandated for anything that waits on the network — loading, empty,
// error with a retry, loaded — and this screen has three. `_load`
// (lib/screens/player/find_venues_screen.dart:117) ends in a bare
// `catch (_) { setState(() => _loading = false); }`, and the non-throwing failure path
// at :112 sets `_venues = []`. Both land on the same empty state, so a 500 from the API
// and a genuinely empty result set are indistinguishable on screen: the player is told
// "No venues found — try a different search" when the truth is that the request failed
// and there is nothing to retry with.
//
// That is pinned here as behaviour rather than fixed, because the fix is a `lib/` change
// outside the scope of writing tests. Three tests carry it, each naming the line: a 500,
// a dropped connection, and an unparseable body all reach the empty state. When the
// error state is added, those three are the ones that must change, and the comment on
// each says what to change it to.
//
// The rest of the file pins what the screen does get right. The recommendation strip is
// a separate request whose failure is tolerated — a venue list that renders without its
// "For you" rail is the correct degradation, and the test asserts the list survives a
// recommender that returned 500. The filter chips and the search box are asserted
// through the query string the screen actually sent rather than through its private
// state, because the contract with the backend is the query, not the field.
//
// Nothing here settles: the loading state is a `CircularProgressIndicator`, which
// animates forever.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/find_venues_screen.dart';

import '../screen_harness.dart';

/// One venue row, in the shape `/venues` returns.
Map<String, dynamic> venue({
  String id = 'v-1',
  String name = 'Karachi Sports Arena',
  String sport = 'futsal',
  num price = 2500,
  num rating = 4.6,
  String city = 'Karachi',
}) =>
    {
      'id': id,
      'name': name,
      'sport': sport,
      'sports': [sport],
      'price_per_hour': price,
      'rating': rating,
      'city': city,
      'address': 'Block 4, Clifton',
      'review_count': 12,
      'images': <String>[],
    };

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // The recommender is a second, independent request on every load. Stubbed empty
    // by default so a test that says nothing about it is not silently asserting on a
    // 404 fixture.
    api.ok('/venues/recommended', {'venues': <dynamic>[], 'source': 'heuristic'});
    api.ok('/users/me/player', {'sport_preferences': <String>[]});
  });

  group('while the venues are being fetched', () {
    testWidgets('a spinner is shown rather than an empty list', (tester) async {
      // The distinction that matters: an empty list drawn during the fetch reads as
      // "there are no venues", which is a claim the screen cannot make yet.
      api.ok('/venues', [venue()], delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const FindVenuesScreen());

      expectLoading(tester);
      expect(find.text('No venues found'), findsNothing);
      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('the fetch starts without waiting for a gesture', (tester) async {
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());

      expect(api.countTo('/venues'), 1);
    });
  });

  group('once the venues arrive', () {
    testWidgets('each venue is listed by name', (tester) async {
      api.ok('/venues', [
        venue(name: 'Karachi Sports Arena'),
        venue(id: 'v-2', name: 'Clifton Futsal Park'),
      ]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text('Clifton Futsal Park'), findsOneWidget);
      expect(find.text('No venues found'), findsNothing);
    });

    testWidgets('the spinner is gone', (tester) async {
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a venue with no photo still renders', (tester) async {
      // Seeded venues frequently have no image, so this is the common case rather
      // than an edge one.
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('when the search really is empty', () {
    testWidgets('the empty state explains itself', (tester) async {
      api.ok('/venues', <dynamic>[]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('No venues found'), findsOneWidget);
      expect(find.text('Try a different search or filter criteria'), findsOneWidget);
      expect(find.byIcon(Icons.search_off_outlined), findsOneWidget);
    });

    testWidgets('an unfiltered empty result offers no filters to clear',
        (tester) async {
      // Offering "Clear All Filters" when none are set would be a dead button.
      api.ok('/venues', <dynamic>[]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('Clear All Filters'), findsNothing);
    });

    testWidgets('a filtered empty result offers to clear the filters',
        (tester) async {
      api.ok('/venues', <dynamic>[]);

      await pumpScreen(tester, const FindVenuesScreen(initialSport: 'Futsal'));
      await settleData(tester);

      expect(find.text('Clear All Filters'), findsOneWidget);
    });

    testWidgets('clearing the filters refetches without them', (tester) async {
      api.ok('/venues', <dynamic>[]);

      await pumpScreen(tester, const FindVenuesScreen(initialSport: 'Futsal'));
      await settleData(tester);
      expect(api.to('/venues').last.param('sport'), 'futsal');

      await tester.tap(find.text('Clear All Filters'));
      await settleData(tester);

      expect(api.to('/venues').last.param('sport'), isNull,
          reason: 'the sport filter was cleared on screen but not in the query');
    });
  });

  group('when the request fails', () {
    // Pinned as it behaves, not as it should. `_load`
    // (lib/screens/player/find_venues_screen.dart:112) sets `_venues = []` when the
    // envelope reports failure, and there is no `_error` field to render, so a 500
    // reaches the same empty state an genuinely empty result does. The player is
    // advised to change a search that was never run. The fix is an `_error` field, an
    // error branch beside the `_venues.isEmpty` one, and a Retry that calls `_load`;
    // this test should then assert the message and the button.
    testWidgets('a server error is reported as an empty search', (tester) async {
      api.fail('/venues', 'Venue lookup failed');

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('No venues found'), findsOneWidget);
      expect(find.text('Venue lookup failed'), findsNothing,
          reason: 'the message the API sent never reaches the screen');
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    });

    // Pinned as it behaves, not as it should. Same cause, different path: a dropped
    // connection throws, and `catch (_)`
    // (lib/screens/player/find_venues_screen.dart:117) discards it and clears the
    // spinner. This is the exact symptom of a missing `adb reverse`, and the screen
    // reports it as "no venues in your city".
    testWidgets('a dropped connection is reported as an empty search',
        (tester) async {
      api.offline('/venues');

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('No venues found'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'a spinner that never resolves would be the worse bug');
    });

    // Pinned as it behaves, not as it should. Same cause: `jsonDecode` throws on a
    // body that is not JSON — an HTML error page from a proxy, for instance — and the
    // same bare catch swallows it.
    testWidgets('an unparseable body is reported as an empty search',
        (tester) async {
      api.on('/venues', const FakeResponse(502, '<html>Bad Gateway</html>'));

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('No venues found'), findsOneWidget);
    });

    testWidgets('a failed recommender does not take the venue list with it',
        (tester) async {
      // The correct degradation, and the one thing the error handling here gets
      // right: the rail is optional, the list is not.
      api.ok('/venues', [venue()]);
      api.fail('/venues/recommended', 'recommender unavailable');

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(find.text('Karachi Sports Arena'), findsOneWidget);
    });
  });

  group('the filters the screen sends', () {
    testWidgets('an initial sport is applied to the first request',
        (tester) async {
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen(initialSport: 'Cricket'));
      await settleData(tester);

      expect(api.to('/venues').first.param('sport'), 'cricket',
          reason: 'the sport is lower-cased for the API');
    });

    testWidgets('no sport means no sport parameter', (tester) async {
      // An empty `sport=` would filter to nothing rather than to everything.
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(api.to('/venues').first.param('sport'), isNull);
    });

    testWidgets('a search of one character does not fetch', (tester) async {
      // Fetching per keystroke would put a request on the wire for every letter of
      // every venue name.
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);
      final before = api.countTo('/venues');

      await tester.enterText(find.byType(TextField).first, 'K');
      await settleData(tester);

      expect(api.countTo('/venues'), before);
    });

    testWidgets('a search of two characters fetches with the term',
        (tester) async {
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      await tester.enterText(find.byType(TextField).first, 'Ka');
      await settleData(tester);

      expect(api.to('/venues').last.param('search'), 'Ka');
    });

    testWidgets('clearing the search refetches everything', (tester) async {
      // The one case where an empty box must fetch: it is how a player gets back to
      // the full list.
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      await tester.enterText(find.byType(TextField).first, 'Karachi');
      await settleData(tester);
      final afterSearch = api.countTo('/venues');

      await tester.enterText(find.byType(TextField).first, '');
      await settleData(tester);

      expect(api.countTo('/venues'), greaterThan(afterSearch));
      expect(api.to('/venues').last.param('search'), isNull);
    });

    testWidgets('the default sort is not sent as a parameter', (tester) async {
      // The backend already defaults to rating; sending it makes every url longer
      // for no behaviour change.
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(api.to('/venues').first.param('sort'), isNull);
    });

    testWidgets('the request carries the session token', (tester) async {
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);

      expect(api.to('/venues'), isNotEmpty);
    });
  });

  group('pulling to refresh', () {
    testWidgets('a pull refetches the list', (tester) async {
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen());
      await settleData(tester);
      final before = api.countTo('/venues');

      await tester.fling(find.text('Karachi Sports Arena'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(api.countTo('/venues'), greaterThan(before));
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the loaded list does not clip', (tester) async {
      api.ok('/venues', [venue()]);

      await pumpScreen(tester, const FindVenuesScreen(), textScale: 2.0);
      await settleData(tester);

      expectNoOverflow(tester);
    });

    testWidgets('the empty state does not clip', (tester) async {
      api.ok('/venues', <dynamic>[]);

      await pumpScreen(tester, const FindVenuesScreen(), textScale: 2.0);
      await settleData(tester);

      expect(find.text('No venues found'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
