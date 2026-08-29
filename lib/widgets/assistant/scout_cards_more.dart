import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import 'scout_bits.dart';
import 'scout_cards.dart';
import 'scout_chips.dart';
import 'scout_theme.dart';

/// The eight display-only cards: player, team, tournament, map, wallet, stats,
/// policy, capabilities.
///
/// They are split from `scout_cards.dart` along the same seam the model file uses —
/// those four move money or drive the dialog FSM, these eight show something. The
/// practical difference is that nothing in this file can lose a booking, so it can
/// be read, reviewed and changed with much less care than the other four.
///
/// Every one of them keeps two habits from the money cards, though:
///  * a null number renders as nothing, never as a zero. `matchPct == null` means
///    the ranker declined to score, and a "0% match" would be a lie the model never
///    told (the venue, player and team cards all pass model output through unchanged).
///  * a card's buttons are the backend's own chips, so a tap posts an action the
///    server already offered rather than one this file invented.
class ScoutExtraCard extends StatelessWidget {
  final ScoutCard card;
  final ScoutCardActions actions;
  final String? contextText;

  const ScoutExtraCard({
    required this.card,
    required this.actions,
    this.contextText,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final d = card.data;
    switch (card.type) {
      case ScoutCardType.player:
        return _PlayerCard(d, actions);
      case ScoutCardType.team:
        return _TeamCard(d, actions);
      case ScoutCardType.tournament:
        return _TournamentCard(d, actions);
      case ScoutCardType.map:
        return _MapCard(d, actions);
      case ScoutCardType.wallet:
        return _WalletCard(d, actions);
      case ScoutCardType.policy:
        return _PolicyCard(d, contextText);
      case ScoutCardType.capabilities:
        return _CapabilitiesCard(d, actions);
      case ScoutCardType.stats:
        return _StatsCard(d, actions);
      default:
        return _UnknownCard(card.type);
    }
  }
}

/// A player, as ranked by model #4's player scorer.
///
/// The layout puts the match percentage on the same line as the name because that
/// number is the whole reason this player is in front of you — it is the ranker's
/// answer, and burying it under the position and the trust score would make the card
/// look like a directory listing instead of a recommendation. When it is null there
/// is simply no badge; the card still works as a directory listing, honestly.
class _PlayerCard extends StatelessWidget {
  final CardData d;
  final ScoutCardActions actions;

  const _PlayerCard(this.d, this.actions);

  @override
  Widget build(BuildContext context) {
    final trust = d.moneyOrNull('trustScore');
    final played = d.intOrNull('matchesPlayed');

    return ScoutCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ScoutThumb(
                url: d.strOrNull('photo'),
                fallback: Icons.person_rounded,
                size: 44,
                radius: 999,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ScoutCardTitle(
                            title: d.str('name', or: 'Player'),
                            subtitle: d.strOrNull('city'),
                          ),
                        ),
                        ScoutMatchBadge(pct: d.pctOrNull),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ScoutFacts(
                      facts: [
                        if (d.has('position'))
                          ScoutFact(Icons.place_outlined, d.str('position')),
                        if (d.has('skill'))
                          ScoutFact(Icons.trending_up_rounded, d.str('skill')),
                        if (trust != null)
                          ScoutFact(
                            Icons.verified_user_outlined,
                            'Trust ${trust.round()}',
                            color: trust >= 70 ? ScoutTheme.good : ScoutTheme.inkSoft,
                          ),
                        if (played != null)
                          ScoutFact(
                            Icons.sports_rounded,
                            '$played match${played == 1 ? '' : 'es'}',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          ScoutReasons(reasons: d.strings('reasons')),
          ScoutCardButtons(buttons: d.buttons(), actions: actions),
        ],
      ),
    );
  }
}

/// A team — for `find_teams`, `find_opponents` and `team_stats` alike.
///
/// `displayElo` and `isRanked` are two fields for one honesty rule that the ELO
/// helper enforces server-side: a side with fewer than the minimum verified matches
/// is **Unranked**, not "1200". Printing the starting rating for a team that has
/// never played would invent a competitive record, so when `isRanked` is false this
/// card says the word instead of the number.
class _TeamCard extends StatelessWidget {
  final CardData d;
  final ScoutCardActions actions;

