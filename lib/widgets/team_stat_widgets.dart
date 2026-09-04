/// Team stat visuals.
///
/// Everything the rankings screen and the team profile draw for ratings, form
/// and history lives here, for the same reason widgets/match_widgets.dart exists:
/// a rank arrow that is green on one screen and grey on the next reads as a bug,
/// and two copies of a "+18 ELO" pill drift apart the first time one is edited.
///
/// Pieces:
///   • [EloHistoryChart]  FR5.14 — last-10 line chart, solid green dot = verified,
///                        hollow red dot = disputed
///   • [MovementBadge]    FR5.13 — rank change vs 7 days ago, with new as its own
///                        state rather than a zero
///   • [FormRow]          the last-5 W/L/D pills
///   • [StatTile]         one labelled number, used across the profile header
///   • [MatchHistoryTile] FR5.16 — opponent, "Won 2–1", date, "+18 ELO"
///   • [RatingText]       the one widget allowed to print a rating, so "Unranked"
///                        can never be quietly replaced by the 1000 seed
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../constants/colors.dart';
import '../models/team_stats.dart';

/// FR5.14's palette, named once so the chart, the legend and the history rows
/// cannot disagree about what green means.
const Color kVerifiedDot = AppColors.success;
const Color kDisputedDot = AppColors.error;

// Rating text

/// Prints a rating or the word "Unranked" (FR2.6). Screens should use this
/// rather than reading `elo` directly — that is exactly how the leaderboard
/// ended up printing the 1000 seed for teams that had never played.
class RatingText extends StatelessWidget {
  final RatingDisplay source;
  final double size;
  final Color? color;
  final FontWeight weight;

  const RatingText(
    this.source, {
    super.key,
    this.size = 15,
    this.color,
    this.weight = FontWeight.bold,
  });

  @override
  Widget build(BuildContext context) {
    final unranked = !source.ranked || source.displayElo == null;
    return Text(
      source.eloLabel,
      style: GoogleFonts.poppins(
        // "Unranked" is a longer word doing a smaller job — shrink it so it does
        // not crowd a row sized for four digits.
        fontSize: unranked ? size * 0.68 : size,
        fontWeight: unranked ? FontWeight.w600 : weight,
        color: unranked ? AppColors.textSecondary : (color ?? AppColors.textPrimary),
      ),
    );
  }
}

// Movement badge

/// Rank change over the movement window. Four distinct states, because
/// collapsing "new to the board" into "no change" would claim a history the
/// team does not have.
class MovementBadge extends StatelessWidget {
  final int? movement;
  final bool compact;

  const MovementBadge(this.movement, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final m = movement;

    if (m == null) {
      return _pill('NEW', AppColors.warning, null);
    }
    if (m == 0) {
      // A dash, not "0" — a zero next to a number column reads as a score.
      return _pill('–', AppColors.textSecondary, null);
    }
    final up = m > 0;
    return _pill(
      '${m.abs()}',
      up ? AppColors.success : AppColors.error,
      up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
    );
  }

  Widget _pill(String text, Color color, IconData? icon) => Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, size: compact ? 13 : 15, color: color),
            // A three-digit jump on a 40px rank column would otherwise overflow.
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: GoogleFonts.poppins(
                  fontSize: compact ? 9 : 10,
                  fontWeight: FontWeight.w800,
                  color: color,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      );
}

// FORM row

/// The last-5 W/L/D pills, oldest on the left — the order every football table
/// uses, so it needs no legend.
class FormRow extends StatelessWidget {
  final String form;
  final double size;

  const FormRow(this.form, {super.key, this.size = 22});

  @override
  Widget build(BuildContext context) {
    final seq = form.split('').reversed.toList();
    if (seq.isEmpty) {
      return Text(
        'No matches yet',
        style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Indexed, not `c != seq.last` — that compares by value, so a run like
        // "WWWWW" would collapse to five pills with no gaps between them.
        for (var i = 0; i < seq.length; i++) ...[
          if (i > 0) SizedBox(width: size * 0.18),
          _pill(seq[i]),
        ],
      ],
    );
  }

