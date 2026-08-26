import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../models/review.dart';

/// The visual vocabulary of reviews & Trust 2.0 (S.4 Wave D), in one place.
///
/// Sibling to `match_widgets.dart` and it follows the same discipline: one
/// definition per concept so a sentiment chip that reads "Positive" in green on the
/// rate screen can't read amber on the trust profile, and every widget handles the
/// *no-data* case as a first-class state. A brand-new user has no rating, no
/// attendance record and no sentiment — "not rated yet" is the common case on a
/// fresh install, never an afterthought. Nothing here paints a zero where the truth
/// is "unknown": an empty bar and a genuine 0% must never look alike.

// ═══════════════════════════════════════════════════════════════
//  Trust tone — the one place bands map to words + colour
// ═══════════════════════════════════════════════════════════════

/// How a 0–100 trust score reads to a human. Bands match the server's
/// `matchCore.trustBadge` vocabulary (excellent/good/fair/low) so the gauge, the
/// badge chip and the roster all agree, and the thresholds match the legacy
/// `trust_score_screen._label` so the M25 rewrite doesn't silently move the lines.
class TrustTone {
  final String label;
  final Color color;
  final String band; // aligns with TrustBadgeChip's excellent|good|fair|low
  const TrustTone(this.label, this.color, this.band);

  static TrustTone of(int? score) {
    if (score == null) return const TrustTone('Not rated yet', AppColors.textSecondary, 'unknown');
    if (score >= 90) return const TrustTone('Highly Trusted', AppColors.success, 'excellent');
    if (score >= 75) return const TrustTone('Trusted', AppColors.accent, 'good');
    if (score >= 60) return const TrustTone('Fair', AppColors.warning, 'fair');
    return const TrustTone('Needs Improvement', AppColors.error, 'low');
  }
}

// ═══════════════════════════════════════════════════════════════
//  TrustGauge — the M25 centrepiece (full ring)
// ═══════════════════════════════════════════════════════════════

/// A full-ring trust gauge: the score fills a complete circle, band label beneath
/// the number in the middle.
///
/// A full ring rather than the match screen's half-circle: this is a *standing*
/// reputation, not a one-off comparison, and a closed loop reads as a settled state
/// while a needle reads as a live measurement. Hand-painted for the same reason the
/// match gauge is — two arcs and a dot don't warrant a charting dependency — and it
/// deliberately reuses that gauge's sweep-in animation and gradient so the two feel
/// like one family.
class TrustGauge extends StatelessWidget {
  final int? score;
  final double size;

  const TrustGauge({super.key, required this.score, this.size = 190});

