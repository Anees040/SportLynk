import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../constants/colors.dart';

/// The play control for a voice note: a play/pause button, a scrubbable
/// progress track, and a duration that counts up while playing and shows the
/// clip's length at rest. [MessageBubble] wraps this with the sender label and
/// the time/ticks footer, exactly as it does for text and images.
///
/// The [AudioPlayer] is created lazily on the first play and disposed with the
/// widget, so a screen full of voice notes holds no decoders until one is
/// actually played. A single static [_current] enforces WhatsApp's rule that
/// starting one clip pauses whatever else was playing.
class VoiceNotePlayer extends StatefulWidget {
  /// The hosted clip. Null while the note is still uploading, when [pending] is
  /// true and only the spinner shows.
  final String? url;

  /// The clip's length in milliseconds, measured while recording. Used for the
  /// resting label and the track extent until the decoder reports its own.
  final int durationMs;

  /// True while the optimistic bubble waits for its upload — playback is not
  /// offered yet, a spinner sits where the play button will be.
  final bool pending;

  const VoiceNotePlayer({
    required this.url,
    required this.durationMs,
    this.pending = false,
    super.key,
  });

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  /// The clip currently playing anywhere in the app, so a new play pauses it.
  static _VoiceNotePlayerState? _current;

  AudioPlayer? _player;
  bool _loading = false;
  Duration _position = Duration.zero;
  Duration? _reportedDuration;

  Duration get _total =>
      _reportedDuration ?? Duration(milliseconds: widget.durationMs);

  @override
  void dispose() {
    if (identical(_current, this)) _current = null;
    _player?.dispose();
    super.dispose();
  }

  Future<void> _ensureLoaded() async {
    if (_player != null || widget.url == null) return;
    final p = AudioPlayer();
    _player = p;
    p.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    p.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _reportedDuration = d);
    });
    p.playerStateStream.listen((s) {
      if (!mounted) return;
      // A finished clip resets to the start so the next tap plays it again
      // rather than sitting at the end.
      if (s.processingState == ProcessingState.completed) {
        p.pause();
        p.seek(Duration.zero);
        setState(() => _position = Duration.zero);
      } else {
        setState(() {});
      }
    });
    setState(() => _loading = true);
    try {
      await p.setUrl(widget.url!);
    } catch (_) {
      // A clip that will not load leaves the button tappable; the failure is
      // silent rather than throwing under the bubble.
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle() async {
    if (widget.url == null) return;
    await _ensureLoaded();
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      await p.pause();
    } else {
      if (_current != null && !identical(_current, this)) {
        _current!._player?.pause();
      }
      _current = this;
      await p.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player?.playing ?? false;
    final total = _total;
    final totalMs = total.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, totalMs == 0 ? 1 : totalMs);
    // Count up while there is progress, show the full length at rest.
    final label = _fmt(posMs > 0 ? _position : total);

    return SizedBox(
      width: 214,
      child: Row(
        children: [
          _button(playing),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    activeTrackColor: AppColors.accent,
                    inactiveTrackColor: AppColors.border,
                    thumbColor: AppColors.accent,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: posMs.toDouble(),
                    max: (totalMs == 0 ? 1 : totalMs).toDouble(),
                    onChanged: (widget.url == null || totalMs == 0)
                        ? null
                        : (v) {
                            final to = Duration(milliseconds: v.round());
                            setState(() => _position = to);
                            _player?.seek(to);
                          },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _button(bool playing) {
    if (widget.pending || _loading) {
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
      color: AppColors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _toggle,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(
            playing ? Icons.pause : Icons.play_arrow,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
