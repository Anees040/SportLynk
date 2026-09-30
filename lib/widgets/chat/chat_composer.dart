import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../constants/colors.dart';

/// The message input bar. Owns the behaviours that make chat feel right:
///   • the send button only appears once there is something to send;
///   • an attachment button sits beside the mic, so a photo is one tap away
///     without crowding the text field;
///   • when the field is empty a hold-to-record mic takes the send button's
///     place — hold to record, release to send, slide left to cancel, slide up
///     to lock it hands-free, then pause or send at leisure;
///   • typing is announced on the first keystroke and auto-stopped after a short
///     lull, so the other side sees "typing…" appear and fade — without a socket
///     event per character.
///
/// [onSendAudio] is optional: without it the mic is not offered and the bar is a
/// plain text-and-attachment composer (the shape the widget tests exercise).
/// Recording is unavailable on web — the browser cannot hand back a file the
/// uploader can read — so the mic there explains itself rather than failing.
class ChatComposer extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String text) onSend;
  final VoidCallback onPickImage;
  final void Function(bool isTyping) onTyping;

  /// Called with the clip's path, its length in milliseconds, and its mime once a
  /// voice note is released. Null disables voice notes entirely.
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
  // Beyond this drag upward, recording latches hands-free and the finger can lift.
  static const _lockThreshold = 80.0;
  // A recording shorter than this was a mis-tap, not a message.
  static const _minMs = 1000;
  // A voice note is not a podcast; the uploader's free tier is finite.
  static const _maxRecording = Duration(minutes: 5);

  Timer? _stopTimer;
  bool _typing = false;
  bool _hasText = false;

  AudioRecorder? _recorder;
  // Plays the short cue when a recording starts (Issue 4). Created lazily so a
  // composer that never records a voice note pays nothing for it.
  AudioPlayer? _cuePlayer;
  bool _recording = false;
  bool _armed = false; // finger still down (the press may outlive the async start)
  bool _cancelHint = false;
  bool _towardLock = false; // finger dragging up toward the lock affordance
  bool _locked = false; // hands-free: recording continues after the finger lifts
  bool _paused = false;
  Timer? _ticker;

  // Elapsed time accumulates across pause/resume: [_elapsedBase] holds the time
  // banked by finished runs, and [_runStart] marks the current unpaused run.
  Duration _elapsedBase = Duration.zero;
  DateTime? _runStart;

  bool get _voiceEnabled => widget.onSendAudio != null;

  /// The recording's running length, excluding any paused stretches.
  Duration get _elapsed {
    final start = _runStart;
    if (start == null || _paused) return _elapsedBase;
    return _elapsedBase + DateTime.now().difference(start);
  }

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
    _cuePlayer?.dispose();
    super.dispose();
  }

  /// The short start-of-recording cue: a light haptic and a brief tone, played
  /// the moment recording begins (Issue 4). Failures are swallowed — a missing
  /// audio route must never stop a voice note from being recorded.
  Future<void> _playRecStartCue() async {
    HapticFeedback.mediumImpact();
    try {
      final p = _cuePlayer ??= AudioPlayer();
      await p.setAsset('assets/sounds/rec_start.wav');
      await p.seek(Duration.zero);
      await p.play();
    } catch (_) {}
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

  /// A tap starts a hands-free (locked) recording — the WhatsApp shortcut for a
  /// longer note without holding the finger down. Holding still records too, and
  /// can slide up to lock or left to cancel.
  Future<void> _onMicTap() async {
    if (_recording || !widget.enabled) return;
    await _startRecording();
    if (mounted && _recording) _lockRecording();
  }

  Future<void> _startRecording() async {
    if (_recording || !widget.enabled) return;
    _armed = true;
    _cancelHint = false;
    _towardLock = false;
    _locked = false;
    _paused = false;

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
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
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

    // The finger may have lifted during the async start; if so, stop at once and
    // treat it as a tap rather than leaving a recorder running.
    if (!_armed) {
      await rec.stop();
      return;
    }

    _elapsedBase = Duration.zero;
    _runStart = DateTime.now();
    _startTicker();
    setState(() => _recording = true);
    unawaited(_playRecStartCue());
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_elapsed >= _maxRecording) {
        _finishRecording(cancel: false);
        return;
      }
      setState(() {});
    });
  }

  /// Fold the current unpaused run into [_elapsedBase] and stop the run clock.
  void _accumulate() {
    final start = _runStart;
    if (start != null) {
      _elapsedBase += DateTime.now().difference(start);
      _runStart = null;
    }
  }

  void _onMicMove(LongPressMoveUpdateDetails d) {
    if (!_recording || _locked) return;
    final dy = d.offsetFromOrigin.dy;
    // Upward past the threshold latches the recording so the finger can lift.
    if (dy < -_lockThreshold) {
      _lockRecording();
      return;
    }
    final towardLock = dy < -_lockThreshold * 0.4;
    final wantCancel =
        !towardLock && d.offsetFromOrigin.dx < -_cancelThreshold;
    if (towardLock != _towardLock || wantCancel != _cancelHint) {
      setState(() {
        _towardLock = towardLock;
        _cancelHint = wantCancel;
      });
    }
  }

  void _lockRecording() {
    if (_locked) return;
    setState(() {
      _locked = true;
      _towardLock = false;
      _cancelHint = false;
    });
  }

  void _onMicRelease() {
    _armed = false;
    // A locked recording keeps going hands-free; its own buttons end it.
    if (!_recording || _locked) return;
    _finishRecording(cancel: _cancelHint);
  }

  Future<void> _togglePause() async {
    final rec = _recorder;
    if (rec == null || !_recording) return;
    if (_paused) {
      try {
        await rec.resume();
      } catch (_) {}
      _runStart = DateTime.now();
      _startTicker();
      if (mounted) setState(() => _paused = false);
    } else {
      try {
        await rec.pause();
      } catch (_) {}
      _accumulate();
      _ticker?.cancel();
      _ticker = null;
      if (mounted) setState(() => _paused = true);
    }
  }

  Future<void> _finishRecording({required bool cancel}) async {
    _ticker?.cancel();
    _ticker = null;
    _accumulate();
    final rec = _recorder;
    final ms = _elapsedBase.inMilliseconds;
    if (mounted) {
      setState(() {
        _recording = false;
        _locked = false;
        _paused = false;
        _cancelHint = false;
        _towardLock = false;
        _elapsedBase = Duration.zero;
        _runStart = null;
      });
    } else {
      _recording = false;
      _locked = false;
      _paused = false;
    }
    if (rec == null) return;

    // A cancel or a too-short clip is dropped without a trace; both stop the
    // recorder so a half-written temp file is not left on disk.
    if (cancel || ms < _minMs) {
      try {
        await rec.stop();
      } catch (_) {}
      if (!cancel && ms < _minMs && mounted) {
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
        child: _locked
            ? _lockedBar()
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_recording) _lockHint(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                          child:
                              _recording ? _recordingBar() : _inputField()),
                      if (!_recording) _attachButton(),
                      const SizedBox(width: 6),
                      _rightButton(),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _attachButton() {
    // A camera icon, not a paperclip: tapping it opens the live camera, from
    // which the gallery is one tap away (Issue 2). The screen owns what opens;
    // this button only signals the intent.
    return IconButton(
      icon: const Icon(Icons.photo_camera_outlined, color: AppColors.textSecondary),
      tooltip: 'Camera',
      onPressed: widget.enabled ? widget.onPickImage : null,
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
          const SizedBox(width: 16),
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

  /// The lock affordance shown above the mic while recording by hand: sliding the
  /// finger up onto it latches the recording so it continues without holding.
  Widget _lockHint() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, right: 14),
      child: Align(
        alignment: Alignment.centerRight,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.all(_towardLock ? 8 : 6),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            shape: BoxShape.circle,
            border: Border.all(
                color: _towardLock ? AppColors.accent : AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: _towardLock ? 20 : 16,
                  color:
                      _towardLock ? AppColors.accent : AppColors.textSecondary),
              const Icon(Icons.keyboard_arrow_up,
                  size: 14, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  /// Replaces the field while recording by hand: a pulsing dot, the running time,
  /// and the slide-to-cancel hint that turns red past the threshold.
  Widget _recordingBar() {
    final m = _elapsed.inMinutes;
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
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
          _pulseDot(on),
          const SizedBox(width: 10),
          Text('$m:$s',
              style:
                  const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
          Expanded(
            child: Center(
              child: Text(
                _cancelHint ? 'Release to cancel' : '‹ Slide to cancel',
                style: TextStyle(
                  fontSize: 12.5,
                  color:
                      _cancelHint ? AppColors.error : AppColors.textSecondary,
                  fontWeight:
                      _cancelHint ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pulseDot(bool on) => AnimatedOpacity(
        opacity: on ? 1 : 0.25,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
              color: AppColors.error, shape: BoxShape.circle),
        ),
      );

  /// The hands-free bar shown once a recording is locked: discard on the left,
  /// the running time and state in the middle, then pause/resume and send.
  Widget _lockedBar() {
    final m = _elapsed.inMinutes;
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final on = _paused || (_elapsed.inMilliseconds ~/ 500) % 2 == 0;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.delete_outline, color: AppColors.error),
          tooltip: 'Discard recording',
          onPressed: () => _finishRecording(cancel: true),
        ),
        _pulseDot(on),
        const SizedBox(width: 10),
        Text('$m:$s',
            style: const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _paused ? 'Paused' : 'Recording…',
            style: const TextStyle(
                fontSize: 12.5, color: AppColors.textSecondary),
          ),
        ),
        IconButton(
          icon: Icon(_paused ? Icons.play_arrow : Icons.pause,
              color: AppColors.primary),
          tooltip: _paused ? 'Resume recording' : 'Pause recording',
          onPressed: _togglePause,
        ),
        const SizedBox(width: 4),
        Material(
          color: AppColors.accent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _finishRecording(cancel: false),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Icon(Icons.send_rounded, color: Colors.white, size: 22),
            ),
          ),
        ),
      ],
    );
  }

  Widget _rightButton() {
    // The mic — plain when idle, enlarged and red while recording — kept on the
    // same GestureDetector throughout, so the long-press that started recording
    // carries through the rebuild.
    if (_recording || (_voiceEnabled && !_hasText)) {
      final size = _recording ? 30.0 : 22.0;
      return GestureDetector(
        onTap: _onMicTap,
        onLongPressStart: widget.enabled ? (_) => _startRecording() : null,
        onLongPressMoveUpdate: _onMicMove,
        onLongPressEnd: (_) => _onMicRelease(),
        onLongPressCancel: _onMicRelease,
        child: Semantics(
          label: _recording ? 'Recording, release to send' : 'Hold to record',
          button: true,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.all(_recording ? 14 : 12),
            decoration: BoxDecoration(
              color: _recording ? AppColors.error : AppColors.accent,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.mic, color: Colors.white, size: size),
          ),
        ),
      );
    }

    // The send button: a state, not a decoration — grey and inert until there is
    // something to send.
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
