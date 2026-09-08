// The reviews and Trust 2.0 vocabulary: the gauge, the four breakdown tiles, the
// sentiment chip, the stars, the histogram and the team strip.
//
// The single rule the file header of lib/widgets/trust_widgets.dart states is that
// nothing here paints a zero where the truth is unknown — an empty bar and a genuine
// 0% must never look alike. That distinction is the whole test suite. A brand-new user
// has no rating, no attendance record and no sentiment, so on a fresh install the
// unknown state is the common case rather than an edge one, and every widget is
// therefore asserted on the empty path first and the populated path second.
//
// The bands are pinned from both sides of every threshold. TrustTone's lines were
// carried over from the screen it replaced specifically so the rewrite would not move
// them, and a moved line silently redescribes every user sitting on it: a 75 that
// starts reading "Fair" instead of "Trusted" is a reputational change nobody made.
// The band strings are asserted alongside the labels because the server's
// matchCore.trustBadge vocabulary is what the roster and the badge chip key off, so
// the two vocabularies have to stay welded.
//
// SentimentChip has three states that must never be dressed as one another, and their
// precedence is the interesting part: an unreachable model is not a neutral verdict,
// and a flagged review leads with the escalation because that is the fact a moderator
// acts on. The chip is also the demo's payoff moment, which is exactly why its
// unavailable state is asserted as carefully as its scored one — a chip that read
// "Neutral" when the ml-service was down would be a fabricated model output.
//
// The stars carry two contracts worth pinning. The input clears when the current
// highest star is tapped again, so a mis-tap is recoverable without a second control;
// and the display renders halves, because rounding 4.3 to 4 tells the user the reviews
// support something they do not.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/review.dart';
import 'package:sportlynk/widgets/trust_widgets.dart';

import 'widget_harness.dart';

Review review({
  String id = 'r1',
  int stars = 4,
  String? text = 'Good pitch, lights were on time.',
  String? reviewerName = 'Bilal Ahmed',
  String? reviewType,
  String? sentimentLabel,
  DateTime? createdAt,
}) =>
    Review(
      id: id,
      stars: stars,
      text: text,
      reviewerName: reviewerName,
      reviewType: reviewType,
      sentimentLabel: sentimentLabel,
      createdAt: createdAt,
    );