  const _TeamCard(this.d, this.actions);

  @override
  Widget build(BuildContext context) {
    final ranked = d.raw['isRanked'] == null ? null : d.flag('isRanked');
    final shown = d.intOrNull('displayElo') ?? d.intOrNull('elo');
    final wins = d.intOrNull('wins');
    final losses = d.intOrNull('losses');
    final members = d.intOrNull('memberCount');

    return ScoutCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ScoutThumb(
                url: d.strOrNull('logo'),
                fallback: Icons.shield_outlined,
                size: 42,
                radius: 12,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ScoutCardTitle(
                            title: d.str('name', or: 'Team'),
                            subtitle: [
                              if (d.has('sport')) d.str('sport'),
                              if (d.has('city')) d.str('city'),
                            ].join(' · '),
                          ),
                        ),
                        ScoutMatchBadge(pct: d.pctOrNull),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ScoutFacts(
                      facts: [
                        if (ranked == false)
                          const ScoutFact(
                            Icons.hourglass_empty_rounded,
                            'Unranked',
                            color: ScoutTheme.inkFaint,
                          )
                        else if (shown != null)
                          ScoutFact(
                            Icons.emoji_events_outlined,
                            '$shown ELO',
                            color: ScoutTheme.money,
                          ),
                        if (wins != null && losses != null)
                          ScoutFact(Icons.timeline_rounded, '${wins}W–${losses}L'),
                        if (members != null)
                          ScoutFact(Icons.groups_outlined, '$members player${members == 1 ? '' : 's'}'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          ScoutReasons(reasons: d.strings('reasons')),
          ScoutCardButtons(buttons: d.buttons(), actions: actions),
        ],
      ),
    );
  }
}

/// An open tournament.
///
/// The deadline gets its own row rather than joining the fact strip because it is the
/// only irreversible thing on the card: a ground can be booked tomorrow, a tournament
/// that closed last night cannot be entered at all. The backend has already converted
/// that instant to a PKT calendar day, so this widget does no date maths — reading a
/// deadline a day early is a bug worth avoiding by not having the code.
class _TournamentCard extends StatelessWidget {
  final CardData d;
  final ScoutCardActions actions;

  const _TournamentCard(this.d, this.actions);

  @override
  Widget build(BuildContext context) {
    final full = d.flag('isFull');
    final maxTeams = d.intOrNull('maxTeams');
    final teamsIn = d.intOrNull('teamsIn') ?? 0;
    final left = d.intOrNull('spotsLeft');
    final free = d.moneyOrNull('entryFee') == 0;

    return ScoutCardFrame(
      tint: full ? ScoutTheme.danger : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ScoutCardTitle(
                  title: d.str('name', or: 'Tournament'),
                  subtitle: [
                    if (d.has('sport')) d.str('sport'),
                    if (d.has('format')) d.str('format'),
                  ].join(' · '),
                ),
              ),
              if (full)
                const _MiniPill(text: 'Full', color: ScoutTheme.danger)
              else if (left != null && left <= 3)
                _MiniPill(text: '$left left', color: ScoutTheme.money),
            ],
          ),
          const SizedBox(height: 7),
          ScoutFacts(
            facts: [
              if (d.has('startLabel')) ScoutFact(Icons.event_rounded, d.str('startLabel')),
              ScoutFact(
                free ? Icons.card_giftcard_rounded : Icons.confirmation_number_outlined,
                d.str('entryFeeLabel', or: free ? 'Free entry' : '—'),
                color: free ? ScoutTheme.good : ScoutTheme.money,
              ),
              if (d.has('venueName'))
                ScoutFact(Icons.stadium_outlined, d.str('venueName')),
              if (d.has('organiser'))
                ScoutFact(Icons.person_outline_rounded, d.str('organiser')),
            ],
          ),
          if (maxTeams != null) ...[
            const SizedBox(height: 9),
            _FillBar(value: teamsIn, of: maxTeams),
          ],
          if (d.has('deadlineLabel')) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.timer_outlined, size: 12, color: ScoutTheme.danger),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'Registration closes ${d.str('deadlineLabel')}',
                    style: const TextStyle(
                      color: ScoutTheme.inkSoft,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          ScoutCardButtons(buttons: d.buttons(), actions: actions),
        ],
      ),
    );
  }
}

