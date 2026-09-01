import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import 'scout_bits.dart';
import 'scout_cards_more.dart';
import 'scout_chips.dart';
import 'scout_theme.dart';

/// The switch: one card type in, one widget out.
///
/// The backend's reply contract says the client renders by `card.type`, which makes
/// this the single place a type becomes pixels. Two consequences are deliberate:
///
///  1. An unknown type renders as a labelled placeholder, not a crash and not
///     silence. A newer backend that adds a thirteenth card must degrade to
///     "this needs a newer app version" on an old build, because the reply's text
///     is still perfectly useful without the card.
///  2. `stats` is in the contract but produced by no action today. It still gets a
///     renderer — a generic key/value table over whatever `data` holds — so the
///     day an action starts emitting it, nothing has to ship first.
///
/// The four money-and-state cards live here; the eight display-only ones are in
/// `scout_cards_more.dart`, the same split the model file draws.
class ScoutCardView extends StatelessWidget {
  final ScoutCard card;
  final ScoutCardActions actions;

  /// The text of the bubble this card sits under, when there is one.
  ///
  /// Only the policy card reads it, and only to avoid printing a paragraph the
  /// user has already just read: `topup_help` puts both of its policy sentences in
  /// the reply text and in the card, while `refund_policy` puts the second one in
  /// the card alone. A card cannot know which without seeing the sentence above it.
  final String? contextText;

  const ScoutCardView({
    required this.card,
    required this.actions,
    this.contextText,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    switch (card.type) {
      case ScoutCardType.venue:
        return _VenueCard(VenueCardData.of(card.data), actions);
      case ScoutCardType.slotPicker:
        return _SlotPickerCard(SlotPickerData.of(card.data), actions);
      case ScoutCardType.confirm:
        return _ConfirmCard(ConfirmData.of(card.data), actions);
      case ScoutCardType.booking:
        return _BookingCard(BookingCardData.of(card.data), actions);
      default:
        return ScoutExtraCard(card: card, actions: actions, contextText: contextText);
    }
  }
}

/// The card shell every renderer sits in, so twelve cards cannot drift into twelve
/// paddings. [tint] recolours the border — used only where meaning demands it.
class ScoutCardFrame extends StatelessWidget {
  final Widget child;
  final Color? tint;
  final EdgeInsets padding;

  const ScoutCardFrame({
    required this.child,
    this.tint,
    this.padding = const EdgeInsets.all(11),
    super.key,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: ScoutTheme.cardDecoration(tint: tint),
        child: child,
      );
}

/// A card's own buttons: the backend's chips, plus any client-side navigation the
/// card wants to offer.
///
/// [primary] names the one action the card exists for, so "Book" is filled and
/// "Directions" is not. Everything else is uniform, which keeps the visual weight
/// of a card proportional to what it can do rather than to how many chips it has.
class ScoutCardButtons extends StatelessWidget {
  final List<ScoutChip> buttons;
  final ScoutCardActions actions;
  final Set<String> primary;
  final List<Widget> extra;

  const ScoutCardButtons({
    required this.buttons,
    required this.actions,
    this.primary = const {},
    this.extra = const [],
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty && extra.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          ...buttons.map(
            (b) => ScoutChipButton(
              label: b.label,
              icon: ScoutChipIcons.of(b.action),
              tone: primary.contains(b.action)
                  ? ScoutChipTone.primary
                  : (b.action == 'cancel_booking' || b.action == 'cancel_confirm'
                      ? ScoutChipTone.danger
                      : ScoutChipTone.normal),
              dense: true,
              enabled: actions.enabled && actions.onChip != null,
              onTap: () => actions.onChip?.call(b),
            ),
          ),
          ...extra,
        ],
      ),
    );
  }
}

/// A ground.
///
/// Reads top-left to bottom-right in the order a player decides in: is it the
/// right place, where is it, what does it cost, is it any good, why is it here,
/// and only then what can I do about it. The match badge sits top-right because
/// it is the model's opinion, not a fact about the ground — and it disappears
/// entirely when nothing ranked this list.
class _VenueCard extends StatelessWidget {
  final VenueCardData v;
  final ScoutCardActions actions;

  const _VenueCard(this.v, this.actions);

  @override
  Widget build(BuildContext context) {
    final rating = v.rating;
    return ScoutCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ScoutThumb(url: v.photo, size: 56),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ScoutCardTitle(
                      title: v.name,
                      subtitle: [v.address, v.city]
                          .where((s) => s.trim().isNotEmpty)
                          .join(', '),
                      trailing: ScoutMatchBadge(pct: v.matchPct),
                    ),
                    const SizedBox(height: 6),
                    ScoutFacts(
                      facts: [
                        if (v.pricePerHour != null)
                          ScoutFact(
                            Icons.payments_rounded,
                            '${formatPkr(v.pricePerHour)}/hr',
                            color: ScoutTheme.money,
                          ),
                        ScoutFact(
                          Icons.star_rounded,
                          rating == null
                              ? 'New'
                              : '${rating.toStringAsFixed(1)}'
                                  '${v.totalReviews > 0 ? ' (${v.totalReviews})' : ''}',
                          color: rating == null ? ScoutTheme.inkFaint : ScoutTheme.money,
                        ),
                        if (v.sport.isNotEmpty)
                          ScoutFact(Icons.sports_soccer_rounded, v.sport),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          ScoutReasons(reasons: v.reasons),
          ScoutCardButtons(
            buttons: v.buttons,
            actions: actions,
            primary: const {'book_venue'},
          ),
        ],
      ),
    );
  }
}

