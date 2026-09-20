import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';
import 'tick_icon.dart';

/// A run of consecutive photos from one sender, drawn as a single WhatsApp-style
/// grid instead of a stack of separate bubbles. The screen decides what counts
/// as an album (same sender, sent, no caption, close in time — a pending, failed
/// or captioned photo stays its own bubble); this widget only lays the run out.
///
/// Every tile still stands for one real message: a tap opens the viewer at that
/// photo, a long-press opens that message's action sheet, so react and delete
/// remain per-photo exactly as they are for a lone image bubble. The footer
/// carries the run's newest time and the group tick of its last message.
class ImageAlbumBubble extends StatelessWidget {
  final List<ChatMessage> images;
  final bool isMine;
  final bool showSender;
  final TickState tickState;
  final void Function(int index) onOpen;
  final void Function(ChatMessage message) onLongPress;

  const ImageAlbumBubble({
    required this.images,
    required this.isMine,
    required this.tickState,
    required this.onOpen,
    required this.onLongPress,
    this.showSender = false,
    super.key,
  });

  static const _gap = 2.0;

  static const _nameColors = [
    Color(0xFF166534), Color(0xFF9A3412), Color(0xFF1E40AF), Color(0xFF6B21A8),
    Color(0xFF9D174D), Color(0xFF115E59), Color(0xFF854D0E), Color(0xFF3730A3),
  ];
  Color get _nameColor =>
      _nameColors[(images.first.senderId ?? '').hashCode.abs() % _nameColors.length];

  @override
  Widget build(BuildContext context) {
    // The album is square, capped so it never dominates the thread; three or
    // more photos fill the square, two sit as a single row half as tall.
    final side = (MediaQuery.sizeOf(context).width * 0.66).clamp(180.0, 260.0);

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
          if (showSender && !isMine)
            Padding(
              padding: const EdgeInsets.only(bottom: 3, left: 4),
              child: Text(
                images.first.senderName ?? 'Player',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _nameColor),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                _grid(side),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _footer(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(double side) {
    final n = images.length;
    final half = (side - _gap) / 2;

    if (n == 2) {
      return SizedBox(
        width: side,
        height: half,
        child: Row(children: [
          _tile(0, half, half),
          const SizedBox(width: _gap),
          _tile(1, half, half),
        ]),
      );
    }
    if (n == 3) {
      return SizedBox(
        width: side,
        height: side,
        child: Row(children: [
          _tile(0, half, side),
          const SizedBox(width: _gap),
          Column(children: [
            _tile(1, half, half),
            const SizedBox(height: _gap),
            _tile(2, half, half),
          ]),
        ]),
      );
    }
    // Four or more: a 2x2, with the fourth tile standing in for everything past
    // the third when there are extras behind it.
    final extra = n > 4 ? n - 3 : 0;
    return SizedBox(
      width: side,
      height: side,
      child: Column(children: [
        Row(children: [
          _tile(0, half, half),
          const SizedBox(width: _gap),
          _tile(1, half, half),
        ]),
        const SizedBox(height: _gap),
        Row(children: [
          _tile(2, half, half),
          const SizedBox(width: _gap),
          _tile(3, half, half, moreCount: extra),
        ]),
      ]),
    );
  }

  Widget _tile(int index, double w, double h, {int moreCount = 0}) {
    final url = images[index].mediaUrl ?? '';
    return GestureDetector(
      onTap: () => onOpen(index),
      onLongPress: () => onLongPress(images[index]),
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, _) => Container(color: AppColors.inputFill),
              errorWidget: (_, _, _) => Container(
                color: AppColors.inputFill,
                child: const Icon(Icons.broken_image_outlined, color: AppColors.textSecondary),
              ),
            ),
            if (moreCount > 0)
              Container(
                color: Colors.black.withValues(alpha: 0.45),
                alignment: Alignment.center,
                child: Text('+$moreCount',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(DateFormat('h:mm a').format(images.last.createdAt),
            style: const TextStyle(fontSize: 10.5, color: Colors.white)),
        if (isMine) ...[
          const SizedBox(width: 3),
          TickIcon(tickState, mutedColor: Colors.white),
        ],
      ],
    );
  }
}
