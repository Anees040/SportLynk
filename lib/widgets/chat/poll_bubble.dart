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

  Widget _option(int i) {
    final mine = poll.didVote(myUserId, i);
    final count = poll.countFor(i);
    final frac = poll.fraction(i).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        onTap: poll.closed ? null : () => onVote(i),
        child: Stack(
          children: [
            // The share-of-vote fill behind the row.
            Positioned.fill(
              child: FractionallySizedBox(
                widthFactor: frac == 0 ? 0.0001 : frac,
                alignment: Alignment.centerLeft,
                child: Container(
                  decoration: BoxDecoration(
                    color: mine ? AppColors.accentLight : AppColors.inputFill,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    mine
                        ? (poll.allowMultiple ? Icons.check_box : Icons.check_circle)
                        : (poll.allowMultiple
                            ? Icons.check_box_outline_blank
                            : Icons.radio_button_unchecked),
                    size: 18,
                    color: mine ? AppColors.primary : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(poll.options[i],
                        style: const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
                  ),
                  const SizedBox(width: 8),
                  Text('$count',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
