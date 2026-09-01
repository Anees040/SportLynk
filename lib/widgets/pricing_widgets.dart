import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/colors.dart';
import '../services/pricing_service.dart';

/// The owner-facing surface of the pricing model (S.3 Wave D).
///
/// Kept out of the two screens because both the dashboard card and the venue
/// forecast need the same demand palette and the same honesty rules, and two
/// copies of "which green means high demand" is two answers to one question.
///
/// The rule every widget here obeys: **nothing on screen may claim more certainty
/// than the payload carries.** A heuristic suggestion does not get a confidence
/// bar, an unmeasured chip does not get a number, and an unavailable forecast
/// draws nothing rather than a row of zero-height bars that reads as "no demand".

// Demand palette
// Amber for high rather than red: high demand is good news for an owner, and a red
// bar on their best hour would read as an alert. Green is the app's accent and
// stays for the middle band; grey-blue marks the quiet hours worth discounting.
const Color _kHigh = Color(0xFFF59E0B);
const Color _kMedium = AppColors.accent;
const Color _kLow = Color(0xFF94A3B8);

Color demandColor(String? level) => switch (level) {
      'high' => _kHigh,
      'low' => _kLow,
      _ => _kMedium,
    };

String demandWord(String? level) => switch (level) {
      'high' => 'High',
      'low' => 'Low',
      'medium' => 'Steady',
      _ => 'Unknown',
    };

// AI PRICE card (FR4.17)

/// The dashboard's price card. Replaces the old static one, which showed
/// `base × 1.12` under a hardcoded "92% CONFIDENCE" and an Accept button that only
/// raised a snackbar — a mock of this feature rather than the feature.
///
/// [onApply] is nullable: when the suggestion is not actionable (heuristic source,
/// unavailable, or already equal to the current price) the button is absent rather
/// than disabled-and-explaining, because an owner does not need a greyed control
/// telling them there is nothing to do.
class AiPriceCard extends StatelessWidget {
  final PriceSuggestion? suggestion;
  final bool loading;

  /// Non-null only when applying is possible. Called with the suggested price.
  final Future<void> Function()? onApply;
  final VoidCallback? onRetry;

