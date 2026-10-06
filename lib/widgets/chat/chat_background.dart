import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/colors.dart';

/// The team-chat background. WhatsApp-like in intent — a warm ground under the
/// timeline so both bubble colours read — but with a set of drawn patterns rather
/// than one faint doodle, because a chat the user looks at every day is worth
/// some design. The choice is per device (a preference, not account state) so it
/// lives in [SharedPreferences] rather than the backend.
///
/// Every pattern is painted by [_ChatPatternPainter] from geometry, not shipped
/// as an image asset: it scales to any screen, adds no binary weight, and its
/// tint comes from [AppColors] so it can never fight a bubble. Each is drawn at a
/// low alpha and on a deterministic per-cell seed, so the art is stable across
/// repaints and does not re-randomise as the list scrolls.
enum ChatPattern {
  /// Nothing over the ground.
  none,

  /// Sparse rings and plus marks — the original, kept because it is the quietest.
  doodle,

  /// Balls, goalposts and pennants: the on-brand one for a sports app.
  sport,

  /// A hexagon lattice, the densest geometric option.
  honeycomb,

  /// Gentle horizontal sine bands.
  waves,

  /// Small tilted ticks and triangles scattered like confetti.
  confetti,

  /// A fine blueprint cross-hatch with a heavier rule every fourth line.
  blueprint,

  /// Concentric quarter-arcs, the art-deco fan.
  arcs,

  /// Cricket kit: bats crossed over stumps, with the ball between them.
  cricket,

  /// Pitch markings — centre circles, corner arcs and halfway lines.
  pitch,

  /// Trophies and medals, for the tournament side of the app.
  trophies,

  /// A court net: diagonal mesh with a heavier tape line, as on a badminton or
  /// tennis net.
  net,

  /// Numbered jersey plates, the team-sheet motif.
  jerseys,
}

/// A background the user can pick: a ground colour plus the pattern drawn over
/// it, and whether that pattern uses the stronger tint.
enum ChatBgPreset {
  doodle('Doodle', AppColors.chatBackground, ChatPattern.doodle),
  sport('Sport', AppColors.chatBgSand, ChatPattern.sport, strong: true),
  cricket('Cricket', AppColors.chatBgSand, ChatPattern.cricket, strong: true),
  pitch('Pitch', AppColors.chatBgMint, ChatPattern.pitch, strong: true),
  trophies('Trophy', AppColors.chatBgGold, ChatPattern.trophies, strong: true),
  net('Net', AppColors.chatBgTeal, ChatPattern.net),
  jerseys('Kit', AppColors.chatBgDusk, ChatPattern.jerseys, strong: true),
  honeycomb('Hive', AppColors.chatBgTeal, ChatPattern.honeycomb),
  waves('Waves', AppColors.chatBgMint, ChatPattern.waves, strong: true),
  confetti('Confetti', AppColors.chatBgRose, ChatPattern.confetti, strong: true),
  blueprint('Blueprint', AppColors.chatBgDusk, ChatPattern.blueprint),
  arcs('Arcs', AppColors.chatBgSlate, ChatPattern.arcs, strong: true),
  plain('Plain', AppColors.chatBgPlain, ChatPattern.none);

  const ChatBgPreset(this.label, this.ground, this.pattern, {this.strong = false});

  final String label;
  final Color ground;
  final ChatPattern pattern;
  final bool strong;

  static const _prefsKey = 'chat_bg_preset';

  /// The saved preset, or [doodle] when nothing has been chosen or the stored
  /// value no longer maps to a preset (a name dropped in a later version).
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
/// timeline; this widget owns only the ground and the pattern over it.
class ChatBackground extends StatelessWidget {
  final ChatBgPreset preset;
  final Widget child;

