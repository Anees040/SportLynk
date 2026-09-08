// The Apply sheet: the only place in the product where a suggested price becomes a
// real one, and therefore the only place where a model's opinion can reach a player's
// wallet.
//
// Everything asserted here follows from that. The sheet is a consent step, so the
// tests care far more about what it refuses to offer than about what it draws. A
// booked slot's price is what a player already agreed to pay; a locked slot is
// mid-checkout; a past slot is history. None of the three may be selected, and none of
// the three may be hidden either — an owner who tapped "All" and was told "applied to 6
// of 9" needs the missing three and their reasons already on screen, not in a second
// request. The greyed rows with their own sentence are the feature, and they are pinned
// row by row.
//
// The pre-selection is the second contract worth pinning. The suggestion was computed
// for one venue, one date and one hour; opening on "today" or pre-ticking the whole day
// would invite a Saturday-peak price onto a Tuesday morning, so the sheet opens on the
// suggestion's own date and arrives with exactly the suggestion's own hour ticked. Every
// further slot is an extrapolation the owner has to perform deliberately.
//
// The per-row delta is the third. Slots drift apart in price after a partial apply, so a
// single headline "+30%" would be wrong on some rows; each row prices itself, and a row
// already at the target says "no change" rather than showing an arrow to itself.
//
// The four states the project requires are all present, and the failure state is
// asserted twice over — once for the load and once for the PATCH — because they surface
// through the same band and a regression could easily leave only one of them wired.
//
// The request assertions matter as much as the pixels: this widget's PATCH is the write.
// The endpoint, the bearer, the slot ids and the price are all pinned, because a sheet
// that renders perfectly and sends the wrong body is the worst outcome available here.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/providers/auth_provider.dart';
import 'package:sportlynk/services/pricing_service.dart';
import 'package:sportlynk/widgets/apply_price_sheet.dart';

import '../services/http_seam.dart';
import 'widget_harness.dart';

/// A session holding a token, with no login and no network. `token` is a plain getter
/// on the real provider, so subclassing keeps the type `Provider.of` looks up exact.
class _FakeAuth extends AuthProvider {
  _FakeAuth(this._token);

  final String? _token;

  @override
  String? get token => _token;
}

/// The date the whole file works in. Fixed rather than derived from `DateTime.now()`:
/// the sheet marks a slot past by comparing it to the wall clock, so a relative date is
/// the only way to keep "past" and "future" meaningful in a test that may run at any
/// hour.
final DateTime _today = DateTime.now();

String _iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Tomorrow, so every hour of the day is in the future regardless of when the suite
/// runs. Used by every case that is not specifically about the past.
final DateTime _tomorrow = _today.add(const Duration(days: 1));

/// One row of `GET /api/owner/slots`.
Map<String, dynamic> slot({
  String id = 's1',
  int hour = 20,
  String status = 'available',
  String? effective,
  num price = 1200,
}) =>
    {
      'id': id,
      'start_time': '${hour.toString().padLeft(2, '0')}:00:00',
      'status': status,
      'effective_status': ?effective,
      'price': price,
    };

/// A suggestion for one hour of one day, defaulting to tomorrow at 20:00 so the target
/// slot is always selectable.
PriceSuggestion suggestion({
  int base = 1200,
  int suggested = 1500,
  int? hour = 20,
  String? date,
}) =>
    PriceSuggestion(
      source: 'model',
      basePrice: base,
      suggestedPrice: suggested,
      deltaPct: 25,
      venueId: 'v1',
      slotDate: date ?? _iso(_tomorrow),
      hour: hour,
    );