  const AiPriceCard({
    super.key,
    required this.suggestion,
    this.loading = false,
    this.onApply,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final s = suggestion;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              const Text('✨', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Text(
                'AI Suggested Price',
                style: GoogleFonts.poppins(
                    fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textPrimary),
              ),
            ]),
            if (s != null) _sourceBadge(s),
          ]),
          const SizedBox(height: 10),
          if (loading && s == null)
            _skeleton()
          else if (s == null)
            _unavailable(context)
          else
            ..._body(context, s),
        ],
      ),
    );
  }

  // States

  Widget _skeleton() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
          ),
          const SizedBox(height: 10),
          Text('Reading demand for this slot…',
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        ],
      );

  /// `null` here means the call failed, not that the model declined — so this
  /// offers a retry. A model that answered "no suggestion" comes back as a
  /// suggestion with `source: unavailable` and gets its own sentence below.
  Widget _unavailable(BuildContext context) => Row(children: [
        const Icon(Icons.cloud_off_rounded, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Price suggestion unavailable right now.',
            style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
          ),
        ),
        if (onRetry != null)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('Retry', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
      ]);

  List<Widget> _body(BuildContext context, PriceSuggestion s) {
    final conf = s.confidence;
    final demandPct = s.demand == null ? null : (s.demand! * 100).round();

    return [
      // Price + delta against the venue's current list price. The delta is what an
      // owner decides on — "PKR 2,600" means nothing without "up 30% from
      // your 2,000" beside it.
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(
          'PKR ${_fmt(s.suggestedPrice)}',
          style: GoogleFonts.poppins(
              fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.primary),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('/hr',
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        ),
        const Spacer(),
        if (s.basePrice > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${s.deltaLabel} vs PKR ${_fmt(s.basePrice)}',
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: s.deltaPct >= 0 ? AppColors.success : AppColors.error,
              ),
            ),
          ),
      ]),

      // Confidence bar — only on the model path, and only when a real number came
      // back. It is derived server-side (curve identification × boundary penalty ×
      // model attainment), never a constant.
      if (s.isModel && conf != null) ...[
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: conf.clamp(0.0, 1.0),
            backgroundColor: AppColors.border,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
            minHeight: 3,
          ),
        ),
        const SizedBox(height: 5),
        Row(children: [
          Text('${s.confidenceLabel} confidence',
              style: GoogleFonts.poppins(
                  fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          if (demandPct != null) ...[
            Text(' · ',
                style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary)),
            Text('$demandPct% chance this slot books',
                style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary)),
          ],
        ]),
      ],

      // "Why" chips (top_factors). Each is a per-request counterfactual: the model
      // re-scored with that one piece of context moved to neutral.
      if (s.topFactors.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final f in s.topFactors) _factorChip(f)],
        ),
      ],

      // The model's own sentence — it already includes the policy-cap note when the
      // sweep sat on its bound, which is the honest reason a peak price stops where
      // it does. Composed server-side so the wording cannot drift from the maths.
      if (s.reason != null && s.reason!.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          s.reason!,
          style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary, height: 1.35),
        ),
      ],

      if (s.clamped) ...[
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline_rounded, size: 12, color: AppColors.warning),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              'Pulled back to the platform limit (0.7×–1.5× your list price).',
              style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.warning),
            ),
          ),
        ]),
      ],

      const SizedBox(height: 12),

      // FR4.17: the owner keeps control. There is no auto-apply anywhere in this
      // feature — this button is the only path from a suggestion to a real price.
      if (onApply != null)
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => onApply!(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            icon: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
            label: Text(
              'Apply to slots…',
              style: GoogleFonts.poppins(
                  color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        )
      else if (s.isModel && !s.isActionable)
        Text('This matches your current price — nothing to change.',
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),

      // The caption from the brief, built from the artifact's measured scores rather
      // than a literal. Absent when there is nothing measured to show.
      if (s.modelCaption != null) ...[
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.verified_outlined,
              size: 11, color: AppColors.textSecondary.withValues(alpha: 0.8)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              s.modelCaption!,
              style: GoogleFonts.poppins(
                fontSize: 9.5,
                color: AppColors.textSecondary.withValues(alpha: 0.9),
                letterSpacing: 0.2,
              ),
            ),
          ),
        ]),
      ],
    ];
  }

  Widget _sourceBadge(PriceSuggestion s) {
    final (text, bg) = switch (s.source) {
      'model' => ('AI MODEL', AppColors.accent),
      'heuristic' => ('RULE-BASED', AppColors.warning),
      _ => ('UNAVAILABLE', AppColors.disabled),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(
        text,
        style: GoogleFonts.poppins(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _factorChip(PriceFactor f) {
    final impact = f.impactLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          f.isUp ? Icons.trending_up_rounded : Icons.trending_down_rounded,
          size: 12,
          color: f.isUp ? AppColors.success : AppColors.error,
        ),
        const SizedBox(width: 5),
        Text(f.label,
            style: GoogleFonts.poppins(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        // Only a measured factor shows a number. The heuristic's single chip is a
        // rule with no measured effect; printing "0 pts" beside it would present a
        // rule as a measurement of nothing.
        if (impact != null) ...[
          const SizedBox(width: 5),
          Text(impact,
              style: GoogleFonts.poppins(fontSize: 9.5, color: AppColors.textSecondary)),
        ],
      ]),
    );
  }
}

// 72-hour DEMAND forecast (FR4.18)

/// The forecast section for the venue management screen: a 72-bar chart coloured by
/// demand level, with PKT labels and a legend generated from the same thresholds the
/// server used to bucket the bars.
class DemandForecastSection extends StatelessWidget {
  final DemandForecast? forecast;
  final bool loading;
  final VoidCallback? onRetry;

  const DemandForecastSection({
    super.key,
    required this.forecast,
    this.loading = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final f = forecast;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.insights_rounded, size: 16, color: AppColors.accent),
          const SizedBox(width: 6),
          Text('Demand — next 72 hours',
              style: GoogleFonts.poppins(
                  fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const Spacer(),
          Text('PKT',
              style: GoogleFonts.poppins(
                  fontSize: 9.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        ]),
        const SizedBox(height: 4),
        if (loading && f == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent))),
          )
        else if (f == null)
          _message(
            'Could not load the forecast.',
            'Check your connection and try again.',
            showRetry: true,
          )
        else if (!f.available || f.isEmpty)
          // The server's own sentence, not an invented one. A forecast the model
          // could not produce is different from one the network lost.
          _message(
            'Forecast unavailable',
            f.reason ?? 'The demand model has nothing to show for this venue yet.',
            showRetry: onRetry != null,
          )
        else
          ..._chart(f),
      ]),
    );
  }

  Widget _message(String title, String body, {bool showRetry = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: GoogleFonts.poppins(
                  fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(body,
              style: GoogleFonts.poppins(
                  fontSize: 11, color: AppColors.textSecondary, height: 1.35)),
          if (showRetry && onRetry != null) ...[
            const SizedBox(height: 6),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.accent,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('Try again',
                  style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      );

  List<Widget> _chart(DemandForecast f) {
    final points = f.points;
    final peak = f.peak;

    // The y-axis is fixed to 0..1, not scaled to the series max. A probability chart
    // whose axis moves with the data makes a dead week look exactly like a busy one —
    // the whole value of a calibrated model is that 0.45 means 0.45 everywhere.
    const maxY = 1.0;

    return [
      if (peak != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Busiest: ${_dayWord(peak.slotDate, f.days)} ${peak.hourLabel} · '
            '${(peak.bookProbability * 100).round()}% chance of booking'
            '${f.highCount > 0 ? ' · ${f.highCount} high-demand hour${f.highCount == 1 ? '' : 's'}' : ''}',
            style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
          ),
        ),
      SizedBox(
        height: 150,
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceBetween,
            maxY: maxY,
            minY: 0,
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => AppColors.primary,
                getTooltipItem: (group, groupIdx, rod, rodIdx) {
                  final p = points[group.x.clamp(0, points.length - 1)];
                  return BarTooltipItem(
                    '${_dayWord(p.slotDate, f.days)} ${p.hourLabel} PKT\n'
                    '${(p.bookProbability * 100).round()}% · ${demandWord(p.level)} demand',
                    GoogleFonts.poppins(
                        color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, height: 1.35),
                  );
                },
              ),
            ),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              // Exactly three reference lines, and they are the server's thresholds:
              // the two that bucket the bars plus the base rate they are anchored on.
              // A gridline at an arbitrary 0.25 would invite the owner to read a
              // boundary that does not exist.
              horizontalInterval: 0.25,
              checkToShowHorizontalLine: (v) =>
                  (v - f.levels.high).abs() < 0.001 ||
                  (v - f.levels.low).abs() < 0.001 ||
                  (v - f.levels.baseRate).abs() < 0.001,
              getDrawingHorizontalLine: (v) => FlLine(
                color: (v - f.levels.baseRate).abs() < 0.001
                    ? AppColors.textSecondary.withValues(alpha: 0.35)
                    : AppColors.border,
                strokeWidth: 1,
                dashArray: const [4, 4],
              ),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 30,
                  interval: 0.5,
                  getTitlesWidget: (v, _) => Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Text('${(v * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary)),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 24,
                  interval: 1,
                  getTitlesWidget: (v, _) {
                    final i = v.round();
                    if (i < 0 || i >= points.length) return const SizedBox.shrink();
                    // 72 hour labels is unreadable on a phone, so only the first bar
                    // of each new day is labelled — which also draws the day
                    // boundaries the owner is scanning for.
                    final isDayStart = i == 0 || points[i].slotDate != points[i - 1].slotDate;
                    if (!isDayStart) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        _dayWord(points[i].slotDate, f.days),
                        style: GoogleFonts.poppins(
                            fontSize: 9, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < points.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: points[i].bookProbability.clamp(0.0, 1.0),
                      width: _barWidth(points.length),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                      color: demandColor(points[i].level),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      // Legend built from `f.levels` — the thresholds travelled with the series, so
      // the legend and the bars cannot disagree.
      Wrap(spacing: 12, runSpacing: 6, children: [
        _legend(_kHigh, 'High', '≥ ${(f.levels.high * 100).round()}%'),
        _legend(_kMedium, 'Steady', '${(f.levels.low * 100).round()}–${(f.levels.high * 100).round()}%'),
        _legend(_kLow, 'Low', '< ${(f.levels.low * 100).round()}%'),
      ]),
      const SizedBox(height: 8),
      Text(
        'Bars show the model\'s estimated chance each hour gets booked at your current '
        'price. Thresholds sit around the ${(f.levels.baseRate * 100).round()}% average '
        'booking rate this model was trained on.',
        style: GoogleFonts.poppins(fontSize: 9.5, color: AppColors.textSecondary, height: 1.4),
      ),
      if (f.modelVersion != null) ...[
        const SizedBox(height: 4),
        Text(
          'Model ${f.modelVersion}'
          '${f.modelMetrics?.brier != null ? ' · Brier ${f.modelMetrics!.brier!.toStringAsFixed(3)}' : ''}',
          style: GoogleFonts.poppins(
              fontSize: 9, color: AppColors.textSecondary.withValues(alpha: 0.85)),
        ),
      ],
    ];
  }

  /// 72 bars must fit a phone: at ~330 logical px of plot area a 72-bar series gets
  /// roughly 3px each, so the width is derived rather than fixed.
  double _barWidth(int count) {
    if (count <= 24) return 8;
    if (count <= 48) return 5;
    if (count <= 96) return 3;
    return 2;
  }

  /// `Today` / `Tomorrow` / `Thu` — relative to the first day in the series, not to
  /// the device clock. A phone in a different timezone (or a demo laptop set to UTC)
  /// would otherwise label a PKT forecast against its own idea of today.
  String _dayWord(String slotDate, List<String> days) {
    final idx = days.indexOf(slotDate);
    if (idx == 0) return 'Today';
    if (idx == 1) return 'Tomorrow';
    final parsed = DateTime.tryParse(slotDate);
    if (parsed == null) return slotDate;
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[(parsed.weekday - 1).clamp(0, 6)];
  }

  Widget _legend(Color c, String label, String range) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 5),
        Text(label,
            style: GoogleFonts.poppins(
                fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        const SizedBox(width: 3),
        Text(range, style: GoogleFonts.poppins(fontSize: 9.5, color: AppColors.textSecondary)),
      ]);
}

String _fmt(num v) {
  // Thousands separators without pulling `intl` into a widget file that does not
  // otherwise need it. Prices here are always < 10 million PKR.
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
