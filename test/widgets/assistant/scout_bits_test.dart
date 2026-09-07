// The small parts every Scout card is assembled from, and the claims each one is not
// allowed to make.
//
// Four of the six widgets here exist to say nothing when they have nothing to say, and
// that is what is pinned hardest. A match badge with no percentage draws no badge, because
// "0% match" is a confident claim about a ranking that never ran. A reasons row with no
// reasons collapses, because a ranked list that cannot say why is indistinguishable from
// an arbitrary one and a blank strip hides that. A facts row drops the blank facts rather
// than laying out an icon beside nothing. And a thumbnail falls back to a designed tile
// rather than a broken-image glyph, including for a path that is not a URL at all.
//
// The provenance pill is the one part that has to be legible to a screen reader: it is
// nine-point text whose whole job is to answer "did the model do this, or is it
// hard-coded?", so the sentence it announces is asserted in full. Its chevron is an
// affordance and is therefore drawn only when there is something behind the tap.
//
// The avatar is the exception to the rule that nothing in this feature settles. It
// animates only while it is thinking, so an idle avatar is a still frame that a screen
// test can safely settle on, and both directions of that switch are pinned.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_bits.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../widget_harness.dart';

/// The single decorated box a [ScoutAvatar] draws.
BoxDecoration avatarBox(WidgetTester tester) => tester
    .widget<Container>(find.descendant(
        of: find.byType(ScoutAvatar), matching: find.byType(Container)))
    .decoration! as BoxDecoration;

