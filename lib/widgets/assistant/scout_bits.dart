import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import 'scout_chips.dart';
import 'scout_theme.dart';

/// Scout's face. A ring that breathes while [thinking], so "is it working?" is
/// answered in the app bar as well as by the typing bubble in the list.
class ScoutAvatar extends StatefulWidget {
  final double size;
  final bool thinking;

  const ScoutAvatar({this.size = 34, this.thinking = false, super.key});

  @override
  State<ScoutAvatar> createState() => _ScoutAvatarState();
}

class _ScoutAvatarState extends State<ScoutAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.thinking) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(ScoutAvatar old) {
    super.didUpdateWidget(old);
    if (widget.thinking && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.thinking && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = _c.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [ScoutTheme.accent, ScoutTheme.accentDim],
            ),
            boxShadow: [
              BoxShadow(
                color: ScoutTheme.accent.withValues(alpha: 0.18 + 0.34 * t),
                blurRadius: 6 + 10 * t,
                spreadRadius: 0.5 + 1.5 * t,
              ),
            ],
          ),
          child: Icon(
            Icons.auto_awesome,
            size: widget.size * 0.52,
            color: Colors.white,
          ),
        );
      },
    );
  }
}

/// The provenance pill: where this answer came from, on the answer itself.
///
/// Small on purpose — it is evidence, not decoration — but always present, because
/// "did the model do this or did you hard-code it?" is a per-message question and
/// this is the per-message answer. Tapping opens the full breakdown.
class ScoutSourcePill extends StatelessWidget {
  final ScoutSource source;
  final VoidCallback? onTap;

  const ScoutSourcePill({required this.source, this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    final tone = ScoutTheme.sourceTone(source);
    return Semantics(
      label: 'Answer source: ${source.label}. ${source.gloss}',
      button: onTap != null,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: tone.color.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: tone.color.withValues(alpha: 0.32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(tone.icon, size: 10.5, color: tone.color),
              const SizedBox(width: 4),
              Text(
                source.label,
                style: TextStyle(
                  color: tone.color,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                Icon(Icons.expand_more_rounded, size: 11, color: tone.color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A match percentage from a ranker.
///
/// Draws nothing when [pct] is null. That is the whole point: a null means no
/// model scored this row, and "0% match" would be a confident claim about a
/// calculation that never ran.
class ScoutMatchBadge extends StatelessWidget {
  final int? pct;
  final bool showLabel;

  const ScoutMatchBadge({required this.pct, this.showLabel = false, super.key});

  @override
  Widget build(BuildContext context) {
    final p = pct;
    if (p == null) return const SizedBox.shrink();
    final tone = ScoutTheme.pctTone(p);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: tone.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: tone.color.withValues(alpha: 0.34)),
      ),
      child: Text(
        showLabel ? '$p% · ${tone.label}' : '$p% match',
        style: TextStyle(color: tone.color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// A square thumbnail with a graceful fallback.
///
/// Venues without a photo are common in seeded data, so the empty state is a
/// designed one — a tinted tile with the sport's icon — rather than a broken-image
/// glyph or a hole in the layout.
class ScoutThumb extends StatelessWidget {
  final String? url;
  final IconData fallback;
  final double size;
  final double radius;

  const ScoutThumb({
    required this.url,
    this.fallback = Icons.stadium_rounded,
    this.size = 58,
    this.radius = 12,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ScoutTheme.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ScoutTheme.lineSoft),
      ),
      child: Icon(fallback, color: ScoutTheme.accent.withValues(alpha: 0.7), size: size * 0.42),
    );

    final src = url;
    if (src == null || src.isEmpty || !src.startsWith('http')) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: src,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      ),
    );
  }
}

/// The model's stated reasons for putting a row where it put it.
///
/// Shown by default rather than behind a tap: a ranked list that cannot say why is
/// indistinguishable from an arbitrary one, and "closest to you · under budget" is
/// what makes the ordering reviewable by the person reading it.
class ScoutReasons extends StatelessWidget {
  final List<String> reasons;
  final int max;

  const ScoutReasons({required this.reasons, this.max = 3, super.key});

  @override
  Widget build(BuildContext context) {
    if (reasons.isEmpty) return const SizedBox.shrink();
    final shown = reasons.take(max).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: shown
            .map(
              (r) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_rounded, size: 11, color: ScoutTheme.accent),
                  const SizedBox(width: 3),
                  Text(
                    r,
                    style: const TextStyle(
                      color: ScoutTheme.inkSoft,
                      fontSize: 10.5,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            )
            .toList(),
      ),
    );
  }
}

/// An icon-and-text fact, e.g. a city or a price. The unit of a card's metadata
/// row; [ScoutFacts] lays several of them out.
class ScoutFact {
  final IconData icon;
  final String text;
  final Color? color;

  const ScoutFact(this.icon, this.text, {this.color});
}

/// A wrapped row of [ScoutFact]s. Wrapped, not scrolled — a horizontal scroll
/// inside a chat list is a gesture fight, and a fact the user cannot see is
/// worse than a two-line card.
class ScoutFacts extends StatelessWidget {
  final List<ScoutFact> facts;
  final double fontSize;

  const ScoutFacts({required this.facts, this.fontSize = 11, super.key});

  @override
  Widget build(BuildContext context) {
    final shown = facts.where((f) => f.text.trim().isNotEmpty).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: shown
          .map(
            (f) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(f.icon, size: fontSize + 1.5, color: f.color ?? ScoutTheme.inkFaint),
                const SizedBox(width: 3.5),
                Text(
                  f.text,
                  style: TextStyle(
                    color: f.color ?? ScoutTheme.inkSoft,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          )
          .toList(),
    );
  }
}

/// The heading inside a card: a title, an optional trailing badge, one line each.
class ScoutCardTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const ScoutCardTitle({required this.title, this.subtitle, this.trailing, super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: ScoutTheme.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              if (subtitle != null && subtitle!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

/// The three things a card can ask the screen to do, passed down as one object so
/// adding a fourth does not re-thread every constructor.
///
/// The split matters. [onChip] posts a chip and is therefore a *conversation*
/// move — the server decides what happens. [onScreen] and [onDirections] are
/// *client* moves that leave the chat; Scout is not involved and no turn is
/// recorded. Buttons for the two are styled differently for exactly that reason.
class ScoutCardActions {
  /// Post one of the backend's own chips back as the next turn.
  final ScoutChipTap? onChip;

  /// Navigate inside the app. The key is a `meta.screen` value — `bookings`,
  /// `wallet`, `venues` — not a Flutter route, so the mapping lives in one place.
  final void Function(String screen)? onScreen;

  /// Open a `map` card's route in the phone's maps app.
  final void Function(CardData mapData)? onDirections;

  /// False while a turn is in flight: buttons stay visible but stop responding,
  /// so a double tap cannot post two bookings.
  final bool enabled;

  const ScoutCardActions({
    this.onChip,
    this.onScreen,
    this.onDirections,
    this.enabled = true,
  });

  static const ScoutCardActions none = ScoutCardActions(enabled: false);
}
