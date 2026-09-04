import 'package:flutter/foundation.dart';

class ApiConstants {
  ApiConstants._();

  /// Where the backend lives. One value, overridable at build time.
  ///
  /// ```
  /// flutter run                                                    # emulator
  /// flutter run  --dart-define=API_BASE_URL=http://192.170.0.110:3000/api   # phone on the same Wi-Fi
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

  // Owner — AI pricing. These three sit behind the same owner auth as
  // the rest of this block; the venue id in the path is checked against the caller's
  // ownership server-side, so a wrong id and someone else's id both read as 404.
  static String ownerVenuePricing(String venueId) => '/owner/venues/$venueId/pricing';
  static String ownerVenueForecast(String venueId) => '/owner/venues/$venueId/forecast';
  static String ownerVenueSlotPrice(String venueId) => '/owner/venues/$venueId/slots/price';

  /// The owner's slots for one day: `?date=YYYY-MM-DD&venueId=…`. The Apply sheet
  /// reads this to know which slots exist before it offers to reprice any of them.
  static const String ownerSlots = '/owner/slots';

  // Realtime (Socket.IO)
  /// The Socket.IO origin. The server mounts engine.io at the ROOT (`/socket.io`),
  /// not under `/api`, so the socket must connect to the bare origin — [baseUrl]
  /// with its trailing `/api` stripped. Getting this wrong is the classic "chat
  /// won't connect but REST works" bug, so it is derived here once.
  static String get socketUrl {
    const b = baseUrl;
    return b.endsWith('/api') ? b.substring(0, b.length - 4) : b;
  }

  // Teams (S2)
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
  static String teamSuggestedPlayers(String id) => '/teams/$id/suggested-players';

  // Chat (S2)
  static String chatForTeam(String teamId) => '/chat/team/$teamId';
  static String chatMessages(String channelId) => '/chat/$channelId/messages';
  static String chatRead(String channelId) => '/chat/$channelId/read';
  static String chatMembers(String channelId) => '/chat/$channelId/members';
  static String chatReactions(String channelId, String messageId) => '/chat/$channelId/messages/$messageId/reactions';
  static String chatMessage(String channelId, String messageId) => '/chat/$channelId/messages/$messageId';

  // Chat: the inbox and the other two channel types
  /// The inbox itself. `type` filters to one of booking/captain/team; `cursor` is
  /// the previous page's `sortAt`, passed back verbatim — it is keyed on the same
  /// expression the server sorts by, so building one client-side would page wrong.
  static const String chats = '/chat';
  static const String chatUnreadCount = '/chat/unread-count';
  static String chatForBooking(String bookingId) => '/chat/booking/$bookingId';
  static String chatForMatch(String matchId) => '/chat/match/$matchId';
  static String chatMute(String channelId) => '/chat/$channelId/mute';
  static String chatQuickReplies(String channelId) => '/chat/$channelId/quick-replies';

  // Notifications
  /// The feed. `cursor` is the previous page's `nextCursor`, passed back verbatim:
  /// it is a `"<createdAt>~<id>"` pair, not a timestamp, because one transaction
  /// routinely writes several notifications (a booking approval alerts the player
  /// and the owner) and a timestamp-only cursor silently drops every tied row
  /// after the first at a page boundary. The client must never build or parse it.
  static const String notifications = '/notifications';
  static const String notificationSummary = '/notifications/summary';
  static const String notificationPrefs = '/notifications/preferences';
  static const String notificationReadAll = '/notifications/read-all';
  static const String notificationDevices = '/notifications/devices';
  static const String notificationTest = '/notifications/test';
  static String notificationRead(String id) => '/notifications/$id/read';
  static String notificationUnread(String id) => '/notifications/$id/unread';
  static String notification(String id) => '/notifications/$id';

  // Matches
  /// The match list is `?team_id=` (snake) because it mirrors the SQL column,
  /// while the pairing reads take `teamId`/`challengerTeam` — the backend is the
  /// authority on each name, so they are spelled out here once rather than
  /// guessed at three call sites.
  static const String matches = '/matches';
  static const String matchOpponents = '/matches/opponents';
  static const String matchPreview = '/matches/preview';
  static const String matchLinkableBookings = '/matches/linkable-bookings';
  static const String matchOwnerPending = '/matches/owner/pending';
  static const String matchChallenge = '/matches/challenge';
  static String match(String id) => '/matches/$id';
  static String matchRespond(String id) => '/matches/$id/respond';
  static String matchResult(String id) => '/matches/$id/result';
  static String matchVerify(String id) => '/matches/$id/verify';
  static String matchDispute(String id) => '/matches/$id/dispute';