  @override
  Widget build(BuildContext context) {
    final tone = TrustTone.of(score);
    final target = score == null ? 0.0 : (score!.clamp(0, 100)) / 100;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 850),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _TrustRingPainter(fraction: value, color: tone.color),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The animating number, so a 50 and an 88 don't just differ in arc
                // length — they count up differently too.
                Text(
                  score == null ? '—' : '${(value * 100).round()}',
                  style: GoogleFonts.poppins(
                    fontSize: size * 0.26,
                    fontWeight: FontWeight.bold,
                    height: 1,
                    color: score == null ? AppColors.textSecondary : AppColors.textPrimary,
                  ),
                ),
                if (score != null)
                  Text(
                    'out of 100',
                    style: GoogleFonts.poppins(
                      fontSize: size * 0.055,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                SizedBox(height: size * 0.03),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: size * 0.06, vertical: size * 0.02),
                  decoration: BoxDecoration(
                    color: tone.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    tone.label.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: size * 0.058,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: tone.color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrustRingPainter extends CustomPainter {
  final double fraction;
  final Color color;

  _TrustRingPainter({required this.fraction, required this.color});

  // A full circle, starting at 12 o'clock and sweeping clockwise.
  static const double _start = -math.pi / 2;
  static const double _full = 2 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.085;
    final radius = (size.width - stroke) / 2;
    final centre = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: centre, radius: radius);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = AppColors.inputFill;
    canvas.drawArc(rect, _start, _full, false, track);

    if (fraction > 0) {
      final value = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: _full,
          colors: [color.withValues(alpha: 0.45), color],
          transform: const GradientRotation(_start),
        ).createShader(rect);
      canvas.drawArc(rect, _start, _full * fraction, false, value);

      // A bright dot at the arc's head, so the eye lands on the exact position.
      final angle = _start + _full * fraction;
      final tip = Offset(
        centre.dx + radius * math.cos(angle),
        centre.dy + radius * math.sin(angle),
      );
      canvas.drawCircle(tip, stroke * 0.40, Paint()..color = Colors.white);
      canvas.drawCircle(
        tip,
        stroke * 0.40,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_TrustRingPainter old) =>
      old.fraction != fraction || old.color != color;
}

// ═══════════════════════════════════════════════════════════════
//  TrustMetricTile — one of the four breakdown cards
// ═══════════════════════════════════════════════════════════════

/// One weighted component of the trust score (⭐ rating · 📅 attendance ·
/// ⚖️ dispute-free · 🤖 AI sentiment). Shows the value, a fill bar, and the points
/// this component contributes toward the 100.
///
/// [fraction] is the normalised 0..1 component or **null**. Null renders "No data
/// yet" with an empty track and no contribution — a user with no disputes on record
/// is not 0% dispute-free, they are simply unmeasured, and the tile says so.
class TrustMetricTile extends StatelessWidget {
  final String emoji;
  final String label;
  final double? fraction; // 0..1 or null
  final String? valueText; // headline value already formatted ("4.2 / 5", "92%")
  final int weight; // max points this component can contribute (35/30/20/15)

  const TrustMetricTile({
    super.key,
    required this.emoji,
    required this.label,
    required this.fraction,
    required this.valueText,
    required this.weight,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = fraction != null;
    final f = (fraction ?? 0).clamp(0.0, 1.0);
    final contribution = (f * weight).round();
    // Colour tracks how strong the component is, on the same 4-band scale as trust.
    final Color tone = !hasData
        ? AppColors.textSecondary
        : f >= 0.75
            ? AppColors.success
            : f >= 0.5
                ? AppColors.accent
                : f >= 0.3
                    ? AppColors.warning
                    : AppColors.error;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            hasData ? (valueText ?? '—') : 'No data yet',
            style: GoogleFonts.poppins(
              fontSize: hasData ? 20 : 13,
              fontWeight: hasData ? FontWeight.bold : FontWeight.w500,
              color: hasData ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Container(height: 5, color: AppColors.inputFill),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    height: 5,
                    width: c.maxWidth * f,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: tone,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hasData ? '+$contribution of $weight pts' : 'worth up to $weight pts',
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  SentimentChip — the live-demo moment
// ═══════════════════════════════════════════════════════════════

/// The trained model's verdict on a review, as a chip. This is the demo's payoff:
/// type a review, and this animates in reading "😊 Positive (92%)".
///
/// It has three honest states, and never dresses one as another:
///   • scored     → emoji + label + confidence %, coloured by polarity.
///   • flagged    → an amber "Flagged for review" — the model escalated it; that is
///                  the fact that matters, so it leads (the polarity is still there).
///   • unavailable→ a quiet "Sentiment added shortly" — the ml-service was down, the
///                  review saved anyway, the backfill job will score it later.
/// A stars-only review (no text) has nothing to say and renders nothing.
class SentimentChip extends StatelessWidget {
  final String? label; // 'positive' | 'neutral' | 'negative' | null
  final double? score; // signed magnitude; null when unscored
  final bool flagged;
  final String? source; // 'model' | 'unavailable' | null
  final bool compact;

  const SentimentChip({
    super.key,
    required this.label,
    this.score,
    this.flagged = false,
    this.source,
    this.compact = false,
  });

  /// Build straight from a POST /reviews response's sentiment object.
  factory SentimentChip.fromSentiment(ReviewSentiment s, {bool compact = false}) =>
      SentimentChip(
        label: s.label,
        score: s.score,
        flagged: s.flagged,
        source: s.source,
        compact: compact,
      );

  static ({String emoji, Color color, String word}) _face(String? label) {
    switch (label) {
      case 'positive':
        return (emoji: '😊', color: AppColors.success, word: 'Positive');
      case 'negative':
        return (emoji: '😞', color: AppColors.error, word: 'Negative');
      case 'neutral':
        return (emoji: '😐', color: AppColors.textSecondary, word: 'Neutral');
      default:
        return (emoji: '🤖', color: AppColors.textSecondary, word: 'Analysing');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Unavailable + nothing scored → the "added shortly" state.
    if (source == 'unavailable' && label == null) {
      return _pill(
        icon: Icons.schedule,
        color: AppColors.textSecondary,
        text: 'Sentiment added shortly',
        muted: true,
      );
    }

    // Flagged → lead with the escalation.
    if (flagged) {
      final pct = score == null ? null : (score!.abs() * 100).round();
      return _pill(
        icon: Icons.flag_rounded,
        color: AppColors.warning,
        text: pct == null ? 'Flagged for review' : 'Flagged for review · $pct%',
      );
    }

    if (label == null) return const SizedBox.shrink();

    final f = _face(label);
    final pct = score == null ? null : (score!.abs() * 100).round().clamp(0, 100);
    final text = pct == null ? f.word : '${f.word} ($pct%)';

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: f.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: f.color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(f.emoji, style: TextStyle(fontSize: compact ? 12 : 15)),
          const SizedBox(width: 5),
          Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: compact ? 10.5 : 12.5,
              fontWeight: FontWeight.w600,
              color: f.color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required IconData icon,
    required Color color,
    required String text,
    bool muted = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: muted ? 0.07 : 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: muted ? 0.18 : 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 14, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: compact ? 10.5 : 12.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Stars — input, display, histogram
// ═══════════════════════════════════════════════════════════════

/// A tappable 1–5 star input. [value] is 0 (nothing chosen yet) through 5; tapping a
/// star sets that many. Tapping the current highest star again clears to 0, so a
/// mis-tap is recoverable without a separate control.
class StarRatingInput extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final double size;

  const StarRatingInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final starValue = i + 1;
        final filled = starValue <= value;
        return Semantics(
          button: true,
          label: 'Rate $starValue ${starValue == 1 ? 'star' : 'stars'}',
          selected: filled,
          child: InkResponse(
            radius: size * 0.7,
            onTap: () => onChanged(value == starValue ? 0 : starValue),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Icon(
                filled ? Icons.star_rounded : Icons.star_outline_rounded,
                size: size,
                color: filled ? AppColors.warning : AppColors.disabled,
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Read-only stars for an average or a single rating. Renders halves, so 4.3 shows
/// four-and-a-bit rather than rounding to a number the reviews don't support.
class StarsDisplay extends StatelessWidget {
  final double rating;
  final double size;
  final bool showValue;

  const StarsDisplay({
    super.key,
    required this.rating,
    this.size = 16,
    this.showValue = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...List.generate(5, (i) {
          final starValue = i + 1;
          IconData icon;
          if (rating >= starValue - 0.25) {
            icon = Icons.star_rounded;
          } else if (rating >= starValue - 0.75) {
            icon = Icons.star_half_rounded;
          } else {
            icon = Icons.star_outline_rounded;
          }
          return Icon(icon, size: size, color: AppColors.warning);
        }),
        if (showValue) ...[
          SizedBox(width: size * 0.35),
          Text(
            rating.toStringAsFixed(1),
            style: GoogleFonts.poppins(
              fontSize: size * 0.85,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ],
    );
  }
}

/// The 5→1 ratings histogram. [counts] is high→low: `counts[0]` = number of 5★,
/// `counts[4]` = number of 1★ (exactly [VenueReviews.starCounts]). Bars scale to the
/// tallest so the shape is readable even when one rating dominates; the absolute
/// count sits at the end of each row.
class StarsHistogram extends StatelessWidget {
  final List<int> counts; // length 5, [5★,4★,3★,2★,1★]

  const StarsHistogram({super.key, required this.counts});

  @override
  Widget build(BuildContext context) {
    final safe = counts.length == 5 ? counts : const [0, 0, 0, 0, 0];
    final maxCount = safe.fold<int>(1, (m, c) => c > m ? c : m);

    return Column(
      children: List.generate(5, (i) {
        final star = 5 - i; // row 0 → 5★
        final count = safe[i];
        final fraction = count / maxCount;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Row(
                  children: [
                    Text(
                      '$star',
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const Icon(Icons.star_rounded, size: 11, color: AppColors.warning),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LayoutBuilder(
                    builder: (context, c) => Stack(
                      children: [
                        Container(height: 8, color: AppColors.inputFill),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                          height: 8,
                          width: c.maxWidth * fraction,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: AppColors.warning,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 30,
                child: Text(
                  '$count',
                  textAlign: TextAlign.end,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// A horizontal positive/neutral/negative bar — the venue's sentiment summary at a
/// glance. Segments size to their share; a venue with no scored reviews shows a
/// single "No sentiment yet" track rather than a misleading empty split.
class SentimentSummaryBar extends StatelessWidget {
  final SentimentDistribution distribution;

  const SentimentSummaryBar({super.key, required this.distribution});

  @override
  Widget build(BuildContext context) {
    final d = distribution;
    if (d.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 10,
          color: AppColors.inputFill,
          alignment: Alignment.center,
        ),
      );
    }

    Widget seg(int flex, Color color) => flex == 0
        ? const SizedBox.shrink()
        : Expanded(flex: flex, child: Container(height: 10, color: color));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Row(
            children: [
              seg(d.positive, AppColors.success),
              seg(d.neutral, AppColors.textSecondary),
              seg(d.negative, AppColors.error),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            _legend(AppColors.success, 'Positive', d.positive),
            _legend(AppColors.textSecondary, 'Neutral', d.neutral),
            _legend(AppColors.error, 'Negative', d.negative),
          ],
        ),
      ],
    );
  }

  Widget _legend(Color color, String label, int n) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(
            '$label $n',
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      );
}

// ═══════════════════════════════════════════════════════════════
//  ReviewCard — one review, everywhere it's listed
// ═══════════════════════════════════════════════════════════════

/// One review row: who, when, how many stars, the text, and the model's sentiment.
/// [onFlag] adds a report affordance (omitted where the viewer can't flag, e.g. a
/// venue's own owner reading their reviews read-only). [showType] surfaces the
/// venue/opponent tag on a mixed feed like a user's received reviews.
class ReviewCard extends StatelessWidget {
  final Review review;
  final VoidCallback? onFlag;
  final bool showType;

  const ReviewCard({
    super.key,
    required this.review,
    this.onFlag,
    this.showType = false,
  });

  @override
  Widget build(BuildContext context) {
    final name = review.reviewerName ?? 'A player';
    final initial = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?';

    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.accentLight,
                child: Text(
                  initial,
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (showType && review.reviewType != null) ...[
                          const SizedBox(width: 6),
                          _typeTag(review.isOpponent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        StarsDisplay(rating: review.stars.toDouble(), size: 14),
                        const SizedBox(width: 6),
                        Text(
                          review.relativeTime,
                          style: GoogleFonts.poppins(
                            fontSize: 10.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onFlag != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.outlined_flag, size: 18, color: AppColors.textSecondary),
                  tooltip: 'Report this review',
                  onPressed: onFlag,
                ),
            ],
          ),
          if (review.text != null) ...[
            const SizedBox(height: 10),
            Text(
              review.text!,
              style: GoogleFonts.poppins(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textPrimary,
              ),
            ),
          ],
          if (review.sentimentLabel != null) ...[
            const SizedBox(height: 10),
            SentimentChip(label: review.sentimentLabel, compact: true),
          ],
        ],
      ),
    );
  }

  Widget _typeTag(bool opponent) {
    final color = opponent ? AppColors.primary : AppColors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        opponent ? 'Opponent' : 'Venue',
        style: GoogleFonts.poppins(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: color,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  TeamReputationStrip — the read-only team view
// ═══════════════════════════════════════════════════════════════

/// A compact team standing: ELO, W-L-D, and the captain's trust band. Read-only —
/// the team view onto reputation that stays skill=team, conduct=captain. Every field
/// is optional so it degrades to "Unranked" / "No record yet" for a new team rather
/// than printing a starting ELO it hasn't earned.
class TeamReputationStrip extends StatelessWidget {
  final String? teamName;
  final int? elo;
  final int wins;
  final int losses;
  final int draws;
  final String? captainTrustBand; // excellent|good|fair|low
  final int? captainTrustScore;

  const TeamReputationStrip({
    super.key,
    this.teamName,
    this.elo,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.captainTrustBand,
    this.captainTrustScore,
  });

  @override
  Widget build(BuildContext context) {
    final played = wins + losses + draws;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.groups_rounded, size: 15, color: Colors.white70),
              const SizedBox(width: 6),
              Text(
                teamName == null ? 'TEAM REPUTATION' : teamName!.toUpperCase(),
                style: GoogleFonts.poppins(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _stat(elo == null ? 'Unranked' : '${elo!}', 'ELO'),
              _divider(),
              _stat(played == 0 ? '—' : '$wins-$losses-$draws', 'W-L-D'),
              _divider(),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (captainTrustBand != null && captainTrustBand != 'unknown')
                      _bandChip(captainTrustBand!, captainTrustScore)
                    else
                      Text(
                        'No rating',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    const SizedBox(height: 3),
                    Text(
                      'CAPTAIN TRUST',
                      style: GoogleFonts.poppins(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(
              value,
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: Colors.white54,
              ),
            ),
          ],
        ),
      );

  Widget _divider() => Container(
        width: 1,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Colors.white24,
      );

  Widget _bandChip(String band, int? score) {
    const styles = <String, (Color, IconData, String)>{
      'excellent': (AppColors.success, Icons.verified, 'Highly Trusted'),
      'good': (AppColors.accent, Icons.thumb_up_alt_outlined, 'Trusted'),
      'fair': (AppColors.warning, Icons.remove_circle_outline, 'Fair'),
      'low': (AppColors.error, Icons.warning_amber_rounded, 'Needs Work'),
    };
    final s = styles[band] ?? (AppColors.textSecondary, Icons.help_outline, 'Unknown');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: s.$1.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.$2, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            score == null ? s.$3 : '${s.$3} · $score',
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