void main() {
  group('Scout\'s face', () {
    Future<void> pumpAvatar(WidgetTester tester,
            {bool thinking = false, double size = 34}) =>
        pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Center(child: ScoutAvatar(thinking: thinking, size: size)),
          ),
        );

    testWidgets('it is a gradient circle carrying one glyph', (tester) async {
      await pumpAvatar(tester);
      expect(avatarBox(tester).shape, BoxShape.circle);
      expect(
          avatarBox(tester).gradient,
          const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [ScoutTheme.accent, ScoutTheme.accentDim],
          ));
      expect(tester.getSize(find.byType(ScoutAvatar)), const Size(34, 34));
      expect(tester.widget<Icon>(find.byIcon(Icons.auto_awesome)).size,
          closeTo(17.68, 0.01),
          reason: 'the glyph is a little over half the face at any size');
      expect(tester.widget<Icon>(find.byIcon(Icons.auto_awesome)).color,
          Colors.white);
    });

    // Every other animation in this feature repeats forever; this one is the exception a
    // screen test can settle on, which is only true while the avatar is idle.
    testWidgets('an idle face is a still frame', (tester) async {
      await pumpAvatar(tester);
      final quiet = avatarBox(tester).boxShadow!.single;
      expect(quiet.blurRadius, 6, reason: 'the cycle is parked at its start');
      expect(quiet.spreadRadius, 0.5);
      await tester.pumpAndSettle(const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
      expect(avatarBox(tester).boxShadow!.single.blurRadius, 6);
    });

    testWidgets('a thinking face breathes and never settles', (tester) async {
      await pumpAvatar(tester, thinking: true);
      final first = avatarBox(tester).boxShadow!.single;
      await tester.pump(const Duration(milliseconds: 400));
      final later = avatarBox(tester).boxShadow!.single;
      expect(later.blurRadius, greaterThan(first.blurRadius));
      expect(later.color.a, greaterThan(first.color.a));
      await expectLater(
        () => tester.pumpAndSettle(const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2)),
        throwsA(isA<FlutterError>()),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // The app bar's avatar is rebuilt with the flag flipped as each turn starts and
    // finishes, so both directions have to take effect without a remount.
    testWidgets('the answer arriving parks it back at its quietest',
        (tester) async {
      await pumpAvatar(tester, thinking: true);
      await tester.pump(const Duration(milliseconds: 400));
      expect(avatarBox(tester).boxShadow!.single.blurRadius, greaterThan(6));

      await pumpAvatar(tester);
      expect(avatarBox(tester).boxShadow!.single.blurRadius, 6,
          reason: 'stopping resets the cycle rather than freezing it mid-breath');
      await tester.pumpAndSettle(const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    });

    testWidgets('the next question starts it again', (tester) async {
      await pumpAvatar(tester);
      await pumpAvatar(tester, thinking: true);
      final first = avatarBox(tester).boxShadow!.single;
      await tester.pump(const Duration(milliseconds: 400));
      expect(avatarBox(tester).boxShadow!.single.blurRadius,
          greaterThan(first.blurRadius));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('leaving the screen disposes the controller cleanly',
        (tester) async {
      await pumpAvatar(tester, thinking: true);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(find.byType(ScoutAvatar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // Nine-point text carrying the answer to "did a model do this, or is it hard-coded?".
  // The sentence is the pill's whole accessible name, so it is asserted in full rather
  // than left to the two-word label.
  group('where the answer came from', () {
    Future<int> pumpPill(WidgetTester tester,
        {ScoutSource source = ScoutSource.live, bool tappable = true}) async {
      var taps = 0;
      await pumpApp(
        tester,
        Material(
          color: ScoutTheme.canvas,
          child: Center(
            child: ScoutSourcePill(
                source: source, onTap: tappable ? () => taps++ : null),
          ),
        ),
      );
      return taps;
    }

    testWidgets('the pill names its source and explains it to a screen reader',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPill(tester);
      expect(find.text('Live data'), findsOneWidget);
      expect(
          tester.getSemantics(find.text('Live data')),
          matchesSemantics(
            label: 'Answer source: Live data. Read from the database just now\nLive data',
            isButton: true,
            hasTapAction: true,
            isFocusable: true,
            hasFocusAction: true,
          ));
      handle.dispose();
    });

    // The tone is what separates a live read from a policy quote at a glance; the two
    // must not be able to render as each other.
    testWidgets('each source carries its own glyph', (tester) async {
      await pumpPill(tester);
      expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.bolt_rounded)).size, 10.5);

      await pumpPill(tester, source: ScoutSource.policy);
      expect(find.text('Policy'), findsOneWidget);
      expect(find.byIcon(Icons.gavel_rounded), findsOneWidget);

      await pumpPill(tester, source: ScoutSource.model);
      expect(find.byIcon(Icons.auto_awesome_rounded), findsOneWidget);
    });

    // A source this build does not recognise is still labelled, because a missing pill
    // reads as an answer with no provenance at all.
    testWidgets('a source from a newer server is still drawn', (tester) async {
      await pumpPill(tester, source: ScoutSource.from('crowdsourced_2027'));
      expect(find.text('Unknown'), findsOneWidget);
      expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    });

    // The chevron is an affordance, so it is drawn only when there is a sheet behind it.
    testWidgets('the chevron appears only where the tap leads somewhere',
        (tester) async {
      await pumpPill(tester);
      expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

      await pumpPill(tester, tappable: false);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
      expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    });

    testWidgets('an untappable pill is not announced as a button', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPill(tester, tappable: false);
      expect(
          tester.getSemantics(find.text('Live data')),
          matchesSemantics(
            label: 'Answer source: Live data. Read from the database just now\nLive data',
          ));
      handle.dispose();
    });

    testWidgets('the tap opens whatever was wired to it', (tester) async {
      var taps = 0;
      await pumpApp(
        tester,
        Material(
          color: ScoutTheme.canvas,
          child: Center(
            child: ScoutSourcePill(
                source: ScoutSource.live, onTap: () => taps++),
          ),
        ),
      );
      await tester.tap(find.text('Live data'));
      expect(taps, 1);
    });
  });

  // A null percentage is not a zero percentage: nothing scored the row, so nothing is
  // claimed about it.
  group('the match badge', () {
    Future<void> pumpBadge(WidgetTester tester,
            {int? pct, bool showLabel = false}) =>
        pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Center(
                child: ScoutMatchBadge(pct: pct, showLabel: showLabel)),
          ),
        );

    testWidgets('an unranked row draws no badge at all', (tester) async {
      await pumpBadge(tester);
      expect(tester.getSize(find.byType(ScoutMatchBadge)), Size.zero);
      expect(find.textContaining('%'), findsNothing,
          reason: '"0% match" would be a claim about a ranking that never ran');
    });

    testWidgets('a ranked row states its percentage', (tester) async {
      await pumpBadge(tester, pct: 72);
      expect(find.text('72% match'), findsOneWidget);
      expect(tester.widget<Text>(find.text('72% match')).style!.color,
          ScoutTheme.accent);
    });

    // The band name is for the cards that have room for it; the figure alone is for
    // the ones that do not.
    testWidgets('with the label it names the band as well', (tester) async {
      await pumpBadge(tester, pct: 91, showLabel: true);
      expect(find.text('91% · Great fit'), findsOneWidget);
      expect(find.text('91% match'), findsNothing);
    });

    testWidgets('a weak match is drawn in the danger colour', (tester) async {
      await pumpBadge(tester, pct: 12, showLabel: true);
      expect(find.text('12% · Weak fit'), findsOneWidget);
      expect(tester.widget<Text>(find.text('12% · Weak fit')).style!.color,
          ScoutTheme.danger);
    });
  });

  // A venue photo is a join away and often missing, so the fallback is a designed tile
  // rather than the framework's broken-image glyph.
  group('the thumbnail', () {
    Future<void> pumpThumb(WidgetTester tester,
            {String? url, IconData fallback = Icons.stadium_rounded}) =>
        pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Center(child: ScoutThumb(url: url, fallback: fallback)),
          ),
        );

    testWidgets('a real URL is fetched at the size the card reserved',
        (tester) async {
      await pumpThumb(tester, url: 'https://cdn.example.com/v1.jpg');
      final image =
          tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(image.imageUrl, 'https://cdn.example.com/v1.jpg');
      expect(image.width, 58);
      expect(image.height, 58);
      expect(find.byType(ClipRRect), findsOneWidget);
      expect(find.byIcon(Icons.stadium_rounded), findsOneWidget,
          reason: 'the same tile stands in while the photo is still in flight');
    });

    // A relative path is what an unconfigured upload leaves behind; handing it to the
    // image widget would draw an error glyph inside the card.
    testWidgets('anything that is not an http URL falls back to the tile',
        (tester) async {
      for (final url in [null, '', '/uploads/v1.jpg', 'v1.jpg']) {
        await pumpThumb(tester, url: url);
        expect(find.byType(CachedNetworkImage), findsNothing,
            reason: 'url was ${url == null ? 'null' : '"$url"'}');
        expect(find.byIcon(Icons.stadium_rounded), findsOneWidget);
        expect(tester.getSize(find.byType(ScoutThumb)), const Size(58, 58),
            reason: 'the tile holds the space the photo would have taken');
      }
    });

    testWidgets('the caller chooses the glyph the tile falls back to',
        (tester) async {
      await pumpThumb(tester, url: null, fallback: Icons.person_rounded);
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.person_rounded)).size,
          closeTo(24.36, 0.01));
    });
  });

  // A ranked list that cannot say why it ranked that way is indistinguishable from an
  // arbitrary one, so an empty row collapses instead of leaving a strip that hides it.
  group('the reasons a row was ranked', () {
    Future<void> pumpReasons(WidgetTester tester,
            {required List<String> reasons, int max = 3}) =>
        pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                  width: 300,
                  child: ScoutReasons(reasons: reasons, max: max)),
            ),
          ),
        );

    testWidgets('no reasons means no row', (tester) async {
      await pumpReasons(tester, reasons: const []);
      expect(tester.getSize(find.byType(ScoutReasons)).height, 0);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    });

    testWidgets('each reason is ticked', (tester) async {
      await pumpReasons(tester, reasons: const ['Near you', 'In budget']);
      expect(find.text('Near you'), findsOneWidget);
      expect(find.text('In budget'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      expect(tester.widget<Icon>(find.byIcon(Icons.check_rounded).first).color,
          ScoutTheme.accent);
    });

    // The ranker returns as many as it computed; the card shows the three that fit.
    testWidgets('a long list is cut to the three that fit', (tester) async {
      await pumpReasons(tester, reasons: const [
        'Near you',
        'In budget',
        'Free at 7pm',
        'Highly rated',
        'Played here before',
      ]);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));
      expect(find.text('Free at 7pm'), findsOneWidget);
      expect(find.text('Highly rated'), findsNothing,
          reason: 'the fourth reason is dropped, not wrapped onto a third line');
    });

    testWidgets('a card with room for more asks for more', (tester) async {
      await pumpReasons(tester,
          reasons: const ['Near you', 'In budget', 'Free at 7pm', 'Highly rated'],
          max: 4);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(4));
    });
  });

  group('a row of facts', () {
    Future<void> pumpFacts(WidgetTester tester,
            {required List<ScoutFact> facts, double fontSize = 11}) =>
        pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                  width: 300,
                  child: ScoutFacts(facts: facts, fontSize: fontSize)),
            ),
          ),
        );

    testWidgets('a fact is its glyph beside its text', (tester) async {
      await pumpFacts(tester, facts: const [
        ScoutFact(Icons.place_rounded, '2.4 km away'),
        ScoutFact(Icons.schedule_rounded, '18:00 – 19:00'),
      ]);
      expect(find.text('2.4 km away'), findsOneWidget);
      expect(find.text('18:00 – 19:00'), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.place_rounded)).size, 12.5,
          reason: 'the glyph is set from the row\'s own font size');
      expect(tester.widget<Text>(find.text('2.4 km away')).style!.color,
          ScoutTheme.inkSoft);
    });

    // A join that came back without a value must not leave an icon standing beside
    // nothing, which reads as a rendering fault rather than a missing field.
    testWidgets('a blank fact is dropped rather than laid out', (tester) async {
      await pumpFacts(tester, facts: const [
        ScoutFact(Icons.place_rounded, '2.4 km away'),
        ScoutFact(Icons.star_rounded, '   '),
        ScoutFact(Icons.schedule_rounded, ''),
      ]);
      expect(find.byIcon(Icons.place_rounded), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      expect(find.byIcon(Icons.schedule_rounded), findsNothing);
    });

    testWidgets('a row of nothing but blanks collapses', (tester) async {
      await pumpFacts(tester,
          facts: const [ScoutFact(Icons.star_rounded, '  ')]);
      expect(tester.getSize(find.byType(ScoutFacts)).height, 0);
    });

    // A price that is over the asking figure is the one fact that has to shout, so a
    // fact's own colour overrides the muted default on both halves.
    testWidgets('a fact can carry its own colour', (tester) async {
      await pumpFacts(tester, facts: const [
        ScoutFact(Icons.trending_up_rounded, 'Peak pricing',
            color: ScoutTheme.money),
      ]);
      expect(tester.widget<Text>(find.text('Peak pricing')).style!.color,
          ScoutTheme.money);
      expect(tester.widget<Icon>(find.byIcon(Icons.trending_up_rounded)).color,
          ScoutTheme.money);
    });
  });

  // The heading is the one part of a card that has to survive a venue name of any
  // length without pushing its badge off the edge.
  group('a card\'s heading', () {
    Future<void> pumpTitle(WidgetTester tester,
            {String title = 'Arena One',
            String? subtitle,
            Widget? trailing,
            double textScale = 1.0}) =>
        pumpApp(
          tester,
          ColoredBox(
            color: ScoutTheme.canvas,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: ScoutCardTitle(
                    title: title, subtitle: subtitle, trailing: trailing),
              ),
            ),
          ),
          textScale: textScale,
        );

    testWidgets('a title is two lines at most, then ellipsised', (tester) async {
      await pumpTitle(tester, title: 'Arena One Sports Complex, Gulberg III');
      final text = tester.widget<Text>(find.textContaining('Arena One'));
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expectNoOverflow(tester);
    });

    testWidgets('a subtitle is one line and sits under the title', (tester) async {
      await pumpTitle(tester, subtitle: 'Football · 5-a-side');
      expect(find.text('Football · 5-a-side'), findsOneWidget);
      final subtitle = tester.widget<Text>(find.text('Football · 5-a-side'));
      expect(subtitle.maxLines, 1);
      expect(subtitle.style!.color, ScoutTheme.inkFaint);
      expect(tester.getTopLeft(find.text('Football · 5-a-side')).dy,
          greaterThan(tester.getTopLeft(find.text('Arena One')).dy));
    });

    // A join that returned no sport must not open a gap under the title.
    testWidgets('a blank subtitle takes no space', (tester) async {
      await pumpTitle(tester);
      final without = tester.getSize(find.byType(ScoutCardTitle)).height;
      await pumpTitle(tester, subtitle: '   ');
      expect(tester.getSize(find.byType(ScoutCardTitle)).height, without);
    });

    testWidgets('a trailing badge is given its own room', (tester) async {
      await pumpTitle(tester,
          title: 'Arena One Sports Complex, Gulberg III',
          trailing: const ScoutMatchBadge(pct: 91));
      expect(find.text('91% match'), findsOneWidget);
      final badge = tester.getSize(find.byType(ScoutMatchBadge)).width;
      await pumpTitle(tester, trailing: const ScoutMatchBadge(pct: 91));
      expect(tester.getSize(find.byType(ScoutMatchBadge)).width, badge,
          reason: 'the title yields to the badge rather than squeezing it');
      expect(tester.getTopLeft(find.byType(ScoutMatchBadge)).dx -
              tester.getTopRight(find.text('Arena One')).dx,
          greaterThanOrEqualTo(8));
    });

    testWidgets('the heading holds at a doubled text scale', (tester) async {
      await pumpTitle(tester,
          title: 'Arena One Sports Complex, Gulberg III',
          subtitle: 'Football · 5-a-side',
          trailing: const ScoutMatchBadge(pct: 91),
          textScale: 2.0);
      expect(find.text('91% match'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  // The disabled constant is what every card is handed while a turn is in flight, so
  // its three handlers being absent is the whole guarantee against a double booking.
  group('what a card may ask the screen to do', () {
    test('the disabled constant can do nothing at all', () {
      expect(ScoutCardActions.none.enabled, isFalse);
      expect(ScoutCardActions.none.onChip, isNull);
      expect(ScoutCardActions.none.onScreen, isNull);
      expect(ScoutCardActions.none.onDirections, isNull);
    });

    test('a card is live unless it is told otherwise', () {
      expect(const ScoutCardActions().enabled, isTrue);
    });
  });
}