  // Reviews & Trust 2.0
  /// Reviews mount at the bare `/api` root (not under a `/reviews` collection for
  /// the reads): the write is `POST /api/reviews`, but a venue's reviews hang off
  /// the venue and a user's off the user, mirroring the routes in `reviews.js`.
  static const String reviews = '/reviews';
  static String venueReviews(String venueId) => '/venues/$venueId/reviews';
  static String userReviews(String userId) => '/users/$userId/reviews';
  static String flagReview(String reviewId) => '/reviews/$reviewId/flag';

  // Admin moderation
  /// Under `/api/admin`, behind `checkRole('admin')`. The queue is every review
  /// needing an eye (reported or model-escalated or already hidden); the PATCH
  /// takes `{action: 'hide'|'restore'|'dismiss'}`.
  static const String adminFlaggedReviews = '/admin/reviews/flagged';
  static String adminModerateReview(String reviewId) => '/admin/reviews/$reviewId';

  // Scout, the assistant
  /// Every player-facing turn goes through the one `POST /message`: typed text
  /// and a tapped chip are the same request, distinguished only by whether the
  /// body carries `action`. That is deliberate — a chip must not need a second
  /// endpoint, because the whole point of a chip is to reach a capability the
  /// classifier may not have a label for.
  static const String assistantMessage = '/assistant/message';
  static const String assistantThreads = '/assistant/threads';
  static const String assistantCapabilities = '/assistant/capabilities';
  static String assistantThread(String threadId) => '/assistant/threads/$threadId';
  static String assistantThreadMessages(String threadId) =>
      '/assistant/threads/$threadId/messages';
  static String assistantFeedback(String messageId) =>
      '/assistant/messages/$messageId/feedback';

  // Tournaments
  /// Module 6. `/mine` and `/preview` are declared before `/:id` on the server, so
  /// they are real endpoints and not a tournament whose id happens to be "mine" —
  /// spelled out here in the same order for anyone comparing the two files.
  ///
  /// `preview` is a POST that writes nothing: the economics quote depends on the
  /// whole draft configuration (format, both team counts, four percentages, slot
  /// length, deadline), and a dozen fields in a query string would be worse than
  /// POSTing a read.
  static const String tournaments = '/tournaments';
  static const String myTournaments = '/tournaments/mine';
  static const String tournamentPreview = '/tournaments/preview';
  static String tournament(String id) => '/tournaments/$id';
  static String tournamentRegister(String id) => '/tournaments/$id/register';
  static String tournamentGenerate(String id) => '/tournaments/$id/generate';
  static String tournamentCancel(String id) => '/tournaments/$id/cancel';
  static String tournamentTeam(String id, String teamId) => '/tournaments/$id/teams/$teamId';
  static String tournamentFixtureResult(String id, String fixtureId) =>
      '/tournaments/$id/fixtures/$fixtureId/result';
  static String tournamentFixtureWalkover(String id, String fixtureId) =>
      '/tournaments/$id/fixtures/$fixtureId/walkover';

  // Admin: disputes, users, settings
  /// All of these sit under `/api/admin`, which mounts one
  /// `auth + checkRole('admin')` above every sub-router -- so there is no
  /// per-path authorisation to remember here, and a new admin path cannot ship
  /// without a gate. See the header of `backend/src/routes/admin.js`.
  ///
  /// Both list cursors (`adminDisputes`, `adminUsers`) are opaque and must be
  /// passed back verbatim. The dispute cursor is a
  /// `"<severityElo>~<createdAt>~<id>"` triple because the queue is sorted by
  /// what is at stake and only then by age; the user cursor is
  /// `"<createdAt>~<id>"`. Building either client-side pages wrong.
  static const String adminDisputes = '/admin/disputes';
  static String adminDispute(String id) => '/admin/disputes/$id';
  static const String adminUsers = '/admin/users';
  static String adminSuspendUser(String id) => '/admin/users/$id/suspend';
  static String adminReinstateUser(String id) => '/admin/users/$id/reinstate';
  static const String adminSettings = '/admin/settings';
  static const String adminSettingsReset = '/admin/settings/reset';

  // Financial export (FR4.16)
  /// One generator, two scopes. `?from&to` are required `YYYY-MM-DD` and the span
  /// is capped server-side at 366 days; `?format=json` previews the same walk the
  /// CSV streams, so the screen's totals cannot disagree with the file.
  ///
  /// The CSV is not fetched through [ApiClient] -- it answers `text/csv`, not the
  /// `{success, ...}` envelope every other route uses. See `ReportService`.
  static const String ownerFinancialReport = '/owner/reports/financial';
  static const String adminPlatformReport = '/admin/reports/platform';
}
