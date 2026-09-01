/// chat_channel.dart — one row of the inbox (S.7 Wave B).
///
/// A channel row is not just a name. `context` is resolved server-side per
/// channel type and is what makes the list readable: a booking row carries its
/// live status and slot ("Confirmed · Sat 5 Sept, 6:00 pm"), a coordination row
/// carries the scoreline, a team row its member count. The client renders that
/// string — it never re-derives it, because the status vocabulary and the PKT
/// wall-clock formatting live on the server and a second copy here would drift.
///
/// Every numeric field goes through [asNum]: pg hands decimal back as a string
/// and a raw `as num` on "3" throws.
library;

import 'team.dart' show asNum;

/// The three human channel types. `assistant` is deliberately absent — Scout has
/// its own screen and the inbox endpoint filters it out, so a value the client
/// cannot receive should not be nameable here.
enum ChatChannelType {
  booking,
  captain,
  team,
  unknown;

  static ChatChannelType parse(String? raw) => switch (raw) {
        'booking' => ChatChannelType.booking,
        'captain' => ChatChannelType.captain,
        'team' => ChatChannelType.team,
        _ => ChatChannelType.unknown,
      };

  String get wire => name;

  /// The section heading this row files under.
  String get sectionLabel => switch (this) {
        ChatChannelType.booking => 'Bookings',
        ChatChannelType.captain => 'Matches',
        ChatChannelType.team => 'Teams',
        ChatChannelType.unknown => 'Other',
      };
}

/// The per-type subtitle block, computed by the server. Only the fields that
/// apply to a type are present, so everything past [subtitle] is nullable and the
/// UI asks for what it needs rather than switching on `kind` twice.
class ChatChannelContext {
  final String kind; // 'booking' | 'captain' | 'team'
  final String? status; // booking status, or match status; absent on a team
  final String? title;
  final String? subtitle;
  final String? imageUrl;

  final String? venueName; // booking
  final String? city; // booking
  final String? slotLabel; // booking — already PKT wall clock, never re-zoned

  final String? opponentName; // captain
  final bool isTournament; // captain

  final String? sport; // team
  final int? memberCount; // team

  const ChatChannelContext({
    required this.kind,
    this.status,
    this.title,
    this.subtitle,
    this.imageUrl,
    this.venueName,
    this.city,
    this.slotLabel,
    this.opponentName,
    this.isTournament = false,
    this.sport,
    this.memberCount,
  });

  factory ChatChannelContext.fromJson(Map<String, dynamic> j) => ChatChannelContext(
        kind: '${j['kind'] ?? ''}',
        status: j['status'] as String?,
        title: j['title'] as String?,
        subtitle: j['subtitle'] as String?,
        imageUrl: j['imageUrl'] as String?,
        venueName: j['venueName'] as String?,
        city: j['city'] as String?,
        slotLabel: j['slotLabel'] as String?,
        opponentName: j['opponentName'] as String?,
        isTournament: j['isTournament'] == true,
        sport: j['sport'] as String?,
        memberCount: j['memberCount'] == null ? null : asNum(j['memberCount']).toInt(),
      );
}

/// One inbox row.
class ChatChannel {
  final String id;
  final ChatChannelType type;
  final String? refId;
  final String title;
  final String? imageUrl;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final String? lastMessageSenderId;
  final String? lastMessageSenderName;
  final int messageCount;
  final int unread;
  final bool muted;
  final DateTime? mutedUntil;
  final String role; // chat role: 'admin' | 'member'
  final DateTime? sortAt;
  final ChatChannelContext? context;

  const ChatChannel({
    required this.id,
    required this.type,
    required this.title,
    this.refId,
    this.imageUrl,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.lastMessageSenderId,
    this.lastMessageSenderName,
    this.messageCount = 0,
    this.unread = 0,
    this.muted = false,
    this.mutedUntil,
    this.role = 'member',
    this.sortAt,
    this.context,
  });

  bool get isUnread => unread > 0;
  bool get isAdmin => role == 'admin';
  String? get subtitle => context?.subtitle;

  /// The line under the title. Falls back to the context subtitle for a room that
  /// has no messages yet, so a freshly opened room reads as its own reason to tap
  /// rather than as an empty row.
  ///
  /// A sender prefix is added only where there are more than two people who could
  /// have written it — a booking room has exactly two, so "Ali: ok" there tells
  /// the reader nothing they cannot see from the title. A system pill has no
  /// sender and is never prefixed.
  String previewLine(String myUserId) {
    final body = lastMessagePreview;
    if (body == null || body.trim().isEmpty) {
      return context?.subtitle ?? 'No messages yet';
    }
    final isGroup = type == ChatChannelType.team || type == ChatChannelType.captain;
    if (!isGroup || lastMessageSenderId == null) return body;
    final who = lastMessageSenderId == myUserId
        ? 'You'
        : (lastMessageSenderName ?? 'Someone').split(' ').first;
    return '$who: $body';
  }

