import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// Chips are drawn inside the group rather than pinned above the composer, which costs
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

  /// The user's own words: right-aligned in a neutral pill, dimmed while in flight.
  ///
  /// The pill is a grey, not the brand green it used to be. Green had to carry white
  /// text at 2.3:1 to work, and a neutral removes that constraint instead of
  /// designing around it — which also leaves the green free to mean one thing on
  /// this screen rather than three.
  ///
  /// A failed send is not swallowed. It keeps the bubble, drops the opacity, and puts a
  /// retry beside it — because the text a user typed is the only copy of what they
  /// wanted, and losing it to a timeout is worse than any error message.
  Widget _user(BuildContext context) {
    final t = ScoutTheme.of(context);
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
              color: t.danger,
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
                decoration: BoxDecoration(
                  color: t.userBubble,
                  borderRadius: const BorderRadius.only(
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
                      style: TextStyle(
                        color: t.ink,
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                    if (failed)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Not sent',
                          style: TextStyle(
                            color: t.danger,
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

  /// Scout's side: avatar, provenance, sentence, cards, chips, actions.
  ///
  /// The sentence is bare text on the canvas at full width — no fill and no border,
  /// unlike the user's pill. Only one side of the conversation is bubbled, which is
  /// the pattern a reader recognises from every modern assistant: the user's turn is
  /// an object they placed, and the assistant's is the page answering. The old
  /// bordered bubble boxed the answer and its cards into one narrow column and fought
  /// the twelve card types below it; removing it lets each card own its own width.
  ///
  /// The sentence is only drawn when there is text. A few replies are pure card — the
  /// slot picker after a ground is chosen, for instance — where a stray empty line
  /// above the card would read as a rendering fault rather than a design.
  Widget _scout(BuildContext context) {
    final t = ScoutTheme.of(context);
    final r = msg.reply;
    final cards = r?.cards ?? const <ScoutCard>[];
    final chips = r?.chips ?? const <ScoutChip>[];
    final source = r?.source ?? ScoutSource.unknown;
    final hasText = msg.text.isNotEmpty;
    final canVote = msg.canVote && onVote != null;

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
              if (hasText)
                SelectableText(
                  msg.text,
                  style: TextStyle(color: t.ink, fontSize: 16, height: 1.5),
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
              if (hasText || canVote)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      if (hasText) _CopyButton(text: msg.text),
                      if (canVote)
                        _VoteRow(vote: msg.vote, onVote: (v) => onVote!(msg, v)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Copy Scout's answer to the clipboard.
///
/// The affordance a reader reaches for most in any assistant, and it sits inline
/// under the message rather than only behind a long press. A [SelectableText] already
/// gives word-selection and the platform copy toolbar on a long press; this is the
/// one-tap whole-message copy that a long press does not. The glyph turns to a tick
/// for a beat so the tap is acknowledged without a snackbar covering the transcript.
class _CopyButton extends StatefulWidget {
  final String text;

  const _CopyButton({required this.text});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  static const Duration _held = Duration(milliseconds: 1400);
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(_held, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoutTheme.of(context);
    return IconButton(
      onPressed: _copy,
      icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 14),
      color: _copied ? t.good : t.inkFaint,
      tooltip: _copied ? 'Copied' : 'Copy',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
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
/// A vote can be changed but not withdrawn: the endpoint takes 1 or -1 and upserts on
/// `(message_id, user_id)`, so the active thumb is inert rather than pretending to
/// offer an undo the server would reject.
class _VoteRow extends StatelessWidget {
  final int vote;
  final void Function(int vote) onVote;

  const _VoteRow({required this.vote, required this.onVote});

  @override
  Widget build(BuildContext context) {
    final t = ScoutTheme.of(context);
    return Row(
      children: [
        _VoteButton(
          icon: vote == 1 ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
          tone: vote == 1 ? t.good : t.inkFaint,
          tip: vote == 1 ? 'You marked this helpful' : 'Helpful',
          onTap: vote == 1 ? null : () => onVote(1),
        ),
        _VoteButton(
          icon: vote == -1 ? Icons.thumb_down_rounded : Icons.thumb_down_outlined,
          tone: vote == -1 ? t.danger : t.inkFaint,
          tip: vote == -1 ? 'You marked this unhelpful' : 'Not helpful',
          onTap: vote == -1 ? null : () => onVote(-1),
        ),
      ],
    );
  }
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
  Widget build(BuildContext context) {
    final t = ScoutTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: t.lineSoft),
          ),
          child: Text(
            _label(),
            style: TextStyle(
              color: t.inkFaint,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// "How I answered this" — the per-message audit, one tap from the provenance pill.
///
/// Every assistant demo gets the same question, and it is the right question: which
/// part of this was a model and which part was an if-statement? This sheet answers it
/// for the message on screen — the source, the predicted intent, the confidence,
/// which route produced the answer, the model version and how long the parse took.
///
/// It is also honest about its own limits. `nlu` travels with the live POST response
/// and is not stored on the message row, so an answer reloaded from history can show
/// its source but not its confidence. Saying that beats showing a blank field, and
/// beats guessing a number.
Future<void> showScoutExplainSheet(BuildContext context, ScoutMessage msg) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ScoutTheme.of(context).card,
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
    final t = ScoutTheme.of(context);
    final r = msg.reply;
    final source = r?.source ?? ScoutSource.unknown;
    final tone = t.sourceTone(source);
    final nlu = msg.nlu;
    final pct = nlu?.confidencePct;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How I answered this',
              style: TextStyle(
                color: t.ink,
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
                          style: TextStyle(
                            color: t.inkSoft,
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
              Text(
                'This turn has no classifier record. Either you tapped a button — those '
                'run the action directly and never go near the model — or the message was '
                'reloaded from history, where only the source is kept.',
                style: TextStyle(color: t.inkFaint, fontSize: 11.5, height: 1.45),
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
  Widget build(BuildContext context) {
    final t = ScoutTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: TextStyle(color: t.inkFaint, fontSize: 11.5),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: t.ink,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