/// The slot grid — the fastest path from "I want to play" to a booking.
///
/// Each tile carries its number as well as its time, because the number is a thing
/// the user can also type ("2", "the second one") and the dialog manager resolves
/// it. Showing it makes that shortcut discoverable instead of secret, and it means
/// a screen reader can say "slot 2" rather than reading a bare timestamp.
///
/// The tap posts the chip the backend minted for that slot, not arguments this
/// widget assembled, so a slot id never has to survive a round trip through the
/// UI's own idea of what a slot is.
class _SlotPickerCard extends StatelessWidget {
  final SlotPickerData p;
  final ScoutCardActions actions;

  const _SlotPickerCard(this.p, this.actions);

  @override
  Widget build(BuildContext context) {
    return ScoutCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule_rounded, size: 15, color: ScoutTheme.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [p.venueName, p.dateLabel].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ScoutTheme.ink,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          if (p.slots.isEmpty)
            const Text(
              'No free slots on that day.',
              style: TextStyle(color: ScoutTheme.inkSoft, fontSize: 12),
            )
          else
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: p.slots.map((s) {
                // Only the server's own minted chip may be posted. Synthesizing a
                // `pick_slot` here would author a money-path action client-side, and the
                // point of the button-only actions is that they are unreachable except
                // through a button the server sent. `assistantActions.js` mints one per
                // slot from this same array and `chipFor` matches on both `slotId` and
                // `n`, so a miss cannot happen for a well-formed card — and if one ever
                // does, the tile goes dim instead of guessing at a slot id.
                final chip = p.chipFor(s);
                return _SlotTile(
                  slot: s,
                  enabled: actions.enabled && actions.onChip != null && chip != null,
                  onTap: chip == null ? null : () => actions.onChip?.call(chip),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}

class _SlotTile extends StatelessWidget {
  final SlotOption slot;
  final bool enabled;
  final VoidCallback? onTap;

  const _SlotTile({required this.slot, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? ScoutTheme.ink : ScoutTheme.inkFaint;
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Slot ${slot.n}, ${slot.label}, ${slot.priceLabel}',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: Container(
            width: 92,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: ScoutTheme.accent.withValues(alpha: enabled ? 0.08 : 0.03),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: enabled
                    ? ScoutTheme.accent.withValues(alpha: 0.30)
                    : ScoutTheme.lineSoft,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${slot.n}',
                  style: TextStyle(
                    color: ScoutTheme.accent.withValues(alpha: enabled ? 0.75 : 0.35),
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  slot.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w700),
                ),
                if (slot.priceLabel.isNotEmpty && slot.priceLabel != '—')
                  Text(
                    slot.priceLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled ? ScoutTheme.money : ScoutTheme.inkFaint,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
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

/// The confirm card — the last thing between a sentence and a wallet.
///
/// Styled unlike every other card on purpose. The intent classifier is a guess,
/// and "kal 6 baje book kar do" could be a booking or a question about tomorrow;
/// the difference is real money moving into escrow. So this card gets the money
/// tint, the numbers get a table of their own, and both ways out are explicit
/// buttons — there is no default, and tapping outside does nothing.
///
/// Every figure is the server's arithmetic, rendered. The deposit percentage comes
/// from `escrow.js POLICY` through the payload, so this widget cannot disagree with
/// the charge that is about to happen, and a policy change needs no app release.
class _ConfirmCard extends StatelessWidget {
  final ConfirmData c;
  final ScoutCardActions actions;

  const _ConfirmCard(this.c, this.actions);

  @override
  Widget build(BuildContext context) {
    final refunding = c.what.contains('cancel');
    final totalLabel = refunding ? 'Refund to wallet' : 'Total';
    final depositLabel = refunding
        ? 'Deposit forfeited'
        : 'Deposit now${c.depositPct != null ? ' (${c.depositPct}%)' : ''}';

    // The two footer figures are already named in `lines` for a cancellation, so
    // drop the duplicates rather than print each number twice. Both sides come from
    // the same backend vocabulary, which is what makes matching on the label safe.
    final taken = {totalLabel.toLowerCase(), depositLabel.toLowerCase(), 'refund to wallet'};
    final detail = c.lines
        .where((l) => !taken.contains(l.label.toLowerCase()))
        .toList();

    return ScoutCardFrame(
      tint: ScoutTheme.money,
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                refunding ? Icons.undo_rounded : Icons.lock_outline_rounded,
                size: 15,
                color: ScoutTheme.money,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  c.title,
                  style: const TextStyle(
                    color: ScoutTheme.ink,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...detail.map((l) => _DetailRow(label: l.label, value: l.value)),
          ],
          const SizedBox(height: 9),
          Container(height: 1, color: ScoutTheme.money.withValues(alpha: 0.18)),
          const SizedBox(height: 9),
          if (c.total != null)
            _DetailRow(label: totalLabel, value: c.totalLabel, emphasis: true),
          if (c.deposit != null)
            _DetailRow(
              label: depositLabel,
              value: c.depositLabel,
              emphasis: true,
              tone: ScoutTheme.money,
            ),
          if (c.note != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, size: 12, color: ScoutTheme.inkFaint),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    c.note!,
                    style: const TextStyle(
                      color: ScoutTheme.inkSoft,
                      fontSize: 10.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
          ScoutCardButtons(
            buttons: c.buttons,
            actions: actions,
            primary: const {'confirm'},
          ),
        ],
      ),
    );
  }
}

/// One `label ......... value` row. Label left, value right, so a column of them
/// can be read down the right edge without re-reading the labels.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasis;
  final Color? tone;

  const _DetailRow({
    required this.label,
    required this.value,
    this.emphasis = false,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: emphasis ? ScoutTheme.inkSoft : ScoutTheme.inkFaint,
                  fontSize: emphasis ? 12 : 11.5,
                  fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 10),
          Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: tone ?? ScoutTheme.ink,
              fontSize: emphasis ? 13.5 : 12,
              fontWeight: emphasis ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// The booking card — proof, not a promise.
///
/// This is what arrives after a confirm succeeds, and it is deliberately the most
/// concrete card in the set: a real id, a real date, a status word that came out of
/// the bookings table. The status pill is coloured from that word rather than from
/// the fact that the request returned 200, because "pending" and "confirmed" are
/// different states of someone's Saturday.
///
/// It carries one button the backend does not send: **Open My Bookings**. Scout must
/// never look like a second, parallel booking system — a booking made here is the
/// same row the Bookings tab reads, and the fastest way to prove that to a user (and
/// to a viva panel) is to walk them straight there. That button is client-side, so it
/// spends no turn and no tokens.
class _BookingCard extends StatelessWidget {
  final BookingCardData b;
  final ScoutCardActions actions;

  const _BookingCard(this.b, this.actions);

  static ({Color color, IconData icon, String label}) _tone(String status) {
    switch (status) {
      case 'confirmed':
        return (color: ScoutTheme.good, icon: Icons.verified_rounded, label: 'Confirmed');
      case 'completed':
        return (color: ScoutTheme.inkSoft, icon: Icons.done_all_rounded, label: 'Completed');
      case 'cancelled':
      case 'canceled':
        return (color: ScoutTheme.danger, icon: Icons.cancel_outlined, label: 'Cancelled');
      case 'pending':
        return (color: ScoutTheme.money, icon: Icons.schedule_rounded, label: 'Pending');
      default:
        return (
          color: ScoutTheme.inkSoft,
          icon: Icons.receipt_long_rounded,
          label: status.isEmpty ? 'Booking' : status,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _tone(b.status);
    final ref = b.id.length > 8 ? b.id.substring(0, 8) : b.id;

    return ScoutCardFrame(
      tint: t.color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ScoutCardTitle(
                  title: b.venueName,
                  subtitle: b.city.isEmpty ? null : b.city,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: t.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: t.color.withValues(alpha: 0.34)),
                ),
                child: Row(
                  children: [
                    Icon(t.icon, size: 11, color: t.color),
                    const SizedBox(width: 4),
                    Text(
                      t.label,
                      style: TextStyle(
                        color: t.color,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ScoutFacts(
            facts: [
              if (b.dateLabel.isNotEmpty)
                ScoutFact(Icons.event_rounded, b.dateLabel),
              if (b.timeLabel.trim().isNotEmpty && b.timeLabel.trim() != '–')
                ScoutFact(Icons.access_time_rounded, b.timeLabel),
              if (b.total != null)
                ScoutFact(
                  Icons.payments_outlined,
                  b.totalLabel,
                  color: ScoutTheme.money,
                ),
            ],
          ),
          if (ref.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Ref $ref',
              style: const TextStyle(
                color: ScoutTheme.inkFaint,
                fontSize: 10,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
              ),
            ),
          ],
          ScoutCardButtons(
            buttons: b.buttons,
            actions: actions,
            extra: [
              if (actions.onScreen != null)
                ScoutChipButton(
                  label: 'Open My Bookings',
                  icon: Icons.list_alt_rounded,
                  dense: true,
                  onTap: () => actions.onScreen!('bookings'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
