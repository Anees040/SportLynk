import '../constants/api_constants.dart';
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
}