/// `teamsIn` of `maxTeams`, as a bar you can read without reading.
class _FillBar extends StatelessWidget {
  final int value;
  final int of;

  const _FillBar({required this.value, required this.of});

  @override
  Widget build(BuildContext context) {
    final ratio = of <= 0 ? 0.0 : (value / of).clamp(0.0, 1.0);
    final tone = ratio >= 1 ? ScoutTheme.danger : (ratio >= 0.8 ? ScoutTheme.money : ScoutTheme.accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            backgroundColor: ScoutTheme.lineSoft,
            valueColor: AlwaysStoppedAnimation<Color>(tone),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$value of $of teams in',
          style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 10.5),
        ),
      ],
    );
  }
}

/// A small status pill, for the one word a card needs to shout.
class _MiniPill extends StatelessWidget {
  final String text;
  final Color color;

  const _MiniPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.34)),
        ),
        child: Text(
          text,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
        ),
      );
}

/// Directions to a ground.
///
/// The backend sends two URIs because there are two different failures to avoid: a
/// `geo:` intent opens whatever maps app the phone actually has, and a Google Maps
/// web URL works when it has none. It also sends `hasPin`, which is the honest part —
/// not every venue row has coordinates, and for those the link searches by name and
/// city. Saying so on the card is the difference between "Maps opened somewhere odd"
/// and "Scout is broken".
///
/// The launching itself belongs to the screen, not here: `url_launcher` needs a
/// `BuildContext` for the failure snackbar and a widget this deep should not decide
/// what a failed external intent looks like.
class _MapCard extends StatelessWidget {
  final CardData d;
  final ScoutCardActions actions;

  const _MapCard(this.d, this.actions);

