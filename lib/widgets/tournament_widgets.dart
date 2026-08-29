import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../models/assistant.dart' show formatPkr;
import '../models/tournament.dart';
import 'match_widgets.dart' show TeamCrest;

/// The visual vocabulary of the tournament module, in one place (S.7 Wave A).
///
/// Six screens draw these — the player's browse list, the tournament detail's four
/// tabs, the owner's create screen with its live economics preview, and the owner's
/// management list. Keeping them here is not just deduplication: a capacity bar that
/// counts accepted teams on one screen and holding teams on another would tell two
/// different stories about whether a captain can still enter, and a prize breakdown
/// that rounds differently from the ledger would make the app look like it is lying
/// about money. One definition means one meaning.
///
/// Two rules every widget here follows:
///
/// 1. **Nothing is recomputed.** Capacity, eligibility, the Elo win probability and
///    every rupee of the waterfall arrive decided by the server. These widgets lay
///    out numbers; they do not derive them.
/// 2. **A missing thing is drawn as a missing thing.** A bracket slot with no team is
///    a TBD placeholder, not a skipped row — the shape of the draw IS the
///    information, and a collapsed bracket would hide who plays whom next.
///
/// Money is formatted through the app's ONE [formatPkr], so `PKR 2,400` never
/// appears as `Rs 2400.00` two screens later.

// ═══════════════════════════════════════════════════════════════
//  Pills
// ═══════════════════════════════════════════════════════════════

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final double fontSize;

  const _Pill(this.text, this.color, {this.icon, this.fontSize = 10});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: fontSize + 2, color: color),
              const SizedBox(width: 4),
            ],
            Text(
              text,
              style: GoogleFonts.poppins(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      );
}

/// The tournament's state, in the colour that state deserves. Cancelled is red and
/// finished is grey on purpose — a captain scanning a list needs to know which cups
/// are still worth reading before they read any of them.
class TournamentStatusPill extends StatelessWidget {
  final Tournament tournament;
  const TournamentStatusPill(this.tournament, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    if (t.isCancelled) {
      return _Pill('Cancelled', AppColors.error, icon: Icons.block);
    }
    if (t.isCompleted) {
      return _Pill('Finished', AppColors.textSecondary, icon: Icons.emoji_events);
    }
    if (t.isActive) {
      return _Pill('In progress', AppColors.accent, icon: Icons.sports);
    }
    if (t.isFull) return _Pill('Full', AppColors.warning, icon: Icons.group);
    if (!t.registrationOpen) {
      return _Pill('Registration closed', AppColors.textSecondary, icon: Icons.lock_clock);
    }
    return _Pill('Open', AppColors.success, icon: Icons.how_to_reg);
  }
}

/// An entry's state. `Awaiting approval` is deliberately not softened to `Entered`:
/// the fee is held and the organiser has not said yes yet, and implying otherwise
/// would be the app lying about money.
class EntryStatusPill extends StatelessWidget {
  final String status;
  const EntryStatusPill(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      EntryStatus.accepted => AppColors.success,
      EntryStatus.registered => AppColors.warning,
      EntryStatus.eliminated => AppColors.textSecondary,
      EntryStatus.rejected || EntryStatus.withdrawn => AppColors.error,
      _ => AppColors.textSecondary,
    };
    return _Pill(EntryStatus.label(status), color);
  }
}

// ═══════════════════════════════════════════════════════════════
//  Capacity and countdown — the two facts that decide "can I still enter?"
// ═══════════════════════════════════════════════════════════════

