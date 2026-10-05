import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/chat_audio_service.dart';

/// Resample [src] to exactly [count] evenly spaced values by linear
/// interpolation, so a waveform drawn from few captured samples (a short clip)
/// and one drawn from many (a long clip) both fill a fixed number of bars — the
/// way WhatsApp renders a consistent bar count regardless of length. Returns an
/// empty list when there is nothing to draw; the painter then shows a flat
/// resting track rather than inventing a shape.
///
/// Pure and side-effect free so it can be unit tested without a player.
List<double> resampleWaveform(List<double> src, int count) {
  if (src.isEmpty || count <= 0) return const [];
  if (src.length == count) return List<double>.of(src);
  if (src.length == 1) return List<double>.filled(count, src.first);
  final out = List<double>.filled(count, 0.0);
  final lastSrc = src.length - 1;
  final denom = count == 1 ? 1 : count - 1;
  for (var i = 0; i < count; i++) {
    final t = i * lastSrc / denom; // position in source space, 0..lastSrc
    final lo = t.floor();
    final hi = math.min(lo + 1, lastSrc);
    final f = t - lo;
    out[i] = src[lo] * (1 - f) + src[hi] * f;
  }
  return out;
}

/// The play control for a voice note: a play/pause button, a WhatsApp-style
/// waveform that fills as the clip plays and can be tapped or dragged to scrub, a
/// duration that counts up while playing and shows the clip's length at rest, and
/// — while this clip is the active one — a speed control cycling 1x / 1.5x / 2x.
/// [MessageBubble] wraps this with the sender label and the time/ticks footer,
/// exactly as for text.
///
/// Playback lives in [ChatAudioService] — one player for the whole app — not in
/// this widget, so scrolling the note off-screen no longer stops it or resets the
/// counter. This widget observes that service and asks it to play, pause, seek or
/// change speed for the clip identified by [messageId]. Only the drag position is
/// held locally, so a scrub follows the finger without the player's own position
/// stream fighting it.
///
/// Three failure states are kept distinct, because they need different actions
/// and conflating them is what made a broken note look like a broken player:
///   • [pending] — the clip is still uploading; a spinner, nothing to play yet.
///   • [url] is null and not pending — the SEND failed, so there is no hosted clip
///     at all. The button re-sends via [onRetrySend]; it must never be inert.
///   • the service reports a load error for this id — the clip exists but would
///     not play. The button retries playback and the reason is shown.
class VoiceNotePlayer extends StatefulWidget {
  /// Identifies this clip in the shared player, so the right bubble shows the
  /// live position while every other one rests.
  final String messageId;

  /// The hosted clip. Null while the note is uploading, and also when the send
  /// failed outright.
  final String? url;

  /// The clip's length in milliseconds, measured while recording. Used for the
  /// resting label and the track extent until the decoder reports its own.
  final int durationMs;

  /// Amplitude samples (0..1) captured while recording. Empty for a clip recorded
  /// before samples were sent — the track then falls back to a flat resting bar.
  final List<double> waveform;

  /// True while the optimistic bubble waits for its upload.
  final bool pending;

  /// True when the send itself failed, so the only sensible action is to send the
  /// recording again.
  final bool failedToSend;

  /// Why the send failed, when the caller knows — Cloudinary's own refusal, for
  /// instance. Shown in place of the duration so the cause is visible on the
  /// bubble rather than only in a log.
  final String? sendError;

  /// Re-send a voice note whose upload or send failed.
  final VoidCallback? onRetrySend;

  const VoiceNotePlayer({
    required this.messageId,
    required this.url,
    required this.durationMs,
    this.waveform = const [],
    this.pending = false,
    this.failedToSend = false,
    this.sendError,
    this.onRetrySend,
    super.key,
  });

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  // While the user is dragging the waveform, the rendered position follows the
  // finger from here; the shared player is seeked once on release so a fast drag
  // does not flood it with seeks. Null whenever a drag is not in progress.
  double? _dragFrac;

  static const double _trackHeight = 30;
  static const double _controlSize = 40;

