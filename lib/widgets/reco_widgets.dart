import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../constants/colors.dart';
import '../models/reco.dart';
import 'match_widgets.dart' show CompetitivenessTone, TrustBadgeChip;

/// The S.5 Wave B recommender UI: the match-percentage badge, the "Why this
/// match?" breakdown, and the roster screen's suggested-players rail.
///
/// WHY THE BREAKDOWN IS A FIRST-CLASS WIDGET AND NOT A TOOLTIP
/// A recommender that shows a bare "83%" is asking to be trusted; one that can be
/// opened up is offering to be checked. The whole point of the weighted scorer is
/// that every part of it is publishable — the weights ship in the same payload as
/// the score — so the number the user sees can always be taken apart into the four
/// (or three) blocks that produced it, in the server's own order, with the blocks
/// that had no input labelled as unknown rather than drawn as zero.
///
/// Nothing here computes a score. It renders what the server sent, and when the
/// server sent nothing it says so instead of filling the gap.

// ═══════════════════════════════════════════════════════════════
//  Percentage
// ═══════════════════════════════════════════════════════════════

/// A match percentage as a pill. Colour bands come from [CompetitivenessTone] so
/// a 62% reads the same here as it does on a competitiveness bar — two different
/// percentages with two different colour scales on the same screen would make both
/// meaningless.
///
/// Renders nothing at all for a null [pct]. That is the fallback path, and an
/// empty space is the honest drawing of "no score was computed".
class MatchPctBadge extends StatelessWidget {
  final int? pct;
  final bool compact;

  /// Word before the number, e.g. `MATCH`. Null for the number alone.
  final String? caption;

  const MatchPctBadge({super.key, required this.pct, this.compact = false, this.caption});

