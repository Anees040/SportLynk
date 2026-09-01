import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../constants/api_constants.dart';

/// The app's single Socket.IO connection — the live half of chat.
///
/// One socket serves every chat screen. It authenticates in the handshake with
/// the same JWT as the REST API (the server's `io.use` verifies it), then the
/// server drops this device into a per-user room automatically; joining a channel
/// room is an explicit [joinChannel] the server DB-checks before honouring.
///
/// Events are surfaced as broadcast streams so a screen can subscribe on open and
/// cancel on close without ever tearing down the shared socket. The socket itself
/// only goes away on [disconnect] (logout).
///
/// The connect target is [ApiConstants.socketUrl] — the bare origin, not the
/// `/api` REST base — because engine.io is mounted at the server root.
class RealtimeService {
  static final RealtimeService _instance = RealtimeService._();
  factory RealtimeService() => _instance;
  RealtimeService._();

  io.Socket? _socket;
  String? _token;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _receipts = StreamController<Map<String, dynamic>>.broadcast();
  final _typing = StreamController<Map<String, dynamic>>.broadcast();
  final _presence = StreamController<Map<String, dynamic>>.broadcast();
  final _teamUpdates = StreamController<Map<String, dynamic>>.broadcast();
  final _teamRequests = StreamController<Map<String, dynamic>>.broadcast();
  final _matchUpdates = StreamController<Map<String, dynamic>>.broadcast();
  final _notifications = StreamController<Map<String, dynamic>>.broadcast();
  final _connection = StreamController<bool>.broadcast();

  /// A newly persisted (or re-emitted) message — the client upserts by id, so
  /// this same event also carries reaction changes and delete tombstones.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// A member's read/delivered watermark moved: `{channelId, userId, deliveredAt, readAt?}`.
  Stream<Map<String, dynamic>> get receipts => _receipts.stream;

  /// `{channelId, userId, name, isTyping}`.
  Stream<Map<String, dynamic>> get typing => _typing.stream;

  /// `{channelId, userId, online, lastSeenAt?}`.
  Stream<Map<String, dynamic>> get presence => _presence.stream;

  /// A team the user belongs to changed (roster/roles/left): `{teamId, left?}`.
  Stream<Map<String, dynamic>> get teamUpdates => _teamUpdates.stream;

  /// A pending join request landed for a team the user administers: `{teamId}`.
  Stream<Map<String, dynamic>> get teamRequests => _teamRequests.stream;

  /// A match the user has a stake in moved: `{matchId, status?, ...}`.
  ///
  /// Deliberately carries an id and not the match itself. The payload is emitted
  /// to both rosters and to the venue owner, and what each of them is allowed to
  /// see differs — a team may not read the opponent's submission until both are
  /// in. Sending only the id means every screen re-reads through the endpoint
  /// that enforces that, so the socket can never become a way around a read gate.
  Stream<Map<String, dynamic>> get matchUpdates => _matchUpdates.stream;

  /// Connected / disconnected transitions — the chat screen re-joins its channel
  /// on every `true` so a reconnect silently restores live delivery.
  /// Every notification row, the moment `pushJob` drains it from the outbox.
  ///
  /// This is the in-app half of delivery and it is not conditional on Firebase: the
  /// job emits `notification:new` after stamping the row whether or not a push was
  /// sent, suppressed by a preference or skipped because no service account is
  /// configured. So the bell moves on a dev machine with no FCM key at all -- which
  /// is exactly the state this feature ships in.
  ///
  /// The frame is a summary (id, type, category, priority, title, body, deepLink,
  /// groupKey, groupCount, imageUrl, createdAt), not the full feed row. Listeners
  /// use it to bump a badge and raise a banner; anything that needs the whole row
  /// re-reads the feed.
  Stream<Map<String, dynamic>> get notifications => _notifications.stream;

  Stream<bool> get connection => _connection.stream;

  bool get isConnected => _socket?.connected ?? false;

  /// Connect if not already connected for this token. Idempotent: called on every
  /// chat open, on app resume, and right after login — a matching live socket is
  /// reused, a stale-token socket is replaced.
  void ensureConnected(String token) {
    if (token.isEmpty) return;
    if (_socket != null && _token == token) {
      if (!_socket!.connected) _socket!.connect();
      return;
    }
    if (_socket != null) _teardown();

    _token = token;
    final socket = io.io(
      ApiConstants.socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setAuth({'token': token})
          .setQuery({'token': token})
          .enableReconnection()
          .setReconnectionAttempts(1 << 30)
          .setReconnectionDelay(800)
          .setReconnectionDelayMax(5000)
          .disableAutoConnect()
          .build(),
    );
    _wire(socket);
    _socket = socket;
    socket.connect();
  }

  void _wire(io.Socket s) {
    s.onConnect((_) => _connection.add(true));
    s.onDisconnect((_) => _connection.add(false));
    s.onConnectError((e) {
      _connection.add(false);
      debugPrint('[rt] connect_error: $e');
    });
    s.onError((e) => debugPrint('[rt] error: $e'));

    s.on('chat:message', (d) => _push(_messages, d));
    s.on('receipt', (d) => _push(_receipts, d));
    s.on('typing', (d) => _push(_typing, d));
    s.on('presence', (d) => _push(_presence, d));
    s.on('team:update', (d) => _push(_teamUpdates, d));
    s.on('team:request', (d) => _push(_teamRequests, d));
    s.on('match:update', (d) => _push(_matchUpdates, d));
    s.on('notification:new', (d) => _push(_notifications, d));
  }

  void _push(StreamController<Map<String, dynamic>> c, dynamic data) {
    if (data is Map) c.add(Map<String, dynamic>.from(data));
  }

  // Outbound
  void joinChannel(String channelId) => _socket?.emit('channel:join', {'channelId': channelId});
  void leaveChannel(String channelId) => _socket?.emit('channel:leave', {'channelId': channelId});
  void sendTyping(String channelId, bool isTyping) =>
      _socket?.emit('typing', {'channelId': channelId, 'isTyping': isTyping});
  void markRead(String channelId) => _socket?.emit('message:read', {'channelId': channelId});

  /// Full teardown — used on logout so the next user gets a clean socket.
  void disconnect() {
    _teardown();
    _token = null;
  }

  void _teardown() {
    final s = _socket;
    _socket = null;
    if (s != null) {
      s.dispose();
      _connection.add(false);
    }
  }
}