/// How full the draw is. The denominator is `maxTeams` and the numerator is every
/// entry that HOLDS a spot — approved or awaiting approval — because a captain
/// deciding whether to register cares about the spot, not about the paperwork. That
/// is the same count the server refuses on, so the bar filling up and the Register
/// button refusing happen at the same moment instead of one lagging the other.
class CapacityBar extends StatelessWidget {
  final Tournament tournament;
  final bool showLabel;
  const CapacityBar(this.tournament, {super.key, this.showLabel = true});

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final fraction = t.capacityFraction;
    final color = t.isFull
        ? AppColors.warning
        : fraction >= 0.75
            ? AppColors.accent
            : AppColors.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              children: [
                Icon(Icons.groups_outlined, size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 4),
                Text(
                  t.capacityLabel,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  t.spotsLabel,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 6,
            backgroundColor: AppColors.divider,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

/// "Closes in 2d 4h". Turns amber under 24 hours and red once shut.
///
/// The text comes from [Tournament.countdown], which prefers the server's
/// `secondsToDeadline` over the phone's clock — a device an hour fast must not tell
/// a captain registration closed while the server is still accepting entries.
class CountdownChip extends StatelessWidget {
  final Tournament tournament;
  const CountdownChip(this.tournament, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final left = t.timeLeft;
    final closed = left == null || left.inSeconds <= 0;
    final urgent = !closed && left.inHours < 24;
    final color = closed
        ? AppColors.textSecondary
        : urgent
            ? AppColors.warning
            : AppColors.textSecondary;
    return _Pill(
      t.countdown,
      color,
      icon: closed ? Icons.lock_outline : Icons.schedule,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  The browse row (SRS FE-2)
// ═══════════════════════════════════════════════════════════════

/// One tournament in a list.
///
/// Four facts decide whether a captain taps this, so all four are on the card and
/// none of them is behind a tap: what it costs to enter, what is on the table if you
/// win, how many spots are left, and how long you have to decide. The prize is the
/// server's [Tournament.prize] once the pool is settled and a projection
/// before that — never a marketing number, which is exactly what the mock this
/// replaces used to show.
class TournamentCard extends StatelessWidget {
  final Tournament tournament;
  final VoidCallback? onTap;

  /// Set when the viewer's own team is in this draw — the card then says so instead
  /// of inviting them to enter a second time.
  final MyEntry? myEntry;

  const TournamentCard(this.tournament, {super.key, this.onTap, this.myEntry});

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final entry = myEntry;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        t.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TournamentStatusPill(t),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.place_outlined, size: 13, color: AppColors.textSecondary),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        t.venue.where,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _Pill(t.sport.toUpperCase(), AppColors.primary),
                    const SizedBox(width: 6),
                    _Pill(t.formatLabel, AppColors.accent),
                    const Spacer(),
                    CountdownChip(t),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _MoneyFact(
                      label: 'Entry',
                      value: formatPkr(t.entryFee),
                      icon: Icons.confirmation_number_outlined,
                    ),
                    Container(width: 1, height: 30, color: AppColors.divider),
                    _MoneyFact(
                      label: t.hasPrize ? 'Prize pool' : 'Prize',
                      value: t.hasPrize ? formatPkr(t.prize) : 'Set at draw',
                      icon: Icons.emoji_events_outlined,
                      color: t.hasPrize ? AppColors.success : AppColors.textSecondary,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                CapacityBar(t),
                if (entry != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 14, color: AppColors.success),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '${entry.teamName} — ${EntryStatus.label(entry.status)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.success,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled rupee figure. Two of these side by side answer "what does it cost me
/// and what do I get", which is the only question a browse card has to answer.
class _MoneyFact extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  const _MoneyFact({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 12, color: AppColors.textSecondary),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: GoogleFonts.poppins(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: color ?? AppColors.textPrimary,
              ),
            ),
          ],
        ),
      );
}

// ===============================================================
//  The money waterfall (SRS FE-1, FE-8)
// ===============================================================

/// One line of the waterfall: a label, an optional sub-label, and a rupee figure.
class _MoneyLine extends StatelessWidget {
  final String label;
  final String? note;
  final double amount;
  final bool negative;
  final bool strong;
  final Color? color;
  final IconData? icon;

  const _MoneyLine(
    this.label,
    this.amount, {
    this.note,
    this.negative = false,
    this.strong = false,
    this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final tint = color ?? (negative ? AppColors.error : AppColors.textPrimary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: strong ? 13 : 12.5,
                    fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                    color: strong ? AppColors.textPrimary : AppColors.textSecondary,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            (negative ? '− ' : '') + formatPkr(amount),
            style: GoogleFonts.poppins(
              fontSize: strong ? 14 : 13,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }
}

/// Where every rupee of the entry fees goes (SRS FE-1, FE-8).
///
/// This is the waterfall spelled out in the order the server applies it: the pool
/// comes in, the venue's real slot prices come out FIRST, and only the surplus is
/// split into a prize and the organiser's margin. Showing it as a percentage pie
/// would be a different, and wrong, story: the venue cost is fixed while the pool is
/// variable, so a flat "30% commission" on a thin turnout would pay an owner less
/// than the hours were worth, and the reason a venue runs a tournament at all would
/// evaporate.
///
/// Every figure is the server's. [Economics] carries two shapes, a projection before
/// the draw and the settled figures after it, and the header says which one the
/// reader is looking at, because "you will earn" and "you earned" are not the same
/// promise.
class PrizeBreakdownCard extends StatelessWidget {
  final Economics economics;

  /// Shown on the owner's screens and hidden from captains: the organiser's own take.
  final bool showOwnerView;

  const PrizeBreakdownCard(this.economics, {super.key, this.showOwnerView = false});

  @override
  Widget build(BuildContext context) {
    final e = economics;
    final teams = e.settled ? e.teams : (e.projectedFor ?? e.teams);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                e.settled ? 'Prize money' : 'Projected breakdown',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (!e.settled) _Pill('Projection', AppColors.accent),
            ],
          ),
          const SizedBox(height: 8),
          _MoneyLine(
            'Entry fees collected',
            e.pool,
            note: '$teams ${teams == 1 ? 'team' : 'teams'} x ${formatPkr(e.entryFee)}',
            strong: true,
          ),
          const Divider(height: 14),
          _MoneyLine('Venue hours', e.venueCost, note: _venueNote(e), negative: true),
          if ((e.venueDiscount ?? 0) > 0)
            _MoneyLine(
              'Owner discount',
              e.venueDiscount!,
              note: '${e.venueDiscountPercent}% off the listed slot price',
              color: AppColors.success,
            ),
          const Divider(height: 14),
          _MoneyLine(
            'Prize pool',
            e.prize,
            note: '${e.prizePercent}% of what is left after the venue',
            strong: true,
            color: AppColors.success,
            icon: Icons.emoji_events_outlined,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Column(
              children: [
                _MoneyLine('Champion', e.winnerShare,
                    note: '${e.winnerPercent}% of the prize'),
                _MoneyLine('Runner-up', e.runnerupShare,
                    note: '${e.runnerupPercent}% of the prize'),
              ],
            ),
          ),
          if (showOwnerView) ...[
            const Divider(height: 14),
            _MoneyLine(
              'You keep',
              e.ownerEarning,
              note: 'venue hours recovered in full, plus '
                  '${formatPkr(e.margin)} organiser margin',
              strong: true,
              color: AppColors.primary,
              icon: Icons.storefront_outlined,
            ),
          ],
          if (e.isUnderwater) ...[
            const SizedBox(height: 8),
            TournamentWarning(
              e.pool <= 0
                  ? 'No entry fees have been collected yet, so there is nothing to '
                      'split.'
                  : 'The entry fees do not cover the venue hours these fixtures need, '
                      'so there is no prize money and the organiser is not asked to '
                      'top it up. Raise the entry fee or run fewer teams.',
            ),
          ],
        ],
      ),
    );
  }

  static String _venueNote(Economics e) {
    final hours = e.hours;
    final list = e.listPrice;
    final unit = hours == 1 ? 'hour' : 'hours';
    if (hours != null && hours > 0 && list != null && list > 0) {
      return '$hours $unit of real slots (about ${formatPkr(list)}/hr)';
    }
    if (hours != null && hours > 0) return '$hours $unit of real slots';
    return 'the actual price of the slots the fixtures take';
  }
}

/// An amber caution strip. Used for the underwater guard, for a create screen that
/// cannot proceed, and for the "no open hours at this venue" case, all of which are
/// the app saying "this will not work" without looking like a crash.
class TournamentWarning extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? color;

