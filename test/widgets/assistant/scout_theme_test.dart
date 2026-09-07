// ScoutTheme: the assistant's dark palette, and the two lookups that carry meaning.
//
// Most of this class is constants, and a test that restates a constant is worth
// nothing. What is asserted here is the part where a wrong answer misleads a user
// rather than merely looking wrong.
//
// `sourceTone` is the provenance pill. The whole point of showing provenance is that
// "read from the database just now" and "a trained model guessed" are never mistaken
// for each other at a glance, so the seven sources must map to seven distinct colours
// and seven distinct glyphs; two sources sharing either would defeat the pill while
// still rendering perfectly.
//
// `pctTone` bands a match percentage, and its thresholds are deliberately the same
// 80/55/30 that `CompetitivenessTone` uses on the match screens. That parity is the
// contract worth pinning across the two files: a 62% that reads "competitive" in the
// match list and "fair" in Scout would make the assistant look like it disagreed with
// the app it is embedded in. The test below walks every percentage and compares band
// boundaries rather than labels, which is what the two are allowed to differ on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';
import 'package:sportlynk/widgets/match_widgets.dart';

void main() {
  group('the provenance pill', () {
    test('every source is distinguishable from every other', () {
      final tones = ScoutSource.values.map(ScoutTheme.sourceTone).toList();
      expect(tones.map((t) => t.color).toSet().length, ScoutSource.values.length,
          reason: 'two sources sharing a colour defeat the pill');
      expect(tones.map((t) => t.icon).toSet().length, ScoutSource.values.length,
          reason: 'the glyph is the half that survives a colourblind reading');
    });

    // Live data is the only source that means "true as of this second"; the bolt and
    // its blue are what a user learns to look for.
    test('live data is the bolt, and an unrecognised source is muted', () {
      expect(ScoutTheme.sourceTone(ScoutSource.live).icon, Icons.bolt_rounded);
      expect(ScoutTheme.sourceTone(ScoutSource.unknown).color, ScoutTheme.inkFaint);
      expect(ScoutTheme.sourceTone(ScoutSource.unknown).icon, Icons.help_outline_rounded);
    });
  });

  group('the match-percentage bands', () {
    test('an absent percentage is unranked rather than nought', () {
      expect(ScoutTheme.pctTone(null).label, 'Unranked');
      expect(ScoutTheme.pctTone(null).color, ScoutTheme.inkFaint);
    });

    test('each threshold is exact', () {
      expect(ScoutTheme.pctTone(100).label, 'Great fit');
      expect(ScoutTheme.pctTone(80).label, 'Great fit');
      expect(ScoutTheme.pctTone(79).label, 'Good fit');
      expect(ScoutTheme.pctTone(55).label, 'Good fit');
      expect(ScoutTheme.pctTone(54).label, 'Fair fit');
      expect(ScoutTheme.pctTone(30).label, 'Fair fit');
      expect(ScoutTheme.pctTone(29).label, 'Weak fit');
      expect(ScoutTheme.pctTone(0).label, 'Weak fit');
    });

    test('each band has its own colour', () {
      final colors = [100, 60, 40, 10, null]
          .map((p) => ScoutTheme.pctTone(p).color)
          .toSet();
      expect(colors.length, 5);
    });

    // The labels differ by design; the bands must not.
    test('the bands agree with the match screens at every percentage', () {
      String band(String label) => switch (label) {
            'Great fit' || 'Evenly matched' => 'top',
            'Good fit' || 'Competitive' => 'upper',
            'Fair fit' || 'Uphill' => 'lower',
            'Weak fit' || 'Mismatch' => 'bottom',
            _ => 'none',
          };
      for (var pct = 0; pct <= 100; pct++) {
        expect(band(ScoutTheme.pctTone(pct).label),
            band(CompetitivenessTone.of(pct).label),
            reason: '$pct% must sit in the same band on both screens');
      }
      expect(band(ScoutTheme.pctTone(null).label),
          band(CompetitivenessTone.of(null).label));
    });
  });

  group('the card shell', () {
    test('an untinted card is the flat card colour with the plain line', () {
      final d = ScoutTheme.cardDecoration();
      expect(d.color, ScoutTheme.card);
      expect(d.border, Border.all(color: ScoutTheme.line));
      expect(d.borderRadius, BorderRadius.circular(ScoutTheme.cardRadius));
    });

    // The confirm card is the only tinted one, and the wash has to stay faint: the
    // border carries the signal, not the fill.
    test('a tint washes the fill and colours the border without replacing either', () {
      final d = ScoutTheme.cardDecoration(tint: ScoutTheme.money);
      expect(d.color, isNot(ScoutTheme.card));
      expect(d.color, isNot(ScoutTheme.money));
      expect(d.border, Border.all(color: ScoutTheme.money.withValues(alpha: 0.45)));
    });
  });

  group('the page and the inherited theme', () {
    test('the glow fades into flat canvas by a third of the way down', () {
      final g = ScoutTheme.pageDecoration.gradient! as LinearGradient;
      expect(g.colors, [ScoutTheme.canvasGlow, ScoutTheme.canvas, ScoutTheme.canvas]);
      expect(g.stops, [0, 0.34, 1]);
    });

    // A sheet, a dialog and a snack bar inside the assistant must inherit the dark
    // surface rather than each carrying its own overrides.
    testWidgets('the assistant theme is dark on every surface a screen opens',
        (tester) async {
      final t = ScoutTheme.data();
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, ScoutTheme.canvas);
      expect(t.colorScheme.primary, ScoutTheme.accent);
      expect(t.colorScheme.surface, ScoutTheme.card);
      expect(t.colorScheme.error, ScoutTheme.danger);
      expect(t.bottomSheetTheme.backgroundColor, isNot(Colors.white));
      expect(t.bottomSheetTheme.surfaceTintColor, Colors.transparent);
      expect(t.dialogTheme.surfaceTintColor, Colors.transparent);
      expect(t.textTheme.bodyMedium!.color, ScoutTheme.ink);
    });
  });
}
