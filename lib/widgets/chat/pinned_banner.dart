import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';

/// The strip below the app bar that keeps a pinned announcement in view. Tapping
/// it scrolls the thread to the pinned message; when several are pinned it cycles
/// through them, oldest-first each tap, with a "1 of N" counter so the run's size
/// is never a surprise. An admin gets an unpin control on the right.
///
/// Stateful only to remember which of several pins is currently shown — the pin
/// list itself is owned by the controller and passed in.
class PinnedBanner extends StatefulWidget {
  final List<ChatMessage> pinned;
  final void Function(ChatMessage message) onTap;
  final void Function(ChatMessage message)? onUnpin;

  const PinnedBanner({
    required this.pinned,
    required this.onTap,
    this.onUnpin,
    super.key,
  });

  @override
  State<PinnedBanner> createState() => _PinnedBannerState();
}

class _PinnedBannerState extends State<PinnedBanner> {
  int _index = 0;

  @override
  void didUpdateWidget(PinnedBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A pin removed out from under the index must not leave it out of range.
    if (_index >= widget.pinned.length) _index = 0;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pinned.isEmpty) return const SizedBox.shrink();
    final count = widget.pinned.length;
    final i = _index.clamp(0, count - 1);
    final m = widget.pinned[i];

    final icon = m.isImage
        ? Icons.photo
        : m.isAudio
            ? Icons.mic
            : null;
    final snippet = m.isImage
        ? 'Photo'
        : m.isAudio
            ? 'Voice message'
            : (m.body ?? '').trim();

    return Material(
      color: AppColors.accentLight,
      child: InkWell(
        onTap: () {
          widget.onTap(m);
          if (count > 1) setState(() => _index = (i + 1) % count);
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              const Icon(Icons.push_pin, size: 16, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      count > 1 ? 'Pinned · ${i + 1} of $count' : 'Pinned message',
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.primary),
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
                            style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.onUnpin != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                  tooltip: 'Unpin',
                  onPressed: () => widget.onUnpin!(m),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
