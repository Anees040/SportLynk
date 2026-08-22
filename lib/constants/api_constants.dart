import 'package:flutter/foundation.dart';

class ApiConstants {
  ApiConstants._();

  /// Where the backend lives. One value, overridable at build time.
  ///
  /// ```
  /// flutter run                                                    # emulator
  /// flutter run  --dart-define=API_BASE_URL=http://192.170.0.110:3000/api   # phone on your Wi-Fi
  /// flutter build apk --release --dart-define=API_BASE_URL=https://<app>.onrender.com/api   # anywhere
  /// ```
  ///
  /// `bool.hasEnvironment` rather than `String.fromEnvironment(...).isEmpty`,
  /// because `.isEmpty` is not const-evaluable and this has to stay `const`.
  ///
  /// The default is the **emulator** address. `10.0.2.2` is the alias Android's
  /// emulator gives the host machine's localhost; it is meaningless on a real
  /// phone, so a physical device always needs the `--dart-define`. See README →
  /// "Run modes" and doc/DEPLOY_GUIDE.md.
  static const String baseUrl = bool.hasEnvironment('API_BASE_URL')
      ? String.fromEnvironment('API_BASE_URL')
      : (kIsWeb ? 'http://localhost:3000/api' : 'http://10.0.2.2:3000/api');

  // Auth
  static const String registerPlayer = '/auth/register/player';
  static const String registerOwner = '/auth/register/owner';
  static const String login = '/auth/login';
  static const String verifyPhone = '/auth/verify-phone';
  static const String forgotPasswordSendOtp = '/auth/forgot-password/send-otp';
  static const String forgotPasswordReset = '/auth/forgot-password/reset';
  static const String me = '/auth/me';

  // Venues (public)
  static const String venues = '/venues';
  static String venueById(String id) => '/venues/$id';
  static String venueSlots(String id) => '/venues/$id/slots';

  // Bookings (player)
  static const String bookings = '/bookings';
  static const String myBookings = '/bookings/my';

  // Owner
  static const String ownerVenues = '/owner/venues';
  static String ownerVenueSlots(String venueId) => '/owner/venues/$venueId/slots';
  static const String ownerBookings = '/owner/bookings';
  static String approveBooking(String id) => '/owner/bookings/$id/approve';
  static String rejectBooking(String id) => '/owner/bookings/$id/reject';
  static const String checkin = '/owner/checkin';
  static const String checkinDecide = '/owner/checkin/decide';

  // ── Realtime (Socket.IO) ────────────────────────────────────
  /// The Socket.IO origin. The server mounts engine.io at the ROOT (`/socket.io`),
  /// not under `/api`, so the socket must connect to the bare origin — [baseUrl]
  /// with its trailing `/api` stripped. Getting this wrong is the classic "chat
  /// won't connect but REST works" bug, so it is derived here once.
  static String get socketUrl {
    const b = baseUrl;
    return b.endsWith('/api') ? b.substring(0, b.length - 4) : b;
  }

  // ── Teams (S2) ──────────────────────────────────────────────
  static const String teams = '/teams';
  static const String myTeams = '/teams/mine';
  static const String teamRankings = '/teams/rankings';
  static const String teamDiscover = '/teams/discover';
  static String team(String id) => '/teams/$id';
  static String teamInvites(String id) => '/teams/$id/invites';
  static String teamInvite(String id, String inviteId) => '/teams/$id/invites/$inviteId';
  static String teamInvitePreview(String token) => '/teams/invites/$token';
  static String teamJoin(String token) => '/teams/join/$token';
  static String teamJoinRequest(String id) => '/teams/$id/join-request';
  static String teamRequests(String id) => '/teams/$id/requests';
  static String teamRequest(String id, String requestId) => '/teams/$id/requests/$requestId';
  static String teamMember(String id, String userId) => '/teams/$id/members/$userId';
  static String leaveTeam(String id) => '/teams/$id/members/me';

  // ── Chat (S2) ───────────────────────────────────────────────
  static String chatForTeam(String teamId) => '/chat/team/$teamId';
  static String chatMessages(String channelId) => '/chat/$channelId/messages';
  static String chatRead(String channelId) => '/chat/$channelId/read';
  static String chatMembers(String channelId) => '/chat/$channelId/members';
  static String chatReactions(String channelId, String messageId) => '/chat/$channelId/messages/$messageId/reactions';
  static String chatMessage(String channelId, String messageId) => '/chat/$channelId/messages/$messageId';
}