  @override
  Widget build(BuildContext context) {
    final p = pct;
    if (p == null) return const SizedBox.shrink();
    final tone = CompetitivenessTone.of(p);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9, vertical: compact ? 3 : 5),
      decoration: BoxDecoration(
        color: tone.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tone.color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (caption != null) ...[
            Text(
              caption!,
              style: TextStyle(
                fontSize: compact ? 8 : 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: tone.color.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            '$p%',
            style: TextStyle(
              fontSize: compact ? 11 : 12.5,
              fontWeight: FontWeight.bold,
              color: tone.color,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Attribution
// ═══════════════════════════════════════════════════════════════

/// One line naming what produced an ordering — and, when nothing did, the
/// server's own sentence about what the list is instead.
///
/// This is the same discipline as the pricing card's `source` badge: a screen that
/// ranks things is entitled to say what ranked them, and a degraded ordering must
/// never be presented as the good one.
class RankingSourceNote extends StatelessWidget {
  final RankingInfo ranking;

  /// Shown after the label on the ranked path, e.g. `12 teams weighed`.
  final String? detail;

  const RankingSourceNote({super.key, required this.ranking, this.detail});

  @override
  Widget build(BuildContext context) {
    final ok = ranking.available;
    final note = ranking.fallbackNote;
    final color = ok ? AppColors.primary : AppColors.warning;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: ok ? 0.07 : 0.11),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.insights : Icons.info_outline, size: 14, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              ok
                  ? [ranking.label, ?detail].join(' · ')
                  : (note ?? 'Ranking service unavailable — showing a basic ordering'),
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                fontWeight: ok ? FontWeight.w600 : FontWeight.w500,
                color: ok ? AppColors.textSecondary : AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Why this match?
// ═══════════════════════════════════════════════════════════════

/// The expandable breakdown row (S.5 Wave B).
///
/// Collapsed it is one tappable line; open it lists every component the server
/// scored, in the server's published order, with that component's weight beside
/// it. A component whose input did not exist gets a sentence instead of a bar, and
/// the sentence says it was not held against the candidate — because it was not.
///
/// Renders nothing when there is no breakdown to show, which is what makes the row
/// vanish on the fallback path rather than open onto four empty bars.
class WhyThisMatch extends StatefulWidget {
  final List<ScoreComponent> components;

  /// The server's short phrases for the blocks that carried this match.
  final List<String> reasons;

  /// A closing line — the spec fingerprint, or which input the level block used.
  final String? footnote;

  /// Starts open. Used inside a details sheet, where the breakdown IS the content.
  final bool initiallyExpanded;

  const WhyThisMatch({
    super.key,
    required this.components,
    this.reasons = const [],
    this.footnote,
    this.initiallyExpanded = false,
  });

  @override
  State<WhyThisMatch> createState() => _WhyThisMatchState();
}

class _WhyThisMatchState extends State<WhyThisMatch> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    if (widget.components.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.help_outline, size: 14, color: AppColors.primary),
                const SizedBox(width: 6),
                const Text(
                  'Why this match?',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                const Spacer(),
                if (!_open && widget.reasons.isNotEmpty)
                  Flexible(
                    child: Text(
                      widget.reasons.first,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
                    ),
                  ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.expand_more, size: 18, color: AppColors.primary),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: _open ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          firstChild: _panel(),
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _panel() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.components.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _ComponentRow(widget.components[i]),
            ],
            if (widget.reasons.length > 1) ...[
              const SizedBox(height: 11),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (final r in widget.reasons)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        r,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (widget.footnote != null) ...[
              const SizedBox(height: 10),
              Text(
                widget.footnote!,
                style: const TextStyle(
                  fontSize: 9.5,
                  height: 1.4,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      );
}

/// One weighted block: its name, its share of the total, and either a bar or the
/// reason there isn't one.
class _ComponentRow extends StatelessWidget {
  final ScoreComponent c;
  const _ComponentRow(this.c);

  @override
  Widget build(BuildContext context) {
    final known = c.known;
    final color = known ? CompetitivenessTone.of(c.percent).color : AppColors.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                c.label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            // The weight is shown even when the block is unknown: it is what the
            // formula says, not what this candidate scored.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.border.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${c.weightPercent}% of score',
                style: const TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 7),
            SizedBox(
              width: 34,
              child: Text(
                known ? '${c.percent}%' : '—',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                Container(height: 4, color: Colors.white),
                if (known)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutCubic,
                    height: 4,
                    width: box.maxWidth * (c.value!.clamp(0, 1)),
                    color: color,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          known ? c.explain : c.unknownNote,
          style: TextStyle(
            fontSize: 9.5,
            height: 1.3,
            fontStyle: known ? FontStyle.normal : FontStyle.italic,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Suggested players rail (FR2.8)
// ═══════════════════════════════════════════════════════════════

/// The roster screen's horizontal rail of suggested players.
///
/// A rail rather than a list because this is a suggestion, not a queue: it sits
/// between the admin console and the team's own stats, and it must not push the
/// roster off the screen. Each card carries the match percentage and an invite
/// shortcut; the full breakdown lives one tap away in [PlayerSuggestionSheet],
/// where the bars have room to be read.
///
/// Empty states are three different sentences, because they mean three different
/// things: nobody to suggest, the service is down, or the read failed.
class SuggestedPlayersRail extends StatelessWidget {
  final SuggestedPlayers data;
  final bool loading;
  final bool failed;

  /// True while an invite is being minted, so the buttons can be disabled.
  final bool busy;

  final Future<void> Function() onRetry;
  final void Function(PlayerSuggestion) onInvite;

  const SuggestedPlayersRail({
    super.key,
    required this.data,
    required this.onRetry,
    required this.onInvite,
    this.loading = false,
    this.failed = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 96,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
      );
    }
    if (failed) return _notice(Icons.cloud_off, 'Could not load suggestions.', retry: true);

    final list = data.suggestions;
    if (list.isEmpty) {
      return _notice(
        Icons.person_search_outlined,
        data.ranking.available
            ? 'No players to suggest yet. Suggestions come from players who book '
                '${data.sport ?? 'this sport'} venues near ${data.homeCity ?? data.city ?? 'your city'}.'
            : (data.ranking.fallbackNote ?? 'Suggestions are unavailable right now.'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RankingSourceNote(
          ranking: data.ranking,
          detail: data.ranking.considered == null
              ? null
              : '${data.ranking.considered} player${data.ranking.considered == 1 ? '' : 's'} weighed',
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) => _SuggestionCard(
              s: list[i],
              ranking: data.ranking,
              busy: busy,
              onInvite: () => onInvite(list[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _notice(IconData icon, String text, {bool retry = false}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            if (retry)
              TextButton(
                onPressed: () => onRetry(),
                child: const Text('Retry', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      );
}

class _SuggestionCard extends StatelessWidget {
  final PlayerSuggestion s;
  final RankingInfo ranking;
  final bool busy;
  final VoidCallback onInvite;

  const _SuggestionCard({
    required this.s,
    required this.ranking,
    required this.busy,
    required this.onInvite,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 172,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => PlayerSuggestionSheet.show(
            context,
            s: s,
            ranking: ranking,
            onInvite: busy ? null : onInvite,
          ),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: AppColors.accentLight,
                      backgroundImage: (s.avatarUrl != null && s.avatarUrl!.isNotEmpty)
                          ? CachedNetworkImageProvider(s.avatarUrl!)
                          : null,
                      child: (s.avatarUrl == null || s.avatarUrl!.isEmpty)
                          ? Text(
                              s.initial,
                              style: const TextStyle(
                                color: AppColors.accent,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                    const Spacer(),
                    MatchPctBadge(pct: s.matchPct, compact: true),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  s.sportsLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 7),
                TrustBadgeChip(
                  band: s.trustBand,
                  label: s.trustLabel,
                  score: s.trustScore,
                  showScore: true,
                ),
                const Spacer(),
                Row(
                  children: [
                    const Icon(Icons.event_available_outlined,
                        size: 11, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        s.activityLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9.5, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                SizedBox(
                  width: double.infinity,
                  height: 30,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.link, size: 13),
                    label: const Text('Invite', style: TextStyle(fontSize: 11.5)),
                    onPressed: busy ? null : onInvite,
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

/// The details sheet behind a rail card: who they are, the full breakdown, and the
/// invite shortcut.
///
/// The breakdown opens expanded here. On a 172-wide card it would be unreadable;
/// this is the surface where the explanation is the point.
class PlayerSuggestionSheet {
  PlayerSuggestionSheet._();

  static Future<void> show(
    BuildContext context, {
    required PlayerSuggestion s,
    required RankingInfo ranking,
    VoidCallback? onInvite,
  }) {
    final parts = ranking.breakdown(s.components);
    final footnote = [
      if (s.eloSourceNote != null) s.eloSourceNote!,
      if (ranking.specTag != null) 'Weights published by ${ranking.specTag}',
    ].join('\n');

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.accentLight,
                    backgroundImage: (s.avatarUrl != null && s.avatarUrl!.isNotEmpty)
                        ? CachedNetworkImageProvider(s.avatarUrl!)
                        : null,
                    child: (s.avatarUrl == null || s.avatarUrl!.isEmpty)
                        ? Text(
                            s.initial,
                            style: const TextStyle(
                              color: AppColors.accent,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.sportsLabel,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  MatchPctBadge(pct: s.matchPct, caption: 'MATCH'),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                children: [
                  TrustBadgeChip(
                    band: s.trustBand,
                    label: s.trustLabel,
                    score: s.trustScore,
                    showScore: true,
                  ),
                  _fact(Icons.event_available_outlined, s.activityLabel),
                  if (!s.hasHomeArea) _fact(Icons.place_outlined, 'No usual venue yet'),
                ],
              ),
              const SizedBox(height: 6),
              if (parts.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    ranking.fallbackNote ??
                        'No match breakdown available — this list is ordered by recent activity.',
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: AppColors.textSecondary,
                    ),
                  ),
                )
              else
                WhyThisMatch(
                  components: parts,
                  reasons: s.reasons,
                  footnote: footnote.isEmpty ? null : footnote,
                  initiallyExpanded: true,
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  icon: const Icon(Icons.link, size: 17),
                  label: Text(onInvite == null ? 'Working…' : 'Create invite link'),
                  onPressed: onInvite == null
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          onInvite();
                        },
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'SportLynk has no direct player invite — this mints a single-use link '
                'you send them yourself.',
                style: TextStyle(fontSize: 10.5, height: 1.4, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _fact(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Text(
              text,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
}
