// The verification queue is read-only until the owner confirms an agreed result.
// A failed read is intentionally pinned as the current empty queue because the
// service returns [] for non-success responses.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_match_verify_screen.dart';

import '../screen_harness.dart';

const String kPending = '/matches/owner/pending';

Map<String, dynamic> side(String id, String name, int elo) => {
  'id': id,
  'name': name,
  'elo': elo,
  'ranked': true,
  'played': 4,
  'wins': 3,
  'losses': 1,
  'draws': 0,
  'eloFrozen': false,
};

Map<String, dynamic> match() => {
  'id': 'm-1',
  'status': 'awaiting_owner',
  'sport': 'Football',
  'challenger': side('t-1', 'Lahore Lions', 1200),
  'opponent': side('t-2', 'Karachi Kings', 1180),
  'scoreChallenger': 3,
  'scoreOpponent': 1,
  'winnerTeam': 't-1',
  'eloApplied': false,
  'resultsLocked': false,
  'resultsIn': 2,
  'slotStarted': true,
  'iAmVenueOwner': true,
  'booking': {
    'id': 'b-1',
    'slotDate': '2026-09-20',
    'startTime': '18:00:00',
    'endTime': '19:00:00',
    'venueName': 'Green Turf Arena',
    'venueCity': 'Lahore',
  },
  'submissions': [
    {
      'teamId': 't-1',
      'teamName': 'Lahore Lions',
      'scoreChallenger': 3,
      'scoreOpponent': 1,
      'winnerTeam': 't-1',
    },
    {
      'teamId': 't-2',
      'teamName': 'Karachi Kings',
      'scoreChallenger': 3,
      'scoreOpponent': 1,
      'winnerTeam': 't-1',
    },
  ],
};

Future<void> settleQueue(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> revealVerifyAction(WidgetTester tester) async {
  final list = find.byType(ListView).first;
  await tester.drag(list, const Offset(0, -600));
  await tester.pump();
}

Future<RouteLog> pumpVerify(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerMatchVerifyScreen(),
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
    api.ok(kPending, [match()]);
  });

  group('the queue', () {
    testWidgets('shows a spinner before the pending result arrives', (
      tester,
    ) async {
      api.ok(kPending, [match()], delay: const Duration(milliseconds: 300));
      await pumpVerify(tester, api);
      expectLoading(tester);

      await tester.pump(const Duration(milliseconds: 400));
      await settleQueue(tester);
      expect(find.text('Lahore Lions'), findsWidgets);
    });

    testWidgets('renders both captains, the agreed score and the action', (
      tester,
    ) async {
      await pumpVerify(tester, api);
      await settleQueue(tester);

      expect(find.text('Lahore Lions'), findsWidgets);
      expect(find.text('Karachi Kings'), findsWidgets);
      expect(find.text('3 – 1'), findsAtLeastNWidgets(1));
      await revealVerifyAction(tester);
      expect(find.text('Verify result'), findsOneWidget);
    });

    testWidgets('an empty queue explains why there is nothing to verify', (
      tester,
    ) async {
      api.ok(kPending, const []);
      await pumpVerify(tester, api);
      await settleQueue(tester);

      expect(find.textContaining('Nothing to verify'), findsOneWidget);
    });

    testWidgets('a failed load reads as the empty queue, not an error', (
      tester,
    ) async {
      // Defect, pinned: MatchService.ownerPending returns [] for a non-success,
      // and the screen has no separate error-with-retry branch.
      api.fail(kPending, 'boom');
      await pumpVerify(tester, api);
      await settleQueue(tester);

      expect(find.textContaining('Nothing to verify'), findsOneWidget);
    });
  });

  testWidgets('confirmation precedes verification and reloads the queue', (
    tester,
  ) async {
    api.on(
      '/matches/m-1/verify',
      FakeResponse(
        200,
        jsonEncode({
          'success': true,
          'message': 'Result verified.',
          'data': {},
        }),
      ),
    );
    await pumpVerify(tester, api);
    await settleQueue(tester);
    api.ok(kPending, const []);

    await revealVerifyAction(tester);
    await tapVisible(tester, find.text('Verify result'));
    expect(find.text('Confirm this result?'), findsOneWidget);
    expect(api.countTo('/matches/m-1/verify'), 0);

    await tapVisible(tester, find.text('Confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(api.countTo('/matches/m-1/verify'), 1);
    expect(find.text('Result verified.'), findsOneWidget);
    await settleQueue(tester);
    expect(find.textContaining('Nothing to verify'), findsOneWidget);
  });

  testWidgets('a doubled text scale keeps the queue readable', (tester) async {
    ignoreOverflow();
    await pumpVerify(tester, api, textScale: 2.0);
    await settleQueue(tester);
    expect(find.text('Lahore Lions'), findsWidgets);
  });
}