  @override
  Widget build(BuildContext context) {
    final audio = ChatAudioService.instance;
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final current = audio.isCurrent(widget.messageId);
        final playing = current && audio.playing;
        final loading = widget.pending || (current && audio.loading);
        final playFailed = audio.errorId == widget.messageId;
        // No hosted clip and not uploading: the send never landed.
        final sendFailed = widget.failedToSend || (!widget.pending && widget.url == null);
        final bad = sendFailed || playFailed;

        // How long the clip runs. The length measured while recording is the
        // trustworthy one; the decoder's is accepted only when it is at least as
        // long. A transcoded clip whose header the player misreads reports a
        // near-zero length, and taking that verbatim collapsed the track — the
        // counter read 0:00 the moment play was tapped and the waveform jumped to
        // looking half-played, while the same note showed its real length at rest.
        final recorded = Duration(milliseconds: widget.durationMs);
        final reported = current ? audio.duration : null;
        final total =
            (reported != null && reported > recorded) ? reported : recorded;
        final totalMs = total.inMilliseconds <= 0 ? 1 : total.inMilliseconds;

        // Progress fraction: the drag position while scrubbing, otherwise the
        // player's position for the active clip, otherwise empty.
        final playFrac = current
            ? (audio.position.inMilliseconds / totalMs).clamp(0.0, 1.0)
            : 0.0;
        final frac = _dragFrac ?? playFrac;
        final posMs = (frac * totalMs).round();

        final String label;
        if (sendFailed) {
          label = widget.sendError == null
              ? 'Not sent · tap to send again'
              : 'Not sent · ${widget.sendError}';
        } else if (playFailed) {
          label = audio.errorText ?? 'Could not play';
        } else if (widget.pending) {
          label = 'Sending…';
        } else if (current && (playing || _dragFrac != null || posMs > 0)) {
          label = _fmt(Duration(milliseconds: posMs));
        } else {
          label = _fmt(total);
        }

        return SizedBox(
          width: 236,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _button(loading, playing, bad, sendFailed),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _track(frac, totalMs, sendFailed, current),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: bad ? AppColors.error : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _trailing(current: current, bad: bad),
            ],
          ),
        );
      },
    );
  }

  /// What a tap on the control does, in priority order: re-send a failed send,
  /// retry a failed load, or play/pause. Null only while uploading — every other
  /// state is actionable, so the button is never a dead circle.
  VoidCallback? _action(bool sendFailed) {
    if (widget.pending) return null;
    if (sendFailed) return widget.onRetrySend;
    final u = widget.url;
    if (u == null) return widget.onRetrySend;
    return () => ChatAudioService.instance.toggle(widget.messageId, u);
  }

  Widget _button(bool loading, bool playing, bool bad, bool sendFailed) {
    if (loading) {
      return const SizedBox(
        width: _controlSize,
        height: _controlSize,
        child: Padding(
          padding: EdgeInsets.all(9),
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.accent),
        ),
      );
    }
    final IconData icon = bad ? Icons.refresh : (playing ? Icons.pause : Icons.play_arrow);
    return Material(
      color: bad ? AppColors.error : AppColors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _action(sendFailed),
        child: Semantics(
          button: true,
          label: bad
              ? 'Retry voice message'
              : (playing ? 'Pause voice message' : 'Play voice message'),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(icon, color: AppColors.white, size: 22),
          ),
        ),
      ),
    );
  }

  /// The far-right control: the speed pill while this clip is the active one, a
  /// resting mic glyph otherwise. The pill's hit area matches the play button
  /// (40x40) so it is comfortably tappable though the visible pill is smaller.
  Widget _trailing({required bool current, required bool bad}) {
    final showSpeed = current && !bad && !widget.pending && widget.url != null;
    if (!showSpeed) {
      return SizedBox(
        width: 30,
        height: _controlSize,
        child: Center(
          child: Icon(Icons.mic,
              size: 15, color: bad ? AppColors.error : AppColors.textSecondary),
        ),
      );
    }
    final audio = ChatAudioService.instance;
    final text = _speedLabel(audio.speed);
    return Semantics(
      button: true,
      label: 'Playback speed $text, tap to change',
      child: SizedBox(
        width: _controlSize,
        height: _controlSize,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: audio.cycleSpeed,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The waveform, filled up to the play position, with a draggable thumb while
  /// this clip is the active one. A tap seeks (when active) or starts the clip
  /// (when not); a horizontal drag scrubs. The drag recognizer lives below the
  /// row's swipe-to-reply [Dismissible] in the tree, so a drag that begins on the
  /// waveform scrubs rather than triggering a reply, while a drag elsewhere on the
  /// bubble still opens a reply.
  Widget _track(double frac, int totalMs, bool sendFailed, bool current) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hasUrl = widget.url != null && !sendFailed && width > 0;
        final canScrub = hasUrl && current;

        Duration at(double dx) => Duration(
            milliseconds: ((dx / width).clamp(0.0, 1.0) * totalMs).round());

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: !hasUrl
              ? null
              : (d) {
                  if (current) {
                    ChatAudioService.instance.seek(widget.messageId, at(d.localPosition.dx));
                  }
                },
          // A clean tap on a clip that is not yet active starts it, like the play
          // button. Kept on onTap (not onTapDown) so beginning a drag does not
          // also start playback.
          onTap: (!hasUrl || current)
              ? null
              : () {
                  final u = widget.url;
                  if (u != null) ChatAudioService.instance.toggle(widget.messageId, u);
                },
          onHorizontalDragStart: !canScrub
              ? null
              : (d) => setState(
                  () => _dragFrac = (d.localPosition.dx / width).clamp(0.0, 1.0)),
          onHorizontalDragUpdate: !canScrub
              ? null
              : (d) => setState(
                  () => _dragFrac = (d.localPosition.dx / width).clamp(0.0, 1.0)),
          onHorizontalDragEnd: !canScrub
              ? null
              : (_) {
                  final f = _dragFrac;
                  if (f != null) {
                    ChatAudioService.instance.seek(
                        widget.messageId, Duration(milliseconds: (f * totalMs).round()));
                  }
                  setState(() => _dragFrac = null);
                },
          onHorizontalDragCancel:
              !canScrub ? null : () => setState(() => _dragFrac = null),
          child: SizedBox(
            height: _trackHeight,
            width: double.infinity,
            child: CustomPaint(
              size: Size.infinite,
              painter: _WaveformPainter(
                samples: widget.waveform,
                progress: frac,
                played: sendFailed ? AppColors.error : AppColors.primary,
                unplayed: AppColors.border,
                showThumb: canScrub,
              ),
            ),
          ),
        );
      },
    );
  }

  String _speedLabel(double s) {
    if (s == 1.0) return '1x';
    if (s == 2.0) return '2x';
    // 1.5 and any future fractional value: one decimal, no trailing zero.
    final str = s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toString();
    return '${str}x';
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Paints the voice-note waveform: fixed-thickness, round-capped bars whose
/// heights follow the recorded amplitude, split at the play head into a played
/// and an unplayed colour, with a round thumb on the head while the clip is
/// active. The stored samples are resampled to a bar count that fits the width,
/// so every note reads as a full waveform regardless of length.
class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.samples,
    required this.progress,
    required this.played,
    required this.unplayed,
    required this.showThumb,
  });

  final List<double> samples;
  final double progress; // 0..1
  final Color played;
  final Color unplayed;
  final bool showThumb;

  static const double _barThickness = 3;
  static const double _slot = 6; // bar plus an equal gap
  static const double _minBarFrac = 0.18; // a quiet sample still shows a nub
  static const double _thumbRadius = 6;

  @override
  void paint(Canvas canvas, Size size) {
    // Inset so a round cap, and the thumb circle when shown, are never clipped
    // at the track's ends.
    final pad = showThumb ? _thumbRadius + 2 : _barThickness / 2;
    final usable = math.max(1.0, size.width - pad * 2);
    final centerY = size.height / 2;
    final maxBarHeight = math.max(_barThickness, size.height - _barThickness);

    final barCount = math.max(1, (usable / _slot).floor());
    final bars = resampleWaveform(samples, barCount);
    final step = barCount == 1 ? 0.0 : usable / (barCount - 1);
    final thumbX = pad + usable * progress.clamp(0.0, 1.0);

    final paint = Paint()
      ..strokeWidth = _barThickness
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < barCount; i++) {
      final x = pad + (barCount == 1 ? usable / 2 : step * i);
      // An empty waveform draws uniform short bars — a neutral resting track,
      // not fabricated amplitudes (every bar identical reads as "no data").
      final amp = bars.isEmpty ? 0.0 : bars[i].clamp(0.0, 1.0);
      final h = (_minBarFrac + amp * (1 - _minBarFrac)) * maxBarHeight;
      paint.color = x <= thumbX ? played : unplayed;
      canvas.drawLine(
          Offset(x, centerY - h / 2), Offset(x, centerY + h / 2), paint);
    }

    if (showThumb) {
      canvas.drawCircle(Offset(thumbX, centerY), _thumbRadius + 1.5,
          Paint()..color = AppColors.white);
      canvas.drawCircle(Offset(thumbX, centerY), _thumbRadius,
          Paint()..color = played);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress ||
      old.showThumb != showThumb ||
      old.played != played ||
      old.unplayed != unplayed ||
      !identical(old.samples, samples);
}
