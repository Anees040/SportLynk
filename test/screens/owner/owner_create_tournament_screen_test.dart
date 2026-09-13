// Tournament creation loads the owner's venues, quotes the draft through the
// server, and only posts after a confirmation. The fixtures mirror those three
// contracts rather than recomputing tournament economics in the test.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_create_tournament_screen.dart';

import '../screen_harness.dart';

const String kVenues = '/owner/venues';
const String kPreview = '/tournaments/preview';
const String kCreate = '/tournaments';

Map<String, dynamic> venue() => {
  'id': 'v-1',
  'name': 'Green Turf Arena',
  'city': 'Lahore',
  'sport': 'Football',
};

Map<String, dynamic> preview() => {
  'venue': {
    'id': 'v-1',
    'name': 'Green Turf Arena',
    'city': 'Lahore',
    'sportType': 'Football',
    'pricePerHour': 2000,
  },
  'config': <String, dynamic>{},
  'candidateHours': 10,
  'capacity': {
    'schedulable': true,
    'teams': 8,
    'fixtures': 7,
    'hoursNeeded': 7,
    'hoursAvailable': 10,
    'slotTotal': 14000,
    'rounds': const [],
  },
  'minimum': {
    'schedulable': true,
    'teams': 4,
    'fixtures': 3,
    'hoursNeeded': 3,
    'hoursAvailable': 10,
    'slotTotal': 6000,
    'rounds': const [],
  },
  'economics': {
    'atCapacity': {
      'teams': 8,
      'entryFee': 2000,
      'pool': 16000,
      'venueCost': 14000,
      'prize': 1200,
      'ownerEarning': 14800,
    },
    'atMinimum': {
      'teams': 4,
      'entryFee': 2000,
      'pool': 8000,
      'venueCost': 6000,
      'prize': 1200,
      'ownerEarning': 6800,
    },
  },
  'recommended': {
    'entryFee': 2000,
    'minTeams': 4,
    'venueCost': 6000,
    'targetMarginPercent': 25,
    'targetMargin': 1500,
    'achievable': true,
    'roundedTo': 100,
    'atMinTeams': {
      'teams': 4,
      'entryFee': 2000,
      'pool': 8000,
      'venueCost': 6000,
      'prize': 1200,
      'ownerEarning': 6800,
    },
  },
  'meta': {
    'scheduling': {'source': 'chronological'},
  },
};

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> settleTournament(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> pumpCreate(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerCreateTournamentScreen(),
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
    api.ok(kVenues, [venue()]);
    api.ok(kPreview, preview());
  });

  group('venue loading', () {
    testWidgets('a spinner stands while the venue list is in flight', (
      tester,
    ) async {
      api.ok(kVenues, [venue()], delay: const Duration(milliseconds: 300));
      await pumpCreate(tester, api);

      expectLoading(tester);
      await settleTournament(tester);
      expect(find.text('New tournament'), findsOneWidget);
      expect(find.text('Green Turf Arena · Lahore'), findsOneWidget);
    });

    testWidgets('no venues produces the server-backed empty prompt', (
      tester,
    ) async {
      api.ok(kVenues, const []);
      await pumpCreate(tester, api);
      await settleTournament(tester);

      expect(find.text('You need a venue first'), findsOneWidget);
      expect(find.textContaining('add a venue'), findsOneWidget);
    });

    testWidgets('a venue renders the economics panel and validates locally', (
      tester,
    ) async {
      await pumpCreate(tester, api);
      await settleTournament(tester);

      await tester.scrollUntilVisible(
        find.text('What this pays you'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        find.text('Post tournament'),
        500,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('What this pays you'), findsOneWidget);
      expect(find.text('Post tournament'), findsOneWidget);
      expect(
        find.text('Give the tournament a name'),
        findsOneWidget,
        reason: 'the button is blocked until the name is supplied',
      );
    });
  });

  group('posting', () {
    testWidgets(
      'confirmation precedes the create request and preserves the body',
      (tester) async {
        api.on(
          kCreate,
          FakeResponse(
            200,
            jsonEncode({
              'success': true,
              'message': 'Tournament posted.',
              'data': {},
            }),
          ),
        );
        await pumpCreate(tester, api);
        await settleTournament(tester);

        await tester.scrollUntilVisible(
          field('Tournament name'),
          500,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(field('Tournament name'), 'Friday Night Cup');
        await tester.scrollUntilVisible(
          field('Entry fee per team (PKR)'),
          500,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(field('Entry fee per team (PKR)'), '2000');
        await tester.pump(const Duration(milliseconds: 650));
        await settleTournament(tester);

        await tester.scrollUntilVisible(
          find.text('Post tournament'),
          500,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Post tournament'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Post this tournament?'), findsOneWidget);
        expect(api.countTo(kCreate), 0);

        await tester.tap(find.widgetWithText(ElevatedButton, 'Post it'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(api.countTo(kCreate), 1);
        final body = jsonDecode(api.to(kCreate).single.body!) as Map;
        expect(body['venueId'], 'v-1');
        expect(body['name'], 'Friday Night Cup');
        expect(body['entryFee'], 2000);
      },
    );
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the form present', (tester) async {
      ignoreOverflow();
      await pumpCreate(tester, api, textScale: 2.0);
      await settleTournament(tester);

      expect(find.text('New tournament'), findsOneWidget);
      expect(find.text('Green Turf Arena · Lahore'), findsOneWidget);
    });
  });
}
