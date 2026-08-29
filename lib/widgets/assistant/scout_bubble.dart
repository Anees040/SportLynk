import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import 'scout_bits.dart';
import 'scout_cards.dart';
import 'scout_chips.dart';
import 'scout_theme.dart';

/// One turn on screen: the bubble, its cards, its chips and its provenance.
///
/// The ordering here is the argument of the whole screen. A reply is
/// sentence, then evidence, then next move — so the text comes first, the cards that
/// back it come under it, and the chips that continue the conversation come last.
/// Chips are drawn INSIDE the group rather than pinned above the composer, which costs
/// a little convenience and buys the thing that matters more: scrolling back to a turn
/// brings back the options that were offered at that turn. A pinned dock silently
/// rewrites history to whatever the newest message happened to suggest.
///
/// The provenance pill sits at the top of Scout's group, above the words, because it
/// changes how the words should be read — "read from the database just now" and "an
/// owner answered this once" are different kinds of true. Tapping it opens the explain
/// sheet, which answers "did the model do this, or did you hard-code it?" per message
/// rather than per feature.
class ScoutMessageGroup extends StatelessWidget {
  final ScoutMessage msg;
  final ScoutCardActions actions;

  /// Re-send a user message whose POST failed. The controller reuses the same
  /// `client_id`, so the server de-duplicates instead of double-booking a ground.
  final void Function(ScoutMessage msg)? onRetry;

  /// Cast 1 or -1. A vote can be changed later but not withdrawn, so the active
  /// thumb is inert rather than a toggle.
  final void Function(ScoutMessage msg, int vote)? onVote;

  /// Open "how I answered this" for this message.
  final void Function(ScoutMessage msg)? onExplain;

