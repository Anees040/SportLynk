import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';

/// The body of a poll message: the question, each option as a tappable bar that
/// fills to its share of the vote and shows a count, and a line that totals the
/// voters and opens the per-option voter list. Tapping an option votes (or
/// un-votes); a closed poll is read-only. [MessageBubble] wraps this with the
/// sender label and the time/ticks footer, as it does for text and media.
class PollBubble extends StatelessWidget {
  final ChatPoll poll;
  final String myUserId;
  final void Function(int optionIndex) onVote;

  const PollBubble({
    required this.poll,
    required this.myUserId,
    required this.onVote,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: MediaQuery.sizeOf(context).width * 0.66,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.bar_chart_rounded, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 5),
              Text(
                poll.closed
                    ? 'Poll closed'
                    : (poll.allowMultiple ? 'Select one or more' : 'Select one'),
                style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(poll.question,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 10),
          for (var i = 0; i < poll.options.length; i++) _option(i),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                poll.totalVoters == 1 ? '1 vote' : '${poll.totalVoters} votes',
                style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
              ),
              const Spacer(),
              if (poll.totalVoters > 0)
                GestureDetector(
                  onTap: () => _showVoters(context),
                  child: const Text('View votes',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _option(int i) => _PollOption(
        label: poll.options[i],
        selected: poll.didVote(myUserId, i),
        count: poll.countFor(i),
        fraction: poll.fraction(i),
        allowMultiple: poll.allowMultiple,
        closed: poll.closed,
        onTap: () => onVote(i),
      );

  void _showVoters(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(poll.question,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 12),
              for (var i = 0; i < poll.options.length; i++) ...[
                Text('${poll.options[i]} · ${poll.countFor(i)}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary)),
                const SizedBox(height: 2),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 10),
                  child: Text(
                    poll.voterNames(i).isEmpty ? 'No votes' : poll.voterNames(i).join(', '),
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One poll option as its own stateful row so a tap gives immediate feedback: it
/// presses in, shows a hover state on a pointer device, and animates its tick when
/// the selection toggles. A selected row carries an accent border, a firmer fill
/// and bolder text, so a chosen option reads at a glance rather than by its icon
/// alone.
class _PollOption extends StatefulWidget {
  final String label;
  final bool selected;
  final int count;
  final double fraction;
  final bool allowMultiple;
  final bool closed;
  final VoidCallback onTap;

  const _PollOption({
    required this.label,
    required this.selected,
    required this.count,
    required this.fraction,
    required this.allowMultiple,
    required this.closed,
    required this.onTap,
  });

  @override
  State<_PollOption> createState() => _PollOptionState();
}

class _PollOptionState extends State<_PollOption> {
  bool _pressed = false;
  bool _hovered = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  void _setHovered(bool v) {
    if (_hovered != v) setState(() => _hovered = v);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final frac = widget.fraction.clamp(0.0, 1.0);
    // Contrast: a selected option gains an accent border and a firmer fill than the
    // pale wash it had, and a hover previews that border on a pointer device.
    final Color borderColor = selected
        ? AppColors.accent
        : (_hovered ? AppColors.accent.withValues(alpha: 0.45) : AppColors.border);
    final Color fillColor =
        selected ? AppColors.accent.withValues(alpha: 0.18) : AppColors.inputFill;

    return MouseRegion(
      cursor: widget.closed ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        onTap: widget.closed ? null : widget.onTap,
        onTapDown: widget.closed ? null : (_) => _setPressed(true),
        onTapUp: widget.closed ? null : (_) => _setPressed(false),
        onTapCancel: widget.closed ? null : () => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Stack(
              children: [
                // The share-of-vote fill behind the row, animated to its new width
                // so a changed tally slides rather than snapping.
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: frac),
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => FractionallySizedBox(
                      widthFactor: value <= 0 ? 0.0001 : value,
                      alignment: Alignment.centerLeft,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        decoration: BoxDecoration(
                          color: fillColor,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: borderColor, width: selected ? 1.6 : 1.0),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      // The tick swaps under an AnimatedSwitcher so selecting an
                      // option scales its mark in rather than hard-cutting it.
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (child, anim) =>
                            ScaleTransition(scale: anim, child: child),
                        child: Icon(
                          selected
                              ? (widget.allowMultiple
                                  ? Icons.check_box
                                  : Icons.check_circle)
                              : (widget.allowMultiple
                                  ? Icons.check_box_outline_blank
                                  : Icons.radio_button_unchecked),
                          key: ValueKey(selected),
                          size: 18,
                          color:
                              selected ? AppColors.primary : AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(widget.label,
                            style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textPrimary,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400)),
                      ),
                      const SizedBox(width: 8),
                      Text('${widget.count}',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? AppColors.primary
                                  : AppColors.textSecondary)),
                    ],
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
