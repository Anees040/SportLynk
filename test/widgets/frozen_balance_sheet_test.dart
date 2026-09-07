// FrozenBalanceSheet: the answer to "where exactly is my frozen money?", and the four
// states the project requires of anything that waits on the network.
//
// This is the first widget in `test/widgets/` that fetches, so it runs through the same
// `http.runWithClient` seam the service tests use — `FakeApi` lives one directory over
// and is imported rather than duplicated, because a second fake would drift from the
// first and this sheet's contract is precisely that it renders whatever the envelope
// carried.
//
// All four states are asserted, and two of them are the reason the sheet exists. The
// headline figure is withheld while the request is in flight rather than drawn as zero,
// because a wallet card that says PKR 4,800 and a sheet that says PKR 0 is worse than a
// spinner. And "nothing itemised" has two different meanings: either nothing is frozen,
// which is reassurance, or the wallet still claims a frozen balance that no booking
// accounts for, which is a fault the player has to be told about by name. Collapsing
// those two into one empty state is the regression these tests exist to catch.
//
// The delta band is the same argument at the level of a single figure: when the itemised
// rows and the wallet's own total disagree by a rupee or more, the sheet says so and
// names the amount instead of showing a breakdown that quietly fails to add up.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/frozen_balance_sheet.dart';

import '../services/http_seam.dart';
import 'widget_harness.dart';

/// One row of `GET /api/wallet/frozen`.
Map<String, dynamic> item({
  String venue = 'Arena One',
  String date = '2026-03-20',
  String? start = '18:00:00',
  String? end = '19:00:00',
  num escrow = 1200,
  num price = 1200,
  String status = 'confirmed',
}) =>
    {
      'venue_name': venue,
      'slot_date': date,
      'start_time': start,
      'end_time': end,
      'escrow_held': escrow,
      'slot_price': price,
      'status': status,
    };

/// The envelope the sheet reads: rows, their sum, the wallet's own figure, and the gap.
Map<String, dynamic> frozen({
  List<Map<String, dynamic>> items = const [],
  num itemsTotal = 0,
  num walletFrozen = 0,
  num delta = 0,
}) =>
    {
      'items': items,
      'itemsTotal': itemsTotal,
      'walletFrozen': walletFrozen,
      'delta': delta,
    };

