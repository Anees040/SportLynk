// VoiceNotePlayer: the states a voice note has to show, and the waveform maths.
//
// A voice note is the one bubble whose control is never inert: it is always
// doing one of four things, and each needs a different action, so the states are
// pinned here rather than left to the eye. Uploading shows a spinner and offers
// nothing to play. A send that never produced a hosted clip turns the button
// into a re-send, because retrying playback of a clip that does not exist is the
// trap that made a failed send look like a broken player. A clip that loaded but
// would not decode keeps its own error. A clip that is simply at rest shows its
// length, and only a length — the elapsed counter belongs to the clip that is
// actually playing.
//
// The waveform is resampled to a fixed bar count so a one-second note and a
// five-minute note both read as a full shape; [resampleWaveform] is the pure
// core of that, and its endpoints and range are the part worth pinning, since a
// drifted interpolation is invisible until a real clip looks wrong.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/chat/voice_note_player.dart';

import '../widget_harness.dart';

void main() {
  group('resampleWaveform', () {
    test('an empty source draws nothing, whatever the bar count', () {
      expect(resampleWaveform(const [], 10), isEmpty);
      expect(resampleWaveform(const [], 0), isEmpty);
    });

    test('a single sample fills every bar with that value', () {
      expect(resampleWaveform(const [0.5], 4), [0.5, 0.5, 0.5, 0.5]);
    });

    test('the first and last bars are the source endpoints', () {
      final up = resampleWaveform(const [0.0, 1.0], 3);
      expect(up.first, closeTo(0.0, 1e-9));
      expect(up[1], closeTo(0.5, 1e-9));
      expect(up.last, closeTo(1.0, 1e-9));

      final down = resampleWaveform(const [0.0, 0.25, 0.75, 1.0], 2);
      expect(down, [closeTo(0.0, 1e-9), closeTo(1.0, 1e-9)]);
    });

    test('the output length is exactly the requested bar count', () {
      final src = List<double>.generate(40, (i) => (i % 5) / 5);
      expect(resampleWaveform(src, 20).length, 20);
      expect(resampleWaveform(src, 64).length, 64);
    });

    test('interpolation stays within the source range', () {
      final src = List<double>.generate(13, (i) => (i.isEven) ? 0.1 : 0.9);
      for (final v in resampleWaveform(src, 37)) {
        expect(v, inInclusiveRange(0.1, 0.9));
      }
    });
  });

  group('VoiceNotePlayer states', () {
    Future<void> pump(
      WidgetTester tester, {
      String? url,
      int durationMs = 5000,
      List<double> waveform = const [0.2, 0.8, 0.4, 1.0, 0.3],
      bool pending = false,
      bool failedToSend = false,
      String? sendError,
      VoidCallback? onRetrySend,
    }) =>
        pumpApp(
          tester,
          Scaffold(
            body: Center(
              child: VoiceNotePlayer(
                messageId: 'm1',
                url: url,
                durationMs: durationMs,
                waveform: waveform,
                pending: pending,
                failedToSend: failedToSend,
                sendError: sendError,
                onRetrySend: onRetrySend,
              ),
            ),
          ),
        );

    testWidgets('a loaded, resting clip shows play, its length, and a waveform',
        (tester) async {
      useDeviceSurface(tester);
      await pump(tester, url: 'https://res.cloudinary.com/x/video/upload/v1/a.mp4');

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      // At rest the label is the clip's length, not an elapsed 0:00.
      expect(find.text('0:05'), findsOneWidget);
      // The waveform is painted, and the resting trailing glyph is the mic.
      expect(
        find.descendant(
            of: find.byType(VoiceNotePlayer), matching: find.byType(CustomPaint)),
        findsWidgets,
      );
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('an empty waveform still lays out', (tester) async {
      useDeviceSurface(tester);
      await pump(tester,
          url: 'https://res.cloudinary.com/x/video/upload/v1/a.mp4',
          waveform: const []);
      expect(find.byType(VoiceNotePlayer), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('an uploading clip shows a spinner and no play control',
        (tester) async {
      useDeviceSurface(tester);
      await pump(tester, url: null, pending: true);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('a failed send offers a re-send that fires the callback',
        (tester) async {
      useDeviceSurface(tester);
      var retried = false;
      await pump(tester,
          url: null,
          failedToSend: true,
          sendError: 'Upload rejected',
          onRetrySend: () => retried = true);

      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.textContaining('Not sent'), findsOneWidget);
      expect(find.textContaining('Upload rejected'), findsOneWidget);

      await tester.tap(find.byType(InkWell));
      expect(retried, isTrue);
    });
  });
}
