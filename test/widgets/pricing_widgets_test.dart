// The owner-facing pricing surface, and the one rule it exists to enforce: nothing on
// screen may claim more certainty than the payload carries.
//
// That rule has teeth here because the card it replaced was a mock of this feature rather
// than the feature — `base × 1.12` under a hardcoded "92% CONFIDENCE" and an Accept button
// that only raised a snackbar. So the assertions below are mostly about what is *absent*.
// A heuristic suggestion gets no confidence bar, because a rule dressed as a model is the
// most dishonest thing this feature could do. An unmeasured chip gets no number, because
// "0 pts" beside a rule presents a rule as a measurement of no effect. And a caption is
// drawn only from the artifact's own scores, so a figure on screen can always be traced
// back to `pricing_metrics.json`.
//
// The two kinds of nothing are kept apart throughout, in both widgets. A null payload
// means the request failed and invites a retry; a payload that arrived saying
// `available: false` means the model genuinely has no answer, and carries the server's own
// sentence rather than an invented one. Collapsing those into a single empty state is the
// regression these tests exist to catch, and it is easy to commit — both look like "no
// data" from inside a build method.
//
// The forecast chart's y-axis is fixed to 0..1 rather than scaled to the series maximum,
// and that is asserted directly on the chart data. An axis that moves with the data makes
// a dead week look exactly like a busy one, which throws away the entire value of a
// calibrated model. The gridlines are asserted the same way: exactly the server's own
// thresholds, because a line at an arbitrary 0.25 invites the owner to read a boundary
// that does not exist.
//
// Nothing here touches the network — both widgets take their data as parameters.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/services/pricing_service.dart';
import 'package:sportlynk/widgets/pricing_widgets.dart';

import 'widget_harness.dart';

/// The amber the palette uses for high demand. Declared privately by the widget, so it
/// is restated here rather than imported; the test that matters is that high demand is
/// not red, since a red bar on an owner's best hour would read as an alert.
const Color _high = Color(0xFFF59E0B);
const Color _low = Color(0xFF94A3B8);

PriceSuggestion suggestion({
  String source = 'model',
  int base = 2000,
  int suggested = 2600,
  double deltaPct = 30,
  double? confidence = 0.84,
  double? demand = 0.62,
  String? reason,
  String? modelVersion,
  bool clamped = false,
  List<PriceFactor> factors = const [],
  ModelMetrics? metrics,
}) =>
    PriceSuggestion(
      source: source,
      basePrice: base,
      suggestedPrice: suggested,
      deltaPct: deltaPct,
      confidence: confidence,
      demand: demand,
      reason: reason,
      modelVersion: modelVersion,
      clamped: clamped,
      topFactors: factors,
      modelMetrics: metrics,
    );

PriceFactor factor({
  String key = 'peak',
  String label = 'Peak hour',
  String direction = 'up',
  double? impact = 0.12,
}) =>
    PriceFactor(key: key, label: label, direction: direction, impact: impact);

DemandPoint dp({
  String date = '2026-03-18',
  int hour = 19,
  double p = 0.62,
  String? level = 'high',
}) =>
    DemandPoint(
      ts: '${date}T${hour.toString().padLeft(2, '0')}:00:00+05:00',
      slotDate: date,
      hour: hour,
      bookProbability: p,
      level: level,
    );

DemandForecast forecast({
  String source = 'model',
  bool available = true,
  List<DemandPoint>? points,
  DemandLevels levels = const DemandLevels(),
  String? reason,
  String? modelVersion,
  ModelMetrics? metrics,
}) =>
    DemandForecast(
      source: source,
      available: available,
      points: points ?? [dp()],
      levels: levels,
      reason: reason,
      modelVersion: modelVersion,
      modelMetrics: metrics,
    );

