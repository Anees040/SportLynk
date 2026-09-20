import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';

/// The strip that sits directly above the composer while a reply is being
/// composed, showing what is being replied to and a way to cancel it. It mirrors
/// the quote block that will appear inside the sent bubble, so what the sender
/// sees while typing is what the room will see once it lands.
class ReplyBanner extends StatelessWidget {
  final ChatMessage target;
  final VoidCallback onCancel;

  const ReplyBanner({required this.target, required this.onCancel, super.key});

  @override
  Widget build(BuildContext context) {
    final who = target.senderName ?? 'this message';
    final icon = target.isImage
        ? Icons.photo
        : target.isAudio
            ? Icons.mic
            : null;
    final snippet = target.isImage
        ? 'Photo'
        : target.isAudio
            ? 'Voice message'
            : (target.body ?? '').trim();

    return Container(
      color: AppColors.inputFill,
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          Container(width: 3, height: 34, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $who',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.primary),
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
                        snippet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
            tooltip: 'Cancel reply',
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}