  const TournamentWarning(
    this.text, {
    super.key,
    this.icon = Icons.warning_amber_rounded,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final tint = color ?? AppColors.warning;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: tint),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                height: 1.4,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The owner's argument for running a tournament instead of selling the hours.
///
/// The comparison is the entire commercial case of this module, so it is stated in
/// rupees the owner can check rather than as a percentage they have to trust: what
/// the same slots would fetch at their own list price, against what the tournament
/// pays them. The server computes both from real `slots.price` rows; this widget
/// only lays them out.
///
/// It renders nothing when the server did not send the comparison (which happens on
/// the settled branch, where the hours are already paid for and the counterfactual
/// no longer exists).
class OwnerUpliftNote extends StatelessWidget {
  final Economics economics;
  const OwnerUpliftNote(this.economics, {super.key});

  @override
  Widget build(BuildContext context) {
    final e = economics;
    final retail = e.retailValue;
    final up = e.uplift;
    if (retail == null || up == null || retail <= 0) return const SizedBox.shrink();
    final better = up >= 0;
    final tint = better ? AppColors.success : AppColors.warning;
    final pct = e.upliftPercent;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(better ? Icons.trending_up : Icons.trending_down, size: 18, color: tint),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  better
                      ? 'You earn ${formatPkr(up)} more than selling these hours'
                      : 'You earn ${formatPkr(up.abs())} less than selling these hours',
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: tint,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Tournament pays you ${formatPkr(e.ownerEarning)}. The same slots '
                  'sold one by one would fetch ${formatPkr(retail)}'
                  '${pct == null ? '' : better ? ' (+${pct.round()}%)' : ' (${pct.round()}%)'}.',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===============================================================
//  Fixtures and the bracket (SRS FE-6, FE-7)
// ===============================================================

/// One side of a fixture: crest, name, seed, and the score if there is one.
///
/// A team that is not known yet is drawn as "TBD" rather than skipped, and a bye is
/// drawn as "Bye" rather than as a blank. The empty half of a first-round pairing is
/// the information: it is how a captain sees they got a free pass to round two.
class _FixtureSide extends StatelessWidget {
  final String name;
  final String? logo;
  final int? elo;
  final int? score;
  final bool won;
  final bool dim;
  final bool compact;

  const _FixtureSide({
    required this.name,
    this.logo,
    this.elo,
    this.score,
    this.won = false,
    this.dim = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = dim
        ? AppColors.textSecondary
        : won
            ? AppColors.success
            : AppColors.textPrimary;
    return Row(
      children: [
        TeamCrest(logoUrl: logo, radius: compact ? 11 : 14),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                  fontSize: compact ? 11.5 : 13,
                  fontWeight: won ? FontWeight.w700 : FontWeight.w500,
                  fontStyle: dim ? FontStyle.italic : FontStyle.normal,
                  color: color,
                ),
              ),
              if (elo != null && !compact)
                Text(
                  'ELO $elo',
                  style: GoogleFonts.poppins(
                    fontSize: 9.5,
                    color: AppColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        if (score != null) ...[
          const SizedBox(width: 6),
          Text(
            '$score',
            style: GoogleFonts.poppins(
              fontSize: compact ? 12.5 : 15,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
        if (won) ...[
          const SizedBox(width: 5),
          Icon(Icons.check_circle, size: compact ? 11 : 13, color: AppColors.success),
        ],
      ],
    );
  }
}

/// One fixture, as a card.
///
/// Carries four things a card in a list has to carry on its own: who plays whom,
/// when and where, what the result was if there is one, and, before it is played,
/// the Elo win probability. That last line is labelled as the Elo formula and not as
/// a prediction, because that is what it is: a closed-form function of two ratings,
/// not a trained model, and calling it AI would claim an accuracy it does not have.
///
/// [onTap] opens the underlying match when there is one; [trailing] is where the
/// organiser's "Enter result" button goes, so the same tile serves the public bracket
/// and the owner's management list.
class FixtureTile extends StatelessWidget {
  final Fixture fixture;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Highlights the viewer's own team, so a captain can find their game in a
  /// 28-fixture round-robin without reading every row.
  final String? highlightTeamId;

  const FixtureTile(
    this.fixture, {
    super.key,
    this.onTap,
    this.trailing,
    this.highlightTeamId,
  });

  @override
  Widget build(BuildContext context) {
    final f = fixture;
    final mine = highlightTeamId != null &&
        (f.teamA == highlightTeamId || f.teamB == highlightTeamId);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: mine ? AppColors.accent.withValues(alpha: 0.55) : AppColors.divider,
          width: mine ? 1.4 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      f.label ?? 'Round ${f.round}',
                      style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const Spacer(),
                    if (f.isBye)
                      _Pill('Bye', AppColors.textSecondary)
                    else if (f.isWalkover)
                      _Pill('Walkover', AppColors.warning)
                    else if (f.isPlayed)
                      _Pill('Final score', AppColors.success)
                    else if (f.isTbd)
                      _Pill('To be decided', AppColors.textSecondary)
                    else
                      _Pill('Upcoming', AppColors.accent),
                  ],
                ),
                const SizedBox(height: 9),
                _FixtureSide(
                  name: f.nameA,
                  logo: f.teamALogo,
                  elo: f.teamAElo,
                  score: f.scoreA,
                  won: f.aWon,
                  dim: f.teamA == null,
                ),
                const SizedBox(height: 8),
                _FixtureSide(
                  name: f.nameB,
                  logo: f.teamBLogo,
                  elo: f.teamBElo,
                  score: f.scoreB,
                  won: f.bWon,
                  dim: f.teamB == null,
                ),
                if (f.when.isNotEmpty || f.favouriteLine != null || trailing != null) ...[
                  const Divider(height: 18),
                  Row(
                    children: [
                      if (f.when.isNotEmpty) ...[
                        Icon(Icons.event_outlined, size: 12, color: AppColors.textSecondary),
                        const SizedBox(width: 4),
                        Text(
                          f.when,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                      const Spacer(),
                      ?trailing,
                    ],
                  ),
                  if (f.favouriteLine != null && !f.isSettled) ...[
                    const SizedBox(height: 7),
                    _EloOddsLine(f),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Elo win probability as a two-sided bar plus the favoured side in words.
///
/// Labelled "Elo formula" on purpose. This is `1 / (1 + 10^((Rb-Ra)/400))` computed
/// on the server from two ratings the app already shows, not the output of any
/// trained model, and the project has four real models to point at without borrowing
/// credit for arithmetic. Naming the source is also what makes it useful: a captain
/// who knows it is a rating comparison knows exactly how much to trust it before a
/// cup upset.
class _EloOddsLine extends StatelessWidget {
  final Fixture fixture;
  const _EloOddsLine(this.fixture);

  @override
  Widget build(BuildContext context) {
    final f = fixture;
    final a = f.winProbabilityA;
    final line = f.favouriteLine;
    if (a == null || line == null) return const SizedBox.shrink();
    final even = line.startsWith('Even');
    final tint = even ? AppColors.textSecondary : AppColors.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              Expanded(
                flex: (a * 1000).round().clamp(1, 999),
                child: Container(height: 4, color: AppColors.accent),
              ),
              Expanded(
                flex: ((1 - a) * 1000).round().clamp(1, 999),
                child: Container(height: 4, color: AppColors.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.functions, size: 11, color: tint),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '$line  ·  Elo formula',
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A fixture as a bracket cell: narrow, fixed width, no chrome.
///
/// Deliberately thinner than [FixtureTile]. A bracket is read as a shape first, so a
/// cell shows only the two sides and the score; the venue, the time and the odds live
/// one tap away in the fixture sheet. A cell whose teams are not known yet still
/// occupies its full height, because a bracket that collapsed its unknown rows would
/// stop being a bracket.
class _BracketCell extends StatelessWidget {
  final Fixture fixture;
  final VoidCallback? onTap;
  final String? highlightTeamId;

  const _BracketCell(this.fixture, {this.onTap, this.highlightTeamId});

  @override
  Widget build(BuildContext context) {
    final f = fixture;
    final mine = highlightTeamId != null &&
        (f.teamA == highlightTeamId || f.teamB == highlightTeamId);
    final border = mine
        ? AppColors.accent.withValues(alpha: 0.6)
        : f.isSettled
            ? AppColors.divider
            : AppColors.border;
    return Container(
      width: 190,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: f.isTbd ? AppColors.inputFill : AppColors.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: mine ? 1.4 : 1),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FixtureSide(
                  name: f.nameA,
                  logo: f.teamALogo,
                  score: f.scoreA,
                  won: f.aWon,
                  dim: f.teamA == null,
                  compact: true,
                ),
                const SizedBox(height: 6),
                _FixtureSide(
                  name: f.nameB,
                  logo: f.teamBLogo,
                  score: f.scoreB,
                  won: f.bWon,
                  dim: f.teamB == null,
                  compact: true,
                ),
                if (f.isBye || f.isWalkover) ...[
                  const SizedBox(height: 6),
                  _Pill(
                    f.isBye ? 'Bye' : 'Walkover',
                    AppColors.textSecondary,
                    fontSize: 9,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The draw, as columns you scroll sideways through (SRS FE-6, FE-8).
///
/// One column per round, left to right, so the shape of the knockout is visible at a
/// glance and the champion's path can be traced by eye. Rounds are NOT centred
/// against their parents with connector lines: on a phone that costs most of the
/// width to whitespace, and the round header plus the seeded ordering already say who
/// meets whom. The final column is the one with a single cell.
///
/// Byes appear as real cells with one empty side, because a top seed getting a free
/// pass into round two is a fact about the draw a captain should be able to see.
class BracketView extends StatelessWidget {
  final Bracket bracket;
  final String? highlightTeamId;
  final void Function(Fixture fixture)? onFixtureTap;

  const BracketView(
    this.bracket, {
    super.key,
    this.highlightTeamId,
    this.onFixtureTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = bracket;
    if (!b.generated || b.roundsList.isEmpty) {
      return const TournamentEmpty(
        icon: Icons.account_tree_outlined,
        title: 'The draw is not out yet',
        message: 'Fixtures are generated when registration closes, or when the '
            'organiser draws the bracket early. Seeding is by team ELO.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (b.hasByes)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TournamentWarning(
              '${b.byes} ${b.byes == 1 ? 'team' : 'teams'} received a bye into the '
              'next round. Byes go to the top seeds when the number of entries is not '
              'a power of two, and no rating changes hands for a game that was not '
              'played.',
              icon: Icons.info_outline,
              color: AppColors.accent,
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final round in b.roundsList) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _RoundHeader(round),
                    const SizedBox(height: 10),
                    for (final f in round.fixtures)
                      _BracketCell(
                        f,
                        highlightTeamId: highlightTeamId,
                        onTap: onFixtureTap == null ? null : () => onFixtureTap!(f),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A round's name and how much of it has been played.
class _RoundHeader extends StatelessWidget {
  final BracketRound round;
  const _RoundHeader(this.round);

  @override
  Widget build(BuildContext context) {
    final done = round.isComplete;
    return SizedBox(
      width: 190,
      child: Row(
        children: [
          Expanded(
            child: Text(
              round.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          _Pill(
            done ? 'Done' : round.progress,
            done ? AppColors.success : AppColors.textSecondary,
            fontSize: 9,
          ),
        ],
      ),
    );
  }
}

// ===============================================================
//  Standings, records, provenance, empties
// ===============================================================

/// The round-robin table (SRS FE-7: "refresh live standings").
///
/// Ordered by the server, which sorts on points, then goal difference, then the
/// head-to-head result — so the app never re-sorts. Two teams level on points and
/// goal difference are separated by the game they played against each other, and only
/// the server knows that; re-sorting here on points alone would silently disagree with
/// the champion the server actually crowns.
class StandingsTable extends StatelessWidget {
  final List<Standing> standings;
  final String? highlightTeamId;

  /// Knockout draws are decided in favour of the higher seed, so the note under the
  /// table changes with the format.
  final bool knockout;

  const StandingsTable(
    this.standings, {
    super.key,
    this.highlightTeamId,
    this.knockout = false,
  });

  @override
  Widget build(BuildContext context) {
    if (standings.isEmpty) {
      return const TournamentEmpty(
        icon: Icons.leaderboard_outlined,
        title: 'No results yet',
        message: 'The table fills in as fixtures are played.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            children: [
              _StandingsHeaderRow(),
              for (final s in standings)
                _StandingRow(s, highlight: s.teamId == highlightTeamId),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          knockout
              ? 'Win 3 points, draw 1. A drawn knockout tie is decided in favour of '
                  'the higher seed.'
              : 'Win 3 points, draw 1, loss 0. Level on points is separated by goal '
                  'difference, then by the head-to-head result.',
          style: GoogleFonts.poppins(
            fontSize: 10.5,
            height: 1.4,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _StandingsHeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 22),
            Expanded(child: _h('Team')),
            SizedBox(width: 26, child: _h('P', center: true)),
            SizedBox(width: 26, child: _h('W', center: true)),
            SizedBox(width: 26, child: _h('D', center: true)),
            SizedBox(width: 26, child: _h('L', center: true)),
            SizedBox(width: 34, child: _h('GD', center: true)),
            SizedBox(width: 30, child: _h('Pts', center: true)),
          ],
        ),
      );

  static Widget _h(String t, {bool center = false}) => Text(
        t,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: GoogleFonts.poppins(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
          letterSpacing: 0.2,
        ),
      );
}

class _StandingRow extends StatelessWidget {
  final Standing standing;
  final bool highlight;
  const _StandingRow(this.standing, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final s = standing;
    final top = s.position == 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: highlight ? AppColors.accent.withValues(alpha: 0.07) : null,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: top
                ? Icon(Icons.emoji_events, size: 14, color: AppColors.warning)
                : Text(
                    '${s.position}',
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    fontWeight: highlight || top ? FontWeight.w700 : FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  s.seed == null ? 'ELO ${s.elo}' : 'Seed ${s.seed} · ELO ${s.elo}',
                  style: GoogleFonts.poppins(
                    fontSize: 9.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _n('${s.played}'),
          _n('${s.wins}'),
          _n('${s.draws}'),
          _n('${s.losses}'),
          SizedBox(width: 34, child: _cell(s.diff, bold: false)),
          SizedBox(width: 30, child: _cell('${s.points}', bold: true)),
        ],
      ),
    );
  }

  static Widget _n(String t) => SizedBox(width: 26, child: _cell(t, bold: false));

  static Widget _cell(String t, {required bool bold}) => Text(
        t,
        textAlign: TextAlign.center,
        style: GoogleFonts.poppins(
          fontSize: 11.5,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          color: bold ? AppColors.textPrimary : AppColors.textSecondary,
        ),
      );
}

/// The empty state, in the module's own words.
///
/// Every empty here explains WHY it is empty and what happens next — "fixtures are
/// generated when registration closes", "the table fills in as fixtures are played" —
/// because in a tournament an empty list is usually a stage of the process rather
/// than a dead end, and "Nothing here" would make a working tournament look broken.
class TournamentEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const TournamentEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 34),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.inputFill,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 30, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      );
}

/// Where the fixtures' hours came from (trained model #1, or date order).
///
/// The same discipline as `RankingSourceNote` in the recommender: a degraded ordering
/// must never be presented as the good one. When ml-service answered, the note says
/// the demand model placed the early rounds in the venue's quietest hours — which is
/// not decoration, because the venue cost is the sum of those slots' real prices, so
/// off-peak placement is what lets the entry fee be lower while the owner's sellable
/// peak inventory stays sellable. When it did not answer, the note says "date order"
/// and gives the reason, and the tournament still ran.
class SchedulingNote extends StatelessWidget {
  final SchedulingMeta meta;
  const SchedulingNote(this.meta, {super.key});

  @override
  Widget build(BuildContext context) {
    final m = meta;
    final ok = m.fromModel;
    final tint = ok ? AppColors.accent : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: ok ? 0.07 : 0.11),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: tint.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.insights : Icons.info_outline, size: 15, color: tint),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.label,
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (ok && m.modelVersion != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      'Demand model ${m.modelVersion}'
                      '${m.cached ? ' · cached' : ''}'
                      '${m.candidates > 0 ? ' · ${m.candidates} windows considered' : ''}',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Tournament record: 12 played · 8 W · 2 titles".
///
/// The module's answer to "is this team any good in cups?" — and the reason there is
/// no second ELO ladder. A separate tournament rating would be meaningless at three
/// matches, would seed the first tournament off all-1000s, and would force "which
/// number am I?" onto every screen. Counted achievements say the same thing without
/// pretending to a precision the sample size cannot support. Renders nothing for a
/// team that has never entered one.
class TeamRecordLine extends StatelessWidget {
  final TeamRecord record;
  final bool dense;
  const TeamRecordLine(this.record, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    if (record.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(
          Icons.emoji_events_outlined,
          size: dense ? 11 : 13,
          color: record.titles > 0 ? AppColors.warning : AppColors.textSecondary,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            dense ? record.line : 'Tournament record: ${record.line}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: dense ? 10 : 11.5,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// One entered team (SRS FE-5, FE-8).
///
/// The public teams tab and the organiser's approval list are the same row with
/// different [actions] — one shows who is in, the other adds Approve / Reject /
/// Remove. Keeping them one widget is why an organiser's list can never disagree with
/// what a captain sees about their own entry.
///
/// The fee is shown as HELD, not paid, while the entry is pending. That distinction is
/// the whole point of the escrow: the money has left the captain's spendable balance
/// but nobody has earned it yet, and a row that said "paid" would be describing a
/// transfer that has not happened.
class RegistrationTile extends StatelessWidget {
  final Registration registration;
  final List<Widget> actions;
  final bool showCaptain;

  const RegistrationTile(
    this.registration,
    {super.key,
    this.actions = const [],
    this.showCaptain = false,
  });

  @override
  Widget build(BuildContext context) {
    final r = registration;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            children: [
              TeamCrest(logoUrl: r.logoUrl, radius: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            r.teamName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        EntryStatusPill(r.status),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (r.seedLabel.isNotEmpty) r.seedLabel,
                        'ELO ${r.elo}',
                        if (r.city != null) r.city!,
                        if (showCaptain && r.captainName != null) r.captainName!,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    if (!r.record.isEmpty) ...[
                      const SizedBox(height: 3),
                      TeamRecordLine(r.record, dense: true),
                    ],
                  ],
                ),
              ),
              if (r.paidAmount > 0) ...[
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatPkr(r.paidAmount),
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      r.isOut ? 'refunded' : 'held',
                      style: GoogleFonts.poppins(
                        fontSize: 9.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          if (actions.isNotEmpty) ...[
            const Divider(height: 18),
            Row(children: actions),
          ],
        ],
      ),
    );
  }
}

/// A small filled action, for the two or three that sit inside a tile.
///
/// Exists because the organiser's approve / reject / remove row needs buttons that fit
/// three-to-a-line inside a card, which the app's full-width primary button cannot.
/// [busy] is driven by the calling screen's in-flight set, so a double tap on Approve
/// cannot fire two refunds.
class TournamentActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final bool busy;
  final bool filled;

  const TournamentActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    this.onPressed,
    this.busy = false,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final tint = enabled ? color : AppColors.disabled;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: filled ? tint : tint.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(9),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(
                          filled ? AppColors.white : tint,
                        ),
                      ),
                    )
                  else
                    Icon(icon, size: 13, color: filled ? AppColors.white : tint),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: filled ? AppColors.white : tint,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The champion, and the runner-up beside them.
///
/// The runner-up is on the banner and not in a footnote because they are PAID — 30% of
/// the prize by default — and a screen that celebrated only the winner would leave the
/// second cheque unexplained. Renders nothing until a champion exists.
class ChampionBanner extends StatelessWidget {
  final Tournament tournament;
  const ChampionBanner(this.tournament, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    if (!t.hasChampion) return const SizedBox.shrink();
    final e = t.economics;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.warning.withValues(alpha: 0.16),
            AppColors.accent.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.emoji_events, size: 30, color: AppColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.winnerName ?? 'Champion',
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  e == null || e.winnerShare <= 0
                      ? 'Champions'
                      : 'Champions · ${formatPkr(e.winnerShare)}',
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary,
                  ),
                ),
                if (t.runnerUpName != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    e == null || e.runnerupShare <= 0
                        ? 'Runner-up: ${t.runnerUpName}'
                        : 'Runner-up: ${t.runnerUpName} · ${formatPkr(e.runnerupShare)}',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Fixtures grouped under their round heading, scrolling vertically.
///
/// The right shape for round-robin, where there is no bracket to trace — 6 teams is 15
/// fixtures across 5 rounds and a sideways bracket would be nonsense — and the right
/// shape for the organiser, who works down a list entering scores rather than reading a
/// draw. [trailingBuilder] is how the owner's "Enter result" button gets onto the
/// fixtures that can take one.
class FixtureRoundList extends StatelessWidget {
  final List<BracketRound> rounds;
  final String? highlightTeamId;
  final void Function(Fixture fixture)? onFixtureTap;
  final Widget? Function(Fixture fixture)? trailingBuilder;

  const FixtureRoundList(
    this.rounds, {
    super.key,
    this.highlightTeamId,
    this.onFixtureTap,
    this.trailingBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (rounds.isEmpty) {
      return const TournamentEmpty(
        icon: Icons.sports_soccer_outlined,
        title: 'No fixtures yet',
        message: 'They are drawn when registration closes, or when the organiser '
            'generates them early.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final round in rounds) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Row(
              children: [
                Text(
                  round.label,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                _Pill(
                  round.isComplete ? 'Complete' : round.progress,
                  round.isComplete ? AppColors.success : AppColors.textSecondary,
                ),
                const Spacer(),
                if (round.date != null)
                  Text(
                    round.date!,
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          for (final f in round.fixtures)
            FixtureTile(
              f,
              highlightTeamId: highlightTeamId,
              onTap: onFixtureTap == null ? null : () => onFixtureTap!(f),
              trailing: trailingBuilder?.call(f),
            ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}
