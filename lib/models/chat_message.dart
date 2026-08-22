import 'team.dart' show asNum;

/// The kind of a message. Mirrors the DB `kind` column exactly. `audio` exists
/// so the client can render voice notes the moment the backend starts accepting
/// them (a planned follow-up) without a model change.
enum MessageKind { text, image, audio, system }

MessageKind _kindFrom(dynamic raw) {
  switch ('$raw') {
    case 'image':
      return MessageKind.image;
    case 'audio':
      return MessageKind.audio;
    case 'system':
      return MessageKind.system;
    default:
      return MessageKind.text;
  }
}

/// The delivery state drawn beside one of MY messages:
///   sending  → clock (optimistic, not yet acknowledged by the server)
///   sent     → single grey tick (row exists on the server)
///   delivered→ double grey tick (every other member's device has it)
///   read     → double blue tick (every other member has opened the chat since)
/// In a group these collapse across OTHER members: the weakest wins, so a
/// message is only "read" once the last person has read it — exactly WhatsApp.
enum TickState { sending, sent, delivered, read }

class MessageReaction {
  final String emoji;
  final String userId;
  const MessageReaction(this.emoji, this.userId);

  factory MessageReaction.fromJson(Map<String, dynamic> j) =>
      MessageReaction('${j['emoji']}', '${j['userId'] ?? j['user_id']}');
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
  final String? replyToId;
  final Map<String, dynamic>? systemMeta;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final List<MessageReaction> reactions;

  /// Client-only. True while an optimistic message waits for its server ack;
  /// [failed] flips true if the send errored so the bubble can offer a retry.
  final bool pending;
  final bool failed;

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
    this.replyToId,
    this.systemMeta,
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.reactions = const [],
    this.pending = false,
    this.failed = false,
  });

  bool get isSystem => kind == MessageKind.system;
  bool get isImage => kind == MessageKind.image;
  bool get isDeleted => deletedAt != null;
  bool get hasCaption => (body ?? '').trim().isNotEmpty;

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
        replyToId: j['reply_to_id']?.toString(),
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
      );

  ChatMessage copyWith({
    String? id,
    bool? pending,
    bool? failed,
    List<MessageReaction>? reactions,
    DateTime? deletedAt,
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
        replyToId: replyToId,
        systemMeta: systemMeta,
        createdAt: createdAt,
        editedAt: editedAt,
        deletedAt: deletedAt ?? this.deletedAt,
        reactions: reactions ?? this.reactions,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
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