  const ScoutMessageGroup({
    required this.msg,
    required this.actions,
    this.onRetry,
    this.onVote,
    this.onExplain,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: msg.isScout ? _scout(context) : _user(context),
      );

  /// The user's own words: right-aligned, gradient, and dimmed while in flight.
  ///
  /// A failed send is not swallowed. It keeps the bubble, drops the opacity, and puts a
  /// retry beside it — because the text a user typed is the only copy of what they
  /// wanted, and losing it to a timeout is worse than any error message.
  Widget _user(BuildContext context) {
    final failed = msg.delivery == ScoutDelivery.failed;
    final sending = msg.delivery == ScoutDelivery.sending;

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (failed)
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 2),
            child: IconButton(
              onPressed: onRetry == null ? null : () => onRetry!(msg),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              color: ScoutTheme.danger,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
              tooltip: 'Send again',
            ),
          ),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.76),
            child: Opacity(
              opacity: sending ? 0.62 : 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(
                  gradient: ScoutTheme.userBubbleGradient,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(ScoutTheme.bubbleRadius),
                    topRight: Radius.circular(ScoutTheme.bubbleRadius),
                    bottomLeft: Radius.circular(ScoutTheme.bubbleRadius),
                    bottomRight: Radius.circular(6),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      msg.text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (failed)
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Text(
                          'Not sent',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Scout's side: avatar, provenance, sentence, cards, chips, vote.
  ///
  /// The bubble is only drawn when there IS text. A few replies are pure card — the
  /// slot picker after a ground is chosen, for instance — and an empty rounded
  /// rectangle above a card looks like a rendering bug rather than a design.
  Widget _scout(BuildContext context) {
    final r = msg.reply;
    final cards = r?.cards ?? const <ScoutCard>[];
    final chips = r?.chips ?? const <ScoutChip>[];
    final source = r?.source ?? ScoutSource.unknown;
    final maxBubble = MediaQuery.sizeOf(context).width * 0.80;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: ScoutAvatar(size: 26),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (source != ScoutSource.unknown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5, left: 1),
                  child: ScoutSourcePill(
                    source: source,
                    onTap: onExplain == null ? null : () => onExplain!(msg),
                  ),
                ),
              if (msg.text.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxBubble),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                    decoration: BoxDecoration(
                      color: ScoutTheme.bubble,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(6),
                        topRight: Radius.circular(ScoutTheme.bubbleRadius),
                        bottomLeft: Radius.circular(ScoutTheme.bubbleRadius),
                        bottomRight: Radius.circular(ScoutTheme.bubbleRadius),
                      ),
                      border: Border.all(color: ScoutTheme.line),
                    ),
                    child: SelectableText(
                      msg.text,
                      style: const TextStyle(
                        color: ScoutTheme.ink,
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              for (final c in cards)
                Padding(
                  padding: const EdgeInsets.only(top: ScoutTheme.gap),
                  child: ScoutCardView(card: c, actions: actions, contextText: msg.text),
                ),
              if (chips.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: ScoutChipsWrap(
                    chips: chips,
                    onTap: actions.onChip,
                    dense: true,
                    enabled: actions.enabled,
                  ),
                ),
              if (msg.canVote && onVote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _VoteRow(vote: msg.vote, onVote: (v) => onVote!(msg, v)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Was this answer any good?
///
/// Two taps, stored against the Scout message id — which is why the row only appears
/// once the server has given the message a real id, and never on an optimistic bubble
/// that has none. These votes are the only quality signal that comes from real use
/// rather than from a held-out exam, so the row is always present and never modal.
///
/// A vote can be CHANGED but not withdrawn: the endpoint takes 1 or -1 and upserts on
/// `(message_id, user_id)`, so the active thumb is inert rather than pretending to
/// offer an undo the server would reject.
class _VoteRow extends StatelessWidget {
  final int vote;
  final void Function(int vote) onVote;

  const _VoteRow({required this.vote, required this.onVote});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          _VoteButton(
            icon: vote == 1 ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
            tone: vote == 1 ? ScoutTheme.good : ScoutTheme.inkFaint,
            tip: vote == 1 ? 'You marked this helpful' : 'Helpful',
            onTap: vote == 1 ? null : () => onVote(1),
          ),
          _VoteButton(
            icon: vote == -1 ? Icons.thumb_down_rounded : Icons.thumb_down_outlined,
            tone: vote == -1 ? ScoutTheme.danger : ScoutTheme.inkFaint,
            tip: vote == -1 ? 'You marked this unhelpful' : 'Not helpful',
            onTap: vote == -1 ? null : () => onVote(-1),
          ),
        ],
      );
}

class _VoteButton extends StatelessWidget {
  final IconData icon;
  final Color tone;
  final String tip;
  final VoidCallback? onTap;

  const _VoteButton({
    required this.icon,
    required this.tone,
    required this.tip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 14),
        color: tone,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
      );
}

/// A day boundary in the transcript.
///
/// Chat history without them turns into one undated wall as soon as it is more than a
/// session old, and Scout's history is explicitly meant to be read back — a booking
/// made last Tuesday should look like last Tuesday.
class ScoutDateSeparator extends StatelessWidget {
  final DateTime day;

  const ScoutDateSeparator({required this.day, super.key});

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _label() {
    final now = DateTime.now();
    if (sameDay(day, now)) return 'Today';
    if (sameDay(day, now.subtract(const Duration(days: 1)))) return 'Yesterday';
    final sameYear = day.year == now.year;
    final base = '${day.day} ${_months[day.month - 1]}';
    return sameYear ? base : '$base ${day.year}';
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: BoxDecoration(
              color: ScoutTheme.card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: ScoutTheme.lineSoft),
            ),
            child: Text(
              _label(),
              style: const TextStyle(
                color: ScoutTheme.inkFaint,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      );
}

/// "How I answered this" — the per-message audit, one tap from the provenance pill.
///
/// Every assistant demo gets the same question, and it is the right question: which
/// part of this was a model and which part was an if-statement? This sheet answers it
/// for the message in front of you — the source, the predicted intent, the confidence,
/// which route produced the answer, the model version and how long the parse took.
///
/// It is also honest about its own limits. `nlu` travels with the live POST response
/// and is NOT stored on the message row, so an answer reloaded from history can show
/// its source but not its confidence. Saying that beats showing a blank field, and
/// beats guessing a number.
Future<void> showScoutExplainSheet(BuildContext context, ScoutMessage msg) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ScoutTheme.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ExplainSheet(msg: msg),
  );
}

class _ExplainSheet extends StatelessWidget {
  final ScoutMessage msg;

  const _ExplainSheet({required this.msg});

  @override
  Widget build(BuildContext context) {
    final r = msg.reply;
    final source = r?.source ?? ScoutSource.unknown;
    final tone = ScoutTheme.sourceTone(source);
    final nlu = msg.nlu;
    final pct = nlu?.confidencePct;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How I answered this',
              style: TextStyle(
                color: ScoutTheme.ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tone.color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: tone.color.withValues(alpha: 0.28)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(tone.icon, size: 17, color: tone.color),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          source.label,
                          style: TextStyle(
                            color: tone.color,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          source.gloss,
                          style: const TextStyle(
                            color: ScoutTheme.inkSoft,
                            fontSize: 11.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (nlu != null) ...[
              if (nlu.intent != null) _ExplainRow('Understood as', nlu.intent!),
              if (pct != null) _ExplainRow('Confidence', '$pct%'),
              if (nlu.abstained) const _ExplainRow('Outcome', 'Below threshold — I offered the menu'),
              if (nlu.via != null) _ExplainRow('Route', nlu.via!),
              if (nlu.modelVersion != null) _ExplainRow('Model', nlu.modelVersion!),
              if (nlu.ms != null) _ExplainRow('Parse time', '${nlu.ms} ms'),
            ] else
              const Text(
                'This turn has no classifier record. Either you tapped a button — those '
                'run the action directly and never go near the model — or the message was '
                'reloaded from history, where only the source is kept.',
                style: TextStyle(color: ScoutTheme.inkFaint, fontSize: 11.5, height: 1.45),
              ),
            if (r?.action != null) ...[
              const SizedBox(height: 4),
              _ExplainRow(
                'Action run',
                '${r!.action}${r.actionOk == false ? ' (failed)' : ''}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExplainRow extends StatelessWidget {
  final String label;
  final String value;

  const _ExplainRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              child: Text(
                label,
                style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 11.5),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  color: ScoutTheme.ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}
