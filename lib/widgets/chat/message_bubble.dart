import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';
import '../../utils/cloudinary_url.dart';
import 'poll_bubble.dart';
import 'tick_icon.dart';
import 'voice_note_player.dart';

/// One chat bubble. Handles mine-vs-theirs alignment and colour, text & image
/// payloads, the deleted tombstone, per-message reactions, and (on my messages)
/// the delivery ticks. Long-press opens the action sheet the screen owns; a
/// failed send taps to retry.
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  final bool showSender; // group: label the sender on the first of their run
  final TickState tickState;
  final VoidCallback? onLongPress;
  final void Function(String emoji)? onReactionTap;
  final VoidCallback? onImageTap;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel; // cancel a still-uploading image
  final VoidCallback? onQuoteTap; // jump to the message this one replies to

  /// 0..1 while this message's own bytes are uploading, null otherwise. Drives a
  /// determinate ring on the pending overlay instead of an indeterminate spinner.
  final double? uploadProgress;

  /// For a poll message: the viewer's id (to mark their choices) and the vote
  /// callback. Null for non-poll bubbles.
  final String? myUserId;
  final void Function(int optionIndex)? onPollVote;

  /// Why this message's send failed, when it did. Shown beside "Not sent" so a
  /// failure names its cause rather than leaving the user to guess.
  final String? failureReason;

  const MessageBubble({
    required this.message,
    required this.isMine,
    required this.tickState,
    this.showSender = false,
    this.onLongPress,
    this.onReactionTap,
    this.onImageTap,
    this.onRetry,
    this.onCancel,
    this.onQuoteTap,
    this.uploadProgress,
    this.myUserId,
    this.onPollVote,
    this.failureReason,
    super.key,
  });

  // A stable, pleasant name colour per sender — the WhatsApp group touch.
  static const _nameColors = [
    Color(0xFF166534), Color(0xFF9A3412), Color(0xFF1E40AF), Color(0xFF6B21A8),
    Color(0xFF9D174D), Color(0xFF115E59), Color(0xFF854D0E), Color(0xFF3730A3),
  ];
  Color get _nameColor =>
      _nameColors[(message.senderId ?? '').hashCode.abs() % _nameColors.length];

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.78;
    final bubbleColor = isMine ? AppColors.chatBubbleMine : AppColors.chatBubbleOther;

    return Padding(
      padding: EdgeInsets.only(
        top: showSender ? 8 : 2,
        bottom: 2,
        left: isMine ? 40 : 8,
        right: isMine ? 8 : 40,
      ),
      child: Column(
        crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: message.isDeleted ? null : onLongPress,
            onTap: message.failed ? onRetry : null,
            child: Container(
              constraints: BoxConstraints(maxWidth: maxW),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isMine || !showSender ? 14 : 4),
                  topRight: Radius.circular(!isMine || !showSender ? 14 : 4),
                  bottomLeft: const Radius.circular(14),
                  bottomRight: const Radius.circular(14),
                ),
                border: isMine ? null : Border.all(color: AppColors.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: _content(context),
            ),
          ),
          if (message.reactions.isNotEmpty) _reactions(),
          if (message.failed)
            // The marker is a retry target too, not just a caption: the whole
            // failed bubble — body, media and this line — resends on a tap, so
            // there is no instruction to read and no dead pixel to hit.
            GestureDetector(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 12, color: AppColors.error),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        failureReason == null ? 'Not sent' : 'Not sent · $failureReason',
                        maxLines: 2,
                        style: const TextStyle(fontSize: 10.5, color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (message.isDeleted) return _deleted();
    if (message.isImage) return _image(context);
    if (message.isAudio) return _audio();
    if (message.isPoll && message.poll != null) return _poll();
    return _text();
  }

  Widget _poll() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSender && !isMine) _senderName(),
          if (message.isReply) _quote(),
          PollBubble(
            poll: message.poll!,
            myUserId: myUserId ?? '',
            onVote: (i) => onPollVote?.call(i),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(padding: const EdgeInsets.only(top: 4), child: _footer()),
          ),
        ],
      ),
    );
  }

  Widget _audio() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSender && !isMine) _senderName(),
          if (message.isReply) _quote(),
          VoiceNotePlayer(
            messageId: message.id,
            url: message.mediaUrl,
            durationMs: message.durationMs.toInt(),
            waveform: message.waveform,
            pending: message.pending,
            failedToSend: message.failed,
            sendError: failureReason,
            onRetrySend: onRetry,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _footer(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deleted() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Text('This message was deleted',
                style: TextStyle(
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    color: AppColors.textSecondary)),
          ],
        ),
      );

  Widget _text() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSender && !isMine) _senderName(),
          if (message.isReply) _quote(),
          // Body and the time/ticks share the last line where they fit, wrapping
          // otherwise — the compact WhatsApp footer.
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _bodyText(message.body ?? ''),
              const SizedBox(width: 8),
              _footer(),
            ],
          ),
        ],
      ),
    );
  }

  /// The body, with @mentions tinted. Only `@word` tokens are highlighted, and
  /// only when the message actually mentions somebody — so a stray "@" in
  /// ordinary text is never styled, and a message with no mentions is a plain
  /// [Text] with no per-character span cost.
  Widget _bodyText(String text, {double fontSize = 14.5, double height = 1.32}) {
    final base = TextStyle(fontSize: fontSize, height: height, color: AppColors.textPrimary);
    if (message.mentions.isEmpty || !text.contains('@')) {
      return Text(text, style: base);
    }
    final spans = <TextSpan>[];
    final re = RegExp(r'(@\w+)');
    var last = 0;
    for (final match in re.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: base));
      }
      spans.add(TextSpan(
        text: match.group(0),
        style: base.copyWith(color: AppColors.primary, fontWeight: FontWeight.w600),
      ));
      last = match.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last), style: base));
    return Text.rich(TextSpan(children: spans));
  }

  /// The quoted parent shown above a reply's own body: a coloured left bar, the
  /// original sender's name, and a one-line snippet. Tapping it asks the screen to
  /// scroll to the original.
  Widget _quote() {
    final rp = message.replyPreview!;
    final who = rp.senderName ?? 'Someone';
    final icon = rp.deleted
        ? null
        : rp.kind == MessageKind.image
            ? Icons.photo
            : rp.kind == MessageKind.audio
                ? Icons.mic
                : null;
    return GestureDetector(
      onTap: onQuoteTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(6),
          border: const Border(left: BorderSide(color: AppColors.accent, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              who,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary),
            ),
            const SizedBox(height: 1),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 13, color: AppColors.textSecondary),
                  const SizedBox(width: 3),
                ],
                Flexible(
                  child: Text(
                    rp.snippet,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontStyle: rp.deleted ? FontStyle.italic : FontStyle.normal,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The picked file while uploading (so the bubble is never empty), then a
  /// bubble-sized Cloudinary derivative once the send completes — the full image
  /// is fetched only by the viewer, not every thumbnail in the scroll.
  Widget _imageContent() {
    if (message.mediaUrl == null && message.localPath != null) {
      final path = message.localPath!;
      return kIsWeb
          ? Image.network(path, fit: BoxFit.cover)
          : Image.file(File(path), fit: BoxFit.cover);
    }
    return CachedNetworkImage(
      imageUrl: chatThumbUrl(message.mediaUrl ?? ''),
      fit: BoxFit.cover,
      memCacheWidth: 800,
      fadeInDuration: const Duration(milliseconds: 150),
      // A shimmer stands in while the derivative loads, with a real download ring
      // over it once the byte total is known — the receive half of Issue 1f.
      progressIndicatorBuilder: (_, _, p) => Stack(
        fit: StackFit.expand,
        children: [
          Shimmer.fromColors(
            baseColor: AppColors.inputFill,
            highlightColor: AppColors.white,
            child: Container(color: AppColors.inputFill),
          ),
          if (p.progress != null)
            Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                    value: p.progress, strokeWidth: 2.5, color: Colors.white),
              ),
            ),
        ],
      ),
      errorWidget: (_, _, _) => Container(
        color: AppColors.inputFill,
        child: const Center(
            child: Icon(Icons.broken_image_outlined, color: AppColors.textSecondary)),
      ),
    );
  }

  Widget _image(BuildContext context) {
    final radius = BorderRadius.circular(11);
    // Every photo bubble is the same width, so a run of images reads as a tidy
    // column rather than a ragged mix of sizes; the height follows the photo's
    // own ratio (already clamped by the model) so the image is never distorted.
    final imgW = (MediaQuery.sizeOf(context).width * 0.62).clamp(200.0, 280.0);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSender && !isMine)
            Padding(padding: const EdgeInsets.fromLTRB(6, 4, 6, 2), child: _senderName()),
          if (message.isReply)
            Padding(padding: const EdgeInsets.fromLTRB(3, 2, 3, 2), child: _quote()),
          SizedBox(
            width: imgW,
            child: ClipRRect(
              borderRadius: radius,
              child: GestureDetector(
                // A failed photo resends on a tap on the photo itself — the whole
                // target, not a line of text beside it. Opening the viewer would
                // be the wrong action anyway: there is no hosted image yet.
                onTap: message.failed
                    ? onRetry
                    : (message.pending ? null : onImageTap),
                child: Stack(
                  children: [
                    AspectRatio(
                      aspectRatio: message.aspectRatio,
                      child: _imageContent(),
                    ),
                    // The failed photo carries its own retry affordance, so the
                    // action is visible rather than something to be guessed at.
                    if (message.failed)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.38),
                          child: const Center(
                            child: CircleAvatar(
                              radius: 20,
                              backgroundColor: AppColors.error,
                              child: Icon(Icons.refresh, color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                      ),
                    if (message.pending)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.28),
                          child: Center(
                            child: onCancel == null
                                ? SizedBox(
                                    width: 34,
                                    height: 34,
                                    child: CircularProgressIndicator(
                                        value: uploadProgress,
                                        color: Colors.white,
                                        strokeWidth: 2.5),
                                  )
                                : Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      SizedBox(
                                        width: 46,
                                        height: 46,
                                        child: CircularProgressIndicator(
                                            value: uploadProgress,
                                            color: Colors.white,
                                            strokeWidth: 2.5),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.close,
                                            color: Colors.white, size: 20),
                                        tooltip: 'Cancel',
                                        onPressed: onCancel,
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    // Time/ticks float on a scrim when there is no caption to host them.
                    if (!message.hasCaption)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: _footer(onDark: true),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (message.hasCaption)
            SizedBox(
              width: imgW,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 6, 4),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    _bodyText(message.body!, height: 1.3),
                    const SizedBox(width: 8),
                    _footer(),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _senderName() => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          message.senderName ?? 'Player',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _nameColor),
        ),
      );

  Widget _footer({bool onDark = false}) {
    final color = onDark ? Colors.white : AppColors.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(DateFormat('h:mm a').format(message.createdAt),
            style: TextStyle(fontSize: 10.5, color: color)),
        if (isMine && !message.isDeleted) ...[
          const SizedBox(width: 3),
          TickIcon(tickState, mutedColor: color),
        ],
      ],
    );
  }

  Widget _reactions() {
    final counts = message.reactionCounts;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(
        spacing: 4,
        children: counts.entries.map((e) {
          return GestureDetector(
            onTap: () => onReactionTap?.call(e.key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                e.value > 1 ? '${e.key} ${e.value}' : e.key,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
