import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../services/chat_service.dart';
import '../services/cloudinary_service.dart';
import '../services/realtime_service.dart';

/// Owns the live state of one open chat. Instantiated locally by ChatThreadScreen
/// (not a global provider) and disposed with it, so nothing leaks between chats.
///
/// It fuses three sources into one coherent timeline:
///   • REST history (initial page + pagination)
///   • the socket's `chat:message` push (new messages, reaction changes, deletes
///     — all the same event; the client upserts by id)
///   • `receipt` / `typing` / `presence` events, which drive ticks and subtitles
///
/// Ticks are computed, not stored. For each of my messages the state is the
/// weakest across every other member: read only once the last person has read,
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
  List<ChatMessage> _pinned = [];

  /// Where my read watermark sat when the room opened, captured once so the
  /// "unread messages" divider marks the boundary I arrived at — not one that
  /// advances as I read. Null until the first member load; stays put after.
  DateTime? _unreadBoundary;
  bool _boundaryCaptured = false;

  final Map<String, ChatMember> _members = {};
  final Map<String, DateTime> _read = {};
  final Map<String, DateTime> _delivered = {};
  final Map<String, bool> _online = {};
  final Map<String, DateTime?> _lastSeen = {};

  final Map<String, String> _typingNames = {}; // userId → display name
  final Map<String, Timer> _typingTimers = {};

  final List<StreamSubscription> _subs = [];

  /// clientIds of image sends the user cancelled while they were still
  /// uploading; their upload result is dropped when it eventually returns.
  final Set<String> _canceled = {};

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _connected = false;
  String? _error;
  int _sendCounter = 0;

  // Public view
  List<ChatMessage> get messages => _ordered;
  List<ChatMember> get members => _members.values.toList();
  List<ChatMessage> get pinned => _pinned;
  DateTime? get unreadBoundary => _unreadBoundary;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  bool get connected => _connected;
  String? get error => _error;
  int get memberCount => _members.length;

  /// The member the picker offers for @mentions: everyone but me, and never a
  /// system/absent sender. Sorted by name so the list is stable.
  List<ChatMember> get mentionCandidates {
    final out = _members.values.where((m) => m.userId != myUserId).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

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

  // Init & teardown
  Future<void> _init() async {
    _rt.ensureConnected(token);
    // Seed from the socket's current state. The connection stream is a broadcast
    // with no replay, so a chat opened after the socket already connected (the
    // common case — it connects at login) would otherwise never receive an
    // onConnect event and would sit on "Connecting…" forever despite being live.
    _connected = _rt.isConnected;
    _subs.add(_rt.messages.listen(_onMessage));
    _subs.add(_rt.receipts.listen(_onReceipt));
    _subs.add(_rt.typing.listen(_onTyping));
    _subs.add(_rt.presence.listen(_onPresence));
    _subs.add(_rt.pinned.listen(_onPinnedChanged));
    _subs.add(_rt.connection.listen(_onConnection));

    _rt.joinChannel(channelId);
    await _loadMembers();
    await _loadInitial();
    await _loadPinned();
  }

  Future<void> _loadMembers() async {
    final list = await _chat.members(token, channelId);
    for (final m in list) {
      _members[m.userId] = m;
      _read[m.userId] = m.lastReadAt;
      _delivered[m.userId] = m.lastDeliveredAt;
      if (m.lastSeenAt != null) _lastSeen[m.userId] = m.lastSeenAt;
    }
    // The unread boundary is where my own watermark sat when I arrived. Captured
    // exactly once, before the first _markRead moves it, so reopening a room I
    // have already read does not plant a fresh divider.
    if (!_boundaryCaptured) {
      _unreadBoundary = _members[myUserId]?.lastReadAt;
      _boundaryCaptured = true;
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

  Future<void> _loadPinned() async {
    _pinned = await _chat.pinned(token, channelId);
    notifyListeners();
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

  // Sending
  String _newClientId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${myUserId.hashCode}-${_sendCounter++}';

  Future<void> sendText(
    String raw, {
    String? replyToId,
    ReplyPreview? replyPreview,
    List<String> mentions = const [],
  }) async {
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
      replyToId: replyToId,
      replyPreview: replyPreview,
      mentions: mentions,
      createdAt: DateTime.now(),
      pending: true,
    ));

    final r = await _chat.sendText(
      token,
      channelId,
      body: body,
      clientId: clientId,
      replyToId: replyToId,
      mentions: mentions.isEmpty ? null : mentions,
    );
    _reconcile(clientId, r);
  }

  /// Called by the screen after it has uploaded the picked image to Cloudinary.
  Future<void> sendImage({
    required String mediaUrl,
    String? mediaMime,
    int? mediaW,
    int? mediaH,
    String? caption,
    String? replyToId,
    ReplyPreview? replyPreview,
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
      replyToId: replyToId,
      replyPreview: replyPreview,
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
      replyToId: replyToId,
    );
    _reconcile(clientId, r);
  }

  /// Send a just-picked image. The bubble appears immediately from the local
  /// file with a spinner; the upload and the server send happen behind it, so
  /// there is never a gap where nothing is on screen. The upload cannot report
  /// byte progress (Cloudinary's unsigned uploader does not), so the spinner is
  /// indeterminate. A failed upload leaves the bubble in the failed state for a
  /// tap-to-retry; a [cancelPending] call drops it and ignores the result.
  Future<void> sendImageLocal({
    required String localPath,
    String? mediaMime,
    int? mediaW,
    int? mediaH,
    String? caption,
    String? replyToId,
    ReplyPreview? replyPreview,
  }) async {
    final clientId = _newClientId();
    _addOptimistic(ChatMessage(
      id: 'local:$clientId',
      clientId: clientId,
      channelId: channelId,
      senderId: myUserId,
      kind: MessageKind.image,
      body: (caption ?? '').trim().isEmpty ? null : caption!.trim(),
      localPath: localPath,
      mediaMime: mediaMime,
      mediaW: mediaW ?? 0,
      mediaH: mediaH ?? 0,
      replyToId: replyToId,
      replyPreview: replyPreview,
      createdAt: DateTime.now(),
      pending: true,
    ));

    final url = await CloudinaryService().uploadImage(localPath, folder: 'chat');
    if (_canceled.remove(clientId)) return; // cancelled during upload

    if (url == null) {
      final temp = _byId['local:$clientId'];
      if (temp != null) {
        _byId['local:$clientId'] = temp.copyWith(pending: false, failed: true);
        _rebuild();
      }
      return;
    }

    final r = await _chat.sendImage(
      token,
      channelId,
      mediaUrl: url,
      mediaMime: mediaMime,
      mediaW: mediaW,
      mediaH: mediaH,
      caption: caption,
      clientId: clientId,
      replyToId: replyToId,
    );
    if (_canceled.remove(clientId)) return; // cancelled during the server send
    _reconcile(clientId, r);
  }

  /// Send a just-recorded voice note. The bubble appears immediately with its
  /// known [durationMs] and a spinner; the upload and the server send happen
  /// behind it, mirroring [sendImageLocal]. A failed upload leaves the bubble in
  /// the failed state for a tap-to-retry; a [cancelPending] call drops it.
  Future<void> sendAudioLocal({
    required String localPath,
    String? mediaMime,
    int durationMs = 0,
    String? replyToId,
    ReplyPreview? replyPreview,
  }) async {
    final clientId = _newClientId();
    _addOptimistic(ChatMessage(
      id: 'local:$clientId',
      clientId: clientId,
      channelId: channelId,
      senderId: myUserId,
      kind: MessageKind.audio,
      localPath: localPath,
      mediaMime: mediaMime,
      durationMs: durationMs,
      replyToId: replyToId,
      replyPreview: replyPreview,
      createdAt: DateTime.now(),
      pending: true,
    ));

    final url = await CloudinaryService().uploadAudio(localPath, folder: 'chat_audio');
    if (_canceled.remove(clientId)) return; // cancelled during upload

    if (url == null) {
      final temp = _byId['local:$clientId'];
      if (temp != null) {
        _byId['local:$clientId'] = temp.copyWith(pending: false, failed: true);
        _rebuild();
      }
      return;
    }

    final r = await _chat.sendAudio(
      token,
      channelId,
      mediaUrl: url,
      mediaMime: mediaMime,
      durationMs: durationMs,
      clientId: clientId,
      replyToId: replyToId,
    );
    if (_canceled.remove(clientId)) return; // cancelled during the server send
    _reconcile(clientId, r);
  }

  /// Cancel a still-uploading image or voice note: drop the optimistic bubble now
  /// and ignore the upload's result when it returns.
  void cancelPending(ChatMessage m) {
    final cid = m.clientId;
    if (cid == null || !m.pending) return;
    _canceled.add(cid);
    _byId.remove(m.id);
    _rebuild();
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
    if (failed.kind == MessageKind.image) {
      // A failed image usually failed at the upload, so it still has only its
      // local file — re-upload from there. If it uploaded but the server send
      // failed, the hosted url is enough. Either way the reply target is carried
      // through, so retrying a reply stays a reply.
      if (failed.localPath != null) {
        await sendImageLocal(
          localPath: failed.localPath!,
          mediaMime: failed.mediaMime,
          mediaW: failed.mediaW.toInt(),
          mediaH: failed.mediaH.toInt(),
          caption: failed.body,
          replyToId: failed.replyToId,
          replyPreview: failed.replyPreview,
        );
      } else if (failed.mediaUrl != null) {
        await sendImage(
          mediaUrl: failed.mediaUrl!,
          mediaMime: failed.mediaMime,
          mediaW: failed.mediaW.toInt(),
          mediaH: failed.mediaH.toInt(),
          caption: failed.body,
          replyToId: failed.replyToId,
          replyPreview: failed.replyPreview,
        );
      }
    } else if (failed.kind == MessageKind.audio && failed.localPath != null) {
      // A voice note only ever holds its local clip until the send lands, so a
      // retry always re-uploads from the recorded file.
      await sendAudioLocal(
        localPath: failed.localPath!,
        mediaMime: failed.mediaMime,
        durationMs: failed.durationMs.toInt(),
        replyToId: failed.replyToId,
        replyPreview: failed.replyPreview,
      );
    } else {
      await sendText(
        failed.body ?? '',
        replyToId: failed.replyToId,
        replyPreview: failed.replyPreview,
        mentions: failed.mentions,
      );
    }
  }

  // Reactions & delete
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

  /// Only a channel admin may pin, and only a real, non-system, non-deleted
  /// message. Unlike delete there is no "your own message" exception: a pin is an
  /// announcement to the whole room, not a thing a member does to their own line.
  bool canPin(ChatMessage m) {
    if (m.isSystem || m.isDeleted || m.pending || m.failed) return false;
    return _members[myUserId]?.isAdmin ?? false;
  }

  bool isPinned(String messageId) => _pinned.any((p) => p.id == messageId);

  /// Whether I am a channel admin — the one thing the pinned banner needs up
  /// front to decide whether to offer its unpin control, without a message in hand.
  bool get amAdmin => _members[myUserId]?.isAdmin ?? false;

  /// Pin or unpin. Not optimistic: pinning is rare and admin-only, and the server
  /// echoes the updated message and nudges every client to refetch the banner, so
  /// a refetch on success is both correct and simplest.
  Future<Map<String, dynamic>> togglePin(ChatMessage m, {required bool pinned}) async {
    final r = await _chat.setPinned(token, channelId, m.id, pinned: pinned);
    if (r['success'] == true) {
      if (r['data'] is Map && (r['data'] as Map).containsKey('id')) {
        _byId[m.id] = ChatMessage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
        _rebuild();
      }
      await _loadPinned();
    }
    return r;
  }

  // Live event handlers
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

  /// Somebody pinned or unpinned in this room. The event is a bare nudge, so the
  /// banner is refetched rather than reconstructed from a payload.
  void _onPinnedChanged(Map<String, dynamic> data) {
    if ('${data['channelId']}' != channelId) return;
    _loadPinned();
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
    await _loadPinned();
  }

  // Tick computation
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

  // Read marking
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
  /// cadence; this method forwards it — a no-op when the socket is down.
  void sendTyping(bool typing) => _rt.sendTyping(channelId, typing);

  // Helpers
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
