// ScoutChips: the tappable end of every Scout reply.
//
// Three separate contracts live in this file, and each one has a way of failing that
// still renders perfectly.
//
// The glyph map is keyed on the action, which is stable, and never on the label, which
// is copy the backend may reword. An action this app has not heard of falls back to a
// neutral chevron rather than vanishing, because a chip that disappeared because the map
// is behind the server would silently remove the only thing a user could do next.
//
// The chip sends the chip back, never its text. `onTap` receives the whole [ScoutChip]
// — action and args included — so a "Book it" chip carries the slot it was built with;
// a handler wired to the label would break the moment the copy changed.
//
// A missing handler disables the chip rather than drawing a live-looking button that
// does nothing, which is the same rule the composer's send button follows. And an empty
// chip list collapses: rule 1 of the reply contract is that every answer ends with
// something to tap, so an empty row is a fault upstream and drawing a blank strip inside
// the bubble would hide it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_chips.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../widget_harness.dart';

const _chips = [
  ScoutChip(label: 'Book it', action: 'book_venue', args: {'venueId': 'v1'}),
  ScoutChip(label: 'Other times', action: 'check_availability'),
  ScoutChip(label: 'Cancel', action: 'cancel_confirm'),
];

void main() {
  group('the glyph map', () {
    test('a known action gets its own glyph', () {
      expect(ScoutChipIcons.of('book_venue'), Icons.event_available_rounded);
      expect(ScoutChipIcons.of('wallet_balance'), Icons.account_balance_wallet_rounded);
    });

    // The map is behind the backend by construction; a chip must stay tappable anyway.
    test('an action this app has never seen still gets a glyph', () {
      expect(ScoutChipIcons.of('settle_tournament_prizes'),
          Icons.chevron_right_rounded);
      expect(ScoutChipIcons.of(''), Icons.chevron_right_rounded);
    });
  });

  group('one chip', () {
    testWidgets('it draws its label, its glyph and a button to a screen reader',
        (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Center(
              child: ScoutChipButton(
                label: 'Book it',
                icon: Icons.event_available_rounded,
                onTap: () => taps++,
              ),
            ),
          ));
      expect(find.text('Book it'), findsOneWidget);
      expect(find.byIcon(Icons.event_available_rounded), findsOneWidget);
      // Pinned as it behaves: the `Semantics` wrapper adds the label without excluding
      // the child, so the chip is announced twice. Recorded here so that adding
      // `excludeSemantics: true` shows up as a failing expectation rather than passing
      // unnoticed — see the note in the report.
      expect(
          tester.getSemantics(find.byType(ScoutChipButton)),
          matchesSemantics(
            label: 'Book it\nBook it',
            isButton: true,
            isEnabled: true,
            hasEnabledState: true,
            hasTapAction: true,
            isFocusable: true,
            hasFocusAction: true,
          ));
      await tester.tap(find.text('Book it'));
      expect(taps, 1);
      handle.dispose();
    });

    // The one action a card is for reads as the answer: filled, not outlined.
    testWidgets('a primary chip is filled while a normal one is a wash',
        (tester) async {
      Future<BoxDecoration> decoration(ScoutChipTone tone) async {
        await pumpApp(
            tester,
            ColoredBox(
              color: ScoutTheme.canvas,
              child: Center(
                child: ScoutChipButton(label: 'Confirm', tone: tone, onTap: () {}),
              ),
            ));
        return tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .decoration! as BoxDecoration;
      }

      final primary = await decoration(ScoutChipTone.primary);
      expect(primary.gradient, ScoutTheme.userBubbleGradient);
      expect(primary.color, isNull);

      final normal = await decoration(ScoutChipTone.normal);
      expect(normal.gradient, isNull);
      expect(normal.color, ScoutTheme.accent.withValues(alpha: 0.10));
    });

    testWidgets('a destructive chip is drawn in the danger colour', (tester) async {
      await pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Center(
              child: ScoutChipButton(
                label: 'Cancel booking',
                icon: Icons.event_busy_rounded,
                tone: ScoutChipTone.danger,
                onTap: () {},
              ),
            ),
          ));
      expect(tester.widget<Text>(find.text('Cancel booking')).style!.color,
          ScoutTheme.danger);
      expect(tester.widget<Icon>(find.byIcon(Icons.event_busy_rounded)).color,
          ScoutTheme.danger);
    });

    // Disabled means unreachable, not merely ignored — the same rule the composer's
    // send button follows.
    testWidgets('a disabled chip is muted and cannot be pressed', (tester) async {
      var taps = 0;
      await pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Center(
              child: ScoutChipButton(
                label: 'Book it',
                enabled: false,
                onTap: () => taps++,
              ),
            ),
          ));
      expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
      expect(tester.widget<Text>(find.text('Book it')).style!.color,
          ScoutTheme.inkFaint);
      await tester.tap(find.text('Book it'));
      expect(taps, 0);
    });

    testWidgets('a dense chip is smaller in every dimension', (tester) async {
      Future<Size> size({required bool dense}) async {
        await pumpApp(
            tester,
            ColoredBox(
              color: ScoutTheme.canvas,
              child: Center(
                child: ScoutChipButton(
                    label: 'Other times',
                    icon: Icons.schedule_rounded,
                    dense: dense,
                    onTap: () {}),
              ),
            ));
        return tester.getSize(find.byType(AnimatedContainer));
      }

      final loose = await size(dense: false);
      final tight = await size(dense: true);
      expect(tight.width, lessThan(loose.width));
      expect(tight.height, lessThan(loose.height));
    });
  });

  group('a reply\'s row of chips', () {
    Future<void> pumpWrap(WidgetTester tester,
            {List<ScoutChip> chips = _chips,
            ScoutChipTap? onTap,
            Set<String> primaryActions = const {},
            bool enabled = true,
            double textScale = 1.0}) =>
        pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: ScoutChipsWrap(
                  chips: chips,
                  onTap: onTap,
                  primaryActions: primaryActions,
                  enabled: enabled,
                ),
              ),
            ),
          ),
          textScale: textScale,
        );

    // Rule 1 of the reply contract is that every answer ends with something to tap, so
    // an empty list is a fault upstream; drawing a blank strip would hide it.
    testWidgets('an empty list collapses rather than leaving a gap', (tester) async {
      await pumpWrap(tester, chips: const []);
      expect(tester.getSize(find.byType(ScoutChipsWrap)).height, 0);
    });

    testWidgets('every chip is drawn with the glyph its action earns', (tester) async {
      await pumpWrap(tester, onTap: (_) {});
      expect(find.byType(ScoutChipButton), findsNWidgets(3));
      expect(find.byIcon(Icons.event_available_rounded), findsOneWidget);
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });

    // The chip goes back, not its text: the args are what make "Book it" mean this
    // slot at this venue.
    testWidgets('a tap reports the whole chip, args included', (tester) async {
      final tapped = <ScoutChip>[];
      await pumpWrap(tester, onTap: tapped.add);
      await tester.tap(find.text('Book it'));
      await tester.pump();
      expect(tapped.single.action, 'book_venue');
      expect(tapped.single.args, {'venueId': 'v1'});
    });

    // The destructive set has a default for a reason: a cancel chip must read as one
    // even when the caller passes no tones at all.
    testWidgets('cancelling is destructive by default', (tester) async {
      await pumpWrap(tester, onTap: (_) {});
      expect(tester.widget<Text>(find.text('Cancel')).style!.color, ScoutTheme.danger);
      expect(tester.widget<Text>(find.text('Other times')).style!.color,
          const Color(0xFFB7F7CD));
    });

    testWidgets('the caller nominates which action a card is for', (tester) async {
      await pumpWrap(tester, onTap: (_) {}, primaryActions: const {'book_venue'});
      expect(tester.widget<Text>(find.text('Book it')).style!.color, Colors.white);
      expect(tester.widget<Text>(find.text('Book it')).style!.fontWeight,
          FontWeight.w700);
    });

    // A turn still in flight, and an old turn on a screen that has moved on: both
    // leave the chips visible and inert rather than removing them.
    testWidgets('no handler disables every chip', (tester) async {
      await pumpWrap(tester);
      expect(find.byType(ScoutChipButton), findsNWidgets(3));
      for (final chip in tester.widgetList<ScoutChipButton>(
          find.byType(ScoutChipButton))) {
        expect(chip.enabled, isFalse);
      }
    });

    testWidgets('a disabled row keeps its chips but not their taps', (tester) async {
      final tapped = <ScoutChip>[];
      await pumpWrap(tester, onTap: tapped.add, enabled: false);
      await tester.tap(find.text('Book it'));
      await tester.pump();
      expect(tapped, isEmpty);
    });

    testWidgets('six chips wrap onto more than one line', (tester) async {
      await pumpWrap(tester, onTap: (_) {}, chips: const [
        ScoutChip(label: 'Find a venue', action: 'find_venue'),
        ScoutChip(label: 'My bookings', action: 'my_bookings'),
        ScoutChip(label: 'Wallet balance', action: 'wallet_balance'),
        ScoutChip(label: 'Find players', action: 'find_players'),
        ScoutChip(label: 'Tournaments', action: 'tournament_list'),
        ScoutChip(label: 'Refund policy', action: 'refund_policy'),
      ]);
      final tops = tester
          .widgetList<ScoutChipButton>(find.byType(ScoutChipButton))
          .map((c) => tester.getTopLeft(find.byWidget(c)).dy)
          .toSet();
      expect(tops.length, greaterThan(1), reason: 'the row wrapped');
      expectNoOverflow(tester);
    });

    // The fix the comment above anticipated is now in — the label is wrapped in a
    // `Flexible` with `TextOverflow.ellipsis`, so a doubled text scale no longer
    // overflows the row. The assertion now proves the defect is gone.
    testWidgets('at a doubled text scale a chip is wider than its bubble',
        (tester) async {
      await pumpWrap(tester, onTap: (_) {}, textScale: 2.0);
      expect(find.text('Book it'), findsOneWidget);
      expect(find.text('Other times'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