  const ChatBackground({required this.preset, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: preset.ground),
        if (preset.pattern != ChatPattern.none)
          Positioned.fill(
            child: CustomPaint(
              painter: _ChatPatternPainter(
                pattern: preset.pattern,
                tint: preset.strong
                    ? AppColors.chatPatternStrong
                    : AppColors.chatPattern,
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// Draws one of [ChatPattern] across the whole surface in [tint].
class _ChatPatternPainter extends CustomPainter {
  final ChatPattern pattern;
  final Color tint;

  const _ChatPatternPainter({required this.pattern, required this.tint});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = tint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = tint..style = PaintingStyle.fill;

    switch (pattern) {
      case ChatPattern.none:
        return;
      case ChatPattern.doodle:
        _doodle(canvas, size, stroke);
      case ChatPattern.sport:
        _sport(canvas, size, stroke);
      case ChatPattern.honeycomb:
        _honeycomb(canvas, size, stroke);
      case ChatPattern.waves:
        _waves(canvas, size, stroke);
      case ChatPattern.confetti:
        _confetti(canvas, size, stroke, fill);
      case ChatPattern.blueprint:
        _blueprint(canvas, size, stroke);
      case ChatPattern.arcs:
        _arcs(canvas, size, stroke);
      case ChatPattern.cricket:
        _cricket(canvas, size, stroke);
      case ChatPattern.pitch:
        _pitch(canvas, size, stroke);
      case ChatPattern.trophies:
        _trophies(canvas, size, stroke, fill);
      case ChatPattern.net:
        _net(canvas, size, stroke);
      case ChatPattern.jerseys:
        _jerseys(canvas, size, stroke, fill);
    }
  }

  // A deterministic generator per grid cell, so the art never changes on repaint.
  math.Random _cellRandom(int r, int c) =>
      math.Random((r * 73856093) ^ (c * 19349663));

  void _doodle(Canvas canvas, Size size, Paint p) {
    const cell = 56.0;
    _forEachCell(size, cell, (r, c, origin) {
      final rnd = _cellRandom(r, c);
      final centre = origin + Offset(rnd.nextDouble() * cell * 0.5, rnd.nextDouble() * cell * 0.5);
      if (((r * 73856093) ^ (c * 19349663)).isEven) {
        canvas.drawCircle(centre, 4.5, p);
      } else {
        canvas.drawLine(centre - const Offset(4, 0), centre + const Offset(4, 0), p);
        canvas.drawLine(centre - const Offset(0, 4), centre + const Offset(0, 4), p);
      }
    });
  }

  /// Sports marks on a jittered grid, rotated a little so the field does not look
  /// stamped: a ball with seams, a goal, a pennant and a whistle-ish ring.
  void _sport(Canvas canvas, Size size, Paint p) {
    const cell = 76.0;
    _forEachCell(size, cell, (r, c, origin) {
      final rnd = _cellRandom(r, c);
      final centre = origin + Offset(rnd.nextDouble() * cell * 0.55, rnd.nextDouble() * cell * 0.55);
      final kind = rnd.nextInt(4);
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate((rnd.nextDouble() - 0.5) * 0.7);
      switch (kind) {
        case 0: // ball: a circle with two seams
          canvas.drawCircle(Offset.zero, 8, p);
          canvas.drawArc(Rect.fromCircle(center: const Offset(-6, 0), radius: 9),
              -0.9, 1.8, false, p);
          canvas.drawArc(Rect.fromCircle(center: const Offset(6, 0), radius: 9),
              math.pi - 0.9, 1.8, false, p);
        case 1: // goal: two posts and a crossbar
          canvas.drawLine(const Offset(-9, 7), const Offset(-9, -6), p);
          canvas.drawLine(const Offset(9, 7), const Offset(9, -6), p);
          canvas.drawLine(const Offset(-9, -6), const Offset(9, -6), p);
        case 2: // pennant on a pole
          canvas.drawLine(const Offset(-7, 9), const Offset(-7, -8), p);
          canvas.drawPath(
            Path()
              ..moveTo(-7, -8)
              ..lineTo(8, -4)
              ..lineTo(-7, 0)
              ..close(),
            p,
          );
        default: // ring with a stub, read as a whistle
          canvas.drawCircle(Offset.zero, 6, p);
          canvas.drawLine(const Offset(5, -4), const Offset(10, -8), p);
      }
      canvas.restore();
    });
  }

  void _honeycomb(Canvas canvas, Size size, Paint p) {
    const radius = 17.0;
    final w = radius * math.sqrt(3);
    final rows = (size.height / (radius * 1.5)).ceil() + 2;
    final cols = (size.width / w).ceil() + 2;
    for (var r = -1; r < rows; r++) {
      for (var c = -1; c < cols; c++) {
        final cx = c * w + (r.isOdd ? w / 2 : 0);
        final cy = r * radius * 1.5;
        final path = Path();
        for (var i = 0; i < 6; i++) {
          final a = math.pi / 180 * (60 * i - 30);
          final x = cx + radius * math.cos(a);
          final y = cy + radius * math.sin(a);
          if (i == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        path.close();
        canvas.drawPath(path, p);
      }
    }
  }

  void _waves(Canvas canvas, Size size, Paint p) {
    const gap = 26.0;
    const amp = 6.0;
    const period = 90.0;
    final rows = (size.height / gap).ceil() + 1;
    for (var r = 0; r < rows; r++) {
      final y = r * gap;
      final path = Path()..moveTo(0, y);
      // Offsetting alternate rows by half a period makes the bands interlock
      // rather than stack into visible columns.
      final phase = r.isEven ? 0.0 : period / 2;
      for (var x = 0.0; x <= size.width; x += 6) {
        path.lineTo(x, y + math.sin((x + phase) / period * 2 * math.pi) * amp);
      }
      canvas.drawPath(path, p);
    }
  }

  void _confetti(Canvas canvas, Size size, Paint stroke, Paint fill) {
    const cell = 44.0;
    _forEachCell(size, cell, (r, c, origin) {
      final rnd = _cellRandom(r, c);
      final centre = origin + Offset(rnd.nextDouble() * cell * 0.7, rnd.nextDouble() * cell * 0.7);
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(rnd.nextDouble() * math.pi);
      switch (rnd.nextInt(3)) {
        case 0:
          canvas.drawLine(const Offset(-5, 0), const Offset(5, 0), stroke);
        case 1:
          canvas.drawPath(
            Path()
              ..moveTo(0, -4)
              ..lineTo(4, 3)
              ..lineTo(-4, 3)
              ..close(),
            stroke,
          );
        default:
          canvas.drawCircle(Offset.zero, 2.2, fill);
      }
      canvas.restore();
    });
  }

  void _blueprint(Canvas canvas, Size size, Paint p) {
    const gap = 22.0;
    final heavy = Paint()
      ..color = p.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final light = Paint()
      ..color = p.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    final cols = (size.width / gap).ceil() + 1;
    final rows = (size.height / gap).ceil() + 1;
    for (var c = 0; c < cols; c++) {
      final x = c * gap;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), c % 4 == 0 ? heavy : light);
    }
    for (var r = 0; r < rows; r++) {
      final y = r * gap;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), r % 4 == 0 ? heavy : light);
    }
  }

  void _arcs(Canvas canvas, Size size, Paint p) {
    const cell = 64.0;
    _forEachCell(size, cell, (r, c, origin) {
      // Each cell holds three nested quarter-arcs, with the corner they spring
      // from rotating per cell so the fans tile without an obvious seam.
      final corner = ((r * 73856093) ^ (c * 19349663)).abs() % 4;
      final start = -math.pi / 2 * corner;
      final pivot = switch (corner) {
        0 => origin,
        1 => origin + const Offset(cell, 0),
        2 => origin + const Offset(cell, cell),
        _ => origin + const Offset(0, cell),
      };
      for (final rad in const [cell * 0.3, cell * 0.55, cell * 0.8]) {
        canvas.drawArc(
          Rect.fromCircle(center: pivot, radius: rad),
          start,
          math.pi / 2,
          false,
          p,
        );
      }
    });
  }

  void _forEachCell(Size size, double cell, void Function(int r, int c, Offset origin) draw) {
    final cols = (size.width / cell).ceil() + 1;
    final rows = (size.height / cell).ceil() + 1;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        draw(r, c, Offset(c * cell, r * cell));
      }
    }
  }

