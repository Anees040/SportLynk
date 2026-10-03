import 'dart:async';
import 'dart:convert';

import 'package:cloudinary_public/cloudinary_public.dart' show CloudinaryResourceType;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Live upload fraction (0..1) per optimistic clientId, shown as a determinate
  /// ring on the bubble while its bytes are in flight and cleared once the upload
  /// finishes. Absent means "not uploading" — the bubble shows no ring.
  final Map<String, double> _uploadProgress = {};

  /// Why a failed send failed, per optimistic clientId. Cleared on a retry, so a
  /// bubble shows the reason for its latest attempt and nothing older.
  final Map<String, String> _sendError = {};

  /// Image uploads run a few at a time rather than strictly one after another, so
  /// a batch of photos appears and climbs together instead of trickling in; the
  /// cap keeps a phone's uplink from being split so thin that none makes progress.
  static const int _maxConcurrentUploads = 3;
  int _activeUploads = 0;
  final List<Future<void> Function()> _uploadQueue = [];

  /// Sends composed while the socket was down, held in arrival order and drained
  /// by [_flushOutbox] on reconnect. Each carries the clientId the optimistic
  /// bubble already shows, so a flush reuses that idempotency key rather than
  /// duplicating a row the server may have accepted before the drop.
  final List<_Queued> _outbox = [];
  bool _flushing = false;

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _connected = false;
  String? _error;
  int _sendCounter = 0;

  /// The visible "Connecting…" state, held back behind a short grace so a brief
  /// blip does not flash the bar. Distinct from [_connected], which flips at once
  /// because read-marking and the outbox key off the true socket state.
  bool _showConnecting = false;
  Timer? _connectingTimer;

  /// Debounces cache writes: the timeline rebuilds on nearly every event, but the
  /// cache only needs the settled result a moment later.
  Timer? _persistTimer;

  // Public view
  List<ChatMessage> get messages => _ordered;
  List<ChatMember> get members => _members.values.toList();
  List<ChatMessage> get pinned => _pinned;
  DateTime? get unreadBoundary => _unreadBoundary;
  bool get loading => _loading;
  bool get hasMore => _hasMore;
  bool get connected => _connected;

  /// Whether a message id is currently loaded in the timeline — used by the
  /// quote-jump to decide whether it must page in older history before scrolling.
  bool hasMessage(String id) => _byId.containsKey(id);

  /// The loaded message with [id], or null — used by the selection bar to act on
  /// the set of ids it holds without each row passing its whole message up.
  ChatMessage? messageById(String id) => _byId[id];

  /// The live upload fraction (0..1) for an optimistic message, or null when it
  /// is not uploading — so the bubble shows a determinate ring only while bytes
  /// are moving, and an indeterminate one for the brief server-send that follows.
  double? uploadProgressFor(ChatMessage m) =>
      m.clientId == null ? null : _uploadProgress[m.clientId];

  /// Why this message's send failed, or null. Shown on the bubble so a failure
  /// names its cause ("Upload preset not found") instead of only "Not sent".
  String? sendErrorFor(ChatMessage m) =>
      m.clientId == null ? null : _sendError[m.clientId];

  /// Whether to show the "Connecting…" bar: only once we have been offline past
  /// the grace, so a momentary reconnect stays silent.
  bool get reconnecting => _showConnecting;
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
    // Show the last cached page immediately so a reopened room — cold or offline
    // — is never a blank screen while the network resolves. The REST load below
    // upserts over this by id, so nothing double-renders.
    await _hydrateFromCache();

    _rt.ensureConnected(token);
    // Seed from the socket's current state. The connection stream is a broadcast
    // with no replay, so a chat opened after the socket already connected (the
    // common case — it connects at login) would otherwise never receive an
    // onConnect event and would sit on "Connecting…" forever despite being live.
    _connected = _rt.isConnected;
    if (!_connected) _scheduleConnectingBar();
    _subs.add(_rt.messages.listen(_onMessage));
    _subs.add(_rt.receipts.listen(_onReceipt));
    _subs.add(_rt.typing.listen(_onTyping));
    _subs.add(_rt.presence.listen(_onPresence));
    _subs.add(_rt.pinned.listen(_onPinnedChanged));
    _subs.add(_rt.connection.listen(_onConnection));

    _rt.joinChannel(channelId);
    // A cold open can rehydrate a pending send from a prior offline session while
    // the socket is already up (it connects at login, before this listener). No
    // up-edge will fire in that case, so drain the outbox once here.
    if (_connected) _flushOutbox();
    await _loadMembers();
    await _loadInitial();
    await _loadPinned();
  }

  // Local cache — a single per-channel key holding the newest page as JSON, so a
  // reopened room shows history before the socket or REST resolves.
  String get _cacheKey => 'chat_cache_$channelId';
  static const int _cacheLimit = 40;

  Future<void> _hydrateFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List).whereType<Map>();
      for (final j in list) {
        final m = ChatMessage.fromJson(Map<String, dynamic>.from(j));
        _byId.putIfAbsent(m.id, () => m);
        // A cached-pending send from a previous session is re-queued so it flushes
        // on reconnect; text and any still-present local media can resume, while a
        // send whose source is gone is surfaced as failed rather than a stuck clock.
        if (m.pending) _requeueFromCache(m);
      }
      if (_byId.isNotEmpty) {
        _loading = false;
        _rebuild();
      }
    } catch (_) {
      // A corrupt or version-skewed cache is discarded silently: it is only an
      // optimisation, and the REST load is the source of truth.
    }
  }

  void _requeueFromCache(ChatMessage m) {
    final cid = m.clientId;
    if (cid == null) return;
    switch (m.kind) {
      case MessageKind.text:
        _enqueue(cid, () => _doSendText(cid, m.body ?? '', m.replyToId, m.mentions));
      case MessageKind.image when m.localPath != null:
        _enqueue(cid, () => _uploadAndSendImage(cid, m.localPath!, m.mediaMime,
            m.mediaW.toInt(), m.mediaH.toInt(), m.body, m.replyToId));
      case MessageKind.audio when m.localPath != null:
        _enqueue(cid, () => _uploadAndSendAudio(
            cid, m.localPath!, m.mediaMime, m.durationMs.toInt(), m.waveform, m.replyToId));
      default:
        _byId[m.id] = m.copyWith(pending: false, failed: true);
    }
  }

  void _persistSoon() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), _persistCache);
  }

  Future<void> _persistCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Newest page only; a pending tail is always kept so a queued send survives
      // a restart even when it sits beyond the newest window.
      final tail = _ordered.length <= _cacheLimit
          ? _ordered
          : _ordered.sublist(_ordered.length - _cacheLimit);
      final pending = _ordered.where((m) => m.pending && !tail.contains(m));
      final keep = [...tail, ...pending];
      await prefs.setString(_cacheKey, jsonEncode(keep.map((m) => m.toJson()).toList()));
    } catch (_) {
      // Best-effort; a failed write only costs the next cold open its instant page.
    }
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
    _connectingTimer?.cancel();
    // Flush any debounced cache write immediately so the newest page is not lost
    // when the room is closed within the debounce window.
    if (_persistTimer?.isActive ?? false) {
      _persistTimer!.cancel();
      _persistCache();
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

    // Offline: hold the send as a pending bubble and queue it for the reconnect
    // flush. A send attempted while connected that then fails still falls through
    // to the red retry state via [_reconcile] — the queue is only for the offline
    // compose, not for masking genuine failures.
    if (!_connected) {
      _enqueue(clientId, () => _doSendText(clientId, body, replyToId, mentions));
      return;
    }
    await _doSendText(clientId, body, replyToId, mentions);
  }

  Future<void> _doSendText(String clientId, String body, String? replyToId,
      List<String> mentions) async {
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

    // Offline: the upload cannot proceed, so hold the bubble pending and defer the
    // whole upload-and-send to the reconnect flush rather than failing it red.
    if (!_connected) {
      _enqueue(clientId,
          () => _uploadAndSendImage(clientId, localPath, mediaMime, mediaW ?? 0, mediaH ?? 0, caption, replyToId));
      return;
    }
    // Online: schedule under the concurrency cap and return at once, so a batch of
    // photos all become visible bubbles immediately and upload in parallel rather
    // than one blocking the next.
    _scheduleUpload(() =>
        _uploadAndSendImage(clientId, localPath, mediaMime, mediaW ?? 0, mediaH ?? 0, caption, replyToId));
  }

  /// Run [task] under [_maxConcurrentUploads], queueing it in arrival order when
  /// the cap is reached and starting the next as each one settles.
  void _scheduleUpload(Future<void> Function() task) {
    if (_activeUploads >= _maxConcurrentUploads) {
      _uploadQueue.add(task);
      return;
    }
    _activeUploads++;
    () async {
      try {
        await task();
      } finally {
        _activeUploads--;
        if (_uploadQueue.isNotEmpty) {
          _scheduleUpload(_uploadQueue.removeAt(0));
        }
      }
    }();
  }

  /// Record an upload's byte progress for its bubble's ring. Rebuilds only when
  /// the visible 5% step changes, not on every frame the uploader reports.
  void _onUploadProgress(String clientId, int sent, int total) {
    if (total <= 0) return;
    final frac = (sent / total).clamp(0.0, 1.0);
    final prev = _uploadProgress[clientId] ?? -1;
    _uploadProgress[clientId] = frac;
    if ((frac * 20).floor() != (prev * 20).floor()) _rebuild();
  }

  Future<void> _uploadAndSendImage(String clientId, String localPath,
      String? mediaMime, int mediaW, int mediaH, String? caption, String? replyToId) async {
    final up = await CloudinaryService().upload(
      localPath,
      resourceType: CloudinaryResourceType.Image,
      folder: 'chat',
      onProgress: (sent, total) => _onUploadProgress(clientId, sent, total),
    );
    _uploadProgress.remove(clientId);
    if (_canceled.remove(clientId)) return; // cancelled during upload

    if (up.url == null) {
      _fail(clientId, up.error ?? 'Upload failed');
      return;
    }

    final r = await _chat.sendImage(
      token,
      channelId,
      mediaUrl: up.url!,
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

  /// Mark an optimistic message failed and record why, so the bubble can name
  /// the cause instead of showing a bare "Not sent" the user cannot act on.
  void _fail(String clientId, String reason) {
    _sendError[clientId] = reason;
    final temp = _byId['local:$clientId'];
    if (temp != null) {
      _byId['local:$clientId'] = temp.copyWith(pending: false, failed: true);
    }
    _rebuild();
  }

  /// Send a just-recorded voice note. The bubble appears immediately with its
  /// known [durationMs] and a spinner; the upload and the server send happen
  /// behind it, mirroring [sendImageLocal]. A failed upload leaves the bubble in
  /// the failed state for a tap-to-retry; a [cancelPending] call drops it.
  Future<void> sendAudioLocal({
    required String localPath,
    String? mediaMime,
    int durationMs = 0,
    List<double> waveform = const [],
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
      waveform: waveform,
      replyToId: replyToId,
      replyPreview: replyPreview,
      createdAt: DateTime.now(),
      pending: true,
    ));

    // Offline: defer the upload-and-send to the reconnect flush rather than
    // failing it red, mirroring the image path.
    if (!_connected) {
      _enqueue(clientId,
          () => _uploadAndSendAudio(clientId, localPath, mediaMime, durationMs, waveform, replyToId));
      return;
    }
    await _uploadAndSendAudio(clientId, localPath, mediaMime, durationMs, waveform, replyToId);
  }

  Future<void> _uploadAndSendAudio(String clientId, String localPath,
      String? mediaMime, int durationMs, List<double> waveform, String? replyToId) async {
    // Audio goes up under Cloudinary's Video resource type. An unsigned preset
    // limited to images refuses it, and that refusal is the one message that
    // explains why a voice note never arrives — so it is carried to the bubble
    // rather than collapsed into a bare failure.
    final up = await CloudinaryService().upload(
      localPath,
      resourceType: CloudinaryResourceType.Video,
      folder: 'chat_audio',
      onProgress: (sent, total) => _onUploadProgress(clientId, sent, total),
    );
    _uploadProgress.remove(clientId);
    if (_canceled.remove(clientId)) return; // cancelled during upload

    if (up.url == null) {
      _fail(clientId, up.error ?? 'Upload failed');
      return;
    }

    final r = await _chat.sendAudio(
      token,
      channelId,
      mediaUrl: up.url!,
      mediaMime: mediaMime,
      durationMs: durationMs,
      waveform: waveform,
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
    _uploadProgress.remove(cid);
    _sendError.remove(cid);
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
    // The previous attempt's reason must not outlive it, or a retry that is
    // still in flight would show the old failure under a live clock.
    if (failed.clientId != null) _sendError.remove(failed.clientId);
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
        waveform: failed.waveform,
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

  /// "Delete for me": drop one message from this reader's view. The row stays on
  /// the server for everyone else, so the only local effect is removing it from
  /// the timeline — and because the server filters it out of future history
  /// reads, it does not come back on a refresh. An optimistic message that never
  /// reached the server is simply forgotten.
  Future<Map<String, dynamic>> hideMessage(String messageId) async {
    final m = _byId[messageId];
    if (m == null) return {'success': false, 'message': 'Message not found.'};
    if (m.id.startsWith('local:')) {
      _byId.remove(messageId);
      _rebuild();
      return {'success': true};
    }
    final r = await _chat.hideMessage(token, channelId, messageId);
    if (r['success'] == true) {
      _byId.remove(messageId);
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

  /// Create a poll. The server posts the poll message and also pushes it over the
  /// socket; the returned row is upserted at once so the creator sees it without
  /// waiting for the echo.
  Future<Map<String, dynamic>> createPoll({
    required String question,
    required List<String> options,
    bool allowMultiple = false,
  }) async {
    final r = await _chat.createPoll(token, channelId,
        question: question, options: options, allowMultiple: allowMultiple);
    if (r['success'] == true && r['data'] is Map) {
      final msg = ChatMessage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
      _byId[msg.id] = msg;
      _rebuild();
    }
    return r;
  }

  /// Vote on (or un-vote) a poll option. Optimistic: the tally updates at once,
  /// mirroring the server's single/multi rule, then reconciles with the
  /// authoritative message the vote call returns (or reverts on failure).
  Future<void> votePoll(ChatMessage m, int optionIndex) async {
    final poll = m.poll;
    if (poll == null || poll.closed) return;
    final votes = [...poll.votes];
    if (poll.didVote(myUserId, optionIndex)) {
      votes.removeWhere((v) => v.userId == myUserId && v.optionIndex == optionIndex);
    } else {
      if (!poll.allowMultiple) votes.removeWhere((v) => v.userId == myUserId);
      votes.add(PollVote(
        optionIndex: optionIndex,
        userId: myUserId,
        userName: _members[myUserId]?.name ?? 'You',
      ));
    }
    _byId[m.id] = m.copyWith(
      poll: ChatPoll(
        id: poll.id,
        question: poll.question,
        options: poll.options,
        allowMultiple: poll.allowMultiple,
        closed: poll.closed,
        votes: votes,
      ),
    );
    _rebuild();

    final r = await _chat.votePoll(token, channelId, poll.id, optionIndex: optionIndex);
    if (r['success'] == true && r['data'] is Map) {
      _byId[m.id] = ChatMessage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
    } else {
      _byId[m.id] = m; // revert the optimistic change
    }
    _rebuild();
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
      // Reconnected: clear the grace, drain anything composed while offline, then
      // refresh members and the latest page so what was missed is folded in
      // (upsert dedupes overlaps, and the flush reuses each clientId).
      _connectingTimer?.cancel();
      _showConnecting = false;
      _rt.joinChannel(channelId);
      _flushOutbox();
      _resync();
    } else {
      _scheduleConnectingBar();
    }
    notifyListeners();
  }

  /// Reveal the "Connecting…" bar only after a short grace, so a momentary drop
  /// or the sliver of offline time at a cold open does not flash it.
  void _scheduleConnectingBar() {
    _connectingTimer?.cancel();
    _connectingTimer = Timer(const Duration(seconds: 3), () {
      if (!_connected) {
        _showConnecting = true;
        notifyListeners();
      }
    });
  }

  void _enqueue(String clientId, Future<void> Function() send) {
    _outbox.removeWhere((q) => q.clientId == clientId); // collapse a re-queue
    _outbox.add(_Queued(clientId, send));
  }

  /// Drain the offline outbox in arrival order once the socket is back. Each send
  /// carries its original clientId, so a message the server accepted just before
  /// the drop is deduped rather than doubled.
  Future<void> _flushOutbox() async {
    if (_flushing || _outbox.isEmpty) return;
    _flushing = true;
    final queued = List<_Queued>.from(_outbox);
    _outbox.clear();
    for (final q in queued) {
      if (!_connected) {
        _outbox.add(q); // dropped again mid-flush; hold for the next reconnect
        continue;
      }
      await q.send();
    }
    _flushing = false;
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
    _persistSoon();
  }

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
  static final DateTime _farFuture = DateTime.fromMillisecondsSinceEpoch(99999999999999);
}

/// A send held back while the socket is down. [clientId] is the idempotency key
/// the optimistic bubble already carries; [send] performs the real network call
/// when the reconnect flush runs it.
class _Queued {
  _Queued(this.clientId, this.send);
  final String clientId;
  final Future<void> Function() send;
}
