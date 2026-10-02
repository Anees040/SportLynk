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
  Duration _position = Duration.zero;
  Duration? _duration;

  String? get currentId => _currentId;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get errorId => _errorId;
  Duration get position => _position;
  Duration? get duration => _duration;

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
  }

  /// Play [id]'s clip, or pause it when it is already the one playing. A tap on a
  /// different clip replaces the current one.
  Future<void> toggle(String id, String url) async {
    _wire();
    if (_currentId == id) {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    _currentId = id;
    _errorId = null;
    _loading = true;
    _position = Duration.zero;
    _duration = null;
    notifyListeners();
    try {
      await _player.setUrl(url).timeout(const Duration(seconds: 20));
      _loading = false;
      notifyListeners();
      await _player.play();
    } catch (_) {
      // A clip that will not load or times out surfaces as an error on its own
      // bubble (a retry tap), never a thrown exception under the thread.
      _loading = false;
      _errorId = id;
      _currentId = null;
      _playing = false;
      notifyListeners();
    }
  }

  /// Scrub [id]'s clip, honoured only while it is the current one.
  Future<void> seek(String id, Duration to) async {
    if (_currentId != id) return;
    _position = to;
    notifyListeners();
    await _player.seek(to);
  }

  /// Stop and release the current clip — called when the thread closes so a note
  /// does not keep playing into a screen that is gone.
  Future<void> stop() async {
    if (_currentId == null && !_playing) return;
    _currentId = null;
    _playing = false;
    _position = Duration.zero;
    _duration = null;
    await _player.stop();
    notifyListeners();
  }
}
