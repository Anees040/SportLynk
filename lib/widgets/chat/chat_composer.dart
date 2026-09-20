import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../constants/colors.dart';

/// The message input bar. Owns three subtleties that make chat feel right:
///   • the send button only appears once there's something to send;
///   • when the field is empty a hold-to-record mic takes its place, so a voice
///     note is one gesture — hold to record, release to send, slide to cancel;
///   • typing is announced on the first keystroke and auto-stopped after a short
///     lull, so the other side sees "typing…" appear and fade like WhatsApp —
///     without a socket event per character.
///
/// [onSendAudio] is optional: without it the mic is not offered and the bar
/// behaves exactly as a text-and-photo composer (the shape the widget tests
/// exercise). Recording is unavailable on web — the browser cannot hand back a
/// file the Cloudinary uploader can read — so the mic there explains itself
/// rather than failing silently.
class ChatComposer extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String text) onSend;
  final VoidCallback onPickImage;
  final void Function(bool isTyping) onTyping;

  /// Called with the recorded clip's path, its length in milliseconds, and its
  /// mime once a voice note is released. Null disables voice notes entirely.
  final void Function(String path, int durationMs, String mime)? onSendAudio;

  /// Optional external focus, so the screen can put the caret in the field when a
  /// reply is started. Null keeps the field's own default focus behaviour.
  final FocusNode? focusNode;

  final bool enabled;

  const ChatComposer({
    required this.controller,
    required this.onSend,
    required this.onPickImage,
    required this.onTyping,
    this.onSendAudio,
    this.focusNode,
    this.enabled = true,
    super.key,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  // Beyond this drag to the left, releasing cancels instead of sending.
  static const _cancelThreshold = 80.0;
  // A recording shorter than this was a mis-tap, not a message.
  static const _minMs = 1000;
  // Cloudinary's free tier is finite; a voice note is not a podcast.
  static const _maxRecording = Duration(minutes: 5);

  Timer? _stopTimer;
  bool _typing = false;
  bool _hasText = false;

  AudioRecorder? _recorder;
  bool _recording = false;
  bool _armed = false; // finger still down (the press may outlive the async start)
  bool _cancelHint = false;
  Timer? _ticker;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;

  bool get _voiceEnabled => widget.onSendAudio != null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _stopTimer?.cancel();
    _ticker?.cancel();
    _recorder?.dispose();
    super.dispose();
  }

  void _onChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);

    if (has) {
      if (!_typing) {
        _typing = true;
        widget.onTyping(true);
      }
      _stopTimer?.cancel();
      _stopTimer = Timer(const Duration(milliseconds: 1800), _stopTyping);
    } else {
      _stopTyping();
    }
  }

  void _stopTyping() {
    _stopTimer?.cancel();
    if (_typing) {
      _typing = false;
      widget.onTyping(false);
    }
  }

  void _send() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    widget.controller.clear();
    _stopTyping();
  }

  // Voice recording

  void _onMicTap() {
    // A tap is not a hold: explain the gesture rather than record a blank.
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Hold to record, release to send'),
      duration: Duration(seconds: 2),
    ));
  }

  Future<void> _startRecording() async {
    if (_recording || !widget.enabled) return;
    _armed = true;
    _cancelHint = false;

    if (kIsWeb) {
      _armed = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Voice notes are available in the app.'),
        ));
      }
      return;
    }

    final rec = _recorder ??= AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        _armed = false;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Microphone permission is needed for voice notes.'),
          ));
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      // This branch is mobile-only (web returns early above), so a POSIX join is
      // safe; path_provider hands back a native temp directory on each platform.
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      // Mono AAC at a voice-grade bitrate: intelligible speech, small files.
      await rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (_) {
      _armed = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not start recording.'),
        ));
      }
      return;
    }

    // The finger may have lifted during the async start; if so, stop at once
    // and treat it as a tap rather than leaving a recorder running.
    if (!_armed) {
      await rec.stop();
      return;
    }

    _startedAt = DateTime.now();
    _elapsed = Duration.zero;
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final started = _startedAt;
      if (started == null) return;
      final e = DateTime.now().difference(started);
      if (e >= _maxRecording) {
        _finishRecording(cancel: false);
        return;
      }
      setState(() => _elapsed = e);
    });
    setState(() => _recording = true);
  }

  void _onMicMove(LongPressMoveUpdateDetails d) {
    if (!_recording) return;
    final wantCancel = d.offsetFromOrigin.dx < -_cancelThreshold;
    if (wantCancel != _cancelHint) setState(() => _cancelHint = wantCancel);
  }

  void _onMicRelease() {
    _armed = false;
    if (!_recording) return;
    _finishRecording(cancel: _cancelHint);
  }

  Future<void> _finishRecording({required bool cancel}) async {
    _ticker?.cancel();
    _ticker = null;
    final rec = _recorder;
    final started = _startedAt;
    final ms = started == null ? 0 : DateTime.now().difference(started).inMilliseconds;
    _startedAt = null;
    if (mounted) {
      setState(() {
        _recording = false;
        _cancelHint = false;
        _elapsed = Duration.zero;
      });
    } else {
      _recording = false;
    }
    if (rec == null) return;

    // A cancel or a too-short clip is dropped without a trace; both stop the
    // recorder so the temp file is not left half-written on disk.
    if (cancel || ms < _minMs) {
      try {
        await rec.stop();
      } catch (_) {}
      if (cancel == false && ms < _minMs && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Hold to record, release to send'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }

    String? path;
    try {
      path = await rec.stop();
    } catch (_) {
      path = null;
    }
    if (path != null && path.isNotEmpty) {
      widget.onSendAudio?.call(path, ms, 'audio/mp4');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _recording ? _recordingBar() : _inputField()),
            const SizedBox(width: 6),
            _rightButton(),
          ],
        ),
      ),
    );
  }

  Widget _inputField() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.image_outlined, color: AppColors.textSecondary),
            tooltip: 'Send a photo',
            onPressed: widget.enabled ? widget.onPickImage : null,
          ),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              enabled: widget.enabled,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 15, color: AppColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'Message',
                hintStyle: TextStyle(color: AppColors.textSecondary),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// Replaces the input field while recording: a pulsing dot, the running time,
  /// and the slide-to-cancel affordance that turns red once past the threshold.
  Widget _recordingBar() {
    final m = _elapsed.inMinutes;
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    // Pulse the dot roughly twice a second off the same clock as the label.
    final on = (_elapsed.inMilliseconds ~/ 500) % 2 == 0;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          AnimatedOpacity(
            opacity: on ? 1 : 0.25,
            duration: const Duration(milliseconds: 200),
            child: Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 10),
          Text('$m:$s',
              style: const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
          Expanded(
            child: Center(
              child: Text(
                _cancelHint ? 'Release to cancel' : '‹ Slide to cancel',
                style: TextStyle(
                  fontSize: 12.5,
                  color: _cancelHint ? AppColors.error : AppColors.textSecondary,
                  fontWeight: _cancelHint ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rightButton() {
    // The mic, when voice is on and there is nothing to send, and the enlarged
    // red mic while recording — the same GestureDetector throughout, so the
    // long-press that started recording carries through the rebuild.
    if (_recording || (_voiceEnabled && !_hasText)) {
      final size = _recording ? 30.0 : 22.0;
      return GestureDetector(
        onTap: _onMicTap,
        onLongPressStart: widget.enabled ? (_) => _startRecording() : null,
        onLongPressMoveUpdate: _onMicMove,
        onLongPressEnd: (_) => _onMicRelease(),
        onLongPressCancel: _onMicRelease,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.all(_recording ? 14 : 12),
          decoration: BoxDecoration(
            color: _recording ? AppColors.error : AppColors.accent,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.mic, color: Colors.white, size: size),
        ),
      );
    }

    // The send button: a state, not a decoration — grey and inert until there
    // is something to send.
    return AnimatedScale(
      scale: _hasText ? 1 : 0.9,
      duration: const Duration(milliseconds: 120),
      child: Material(
        color: _hasText ? AppColors.accent : AppColors.disabled,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _hasText && widget.enabled ? _send : null,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.send_rounded, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}