  Widget _pill(String c) {
    final (color, label) = switch (c.toUpperCase()) {
      'W' => (AppColors.success, 'W'),
      'L' => (AppColors.error, 'L'),
      _ => (AppColors.textSecondary, 'D'),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Text(
        label,
        style: GoogleFonts.poppins(
          color: Colors.white,
          fontSize: size * 0.5,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

// Stat tile

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? valueWidget;

  const StatTile({
    super.key,
    required this.label,
    this.value = '',
    this.valueColor,
    this.valueWidget,
  });

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            valueWidget ??
                FittedBox(
                  child: Text(
                    value,
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: valueColor ?? AppColors.primary,
                    ),
                  ),
                ),
            const SizedBox(height: 3),
            Text(
              label,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
}

// ELO history chart  (FR5.14)

/// The team's rating over its last matches.
///
/// FR5.14's business rule is the dot styling, and it carries real meaning:
///
///   solid green   the result was verified by the venue owner and moved the rating
///   hollow red    the result was disputed — the match counted, the rating did not
///   hollow grey   verified but unrated, i.e. the rating is frozen (ER2.3)
///
/// The line is drawn through every point, including the unrated ones, because the
/// rating genuinely did not change across them — a gap would read as missing data
/// and a drop to zero would read as a collapse.
class EloHistoryChart extends StatelessWidget {
  final List<EloPoint> points;
  final double height;

  const EloHistoryChart(this.points, {super.key, this.height = 190});

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) return _tooShort();

    final values = points.map((p) => p.eloAt).toList();
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);

    // Pad the band so the line never touches the frame, and keep a minimum span
    // so a run of near-identical ratings does not render as a jagged mountain
    // range — a 2-point swing must not look like a 200-point one.
    final span = (hi - lo).clamp(20, 1 << 30);
    final pad = (span * 0.28).ceil();
    final minY = (lo - pad).toDouble();
    final maxY = (hi + pad).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (points.length - 1).toDouble(),
              minY: minY,
              maxY: maxY,
              clipData: const FlClipData.all(),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: ((maxY - minY) / 3).ceilToDouble(),
                getDrawingHorizontalLine: (_) =>
                    const FlLine(color: AppColors.border, strokeWidth: 1, dashArray: [4, 4]),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 38,
                    interval: ((maxY - minY) / 3).ceilToDouble(),
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        v.round().toString(),
                        textAlign: TextAlign.right,
                        style: GoogleFonts.poppins(
                            fontSize: 9.5, color: AppColors.textSecondary),
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    interval: 1,
                    getTitlesWidget: (v, _) {
                      final i = v.round();
                      if (i < 0 || i >= points.length) return const SizedBox.shrink();
                      // Only ever label the ends and the middle. Ten dates side
                      // by side overlap into noise on a phone.
                      final show = i == 0 || i == points.length - 1 || i == points.length ~/ 2;
                      if (!show) return const SizedBox.shrink();
                      final at = points[i].at;
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          at == null ? '' : DateFormat('d MMM').format(at),
                          style: GoogleFonts.poppins(
                              fontSize: 9.5, color: AppColors.textSecondary),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  // NOTE: the tooltip's corner radius is left at the package
                  // default on purpose. It is the one property fl_chart renamed
                  // between 0.69 (`tooltipRoundedRadius: double`) and 1.x
                  // (`tooltipBorderRadius: BorderRadius`), and skipping it keeps
                  // this file compiling on either line. Everything else used here
                  // is identical across both.
                  getTooltipColor: (_) => AppColors.primary,
                  getTooltipItems: (spots) => spots.map((s) {
                    final p = points[s.x.round().clamp(0, points.length - 1)];
                    final delta = p.deltaLabel;
                    return LineTooltipItem(
                      '${p.opponentName ?? 'Opponent'}\n'
                      '${p.headline}${delta == null ? '' : '  ·  $delta'}\n'
                      'Rating ${p.eloAt}${p.rated ? '' : ' (unchanged)'}',
                      GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < points.length; i++)
                      FlSpot(i.toDouble(), points[i].eloAt.toDouble()),
                  ],
                  isCurved: true,
                  curveSmoothness: 0.22,
                  preventCurveOverShooting: true,
                  color: AppColors.accent,
                  barWidth: 2.6,
                  isStrokeCapRound: true,
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.accent.withValues(alpha: 0.26),
                        AppColors.accent.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                  dotData: FlDotData(
                    show: true,
                    getDotPainter: (spot, _, _, index) {
                      final p = points[index.clamp(0, points.length - 1)];
                      if (p.disputed) {
                        // Hollow red — the match happened, the rating did not move.
                        return FlDotCirclePainter(
                          radius: 4.2,
                          color: Colors.white,
                          strokeWidth: 2.2,
                          strokeColor: kDisputedDot,
                        );
                      }
                      if (!p.rated) {
                        // Verified but frozen (ER2.3) — hollow, but grey, so it is
                        // never mistaken for a dispute.
                        return FlDotCirclePainter(
                          radius: 3.8,
                          color: Colors.white,
                          strokeWidth: 2,
                          strokeColor: AppColors.textSecondary,
                        );
                      }
                      return FlDotCirclePainter(
                        radius: 4.2,
                        color: kVerifiedDot,
                        strokeWidth: 1.6,
                        strokeColor: Colors.white,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _legend(),
      ],
    );
  }

  Widget _legend() {
    final hasDisputed = points.any((p) => p.disputed);
    final hasFrozen = points.any((p) => !p.rated && !p.disputed);
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        _key(kVerifiedDot, filled: true, label: 'Verified'),
        if (hasDisputed) _key(kDisputedDot, filled: false, label: 'Disputed'),
        if (hasFrozen) _key(AppColors.textSecondary, filled: false, label: 'Rating frozen'),
      ],
    );
  }

  Widget _key(Color color, {required bool filled, required String label}) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: filled ? color : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 1.8),
            ),
          ),
          const SizedBox(width: 5),
          Text(label,
              style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary)),
        ],
      );

  /// One point cannot make a line. Say what is missing rather than drawing an
  /// empty frame that looks broken.
  Widget _tooShort() => Container(
        height: height * 0.62,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.show_chart, size: 34, color: AppColors.disabled),
            const SizedBox(height: 10),
            Text(
              points.isEmpty
                  ? 'No rated matches yet — the chart appears once a result is verified.'
                  : 'One rated match so far. The chart needs two to draw a trend.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
            ),
          ],
        ),
      );
}

