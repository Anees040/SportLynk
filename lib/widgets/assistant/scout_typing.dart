import 'dart:async';

import 'package:flutter/material.dart';

import 'scout_bits.dart';
import 'scout_theme.dart';

/// Scout thinking.
///
/// Three dots would be enough for a normal request, but this app's own
/// [ApiClient] allows 45 seconds for a cold call — the first request after a lull
/// can genuinely take that long. A spinner that says nothing for forty seconds
/// reads as a hang, so the caption escalates: silence, then "thinking", then an
/// honest explanation of why it is slow. Nothing here claims to know what Scout is
/// doing; it only reports how long it has been doing it.
class ScoutTyping extends StatefulWidget {
  const ScoutTyping({super.key});

  @override
  State<ScoutTyping> createState() => _ScoutTypingState();
}

class _ScoutTypingState extends State<ScoutTyping>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  Timer? _slow;
  Timer? _verySlow;
  String? _caption;

  @override
  void initState() {
    super.initState();
    _slow = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _caption = 'Thinking…');
    });
    _verySlow = Timer(const Duration(seconds: 9), () {
      if (mounted) {
        setState(() => _caption = 'Still working — the first request after a quiet '
            'spell takes longer.');
      }
    });
  }

  @override
  void dispose() {
    _slow?.cancel();
    _verySlow?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final caption = _caption;
    return Semantics(
      liveRegion: true,
      label: caption ?? 'Scout is typing',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 40, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ScoutAvatar(size: 26, thinking: true),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    decoration: BoxDecoration(
                      color: ScoutTheme.bubble,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(5),
                        topRight: Radius.circular(ScoutTheme.bubbleRadius),
                        bottomLeft: Radius.circular(ScoutTheme.bubbleRadius),
                        bottomRight: Radius.circular(ScoutTheme.bubbleRadius),
                      ),
                      border: Border.all(color: ScoutTheme.line),
                    ),
                    child: AnimatedBuilder(
                      animation: _c,
                      builder: (_, _) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(3, (i) {
                          final t = (_c.value + i * 0.2) % 1.0;
                          final dy = -3.0 * (t < 0.5 ? t * 2 : (1 - t) * 2);
                          final glow = t < 0.5 ? t * 2 : (1 - t) * 2;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2.5),
                            child: Transform.translate(
                              offset: Offset(0, dy),
                              child: Container(
                                width: 6.5,
                                height: 6.5,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color.lerp(
                                    ScoutTheme.inkFaint,
                                    ScoutTheme.accent,
                                    glow,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                  if (caption != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, top: 5),
                      child: Text(
                        caption,
                        style: const TextStyle(
                          color: ScoutTheme.inkFaint,
                          fontSize: 10.5,
                          height: 1.3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
