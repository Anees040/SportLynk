// ScoutTheme: the assistant's two-brightness palette, and the two lookups that
// carry meaning.
//
// Most of this class is colour constants, and a test that restates a constant is
// worth nothing. What is asserted here is the part where a wrong answer misleads a
// user rather than merely looking wrong.
//
// `sourceTone` is the provenance pill. The whole point of showing provenance is that
// "read from the database just now" and "a trained model guessed" are never mistaken
// for each other at a glance, so the seven sources must map to seven distinct colours
// and seven distinct glyphs in each brightness; two sources sharing either would
// defeat the pill while still rendering perfectly.
//
// `pctTone` bands a match percentage, and its thresholds are deliberately the same
// 80/55/30 that `CompetitivenessTone` uses on the match screens. That parity is the
// contract worth pinning across the two files: a 62% that reads "competitive" in the
// match list and "fair" in Scout would make the assistant look like it disagreed with
// the app it is embedded in. The test below walks every percentage and compares band
// boundaries rather than labels, which is what the two are allowed to differ on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';
import 'package:sportlynk/widgets/match_widgets.dart';

void main() {
  // `ScoutTheme.data` builds a Poppins text theme, and `google_fonts` fetches a
  // missing face over HTTP on first use. This file exercises `data` without the
  // widget harness that would otherwise disable that, so it is disabled here — the
  // text lays out in the fallback face, which none of these assertions depend on.
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('the provenance pill', () {
    // Both palettes have to keep the seven sources apart: the pill renders in
    // whichever brightness the phone is in, and a collision in either is a defeat.
    for (final t in [ScoutTheme.light, ScoutTheme.dark]) {
      final which = t.isDark ? 'dark' : 'light';
      test('every source is distinguishable from every other ($which)', () {
        final tones = ScoutSource.values.map(t.sourceTone).toList();
        expect(tones.map((tone) => tone.color).toSet().length,
            ScoutSource.values.length,
            reason: 'two sources sharing a colour defeat the pill');
        expect(tones.map((tone) => tone.icon).toSet().length,
            ScoutSource.values.length,
            reason: 'the glyph is the half that survives a colourblind reading');
      });
    }

    // Live data is the only source that means "true as of this second"; the bolt is
    // what a user learns to look for, in either brightness.
    test('live data is the bolt, and an unrecognised source is muted', () {
      for (final t in [ScoutTheme.light, ScoutTheme.dark]) {
        expect(t.sourceTone(ScoutSource.live).icon, Icons.bolt_rounded);
        expect(t.sourceTone(ScoutSource.unknown).color, t.inkFaint);
        expect(t.sourceTone(ScoutSource.unknown).icon,
            Icons.help_outline_rounded);
      }
    });
  });

  group('the match-percentage bands', () {
    test('an absent percentage is unranked rather than nought', () {
      expect(ScoutTheme.light.pctTone(null).label, 'Unranked');
      expect(ScoutTheme.light.pctTone(null).color, ScoutTheme.light.inkFaint);
    });

    test('each threshold is exact', () {
      final t = ScoutTheme.light;
      expect(t.pctTone(100).label, 'Great fit');
      expect(t.pctTone(80).label, 'Great fit');
      expect(t.pctTone(79).label, 'Good fit');
      expect(t.pctTone(55).label, 'Good fit');
      expect(t.pctTone(54).label, 'Fair fit');
      expect(t.pctTone(30).label, 'Fair fit');
      expect(t.pctTone(29).label, 'Weak fit');
      expect(t.pctTone(0).label, 'Weak fit');
    });

    test('each band has its own colour', () {
      final colors = [100, 60, 40, 10, null]
          .map((p) => ScoutTheme.light.pctTone(p).color)
          .toSet();
      expect(colors.length, 5);
    });

    // The labels differ by design; the bands must not.
    test('the bands agree with the match screens at every percentage', () {
      final t = ScoutTheme.light;
      String band(String label) => switch (label) {
            'Great fit' || 'Evenly matched' => 'top',
            'Good fit' || 'Competitive' => 'upper',
            'Fair fit' || 'Uphill' => 'lower',
            'Weak fit' || 'Mismatch' => 'bottom',
            _ => 'none',
          };
      for (var pct = 0; pct <= 100; pct++) {
        expect(band(t.pctTone(pct).label),
            band(CompetitivenessTone.of(pct).label),
            reason: '$pct% must sit in the same band on both screens');
      }
      expect(band(t.pctTone(null).label),
          band(CompetitivenessTone.of(null).label));
    });
  });

  group('the card shell', () {
    test('an untinted card is the flat card colour with the plain line', () {
      final t = ScoutTheme.light;
      final d = t.cardDecoration();
      expect(d.color, t.card);
      expect(d.border, Border.all(color: t.line));
      expect(d.borderRadius, BorderRadius.circular(ScoutTheme.cardRadius));
    });

    // The confirm card is the only tinted one, and the wash has to stay faint: the
    // border carries the signal, not the fill.
    test('a tint washes the fill and colours the border without replacing either',
        () {
      final t = ScoutTheme.light;
      final d = t.cardDecoration(tint: t.money);
      expect(d.color, isNot(t.card));
      expect(d.color, isNot(t.money));
      expect(d.border, Border.all(color: t.money.withValues(alpha: 0.45)));
    });
  });

  group('the inherited theme', () {
    // The canvas is flat in both brightnesses — the first build's top-of-screen
    // green glow is gone, so the scaffold takes a solid colour and no gradient.
    // Pumped rather than asserted directly: `data` builds a Poppins text theme
    // whose font loader raises asynchronously outside a widget binding.
    testWidgets('the scaffold is a flat colour, not a gradient', (tester) async {
      expect(ScoutTheme.data(Brightness.light).scaffoldBackgroundColor,
          ScoutTheme.light.canvas);
      expect(ScoutTheme.data(Brightness.dark).scaffoldBackgroundColor,
          ScoutTheme.dark.canvas);
    });

    // A sheet, a dialog and a snack bar inside the assistant must inherit the
    // screen's surface rather than each carrying its own overrides. The palette
    // follows the brightness the screen is handed.
    testWidgets('the assistant theme carries the palette for the given brightness',
        (tester) async {
      for (final brightness in Brightness.values) {
        final t = brightness == Brightness.dark
            ? ScoutTheme.dark
            : ScoutTheme.light;
        final data = ScoutTheme.data(brightness);
        expect(data.brightness, brightness);
        expect(data.scaffoldBackgroundColor, t.canvas);
        expect(data.colorScheme.primary, t.accent);
        expect(data.colorScheme.surface, t.card);
        expect(data.colorScheme.error, t.danger);
        expect(data.bottomSheetTheme.backgroundColor, t.card);
        expect(data.bottomSheetTheme.surfaceTintColor, Colors.transparent);
        expect(data.dialogTheme.surfaceTintColor, Colors.transparent);
        expect(data.textTheme.bodyMedium!.color, t.ink);
      }
    });
  });
}
