import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// One app-wide player for chat voice notes.
///
/// The decoder used to live inside each bubble's [State], so scrolling a playing
/// note off-screen disposed its player: the clip stopped, the counter snapped
/// back to 0:00, and a rebuild on a disposed player threw. Holding a single
/// player here lets a bubble come and go while its audio keeps running, cancels
/// its stream subscriptions in one place, and enforces WhatsApp's rule that
/// starting one clip stops whatever else was playing.
///
/// A bubble observes this (it is a [ChangeNotifier]) and asks it to [toggle] or
/// [seek] its own clip, identified by message id. Only the clip whose id equals
/// [currentId] is the live one; every other bubble renders its resting state.
class ChatAudioService extends ChangeNotifier {
  ChatAudioService._();
  static final ChatAudioService instance = ChatAudioService._();

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _wired = false;

  String? _currentId;
  bool _playing = false;
  bool _loading = false;
  String? _errorId;
  String? _errorText;
  Duration _position = Duration.zero;
  Duration? _duration;

  // Playback speed, cycled by the bubble's speed control. just_audio re-applies
  // the player's speed to every new source it loads (see _setPlatformActive in
  // the package), so one setting carries across clips without being re-sent —
  // matching WhatsApp, where the chosen speed persists for the session rather
  // than resetting on each note.
  static const List<double> speeds = <double>[1.0, 1.5, 2.0];
  double _speed = 1.0;

  String? get currentId => _currentId;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get errorId => _errorId;

  /// Why the current clip would not play, short enough for a bubble. Null unless
  /// [errorId] is set. Surfaced rather than swallowed: a voice note that silently
  /// refuses to start is indistinguishable from a broken player.
  String? get errorText => _errorText;
  Duration get position => _position;
  Duration? get duration => _duration;

  /// The current playback speed, always one of [speeds]. The bubble renders its
  /// label from this and advances it through [cycleSpeed].
  double get speed => _speed;

  bool isCurrent(String id) => _currentId == id;

  void _wire() {
    if (_wired) return;
    _wired = true;
    _subs.add(_player.positionStream.listen((p) {
      _position = p;
      notifyListeners();
    }));
    _subs.add(_player.durationStream.listen((d) {
      if (d != null) {
        _duration = d;
        notifyListeners();
      }
    }));
    _subs.add(_player.playerStateStream.listen((s) {
      // A finished clip rewinds to the start and rests, so the next tap replays
      // it rather than sitting at the end.
      if (s.processingState == ProcessingState.completed) {
        _playing = false;
        _position = Duration.zero;
        _player.pause();
        _player.seek(Duration.zero);
      } else {
        _playing = s.playing;
      }
      notifyListeners();
    }));
    // Errors raised mid-playback (a dropped connection, a codec the device
    // refuses) arrive here rather than from the setUrl future, so they need their
    // own handler or they surface as an unhandled exception in the terminal.
    _subs.add(_player.playbackEventStream.listen(
      (_) {},
      onError: (Object e) => _fail(_currentId, e),
    ));
  }

  void _fail(String? id, Object error) {
    _loading = false;
    _playing = false;
    _errorId = id;
    _errorText = _describe(error);
    _currentId = null;
    notifyListeners();
  }

  /// A short, human reason. just_audio's exceptions carry platform detail that is
  /// useful in a log and unreadable in a bubble, so the common cases are named and
  /// anything else falls back to the type.
  String _describe(Object e) {
    if (e is String) return e;
    if (e is TimeoutException) return 'Took too long to load';
    if (e is PlayerException) {
      final m = (e.message ?? '').trim();
      return m.isEmpty ? 'Could not play this clip' : m;
    }
    if (e is PlayerInterruptedException) return 'Playback was interrupted';
    return 'Could not play this clip';
  }

  /// Play [id]'s clip, or pause it when it is already the one playing. A tap on a
  /// different clip replaces the current one.
  Future<void> toggle(String id, String url) async {
    _wire();
    if (_currentId == id) {
      if (_player.playing) {
        await _player.pause();
      } else {
        // Not awaited: play() completes only when the clip ENDS, so awaiting it
        // would hold this call open for the whole clip.
        _player.play();
      }
      return;
    }

    _currentId = id;
    _errorId = null;
    _errorText = null;
    _loading = true;
    _position = Duration.zero;
    _duration = null;
    notifyListeners();
    try {
      final decoded = await _player.setUrl(url).timeout(const Duration(seconds: 25));
      if (_currentId != id) return; // another clip was started while this loaded
      // The host accepted the upload but the decoder found no audio in it — a zero
      // or absent duration. That is the signature of a clip stored under the wrong
      // resource type: the file downloads, "plays", and reaches completed at once,
      // which otherwise shows only as a silent snap back to 0:00, indistinguishable
      // from a broken player. Surface it as a failure with a retry instead.
      if (decoded == null || decoded == Duration.zero) {
        _fail(id, 'This clip could not be played — it may not have uploaded correctly');
        return;
      }
      _loading = false;
      notifyListeners();
      _player.play();
    } catch (e) {
      // The clip would not load. Reported on its own bubble with a reason and a
      // retry, never as a thrown exception under the thread.
      debugPrint('[chat-audio] $id failed to load: $e');
      _fail(id, e);
    }
  }

  /// Scrub [id]'s clip, honoured only while it is the current one.
  Future<void> seek(String id, Duration to) async {
    if (_currentId != id) return;
    _position = to;
    notifyListeners();
    await _player.seek(to);
  }

  /// Advance the playback speed to the next of [speeds], wrapping 2x back to 1x,
  /// and apply it to the live player. The setting is not tied to a clip: it holds
  /// across notes, so a listener who set 1.5x hears the next note at 1.5x too.
  Future<void> cycleSpeed() async {
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    _speed = next;
    notifyListeners();
    try {
      await _player.setSpeed(next);
    } catch (e) {
      // Speed is cosmetic and has nowhere on the bubble to report a fault, so a
      // rare platform refusal is logged rather than thrown out of a tap handler.
      // The label still reflects the user's choice; only the audio rate lagged.
      debugPrint('[chat-audio] setSpeed($next) failed: $e');
    }
  }

  /// Stop and release the current clip — called when the thread closes so a note
  /// does not keep playing into a screen that is gone.
  Future<void> stop() async {
    if (_currentId == null && !_playing) return;
    _currentId = null;
    _playing = false;
    _errorId = null;
    _errorText = null;
    _position = Duration.zero;
    _duration = null;
    await _player.stop();
    notifyListeners();
  }
}