  /// Crossed bats, stumps and a ball — the kit for the sport the app is mostly
  /// booked for.
  void _cricket(Canvas canvas, Size size, Paint p) {
    const cell = 88.0;
    _forEachCell(size, cell, (r, c, origin) {
      final rnd = _cellRandom(r, c);
      final centre =
          origin + Offset(rnd.nextDouble() * cell * 0.5, rnd.nextDouble() * cell * 0.5);
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate((rnd.nextDouble() - 0.5) * 0.5);
      if (rnd.nextBool()) {
        // Three stumps under their bails.
        for (final x in const [-6.0, 0.0, 6.0]) {
          canvas.drawLine(Offset(x, -9), Offset(x, 9), p);
        }
        canvas.drawLine(const Offset(-8, -9), const Offset(8, -9), p);
      } else {
        // A bat — blade and handle — with the ball beside it.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: const Offset(0, 2), width: 9, height: 17),
            const Radius.circular(3),
          ),
          p,
        );
        canvas.drawLine(const Offset(0, -7), const Offset(0, -14), p);
        canvas.drawCircle(const Offset(11, 8), 3.6, p);
      }
      canvas.restore();
    });
  }

  /// Pitch markings: a centre circle with its halfway line, and corner arcs.
  void _pitch(Canvas canvas, Size size, Paint p) {
    const cell = 150.0;
    _forEachCell(size, cell, (r, c, origin) {
      final centre = origin + const Offset(cell / 2, cell / 2);
      canvas.drawCircle(centre, 26, p);
      canvas.drawCircle(centre, 2.5, p);
      canvas.drawLine(
          Offset(origin.dx, centre.dy), Offset(origin.dx + cell, centre.dy), p);
      for (var k = 0; k < 4; k++) {
        final corner = switch (k) {
          0 => origin,
          1 => origin + const Offset(cell, 0),
          2 => origin + const Offset(cell, cell),
          _ => origin + const Offset(0, cell),
        };
        canvas.drawArc(
          Rect.fromCircle(center: corner, radius: 13),
          -math.pi / 2 * k,
          math.pi / 2,
          false,
          p,
        );
      }
    });
  }

  /// Trophies and medals, for the tournament side of the app.
  void _trophies(Canvas canvas, Size size, Paint stroke, Paint fill) {
    const cell = 82.0;
    _forEachCell(size, cell, (r, c, origin) {
      final rnd = _cellRandom(r, c);
      final centre =
          origin + Offset(rnd.nextDouble() * cell * 0.5, rnd.nextDouble() * cell * 0.5);
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      if (rnd.nextBool()) {
        // Cup: bowl, handles, stem, base.
        canvas.drawPath(
          Path()
            ..moveTo(-7, -9)
            ..lineTo(7, -9)
            ..lineTo(5, 1)
            ..lineTo(-5, 1)
            ..close(),
          stroke,
        );
        canvas.drawArc(Rect.fromCircle(center: const Offset(-9, -6), radius: 4),
            math.pi / 2, math.pi, false, stroke);
        canvas.drawArc(Rect.fromCircle(center: const Offset(9, -6), radius: 4),
            -math.pi / 2, math.pi, false, stroke);
        canvas.drawLine(const Offset(0, 1), const Offset(0, 7), stroke);
        canvas.drawLine(const Offset(-6, 8), const Offset(6, 8), stroke);
      } else {
        // Medal on a ribbon.
        canvas.drawLine(const Offset(-5, -11), const Offset(-1, -3), stroke);
        canvas.drawLine(const Offset(5, -11), const Offset(1, -3), stroke);
        canvas.drawCircle(const Offset(0, 4), 7, stroke);
        canvas.drawCircle(const Offset(0, 4), 2, fill);
      }
      canvas.restore();
    });
  }

  /// Court netting: a diagonal mesh crossed by the heavier tape line.
  void _net(Canvas canvas, Size size, Paint p) {
    const gap = 17.0;
    final mesh = Paint()
      ..color = p.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    final tape = Paint()
      ..color = p.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    final span = size.width + size.height;
    for (var d = -size.height; d < span; d += gap) {
      canvas.drawLine(Offset(d, 0), Offset(d + size.height, size.height), mesh);
      canvas.drawLine(Offset(d, size.height), Offset(d + size.height, 0), mesh);
    }
    for (var y = gap * 4; y < size.height; y += gap * 8) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), tape);
    }
  }

  /// Jersey plates — the team sheet, which is what a team chat is.
  void _jerseys(Canvas canvas, Size size, Paint stroke, Paint fill) {
    const cell = 78.0;
    _forEachCell(size, cell, (r, c, origin) {
      final rnd = _cellRandom(r, c);
      final centre =
          origin + Offset(rnd.nextDouble() * cell * 0.5, rnd.nextDouble() * cell * 0.5);
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate((rnd.nextDouble() - 0.5) * 0.4);
      canvas.drawPath(
        Path()
          ..moveTo(-7, -8)
          ..lineTo(-3, -10)
          ..lineTo(3, -10)
          ..lineTo(7, -8)
          ..lineTo(11, -4)
          ..lineTo(8, -1)
          ..lineTo(8, 11)
          ..lineTo(-8, 11)
          ..lineTo(-8, -1)
          ..lineTo(-11, -4)
          ..close(),
        stroke,
      );
      canvas.drawArc(Rect.fromCircle(center: const Offset(0, -10), radius: 3), 0,
          math.pi, false, stroke);
      // A squat bar stands in for the squad number: a real glyph would need a
      // text layout per cell, which is far more cost than the mark is worth.
      canvas.drawRect(
          Rect.fromCenter(center: const Offset(0, 4), width: 5, height: 2), fill);
      canvas.restore();
    });
  }

  @override
  bool shouldRepaint(covariant _ChatPatternPainter old) =>
      old.pattern != pattern || old.tint != tint;
}

/// The preset picker, opened from the thread's overflow menu. Returns the chosen
/// preset (already persisted) or null if dismissed. Each swatch is the real
/// painter at a small size, so what is previewed is exactly what is applied.
Future<ChatBgPreset?> showChatBackgroundPicker(
  BuildContext context,
  ChatBgPreset current,
) {
  return showModalBottomSheet<ChatBgPreset>(
    context: context,
    // Scroll-controlled and height-capped: the preset grid plus its header stands
    // taller than the default sheet (9/16 of the screen) on shorter devices, which
    // overflowed the bottom. Capping at 85% and letting the content scroll removes
    // the overflow on every form factor rather than only the tall ones.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: SingleChildScrollView(
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
            const SizedBox(height: 4),
            const Text('Pick a look for this device',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
      ),
    ),
  );
}