  factory ChatChannel.fromJson(Map<String, dynamic> j) => ChatChannel(
        id: '${j['id']}',
        type: ChatChannelType.parse(j['type'] as String?),
        refId: j['refId'] as String?,
        title: '${j['title'] ?? 'Chat'}',
        imageUrl: j['imageUrl'] as String?,
        lastMessageAt: _date(j['lastMessageAt']),
        lastMessagePreview: j['lastMessagePreview'] as String?,
        lastMessageSenderId: j['lastMessageSenderId'] as String?,
        lastMessageSenderName: j['lastMessageSenderName'] as String?,
        messageCount: asNum(j['messageCount']).toInt(),
        unread: asNum(j['unread']).toInt(),
        muted: j['muted'] == true,
        mutedUntil: _date(j['mutedUntil']),
        role: '${j['role'] ?? 'member'}',
        sortAt: _date(j['sortAt']),
        context: j['context'] is Map
            ? ChatChannelContext.fromJson(Map<String, dynamic>.from(j['context'] as Map))
            : null,
      );

  ChatChannel copyWith({
    int? unread,
    bool? muted,
    DateTime? mutedUntil,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    String? lastMessageSenderId,
    String? lastMessageSenderName,
  }) =>
      ChatChannel(
        id: id,
        type: type,
        refId: refId,
        title: title,
        imageUrl: imageUrl,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        lastMessageSenderId: lastMessageSenderId ?? this.lastMessageSenderId,
        lastMessageSenderName: lastMessageSenderName ?? this.lastMessageSenderName,
        messageCount: messageCount,
        unread: unread ?? this.unread,
        muted: muted ?? this.muted,
        // `mutedUntil` is cleared by an un-mute, so it cannot use `??`: the
        // server answering `{muted:false, mutedUntil:null}` must be able to erase
        // the old timestamp, and `?? this.mutedUntil` would silently keep it.
        mutedUntil: (muted == false) ? mutedUntil : (mutedUntil ?? this.mutedUntil),
        role: role,
        sortAt: sortAt,
        context: context,
      );
}

/// One page of the inbox. [nextCursor] is the server's own `sortAt` string and is
/// passed back untouched — it is keyed on the expression the ORDER BY uses, so a
/// cursor built here would skip or repeat rows at the page seam.
class ChatInboxPage {
  final List<ChatChannel> items;
  final String? nextCursor;

  const ChatInboxPage({this.items = const [], this.nextCursor});

  bool get hasMore => nextCursor != null;

  factory ChatInboxPage.fromJson(Map<String, dynamic> j) => ChatInboxPage(
        items: (j['items'] as List? ?? [])
            .whereType<Map>()
            .map((m) => ChatChannel.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        nextCursor: j['nextCursor'] == null ? null : '${j['nextCursor']}',
      );
}

/// The header badge. Muted rooms are excluded by the server, so this total is
/// always "what the user asked to be told about" and never needs client filtering.
class ChatUnread {
  final int total;
  final int rooms;
  final Map<ChatChannelType, int> byType;

  const ChatUnread({this.total = 0, this.rooms = 0, this.byType = const {}});

  int of(ChatChannelType t) => byType[t] ?? 0;

  factory ChatUnread.fromJson(Map<String, dynamic> j) {
    final raw = j['byType'] is Map ? Map<String, dynamic>.from(j['byType'] as Map) : const {};
    return ChatUnread(
      total: asNum(j['total']).toInt(),
      rooms: asNum(j['rooms']).toInt(),
      byType: {
        for (final e in raw.entries)
          if (ChatChannelType.parse(e.key) != ChatChannelType.unknown)
            ChatChannelType.parse(e.key): asNum(e.value).toInt(),
      },
    );
  }
}

/// One FR8.10 reply chip. Advisory: tapping it fills the composer and nothing is
/// sent, which is why the whole payload carries [QuickReplySet.advisory].
class QuickReply {
  final String text;
  final String? intent;

  const QuickReply({required this.text, this.intent});

  factory QuickReply.fromJson(Map<String, dynamic> j) =>
      QuickReply(text: '${j['text'] ?? ''}', intent: j['intent'] as String?);
}

/// The quick-reply response. [source] is the honest provenance of the intent:
/// `model` when the released classifier answered, `lexicon` when the keyword table
/// did because ml-service was unreachable, `unavailable` when neither could.
/// The UI shows the sparkle badge only for `model` — the same rule the venue rail
/// follows, for the same reason.
class QuickReplySet {
  final List<QuickReply> suggestions;
  final String? intent;
  final double confidence;
  final String audience; // 'owner' | 'player' | 'captain'
  final String source; // 'model' | 'lexicon' | 'unavailable'
  final String? modelVersion;
  final bool advisory;

  const QuickReplySet({
    this.suggestions = const [],
    this.intent,
    this.confidence = 0,
    this.audience = 'player',
    this.source = 'unavailable',
    this.modelVersion,
    this.advisory = true,
  });

  bool get isEmpty => suggestions.isEmpty;
  bool get fromModel => source == 'model';

  factory QuickReplySet.fromJson(Map<String, dynamic> j) => QuickReplySet(
        suggestions: (j['suggestions'] as List? ?? [])
            .whereType<Map>()
            .map((m) => QuickReply.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        intent: j['intent'] as String?,
        confidence: asNum(j['confidence']).toDouble(),
        audience: '${j['audience'] ?? 'player'}',
        source: '${j['source'] ?? 'unavailable'}',
        modelVersion: j['modelVersion'] as String?,
        advisory: j['advisory'] != false,
      );
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse('$v')?.toLocal();
}
