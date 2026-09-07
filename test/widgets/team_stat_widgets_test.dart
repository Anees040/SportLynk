// The team stat visuals, and the several places where an honest blank is the whole
// requirement.
//
// Almost every widget in this file exists to stop a number being invented. [RatingText]
// is the clearest case: a team's rating column is seeded at 1000 before it has played
// anything, so any screen reading `elo` directly prints a rating the team has not
// earned — which is exactly how the leaderboard once did. The widget prints "Unranked"
// instead, and the test that matters is the one proving the seed never reaches the
// screen even though it is sitting right there in the model.
//
// [MovementBadge] is the same argument with four states rather than two. "New to the
// board" and "held its place" are different facts, and rendering the first as a zero
// claims a week of history the team does not have; rendering the second as a literal
// "0" in a column of numbers reads as a score. So null draws NEW and zero draws a dash,
// and both are pinned.
//
// The ELO chart's dots carry business meaning that no other screen expresses: solid
// green is a verified result that moved the rating, hollow red is a disputed one where
// the match counted and the rating did not, and hollow grey is a verified result against
// a frozen rating (ER2.3). Grey and red must never be confused, because one is the
// team's own fault and the other is not. The painter is asked for each dot directly
// rather than inspected through pixels, which is the only way to assert the third state
// exists at all.
//
// The legend follows the data instead of listing every possibility, so a team with no
// disputes is never told what a disputed dot would have meant. That conditional is
// pinned in both directions.
//
// [FormRow] reverses the string it is given, because the server sends newest-first and
// every football table in the world reads oldest-left. A regression there is invisible —
// five pills either way — until a team's run of form is quietly backwards, so the order
// is asserted by geometry.
//
// Nothing here touches the network. The one widget that could, [MatchHistoryTile] with
// an opponent logo, is driven with a null logo throughout: a non-empty url reaches
// `CachedNetworkImageProvider` and a test has no business making that request.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/team_stats.dart';
import 'package:sportlynk/widgets/team_stat_widgets.dart';

import 'widget_harness.dart';

/// A rating source with both fields settable, so the ranked and unranked branches can
/// be driven without building a whole leaderboard row. Uses the real mixin, which is
/// what supplies `eloLabel`.
class _Rating with RatingDisplay {
  _Rating({required this.ranked, required this.displayElo});

  @override
  final bool ranked;

  @override
  final int? displayElo;
}

/// One point of the ELO series. `opponentLogo` is left null everywhere: a non-empty url
/// would be fetched over the network by `CachedNetworkImageProvider`.
EloPoint point({
  String matchId = 'm1',
  int eloAt = 1000,
  DateTime? at,
  bool verified = true,
  bool disputed = false,
  bool rated = true,
  String? opponentName = 'Karachi Kings',
  int myScore = 2,
  int theirScore = 1,
  String result = 'win',
  int? eloDelta = 18,
}) =>
    EloPoint(
      matchId: matchId,
      eloAt: eloAt,
      at: at,
      verified: verified,
      disputed: disputed,
      rated: rated,
      opponentName: opponentName,
      myScore: myScore,
      theirScore: theirScore,
      result: result,
      eloDelta: eloDelta,
    );