void main() {
  tearDown(resetApiClient);

  /// Opens the sheet the way the pricing card does, and records what it returned.
  ///
  /// The sheet is a route rather than a widget, so it is pushed from a button in the
  /// home tree; that also means its own `context` outlives the pop, which is what the
  /// snackbar assertions depend on.
  Future<List<bool?>> openSheet(
    WidgetTester tester, {
    PriceSuggestion? s,
    String? token = 'tok-1',
    double textScale = 1.0,
  }) async {
    final results = <bool?>[];
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          backgroundColor: AppColors.background,
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final r = await showApplyPriceSheet(
                  context,
                  venueId: 'v1',
                  suggestion: s ?? suggestion(),
                );
                results.add(r);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: _FakeAuth(token)),
      ],
      textScale: textScale,
    );
    await tester.tap(find.text('open'));
    return results;
  }

  /// Pumps a modal route's entrance out. One `pump` leaves the sheet mid-transition, and
  /// a tap on a widget that has not reached its final offset derives a hit-test point
  /// off-screen and silently misses.
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Opens the sheet and lets both the transition and the slot request finish.
  Future<List<bool?>> openLoaded(
    WidgetTester tester, {
    PriceSuggestion? s,
    String? token = 'tok-1',
    double textScale = 1.0,
  }) async {
    final r = await openSheet(tester, s: s, token: token, textScale: textScale);
    await settleSheet(tester);
    await tester.pump();
    return r;
  }

  group('opening the sheet', () {
    testWidgets('the price being applied is in the heading, not the delta',
        (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(suggested: 1500));
        expect(find.text('Apply PKR 1,500/hr'), findsOneWidget,
            reason: 'the owner is agreeing to a rupee figure, not to a percentage');
        expect(
          find.text('Choose the slots to reprice. Booked and held slots cannot change.'),
          findsOneWidget,
        );
      });
    });

    testWidgets('a five-figure price is grouped', (tester) async {
      final api = FakeApi()..ok([slot(price: 9000)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(base: 9000, suggested: 12500));
        expect(find.text('Apply PKR 12,500/hr'), findsOneWidget);
      });
    });

    testWidgets('the slots asked for are the suggestion\'s own day and venue',
        (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester);
        expect(api.endpoint().split('?').first, '/owner/slots');
        expect(api.query(), {'date': _iso(_tomorrow), 'venueId': 'v1'});
        expect(api.method(), 'GET');
        expect(api.token(), 'tok-1');
      });
    });

    // The sheet's whole reason for existing is that the suggestion belongs to one date.
    // Landing on today would offer a peak-hour price against a different day's demand.
    testWidgets('a suggestion for a later day opens on that day', (tester) async {
      final later = _today.add(const Duration(days: 9));
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(date: _iso(later)));
        expect(api.query()['date'], _iso(later));
        expect(find.textContaining('Today'), findsNothing);
      });
    });

    testWidgets('a suggestion with no date falls back to today', (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(date: ''));
        expect(api.query()['date'], _iso(_today));
        expect(find.textContaining('Today · '), findsOneWidget);
      });
    });

    testWidgets('a spinner stands in while the day is being fetched',
        (tester) async {
      final completer = Completer<void>();
      final api = FakeApi()..ok([slot()], defer: completer.future);
      await api.run(() async {
        await openSheet(tester);
        await settleSheet(tester);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Apply PKR 1,500/hr'), findsOneWidget,
            reason: 'the heading is known before the request answers');
        expect(find.text('Nothing selected'), findsOneWidget);
        completer.complete();
        await tester.pump();
      });
    });
  });

  group('what the sheet arrives having ticked', () {
    // Pre-ticking the whole day would let one tap reprice hours the model never scored.
    testWidgets('only the hour the suggestion was computed for', (tester) async {
      final api = FakeApi()
        ..ok([
          slot(id: 's18', hour: 18),
          slot(id: 's20', hour: 20),
          slot(id: 's22', hour: 22),
        ]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(hour: 20));
        expect(find.text('1 slot selected'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
        expect(find.byIcon(Icons.circle_outlined), findsNWidgets(2));
      });
    });

    testWidgets('nothing at all when the suggestion names no hour',
        (tester) async {
      final api = FakeApi()..ok([slot(id: 's18', hour: 18), slot(id: 's20')]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(hour: null));
        expect(find.text('Nothing selected'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      });
    });

    testWidgets('nothing when that hour is already booked', (tester) async {
      final api = FakeApi()
        ..ok([slot(id: 's20', status: 'booked'), slot(id: 's21', hour: 21)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(hour: 20));
        expect(find.text('Nothing selected'), findsOneWidget,
            reason: 'a booked slot cannot be pre-selected any more than it can be tapped');
      });
    });

    testWidgets('the slots are ordered by hour whatever order they arrived in',
        (tester) async {
      final api = FakeApi()
        ..ok([
          slot(id: 's22', hour: 22),
          slot(id: 's08', hour: 8),
          slot(id: 's20', hour: 20),
        ]);
      await api.run(() async {
        await openLoaded(tester);
        final eight = tester.getTopLeft(find.text('08:00')).dy;
        final twenty = tester.getTopLeft(find.text('20:00')).dy;
        final twentyTwo = tester.getTopLeft(find.text('22:00')).dy;
        expect(eight, lessThan(twenty));
        expect(twenty, lessThan(twentyTwo));
      });
    });

    testWidgets('a row with no id is dropped rather than drawn unusable',
        (tester) async {
      final api = FakeApi()..ok([slot(id: ''), slot(id: 's21', hour: 21)]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('21:00'), findsOneWidget);
        expect(find.text('20:00'), findsNothing,
            reason: 'a slot with no id could never be sent in the PATCH');
      });
    });
  });

  // Each of these rows is shown, greyed, with its own reason — the alternative is an
  // owner who selected nine and was told six, with no way to see which three.
  group('the slots that cannot be repriced', () {
    testWidgets('a booked slot says the price is locked in', (tester) async {
      final api = FakeApi()..ok([slot(status: 'booked')]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('booked — price is locked in'), findsOneWidget);
        expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
        expect(find.byIcon(Icons.circle_outlined), findsNothing);
      });
    });

    testWidgets('a slot held mid-checkout names the player', (tester) async {
      final api = FakeApi()..ok([slot(effective: 'locked')]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('held by a player right now'), findsOneWidget);
      });
    });

    testWidgets('a blocked slot is labelled blocked', (tester) async {
      final api = FakeApi()..ok([slot(status: 'blocked')]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('blocked'), findsOneWidget);
      });
    });

    testWidgets('an unrecognised status still refuses the tap', (tester) async {
      final api = FakeApi()..ok([slot(status: 'quarantined')]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('not available'), findsOneWidget,
            reason: 'an unknown status is treated as unsafe, not as available');
      });
    });

    // `effective_status` folds a live hold in server-side, so it wins over the raw
    // column whenever both are present.
    testWidgets('a live hold beats the stored status', (tester) async {
      final api = FakeApi()..ok([slot(status: 'available', effective: 'locked')]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('held by a player right now'), findsOneWidget);
        expect(find.text('Nothing selected'), findsOneWidget);
      });
    });

    testWidgets('a greyed row shows its current price and no arrow',
        (tester) async {
      final api = FakeApi()..ok([slot(status: 'booked', price: 1200)]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('PKR 1,200'), findsOneWidget);
        expect(find.text('PKR 1,200 → 1,500'), findsNothing);
      });
    });

    testWidgets('tapping one changes nothing', (tester) async {
      final api = FakeApi()..ok([slot(status: 'booked')]);
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('20:00'));
        await tester.pump();
        expect(find.text('Nothing selected'), findsOneWidget);
      });
    });

    // An hour that has already gone by on today's schedule cannot be repriced, and the
    // reason is the clock rather than the status.
    testWidgets('an hour that has passed today says so', (tester) async {
      if (_today.hour < 1) return;
      final api = FakeApi()..ok([slot(hour: 0)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(hour: 0, date: _iso(_today)));
        expect(find.text('already passed'), findsOneWidget);
        expect(find.text('Nothing selected'), findsOneWidget);
      });
    });
  });

  group('choosing the slots', () {
    testWidgets('a tap ticks a row and the footer counts it', (tester) async {
      final api = FakeApi()
        ..ok([slot(id: 's20'), slot(id: 's21', hour: 21)]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('1 slot selected'), findsOneWidget);
        await tester.tap(find.text('21:00'));
        await tester.pump();
        expect(find.text('2 slots selected'), findsOneWidget,
            reason: 'the count is pluralised, and it is a count of slots not of hours');
      });
    });

    testWidgets('a second tap unticks it', (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('20:00'));
        await tester.pump();
        expect(find.text('Nothing selected'), findsOneWidget);
      });
    });

    testWidgets('All takes every selectable slot and nothing else',
        (tester) async {
      final api = FakeApi()
        ..ok([
          slot(id: 's18', hour: 18),
          slot(id: 's19', hour: 19, status: 'booked'),
          slot(id: 's20'),
        ]);
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('All'));
        await tester.pump();
        expect(find.text('2 slots selected'), findsOneWidget,
            reason: 'the booked hour is not swept up by "All"');
      });
    });

    testWidgets('All becomes Clear once everything is ticked', (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('Clear'), findsOneWidget,
            reason: 'the one selectable slot is already the pre-selection');
        await tester.tap(find.text('Clear'));
        await tester.pump();
        expect(find.text('Nothing selected'), findsOneWidget);
        expect(find.text('All'), findsOneWidget);
      });
    });

    testWidgets('a day with nothing selectable disables the toggle',
        (tester) async {
      final api = FakeApi()..ok([slot(status: 'booked')]);
      await api.run(() async {
        await openLoaded(tester);
        final button = tester.widget<TextButton>(
          find.ancestor(of: find.text('All'), matching: find.byType(TextButton)),
        );
        expect(button.onPressed, isNull);
      });
    });
  });

  group('the rupee change on each row', () {
    testWidgets('a rise shows the arrow and both figures', (tester) async {
      final api = FakeApi()..ok([slot(price: 1200)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(suggested: 1500));
        expect(find.text('PKR 1,200 → 1,500'), findsOneWidget);
        final text = tester.widget<Text>(find.text('PKR 1,200 → 1,500'));
        expect(text.style?.color, AppColors.success);
      });
    });

    testWidgets('a cut is coloured against the owner\'s revenue', (tester) async {
      final api = FakeApi()..ok([slot(price: 1800)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(suggested: 1500));
        final text = tester.widget<Text>(find.text('PKR 1,800 → 1,500'));
        expect(text.style?.color, AppColors.error);
      });
    });

    // Slots drift apart after a partial apply, so the row prices itself rather than
    // inheriting the card's headline delta.
    testWidgets('two slots at different prices each price themselves',
        (tester) async {
      final api = FakeApi()
        ..ok([slot(id: 's20', price: 1200), slot(id: 's21', hour: 21, price: 900)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(suggested: 1500));
        expect(find.text('PKR 1,200 → 1,500'), findsOneWidget);
        expect(find.text('PKR 900 → 1,500'), findsOneWidget);
      });
    });

    testWidgets('a slot already at the price says so instead of pointing at itself',
        (tester) async {
      final api = FakeApi()..ok([slot(price: 1500)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(suggested: 1500));
        expect(find.text('no change'), findsOneWidget);
        expect(find.text('PKR 1,500 → 1,500'), findsNothing);
      });
    });

    testWidgets('a sub-rupee difference counts as no change', (tester) async {
      final api = FakeApi()..ok([slot(price: 1500.4)]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(suggested: 1500));
        expect(find.text('no change'), findsOneWidget);
      });
    });

    testWidgets('a price sent as a string is still read', (tester) async {
      final api = FakeApi()..ok([<String, dynamic>{...slot(), 'price': '1200.00'}]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(suggested: 1500));
        expect(find.text('PKR 1,200 → 1,500'), findsOneWidget,
            reason: 'Postgres numerics arrive as strings over JSON');
      });
    });
  });

  group('moving between days', () {
    testWidgets('the forward chevron fetches the next day', (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.byIcon(Icons.chevron_right_rounded));
        await tester.pump();
        await tester.pump();
        expect(api.sent.length, 2);
        expect(api.query(1)['date'],
            _iso(_tomorrow.add(const Duration(days: 1))));
      });
    });

    testWidgets('the back chevron is dead on today', (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester, s: suggestion(date: _iso(_today), hour: null));
        final back = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.chevron_left_rounded),
            matching: find.byType(IconButton),
          ),
        );
        expect(back.onPressed, isNull,
            reason: 'the schedule only moves forward: no repricing the past');
      });
    });

    testWidgets('a day away from today can be stepped back', (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.byIcon(Icons.chevron_left_rounded));
        await tester.pump();
        await tester.pump();
        expect(api.query(1)['date'], _iso(_today));
      });
    });

    // Carrying a tick across a day change would apply a price to a slot the owner never
    // looked at.
    testWidgets('changing day drops the previous day\'s selection',
        (tester) async {
      final api = FakeApi()
        ..ok([slot(id: 's20')])
        ..ok([slot(id: 's30', hour: 20)]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('1 slot selected'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.chevron_right_rounded));
        await tester.pump();
        await tester.pump();
        expect(find.text('1 slot selected'), findsOneWidget,
            reason: 'the new day re-runs the pre-selection rather than keeping ids');
      });
    });
  });

  group('a day with no schedule', () {
    testWidgets('the empty state says what to do about it', (tester) async {
      final api = FakeApi()..ok(<Map<String, dynamic>>[]);
      await api.run(() async {
        await openLoaded(tester);
        expect(
          find.text('No slots on this day.\nGenerate the schedule first, then come back.'),
          findsOneWidget,
        );
        expect(find.text('Nothing selected'), findsOneWidget);
      });
    });

    testWidgets('the apply button is dead with nothing ticked', (tester) async {
      final api = FakeApi()..ok(<Map<String, dynamic>>[]);
      await api.run(() async {
        await openLoaded(tester);
        final button = tester.widget<ElevatedButton>(
          find.ancestor(
            of: find.text('Apply price'),
            matching: find.byType(ElevatedButton),
          ),
        );
        expect(button.onPressed, isNull);
      });
    });
  });

  group('when the day cannot be loaded', () {
    testWidgets('the server\'s own sentence is shown', (tester) async {
      final api = FakeApi()..fail('That venue is not yours.');
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('That venue is not yours.'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });
    });

    testWidgets('an unreachable server gets a sentence of its own', (tester) async {
      final api = FakeApi()..offline();
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('Could not load slots for this day.'), findsOneWidget);
      });
    });

    // The band is not a dead end: stepping to another day re-issues the request, which
    // is the retry this sheet offers.
    testWidgets('stepping to another day clears the band', (tester) async {
      final api = FakeApi()
        ..fail('That venue is not yours.')
        ..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester);
        expect(find.text('That venue is not yours.'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.chevron_right_rounded));
        await tester.pump();
        await tester.pump();
        expect(find.text('That venue is not yours.'), findsNothing);
        expect(find.text('20:00'), findsOneWidget);
      });
    });
  });

  group('applying the price', () {
    testWidgets('the PATCH carries the ticked ids and the suggested price',
        (tester) async {
      final api = FakeApi()
        ..ok([slot(id: 's20'), slot(id: 's21', hour: 21)])
        ..ok({'updated': 2, 'skipped': <Map<String, dynamic>>[]},
            extra: {'message': 'Price applied to 2 of 2 slots'});
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('21:00'));
        await tester.pump();
        await tester.tap(find.text('Apply price'));
        await tester.pump();

        expect(api.endpoint(1), '/owner/venues/v1/slots/price');
        expect(api.method(1), 'PATCH');
        expect(api.token(1), 'tok-1');
        expect(api.body(1)['price'], 1500);
        expect(
          (api.body(1)['slotIds'] as List).cast<String>()..sort(),
          ['s20', 's21'],
        );
      });
    });

    testWidgets('the button shows a spinner and refuses a second press',
        (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..hang();
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        expect(find.text('Apply price'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        final button = tester.widget<ElevatedButton>(
          find.ancestor(
            of: find.byType(CircularProgressIndicator),
            matching: find.byType(ElevatedButton),
          ),
        );
        expect(button.onPressed, isNull,
            reason: 'a double tap would issue the write twice');
      });
    });

    testWidgets('the sheet closes reporting success to its caller',
        (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..ok({'updated': 1, 'skipped': <Map<String, dynamic>>[]},
            extra: {'message': 'Price applied to 1 of 1 slot'});
      await api.run(() async {
        final results = await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await settleSheet(tester);
        expect(results.single, isTrue,
            reason: 'the card above refreshes on a true result and not otherwise');
        expect(find.text('Apply PKR 1,500/hr'), findsNothing);
      });
    });

    testWidgets('the server\'s own sentence is what the snackbar shows',
        (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..ok({'updated': 1, 'skipped': <Map<String, dynamic>>[]},
            extra: {'message': 'Price applied to 1 of 1 slot'});
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Price applied to 1 of 1 slot'), findsOneWidget);
      });
    });

    testWidgets('a partial apply names how many were skipped and why',
        (tester) async {
      final api = FakeApi()
        ..ok([slot(id: 's20'), slot(id: 's21', hour: 21)])
        ..ok({
          'updated': 1,
          'skipped': [
            {'id': 's21', 'reason': 'booked'},
          ],
        }, extra: {'message': 'Price applied to 1 of 2 slots'});
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('21:00'));
        await tester.pump();
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(
          find.text('Price applied to 1 of 2 slots (1 skipped — already booked)'),
          findsOneWidget,
          reason: 'the owner learns which three of nine without opening the sheet again',
        );
      });
    });

    testWidgets('the most common skip reason is the one reported',
        (tester) async {
      final api = FakeApi()
        ..ok([
          slot(id: 's19', hour: 19),
          slot(id: 's20'),
          slot(id: 's21', hour: 21),
        ])
        ..ok({
          'updated': 0,
          'skipped': [
            {'id': 's19', 'reason': 'locked'},
            {'id': 's20', 'reason': 'unchanged'},
            {'id': 's21', 'reason': 'unchanged'},
          ],
        }, extra: {'message': 'Price applied to 0 of 3 slots'});
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('All'));
        await tester.pump();
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(
          find.text(
              'Price applied to 0 of 3 slots (3 skipped — already at this price)'),
          findsOneWidget,
        );
      });
    });

    testWidgets('a reason with no phrase of its own is passed through',
        (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..ok({
          'updated': 0,
          'skipped': [
            {'id': 's20', 'reason': 'venue_suspended'},
          ],
        }, extra: {'message': 'Nothing applied'});
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Nothing applied (1 skipped — venue_suspended)'),
            findsOneWidget);
      });
    });

    testWidgets('a skip list of bare ids still gets a phrase', (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..ok({'updated': 0, 'skipped': ['s20']},
            extra: {'message': 'Nothing applied'});
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Nothing applied (1 skipped — see the schedule)'),
            findsOneWidget);
      });
    });

    testWidgets('a full apply says nothing about skips', (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..ok({'updated': 1, 'skipped': <Map<String, dynamic>>[]},
            extra: {'message': 'Price applied to 1 of 1 slot'});
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('skipped'), findsNothing);
      });
    });
  });

  group('when the write is refused', () {
    testWidgets('the sheet stays open with the reason and the ticks intact',
        (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..fail('Another owner changed this slot. Reload and try again.');
      await api.run(() async {
        final results = await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Another owner changed this slot. Reload and try again.'),
            findsOneWidget);
        expect(find.text('1 slot selected'), findsOneWidget,
            reason: 'losing the selection would make the owner choose all over again');
        expect(results, isEmpty, reason: 'the sheet did not pop');
        expect(find.text('Apply price'), findsOneWidget,
            reason: 'the button comes back rather than staying on its spinner');
      });
    });

    testWidgets('an unreachable server gets the sheet\'s own sentence',
        (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..offline();
      await api.run(() async {
        await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Could not apply the price.'), findsOneWidget);
      });
    });

    testWidgets('a second attempt is allowed and can succeed', (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..fail('Try again.')
        ..ok({'updated': 1, 'skipped': <Map<String, dynamic>>[]},
            extra: {'message': 'Price applied to 1 of 1 slot'});
      await api.run(() async {
        final results = await openLoaded(tester);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await settleSheet(tester);
        expect(api.sent.length, 3);
        expect(results.single, isTrue);
      });
    });

    // A session with no token still sends, because the server is the authority on who
    // may write; the sheet's job is to surface the refusal rather than to pre-judge it.
    testWidgets('a missing token sends an empty bearer and shows the refusal',
        (tester) async {
      final api = FakeApi()
        ..ok([slot()])
        ..fail('Not authorised.', status: 401);
      await api.run(() async {
        await openLoaded(tester, token: null);
        await tester.tap(find.text('Apply price'));
        await tester.pump();
        await tester.pump();
        expect(api.token(1), isNull);
        expect(find.text('Not authorised.'), findsOneWidget);
      });
    });
  });

  group('dismissing without applying', () {
    testWidgets('a drag down returns nothing rather than false', (tester) async {
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        final results = await openLoaded(tester);
        await tester.drag(find.text('20:00'), const Offset(0, 600));
        await settleSheet(tester);
        await settleSheet(tester);
        expect(results.single, isNull,
            reason: 'null and false both mean "do not refresh", and neither wrote');
        expect(api.sent.length, 1, reason: 'no PATCH was issued');
      });
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the sheet still lays out', (tester) async {
      useDeviceSurface(tester);
      final api = FakeApi()
        ..ok([slot(id: 's20'), slot(id: 's21', hour: 21, status: 'booked')]);
      await api.run(() async {
        await openLoaded(tester, textScale: 2.0);
        expect(find.text('Apply PKR 1,500/hr'), findsOneWidget);
        expectNoOverflow(tester);
      });
    });

    testWidgets('every selectable row is a real tap target', (tester) async {
      useDeviceSurface(tester);
      final api = FakeApi()..ok([slot()]);
      await api.run(() async {
        await openLoaded(tester);
        expectTapTarget(
          tester,
          find.ancestor(of: find.text('20:00'), matching: find.byType(InkWell)).first,
        );
      });
    });
  });
}
