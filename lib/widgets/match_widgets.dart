import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../models/match.dart';

/// The visual vocabulary of the match flow, in one place.
///
/// Five screens draw these — Find Opponents, the challenge sheet, the Match
/// Center's three tabs, and the owner's verify screen. Keeping them here is not
/// just deduplication: a competitiveness bar that reads "well matched" in green on
/// one screen and amber on the next would quietly destroy the user's trust in the
/// number. One definition means one meaning.
///
/// Every widget here handles the *unranked* case explicitly. FR2.6 says a team has
/// no rating until it has played a verified match, so "no score yet" is a normal
/// state that appears constantly on a new install — not an edge case to bolt on
/// afterwards.

//  Competitiveness (FR5.4)

/// How a competitiveness score reads to a human. 5..100 from the server, where
/// 100 is two teams with identical ratings.
class CompetitivenessTone {
  final String label;
  final Color color;
  const CompetitivenessTone(this.label, this.color);

  /// The bands are wide on purpose. The score is a rating-gap transform, not a
  /// measurement, so implying precision with ten narrow bands would overstate
  /// what it knows. Four bands is as much as the number can honestly support.
  static CompetitivenessTone of(int? score) {
    if (score == null) return const CompetitivenessTone('Unranked', AppColors.textSecondary);
    if (score >= 80) return const CompetitivenessTone('Evenly matched', AppColors.success);
    if (score >= 55) return const CompetitivenessTone('Competitive', AppColors.accent);
    if (score >= 30) return const CompetitivenessTone('Uphill', AppColors.warning);
    return const CompetitivenessTone('Mismatch', AppColors.error);
  }
}

/// A horizontal competitiveness bar with its label — the list-row form (FR5.4).
///
/// When [score] is null the track is drawn empty with an explanation rather than
/// a 0% fill. A 5% bar and "no data" look identical at a glance, and one of them
/// is a lie about a team that simply has not played yet.
class CompetitivenessBar extends StatelessWidget {
  final int? score;
  final bool compact;

  /// Shown in place of the tone label when there is no score. Defaults to a
  /// sentence that says *why*, because "Unranked" alone reads like a fault.
  final String? unrankedNote;

  const CompetitivenessBar({
    super.key,
    required this.score,
    this.compact = false,
    this.unrankedNote,
  });