// MATCH history tile  (FR5.16)

/// One row of match history: opponent, "Won 2–1", the date, and the signed ELO
/// change. A disputed row says so instead of showing a delta, because no points
/// moved and "+0" would be a lie.
class MatchHistoryTile extends StatelessWidget {
  final EloPoint point;
  final VoidCallback? onTap;

  const MatchHistoryTile(this.point, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = point;
    final accent = switch (p.result) {
      'win' => AppColors.success,
      'loss' => AppColors.error,
      'disputed' => AppColors.warning,
      _ => AppColors.textSecondary,
    };
    final logo = p.opponentLogo;
    final delta = p.deltaLabel;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            // A 3px result stripe reads faster than any word — the same trick a
            // match list uses in every sports app.
            Container(
              width: 3,
              height: 34,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 11),
            CircleAvatar(
              radius: 17,
              backgroundColor: AppColors.inputFill,
              backgroundImage:
                  (logo != null && logo.isNotEmpty) ? CachedNetworkImageProvider(logo) : null,
              child: (logo == null || logo.isEmpty)
                  ? const Icon(Icons.shield_outlined, size: 16, color: AppColors.primary)
                  : null,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.opponentName ?? 'Opponent',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                        fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        p.headline,
                        style: GoogleFonts.poppins(
                            fontSize: 11.5, fontWeight: FontWeight.w700, color: accent),
                      ),
                      if (p.at != null) ...[
                        Text('  ·  ',
                            style: GoogleFonts.poppins(
                                fontSize: 11.5, color: AppColors.textSecondary)),
                        Text(
                          DateFormat('d MMM yyyy').format(p.at!),
                          style: GoogleFonts.poppins(
                              fontSize: 11.5, color: AppColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (delta != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (p.eloDelta! > 0 ? AppColors.success : AppColors.error)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '$delta ELO',
                  style: GoogleFonts.poppins(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: p.eloDelta! > 0 ? AppColors.success : AppColors.error,
                  ),
                ),
              )
            else
              Text(
                p.disputed ? 'No change' : 'Frozen',
                style: GoogleFonts.poppins(
                    fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