void main() {
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

  Color? textColorOf(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).style?.color;

  group('the band a trust score falls in', () {
    // Pinned from both sides of every line. These thresholds were carried over from
    // the screen this replaced so the rewrite would not silently redescribe a user
    // sitting exactly on one.
    test('an unscored user is not rated rather than zero', () {
      final t = TrustTone.of(null);
      expect(t.label, 'Not rated yet');
      expect(t.color, AppColors.textSecondary);
      expect(t.band, 'unknown');
    });

    test('90 is highly trusted and 89 is not', () {
      expect(TrustTone.of(90).label, 'Highly Trusted');
      expect(TrustTone.of(90).band, 'excellent');
      expect(TrustTone.of(89).label, 'Trusted');
    });

    test('75 is trusted and 74 is not', () {
      expect(TrustTone.of(75).label, 'Trusted');
      expect(TrustTone.of(75).band, 'good');
      expect(TrustTone.of(74).label, 'Fair');
    });

    test('60 is fair and 59 is not', () {
      expect(TrustTone.of(60).label, 'Fair');
      expect(TrustTone.of(60).band, 'fair');
      expect(TrustTone.of(59).label, 'Needs Improvement');
      expect(TrustTone.of(59).band, 'low');
    });

    test('a zero is a real score, and it reads as the lowest band', () {
      expect(TrustTone.of(0).label, 'Needs Improvement');
      expect(TrustTone.of(0).band, 'low');
    });

    test('100 is the top band', () {
      expect(TrustTone.of(100).label, 'Highly Trusted');
    });

    // The band strings are what TrustBadgeChip and the server's trustBadge
    // vocabulary key off, so the four must stay exactly these words.
    test('the bands are the server\'s own four words', () {
      expect(
        [90, 75, 60, 0].map((s) => TrustTone.of(s).band).toList(),
        ['excellent', 'good', 'fair', 'low'],
      );
    });
  });

  group('the trust gauge', () {
    testWidgets('a score counts up to its own number', (tester) async {
      await pumpOne(tester, const TrustGauge(score: 88));
      await tester.pumpAndSettle();
      expect(find.text('88'), findsOneWidget);
      expect(find.text('out of 100'), findsOneWidget);
      expect(find.text('TRUSTED'), findsOneWidget);
    });

    // An unrated user gets a dash and no denominator: "0 out of 100" would be a
    // verdict nobody reached.
    testWidgets('no score is a dash, with no denominator and no zero',
        (tester) async {
      await pumpOne(tester, const TrustGauge(score: null));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.text('out of 100'), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(find.text('NOT RATED YET'), findsOneWidget);
    });

    testWidgets('an unrated number is drawn in muted ink', (tester) async {
      await pumpOne(tester, const TrustGauge(score: null));
      expect(textColorOf(tester, find.text('—')), AppColors.textSecondary);
    });

    testWidgets('a rated number is drawn in primary ink, the band in its colour',
        (tester) async {
      await pumpOne(tester, const TrustGauge(score: 45));
      await tester.pumpAndSettle();
      expect(textColorOf(tester, find.text('45')), AppColors.textPrimary);
      expect(textColorOf(tester, find.text('NEEDS IMPROVEMENT')), AppColors.error);
    });

    testWidgets('the gauge is square at the size it was given', (tester) async {
      await pumpOne(tester, const TrustGauge(score: 70, size: 200));
      expect(
        tester.getSize(
          find.descendant(
            of: find.byType(TrustGauge),
            matching: find.byType(CustomPaint),
          ),
        ),
        const Size(200, 200),
      );
    });

    testWidgets('the number scales with the gauge', (tester) async {
      await pumpOne(tester, const TrustGauge(score: 70, size: 120));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('70')).style?.fontSize,
          closeTo(120 * 0.26, 0.01));
    });

    testWidgets('a score of zero still paints the ring and reads as zero',
        (tester) async {
      await pumpOne(tester, const TrustGauge(score: 0));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsOneWidget);
      expect(find.text('out of 100'), findsOneWidget,
          reason: 'zero is a measured score, not an absent one');
    });
  });

  group('one component of the trust score', () {
    testWidgets('a measured component shows its value and its contribution',
        (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '⭐',
          label: 'Average rating',
          fraction: 0.84,
          valueText: '4.2 / 5',
          weight: 35,
        ),
      );
      expect(find.text('Average rating'), findsOneWidget);
      expect(find.text('4.2 / 5'), findsOneWidget);
      expect(find.text('+29 of 35 pts'), findsOneWidget);
    });

    // A user with no disputes on record is not 0% dispute-free, they are unmeasured,
    // and the tile has to say the difference.
    testWidgets('an unmeasured component says so and claims no points',
        (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '⚖️',
          label: 'Dispute-free',
          fraction: null,
          valueText: '100%',
          weight: 20,
        ),
      );
      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('100%'), findsNothing,
          reason: 'the formatted value must not leak through the unknown state');
      expect(find.text('worth up to 20 pts'), findsOneWidget);
      expect(find.textContaining('+0'), findsNothing);
    });

    testWidgets('an unmeasured component leaves the bar empty', (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '🤖',
          label: 'Review sentiment',
          fraction: null,
          valueText: null,
          weight: 15,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AnimatedContainer)).width, 0.0);
    });

    testWidgets('an unmeasured component is drawn in muted ink', (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '📅',
          label: 'Attendance',
          fraction: null,
          valueText: null,
          weight: 30,
        ),
      );
      expect(textColorOf(tester, find.text('No data yet')), AppColors.textSecondary);
    });

    // A measured component with no formatted value falls back to a dash rather than
    // to the words reserved for the unknown state.
    testWidgets('a measured component with no text is a dash, not "no data"',
        (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '📅',
          label: 'Attendance',
          fraction: 0.6,
          valueText: null,
          weight: 30,
        ),
      );
      expect(find.text('—'), findsOneWidget);
      expect(find.text('No data yet'), findsNothing);
      expect(find.text('+18 of 30 pts'), findsOneWidget);
    });

    testWidgets('the bar is as wide as the fraction', (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '⭐',
          label: 'Average rating',
          fraction: 0.5,
          valueText: '2.5 / 5',
          weight: 35,
        ),
        width: 240,
      );
      await tester.pumpAndSettle();
      final bar = tester.getSize(find.byType(AnimatedContainer));
      final track = tester.getSize(find.byType(LayoutBuilder));
      expect(bar.width, closeTo(track.width / 2, 1));
    });

    testWidgets('a fraction above one is clamped rather than overflowing',
        (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '⭐',
          label: 'Average rating',
          fraction: 1.4,
          valueText: '5 / 5',
          weight: 35,
        ),
        width: 240,
      );
      await tester.pumpAndSettle();
      final bar = tester.getSize(find.byType(AnimatedContainer));
      final track = tester.getSize(find.byType(LayoutBuilder));
      expect(bar.width, closeTo(track.width, 1));
      expect(find.text('+35 of 35 pts'), findsOneWidget);
      expectNoOverflow(tester);
    });

    // The colour scale is the same four bands as trust itself, so a strong
    // component reads the same here as a strong score reads on the gauge.
    testWidgets('the bar colour follows the same four bands', (tester) async {
      for (final entry in <double, Color>{
        0.80: AppColors.success,
        0.60: AppColors.accent,
        0.35: AppColors.warning,
        0.10: AppColors.error,
      }.entries) {
        await pumpOne(
          tester,
          TrustMetricTile(
            emoji: '⭐',
            label: 'Average rating',
            fraction: entry.key,
            valueText: 'v',
            weight: 35,
          ),
        );
        await tester.pumpAndSettle();
        final box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
        expect((box.decoration as BoxDecoration).color, entry.value,
            reason: '${entry.key} must fall in the same band as trust');
      }
    });

    testWidgets('a long label ellipsises rather than overflowing', (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '⭐',
          label: 'Average rating across every venue and opponent review received',
          fraction: 0.5,
          valueText: '2.5 / 5',
          weight: 35,
        ),
        width: 150,
      );
      final t = tester.widget<Text>(find.textContaining('Average rating across'));
      expect(t.maxLines, 1);
      expect(t.overflow, TextOverflow.ellipsis);
      expectNoOverflow(tester);
    });
  });

  group('the model\'s verdict on a review', () {
    testWidgets('a scored review shows the polarity and the confidence',
        (tester) async {
      await pumpOne(tester, const SentimentChip(label: 'positive', score: 0.92));
      expect(find.text('Positive (92%)'), findsOneWidget);
      expect(find.text('😊'), findsOneWidget);
      expect(textColorOf(tester, find.text('Positive (92%)')), AppColors.success);
    });

    testWidgets('a negative verdict is read from the magnitude, not the sign',
        (tester) async {
      await pumpOne(tester, const SentimentChip(label: 'negative', score: -0.77));
      expect(find.text('Negative (77%)'), findsOneWidget);
      expect(find.text('😞'), findsOneWidget);
      expect(textColorOf(tester, find.text('Negative (77%)')), AppColors.error);
    });

    testWidgets('a neutral verdict is muted, not amber', (tester) async {
      await pumpOne(tester, const SentimentChip(label: 'neutral', score: 0.4));
      expect(find.text('Neutral (40%)'), findsOneWidget);
      expect(find.text('😐'), findsOneWidget);
      expect(textColorOf(tester, find.text('Neutral (40%)')),
          AppColors.textSecondary);
    });

    testWidgets('a label with no score shows the word alone', (tester) async {
      await pumpOne(tester, const SentimentChip(label: 'positive'));
      expect(find.text('Positive'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
    });

    // The ml-service being down is not a neutral verdict. It is a promise that the
    // backfill job will score the review later.
    testWidgets('an unreachable model says the sentiment is coming, not neutral',
        (tester) async {
      await pumpOne(
        tester,
        const SentimentChip(label: null, source: 'unavailable'),
      );
      expect(find.text('Sentiment added shortly'), findsOneWidget);
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.textContaining('Neutral'), findsNothing);
    });

    // Precedence matters: once the model escalated a review, the escalation is the
    // fact a moderator acts on, so it wins over the polarity.
    testWidgets('a flagged review leads with the escalation', (tester) async {
      await pumpOne(
        tester,
        const SentimentChip(label: 'negative', score: -0.88, flagged: true),
      );
      expect(find.text('Flagged for review · 88%'), findsOneWidget);
      expect(find.byIcon(Icons.flag_rounded), findsOneWidget);
      expect(find.text('Negative (88%)'), findsNothing);
      expect(textColorOf(tester, find.text('Flagged for review · 88%')),
          AppColors.warning);
    });

    testWidgets('a flagged review with no score still says it was flagged',
        (tester) async {
      await pumpOne(tester, const SentimentChip(label: null, flagged: true));
      expect(find.text('Flagged for review'), findsOneWidget);
    });

    // A flag beats the unavailable state too, because a flag can only have come
    // from a model that ran.
    testWidgets('a flag outranks an unavailable source', (tester) async {
      await pumpOne(
        tester,
        const SentimentChip(label: null, flagged: true, source: 'unavailable'),
      );
      expect(find.text('Flagged for review'), findsOneWidget);
      expect(find.text('Sentiment added shortly'), findsNothing);
    });

    // A stars-only review has nothing to say.
    testWidgets('an unscored review with no text draws nothing', (tester) async {
      await pumpOne(tester, const SentimentChip(label: null));
      expect(find.byType(Text), findsNothing);
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('an unknown label degrades to the analysing face', (tester) async {
      await pumpOne(tester, const SentimentChip(label: 'mixed', score: 0.5));
      expect(find.text('Analysing (50%)'), findsOneWidget);
      expect(find.text('🤖'), findsOneWidget);
    });

    testWidgets('a magnitude beyond one is clamped to a hundred', (tester) async {
      await pumpOne(tester, const SentimentChip(label: 'positive', score: 1.6));
      expect(find.text('Positive (100%)'), findsOneWidget);
    });

    testWidgets('the compact form says the same thing more quietly',
        (tester) async {
      await pumpOne(
        tester,
        const SentimentChip(label: 'positive', score: 0.92, compact: true),
      );
      final compact = tester.widget<Text>(find.text('Positive (92%)')).style!.fontSize;
      await pumpOne(tester, const SentimentChip(label: 'positive', score: 0.92));
      final full = tester.widget<Text>(find.text('Positive (92%)')).style!.fontSize;
      expect(compact, lessThan(full!));
    });

    testWidgets('a chip built from a response carries every field', (tester) async {
      await pumpOne(
        tester,
        SentimentChip.fromSentiment(
          const ReviewSentiment(
            label: 'negative',
            score: -0.64,
            flagged: true,
            source: 'model',
          ),
        ),
      );
      expect(find.text('Flagged for review · 64%'), findsOneWidget);
    });

    testWidgets('a pending response builds the pending chip', (tester) async {
      await pumpOne(
        tester,
        SentimentChip.fromSentiment(const ReviewSentiment(source: 'unavailable')),
      );
      expect(find.text('Sentiment added shortly'), findsOneWidget);
    });
  });

  group('choosing a star rating', () {
    testWidgets('nothing chosen yet is five empty stars', (tester) async {
      await pumpOne(tester, StarRatingInput(value: 0, onChanged: (_) {}));
      expect(find.byIcon(Icons.star_outline_rounded), findsNWidgets(5));
      expect(find.byIcon(Icons.star_rounded), findsNothing);
    });

    testWidgets('a chosen rating fills that many stars', (tester) async {
      await pumpOne(tester, StarRatingInput(value: 3, onChanged: (_) {}));
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(3));
      expect(find.byIcon(Icons.star_outline_rounded), findsNWidgets(2));
    });

    testWidgets('tapping a star reports that many', (tester) async {
      final chosen = <int>[];
      await pumpOne(tester, StarRatingInput(value: 0, onChanged: chosen.add));
      await tester.tap(find.byType(InkResponse).at(3));
      await tester.pump();
      expect(chosen, [4]);
    });

    // Tapping the current highest star again clears the rating, so a mis-tap is
    // recoverable without a separate control.
    testWidgets('tapping the current rating again clears it', (tester) async {
      final chosen = <int>[];
      await pumpOne(tester, StarRatingInput(value: 4, onChanged: chosen.add));
      await tester.tap(find.byType(InkResponse).at(3));
      await tester.pump();
      expect(chosen, [0]);
    });

    testWidgets('tapping a lower star lowers the rating rather than clearing it',
        (tester) async {
      final chosen = <int>[];
      await pumpOne(tester, StarRatingInput(value: 4, onChanged: chosen.add));
      await tester.tap(find.byType(InkResponse).at(1));
      await tester.pump();
      expect(chosen, [2]);
    });

    testWidgets('each star announces which rating it sets', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpOne(tester, StarRatingInput(value: 2, onChanged: (_) {}));
      expect(find.bySemanticsLabel('Rate 1 star'), findsOneWidget);
      expect(find.bySemanticsLabel('Rate 5 stars'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a chosen star reports itself as selected', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpOne(tester, StarRatingInput(value: 2, onChanged: (_) {}));
      final second = tester.getSemantics(find.bySemanticsLabel('Rate 2 stars'));
      expect(second.flagsCollection.isSelected, ui.Tristate.isTrue);
      final fourth = tester.getSemantics(find.bySemanticsLabel('Rate 4 stars'));
      expect(fourth.flagsCollection.isSelected, ui.Tristate.isFalse);
      handle.dispose();
    });

    // The default 40-logical-pixel star plus its ink radius is the tap target; a
    // rating control below the floor is unusable one-handed.
    testWidgets('every star is a real tap target', (tester) async {
      await pumpOne(tester, StarRatingInput(value: 0, onChanged: (_) {}));
      for (var i = 0; i < 5; i++) {
        expectTapTarget(tester, find.byType(InkResponse).at(i), minimum: 40);
      }
    });
  });

  group('showing a rating that already exists', () {
    // Halves exist so 4.3 is not rounded to a number the reviews do not support.
    testWidgets('a fractional average renders a half star', (tester) async {
      await pumpOne(tester, const StarsDisplay(rating: 4.3));
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
      expect(find.byIcon(Icons.star_half_rounded), findsOneWidget);
    });

    testWidgets('a whole average renders whole stars', (tester) async {
      await pumpOne(tester, const StarsDisplay(rating: 4));
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.star_half_rounded), findsNothing);
    });

    // The boundaries decide whether a 4.8 shows five stars or four and a half, and
    // the answer changes what a venue looks like at a glance.
    testWidgets('a rating three quarters of the way up fills the star',
        (tester) async {
      await pumpOne(tester, const StarsDisplay(rating: 4.75));
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(5));
    });

    testWidgets('a rating a quarter of the way up is a half star', (tester) async {
      await pumpOne(tester, const StarsDisplay(rating: 4.25));
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
      expect(find.byIcon(Icons.star_half_rounded), findsOneWidget);
    });

    testWidgets('a zero average is five empty stars', (tester) async {
      await pumpOne(tester, const StarsDisplay(rating: 0));
      expect(find.byIcon(Icons.star_outline_rounded), findsNWidgets(5));
    });

    testWidgets('the figure is only printed when asked for', (tester) async {
      await pumpOne(tester, const StarsDisplay(rating: 4.3));
      expect(find.text('4.3'), findsNothing);
      await pumpOne(tester, const StarsDisplay(rating: 4.3, showValue: true));
      expect(find.text('4.3'), findsOneWidget);
    });

    testWidgets('the figure keeps one decimal place', (tester) async {
      await pumpOne(tester, const StarsDisplay(rating: 4, showValue: true));
      expect(find.text('4.0'), findsOneWidget);
    });
  });

  group('the ratings histogram', () {
    testWidgets('every star level gets a row, five down to one', (tester) async {
      await pumpOne(tester, const StarsHistogram(counts: [12, 9, 8, 7, 0]));
      for (final s in ['5', '4', '3', '2', '1']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(find.text('12'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });

    // Bars scale to the tallest so the shape stays readable when one rating
    // dominates.
    testWidgets('bars are scaled against the tallest count', (tester) async {
      await pumpOne(
        tester,
        const StarsHistogram(counts: [10, 5, 0, 0, 0]),
        width: 300,
      );
      await tester.pumpAndSettle();
      final tallest = tester.getSize(find.byType(AnimatedContainer).at(0)).width;
      final half = tester.getSize(find.byType(AnimatedContainer).at(1)).width;
      expect(half, closeTo(tallest / 2, 1));
      expect(tester.getSize(find.byType(AnimatedContainer).at(2)).width, 0.0);
    });

    testWidgets('a venue with no reviews draws five empty rows', (tester) async {
      await pumpOne(tester, const StarsHistogram(counts: [0, 0, 0, 0, 0]));
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        expect(tester.getSize(find.byType(AnimatedContainer).at(i)).width, 0.0);
      }
      expect(find.text('0'), findsNWidgets(5));
    });

    // A malformed list is a wire problem, not a reason to throw on a screen.
    testWidgets('a list of the wrong length degrades to empty rows',
        (tester) async {
      await pumpOne(tester, const StarsHistogram(counts: [3, 1]));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsNWidgets(5));
      expectNoOverflow(tester);
    });

    testWidgets('a four-figure count still lays out', (tester) async {
      await pumpOne(tester, const StarsHistogram(counts: [1240, 5, 2, 1, 0]));
      expect(find.text('1240'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('a venue\'s sentiment at a glance', () {
    testWidgets('the three segments carry their counts in the legend',
        (tester) async {
      await pumpOne(
        tester,
        const SentimentSummaryBar(
          distribution: SentimentDistribution(positive: 8, neutral: 3, negative: 1),
        ),
      );
      expect(find.text('Positive 8'), findsOneWidget);
      expect(find.text('Neutral 3'), findsOneWidget);
      expect(find.text('Negative 1'), findsOneWidget);
    });

    testWidgets('the segments size to their share', (tester) async {
      await pumpOne(
        tester,
        const SentimentSummaryBar(
          distribution: SentimentDistribution(positive: 3, neutral: 1, negative: 0),
        ),
        width: 320,
      );
      final positive = tester.getSize(find.byType(Expanded).at(0));
      final neutral = tester.getSize(find.byType(Expanded).at(1));
      expect(positive.width, closeTo(neutral.width * 3, 1.5));
    });

    testWidgets('a polarity with no reviews takes no width at all',
        (tester) async {
      await pumpOne(
        tester,
        const SentimentSummaryBar(
          distribution: SentimentDistribution(positive: 4, neutral: 0, negative: 0),
        ),
      );
      expect(find.byType(Expanded), findsOneWidget,
          reason: 'a zero segment is dropped, not drawn one pixel wide');
      expect(find.text('Neutral 0'), findsOneWidget,
          reason: 'the legend still reports the zero as a fact');
    });

    // An empty split would read as three equal thirds of nothing.
    testWidgets('no scored reviews is a single empty track with no legend',
        (tester) async {
      await pumpOne(
        tester,
        const SentimentSummaryBar(distribution: SentimentDistribution.empty),
      );
      expect(find.byType(Expanded), findsNothing);
      expect(find.textContaining('Positive'), findsNothing);
    });
  });

  group('one review as it is listed', () {
    testWidgets('it names the reviewer, the stars and the text', (tester) async {
      await pumpOne(tester, ReviewCard(review: review(stars: 5)));
      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('Good pitch, lights were on time.'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(5));
    });

    testWidgets('an anonymous review is still attributed to a player',
        (tester) async {
      await pumpOne(tester, ReviewCard(review: review(reviewerName: null)));
      expect(find.text('A player'), findsOneWidget);
      expect(find.text('A'), findsOneWidget, reason: 'the avatar initial');
    });

    testWidgets('a stars-only review draws no body text', (tester) async {
      await pumpOne(tester, ReviewCard(review: review(text: null)));
      expect(find.text('Good pitch, lights were on time.'), findsNothing);
      expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
    });

    testWidgets('an unscored review shows no sentiment chip', (tester) async {
      await pumpOne(tester, ReviewCard(review: review()));
      expect(find.byType(SentimentChip), findsNothing);
    });

    testWidgets('a scored review carries its sentiment', (tester) async {
      await pumpOne(
        tester,
        ReviewCard(review: review(sentimentLabel: 'positive')),
      );
      expect(find.text('Positive'), findsOneWidget);
    });

    testWidgets('the age is a relative time', (tester) async {
      await pumpOne(
        tester,
        ReviewCard(
          review: review(
            createdAt: DateTime.now().subtract(const Duration(hours: 3)),
          ),
        ),
      );
      expect(find.text('3h ago'), findsOneWidget);
    });

    testWidgets('a review with no date shows no age', (tester) async {
      await pumpOne(tester, ReviewCard(review: review()));
      expect(find.textContaining('ago'), findsNothing);
    });

    // The report affordance is omitted where the viewer cannot flag, such as an
    // owner reading their own venue's reviews.
    testWidgets('there is no report button unless flagging is possible',
        (tester) async {
      await pumpOne(tester, ReviewCard(review: review()));
      expect(find.byIcon(Icons.outlined_flag), findsNothing);
    });

    testWidgets('the report button reports the review', (tester) async {
      var flagged = 0;
      await pumpOne(
        tester,
        ReviewCard(review: review(), onFlag: () => flagged++),
      );
      await tester.tap(find.byIcon(Icons.outlined_flag));
      await tester.pump();
      expect(flagged, 1);
    });

    testWidgets('the report button says what it does', (tester) async {
      await pumpOne(tester, ReviewCard(review: review(), onFlag: () {}));
      expect(find.byTooltip('Report this review'), findsOneWidget);
    });

    // The type tag only belongs on a mixed feed, where a row can be either kind.
    testWidgets('the venue or opponent tag appears only on a mixed feed',
        (tester) async {
      await pumpOne(
        tester,
        ReviewCard(review: review(reviewType: 'opponent')),
      );
      expect(find.text('Opponent'), findsNothing);

      await pumpOne(
        tester,
        ReviewCard(review: review(reviewType: 'opponent'), showType: true),
      );
      expect(find.text('Opponent'), findsOneWidget);
    });

    testWidgets('a venue review is tagged as one on a mixed feed', (tester) async {
      await pumpOne(
        tester,
        ReviewCard(review: review(reviewType: 'venue'), showType: true),
      );
      expect(find.text('Venue'), findsOneWidget);
    });

    testWidgets('a row with no type carries no tag even on a mixed feed',
        (tester) async {
      await pumpOne(tester, ReviewCard(review: review(), showType: true));
      expect(find.text('Venue'), findsNothing);
      expect(find.text('Opponent'), findsNothing);
    });

    testWidgets('a long name ellipsises rather than pushing the tag off',
        (tester) async {
      await pumpOne(
        tester,
        ReviewCard(
          review: review(
            reviewerName: 'Muhammad Abdul Rehman Siddiqui Junior',
            reviewType: 'opponent',
          ),
          showType: true,
          onFlag: () {},
        ),
        width: 260,
      );
      expect(find.text('Opponent'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('a whitespace-only name still yields an initial', (tester) async {
      await pumpOne(tester, ReviewCard(review: review(reviewerName: '   ')));
      expect(find.text('?'), findsOneWidget);
    });
  });

  group('a team\'s standing', () {
    testWidgets('a rated team shows its rating and record', (tester) async {
      await pumpOne(
        tester,
        const TeamReputationStrip(
          teamName: 'Karachi United',
          elo: 1180,
          wins: 4,
          losses: 1,
          draws: 1,
          captainTrustBand: 'good',
          captainTrustScore: 78,
        ),
      );
      expect(find.text('KARACHI UNITED'), findsOneWidget);
      expect(find.text('1180'), findsOneWidget);
      expect(find.text('4-1-1'), findsOneWidget);
      expect(find.text('Trusted · 78'), findsOneWidget);
    });

    // A new team has not earned the seed rating, so printing it would be a claim
    // the team never made.
    testWidgets('a new team is unranked rather than showing a seed rating',
        (tester) async {
      await pumpOne(tester, const TeamReputationStrip(teamName: 'New Team'));
      expect(find.text('Unranked'), findsOneWidget);
      expect(find.textContaining('1000'), findsNothing);
    });

    testWidgets('a team with no matches shows a dash, not three zeroes',
        (tester) async {
      await pumpOne(tester, const TeamReputationStrip(elo: 1000));
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0-0-0'), findsNothing);
    });

    testWidgets('an unnamed team gets the generic heading', (tester) async {
      await pumpOne(tester, const TeamReputationStrip());
      expect(find.text('TEAM REPUTATION'), findsOneWidget);
    });

    testWidgets('a captain with no trust score says there is no rating',
        (tester) async {
      await pumpOne(tester, const TeamReputationStrip(elo: 1100));
      expect(find.text('No rating'), findsOneWidget);
    });

    // 'unknown' is the band TrustTone returns for an unscored captain, and it must
    // not be drawn as a chip reading "Unknown".
    testWidgets('an unknown band is treated as no rating at all', (tester) async {
      await pumpOne(
        tester,
        const TeamReputationStrip(captainTrustBand: 'unknown'),
      );
      expect(find.text('No rating'), findsOneWidget);
      expect(find.text('Unknown'), findsNothing);
    });

    testWidgets('every band gets its own word and icon', (tester) async {
      for (final entry in <String, (String, IconData)>{
        'excellent': ('Highly Trusted', Icons.verified),
        'good': ('Trusted', Icons.thumb_up_alt_outlined),
        'fair': ('Fair', Icons.remove_circle_outline),
        'low': ('Needs Work', Icons.warning_amber_rounded),
      }.entries) {
        await pumpOne(
          tester,
          TeamReputationStrip(captainTrustBand: entry.key),
        );
        expect(find.text(entry.value.$1), findsOneWidget,
            reason: 'band ${entry.key}');
        expect(find.byIcon(entry.value.$2), findsOneWidget);
      }
    });

    testWidgets('a band the server has not shipped yet degrades to unknown',
        (tester) async {
      await pumpOne(
        tester,
        const TeamReputationStrip(captainTrustBand: 'provisional'),
      );
      expect(find.text('Unknown'), findsOneWidget);
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets('a band with a score prints both', (tester) async {
      await pumpOne(
        tester,
        const TeamReputationStrip(
          captainTrustBand: 'excellent',
          captainTrustScore: 94,
        ),
      );
      expect(find.text('Highly Trusted · 94'), findsOneWidget);
    });

    testWidgets('a long team name does not overflow the strip', (tester) async {
      await pumpOne(
        tester,
        const TeamReputationStrip(
          teamName: 'Karachi United Football and Sporting Association',
          elo: 1180,
          wins: 12,
          losses: 4,
          draws: 3,
          captainTrustBand: 'excellent',
          captainTrustScore: 94,
        ),
        width: 340,
      );
      expectNoOverflow(tester);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the gauge still lays out and still reads', (tester) async {
      await pumpOne(tester, const TrustGauge(score: 88), textScale: 2.0);
      await tester.pumpAndSettle();
      expect(find.text('88'), findsOneWidget);
    });

    testWidgets('a metric tile still lays out', (tester) async {
      await pumpOne(
        tester,
        const TrustMetricTile(
          emoji: '⭐',
          label: 'Average rating',
          fraction: 0.84,
          valueText: '4.2 / 5',
          weight: 35,
        ),
        textScale: 2.0,
      );
      expectNoOverflow(tester);
      expect(find.text('+29 of 35 pts'), findsOneWidget);
    });

    testWidgets('the sentiment chip still lays out', (tester) async {
      await pumpOne(
        tester,
        const SentimentChip(label: 'positive', score: 0.92),
        textScale: 2.0,
      );
      expectNoOverflow(tester);
    });

    testWidgets('the histogram still lays out', (tester) async {
      await pumpOne(
        tester,
        const StarsHistogram(counts: [12, 5, 2, 1, 0]),
        textScale: 2.0,
      );
      expectNoOverflow(tester);
    });

    testWidgets('the stars stay pressable', (tester) async {
      await pumpOne(
        tester,
        StarRatingInput(value: 0, onChanged: (_) {}),
        textScale: 2.0,
      );
      expectTapTarget(tester, find.byType(InkResponse).first, minimum: 40);
    });
  });
}
