// The sheet the Scout app bar opens: the list of things Scout can do.
//
// It is a `showModalBottomSheet` function rather than a widget, so each test drives it
// the way the app bar does — through a button that has a `BuildContext` — and the
// assertions are about what a tap on a row does after the sheet has closed itself. That
// ordering is the part worth pinning: every row pops the sheet before it acts, so a
// handler that ran first and popped second would leave a sheet over the transcript it
// had just changed.
//
// The help sheet is how the abilities the classifier has no label for stay reachable: a
// row posts its own action, so the model is never consulted. Its grouping is asserted in
// first-seen order because the server decides the order and the sheet must not sort it.
//
// The chat list used to be tested here too. It is a drawer now, and its cases live in
// `scout_drawer_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_sheets.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../../services/http_seam.dart';
import '../widget_harness.dart';

void main() {
  tearDown(resetApiClient);

  /// A modal sheet slides in over a quarter of a second, and a tap before it has landed
  /// hits the barrier rather than the row.
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('the list of things Scout can do', () {
    /// Opens the help sheet the way the app bar does, and records what a row posted.
    Future<List<ScoutChip>> openHelp(
      WidgetTester tester,
      List<ScoutCapability> capabilities, {
      double textScale = 1.0,
    }) async {
      if (find.byType(Scaffold).evaluate().isNotEmpty) {
        Navigator.of(tester.element(find.byType(Scaffold))).popUntil((route) => route.isFirst);
        await tester.pumpAndSettle();
      }
      final picked = <ScoutChip>[];
      await pumpApp(
        tester,
        Builder(
          builder: (context) => Scaffold(
            backgroundColor: ScoutTheme.light.canvas,
            body: Center(
              child: GestureDetector(
                onTap: () => showScoutHelpSheet(
                  context,
                  capabilities: capabilities,
                  onPick: picked.add,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        textScale: textScale,
      );
      await tester.tap(find.text('open'));
      await settleSheet(tester);
      return picked;
    }

    ScoutCapability capability({
      String action = 'find_venue',
      String label = 'Find a ground',
      String group = 'Booking',
      String gloss = 'By area, sport or price',
    }) =>
        ScoutCapability(
            action: action, label: label, group: group, gloss: gloss);

    /// The three the classifier has no label for, spread over two groups.
    List<ScoutCapability> twoGroups() => [
          capability(),
          capability(
              action: 'my_bookings',
              label: 'My bookings',
              gloss: 'Upcoming and past'),
          capability(
              action: 'find_players',
              label: 'Find players',
              group: 'Matchmaking',
              gloss: 'For a game tonight'),
        ];

    testWidgets('the sheet says what it is, in both the languages it accepts',
        (tester) async {
      await openHelp(tester, twoGroups());
      expect(find.text('What I can do'), findsOneWidget);
      expect(
          find.text('Tap one, or just type it in your own words — English, '
              'Roman Urdu, either.'),
          findsOneWidget);
    });

    // The server decides the order, so the sheet must not sort it: a heading moving
    // between builds would move the row a reader was reaching for.
    testWidgets('the groups are upper-cased and kept in first-seen order',
        (tester) async {
      await openHelp(tester, twoGroups());
      expect(find.text('BOOKING'), findsOneWidget);
      expect(find.text('MATCHMAKING'), findsOneWidget);
      expect(find.text('Booking'), findsNothing,
          reason: 'the heading is drawn upper-cased, not restyled');
      expect(tester.getTopLeft(find.text('BOOKING')).dy,
          lessThan(tester.getTopLeft(find.text('MATCHMAKING')).dy));
      expect(tester.getTopLeft(find.text('My bookings')).dy,
          lessThan(tester.getTopLeft(find.text('MATCHMAKING')).dy),
          reason: 'a group holds its own rows rather than interleaving them');
    });

    testWidgets('a row is its label, its gloss and the glyph its action earns',
        (tester) async {
      await openHelp(tester, [capability()]);
      expect(find.text('Find a ground'), findsOneWidget);
      expect(find.text('By area, sport or price'), findsOneWidget);
      expect(find.byIcon(Icons.stadium_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget,
          reason: 'the row reads as something that leads somewhere');
    });

    testWidgets('an action this build has no glyph for still gets one',
        (tester) async {
      await openHelp(
          tester, [capability(action: 'settle_dispute', label: 'Settle it')]);
      expect(find.text('Settle it'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(2),
          reason: 'the fallback glyph and the trailing chevron');
    });

    testWidgets('a row with nothing to add draws no second line',
        (tester) async {
      await openHelp(tester, [capability(gloss: '')]);
      final withoutGloss = tester.getSize(find.byType(InkWell).last).height;
      await openHelp(tester, [capability()]);
      expect(tester.getSize(find.byType(InkWell).last).height,
          greaterThan(withoutGloss));
    });

    // This is the mechanism the whole sheet exists for: the row posts its own action,
    // so an ability the released classifier cannot label is still reachable.
    testWidgets('a tap closes the sheet and posts the action itself',
        (tester) async {
      final picked = await openHelp(tester, twoGroups());
      await tester.tap(find.text('Find players'));
      await settleSheet(tester);
      expect(find.text('What I can do'), findsNothing,
          reason: 'the sheet is popped before the action is posted');
      expect(picked.single.action, 'find_players');
      expect(picked.single.label, 'Find players',
          reason: 'the label travels with it so the transcript reads as a chip');
      expect(picked.single.args, isNull);
    });

    testWidgets('an empty list still invites a question', (tester) async {
      await openHelp(tester, const []);
      expect(
          find.text('I could not load the list just now. Ask me anything anyway '
              '— grounds, bookings, teams, your wallet.'),
          findsOneWidget);
      expect(find.byType(InkWell), findsNothing,
          reason: 'there is nothing to tap, so nothing is drawn as tappable');
      expect(find.text('What I can do'), findsOneWidget);
    });

    testWidgets('the rows hold at a doubled text scale', (tester) async {
      useDeviceSurface(tester);
      await openHelp(tester, twoGroups(), textScale: 2.0);
      expect(find.text('Find a ground'), findsOneWidget);
      expect(find.text('BOOKING'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
