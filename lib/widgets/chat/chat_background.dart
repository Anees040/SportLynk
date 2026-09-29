import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/colors.dart';

/// The team-chat background (Issue 5). WhatsApp-like: a warm ground under the
/// timeline so both bubble colours read, with a small set of presets the user
/// picks from. The choice is per device — a preference, not account state — so
/// it lives in [SharedPreferences] rather than the backend, keeping the feature
/// simple as asked.
///
/// A preset is a flat ground plus a flag for whether the faint doodle pattern is
/// painted over it. The pattern is drawn by [_ChatPatternPainter], not shipped as
/// an image asset, so it scales to any size and adds no binary weight.
enum ChatBgPreset {
  doodle('Doodle', AppColors.chatBackground, true),
  plain('Plain', AppColors.chatBgPlain, false),
  mint('Mint', AppColors.chatBgMint, false),
  slate('Slate', AppColors.chatBgSlate, false);

  const ChatBgPreset(this.label, this.ground, this.pattern);

  final String label;
  final Color ground;
  final bool pattern;

  static const _prefsKey = 'chat_bg_preset';

  /// The saved preset, or [doodle] when nothing has been chosen or the stored
  /// value no longer maps to a preset.
  static Future<ChatBgPreset> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_prefsKey);
    return ChatBgPreset.values.firstWhere(
      (p) => p.name == name,
      orElse: () => ChatBgPreset.doodle,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, name);
  }
}

/// Paints [preset] behind [child]. The child is expected to be the chat
/// timeline; this widget owns only the ground and the optional pattern.
class ChatBackground extends StatelessWidget {
  final ChatBgPreset preset;
  final Widget child;

  const ChatBackground({required this.preset, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final ground = ColoredBox(color: preset.ground);
    return Stack(
      fit: StackFit.expand,
      children: [
        ground,
        if (preset.pattern)
          const Positioned.fill(
            child: CustomPaint(painter: _ChatPatternPainter()),
          ),
        child,
      ],
    );
  }
}

/// A sparse, faint doodle: small rings and plus marks on a jittered grid. Drawn
/// in [AppColors.chatPattern] (a low-alpha forest tint) so it reads as texture
/// rather than content and never competes with a bubble.
class _ChatPatternPainter extends CustomPainter {
  const _ChatPatternPainter();

  static const double _cell = 56;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.chatPattern
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    final cols = (size.width / _cell).ceil() + 1;
    final rows = (size.height / _cell).ceil() + 1;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        // A deterministic per-cell jitter and shape choice, so the pattern is
        // stable across repaints and never re-randomises as the list scrolls.
        final seed = (r * 73856093) ^ (c * 19349663);
        final rnd = math.Random(seed);
        final dx = c * _cell + rnd.nextDouble() * _cell * 0.5;
        final dy = r * _cell + rnd.nextDouble() * _cell * 0.5;
        final center = Offset(dx, dy);
        if (seed.isEven) {
          canvas.drawCircle(center, 4.5, paint);
        } else {
          canvas.drawLine(center - const Offset(4, 0), center + const Offset(4, 0), paint);
          canvas.drawLine(center - const Offset(0, 4), center + const Offset(0, 4), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ChatPatternPainter oldDelegate) => false;
}

/// The preset picker, opened from the thread's overflow menu. Returns the chosen
/// preset (already persisted) or null if dismissed.
Future<ChatBgPreset?> showChatBackgroundPicker(
  BuildContext context,
  ChatBgPreset current,
) {
  return showModalBottomSheet<ChatBgPreset>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Chat background',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: ChatBgPreset.values.map((p) {
                final selected = p == current;
                return GestureDetector(
                  onTap: () async {
                    await p.save();
                    if (ctx.mounted) Navigator.pop(ctx, p);
                  },
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected ? AppColors.accent : AppColors.border,
                              width: selected ? 2.5 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ChatBackground(preset: p, child: const SizedBox.expand()),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(p.label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected ? AppColors.accent : AppColors.textSecondary,
                          )),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    ),
  );
}