  @override
  Widget build(BuildContext context) {
    final tone = CompetitivenessTone.of(score);
    final fraction = score == null ? 0.0 : (score!.clamp(5, 100)) / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              score == null ? Icons.help_outline : Icons.balance,
              size: compact ? 12 : 14,
              color: tone.color,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                score == null
                    ? (unrankedNote ?? 'Not comparable yet — no verified matches')
                    : tone.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                  fontSize: compact ? 10.5 : 11.5,
                  fontWeight: FontWeight.w600,
                  color: tone.color,
                ),
              ),
            ),
            if (score != null)
              Text(
                '$score%',
                style: GoogleFonts.poppins(
                  fontSize: compact ? 10.5 : 11.5,
                  fontWeight: FontWeight.bold,
                  color: tone.color,
                ),
              ),
          ],
        ),
        SizedBox(height: compact ? 4 : 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LayoutBuilder(
            builder: (context, c) => Stack(
              children: [
                Container(height: compact ? 5 : 6, color: AppColors.inputFill),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  height: compact ? 5 : 6,
                  width: c.maxWidth * fraction,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: LinearGradient(
                      colors: [tone.color.withValues(alpha: 0.65), tone.color],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The semi-circular competitiveness gauge on the challenge screen (FR5.4).
///
/// A gauge rather than a second bar because this is the one number the captain is
/// being asked to weigh before committing, and it deserves to be the largest
/// thing on the screen. Hand-painted rather than a package: it is two arcs and a
/// needle, and a dependency for that would be a dependency to keep updated.
class CompetitivenessGauge extends StatelessWidget {
  final int? score;
  final double size;

  const CompetitivenessGauge({super.key, required this.score, this.size = 190});

  @override
  Widget build(BuildContext context) {
    final tone = CompetitivenessTone.of(score);
    final target = score == null ? 0.0 : (score!.clamp(5, 100)) / 100;

    // Sweeps in from zero on first paint and re-sweeps when the opponent changes,
    // which is the whole reason the gauge earns its space over a second bar: the
    // motion is what makes a 40 feel different from an 85.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 750),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        width: size,
        // A half-circle plus room for the readout under it.
        height: size * 0.62,
        child: CustomPaint(
          painter: _GaugePainter(fraction: value, color: tone.color),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  score == null ? '—' : '$score',
                  style: GoogleFonts.poppins(
                    fontSize: size * 0.20,
                    fontWeight: FontWeight.bold,
                    color: score == null ? AppColors.textSecondary : AppColors.textPrimary,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tone.label.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: size * 0.055,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: tone.color,
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

class _GaugePainter extends CustomPainter {
  final double fraction;
  final Color color;

  _GaugePainter({required this.fraction, required this.color});

  // A true half-circle, opening upward: π to 2π.
  static const double _start = math.pi;
  static const double _sweep = math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final radius = (size.width - stroke) / 2;
    final centre = Offset(size.width / 2, size.height - stroke / 2 - 2);
    final rect = Rect.fromCircle(center: centre, radius: radius);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = AppColors.inputFill;
    canvas.drawArc(rect, _start, _sweep, false, track);

    if (fraction > 0) {
      final value = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: _start,
          endAngle: _start + _sweep,
          colors: [color.withValues(alpha: 0.45), color],
          transform: GradientRotation(_start),
        ).createShader(rect);
      canvas.drawArc(rect, _start, _sweep * fraction, false, value);

      // The needle tip, so the eye can read the exact position on the arc rather
      // than estimating where a gradient ends.
      final angle = _start + _sweep * fraction;
      final tip = Offset(
        centre.dx + radius * math.cos(angle),
        centre.dy + radius * math.sin(angle),
      );
      canvas.drawCircle(tip, stroke * 0.42, Paint()..color = Colors.white);
      canvas.drawCircle(
        tip,
        stroke * 0.42,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.color != color;
}

//  Trust (FR5.5)

/// The roster's trust badge. Bands come from the server (`matchCore.trustBadge`)
/// so this only chooses the colour and icon for a band it is told.
class TrustBadgeChip extends StatelessWidget {
  final String? band;
  final String? label;
  final int? score;
  final bool showScore;

  const TrustBadgeChip({
    super.key,
    required this.band,
    this.label,
    this.score,
    this.showScore = false,
  });

  static const _styles = <String, (Color, IconData)>{
    'excellent': (AppColors.success, Icons.verified),
    'good': (AppColors.accent, Icons.thumb_up_alt_outlined),
    'fair': (AppColors.warning, Icons.remove_circle_outline),
    'low': (AppColors.error, Icons.warning_amber_rounded),
  };

  @override
  Widget build(BuildContext context) {
    if (band == null) return const SizedBox.shrink();
    final style = _styles[band] ?? (AppColors.textSecondary, Icons.help_outline);
    final color = style.$1;
    final text = showScore && score != null
        ? '${label ?? band} · $score'
        : (label ?? band ?? '');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.$2, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

//  Ratings

/// A team's rating, or "Unranked" (FR2.6). Never prints 1000 for a team that has
/// not played — that would imply a record it does not have.
class EloPill extends StatelessWidget {
  final MatchSide side;
  final bool dark;

  const EloPill({super.key, required this.side, this.dark = true});

  @override
  Widget build(BuildContext context) {
    final unranked = !side.ranked;
    final bg = unranked
        ? AppColors.inputFill
        : (dark ? AppColors.primary : AppColors.accentLight);
    final fg = unranked
        ? AppColors.textSecondary
        : (dark ? Colors.white : AppColors.primary);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (side.eloFrozen) ...[
            Icon(Icons.ac_unit, size: 11, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            unranked ? 'Unranked' : 'ELO ${side.elo}',
            style: GoogleFonts.poppins(
              color: fg,
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// The ±points a match moved a rating (FR5.16). Zero is shown as "no change"
/// rather than "+0", because zero here means the rating was frozen, not that the
/// match was a wash.
class EloDeltaChip extends StatelessWidget {
  final int? delta;
  final bool frozen;

  const EloDeltaChip({super.key, required this.delta, this.frozen = false});

  @override
  Widget build(BuildContext context) {
    final d = delta;
    if (d == null) return const SizedBox.shrink();

    final noChange = d == 0;
    final color = noChange
        ? AppColors.textSecondary
        : (d > 0 ? AppColors.success : AppColors.error);
    final text = noChange ? (frozen ? 'Frozen' : 'No change') : (d > 0 ? '+$d' : '$d');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            noChange
                ? (frozen ? Icons.ac_unit : Icons.remove)
                : (d > 0 ? Icons.arrow_upward : Icons.arrow_downward),
            size: 11,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

//  Status

/// The match's state, in the words a captain would use for it.
class MatchStatusChip extends StatelessWidget {
  final String status;
  const MatchStatusChip({super.key, required this.status});

  /// Deliberately not the raw enum. "awaiting_owner" is a database state;
  /// "Owner verifying" is what is happening to the user's match.
  static (String, Color, IconData) describe(String status) => switch (status) {
        MatchStatus.challengeSent => ('Awaiting reply', AppColors.warning, Icons.schedule),
        MatchStatus.accepted => ('Confirmed', AppColors.accent, Icons.event_available),
        MatchStatus.awaitingResults => ('Result due', AppColors.warning, Icons.edit_note),
        MatchStatus.awaitingOwner => ('Owner verifying', AppColors.primary, Icons.verified_user),
        MatchStatus.completed => ('Completed', AppColors.success, Icons.check_circle),
        MatchStatus.rejected => ('Declined', AppColors.textSecondary, Icons.block),
        MatchStatus.expired => ('Expired', AppColors.textSecondary, Icons.timer_off),
        MatchStatus.disputed => ('Disputed', AppColors.error, Icons.gavel),
        _ => (status, AppColors.textSecondary, Icons.info_outline),
      };

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = describe(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// A live countdown to a challenge's 48h deadline (FR5.12).
///
/// It ticks, rather than rendering once, because a challenge with "3 minutes left"
/// on screen is exactly when a captain is deciding — and a frozen number that has
/// silently become "expired" is how they end up tapping Accept and getting a 409.
/// The tick rate follows the remaining time: seconds matter in the last minute,
/// and nothing below a minute matters two days out.
class ChallengeCountdown extends StatefulWidget {
  final DateTime? expiresAt;
  final bool compact;

  const ChallengeCountdown({super.key, required this.expiresAt, this.compact = false});

  @override
  State<ChallengeCountdown> createState() => _ChallengeCountdownState();
}

class _ChallengeCountdownState extends State<ChallengeCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ChallengeCountdown old) {
    super.didUpdateWidget(old);
    if (old.expiresAt != widget.expiresAt) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    final left = _left;
    if (left == null || left.isNegative) return;
    // Under an hour, tick every second so the number is never stale enough to
    // mislead; above it, once a minute is plenty and costs nothing.
    final period = left.inHours < 1 ? const Duration(seconds: 1) : const Duration(minutes: 1);
    _timer = Timer.periodic(period, (_) {
      if (!mounted) return;
      setState(() {});
      final now = _left;
      // Crossing the hour boundary needs the faster timer.
      if (now != null && now.inHours < 1 && period.inSeconds != 1) _schedule();
      if (now == null || now.isNegative) _timer?.cancel();
    });
  }

  Duration? get _left => widget.expiresAt?.difference(DateTime.now());

  static String format(Duration d) {
    if (d.isNegative) return 'Expired';
    if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h left';
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m left';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s left';
    return '${d.inSeconds}s left';
  }

  @override
  Widget build(BuildContext context) {
    final left = _left;
    if (left == null) return const SizedBox.shrink();

    final expired = left.isNegative;
    // Under six hours is when "I'll deal with it later" stops being safe.
    final urgent = !expired && left.inHours < 6;
    final color = expired
        ? AppColors.textSecondary
        : (urgent ? AppColors.error : AppColors.warning);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(expired ? Icons.timer_off : Icons.timer_outlined, size: widget.compact ? 11 : 13, color: color),
        const SizedBox(width: 4),
        Text(
          format(left),
          style: GoogleFonts.poppins(
            fontSize: widget.compact ? 10.5 : 12,
            fontWeight: urgent ? FontWeight.bold : FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

//  Bits and pieces

/// A team crest, falling back to a shield. Used at four sizes across the flow, so
/// the fallback lives here instead of being re-typed with a different icon.
class TeamCrest extends StatelessWidget {
  final String? logoUrl;
  final double radius;
  final Color? background;

  const TeamCrest({super.key, this.logoUrl, this.radius = 24, this.background});

  @override
  Widget build(BuildContext context) {
    final has = logoUrl != null && logoUrl!.isNotEmpty;
    return CircleAvatar(
      radius: radius,
      backgroundColor: background ?? AppColors.inputFill,
      backgroundImage: has ? CachedNetworkImageProvider(logoUrl!) : null,
      child: has
          ? null
          : Icon(Icons.shield_outlined, size: radius * 0.9, color: AppColors.primary),
    );
  }
}

/// The "Preview" block (FR5.10).
///
/// The label is passed in from the server payload and rendered literally. This is
/// template NLG over real numbers — a rating gap, last-five form, win rates — and
/// calling it a prediction would claim an accuracy it does not have. The label is
/// the honesty, so it is not optional and not paraphrased.
class MatchPreviewBlock extends StatelessWidget {
  final String label;
  final String text;

  const MatchPreviewBlock({super.key, required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.accentLight.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 13, color: AppColors.primary),
              const SizedBox(width: 5),
              Text(
                label.toUpperCase(),
                style: GoogleFonts.poppins(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              height: 1.45,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// An empty / error state that fills a scroll view, so pull-to-refresh still works
/// when there is nothing to pull.
class MatchEmptyState extends StatelessWidget {
  final String text;
  final IconData icon;
  final Widget? action;

  const MatchEmptyState({
    super.key,
    required this.text,
    required this.icon,
    this.action,
  });

  @override
  Widget build(BuildContext context) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: MediaQuery.sizeOf(context).height * .14),
        children: [
          Icon(icon, size: 60, color: AppColors.disabled),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 14,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 20),
            Center(child: action!),
          ],
        ],
      );
}
