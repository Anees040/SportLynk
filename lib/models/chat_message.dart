import 'team.dart' show asNum;

/// The kind of a message. Mirrors the DB `kind` column exactly. `audio` is a
/// voice note: a hosted clip URL, its mime, and how long it runs in [durationMs].
/// `poll` is a question with options; its tallies live in [ChatPoll], carried
/// alongside the message.
enum MessageKind { text, image, audio, poll, system }

MessageKind _kindFrom(dynamic raw) {
  switch ('$raw') {
    case 'image':
      return MessageKind.image;
    case 'audio':
      return MessageKind.audio;
    case 'poll':
      return MessageKind.poll;
    case 'system':
      return MessageKind.system;
    default:
      return MessageKind.text;
  }
}

/// The delivery state drawn beside one of my messages:
///   sending  → clock (optimistic, not yet acknowledged by the server)
///   sent     → single grey tick (row exists on the server)
///   delivered→ double grey tick (every other member's device has it)
///   read     → double blue tick (every other member has opened the chat since)
/// In a group these collapse across other members: the weakest wins, so a
/// message is only "read" once the last person has read it — exactly WhatsApp.
enum TickState { sending, sent, delivered, read }

class MessageReaction {
  final String emoji;
  final String userId;
  const MessageReaction(this.emoji, this.userId);

  factory MessageReaction.fromJson(Map<String, dynamic> j) =>
      MessageReaction('${j['emoji']}', '${j['userId'] ?? j['user_id']}');

  Map<String, dynamic> toJson() => {'emoji': emoji, 'userId': userId};
}

/// The quoted parent shown above a reply's own body. Denormalised by the server
/// (chatCore.REPLY_PREVIEW_SQL) so a reply renders its quote without the parent
/// being loaded — the parent is usually far up the scroll, or not loaded at all.
/// [deleted] is true when the parent was deleted for everyone; the quote then
/// reads "This message was deleted" rather than losing its head.
class ReplyPreview {
  final String id;
  final String? senderName;
  final MessageKind kind;
  final bool deleted;
  final String? body;

  const ReplyPreview({
    required this.id,
    this.senderName,
    this.kind = MessageKind.text,
    this.deleted = false,
    this.body,
  });

  factory ReplyPreview.fromJson(Map<String, dynamic> j) => ReplyPreview(
        id: '${j['id']}',
        senderName: j['senderName'] as String?,
        kind: _kindFrom(j['kind']),
        deleted: j['deleted'] == true,
        body: j['body'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'senderName': senderName,
        'kind': kind.name,
        'deleted': deleted,
        'body': body,
      };

  /// Build a quote from a message already in hand — the optimistic reply shows
  /// its quote immediately, before the server echoes the denormalised copy back.
  factory ReplyPreview.of(ChatMessage m) => ReplyPreview(
        id: m.id,
        senderName: m.senderName,
        kind: m.kind,
        deleted: m.isDeleted,
        body: m.body,
      );

  /// The one line the quote shows: a tombstone, a media label, or the text.
  String get snippet {
    if (deleted) return 'This message was deleted';
    switch (kind) {
      case MessageKind.image:
        return 'Photo';
      case MessageKind.audio:
        return 'Voice message';
      default:
        return (body ?? '').trim();
    }
  }
}

/// One vote on a poll: which option, and who cast it (votes are named, so a tap
/// on a tally can show the voters).
class PollVote {
  final int optionIndex;
  final String userId;
  final String userName;
  const PollVote(
      {required this.optionIndex, required this.userId, required this.userName});

  factory PollVote.fromJson(Map<String, dynamic> j) => PollVote(
        optionIndex: asNum(j['optionIndex']).toInt(),
        userId: '${j['userId']}',
        userName: '${j['userName'] ?? 'Someone'}',
      );

  Map<String, dynamic> toJson() =>
      {'optionIndex': optionIndex, 'userId': userId, 'userName': userName};
}

/// A poll carried by a message of kind [MessageKind.poll]: the question, the
/// fixed options, whether more than one may be chosen, and every vote. The UI
/// derives tallies and percentages from [votes] so a vote arriving over the
/// socket needs no separate count to stay in sync.
class ChatPoll {
  final String id;
  final String question;
  final List<String> options;
  final bool allowMultiple;
  final bool closed;
  final List<PollVote> votes;

  const ChatPoll({
    required this.id,
    required this.question,
    required this.options,
    this.allowMultiple = false,
    this.closed = false,
    this.votes = const [],
  });

