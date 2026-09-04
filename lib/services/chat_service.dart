import '../constants/api_constants.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import 'api_service.dart';

/// REST calls for the team chat. The live half (typing, receipts, presence, and
/// the push of new messages) is [RealtimeService]; this covers history, sending,
/// read-marks, the member watermarks that drive ticks, reactions and deletes.
///
/// Sends return the raw `{success, data}` map: `data` is the persisted message,
/// which the controller uses to reconcile its optimistic copy (matching on the
/// `clientId` it generated).
class ChatService {
  final ApiClient _api = ApiClient();

  Future<Map<String, dynamic>> channelForTeam(String token, String teamId) =>
      _api.get(ApiConstants.chatForTeam(teamId), token: token);

  Future<List<ChatMessage>> messages(
    String token,
    String channelId, {
    String? before,
    int limit = 40,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (before != null) params['before'] = before;
    final r = await _api.get(ApiConstants.chatMessages(channelId), token: token, queryParams: params);
    if (r['success'] != true) return <ChatMessage>[];
    return (r['data'] as List? ?? [])
        .whereType<Map>()
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<Map<String, dynamic>> sendText(
    String token,
    String channelId, {
    required String body,
    required String clientId,
  }) =>
      _api.post(ApiConstants.chatMessages(channelId), {
        'kind': 'text',
        'body': body,
        'clientId': clientId,
      }, token: token);

  Future<Map<String, dynamic>> sendImage(
    String token,
    String channelId, {
    required String mediaUrl,
    String? mediaMime,
    int? mediaW,
    int? mediaH,
    String? caption,
    required String clientId,
  }) =>
      _api.post(ApiConstants.chatMessages(channelId), {
        'kind': 'image',
        'mediaUrl': mediaUrl,
        'mediaMime': ?mediaMime,
        'mediaW': ?mediaW,
        'mediaH': ?mediaH,
        if (caption != null && caption.isNotEmpty) 'body': caption,
        'clientId': clientId,
      }, token: token);

  /// Move my read watermark to now (or [at]) via REST — the fallback for when
  /// the socket isn't connected. GREATEST on the server keeps it monotonic.
  Future<Map<String, dynamic>> markRead(String token, String channelId, {DateTime? at}) =>
      _api.post(ApiConstants.chatRead(channelId), {
        if (at != null) 'at': at.toUtc().toIso8601String(),
      }, token: token);

  Future<List<ChatMember>> members(String token, String channelId) async {
    final r = await _api.get(ApiConstants.chatMembers(channelId), token: token);
    if (r['success'] != true) return <ChatMember>[];
    return (r['data'] as List? ?? [])
        .whereType<Map>()
        .map((m) => ChatMember.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Toggle a reaction. Same emoji again clears it; a different one replaces it.
  /// Returns the re-hydrated message so the caller can upsert it.
  Future<Map<String, dynamic>> react(String token, String channelId, String messageId, String emoji) =>
      _api.post(ApiConstants.chatReactions(channelId, messageId), {'emoji': emoji}, token: token);

  Future<Map<String, dynamic>> deleteMessage(String token, String channelId, String messageId) =>
      _api.delete(ApiConstants.chatMessage(channelId, messageId), token: token);

  // The inbox and the other two channel types

  /// One page of the inbox, newest activity first. Pass [cursor] back exactly as
  /// the previous page returned it.
  Future<ChatInboxPage> chats(
    String token, {
    int limit = 30,
    String? cursor,
    ChatChannelType? type,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (cursor != null) params['cursor'] = cursor;
    if (type != null && type != ChatChannelType.unknown) params['type'] = type.wire;
    final r = await _api.get(ApiConstants.chats, token: token, queryParams: params);
    if (r['success'] != true || r['data'] is! Map) return const ChatInboxPage();
    return ChatInboxPage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// The header badge. Never throws and never partially fails — a badge that
  /// cannot load is a zero, not an error dialog over the home screen.
  Future<ChatUnread> unreadCount(String token) async {
    final r = await _api.get(ApiConstants.chatUnreadCount, token: token);
    if (r['success'] != true || r['data'] is! Map) return const ChatUnread();
    return ChatUnread.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// The room for a booking, or null when there is none.
  ///
  /// Null is a NORMAL answer, not a failure: a booking that is still pending has
  /// no room yet, one confirmed before rooms existed never will, and the
  /// server answers 404 rather than 403 for a non-member so a stranger cannot
  /// probe it. All three cases render as "no Message button", never as an error.
  Future<String?> channelForBooking(String token, String bookingId) =>
      _channelId(ApiConstants.chatForBooking(bookingId), token);

  /// The coordination room for a match, or null when the challenge was never
  /// accepted (or predates the rooms).
  Future<String?> channelForMatch(String token, String matchId) =>
      _channelId(ApiConstants.chatForMatch(matchId), token);

  Future<String?> _channelId(String path, String token) async {
    final r = await _api.get(path, token: token);
    if (r['success'] != true || r['data'] is! Map) return null;
    final id = (r['data'] as Map)['channelId'];
    return id == null ? null : '$id';
  }

  /// FR8.10 — three suggested replies for the other side's last message.
  ///
  /// Advisory: the result fills the composer and nothing is sent. Pass either the
  /// [messageId] of the message being replied to (preferred — the server reads the
  /// body itself and refuses one from another channel) or raw [text].
  Future<QuickReplySet> quickReplies(
    String token,
    String channelId, {
    String? messageId,
    String? text,
  }) async {
    final r = await _api.post(ApiConstants.chatQuickReplies(channelId), {
      'messageId': ?messageId,
      'text': ?text,
    }, token: token);
    if (r['success'] != true || r['data'] is! Map) return const QuickReplySet();
    return QuickReplySet.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// Mute or unmute one room for me. [hours] is capped server-side (1 hour to a
  /// year); passing `muted: false` clears it. Returns the server's own state so
  /// the caller never has to guess what "muted" now means.
  Future<Map<String, dynamic>> mute(
    String token,
    String channelId, {
    bool muted = true,
    int? hours,
  }) =>
      _api.post(ApiConstants.chatMute(channelId), {
        'muted': muted,
        'hours': ?hours,
      }, token: token);
}
