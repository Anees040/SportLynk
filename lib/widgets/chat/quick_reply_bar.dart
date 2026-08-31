import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/chat_channel.dart';

/// FR8.10 — the suggested-reply chip row that sits above the composer.
///
/// ADVISORY BY CONSTRUCTION: a tap calls [onPick], which fills the composer. This
/// widget cannot send, and the endpoint behind it does not either — the send goes
/// through the ordinary message path, so a mis-tap is a word in a text field
/// rather than a message the other side has already read.
///
/// THE BADGE IS EARNED, NOT DECORATIVE. The sparkle and the word "AI" appear only
/// when [QuickReplySet.fromModel] — i.e. the released 23-label classifier actually
/// answered. When ml-service is down the same three sentences arrive from a keyword
/// table and the row says "Suggested replies" with no sparkle, because claiming a
/// model that did not run is the one thing this project does not do.
class QuickReplyBar extends StatelessWidget {
  final QuickReplySet? set;
  final bool loading;
  final void Function(QuickReply reply) onPick;
  final VoidCallback onDismiss;

  const QuickReplyBar({
    required this.onPick,
    required this.onDismiss,
    this.set,
    this.loading = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return _shell(const _Loading());
    final s = set;
    if (s == null || s.isEmpty) return const SizedBox.shrink();

    return _shell(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (s.fromModel) ...[
              const Icon(Icons.auto_awesome, size: 13, color: AppColors.accent),
              const SizedBox(width: 5),
            ],
            Text(
              s.fromModel ? 'AI suggested replies' : 'Suggested replies',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
                letterSpacing: 0.2,
              ),
            ),
            const Spacer(),
            InkWell(
              onTap: onDismiss,
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close, size: 15, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final r in s.suggestions) ...[
                _Chip(text: r.text, onTap: () => onPick(r)),
                const SizedBox(width: 7),
              ],
            ],
          ),
        ),
      ],
    ));
  }

  Widget _shell(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
        decoration: const BoxDecoration(
          color: AppColors.cardBg,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: child,
      );
}

class _Chip extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _Chip({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accentLight,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12.5,
            color: AppColors.primary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: AppColors.accent),
        ),
        SizedBox(width: 9),
        Text(
          'Reading the message…',
          style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