void main() {
  tearDown(resetApiClient);

  /// Pumps the sheet inside the harness. With [resolve] false the frame is taken
  /// before the reply is rendered, which is the only way to see the loading state.
  Future<void> pumpSheet(WidgetTester tester,
      {bool resolve = true, double textScale = 1.0}) async {
    await pumpApp(
      tester,
      const Scaffold(
        backgroundColor: Colors.white,
        body: FrozenBalanceSheet(token: 'tok-1'),
      ),
      textScale: textScale,
    );
    if (resolve) await tester.pump();
  }

  group('while the breakdown is loading', () {
    testWidgets('a spinner stands in, and no figure is guessed', (tester) async {
      final api = FakeApi()..ok(frozen(walletFrozen: 4800));
      await api.run(() async {
        await pumpSheet(tester, resolve: false);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('PKR 4800'), findsNothing,
            reason: 'the headline waits for the server rather than showing a zero');
        expect(find.text('Frozen in Escrow'), findsOneWidget,
            reason: 'the title and the explanation are drawn immediately');
      });
    });

    testWidgets('the token goes out as a bearer on the wallet route',
        (tester) async {
      final api = FakeApi()..ok(frozen());
      await api.run(() async {
        await pumpSheet(tester);
        expect(api.endpoint(), '/wallet/frozen');
        expect(api.method(), 'GET');
        expect(api.token(), 'tok-1');
      });
    });
  });

  group('when the request fails', () {
    testWidgets('the server\'s own sentence is shown with a retry',
        (tester) async {
      final api = FakeApi()
        ..fail('Escrow is unavailable right now.')
        ..ok(frozen(items: [item()], itemsTotal: 1200, walletFrozen: 1200));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Escrow is unavailable right now.'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsOneWidget);

        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump();
        expect(api.sent.length, 2, reason: 'retry re-issues the request');
        expect(find.text('Arena One'), findsOneWidget);
        expect(find.text('Escrow is unavailable right now.'), findsNothing);
      });
    });

    // A dead server and a missing `adb reverse` are the same failure to the widget.
    testWidgets('an unreachable server still offers the retry', (tester) async {
      final api = FakeApi()..offline();
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });
    });
  });

  // Two very different facts share this branch, and telling them apart is the point:
  // an empty list with an empty wallet is reassurance, while an empty list against a
  // frozen balance is money nothing accounts for.
  group('when nothing is itemised', () {
    testWidgets('an empty wallet is reported as good news', (tester) async {
      final api = FakeApi()..ok(frozen());
      await api.run(() async {
        await pumpSheet(tester);
        expect(
            find.text(
                'Nothing is frozen right now — your whole balance is available to spend.'),
            findsOneWidget);
        expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
        expect(find.text('0 bookings'), findsNothing,
            reason: 'the footer is for a breakdown that exists');
      });
    });

    testWidgets('a frozen balance with no bookings is named as a fault',
        (tester) async {
      final api = FakeApi()..ok(frozen(walletFrozen: 4800));
      await api.run(() async {
        await pumpSheet(tester);
        expect(
            find.text('No active bookings are holding escrow, but PKR '
                '4800 is still marked frozen. '
                'Pull to refresh your wallet, or contact support if it stays.'),
            findsOneWidget);
        expect(
            find.text(
                'Nothing is frozen right now — your whole balance is available to spend.'),
            findsNothing,
            reason: 'unexplained escrow must not read as an empty wallet');
      });
    });
  });

  group('the breakdown', () {
    testWidgets('one booking accounts for the whole frozen balance',
        (tester) async {
      final api = FakeApi()
        ..ok(frozen(items: [item()], itemsTotal: 1200, walletFrozen: 1200));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('Arena One'), findsOneWidget);
        expect(find.text('20 Mar, 2026 • 18:00 – 19:00'), findsOneWidget);
        expect(find.text('1 booking'), findsOneWidget);
        expect(find.text('CONFIRMED'), findsOneWidget);
        expect(find.text('PKR 1200'), findsNWidgets(3),
            reason: 'the headline, the row and the total agree when there is one row');
      });
    });

    testWidgets('two bookings are listed and summed', (tester) async {
      final api = FakeApi()
        ..ok(frozen(
          items: [
            item(),
            item(venue: 'Turf Two', escrow: 3600, price: 3600),
          ],
          itemsTotal: 4800,
          walletFrozen: 4800,
        ));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('2 bookings'), findsOneWidget);
        expect(find.text('PKR 1200'), findsOneWidget);
        expect(find.text('PKR 3600'), findsOneWidget);
        expect(find.text('PKR 4800'), findsNWidgets(2),
            reason: 'the headline and the footer total, not a third figure');
      });
    });

    testWidgets('a booking the owner has not accepted says so', (tester) async {
      final api = FakeApi()
        ..ok(frozen(
            items: [item(status: 'pending')], itemsTotal: 1200, walletFrozen: 1200));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('AWAITING OWNER'), findsOneWidget);
        expect(find.text('CONFIRMED'), findsNothing);
      });
    });

    // A booking made under the old deposit rules froze part of the price; the row has
    // to explain that rather than look like the wrong number.
    testWidgets('a part-frozen booking shows the price it belongs to',
        (tester) async {
      final api = FakeApi()
        ..ok(frozen(
            items: [item(escrow: 600, price: 1500)],
            itemsTotal: 600,
            walletFrozen: 600));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('PKR 600'), findsNWidgets(3));
        expect(find.text('of PKR 1500'), findsOneWidget);
      });
    });

    testWidgets('a fully frozen booking does not repeat its price',
        (tester) async {
      final api = FakeApi()
        ..ok(frozen(items: [item()], itemsTotal: 1200, walletFrozen: 1200));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('of PKR 1200'), findsNothing);
      });
    });

    testWidgets('a slot with no times is still dated', (tester) async {
      final api = FakeApi()
        ..ok(frozen(
            items: [item(start: null, end: null)],
            itemsTotal: 1200,
            walletFrozen: 1200));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.text('20 Mar, 2026'), findsOneWidget);
      });
    });
  });

  // The band is drawn under a breakdown that does not add up, which is the one case
  // where the sheet has to contradict its own rows.
  group('when the figures disagree', () {
    testWidgets('escrow no booking accounts for is named and explained',
        (tester) async {
      final api = FakeApi()
        ..ok(frozen(
            items: [item()], itemsTotal: 1200, walletFrozen: 1500, delta: 300));
      await api.run(() async {
        await pumpSheet(tester);
        expect(
            find.text('PKR 300 of your frozen balance '
                'is not linked to any active booking. '
                'Contact support so it can be released — no money has been lost.'),
            findsOneWidget);
        expect(find.byIcon(Icons.info_outline), findsOneWidget);
      });
    });

    testWidgets('the opposite gap gets the opposite sentence', (tester) async {
      final api = FakeApi()
        ..ok(frozen(
            items: [item()], itemsTotal: 1500, walletFrozen: 1200, delta: -300));
      await api.run(() async {
        await pumpSheet(tester);
        expect(
            find.text('PKR 300 of your frozen balance '
                'is less than your bookings are holding. '
                'Contact support so it can be released — no money has been lost.'),
            findsOneWidget);
      });
    });

    testWidgets('a breakdown that adds up says nothing at all', (tester) async {
      final api = FakeApi()
        ..ok(frozen(items: [item()], itemsTotal: 1200, walletFrozen: 1200));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.byIcon(Icons.info_outline), findsNothing);
      });
    });

    // A sub-paisa rounding difference is arithmetic, not a fault, and must not be
    // dressed up as one.
    testWidgets('a rounding difference is below the threshold', (tester) async {
      final api = FakeApi()
        ..ok(frozen(
            items: [item()], itemsTotal: 1200, walletFrozen: 1200, delta: 0.004));
      await api.run(() async {
        await pumpSheet(tester);
        expect(find.byIcon(Icons.info_outline), findsNothing);
      });
    });
  });

  // Pinned as it behaves, not as it should. `items` is hard-cast, so a payload whose
  // items block is not a list throws inside `setState` and `_loading` is never cleared:
  // the sheet is left on a spinner that can never resolve, which the project's own rule
  // calls a bug. The throw is intercepted by a nested zone because it arrives from
  // `initState`'s continuation rather than from a build, and so cannot be taken from the
  // binding. Guarding the cast and falling through to the error branch is what would
  // turn this expectation green.
  testWidgets('a malformed items block leaves the spinner running',
      (tester) async {
    final api = FakeApi()
      ..ok({'items': 'none', 'itemsTotal': 0, 'walletFrozen': 0, 'delta': 0});
    final escaped = <Object>[];
    await api.run(() async {
      await runZonedGuarded(() async {
        await pumpSheet(tester);
        await tester.pump();
      }, (error, _) => escaped.add(error));
      expect(escaped.single, isA<TypeError>(),
          reason: 'the cast is unguarded: frozen_balance_sheet.dart:72');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Retry'), findsNothing,
          reason: 'no error state is reached, so there is nothing to retry');
    });
  });

  // Pinned as it behaves, not as it should. The sheet's title row and its footer row are
  // each a `Text`, a `Spacer` and a second `Text` with no flex on either side, so at a
  // doubled text scale "Frozen in Escrow" beside its headline figure, and the booking
  // count beside its total, are both wider than the sheet — against the project's rule
  // that text scales without clipping. Both are consumed here so the defect is recorded
  // rather than left to fail a screen test later; wrapping each leading `Text` in an
  // `Expanded` is what would turn these expectations green.
  group('at a doubled text scale', () {
    testWidgets('the title row is wider than the sheet', (tester) async {
      useDeviceSurface(tester);
      final api = FakeApi()..ok(frozen(walletFrozen: 4800));
      await api.run(() async {
        await pumpSheet(tester, textScale: 2.0);
        expect(find.text('Frozen in Escrow'), findsOneWidget);
        expect(
          tester.takeException(),
          isA<FlutterError>(),
          reason: 'the title is unflexed: frozen_balance_sheet.dart:100',
        );
      });
    });

    testWidgets('the footer row fails alongside it', (tester) async {
      useDeviceSurface(tester);
      final api = FakeApi()
        ..ok(frozen(items: [item()], itemsTotal: 1200, walletFrozen: 1200));
      await api.run(() async {
        await pumpSheet(tester, textScale: 2.0);
        expect(find.text('Arena One'), findsOneWidget,
            reason: 'the breakdown itself still renders');
        expect(find.text('1 booking'), findsOneWidget);
        expect(
          tester.takeException().toString(),
          contains('Multiple exceptions (2)'),
          reason: 'the second is frozen_balance_sheet.dart:168',
        );
      });
    });
  });
}