  factory ChatPoll.fromJson(Map<String, dynamic> j) => ChatPoll(
        id: '${j['id']}',
        question: '${j['question'] ?? ''}',
        options: (j['options'] as List? ?? const []).map((e) => '$e').toList(),
        allowMultiple: j['allowMultiple'] == true,
        closed: j['closed'] == true,
        votes: (j['votes'] as List? ?? const [])
            .whereType<Map>()
            .map((v) => PollVote.fromJson(Map<String, dynamic>.from(v)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        'options': options,
        'allowMultiple': allowMultiple,
        'closed': closed,
        'votes': votes.map((v) => v.toJson()).toList(),
      };

  int countFor(int optionIndex) =>
      votes.where((v) => v.optionIndex == optionIndex).length;

  /// Distinct people who have voted — the denominator for an option's share.
  int get totalVoters => votes.map((v) => v.userId).toSet().length;

  bool didVote(String userId, int optionIndex) =>
      votes.any((v) => v.userId == userId && v.optionIndex == optionIndex);

  List<String> voterNames(int optionIndex) => votes
      .where((v) => v.optionIndex == optionIndex)
      .map((v) => v.userName)
      .toList();

  double fraction(int optionIndex) {
    final denom = totalVoters;
    return denom == 0 ? 0 : countFor(optionIndex) / denom;
  }
}

class ChatMessage {
  final String id;
  final String? clientId;
  final String channelId;
  final String? senderId;
  final String? senderName;
  final String? senderAvatar;
  final MessageKind kind;
  final String? body;
  final String? mediaUrl;
  final String? mediaMime;
  final num mediaW;
  final num mediaH;
  final num durationMs;

  /// Amplitude samples (0..1) captured while a voice note recorded, drawn as the
  /// player's waveform. Empty for a text/image message, or for a voice note
  /// recorded before the client started sending samples — the player then falls
  /// back to a plain progress track rather than inventing a shape.
  final List<double> waveform;

  final String? replyToId;
  final ReplyPreview? replyPreview;

  /// The poll carried by a [MessageKind.poll] message, null for any other kind.
  final ChatPoll? poll;

  /// The user ids this message @-mentions. Validated against live membership by
  /// the server, so every id here is (or was) a real member of the channel.
  final List<String> mentions;

  final DateTime? pinnedAt;
  final Map<String, dynamic>? systemMeta;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final List<MessageReaction> reactions;

  /// Client-only. True while an optimistic message waits for its server ack;
  /// [failed] flips true if the send errored so the bubble can offer a retry.
  final bool pending;
  final bool failed;

  /// Client-only. The picked file's local path (a device path on mobile, a blob
  /// URL on web), shown as an instant preview while the image uploads. Null once
  /// the message is a real server row with a hosted [mediaUrl].
  final String? localPath;

  ChatMessage({
    required this.id,
    this.clientId,
    required this.channelId,
    this.senderId,
    this.senderName,
    this.senderAvatar,
    this.kind = MessageKind.text,
    this.body,
    this.mediaUrl,
    this.mediaMime,
    this.mediaW = 0,
    this.mediaH = 0,
    this.durationMs = 0,
    this.waveform = const [],
    this.replyToId,
    this.replyPreview,
    this.poll,
    this.mentions = const [],
    this.pinnedAt,
    this.systemMeta,
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.reactions = const [],
    this.pending = false,
    this.failed = false,
    this.localPath,
  });

  bool get isSystem => kind == MessageKind.system;
  bool get isImage => kind == MessageKind.image;
  bool get isAudio => kind == MessageKind.audio;
  bool get isPoll => kind == MessageKind.poll;
  bool get isDeleted => deletedAt != null;
  bool get hasCaption => (body ?? '').trim().isNotEmpty;
  bool get isReply => replyPreview != null;
  bool get isPinned => pinnedAt != null;

  /// The voice note's length as `m:ss`, from [durationMs]. Falls back to `0:00`
  /// when the length is not yet known (a still-uploading clip carries its own,
  /// measured while recording).
  String get durationLabel {
    final total = (durationMs / 1000).round();
    final m = total ~/ 60;
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// The image's natural aspect ratio, clamped so a freak-tall or freak-wide
  /// photo can't blow out the bubble. Falls back to a gentle portrait.
  double get aspectRatio {
    if (mediaW <= 0 || mediaH <= 0) return 0.75;
    return (mediaW / mediaH).clamp(0.5, 1.9).toDouble();
  }

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: '${j['id']}',
        clientId: j['client_id']?.toString(),
        channelId: '${j['channel_id']}',
        senderId: j['sender_id']?.toString(),
        senderName: j['sender_name'] as String?,
        senderAvatar: j['sender_avatar'] as String?,
        kind: _kindFrom(j['kind']),
        body: j['body'] as String?,
        mediaUrl: j['media_url'] as String?,
        mediaMime: j['media_mime'] as String?,
        mediaW: asNum(j['media_w']),
        mediaH: asNum(j['media_h']),
        durationMs: asNum(j['duration_ms']),
        waveform: (j['waveform'] as List? ?? const [])
            .map((e) => (asNum(e)).toDouble().clamp(0.0, 1.0))
            .toList(),
        replyToId: j['reply_to_id']?.toString(),
        replyPreview: j['reply_preview'] is Map
            ? ReplyPreview.fromJson(Map<String, dynamic>.from(j['reply_preview'] as Map))
            : null,
        poll: j['poll'] is Map
            ? ChatPoll.fromJson(Map<String, dynamic>.from(j['poll'] as Map))
            : null,
        mentions: (j['mentions'] as List? ?? [])
            .map((e) => '$e')
            .toList(),
        pinnedAt: _date(j['pinned_at']),
        systemMeta: j['system_meta'] is Map
            ? Map<String, dynamic>.from(j['system_meta'] as Map)
            : null,
        createdAt: DateTime.tryParse('${j['created_at']}')?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        editedAt: _date(j['edited_at']),
        deletedAt: _date(j['deleted_at']),
        reactions: (j['reactions'] as List? ?? [])
            .whereType<Map>()
            .map((r) => MessageReaction.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
        // Client-only fields. Absent on a server payload (defaulting to
        // false/null); present only when a message is rehydrated from the local
        // cache, so an offline-queued or failed bubble comes back in its state.
        pending: j['pending'] == true,
        failed: j['failed'] == true,
        localPath: j['local_path'] as String?,
      );

  /// Server-shaped map for the local cache, symmetric with [fromJson]. Includes
  /// the client-only [pending]/[failed]/[localPath] so a queued or failed message
  /// survives an app restart and can be flushed or retried on reconnect.
  Map<String, dynamic> toJson() => {
        'id': id,
        'client_id': clientId,
        'channel_id': channelId,
        'sender_id': senderId,
        'sender_name': senderName,
        'sender_avatar': senderAvatar,
        'kind': kind.name,
        'body': body,
        'media_url': mediaUrl,
        'media_mime': mediaMime,
        'media_w': mediaW,
        'media_h': mediaH,
        'duration_ms': durationMs,
        'waveform': waveform,
        'reply_to_id': replyToId,
        'reply_preview': replyPreview?.toJson(),
        'poll': poll?.toJson(),
        'mentions': mentions,
        'pinned_at': pinnedAt?.toUtc().toIso8601String(),
        'system_meta': systemMeta,
        'created_at': createdAt.toUtc().toIso8601String(),
        'edited_at': editedAt?.toUtc().toIso8601String(),
        'deleted_at': deletedAt?.toUtc().toIso8601String(),
        'reactions': reactions.map((r) => r.toJson()).toList(),
        'pending': pending,
        'failed': failed,
        'local_path': localPath,
      };

  ChatMessage copyWith({
    String? id,
    bool? pending,
    bool? failed,
    List<MessageReaction>? reactions,
    DateTime? deletedAt,
    String? localPath,
    ChatPoll? poll,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        clientId: clientId,
        channelId: channelId,
        senderId: senderId,
        senderName: senderName,
        senderAvatar: senderAvatar,
        kind: kind,
        body: body,
        mediaUrl: mediaUrl,
        mediaMime: mediaMime,
        mediaW: mediaW,
        mediaH: mediaH,
        durationMs: durationMs,
        waveform: waveform,
        replyToId: replyToId,
        replyPreview: replyPreview,
        poll: poll ?? this.poll,
        mentions: mentions,
        pinnedAt: pinnedAt,
        systemMeta: systemMeta,
        createdAt: createdAt,
        editedAt: editedAt,
        deletedAt: deletedAt ?? this.deletedAt,
        reactions: reactions ?? this.reactions,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
        localPath: localPath ?? this.localPath,
      );

  /// Reactions folded to `{emoji: count}`, preserving first-seen order so the
  /// chips don't reshuffle as people react.
  Map<String, int> get reactionCounts {
    final counts = <String, int>{};
    for (final r in reactions) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    return counts;
  }

  bool reactedBy(String userId) => reactions.any((r) => r.userId == userId);
  String? myReaction(String userId) {
    for (final r in reactions) {
      if (r.userId == userId) return r.emoji;
    }
    return null;
  }
}

/// A channel member with the two watermarks that drive group ticks, plus the
/// last-seen used for the "online / last seen" subtitle. Watermarks default to
/// the epoch on the server, so a member who has never opened the chat can never
/// accidentally mark a message delivered/read.
class ChatMember {
  final String userId;
  final String role; // 'admin' | 'member' (chat role, not team role)
  final String name;
  final String? avatarUrl;
  final DateTime lastReadAt;
  final DateTime lastDeliveredAt;
  final DateTime? lastSeenAt;

  ChatMember({
    required this.userId,
    required this.role,
    required this.name,
    this.avatarUrl,
    required this.lastReadAt,
    required this.lastDeliveredAt,
    this.lastSeenAt,
  });

  bool get isAdmin => role == 'admin';

  factory ChatMember.fromJson(Map<String, dynamic> j) => ChatMember(
        userId: '${j['user_id']}',
        role: '${j['role'] ?? 'member'}',
        name: '${j['name'] ?? 'Player'}',
        avatarUrl: j['avatar_url'] as String?,
        lastReadAt: _epoch(j['last_read_at']),
        lastDeliveredAt: _epoch(j['last_delivered_at']),
        lastSeenAt: _date(j['last_seen_at']),
      );
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse('$v')?.toLocal();
}

DateTime _epoch(dynamic v) =>
    DateTime.tryParse('$v')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