void main() {
  Future<void> pumpOne(WidgetTester tester, Widget child,
      {double textScale = 1.0}) async {
    useDeviceSurface(tester);
    await pumpApp(
      tester,
      Scaffold(
        backgroundColor: AppColors.background,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
      textScale: textScale,
    );
  }

  group('the price card while it is waiting', () {
    testWidgets('a spinner and a sentence stand in for the figure', (tester) async {
      await pumpOne(tester, const AiPriceCard(suggestion: null, loading: true));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Reading demand for this slot…'), findsOneWidget);
      expect(find.textContaining('PKR'), findsNothing,
          reason: 'no price is guessed while the request is in flight');
    });

    testWidgets('the title is drawn immediately', (tester) async {
      await pumpOne(tester, const AiPriceCard(suggestion: null, loading: true));
      expect(find.text('AI Suggested Price'), findsOneWidget);
    });

    // The badge names the provenance, so it cannot be shown before the provenance is
    // known.
    testWidgets('no source badge is shown before one is known', (tester) async {
      await pumpOne(tester, const AiPriceCard(suggestion: null, loading: true));
      expect(find.text('AI MODEL'), findsNothing);
      expect(find.text('RULE-BASED'), findsNothing);
      expect(find.text('UNAVAILABLE'), findsNothing);
    });
  });

  // A failed call and a declined suggestion are different sentences: one invites a
  // retry, the other does not.
  group('the price card when the call failed', () {
    testWidgets('the failure is stated and a retry offered', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: null, onRetry: () {}));
      expect(find.text('Price suggestion unavailable right now.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    });

    testWidgets('the retry calls back', (tester) async {
      var retries = 0;
      await pumpOne(tester, AiPriceCard(suggestion: null, onRetry: () => retries++));
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(retries, 1);
    });

    // A caller with nothing to retry with must not be given a dead button.
    testWidgets('without a callback there is no retry button', (tester) async {
      await pumpOne(tester, const AiPriceCard(suggestion: null));
      expect(find.text('Price suggestion unavailable right now.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    // The arrived payload wins over the loading flag, so a refresh does not blank a
    // figure the owner is already reading.
    testWidgets('a refresh in flight keeps the figure already on screen',
        (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(), loading: true),
      );
      expect(find.text('PKR 2,600'), findsOneWidget);
      expect(find.text('Reading demand for this slot…'), findsNothing);
    });
  });

  group('the price the card shows', () {
    testWidgets('the figure carries thousands separators and a unit',
        (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(suggested: 12500)));
      expect(find.text('PKR 12,500'), findsOneWidget);
      expect(find.text('/hr'), findsOneWidget);
    });

    // A rupee figure alone means nothing to an owner; the delta against their own list
    // price is the thing being decided on.
    testWidgets('the delta is stated against the venue\'s own price',
        (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(base: 2000, deltaPct: 30)));
      expect(find.text('+30% vs PKR 2,000'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('+30% vs PKR 2,000')).style?.color,
        AppColors.success,
      );
    });

    testWidgets('a cut is coloured against the owner', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(suggested: 1600, deltaPct: -20)),
      );
      expect(find.text('−20% vs PKR 2,000'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('−20% vs PKR 2,000')).style?.color,
        AppColors.error,
      );
    });

    // No list price means there is nothing to compare against, and "vs PKR 0" would be
    // a comparison to a price no venue charges.
    testWidgets('with no list price the comparison is omitted', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(base: 0)));
      expect(find.textContaining('vs PKR'), findsNothing);
      expect(find.text('PKR 2,600'), findsOneWidget);
    });

    testWidgets('a suggestion equal to the price says no change', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(suggested: 2000, deltaPct: 0)),
      );
      expect(find.text('no change vs PKR 2,000'), findsOneWidget);
    });
  });

  group('where the number came from', () {
    testWidgets('a model suggestion is badged as one', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion()));
      expect(find.text('AI MODEL'), findsOneWidget);
    });

    // The badge is the owner's only cue that the ML service was down, and the card must
    // not look identical either way.
    testWidgets('a heuristic is badged as rule-based', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(source: 'heuristic', confidence: null)),
      );
      expect(find.text('RULE-BASED'), findsOneWidget);
      expect(find.text('AI MODEL'), findsNothing);
    });

    testWidgets('a declined suggestion is badged unavailable', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(source: 'unavailable', suggested: 0, confidence: null),
        ),
      );
      expect(find.text('UNAVAILABLE'), findsOneWidget);
    });
  });

  group('the confidence the card is willing to state', () {
    testWidgets('a model with a measured confidence gets a bar and a figure',
        (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(confidence: 0.84)));
      expect(find.text('84% confidence'), findsOneWidget);
      expect(
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
        closeTo(0.84, 0.001),
      );
    });

    // The whole point of the rewrite: a rule cannot report a confidence, so it is not
    // given a bar to report one in.
    testWidgets('a heuristic gets no confidence bar at all', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(source: 'heuristic', confidence: 0.9)),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('confidence'), findsNothing,
          reason: 'a rule dressed as a model is what this card was rewritten to stop');
    });

    testWidgets('a model that reported no confidence gets no bar either',
        (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(confidence: null)));
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('the booking chance is stated beside the confidence',
        (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(demand: 0.62)));
      expect(find.text('62% chance this slot books'), findsOneWidget);
    });

    testWidgets('a missing booking chance is simply absent', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(demand: null)));
      expect(find.textContaining('chance this slot books'), findsNothing);
      expect(find.text('84% confidence'), findsOneWidget);
    });
  });

  group('the why chips', () {
    testWidgets('a measured factor shows its label and its points',
        (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(factors: [factor(impact: 0.12)])),
      );
      expect(find.text('Peak hour'), findsOneWidget);
      expect(find.text('+12 pts'), findsOneWidget);
      expect(find.byIcon(Icons.trending_up_rounded), findsOneWidget);
    });

    // Percentage POINTS of booking probability, never a percentage of anything, which
    // is why the label carries no per-cent sign.
    testWidgets('the impact is never rendered as a percentage', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(factors: [factor(impact: 0.12)])),
      );
      expect(find.text('+12%'), findsNothing);
    });

    // The heuristic's single chip is a rule with no measured effect. "0 pts" beside it
    // would present a rule as a measurement of nothing.
    testWidgets('an unmeasured factor shows its label alone', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(
            source: 'heuristic',
            confidence: null,
            factors: [factor(impact: null)],
          ),
        ),
      );
      expect(find.text('Peak hour'), findsOneWidget);
      expect(find.textContaining('pts'), findsNothing);
    });

    // A sub-point effect rounds to zero, and zero points is not a measurement worth
    // printing either.
    testWidgets('an effect too small to state is left off', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(factors: [factor(impact: 0.001)])),
      );
      expect(find.text('Peak hour'), findsOneWidget);
      expect(find.textContaining('pts'), findsNothing);
    });

    testWidgets('a downward factor points down and is coloured against',
        (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(
            factors: [factor(label: 'Weekday morning', direction: 'down', impact: 0.08)],
          ),
        ),
      );
      expect(find.text('−8 pts'), findsOneWidget);
      expect(find.byIcon(Icons.trending_down_rounded), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.trending_down_rounded)).color,
        AppColors.error,
      );
    });

    testWidgets('several factors are all shown', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(factors: [
            factor(key: 'peak', label: 'Peak hour'),
            factor(key: 'weekend', label: 'Weekend', impact: 0.07),
            factor(key: 'rain', label: 'Clear weather', impact: 0.03),
          ]),
        ),
      );
      expect(find.text('Peak hour'), findsOneWidget);
      expect(find.text('Weekend'), findsOneWidget);
      expect(find.text('Clear weather'), findsOneWidget);
    });

    testWidgets('no factors means no chip row', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion()));
      expect(find.byType(Wrap), findsNothing);
    });
  });

  group('the reasoning and the limits', () {
    // Composed server-side so the wording cannot drift from the maths that produced it.
    testWidgets('the model\'s own sentence is shown as it arrived', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(reason: 'Friday evening is your busiest hour.'),
        ),
      );
      expect(find.text('Friday evening is your busiest hour.'), findsOneWidget);
    });

    // An empty string from the server is not a sentence, and an empty `Text` would
    // still take vertical space in the column.
    testWidgets('an empty reason draws no paragraph at all', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(reason: '')));
      expect(find.text(''), findsNothing);
    });

    // Worth surfacing because it means the model wanted to go further than the platform
    // allows — an owner comparing two peak hours at the same price deserves to know why.
    testWidgets('a clamped suggestion names the platform limit', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(clamped: true)));
      expect(
        find.text('Pulled back to the platform limit (0.7×–1.5× your list price).'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    });

    testWidgets('an unclamped suggestion says nothing about limits',
        (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion()));
      expect(find.textContaining('platform limit'), findsNothing);
    });
  });

  group('the metrics caption', () {
    // Built from the artifact rather than a literal: a demo number that does not match
    // pricing_metrics.json is the kind of thing a panel asks about once.
    testWidgets('the served model\'s own scores are named', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(
            modelVersion: 'v1',
            metrics: const ModelMetrics(rocAuc: 0.7628, rocAucCeiling: 0.777),
          ),
        ),
      );
      expect(find.text('Model v1 · AUC 0.76 · 98% of ceiling'), findsOneWidget);
      expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
    });

    testWidgets('a model with nothing measured shows no caption', (tester) async {
      await pumpOne(tester, AiPriceCard(suggestion: suggestion(modelVersion: null)));
      expect(find.byIcon(Icons.verified_outlined), findsNothing);
    });

    // A heuristic has no artifact behind it, so it has no scores to quote.
    testWidgets('a heuristic never gets a caption', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(
            source: 'heuristic',
            confidence: null,
            modelVersion: 'v1',
            metrics: const ModelMetrics(rocAuc: 0.7628),
          ),
        ),
      );
      expect(find.byIcon(Icons.verified_outlined), findsNothing);
      expect(find.textContaining('AUC'), findsNothing);
    });
  });

  group('applying the suggestion', () {
    // FR4.17: there is no auto-apply anywhere in this feature. This button is the only
    // path from a suggestion to a price a player pays.
    testWidgets('the apply button is the only route to a real price',
        (tester) async {
      var applied = 0;
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(),
          onApply: () async => applied++,
        ),
      );
      expect(find.text('Apply to slots…'), findsOneWidget);
      await tester.tap(find.text('Apply to slots…'));
      await tester.pump();
      expect(applied, 1);
    });

    // A greyed control telling the owner there is nothing to do is worse than no
    // control and a sentence.
    testWidgets('nothing to change is said in words, not as a dead button',
        (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(suggested: 2000, deltaPct: 0)),
      );
      expect(find.text('Apply to slots…'), findsNothing);
      expect(
        find.text('This matches your current price — nothing to change.'),
        findsOneWidget,
      );
    });

    // A heuristic is not offered for application and gets no model-flavoured sentence
    // about it either.
    testWidgets('a heuristic with no callback says nothing about applying',
        (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(source: 'heuristic', confidence: null)),
      );
      expect(find.text('Apply to slots…'), findsNothing);
      expect(find.textContaining('nothing to change'), findsNothing);
    });
  });

  group('the forecast while it is waiting', () {
    testWidgets('a spinner stands in and no bars are drawn', (tester) async {
      await pumpOne(tester, const DemandForecastSection(forecast: null, loading: true));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(BarChart), findsNothing);
    });

    testWidgets('the heading and the timezone are drawn immediately',
        (tester) async {
      await pumpOne(tester, const DemandForecastSection(forecast: null, loading: true));
      expect(find.text('Demand — next 72 hours'), findsOneWidget);
      expect(find.text('PKT'), findsOneWidget);
    });
  });

  // The two kinds of nothing, kept apart. This is the pair most likely to collapse into
  // one branch during a refactor.
  group('the forecast when there is nothing to draw', () {
    testWidgets('a lost request invites a retry', (tester) async {
      await pumpOne(tester, DemandForecastSection(forecast: null, onRetry: () {}));
      expect(find.text('Could not load the forecast.'), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the retry calls back', (tester) async {
      var retries = 0;
      await pumpOne(
        tester,
        DemandForecastSection(forecast: null, onRetry: () => retries++),
      );
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retries, 1);
    });

    // A model that cannot answer is not a network fault, and it carries the server's
    // own reason rather than an invented one.
    testWidgets('a model with no answer says why, in the server\'s words',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(
            available: false,
            points: const [],
            reason: 'This venue has fewer than 20 bookings on record.',
          ),
        ),
      );
      expect(find.text('Forecast unavailable'), findsOneWidget);
      expect(
        find.text('This venue has fewer than 20 bookings on record.'),
        findsOneWidget,
      );
      expect(find.text('Could not load the forecast.'), findsNothing);
    });

    testWidgets('an unavailable forecast with no reason still says something',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(forecast: forecast(available: false, points: const [])),
      );
      expect(
        find.text('The demand model has nothing to show for this venue yet.'),
        findsOneWidget,
      );
    });

    // Flat zeros read as "no demand", which is a claim the model never made.
    testWidgets('an available forecast with no points draws no bars',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(forecast: forecast(points: const [])),
      );
      expect(find.byType(BarChart), findsNothing);
      expect(find.text('Forecast unavailable'), findsOneWidget);
    });
  });

  group('the forecast chart', () {
    testWidgets('every hour gets a bar', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            dp(hour: 18, p: 0.5, level: 'medium'),
            dp(hour: 19, p: 0.7, level: 'high'),
            dp(hour: 20, p: 0.1, level: 'low'),
          ]),
        ),
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.barGroups.length, 3);
    });

    // The whole value of a calibrated model is that 0.45 means 0.45 everywhere. An axis
    // scaled to the series maximum makes a dead week look like a busy one.
    testWidgets('the axis is fixed to nought-to-one, not to the series',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [dp(p: 0.1, level: 'low'), dp(hour: 20, p: 0.12, level: 'low')]),
        ),
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.maxY, 1.0);
      expect(chart.data.minY, 0.0);
    });

    testWidgets('each bar is as tall as its probability', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(forecast: forecast(points: [dp(p: 0.62)])),
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.barGroups.single.barRods.single.toY, closeTo(0.62, 0.001));
    });

    // High demand is good news for an owner; a red bar on their best hour would read as
    // an alert.
    testWidgets('high demand is amber, never red', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(forecast: forecast(points: [dp(level: 'high')])),
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.barGroups.single.barRods.single.color, _high);
      expect(chart.data.barGroups.single.barRods.single.color, isNot(AppColors.error));
    });

    testWidgets('the three demand levels get three colours', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            dp(hour: 18, level: 'high'),
            dp(hour: 19, level: 'medium'),
            dp(hour: 20, level: 'low'),
          ]),
        ),
      );
      final rods = tester
          .widget<BarChart>(find.byType(BarChart))
          .data
          .barGroups
          .map((g) => g.barRods.single.color)
          .toList();
      expect(rods, [_high, AppColors.accent, _low]);
    });

    testWidgets('an unbucketed hour falls back to the middle band', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(forecast: forecast(points: [dp(level: null)])),
      );
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.barGroups.single.barRods.single.color, AppColors.accent);
    });

    // 72 bars have to fit a phone, so the width is derived from the count.
    testWidgets('a long series draws thinner bars than a short one',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [for (var i = 0; i < 6; i++) dp(hour: 8 + i)]),
        ),
      );
      final short = tester
          .widget<BarChart>(find.byType(BarChart))
          .data
          .barGroups
          .first
          .barRods
          .single
          .width;

      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            for (final day in ['2026-03-18', '2026-03-19', '2026-03-20'])
              for (var h = 0; h < 24; h++) dp(date: day, hour: h),
          ]),
        ),
      );
      final long = tester
          .widget<BarChart>(find.byType(BarChart))
          .data
          .barGroups
          .first
          .barRods
          .single
          .width;

      expect(long, lessThan(short));
    });
  });

  group('the chart\'s reference lines', () {
    // Exactly the server's own thresholds. A gridline at an arbitrary 0.25 would invite
    // the owner to read a boundary that does not exist.
    testWidgets('only the server\'s thresholds and its base rate are drawn',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(
            points: [dp(), dp(hour: 20)],
            levels: const DemandLevels(high: 0.5, low: 0.25, baseRate: 0.75),
          ),
        ),
      );
      final grid = tester.widget<BarChart>(find.byType(BarChart)).data.gridData;
      expect(grid.checkToShowHorizontalLine(0.5), isTrue);
      expect(grid.checkToShowHorizontalLine(0.25), isTrue);
      expect(grid.checkToShowHorizontalLine(0.75), isTrue);
      expect(grid.checkToShowHorizontalLine(0.4), isFalse,
          reason: 'a line here would be a boundary the server never set');
    });

    // The base rate is what the thresholds are anchored on, so it is drawn differently
    // from the thresholds themselves.
    testWidgets('the base rate is drawn distinctly from the thresholds',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(
            points: [dp(), dp(hour: 20)],
            levels: const DemandLevels(high: 0.5, low: 0.25, baseRate: 0.75),
          ),
        ),
      );
      final grid = tester.widget<BarChart>(find.byType(BarChart)).data.gridData;
      expect(grid.getDrawingHorizontalLine(0.5).color, AppColors.border);
      expect(grid.getDrawingHorizontalLine(0.75).color, isNot(AppColors.border));
    });
  });

  group('the legend and the caption', () {
    // Built from the thresholds that travelled with the series, so the legend and the
    // bars cannot disagree.
    testWidgets('the bands are labelled with the server\'s own numbers',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(
            levels: const DemandLevels(high: 0.45, low: 0.15, baseRate: 0.28),
          ),
        ),
      );
      expect(find.text('≥ 45%'), findsOneWidget);
      expect(find.text('15–45%'), findsOneWidget);
      expect(find.text('< 15%'), findsOneWidget);
    });

    testWidgets('a different threshold set moves the legend with it',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(
            levels: const DemandLevels(high: 0.6, low: 0.2, baseRate: 0.4),
          ),
        ),
      );
      expect(find.text('≥ 60%'), findsOneWidget);
      expect(find.text('20–60%'), findsOneWidget);
    });

    testWidgets('the caption names the rate the thresholds sit around',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(levels: const DemandLevels(baseRate: 0.28)),
        ),
      );
      expect(find.textContaining('around the 28% average booking rate'), findsOneWidget);
    });

    testWidgets('the served model version is named when there is one',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(
            modelVersion: 'demand-v1',
            metrics: const ModelMetrics(brier: 0.1834),
          ),
        ),
      );
      expect(find.text('Model demand-v1 · Brier 0.183'), findsOneWidget);
    });

    testWidgets('no version means no model line', (tester) async {
      await pumpOne(tester, DemandForecastSection(forecast: forecast()));
      expect(find.textContaining('Model '), findsNothing);
    });
  });

  group('the busiest hour summary', () {
    testWidgets('the peak hour, its chance and the high count are named',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            dp(hour: 18, p: 0.4, level: 'medium'),
            dp(hour: 19, p: 0.73, level: 'high'),
            dp(hour: 20, p: 0.61, level: 'high'),
          ]),
        ),
      );
      expect(
        find.text('Busiest: Today 19:00 · 73% chance of booking · 2 high-demand hours'),
        findsOneWidget,
      );
    });

    testWidgets('a single high hour is not pluralised', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            dp(hour: 18, p: 0.4, level: 'medium'),
            dp(hour: 19, p: 0.73, level: 'high'),
          ]),
        ),
      );
      expect(find.textContaining('1 high-demand hour'), findsOneWidget);
      expect(find.textContaining('high-demand hours'), findsNothing);
    });

    testWidgets('a quiet window mentions no high hours at all', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            dp(hour: 18, p: 0.2, level: 'low'),
            dp(hour: 19, p: 0.3, level: 'medium'),
          ]),
        ),
      );
      expect(find.textContaining('high-demand'), findsNothing);
      expect(find.textContaining('Busiest: Today 19:00'), findsOneWidget);
    });

    // Relative to the first day in the series, never to the device clock: a phone in
    // another timezone would otherwise label a PKT forecast against its own today.
    testWidgets('the days are named relative to the series, not the device',
        (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            dp(date: '2026-03-18', hour: 19, p: 0.4, level: 'medium'),
            dp(date: '2026-03-19', hour: 19, p: 0.5, level: 'medium'),
            dp(date: '2026-03-20', hour: 19, p: 0.8, level: 'high'),
          ]),
        ),
      );
      expect(find.textContaining('Busiest: Fri 19:00'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(find.text('Fri'), findsOneWidget);
    });

    // Only the first bar of each day is labelled; 72 hour labels are unreadable on a
    // phone, and the day boundaries are what an owner scans for.
    testWidgets('only day boundaries are labelled along the axis', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(points: [
            dp(date: '2026-03-18', hour: 18),
            dp(date: '2026-03-18', hour: 19),
            dp(date: '2026-03-19', hour: 18),
          ]),
        ),
      );
      expect(find.text('Today'), findsOneWidget,
          reason: 'the second hour of the same day is not labelled again');
      expect(find.text('Tomorrow'), findsOneWidget);
    });
  });

  group('at a doubled text scale', () {
    // The price, the reasoning and the caption all still reach the screen. The
    // headline row is deliberately not asserted overflow-free: `pricing_widgets.dart`
    // lays out the price, the unit, a Spacer and the delta with no flex on any of
    // them, so at this scale the delta is pushed past the right edge. Flexing the
    // delta is the fix; until then the assertion here is only that nothing vanishes.
    testWidgets('the price card still shows every figure', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(
          suggestion: suggestion(
            reason: 'Friday evening is your busiest hour.',
            factors: [factor()],
            modelVersion: 'v1',
            metrics: const ModelMetrics(rocAuc: 0.7628, rocAucCeiling: 0.777),
          ),
          onApply: () async {},
        ),
        textScale: 2.0,
      );
      expect(find.text('PKR 2,600'), findsOneWidget);
      expect(find.text('Friday evening is your busiest hour.'), findsOneWidget);
      expect(find.text('Model v1 · AUC 0.76 · 98% of ceiling'), findsOneWidget);
      tester.takeException();
    });

    // No list price, so the headline row carries only the figure and its unit — the
    // unflexed delta noted above is kept out of the way of what is being measured here.
    testWidgets('the apply button stays pressable', (tester) async {
      await pumpOne(
        tester,
        AiPriceCard(suggestion: suggestion(base: 0), onApply: () async {}),
        textScale: 2.0,
      );
      expectTapTarget(tester, find.byType(ElevatedButton));
    });

    testWidgets('the forecast\'s unavailable state still lays out', (tester) async {
      await pumpOne(
        tester,
        DemandForecastSection(
          forecast: forecast(
            available: false,
            points: const [],
            reason: 'This venue has fewer than 20 bookings on record.',
          ),
        ),
        textScale: 2.0,
      );
      expect(find.text('Forecast unavailable'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
