// The match flow's shared vocabulary, and the several places where the widget's job
// is to refuse to state something.
//
// The file under test opens by arguing that one definition means one meaning: a
// competitiveness score that reads "well matched" in green on one screen and amber on
// the next would destroy the user's trust in the number. That argument is only true
// while the band boundaries stay where they are, and a boundary is exactly the kind of
// constant a later edit moves by five without noticing. So every threshold is pinned
// from both sides — 79 and 80, 54 and 55, 29 and 30 — rather than sampled in the middle
// of a band where any off-by-five still passes.
//
// The second theme is the unranked case. FR2.6 gives a team no rating until it has
// played a verified match, so "no score yet" is the state a new install shows
// constantly. Three widgets have to express it without inventing a number:
// [CompetitivenessBar] draws an empty track and a sentence rather than a 5% fill,
// because a thin bar and "no data" look identical at a glance and one of them is a lie;
// [CompetitivenessGauge] prints an em dash rather than a zero; and [EloPill] prints
// "Unranked" even though `side.elo` is sitting right there holding the 1000 seed. That
// last one is the highest-value test in the file: the model deliberately keeps a real
// number in `elo` for arithmetic, so the only thing standing between the seed and the
// user's eye is this widget reading `ranked` first.
//
// [EloDeltaChip] carries a distinction no other widget makes. Zero does not mean the
// match was a wash — it means the rating was frozen (ER2.3) or the delta is genuinely
// nil — and the two are separately labelled "Frozen" and "No change". Rendering either
// as "+0" would put a number on a non-event, so both words are pinned along with the
// icon that distinguishes them.
//
// [ChallengeCountdown] is the one stateful widget here, and it is stateful for a stated
// reason: a captain deciding on a challenge with three minutes left must not be looking
// at a frozen number that has silently become expired, because they tap Accept and get
// a 409. Its `format` is pure and is tested directly across every boundary it switches
// on; the ticking itself is tested through the clock, with the tree discarded afterwards
// so a live timer cannot follow the test out.
//
// Nothing here touches the network. [TeamCrest] hands a non-empty url straight to
// `CachedNetworkImageProvider`, so every crest in this file is driven with a null or
// empty logo and the one url case asserts only that a `backgroundImage` was attached.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/match.dart';
import 'package:sportlynk/widgets/match_widgets.dart';

import 'widget_harness.dart';

/// A side with only the fields these widgets read. The rest are given the values a
/// real payload would carry so nothing here depends on a default that could move.
///
/// [elo] defaults to the platform seed on purpose: an unranked side in these tests is
/// one whose `elo` is a perfectly printable 1000, which is the condition [EloPill] has
/// to survive.
MatchSide side({
  bool ranked = true,
  int elo = 1000,
  bool frozen = false,
  int? delta,
  String? logoUrl,
}) =>
    MatchSide(
      id: 't1',
      name: 'Karachi United',
      logoUrl: logoUrl,
      city: 'Karachi',
      elo: elo,
      ranked: ranked,
      displayElo: ranked ? elo : null,
      played: ranked ? 6 : 0,
      wins: ranked ? 4 : 0,
      losses: ranked ? 1 : 0,
      draws: ranked ? 1 : 0,
      eloFrozen: frozen,
      eloDelta: delta,
    );

/// Pumps one widget on the device surface, inside the scroll view these widgets are
/// laid out in on their real screens.
Future<void> pumpOne(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
  double width = 380,
}) async {
  useDeviceSurface(tester);
  await pumpApp(
    tester,
    Scaffold(
      backgroundColor: AppColors.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SizedBox(width: width, child: child),
      ),
    ),
    textScale: textScale,
  );
}

/// The colour of the text [finder] matches.
Color? colorOf(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).style?.color;

/// The colour of the icon [finder] matches.
Color? iconColorOf(WidgetTester tester, Finder finder) =>
    tester.widget<Icon>(finder).color;