void main() {
  /// Puts one widget on a white surface, sized so nothing is measured against the
  /// default 800x600 test window by accident.
  Future<void> pumpOne(WidgetTester tester, Widget child,
      {double textScale = 1.0}) async {
    useDeviceSurface(tester);
    await pumpApp(
      tester,
      Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: child),
      ),
      textScale: textScale,
    );
  }

  /// The painter the chart asks for at dot [index] — the only way to see the three dot
  /// styles, since they differ by stroke and fill rather than by widget.
  FlDotCirclePainter dotAt(WidgetTester tester, int index) {
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final bar = chart.data.lineBarsData.single;
    final painter = bar.dotData.getDotPainter(
      bar.spots[index],
      0,
      bar,
      index,
    );
    return painter as FlDotCirclePainter;
  }

  group('printing a rating', () {
    testWidgets('a ranked team gets its number, grouped', (tester) async {
      await pumpOne(tester, RatingText(_Rating(ranked: true, displayElo: 1240)));
      expect(find.text('1,240'), findsOneWidget);
    });

    // The seed is present in the model and must not reach the screen. This is the
    // regression the widget was written for.
    testWidgets('an unranked team is never shown the 1000 seed', (tester) async {
      await pumpOne(tester, RatingText(_Rating(ranked: false, displayElo: 1000)));
      expect(find.text('Unranked'), findsOneWidget);
      expect(find.text('1,000'), findsNothing);
      expect(find.text('1000'), findsNothing);
    });

    // `ranked` and a present `displayElo` are two separate server facts, and either one
    // missing means the same thing to a reader.
    testWidgets('a ranked team with no figure is still unranked', (tester) async {
      await pumpOne(tester, RatingText(_Rating(ranked: true, displayElo: null)));
      expect(find.text('Unranked'), findsOneWidget);
    });

    testWidgets('the word is set smaller than the number it replaces',
        (tester) async {
      await pumpOne(tester, RatingText(_Rating(ranked: false, displayElo: null), size: 20));
      final style = tester.widget<Text>(find.text('Unranked')).style!;
      expect(style.fontSize, closeTo(20 * 0.68, 0.01),
          reason: 'a longer word doing a smaller job must not crowd a four-digit column');
      expect(style.color, AppColors.textSecondary);
    });

    testWidgets('a rating honours the size and colour it was given',
        (tester) async {
      await pumpOne(
        tester,
        RatingText(_Rating(ranked: true, displayElo: 980),
            size: 18, color: AppColors.accent),
      );
      final style = tester.widget<Text>(find.text('980')).style!;
      expect(style.fontSize, 18);
      expect(style.color, AppColors.accent);
      expect(style.fontWeight, FontWeight.bold);
    });
  });

  // Four states, because two of them are absences of different kinds.
  group('rank movement', () {
    testWidgets('a team new to the board says so rather than showing a zero',
        (tester) async {
      await pumpOne(tester, const MovementBadge(null));
      expect(find.text('NEW'), findsOneWidget);
      expect(find.text('0'), findsNothing,
          reason: 'a zero would claim a week of history the team does not have');
      expect(find.byIcon(Icons.arrow_drop_up), findsNothing);
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    });

    testWidgets('holding a place draws a dash, not a zero', (tester) async {
      await pumpOne(tester, const MovementBadge(0));
      expect(find.text('–'), findsOneWidget);
      expect(find.text('0'), findsNothing,
          reason: 'a zero beside a rank column reads as a score');
    });

    testWidgets('a climb is an up arrow with the places gained', (tester) async {
      await pumpOne(tester, const MovementBadge(4));
      expect(find.byIcon(Icons.arrow_drop_up), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(tester.widget<Text>(find.text('4')).style?.color, AppColors.success);
    });

    // The sign is carried by the arrow and the colour, so the number itself is absolute.
    testWidgets('a fall is a down arrow with an unsigned number', (tester) async {
      await pumpOne(tester, const MovementBadge(-7));
      expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('-7'), findsNothing);
      expect(tester.widget<Text>(find.text('7')).style?.color, AppColors.error);
    });

    testWidgets('the compact form is smaller but says the same thing',
        (tester) async {
      await pumpOne(tester, const MovementBadge(4, compact: true));
      expect(find.text('4'), findsOneWidget);
      expect(tester.widget<Text>(find.text('4')).style?.fontSize, 9);
      expect(tester.widget<Icon>(find.byIcon(Icons.arrow_drop_up)).size, 13);
    });

    // A three-digit jump on a narrow rank column would overflow without the flex.
    testWidgets('a three-digit jump fits in a narrow column', (tester) async {
      useDeviceSurface(tester);
      await pumpApp(
        tester,
        const Scaffold(
          body: Center(
            child: SizedBox(width: 40, child: MovementBadge(148, compact: true)),
          ),
        ),
      );
      expect(find.text('148'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('the last five results', () {
    // The server sends newest-first and every league table reads oldest-left, so the
    // widget reverses. Five pills look identical either way, which is what makes this
    // worth asserting by position.
    testWidgets('the newest result ends up on the right', (tester) async {
      await pumpOne(tester, const FormRow('WLD'));
      final w = tester.getTopLeft(find.text('W')).dx;
      final l = tester.getTopLeft(find.text('L')).dx;
      final d = tester.getTopLeft(find.text('D')).dx;
      expect(d, lessThan(l),
          reason: 'the oldest of the three is drawn first');
      expect(l, lessThan(w));
    });

    testWidgets('a team with no matches says so instead of drawing nothing',
        (tester) async {
      await pumpOne(tester, const FormRow(''));
      expect(find.text('No matches yet'), findsOneWidget);
      expect(find.text('W'), findsNothing);
    });

    testWidgets('each letter gets its own colour', (tester) async {
      await pumpOne(tester, const FormRow('WLD'));
      Color? fill(String letter) {
        final box = tester.widget<Container>(
          find.ancestor(of: find.text(letter), matching: find.byType(Container)).first,
        );
        return (box.decoration as BoxDecoration).color;
      }

      expect(fill('W'), AppColors.success);
      expect(fill('L'), AppColors.error);
      expect(fill('D'), AppColors.textSecondary);
    });

    // Anything that is not a win or a loss is a draw, including a letter the server has
    // not sent before.
    testWidgets('an unrecognised letter is drawn as a draw', (tester) async {
      await pumpOne(tester, const FormRow('X'));
      expect(find.text('D'), findsOneWidget);
      expect(find.text('X'), findsNothing);
    });

    testWidgets('lower case is read the same as upper', (tester) async {
      await pumpOne(tester, const FormRow('w'));
      expect(find.text('W'), findsOneWidget);
    });

    // Indexing rather than comparing by value: `c != seq.last` would collapse the gaps
    // on a run of identical results.
    testWidgets('an unbeaten run still has gaps between the pills',
        (tester) async {
      await pumpOne(tester, const FormRow('WWWWW', size: 20));
      expect(find.text('W'), findsNWidgets(5));
      final xs = [
        for (var i = 0; i < 5; i++) tester.getTopLeft(find.text('W').at(i)).dx,
      ]..sort();
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i] - xs[i - 1], greaterThan(20),
            reason: 'five identical results must not run together into one block');
      }
    });

    testWidgets('the pills scale with the size they are given', (tester) async {
      await pumpOne(tester, const FormRow('W', size: 30));
      final box = find.ancestor(of: find.text('W'), matching: find.byType(Container)).first;
      expect(tester.getSize(box), const Size(30, 30));
      expect(tester.widget<Text>(find.text('W')).style?.fontSize, 15);
    });
  });

  group('a labelled number', () {
    testWidgets('the value sits above its label', (tester) async {
      await pumpOne(
        tester,
        const Row(children: [StatTile(label: 'Played', value: '12')]),
      );
      expect(find.text('12'), findsOneWidget);
      expect(find.text('Played'), findsOneWidget);
      expect(tester.getTopLeft(find.text('12')).dy,
          lessThan(tester.getTopLeft(find.text('Played')).dy));
    });

    testWidgets('a widget may stand in for the number', (tester) async {
      await pumpOne(
        tester,
        Row(
          children: [
            StatTile(
              label: 'Rating',
              valueWidget: RatingText(_Rating(ranked: false, displayElo: 1000)),
            ),
          ],
        ),
      );
      expect(find.text('Unranked'), findsOneWidget,
          reason: 'the tile is how the profile header prints a rating honestly');
    });

    testWidgets('a long value is shrunk rather than clipped', (tester) async {
      useDeviceSurface(tester);
      await pumpApp(
        tester,
        const Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 44,
                child: Row(children: [StatTile(label: 'Rating', value: '1,240')]),
              ),
            ],
          ),
        ),
      );
      expect(find.byType(FittedBox), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the value colour can be overridden', (tester) async {
      await pumpOne(
        tester,
        const Row(
          children: [
            StatTile(label: 'Losses', value: '3', valueColor: AppColors.error),
          ],
        ),
      );
      expect(tester.widget<Text>(find.text('3')).style?.color, AppColors.error);
    });
  });

  group('the rating chart when it cannot be drawn', () {
    // An empty frame looks broken, so the absence is stated.
    testWidgets('no rated matches explains what would make it appear',
        (tester) async {
      await pumpOne(tester, const EloHistoryChart([]));
      expect(
        find.text('No rated matches yet — the chart appears once a result is verified.'),
        findsOneWidget,
      );
      expect(find.byType(LineChart), findsNothing);
      expect(find.byIcon(Icons.show_chart), findsOneWidget);
    });

    // One point is a different fact from none, and the sentence says which.
    testWidgets('one match names the number the chart needs', (tester) async {
      await pumpOne(tester, EloHistoryChart([point()]));
      expect(find.text('One rated match so far. The chart needs two to draw a trend.'),
          findsOneWidget);
      expect(find.byType(LineChart), findsNothing);
    });

    testWidgets('two points are enough to draw', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([point(eloAt: 1000), point(matchId: 'm2', eloAt: 1018)]),
      );
      expect(find.byType(LineChart), findsOneWidget);
      expect(find.byIcon(Icons.show_chart), findsNothing);
    });
  });

  // The dot styles are FR5.14's business rule, and the third one is the reason this
  // group is careful: grey and red both mean "the rating did not move", but only one of
  // them is the team's own doing.
  group('what each dot on the chart means', () {
    testWidgets('a verified rated match is a solid green dot', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([point(eloAt: 1000), point(matchId: 'm2', eloAt: 1018)]),
      );
      final dot = dotAt(tester, 1);
      expect(dot.color, kVerifiedDot);
      expect(dot.strokeColor, Colors.white);
    });

    testWidgets('a disputed match is hollow and red', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([
          point(eloAt: 1000),
          point(matchId: 'm2', eloAt: 1000, disputed: true, rated: false,
              result: 'disputed', eloDelta: null),
        ]),
      );
      final dot = dotAt(tester, 1);
      expect(dot.color, Colors.white, reason: 'hollow: no rating moved');
      expect(dot.strokeColor, kDisputedDot);
    });

    testWidgets('a frozen rating is hollow and grey, never red', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([
          point(eloAt: 1000),
          point(matchId: 'm2', eloAt: 1000, rated: false, eloDelta: null),
        ]),
      );
      final dot = dotAt(tester, 1);
      expect(dot.color, Colors.white);
      expect(dot.strokeColor, AppColors.textSecondary,
          reason: 'ER2.3 is not a dispute and must not be coloured like one');
      expect(dot.strokeColor, isNot(kDisputedDot));
    });

    // A gap would read as missing data and a drop to zero as a collapse, so the line
    // runs through the unrated points at their carried-forward rating.
    testWidgets('the line runs through the unrated points', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([
          point(eloAt: 1000),
          point(matchId: 'm2', eloAt: 1000, rated: false, eloDelta: null),
          point(matchId: 'm3', eloAt: 1018),
        ]),
      );
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final spots = chart.data.lineBarsData.single.spots;
      expect(spots.length, 3);
      expect(spots[1].y, 1000, reason: 'the rating genuinely did not change here');
    });
  });

  group('the chart legend', () {
    testWidgets('a clean history is told only what green means', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([point(eloAt: 1000), point(matchId: 'm2', eloAt: 1018)]),
      );
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Disputed'), findsNothing,
          reason: 'a team with no disputes is not taught what a dispute looks like');
      expect(find.text('Rating frozen'), findsNothing);
    });

    testWidgets('a dispute in the series adds its key', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([
          point(eloAt: 1000),
          point(matchId: 'm2', eloAt: 1000, disputed: true, rated: false,
              result: 'disputed', eloDelta: null),
        ]),
      );
      expect(find.text('Disputed'), findsOneWidget);
      expect(find.text('Rating frozen'), findsNothing);
    });

    testWidgets('a frozen point adds its own', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([
          point(eloAt: 1000),
          point(matchId: 'm2', eloAt: 1000, rated: false, eloDelta: null),
        ]),
      );
      expect(find.text('Rating frozen'), findsOneWidget);
      expect(find.text('Disputed'), findsNothing);
    });

    testWidgets('a series with both gets all three keys', (tester) async {
      await pumpOne(
        tester,
        EloHistoryChart([
          point(eloAt: 1000),
          point(matchId: 'm2', eloAt: 1000, rated: false, eloDelta: null),
          point(matchId: 'm3', eloAt: 1000, disputed: true, rated: false,
              result: 'disputed', eloDelta: null),
        ]),
      );
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Disputed'), findsOneWidget);
      expect(find.text('Rating frozen'), findsOneWidget);
    });
  });

  group('a row of match history', () {
    testWidgets('a win reads as one, with the score and the points gained',
        (tester) async {
      await pumpOne(
        tester,
        MatchHistoryTile(point(at: DateTime(2026, 3, 14))),
      );
      expect(find.text('Karachi Kings'), findsOneWidget);
      expect(find.text('Won 2–1'), findsOneWidget);
      expect(find.text('14 Mar 2026'), findsOneWidget);
      expect(find.text('+18 ELO'), findsOneWidget);
    });

    testWidgets('a loss is coloured against the team', (tester) async {
      await pumpOne(
        tester,
        MatchHistoryTile(point(result: 'loss', myScore: 1, theirScore: 2, eloDelta: -14)),
      );
      expect(find.text('Lost 1–2'), findsOneWidget);
      expect(find.text('-14 ELO'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Lost 1–2')).style?.color, AppColors.error);
      expect(tester.widget<Text>(find.text('-14 ELO')).style?.color, AppColors.error);
    });

    testWidgets('a draw is neutral', (tester) async {
      await pumpOne(
        tester,
        MatchHistoryTile(point(result: 'draw', myScore: 1, theirScore: 1, eloDelta: 2)),
      );
      expect(find.text('Drew 1–1'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Drew 1–1')).style?.color,
          AppColors.textSecondary);
    });

    // "+0" would read as a rated draw. A disputed row has no delta to show and says so
    // in words instead.
    testWidgets('a disputed row says no change rather than plus zero',
        (tester) async {
      await pumpOne(
        tester,
        MatchHistoryTile(point(
            result: 'disputed', disputed: true, rated: false, eloDelta: null)),
      );
      expect(find.text('Disputed 2–1'), findsOneWidget);
      expect(find.text('No change'), findsOneWidget);
      expect(find.textContaining('ELO'), findsNothing);
      expect(tester.widget<Text>(find.text('Disputed 2–1')).style?.color,
          AppColors.warning);
    });

    testWidgets('a verified match against a frozen rating says frozen',
        (tester) async {
      await pumpOne(
        tester,
        MatchHistoryTile(point(rated: false, eloDelta: null)),
      );
      expect(find.text('Frozen'), findsOneWidget);
      expect(find.text('No change'), findsNothing,
          reason: 'the two reasons a rating did not move are not the same reason');
    });

    // A rated match whose exchange happened to be zero also has nothing to show, and
    // the model withholds the label rather than printing +0.
    testWidgets('a zero exchange shows no pill at all', (tester) async {
      await pumpOne(tester, MatchHistoryTile(point(eloDelta: 0)));
      expect(find.text('+0 ELO'), findsNothing);
      expect(find.text('Frozen'), findsOneWidget);
    });

    testWidgets('an opponent the server did not name is still a row',
        (tester) async {
      await pumpOne(tester, MatchHistoryTile(point(opponentName: null)));
      expect(find.text('Opponent'), findsOneWidget);
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    });

    testWidgets('a match with no date omits the separator rather than drawing it bare',
        (tester) async {
      await pumpOne(tester, MatchHistoryTile(point()));
      expect(find.text('Won 2–1'), findsOneWidget);
      expect(find.text('  ·  '), findsNothing);
    });

    testWidgets('the row is inert until it is given something to do',
        (tester) async {
      await pumpOne(tester, MatchHistoryTile(point()));
      expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    });

    testWidgets('a tap opens the match', (tester) async {
      var taps = 0;
      await pumpOne(tester, MatchHistoryTile(point(), onTap: () => taps++));
      await tester.tap(find.text('Karachi Kings'));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('a history row still lays out', (tester) async {
      await pumpOne(
        tester,
        MatchHistoryTile(point(at: DateTime(2026, 3, 14))),
        textScale: 2.0,
      );
      expect(find.text('Karachi Kings'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('a movement badge still lays out', (tester) async {
      await pumpOne(tester, const MovementBadge(-7), textScale: 2.0);
      expect(find.text('7'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the chart\'s empty state still lays out', (tester) async {
      await pumpOne(tester, const EloHistoryChart([]), textScale: 2.0);
      expect(find.byIcon(Icons.show_chart), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
