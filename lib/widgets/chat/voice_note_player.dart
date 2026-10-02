import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/chat_audio_service.dart';

/// The play control for a voice note: a play/pause button, a waveform that fills
/// as the clip plays and can be tapped to scrub, and a duration that counts up
/// while playing and shows the clip's length at rest. [MessageBubble] wraps this
/// with the sender label and the time/ticks footer, exactly as for text.
///
/// Playback lives in [ChatAudioService] — one player for the whole app — not in
/// this widget, so scrolling the note off-screen no longer stops it or resets the
/// counter. This widget only observes that service and asks it to play, pause or
/// seek the clip identified by [messageId].
class VoiceNotePlayer extends StatelessWidget {
  /// Identifies this clip in the shared player, so the right bubble shows the
  /// live position while every other one rests.
  final String messageId;

  /// The hosted clip. Null while the note is still uploading ([pending]).
  final String? url;

  /// The clip's length in milliseconds, measured while recording. Used for the
  /// resting label and the track extent until the decoder reports its own.
  final int durationMs;

  /// Amplitude samples (0..1) captured while recording. Empty for a clip recorded
  /// before samples were sent — the track then falls back to a flat bar.
  final List<double> waveform;

  /// True while the optimistic bubble waits for its upload — a spinner sits where
  /// the play button will be, and playback is not offered yet.
  final bool pending;

  const VoiceNotePlayer({
    required this.messageId,
    required this.url,
    required this.durationMs,
    this.waveform = const [],
    this.pending = false,
    super.key,
  });

  static const double _trackHeight = 28;

  @override
  Widget build(BuildContext context) {
    final audio = ChatAudioService.instance;
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final current = audio.isCurrent(messageId);
        final playing = current && audio.playing;
        final loading = pending || (current && audio.loading);
        final failed = audio.errorId == messageId;

        final total = (current && (audio.duration?.inMilliseconds ?? 0) > 0)
            ? audio.duration!
            : Duration(milliseconds: durationMs);
        final totalMs = total.inMilliseconds <= 0 ? 1 : total.inMilliseconds;
        final posMs = current ? audio.position.inMilliseconds.clamp(0, totalMs) : 0;
        final frac = (posMs / totalMs).clamp(0.0, 1.0);
        final label = failed
            ? 'Tap to retry'
            : _fmt(current && posMs > 0 ? Duration(milliseconds: posMs) : total);

        return SizedBox(
          width: 232,
          child: Row(
            children: [
              _button(loading, playing, failed),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _track(frac, totalMs),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(label,
                            style: TextStyle(
                                fontSize: 11,
                                color: failed
                                    ? AppColors.error
                                    : AppColors.textSecondary)),
                        const Spacer(),
                        const Icon(Icons.mic, size: 13, color: AppColors.textSecondary),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _button(bool loading, bool playing, bool failed) {
    if (loading) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Padding(
          padding: EdgeInsets.all(9),
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.accent),
        ),
      );
    }
    return Material(
      color: failed ? AppColors.error : AppColors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: url == null ? null : () => ChatAudioService.instance.toggle(messageId, url!),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(
            failed ? Icons.refresh : (playing ? Icons.pause : Icons.play_arrow),
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  /// The waveform (or a flat bar when no samples were captured), filled up to the
  /// play position. A tap scrubs the clip while it is the current one.
  Widget _track(double frac, int totalMs) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (url == null || width <= 0)
              ? null
              : (d) {
                  final to = Duration(
                      milliseconds:
                          ((d.localPosition.dx / width).clamp(0.0, 1.0) * totalMs).round());
                  ChatAudioService.instance.seek(messageId, to);
                },
          child: SizedBox(
            height: _trackHeight,
            width: double.infinity,
            child: waveform.isEmpty ? _flatBar(frac) : _bars(frac),
          ),
        );
      },
    );
  }

  Widget _bars(double frac) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(waveform.length, (i) {
        final filled = waveform.isEmpty ? false : (i / waveform.length) <= frac;
        final h = 4 + waveform[i].clamp(0.0, 1.0) * (_trackHeight - 4);
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 0.7),
            child: Container(
              height: h,
              decoration: BoxDecoration(
                color: filled ? AppColors.primary : AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _flatBar(double frac) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Container(height: 4, color: AppColors.border),
          FractionallySizedBox(
            widthFactor: frac,
            child: Container(height: 4, color: AppColors.primary),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
