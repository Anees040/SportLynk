import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import 'scout_theme.dart';

/// What happens when a suggestion is tapped: the chip itself goes back to the
/// server, never its label.
typedef ScoutChipTap = void Function(ScoutChip chip);

/// A glyph per action, so a row of six chips can be scanned rather than read.
///
/// Keyed on the ACTION, which is stable, not on the label, which is copy. An
/// action with no entry falls back to a neutral dot instead of vanishing — a chip
/// must never be un-tappable because this map is behind the backend.
abstract final class ScoutChipIcons {
  static const Map<String, IconData> _byAction = {
    'find_venue': Icons.stadium_rounded,
    'check_availability': Icons.schedule_rounded,
    'book_venue': Icons.event_available_rounded,
    'my_bookings': Icons.receipt_long_rounded,
    'cancel_booking': Icons.event_busy_rounded,
    'navigate': Icons.directions_rounded,
    'find_players': Icons.person_search_rounded,
    'find_opponents': Icons.sports_kabaddi_rounded,
    'find_teams': Icons.groups_rounded,
    'team_stats': Icons.military_tech_rounded,
    'create_team_help': Icons.group_add_rounded,
    'tournament_list': Icons.emoji_events_rounded,
    'wallet_balance': Icons.account_balance_wallet_rounded,
    'topup_help': Icons.add_card_rounded,
    'refund_policy': Icons.policy_rounded,
    'venue_info': Icons.info_outline_rounded,
    'pick_slot': Icons.access_time_rounded,
    'confirm': Icons.check_circle_rounded,
    'cancel_confirm': Icons.close_rounded,
    'retry_last': Icons.refresh_rounded,
    'help': Icons.help_outline_rounded,
    'ask_owner': Icons.storefront_rounded,
    'more': Icons.more_horiz_rounded,
  };

  static IconData of(String action) =>
      _byAction[action] ?? Icons.chevron_right_rounded;
}

/// How prominent a chip is. [primary] is for the one action a card is *for*
/// (Book, Confirm); everything else is [normal]. [danger] is destructive.
enum ScoutChipTone { normal, primary, danger }

/// One suggestion button.
class ScoutChipButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final ScoutChipTone tone;
  final bool enabled;
  final bool dense;
  final VoidCallback? onTap;

  const ScoutChipButton({
    required this.label,
    this.icon,
    this.tone = ScoutChipTone.normal,
    this.enabled = true,
    this.dense = false,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final primary = tone == ScoutChipTone.primary;
    final danger = tone == ScoutChipTone.danger;
    final accent = danger ? ScoutTheme.danger : ScoutTheme.accent;
    final fg = !enabled
        ? ScoutTheme.inkFaint
        : primary
            ? Colors.white
            : (danger ? ScoutTheme.danger : const Color(0xFFB7F7CD));

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 11 : 13,
              vertical: dense ? 7 : 9,
            ),
            decoration: BoxDecoration(
              gradient: primary && enabled ? ScoutTheme.userBubbleGradient : null,
              color: primary && enabled
                  ? null
                  : (enabled ? accent.withValues(alpha: 0.10) : Colors.transparent),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: enabled
                    ? accent.withValues(alpha: primary ? 0.55 : 0.34)
                    : ScoutTheme.lineSoft,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: dense ? 13 : 15, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: dense ? 11.5 : 12.5,
                    fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
                    height: 1.1,
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

/// A reply's chips, wrapped over as many lines as they need.
///
/// This is the widget that keeps rule 1 of the reply contract honest — every
/// answer ends with something to tap. It is rendered inside the bubble group
/// rather than pinned above the composer so that scrolling back to an old turn
/// brings that turn's options back with it; a chip is a stateless action, so an
/// hour-old "Book it" still works.
class ScoutChipsWrap extends StatelessWidget {
  final List<ScoutChip> chips;
  final ScoutChipTap? onTap;
  final bool dense;
  final Set<String> primaryActions;
  final Set<String> dangerActions;
  final bool enabled;

  const ScoutChipsWrap({
    required this.chips,
    this.onTap,
    this.dense = false,
    this.primaryActions = const {},
    this.dangerActions = const {'cancel_confirm', 'cancel_booking'},
    this.enabled = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: chips.map((c) {
        final tone = primaryActions.contains(c.action)
            ? ScoutChipTone.primary
            : dangerActions.contains(c.action)
                ? ScoutChipTone.danger
                : ScoutChipTone.normal;
        return ScoutChipButton(
          label: c.label,
          icon: ScoutChipIcons.of(c.action),
          tone: tone,
          dense: dense,
          enabled: enabled && onTap != null,
          onTap: () => onTap?.call(c),
        );
      }).toList(),
    );
  }
}