  @override
  Widget build(BuildContext context) {
    final hasPin = d.flag('hasPin');
    final where = [
      if (d.has('address')) d.str('address'),
      if (d.has('city')) d.str('city'),
    ].join(', ');

    return ScoutCardFrame(
      tint: ScoutTheme.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: ScoutTheme.accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: ScoutTheme.accent.withValues(alpha: 0.3)),
                ),
                child: const Icon(Icons.directions_rounded, size: 20, color: ScoutTheme.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ScoutCardTitle(
                  title: d.str('name', or: 'Ground'),
                  subtitle: where.isEmpty ? null : where,
                ),
              ),
            ],
          ),
          if (!hasPin) ...[
            const SizedBox(height: 8),
            Text(
              'No exact pin saved for this ground — Maps will search for the name instead.',
              style: TextStyle(
                color: ScoutTheme.inkFaint,
                fontSize: 10.5,
                height: 1.35,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                if (actions.onDirections != null)
                  ScoutChipButton(
                    label: 'Open in Maps',
                    icon: Icons.map_outlined,
                    tone: ScoutChipTone.primary,
                    dense: true,
                    onTap: () => actions.onDirections!(d),
                  ),
                ...d.buttons().map(
                  (b) => ScoutChipButton(
                    label: b.label,
                    icon: ScoutChipIcons.of(b.action),
                    dense: true,
                    enabled: actions.enabled && actions.onChip != null,
                    onTap: () => actions.onChip?.call(b),
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

/// The wallet, in the shape the wallet screen uses.
///
/// Two numbers, not one: `balance` is spendable and `frozen` is already committed to
/// bookings that have not been played. A single "total" would read as more money than
/// the user can act on, and every booking Scout takes moves an amount from the first
/// to the second — so the card that precedes a booking has to show both.
class _WalletCard extends StatelessWidget {
  final CardData d;
  final ScoutCardActions actions;

  const _WalletCard(this.d, this.actions);

  @override
  Widget build(BuildContext context) {
    final frozen = d.moneyOrNull('frozen') ?? 0;
    final minOut = d.moneyOrNull('withdrawalMin');

    return ScoutCardFrame(
      tint: ScoutTheme.money,
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Available to spend',
            style: TextStyle(
              color: ScoutTheme.inkFaint,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            d.label('balanceLabel', 'balance'),
            style: const TextStyle(
              color: ScoutTheme.money,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          if (frozen > 0) ...[
            const SizedBox(height: 9),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: ScoutTheme.canvas.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: ScoutTheme.lineSoft),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 13, color: ScoutTheme.inkSoft),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Held in escrow',
                      style: TextStyle(color: ScoutTheme.inkSoft, fontSize: 11.5),
                    ),
                  ),
                  Text(
                    d.label('frozenLabel', 'frozen'),
                    style: const TextStyle(
                      color: ScoutTheme.ink,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (minOut != null && minOut > 0) ...[
            const SizedBox(height: 7),
            Text(
              'Withdrawals start at ${formatPkr(minOut)}.',
              style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 10.5),
            ),
          ],
          ScoutCardButtons(
            buttons: d.buttons(),
            actions: actions,
            extra: [
              if (actions.onScreen != null)
                ScoutChipButton(
                  label: 'Open wallet',
                  icon: Icons.account_balance_wallet_outlined,
                  dense: true,
                  onTap: () => actions.onScreen!('wallet'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A policy answer, rendered as its numbers.
///
/// This card deliberately does NOT print `body`, because `body` is the same string as
/// the bubble it sits under — the backend passes the reply text into the card so a
/// client that shows cards only still has the answer. Printing both would say
/// everything twice, so what is left is the part prose is bad at: the figures, each
/// labelled, each read from `escrow.js POLICY`, `utils/elo.js` and `global_settings`
/// rather than typed here. Change the deposit percentage in the database and this card
/// changes with no app release — which is the whole point of sending numbers, not text.
class _PolicyCard extends StatelessWidget {
  final CardData d;
  final String? contextText;

  const _PolicyCard(this.d, this.contextText);

  /// The nine figures a policy answer can carry, in the order a reader wants them.
  List<({String label, String value})> _figures() {
    final out = <({String label, String value})>[];
    void add(String label, String? value) {
      if (value != null) out.add((label: label, value: value));
    }

    final window = d.intOrNull('windowHours');
    final refund = d.intOrNull('refundPct');
    final deposit = d.intOrNull('depositPct');
    final grace = d.intOrNull('graceMinutes');
    final minOut = d.moneyOrNull('withdrawalMin');
    final base = d.intOrNull('base');
    final k = d.intOrNull('kFactor');
    final ranked = d.intOrNull('rankedMinMatches');
    final band = d.intOrNull('preferredBand');

    add('Free-cancel window', window == null ? null : '${window}h');
    add('Refunded', refund == null ? null : '$refund%');
    add('Deposit held', deposit == null ? null : '$deposit%');
    add('No-show grace', grace == null ? null : '$grace min');
    add('Min withdrawal', minOut == null ? null : formatPkr(minOut));
    add('Starting rating', base?.toString());
    add('K-factor', k?.toString());
    add('Ranked after', ranked == null ? null : '$ranked match${ranked == 1 ? '' : 'es'}');
    add('Opponent band', band == null ? null : '±$band');
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final figures = _figures();
    final extra = d.strOrNull('extra');

    // `topup_help` puts both policy sentences in the reply AND in the card; only show
    // the second one when the bubble above has not already said it.
    final showExtra = extra != null &&
        extra.length > 8 &&
        !(contextText ?? '').contains(extra);

    if (figures.isEmpty && !showExtra) return const SizedBox.shrink();

    return ScoutCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.gavel_rounded, size: 14, color: ScoutTheme.inkSoft),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  d.str('title', or: 'Policy'),
                  style: const TextStyle(
                    color: ScoutTheme.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          if (figures.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: figures.map((f) => _FigureTile(label: f.label, value: f.value)).toList(),
            ),
          ],
          if (showExtra) ...[
            const SizedBox(height: 10),
            Text(
              extra,
              style: const TextStyle(color: ScoutTheme.inkSoft, fontSize: 11.5, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }
}

/// One policy figure: the number loud, the label quiet.
class _FigureTile extends StatelessWidget {
  final String label;
  final String value;

  const _FigureTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: ScoutTheme.canvas.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ScoutTheme.lineSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: ScoutTheme.ink,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: ScoutTheme.inkFaint,
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      );
}

/// The capability list — what Scout can actually do, as buttons.
///
/// This card is the recovery path from a sentence the classifier could not place, so
/// every entry is a **button carrying its action**, not a suggested phrase to retype.
/// That is what makes the two abilities the released model has no label for reachable
/// at all: a tap posts `find_players` or `navigate` directly and never goes near the
/// classifier.
///
/// Only labels, grouped. The one-line glosses the backend also sends are shown in the
/// capabilities sheet from the app bar instead — sixteen descriptions in a chat card
/// would push the sentence that prompted it off the top of the screen, and this card
/// appears on every low-confidence turn.
class _CapabilitiesCard extends StatelessWidget {
  final CardData d;
  final ScoutCardActions actions;

  const _CapabilitiesCard(this.d, this.actions);

  @override
  Widget build(BuildContext context) {
    final items = ScoutCapability.listFrom(d.raw['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    final groups = ScoutCapability.grouped(items);

    return ScoutCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final g in groups) ...[
            if (g != groups.first) const SizedBox(height: 11),
            Text(
              g.group.toUpperCase(),
              style: const TextStyle(
                color: ScoutTheme.inkFaint,
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: g.items
                  .map(
                    (c) => ScoutChipButton(
                      label: c.label,
                      icon: ScoutChipIcons.of(c.action),
                      dense: true,
                      enabled: actions.enabled && actions.onChip != null,
                      onTap: () => actions.onChip?.call(
                        ScoutChip(label: c.label, action: c.action),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

/// `stats` — declared in the contract, emitted by no action yet.
///
/// It gets a renderer anyway, and a generic one: every scalar in `data` becomes a
/// labelled row, with the key un-camel-cased for the label. When some future handler
/// starts sending a stats card, it will render as something legible on builds that
/// shipped before it existed, which is the only sane default for a wire contract that
/// is going to grow.
class _StatsCard extends StatelessWidget {
  final CardData d;
  final ScoutCardActions actions;

  const _StatsCard(this.d, this.actions);

  /// `matchesPlayed` → `Matches played`.
  static String _humanise(String key) {
    final spaced = key.replaceAllMapped(
      RegExp(r'(?<=[a-z0-9])([A-Z])'),
      (m) => ' ${m[1]!.toLowerCase()}',
    );
    final flat = spaced.replaceAll('_', ' ').trim();
    if (flat.isEmpty) return key;
    return '${flat[0].toUpperCase()}${flat.substring(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final rows = <({String label, String value})>[];
    d.raw.forEach((k, v) {
      if (k == 'buttons' || v == null) return;
      if (v is Map || v is List) return;
      final text = v is bool ? (v ? 'Yes' : 'No') : v.toString();
      if (text.isEmpty) return;
      rows.add((label: _humanise(k), value: text));
    });

    if (rows.isEmpty) return const SizedBox.shrink();

    return ScoutCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScoutCardTitle(title: d.str('title', or: 'Stats')),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.label,
                      style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 11.5),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    r.value,
                    style: const TextStyle(
                      color: ScoutTheme.ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ScoutCardButtons(buttons: d.buttons(), actions: actions),
        ],
      ),
    );
  }
}

/// A card type this build has never heard of.
///
/// Not a crash, not a silent drop. The reply's TEXT is always a complete answer on its
/// own — cards are enrichment — so the honest degradation is to say a piece of the
/// answer needs a newer app and leave the sentence above intact.
class _UnknownCard extends StatelessWidget {
  final String type;

  const _UnknownCard(this.type);

  @override
  Widget build(BuildContext context) => ScoutCardFrame(
        child: Row(
          children: [
            const Icon(Icons.system_update_alt_rounded, size: 14, color: ScoutTheme.inkFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'This answer has a “$type” card that needs a newer version of the app. '
                'The message above still has the full answer.',
                style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 10.5, height: 1.35),
              ),
            ),
          ],
        ),
      );
}
