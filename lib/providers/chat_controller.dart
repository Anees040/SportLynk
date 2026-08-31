import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../services/chat_service.dart';
import '../services/realtime_service.dart';

/// Owns the live state of ONE open chat. Instantiated locally by ChatThreadScreen
/// (not a global provider) and disposed with it, so nothing leaks between chats.
///
/// It fuses three sources into one coherent timeline:
///   • REST history (initial page + pagination)
///   • the socket's `chat:message` push (new messages, reaction changes, deletes
///     — all the same event; the client upserts by id)
///   • `receipt` / `typing` / `presence` events, which drive ticks and subtitles
///
/// TICKS ARE COMPUTED, NOT STORED. For each of my messages the state is the
/// weakest across every OTHER member: read only once the last person has read,
/// delivered only once the last device has it. That is what makes a group's blue
/// tick mean "everyone", exactly like WhatsApp.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.token,
    required this.channelId,
    required this.myUserId,
  }) {
    _init();
  }

  final String token;
  final String channelId;
  final String myUserId;

  final _chat = ChatService();
  final _rt = RealtimeService();

  final Map<String, ChatMessage> _byId = {};
  List<ChatMessage> _ordered = [];

  final Map<String, ChatMember> _members = {};
  final Map<String, DateTime> _read = {};
  final Map<String, DateTime> _delivered = {};
  final Map<String, bool> _online = {};
  final Map<String, DateTime?> _lastSeen = {};

  final Map<String, String> _typingNames = {}; // userId → display name
  final Map<String, Timer> _typingTimers = {};

  final List<StreamSubscription> _subs = [];

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _connected = false;
  String? _error;
  int _sendCounter = 0;

  // ── Public view ────────────────────────────────────────────
  List<ChatMessage> get messages => _ordered;
  List<ChatMember> get members => _members.values.toList();
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  bool get connected => _connected;
  String? get error => _error;
  int get memberCount => _members.length;

  /// "Ali is typing…", "Ali & Sara are typing…", or null when nobody is.
  String? get typingText {
    final names = _typingNames.values.where((n) => n.trim().isNotEmpty).toList();
    if (names.isEmpty) return null;
    if (names.length == 1) return '${names.first} is typing…';
    if (names.length == 2) return '${names[0]} & ${names[1]} are typing…';
    return 'Several people are typing…';
  }

  int get _othersOnline =>
      _online.entries.where((e) => e.key != myUserId && e.value).length;

  /// The app-bar subtitle: typing wins, then an online count, else a plain
  /// member count.
  String get subtitle {
    final t = typingText;
    if (t != null) return t;
    final online = _othersOnline;
    final base = '$memberCount member${memberCount == 1 ? '' : 's'}';
    return online > 0 ? '$base · $online online' : base;
  }

  // ── Init & teardown ────────────────────────────────────────
  Future<void> _init() async {
    _rt.ensureConnected(token);
    _subs.add(_rt.messages.listen(_onMessage));
    _subs.add(_rt.receipts.listen(_onReceipt));
    _subs.add(_rt.typing.listen(_onTyping));
    _subs.add(_rt.presence.listen(_onPresence));
    _subs.add(_rt.connection.listen(_onConnection));

    _rt.joinChannel(channelId);
    await _loadMembers();
    await _loadInitial();
  }

  Future<void> _loadMembers() async {
    final list = await _chat.members(token, channelId);
    for (final m in list) {
      _members[m.userId] = m;
      _read[m.userId] = m.lastReadAt;
      _delivered[m.userId] = m.lastDeliveredAt;
      if (m.lastSeenAt != null) _lastSeen[m.userId] = m.lastSeenAt;
    }
    notifyListeners();
  }

  Future<void> _loadInitial() async {
    final page = await _chat.messages(token, channelId, limit: 40);
    for (final m in page) {
      _byId[m.id] = m;
    }
    _hasMore = page.length >= 40;
    _loading = false;
    _rebuild();
    _markRead();
  }

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore || _ordered.isEmpty) return;
    _loadingMore = true;
    final oldest = _ordered.first.createdAt.toUtc().toIso8601String();
    final page = await _chat.messages(token, channelId, before: oldest, limit: 40);
    for (final m in page) {
      _byId.putIfAbsent(m.id, () => m);
    }
    _hasMore = page.length >= 40;
    _loadingMore = false;
    _rebuild();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _rt.leaveChannel(channelId);
    super.dispose();
  }

  // ── Sending ────────────────────────────────────────────────
  String _newClientId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${myUserId.hashCode}-${_sendCounter++}';

  Future<void> sendText(String raw) async {
    final body = raw.trim();
    if (body.isEmpty) return;
    final clientId = _newClientId();
    _addOptimistic(ChatMessage(
      id: 'local:$clientId',
      clientId: clientId,
      channelId: channelId,
      senderId: myUserId,
      kind: MessageKind.text,
      body: body,
      createdAt: DateTime.now(),
      pending: true,
    ));

    final r = await _chat.sendText(token, channelId, body: body, clientId: clientId);
    _reconcile(clientId, r);
  }

  /// Called by the screen AFTER it has uploaded the picked image to Cloudinary.
  Future<void> sendImage({
    required String mediaUrl,
    String? mediaMime,
    int? mediaW,
    int? mediaH,
    String? caption,
  }) async {
    final clientId = _newClientId();
    _addOptimistic(ChatMessage(
      id: 'local:$clientId',
      clientId: clientId,
      channelId: channelId,
      senderId: myUserId,
      kind: MessageKind.image,
      body: (caption ?? '').trim().isEmpty ? null : caption!.trim(),
      mediaUrl: mediaUrl,
      mediaMime: mediaMime,
      mediaW: mediaW ?? 0,
      mediaH: mediaH ?? 0,
      createdAt: DateTime.now(),
      pending: true,
    ));

    final r = await _chat.sendImage(
      token,
      channelId,
      mediaUrl: mediaUrl,
      mediaMime: mediaMime,
      mediaW: mediaW,
      mediaH: mediaH,
      caption: caption,
      clientId: clientId,
    );
    _reconcile(clientId, r);
  }

  void _addOptimistic(ChatMessage m) {
    _byId[m.id] = m;
    _rebuild();
  }

  void _reconcile(String clientId, Map<String, dynamic> r) {
    if (r['success'] == true && r['data'] is Map) {
      final server = ChatMessage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
      _byId.remove('local:$clientId');
      _byId[server.id] = server;
    } else {
      final temp = _byId['local:$clientId'];
      if (temp != null) {
        _byId['local:$clientId'] = temp.copyWith(pending: false, failed: true);
      }
    }
    _rebuild();
  }

  /// Retry a failed optimistic message (text only; a failed image can be re-picked).
  Future<void> retry(ChatMessage failed) async {
    if (!failed.failed) return;
    _byId.remove(failed.id);
    _rebuild();
    if (failed.kind == MessageKind.image && failed.mediaUrl != null) {
      await sendImage(
        mediaUrl: failed.mediaUrl!,
        mediaMime: failed.mediaMime,
        mediaW: failed.mediaW.toInt(),
        mediaH: failed.mediaH.toInt(),
        caption: failed.body,
      );
    } else {
      await sendText(failed.body ?? '');
    }
  }

  // ── Reactions & delete ─────────────────────────────────────
  Future<void> toggleReaction(String messageId, String emoji) async {
    final m = _byId[messageId];
    if (m == null || m.pending) return;

    // Optimistic: reflect my tap immediately, reconcile from the server echo.
    final mine = m.myReaction(myUserId);
    final next = List<MessageReaction>.from(m.reactions)
      ..removeWhere((r) => r.userId == myUserId);
    if (mine != emoji) next.add(MessageReaction(emoji, myUserId));
    _byId[messageId] = m.copyWith(reactions: next);
    _rebuild();

    final r = await _chat.react(token, channelId, messageId, emoji);
    if (r['success'] == true && r['data'] is Map) {
      _byId[messageId] = ChatMessage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
      _rebuild();
    } else if (r['success'] != true) {
      _byId[messageId] = m; // revert
      _rebuild();
    }
  }

  Future<Map<String, dynamic>> deleteMessage(String messageId) async {
    final m = _byId[messageId];
    if (m == null) return {'success': false, 'message': 'Message not found.'};
    final r = await _chat.deleteMessage(token, channelId, messageId);
    if (r['success'] == true) {
      if (r['data'] is Map && (r['data'] as Map).containsKey('id')) {
        _byId[messageId] = ChatMessage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
      } else {
        _byId[messageId] = m.copyWith(deletedAt: DateTime.now());
      }
      _rebuild();
    }
    return r;
  }

  bool canDelete(ChatMessage m) {
    if (m.isSystem || m.isDeleted || m.pending) return false;
    if (m.senderId == myUserId) return true;
    return _members[myUserId]?.isAdmin ?? false;
  }

  // ── Live event handlers ────────────────────────────────────
  void _onMessage(Map<String, dynamic> data) {
    if ('${data['channel_id']}' != channelId) return;
    final m = ChatMessage.fromJson(data);
    if (m.clientId != null) _byId.remove('local:${m.clientId}');
    _byId[m.id] = m;
    _rebuild();
    // Someone else spoke while I'm looking — mark read so their ticks go blue.
    if (m.senderId != myUserId && !m.isSystem) _markRead();
  }

  void _onReceipt(Map<String, dynamic> data) {
    if ('${data['channelId']}' != channelId) return;
    final userId = '${data['userId']}';
    if (userId == myUserId) return;
    final delivered = DateTime.tryParse('${data['deliveredAt']}')?.toLocal();
    final read = data['readAt'] != null ? DateTime.tryParse('${data['readAt']}')?.toLocal() : null;
    if (delivered != null) _bump(_delivered, userId, delivered);
    if (read != null) _bump(_read, userId, read);
    notifyListeners();
  }

  void _onTyping(Map<String, dynamic> data) {
    if ('${data['channelId']}' != channelId) return;
    final userId = '${data['userId']}';
    if (userId == myUserId) return;
    final isTyping = data['isTyping'] != false;
    _typingTimers[userId]?.cancel();
    if (isTyping) {
      _typingNames[userId] = '${data['name'] ?? _members[userId]?.name ?? 'Someone'}';
      // Fail-safe: clear if the "stopped typing" event is ever missed.
      _typingTimers[userId] = Timer(const Duration(seconds: 6), () {
        _typingNames.remove(userId);
        _typingTimers.remove(userId);
        notifyListeners();
      });
    } else {
      _typingNames.remove(userId);
      _typingTimers.remove(userId);
    }
    notifyListeners();
  }

  void _onPresence(Map<String, dynamic> data) {
    if ('${data['channelId']}' != channelId) return;
    final userId = '${data['userId']}';
    _online[userId] = data['online'] == true;
    final seen = data['lastSeenAt'];
    if (seen != null) _lastSeen[userId] = DateTime.tryParse('$seen')?.toLocal();
    notifyListeners();
  }

  void _onConnection(bool up) {
    _connected = up;
    if (up) {
      // Reconnected: re-enter the room, then refresh members and the latest page
      // so anything missed while offline is folded in (upsert dedupes overlaps).
      _rt.joinChannel(channelId);
      _resync();
    }
    notifyListeners();
  }

  Future<void> _resync() async {
    await _loadMembers();
    final page = await _chat.messages(token, channelId, limit: 40);
    for (final m in page) {
      if (m.clientId != null) _byId.remove('local:${m.clientId}');
      _byId[m.id] = m;
    }
    _rebuild();
    _markRead();
  }

  // ── Tick computation ───────────────────────────────────────
  TickState tickFor(ChatMessage m) {
    if (m.failed) return TickState.sending; // bubble draws its own error affordance
    if (m.pending) return TickState.sending;
    final others = _members.keys.where((id) => id != myUserId);
    if (others.isEmpty) return TickState.sent;

    DateTime minRead = _farFuture;
    DateTime minDelivered = _farFuture;
    for (final id in others) {
      final rd = _read[id] ?? _epoch;
      final dv = _delivered[id] ?? _epoch;
      if (rd.isBefore(minRead)) minRead = rd;
      if (dv.isBefore(minDelivered)) minDelivered = dv;
    }
    if (!minRead.isBefore(m.createdAt)) return TickState.read;
    if (!minDelivered.isBefore(m.createdAt)) return TickState.delivered;
    return TickState.sent;
  }

  // ── Read marking ───────────────────────────────────────────
  void _markRead() {
    if (_connected) {
      _rt.markRead(channelId);
    } else {
      _chat.markRead(token, channelId);
    }
  }

  /// Called by the screen when it becomes visible / regains focus.
  void markReadNow() => _markRead();

  /// Announce (or clear) my typing state to the room. The composer decides the
  /// cadence; we simply forward — a no-op when the socket is down.
  void sendTyping(bool typing) => _rt.sendTyping(channelId, typing);

  // ── Helpers ────────────────────────────────────────────────
  void _bump(Map<String, DateTime> map, String key, DateTime v) {
    final cur = map[key];
    if (cur == null || cur.isBefore(v)) map[key] = v;
  }

  void _rebuild() {
    final list = _byId.values.toList()
      ..sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    _ordered = list;
    notifyListeners();
  }

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
  static final DateTime _farFuture = DateTime.fromMillisecondsSinceEpoch(99999999999999);
}