void main() {
  group('the band a competitiveness score falls in', () {
    // Every boundary is pinned from both sides. Sampling the middle of a band would
    // still pass if a threshold moved by five, which is the size of edit this table
    // actually receives.
    test('a missing score is unranked rather than a low band', () {
      final tone = CompetitivenessTone.of(null);
      expect(tone.label, 'Unranked');
      expect(tone.color, AppColors.textSecondary);
    });

    test('80 is evenly matched and 79 is not', () {
      expect(CompetitivenessTone.of(80).label, 'Evenly matched');
      expect(CompetitivenessTone.of(80).color, AppColors.success);
      expect(CompetitivenessTone.of(79).label, 'Competitive');
    });

    test('55 is competitive and 54 is not', () {
      expect(CompetitivenessTone.of(55).label, 'Competitive');
      expect(CompetitivenessTone.of(55).color, AppColors.accent);
      expect(CompetitivenessTone.of(54).label, 'Uphill');
    });

    test('30 is uphill and 29 is not', () {
      expect(CompetitivenessTone.of(30).label, 'Uphill');
      expect(CompetitivenessTone.of(30).color, AppColors.warning);
      expect(CompetitivenessTone.of(29).label, 'Mismatch');
    });

    test('the floor of the server range is a mismatch', () {
      expect(CompetitivenessTone.of(5).label, 'Mismatch');
      expect(CompetitivenessTone.of(5).color, AppColors.error);
    });

    test('the top of the server range is evenly matched', () {
      expect(CompetitivenessTone.of(100).label, 'Evenly matched');
    });

    test('a tone is worth comparing by value, so two calls agree', () {
      // The four bands are const instances, so the same score returns the identical
      // object. A later edit that builds them per call would make every colour
      // assertion in this file compare a fresh object, which still passes — but it
      // would also mean the table is no longer a table.
      expect(CompetitivenessTone.of(90), same(CompetitivenessTone.of(95)));
    });
  });

  group('the competitiveness bar', () {
    testWidgets('a score prints its band, its percentage and a balance icon',
        (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: 84));

      expect(find.text('Evenly matched'), findsOneWidget);
      expect(find.text('84%'), findsOneWidget);
      expect(find.byIcon(Icons.balance), findsOneWidget);
      expect(colorOf(tester, find.text('84%')), AppColors.success);
    });

    testWidgets('no score draws the sentence that says why, not a percentage',
        (tester) async {
      // The whole point of the widget: a 5% bar and "no data" look the same, so the
      // absent number is replaced by a reason rather than by a small figure.
      await pumpOne(tester, const CompetitivenessBar(score: null));

      expect(find.text('Not comparable yet — no verified matches'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
      expect(find.byIcon(Icons.balance), findsNothing);
    });

    testWidgets('a caller can replace the unranked sentence', (tester) async {
      await pumpOne(
        tester,
        const CompetitivenessBar(
          score: null,
          unrankedNote: 'Play a verified match to compare',
        ),
      );

      expect(find.text('Play a verified match to compare'), findsOneWidget);
      expect(find.text('Not comparable yet — no verified matches'), findsNothing);
    });

    testWidgets('the unranked track is drawn empty', (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: null));
      await tester.pump(const Duration(milliseconds: 500));

      // A zero-width fill, not a minimum-width one: the fraction is 0.0 rather than
      // the clamped 0.05 the scored path would use.
      expect(
        tester.getSize(find.byType(AnimatedContainer)).width,
        0.0,
      );
    });

    testWidgets('the fill is proportional to the score once it has settled',
        (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: 50), width: 200);
      // The fill animates over 420ms; measured before it lands the width is
      // whatever the curve is passing through.
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        tester.getSize(find.byType(AnimatedContainer)).width,
        closeTo(100, 1),
      );
    });

    testWidgets('a score under the server floor is clamped to it', (tester) async {
      // The score is documented as 5..100. A 1 would draw a fill too thin to see,
      // so the widget clamps rather than trusting the payload.
      await pumpOne(tester, const CompetitivenessBar(score: 1), width: 200);
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.getSize(find.byType(AnimatedContainer)).width, closeTo(10, 1));
      // The clamp is for the bar only. The figure printed stays the server's.
      expect(find.text('1%'), findsOneWidget);
    });

    testWidgets('a full score fills the track', (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: 100), width: 200);
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.getSize(find.byType(AnimatedContainer)).width, closeTo(200, 1));
    });

    testWidgets('the compact form is shorter and still says the same thing',
        (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: 84, compact: true));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Evenly matched'), findsOneWidget);
      expect(find.text('84%'), findsOneWidget);
      expect(tester.getSize(find.byType(AnimatedContainer)).height, 5.0);
    });

    testWidgets('the full form is the taller of the two', (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: 84));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.getSize(find.byType(AnimatedContainer)).height, 6.0);
    });

    testWidgets('a long band label ellipsises rather than overflowing',
        (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: 84), width: 90);

      final text = tester.widget<Text>(find.text('Evenly matched'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expectNoOverflow(tester);
    });
  });

  group('the competitiveness gauge', () {
    testWidgets('a score is printed as a bare number with its band beneath',
        (tester) async {
      await pumpOne(tester, const CompetitivenessGauge(score: 72));
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.text('72'), findsOneWidget);
      // Upper-cased for the readout, which is why the bar's assertion above cannot
      // be reused here.
      expect(find.text('COMPETITIVE'), findsOneWidget);
      expect(find.text('Competitive'), findsNothing);
    });

    testWidgets('no score prints a dash rather than a zero', (tester) async {
      await pumpOne(tester, const CompetitivenessGauge(score: null));
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('UNRANKED'), findsOneWidget);
      expect(colorOf(tester, find.text('—')), AppColors.textSecondary);
    });

    testWidgets('a scored readout is the primary ink, not the band colour',
        (tester) async {
      // The number is the thing being read; the band colour lives on the label and
      // the arc. Tinting the number too would make a mismatch look like an error
      // message.
      await pumpOne(tester, const CompetitivenessGauge(score: 22));
      await tester.pump(const Duration(milliseconds: 800));

      expect(colorOf(tester, find.text('22')), AppColors.textPrimary);
      expect(colorOf(tester, find.text('MISMATCH')), AppColors.error);
    });

    testWidgets('the gauge is a half circle plus room for the readout',
        (tester) async {
      await pumpOne(tester, const CompetitivenessGauge(score: 60, size: 200));
      await tester.pump(const Duration(milliseconds: 800));

      // Anchored inside the gauge: the surrounding scaffold contributes its own
      // CustomPaints, so byType alone would measure whichever one came last.
      final box = tester.getSize(
        find.descendant(
          of: find.byType(CompetitivenessGauge),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(box.width, 200);
      expect(box.height, closeTo(124, 0.01));
    });

    testWidgets('it sweeps in from zero rather than appearing at its value',
        (tester) async {
      // The motion is the stated reason the gauge earns its space over a second
      // bar — it is what makes a 40 feel different from an 85. The sweep is not
      // observable through the readout, which is a fixed string, so the tween
      // itself is asserted.
      await pumpOne(tester, const CompetitivenessGauge(score: 100));

      final anim = tester.widget<TweenAnimationBuilder<double>>(
        find.byType(TweenAnimationBuilder<double>),
      );
      expect(anim.tween.begin, 0);
      expect(anim.tween.end, closeTo(1.0, 0.0001));
      expect(anim.duration, const Duration(milliseconds: 750));

      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('100'), findsOneWidget);
    });

    testWidgets('an unranked dial sweeps to nothing rather than to a floor',
        (tester) async {
      await pumpOne(tester, const CompetitivenessGauge(score: null));

      final anim = tester.widget<TweenAnimationBuilder<double>>(
        find.byType(TweenAnimationBuilder<double>),
      );
      expect(anim.tween.end, 0.0);

      await tester.pump(const Duration(milliseconds: 800));
    });

    testWidgets('a score under the server floor is clamped on the dial too',
        (tester) async {
      await pumpOne(tester, const CompetitivenessGauge(score: 1));

      final anim = tester.widget<TweenAnimationBuilder<double>>(
        find.byType(TweenAnimationBuilder<double>),
      );
      // Clamped for the arc, which would otherwise be invisible; the readout keeps
      // the server's own figure.
      expect(anim.tween.end, closeTo(0.05, 0.0001));
      expect(find.text('1'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 800));
    });

    testWidgets('the size argument scales the type with the dial', (tester) async {
      await pumpOne(tester, const CompetitivenessGauge(score: 60, size: 120));
      await tester.pump(const Duration(milliseconds: 800));

      expect(
        tester.widget<Text>(find.text('60')).style?.fontSize,
        closeTo(24, 0.01),
      );
    });

    testWidgets('an unranked gauge still paints its track', (tester) async {
      await pumpOne(tester, const CompetitivenessGauge(score: null));
      await tester.pump(const Duration(milliseconds: 800));

      // An empty dial rather than no dial: the shape is what tells the captain a
      // score belongs here and has not arrived.
      expect(find.byType(CustomPaint), findsWidgets);
      expectNoOverflow(tester);
    });
  });

  group('the trust badge', () {
    testWidgets('no band draws nothing at all', (tester) async {
      // The band is only present on the pairing endpoints, so every other screen
      // passes null and must not get a grey "unknown" chip in its layout. Scoped to
      // the widget's own subtree: the scaffold around it supplies containers and
      // icons of its own.
      await pumpOne(tester, const TrustBadgeChip(band: null), width: 0);

      expect(
        find.descendant(
          of: find.byType(TrustBadgeChip),
          matching: find.byType(Container),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(TrustBadgeChip),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
      expect(tester.getSize(find.byType(TrustBadgeChip)), Size.zero);
    });

    testWidgets('the four server bands each get their own colour and icon',
        (tester) async {
      const cases = <String, (Color, IconData)>{
        'excellent': (AppColors.success, Icons.verified),
        'good': (AppColors.accent, Icons.thumb_up_alt_outlined),
        'fair': (AppColors.warning, Icons.remove_circle_outline),
        'low': (AppColors.error, Icons.warning_amber_rounded),
      };

      for (final entry in cases.entries) {
        await pumpOne(tester, TrustBadgeChip(band: entry.key));
        expect(find.text(entry.key), findsOneWidget);
        expect(iconColorOf(tester, find.byIcon(entry.value.$2)), entry.value.$1,
            reason: 'band ${entry.key} lost its colour');
        expect(find.byIcon(entry.value.$2), findsOneWidget,
            reason: 'band ${entry.key} lost its icon');
      }
    });

    testWidgets('a band the client has never heard of still renders', (tester) async {
      // The bands come from the server. A newer backend adding one must degrade to a
      // neutral chip rather than throwing on a missing map key.
      await pumpOne(tester, const TrustBadgeChip(band: 'provisional'));

      expect(find.text('provisional'), findsOneWidget);
      expect(iconColorOf(tester, find.byType(Icon)), AppColors.textSecondary);
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets('the server label wins over the raw band', (tester) async {
      await pumpOne(
        tester,
        const TrustBadgeChip(band: 'excellent', label: 'Highly trusted'),
      );

      expect(find.text('Highly trusted'), findsOneWidget);
      expect(find.text('excellent'), findsNothing);
    });

    testWidgets('the score is appended only when it is asked for', (tester) async {
      await pumpOne(
        tester,
        const TrustBadgeChip(band: 'good', label: 'Good', score: 78, showScore: true),
      );
      expect(find.text('Good · 78'), findsOneWidget);

      await pumpOne(
        tester,
        const TrustBadgeChip(band: 'good', label: 'Good', score: 78),
      );
      expect(find.text('Good'), findsOneWidget);
      expect(find.textContaining('78'), findsNothing);
    });

    testWidgets('asking for a score there is none of prints the label alone',
        (tester) async {
      await pumpOne(
        tester,
        const TrustBadgeChip(band: 'fair', label: 'Fair', showScore: true),
      );

      expect(find.text('Fair'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
    });
  });

  group('a rating, or the honest absence of one', () {
    testWidgets('a ranked side prints its rating', (tester) async {
      await pumpOne(tester, EloPill(side: side(elo: 1180)));

      expect(find.text('ELO 1180'), findsOneWidget);
    });

    testWidgets('an unranked side prints Unranked even though elo holds the seed',
        (tester) async {
      // The highest-value assertion in the file. `MatchSide.elo` is documented as
      // always a real number — the 1000 base for a new team — and it is right there
      // in the object. FR2.6 says the user must never see it until a verified match
      // exists, so the widget has to read `ranked` first.
      final s = side(ranked: false, elo: 1000);
      expect(s.elo, 1000);

      await pumpOne(tester, EloPill(side: s));

      expect(find.text('Unranked'), findsOneWidget);
      expect(find.textContaining('1000'), findsNothing);
      expect(find.textContaining('ELO'), findsNothing);
    });

    testWidgets('an unranked pill is drawn in the muted palette', (tester) async {
      await pumpOne(tester, EloPill(side: side(ranked: false)));

      expect(colorOf(tester, find.text('Unranked')), AppColors.textSecondary);
    });

    testWidgets('the dark pill is the default and the light one is opt-in',
        (tester) async {
      await pumpOne(tester, EloPill(side: side(elo: 1180)));
      expect(colorOf(tester, find.text('ELO 1180')), Colors.white);

      await pumpOne(tester, EloPill(side: side(elo: 1180), dark: false));
      expect(colorOf(tester, find.text('ELO 1180')), AppColors.primary);
    });

    testWidgets('a frozen rating carries the freeze mark beside it', (tester) async {
      // ER2.3 freezes a rating platform-wide for dispute abuse. The rating is still
      // shown — it is the last honest number — but it must not look live.
      await pumpOne(tester, EloPill(side: side(elo: 1180, frozen: true)));

      expect(find.text('ELO 1180'), findsOneWidget);
      expect(find.byIcon(Icons.ac_unit), findsOneWidget);
    });

    testWidgets('an unfrozen rating carries no mark', (tester) async {
      await pumpOne(tester, EloPill(side: side(elo: 1180)));

      expect(find.byIcon(Icons.ac_unit), findsNothing);
    });

    testWidgets('an unranked frozen side is still unranked', (tester) async {
      await pumpOne(tester, EloPill(side: side(ranked: false, frozen: true)));

      expect(find.text('Unranked'), findsOneWidget);
      expect(find.byIcon(Icons.ac_unit), findsOneWidget);
    });
  });

  group('the points a match moved', () {
    testWidgets('a gain is signed, green and pointing up', (tester) async {
      await pumpOne(tester, const EloDeltaChip(delta: 18));

      expect(find.text('+18'), findsOneWidget);
      expect(colorOf(tester, find.text('+18')), AppColors.success);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('a loss keeps its own minus and points down', (tester) async {
      // The sign comes from the number itself, so a widget that added its own would
      // print "-−12". Pinning the exact string is what catches that.
      await pumpOne(tester, const EloDeltaChip(delta: -12));

      expect(find.text('-12'), findsOneWidget);
      expect(colorOf(tester, find.text('-12')), AppColors.error);
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    });

    testWidgets('a delta that has not been computed draws nothing', (tester) async {
      // Null means the match is not verified yet, which is a different fact from a
      // zero movement and must not render as one.
      await pumpOne(tester, const EloDeltaChip(delta: null));

      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('zero is words rather than a plus nought', (tester) async {
      await pumpOne(tester, const EloDeltaChip(delta: 0));

      expect(find.text('No change'), findsOneWidget);
      expect(find.text('+0'), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(colorOf(tester, find.text('No change')), AppColors.textSecondary);
      expect(find.byIcon(Icons.remove), findsOneWidget);
    });

    testWidgets('zero on a frozen rating says so instead', (tester) async {
      // The two reasons a delta is zero are not interchangeable: one is arithmetic,
      // the other is a sanction the captain needs to understand.
      await pumpOne(tester, const EloDeltaChip(delta: 0, frozen: true));

      expect(find.text('Frozen'), findsOneWidget);
      expect(find.text('No change'), findsNothing);
      expect(find.byIcon(Icons.ac_unit), findsOneWidget);
      expect(find.byIcon(Icons.remove), findsNothing);
    });

    testWidgets('a real movement on a frozen side still prints the movement',
        (tester) async {
      // The frozen flag only decides how zero reads. A non-zero delta is a fact and
      // the word "Frozen" would hide it.
      await pumpOne(tester, const EloDeltaChip(delta: 7, frozen: true));

      expect(find.text('+7'), findsOneWidget);
      expect(find.text('Frozen'), findsNothing);
    });
  });

  group('what a match status says to a captain', () {
    test('every server state is translated out of database language', () {
      // "awaiting_owner" is a row value; "Owner verifying" is what is happening to
      // the captain's match. The mapping is asserted whole because a missing case
      // falls through to printing the raw enum, which is silent in review.
      const expected = <String, String>{
        MatchStatus.challengeSent: 'Awaiting reply',
        MatchStatus.accepted: 'Confirmed',
        MatchStatus.awaitingResults: 'Result due',
        MatchStatus.awaitingOwner: 'Owner verifying',
        MatchStatus.completed: 'Completed',
        MatchStatus.rejected: 'Declined',
        MatchStatus.expired: 'Expired',
        MatchStatus.disputed: 'Disputed',
      };

      for (final entry in expected.entries) {
        expect(MatchStatusChip.describe(entry.key).$1, entry.value,
            reason: '${entry.key} lost its wording');
      }
    });

    test('no raw underscore survives the translation', () {
      for (final status in <String>[
        MatchStatus.challengeSent,
        MatchStatus.awaitingResults,
        MatchStatus.awaitingOwner,
      ]) {
        expect(MatchStatusChip.describe(status).$1, isNot(contains('_')));
      }
    });

    test('a state the client has never seen is passed through, not swallowed', () {
      // A newer backend must render as something. The raw word is a poor label but
      // an empty chip would be a lost match.
      final (label, color, icon) = MatchStatusChip.describe('forfeited');
      expect(label, 'forfeited');
      expect(color, AppColors.textSecondary);
      expect(icon, Icons.info_outline);
    });

    test('the states that need action are not drawn as calm ones', () {
      // A result that is due and a dispute both require the captain to do something;
      // colouring either of them like "Completed" is how they get missed.
      expect(MatchStatusChip.describe(MatchStatus.awaitingResults).$2,
          AppColors.warning);
      expect(MatchStatusChip.describe(MatchStatus.disputed).$2, AppColors.error);
      expect(MatchStatusChip.describe(MatchStatus.completed).$2, AppColors.success);
    });

    test('a closed match is muted rather than alarming', () {
      expect(MatchStatusChip.describe(MatchStatus.rejected).$2,
          AppColors.textSecondary);
      expect(MatchStatusChip.describe(MatchStatus.expired).$2,
          AppColors.textSecondary);
    });

    testWidgets('the chip draws the translated label with its icon', (tester) async {
      await pumpOne(tester, const MatchStatusChip(status: MatchStatus.awaitingOwner));

      expect(find.text('Owner verifying'), findsOneWidget);
      expect(find.text('awaiting_owner'), findsNothing);
      expect(find.byIcon(Icons.verified_user), findsOneWidget);
      expect(colorOf(tester, find.text('Owner verifying')), AppColors.primary);
    });

    testWidgets('an unknown status renders the word the server sent', (tester) async {
      await pumpOne(tester, const MatchStatusChip(status: 'forfeited'));

      expect(find.text('forfeited'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });
  });

  group('the countdown format, at every boundary it switches on', () {
    // The formatter is pure, so the boundaries are asserted directly rather than
    // through a ticking widget. Each pair brackets one branch.
    test('a passed deadline is expired, not a negative duration', () {
      expect(ChallengeCountdown.format(const Duration(seconds: -1)), 'Expired');
      expect(ChallengeCountdown.format(const Duration(days: -3)), 'Expired');
    });

    test('a full day switches to days and remainder hours', () {
      expect(ChallengeCountdown.format(const Duration(days: 1)), '1d 0h left');
      expect(
        ChallengeCountdown.format(const Duration(days: 1, hours: 23)),
        '1d 23h left',
      );
      // One second under a day is still counted in hours.
      expect(
        ChallengeCountdown.format(const Duration(hours: 23, minutes: 59, seconds: 59)),
        '23h 59m left',
      );
    });

    test('the 48h window a challenge opens with reads as two days', () {
      // FR5.12 gives a challenge 48 hours, so this is the string the captain sees
      // first and the one most likely to be screenshotted.
      expect(ChallengeCountdown.format(const Duration(hours: 48)), '2d 0h left');
    });

    test('a full hour switches to hours and remainder minutes', () {
      expect(ChallengeCountdown.format(const Duration(hours: 1)), '1h 0m left');
      expect(
        ChallengeCountdown.format(const Duration(minutes: 59, seconds: 59)),
        '59m 59s left',
      );
    });

    test('a full minute switches to minutes and remainder seconds', () {
      expect(ChallengeCountdown.format(const Duration(minutes: 1)), '1m 0s left');
      expect(ChallengeCountdown.format(const Duration(seconds: 59)), '59s left');
    });

    test('the last seconds are counted one at a time', () {
      expect(ChallengeCountdown.format(const Duration(seconds: 1)), '1s left');
      // Exactly zero is not negative, so it is not yet Expired — it is the last
      // frame before the timer fires.
      expect(ChallengeCountdown.format(Duration.zero), '0s left');
    });

    test('the remainders never exceed their unit', () {
      // A formatter using inMinutes rather than inMinutes % 60 prints "1h 90m",
      // which reads as longer than it is.
      expect(
        ChallengeCountdown.format(const Duration(hours: 1, minutes: 30)),
        '1h 30m left',
      );
      expect(
        ChallengeCountdown.format(const Duration(days: 2, hours: 5, minutes: 40)),
        '2d 5h left',
      );
    });
  });

  group('the countdown as it runs', () {
    testWidgets('no deadline draws nothing', (tester) async {
      // A match with no expiry — anything past the challenge stage — must not leave
      // an empty timer row in the card.
      await pumpOne(tester, const ChallengeCountdown(expiresAt: null));

      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('a deadline two days out is amber, not urgent', (tester) async {
      await pumpOne(
        tester,
        ChallengeCountdown(
          expiresAt: DateTime.now().add(const Duration(hours: 47, minutes: 59)),
        ),
      );

      expect(find.textContaining('1d 23h left'), findsOneWidget);
      expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
      final text = tester.widget<Text>(find.textContaining('left'));
      expect(text.style?.color, AppColors.warning);
      expect(text.style?.fontWeight, FontWeight.w600);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('under six hours it turns red and bold', (tester) async {
      // Six hours is where "I'll deal with it later" stops being safe, so the
      // change in weight is part of the warning, not decoration.
      await pumpOne(
        tester,
        ChallengeCountdown(
          expiresAt: DateTime.now().add(const Duration(hours: 5, minutes: 30)),
        ),
      );

      final text = tester.widget<Text>(find.textContaining('left'));
      expect(text.style?.color, AppColors.error);
      expect(text.style?.fontWeight, FontWeight.bold);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('exactly six hours is not yet urgent', (tester) async {
      await pumpOne(
        tester,
        ChallengeCountdown(
          expiresAt: DateTime.now().add(const Duration(hours: 6, minutes: 1)),
        ),
      );

      expect(
        tester.widget<Text>(find.textContaining('left')).style?.color,
        AppColors.warning,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a passed deadline is muted and carries the stopped-timer icon',
        (tester) async {
      await pumpOne(
        tester,
        ChallengeCountdown(
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      );

      expect(find.text('Expired'), findsOneWidget);
      expect(find.byIcon(Icons.timer_off), findsOneWidget);
      expect(colorOf(tester, find.text('Expired')), AppColors.textSecondary);
    });

    testWidgets('the number actually advances rather than rendering once',
        (tester) async {
      // The stated reason this widget is stateful: a frozen "3m left" is what makes
      // a captain tap Accept on a challenge that has already expired.
      await pumpOne(
        tester,
        ChallengeCountdown(expiresAt: DateTime.now().add(const Duration(seconds: 20))),
      );
      expect(find.textContaining('19s left'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('18s left'), findsOneWidget);
      expect(find.textContaining('19s left'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('it crosses into Expired on its own', (tester) async {
      await pumpOne(
        tester,
        ChallengeCountdown(expiresAt: DateTime.now().add(const Duration(seconds: 2))),
      );
      expect(find.text('Expired'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Expired'), findsOneWidget);
      expect(find.byIcon(Icons.timer_off), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an expired deadline schedules no timer at all', (tester) async {
      // Nothing to tick towards, so a timer here would be a permanent wakeup for a
      // row that will never change. A leaked one fails the test binding on tear-down.
      await pumpOne(
        tester,
        ChallengeCountdown(
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      );
      await tester.pump(const Duration(seconds: 3));

      expect(find.text('Expired'), findsOneWidget);
    });

    testWidgets('a new deadline replaces the old one instead of running beside it',
        (tester) async {
      final near = DateTime.now().add(const Duration(seconds: 30));
      final far = DateTime.now().add(const Duration(hours: 10));

      await pumpOne(tester, ChallengeCountdown(expiresAt: near));
      expect(find.textContaining('29s left'), findsOneWidget);

      await pumpOne(tester, ChallengeCountdown(expiresAt: far));
      await tester.pump(const Duration(seconds: 1));

      expect(find.textContaining('9h'), findsOneWidget);
      expect(find.textContaining('s left'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a long deadline still refreshes once a minute', (tester) async {
      // Above an hour the widget ticks per minute rather than per second. Pinning it
      // keeps a later "simplify to one timer" edit from putting a per-second wakeup
      // on a two-day countdown.
      await pumpOne(
        tester,
        ChallengeCountdown(
          expiresAt: DateTime.now().add(const Duration(hours: 2, minutes: 1)),
        ),
      );
      expect(find.textContaining('2h 0m left'), findsOneWidget);

      await tester.pump(const Duration(seconds: 30));
      expect(find.textContaining('2h 0m left'), findsOneWidget);

      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining('1h 59m left'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the compact form says the same thing in less space',
        (tester) async {
      await pumpOne(
        tester,
        ChallengeCountdown(
          expiresAt: DateTime.now().add(const Duration(hours: 10)),
          compact: true,
        ),
      );

      expect(find.textContaining('left'), findsOneWidget);
      expect(
        tester.widget<Text>(find.textContaining('left')).style?.fontSize,
        10.5,
      );
      expect(tester.widget<Icon>(find.byType(Icon)).size, 11);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('disposing mid-countdown leaves no timer behind', (tester) async {
      await pumpOne(
        tester,
        ChallengeCountdown(expiresAt: DateTime.now().add(const Duration(seconds: 5))),
      );
      await tester.pump(const Duration(seconds: 1));
      // A surviving Timer.periodic is reported by the binding as a pending timer at
      // tear-down, which is how the leak is caught.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));

      expect(find.textContaining('left'), findsNothing);
    });
  });

  group('the team crest', () {
    testWidgets('no logo falls back to a shield rather than a blank circle',
        (tester) async {
      await pumpOne(tester, const TeamCrest());

      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
        isNull,
      );
    });

    testWidgets('an empty logo url is treated as no logo', (tester) async {
      // A team row with `logoUrl: ''` is common — the column exists and was never
      // filled — and handing that to the image provider requests the app's own
      // origin.
      await pumpOne(tester, const TeamCrest(logoUrl: ''));

      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
        isNull,
      );
    });

    testWidgets('a real logo replaces the fallback', (tester) async {
      // Only the provider is asserted. Letting this widget paint would make the
      // test perform an HTTP request.
      await pumpOne(
        tester,
        const TeamCrest(logoUrl: 'https://cdn.example.com/crest.png'),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isA<CachedNetworkImageProvider>());
      expect(avatar.child, isNull);
      expect(find.byIcon(Icons.shield_outlined), findsNothing);
    });

    testWidgets('the radius drives both the circle and the shield', (tester) async {
      await pumpOne(tester, const TeamCrest(radius: 30));

      expect(tester.getSize(find.byType(CircleAvatar)), const Size(60, 60));
      expect(tester.widget<Icon>(find.byType(Icon)).size, closeTo(27, 0.01));
    });

    testWidgets('a caller can tint the empty circle', (tester) async {
      await pumpOne(tester, const TeamCrest(background: AppColors.accentLight));

      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundColor,
        AppColors.accentLight,
      );
    });
  });

  group('the preview block', () {
    testWidgets('the server sentence is rendered as it arrived', (tester) async {
      const text = 'Karachi United have won four of five; expect a tight game.';
      await pumpOne(
        tester,
        const MatchPreviewBlock(label: 'Form guide', text: text),
      );

      expect(find.text(text), findsOneWidget);
    });

    testWidgets('the label is the honesty, so it is drawn and upper-cased',
        (tester) async {
      // The file's own argument: this is template NLG over real numbers, and calling
      // it a prediction would claim an accuracy it does not have. The label the
      // server chose is what keeps that straight, so it is not optional.
      await pumpOne(
        tester,
        const MatchPreviewBlock(label: 'Form guide', text: 'Tight game expected.'),
      );

      expect(find.text('FORM GUIDE'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });

    testWidgets('an empty preview draws nothing rather than an empty box',
        (tester) async {
      await pumpOne(tester, const MatchPreviewBlock(label: 'Form guide', text: ''));

      expect(find.byType(Text), findsNothing);
      expect(find.byIcon(Icons.auto_awesome), findsNothing);
    });

    testWidgets('a long preview wraps instead of overflowing', (tester) async {
      await pumpOne(
        tester,
        MatchPreviewBlock(
          label: 'Form guide',
          text: List.filled(40, 'a close contest').join(', '),
        ),
      );

      expectNoOverflow(tester);
    });
  });

  group('the empty state', () {
    testWidgets('it draws its sentence and icon', (tester) async {
      await pumpOne(
        tester,
        const SizedBox(
          height: 600,
          child: MatchEmptyState(
            text: 'No opponents in your city yet.',
            icon: Icons.groups_outlined,
          ),
        ),
      );

      expect(find.text('No opponents in your city yet.'), findsOneWidget);
      expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
    });

    testWidgets('it stays scrollable so pull-to-refresh survives an empty list',
        (tester) async {
      // The stated reason it is a ListView and not a Column: with nothing to pull,
      // a non-scrollable empty state strands the user on a screen whose only
      // recovery gesture no longer works.
      await pumpOne(
        tester,
        const SizedBox(
          height: 600,
          child: MatchEmptyState(text: 'Nothing here.', icon: Icons.inbox_outlined),
        ),
      );

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.physics, isA<AlwaysScrollableScrollPhysics>());
    });

    testWidgets('an action is drawn when one is offered', (tester) async {
      var taps = 0;
      await pumpOne(
        tester,
        SizedBox(
          height: 600,
          child: MatchEmptyState(
            text: 'Could not load opponents.',
            icon: Icons.cloud_off_rounded,
            action: ElevatedButton(
              onPressed: () => taps++,
              child: const Text('Retry'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Retry'));
      expect(taps, 1);
    });

    testWidgets('no action leaves no dead space where a button would be',
        (tester) async {
      await pumpOne(
        tester,
        const SizedBox(
          height: 600,
          child: MatchEmptyState(text: 'Nothing here.', icon: Icons.inbox_outlined),
        ),
      );

      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byWidgetPredicate((w) => w is Center && w.child is! RichText), findsNothing);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the bar keeps its band, its figure and its layout', (tester) async {
      await pumpOne(tester, const CompetitivenessBar(score: 84), textScale: 2.0);

      expect(find.text('Evenly matched'), findsOneWidget);
      expect(find.text('84%'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the status chip, the pill and the delta all still render',
        (tester) async {
      await pumpOne(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MatchStatusChip(status: MatchStatus.awaitingOwner),
            const SizedBox(height: 8),
            EloPill(side: side(elo: 1180, frozen: true)),
            const SizedBox(height: 8),
            const EloDeltaChip(delta: -12),
            const SizedBox(height: 8),
            const TrustBadgeChip(band: 'excellent', label: 'Highly trusted'),
          ],
        ),
        textScale: 2.0,
      );

      expect(find.text('Owner verifying'), findsOneWidget);
      expect(find.text('ELO 1180'), findsOneWidget);
      expect(find.text('-12'), findsOneWidget);
      expect(find.text('Highly trusted'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the preview block grows rather than clipping', (tester) async {
      await pumpOne(
        tester,
        const MatchPreviewBlock(
          label: 'Form guide',
          text: 'Karachi United have won four of their last five matches.',
        ),
        textScale: 2.0,
      );

      expect(find.text('FORM GUIDE'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
