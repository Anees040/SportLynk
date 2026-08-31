import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'constants/colors.dart';
import 'providers/auth_provider.dart';
import 'providers/venue_provider.dart';
import 'providers/booking_provider.dart';
import 'screens/auth_wrapper.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/player_register_screen.dart';
import 'screens/auth/owner_register_screen.dart';
import 'screens/auth/otp_screen.dart';
import 'screens/auth/forgot_password_screen.dart';
import 'screens/auth/owner_pending_screen.dart';
import 'screens/player/player_home_screen.dart';
import 'screens/owner/owner_home_screen.dart';
import 'screens/admin/admin_home_screen.dart';
import 'screens/player/trust_score_screen.dart';
import 'screens/player/find_venues_screen.dart';
import 'screens/player/venue_detail_screen.dart';
import 'screens/player/find_opponents_screen.dart';
import 'screens/player/team_rankings_screen.dart';
import 'screens/player/tournaments_screen.dart';
import 'screens/player/player_booking_detail_screen.dart';
import 'screens/player/rate_experience_screen.dart';
import 'screens/player/venue_reviews_screen.dart';
import 'screens/player/assistant_screen.dart';
import 'screens/owner/owner_qr_scanner_screen.dart';
import 'screens/owner/owner_wallet_screen.dart';
import 'screens/owner/owner_match_verify_screen.dart';
import 'screens/owner/owner_venue_reviews_screen.dart';
import 'screens/owner/owner_tournaments_screen.dart';
import 'screens/owner/owner_create_tournament_screen.dart';
import 'screens/player/tournament_detail_screen.dart';
import 'screens/admin/admin_moderation_screen.dart';
import 'screens/admin/admin_dispute_detail_screen.dart';
import 'screens/admin/admin_disputes_screen.dart';
import 'screens/admin/admin_settings_screen.dart';
import 'screens/admin/admin_users_screen.dart';
import 'screens/owner/owner_reports_screen.dart';
// S.7 Wave B/C — the chat inbox, the notification feed, and the deep-link map
// that a tray tap resolves through.
import 'providers/notification_provider.dart';
import 'services/push_service.dart';
import 'utils/deep_link.dart';
import 'models/chat_channel.dart';
import 'screens/shared/chats_screen.dart';
import 'screens/shared/chat_thread_screen.dart';
import 'screens/shared/notifications_screen.dart';
import 'screens/shared/notification_prefs_screen.dart';
import 'screens/player/match_center_screen.dart';
import 'screens/player/team_roster_screen.dart';
import 'screens/player/wallet_screen.dart';
import 'screens/owner/owner_booking_requests_screen.dart';

/// Removes scrollbar overlay on all platforms (fixes white line on web).
class _NoScrollbarBehavior extends MaterialScrollBehavior {
  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child; // strips all scrollbars
  }

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}

class AuthGuard extends StatelessWidget {
  final Widget child;
  final String? requiredRole;
  const AuthGuard({required this.child, this.requiredRole, super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        // Still loading auth state — show spinner, don't redirect
        if (auth.isLoading) {
          return const Scaffold(
            backgroundColor: Color(0xFF0A1F13),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF22C55E)),
            ),
          );
        }

        // Not authenticated — redirect to welcome
        if (!auth.isAuthenticated) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              Navigator.pushNamedAndRemoveUntil(
                context, '/welcome', (r) => false);
            }
          });
          return const Scaffold(
            backgroundColor: Color(0xFF0A1F13),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF22C55E)),
            ),
          );
        }

        // Role mismatch — redirect to correct home for each role
        if (requiredRole != null && auth.userRole != requiredRole) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              final route = auth.userRole == 'admin'
                  ? '/admin-home'
                  : auth.userRole == 'owner'
                      ? '/owner-home'
                      : '/player-home';
              Navigator.pushNamedAndRemoveUntil(context, route, (r) => false);
            }
          });
          return const Scaffold(
            backgroundColor: Color(0xFF0A1F13),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF22C55E)),
            ),
          );
        }

        return child;
      },
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }
  // BEFORE runApp, and deliberately so: `getInitialMessage()` is what a tray tap on
  // a KILLED app arrives as, it resolves exactly once, and it must be read before
  // the first frame or the link is lost. PushService parks it and
  // `DeepLink.replayPending()` fires it from the first home screen, once
  // AuthProvider has resolved -- a deep link pushed before authentication would land
  // on a screen that immediately bounces to /login.
  //
  // Its whole body is try/caught inside the service, so a phone with no Play
  // Services degrades to "no push" and never to an app that will not start.
  await PushService().init();
  runApp(const SportLynkApp());
}

class SportLynkApp extends StatelessWidget {
  const SportLynkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => VenueProvider()),
        ChangeNotifierProvider(create: (_) => BookingProvider()),
        // The bell badge on all three home headers, the feed screen, and the
        // `notification:new` socket subscription that keeps them live.
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
      ],
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: MaterialApp(
        // How a notification tap navigates. A tray tap is handled by PushService,
        // which has no BuildContext of its own -- and on a cold start there is not a
        // single mounted widget yet. One app-level key is the only way to reach the
        // navigator from there, so `DeepLink` owns it and `PushService` goes through
        // `DeepLink.open`/`park` rather than touching Navigator itself.
        navigatorKey: DeepLink.navigatorKey,
        title: 'SportLynk',
        debugShowCheckedModeBanner: false,
        scrollBehavior: _NoScrollbarBehavior(),
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.primary,
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: AppColors.background,
          textTheme: GoogleFonts.poppinsTextTheme(),
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.white,
            elevation: 0,
            centerTitle: true,
          ),
        ),
        home: const AuthWrapper(),
        routes: {
          '/welcome': (_) => const WelcomeScreen(),
          '/login': (_) => const LoginScreen(),
          '/register/player': (_) => const PlayerRegisterScreen(),
          '/register/owner': (_) => const OwnerRegisterScreen(),
          '/otp': (_) => const OtpScreen(),
          '/forgot-password': (_) => const ForgotPasswordScreen(),
          '/owner-pending': (_) => const AuthGuard(child: OwnerPendingScreen()),
          '/player-home': (_) => const AuthGuard(requiredRole: 'player', child: PlayerHomeScreen()),
          '/owner-home': (_) => const AuthGuard(requiredRole: 'owner', child: OwnerHomeScreen()),
          '/admin-home': (_) => const AuthGuard(requiredRole: 'admin', child: AdminHomeScreen()),
          '/admin-moderation': (_) => const AuthGuard(requiredRole: 'admin', child: AdminModerationScreen()),
          '/trust-score': (context) {
            // Self view: resolve the signed-in player's own id so the live trust
            // breakdown loads. The `profile:{}` fallback path is kept for callers
            // that still push it with a profile map.
            final auth = Provider.of<AuthProvider>(context, listen: false);
            return AuthGuard(
              requiredRole: 'player',
              child: TrustScoreScreen(userId: auth.currentUser?.id),
            );
          },
          '/rate-experience': (context) {
            final a = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
            return AuthGuard(
              requiredRole: 'player',
              child: RateExperienceScreen(
                bookingId: a['bookingId'] as String,
                venueName: a['venueName'] as String?,
                opponentTeamName: a['opponentTeamName'] as String?,
                canReviewVenue: a['canReviewVenue'] as bool? ?? true,
                canReviewOpponent: a['canReviewOpponent'] as bool? ?? false,
                dateLabel: a['dateLabel'] as String?,
              ),
            );
          },
          '/venue-reviews': (context) {
            final a = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
            return AuthGuard(
              requiredRole: 'player',
              child: VenueReviewsScreen(venueId: a['venueId'] as String, venueName: a['venueName'] as String?),
            );
          },
          '/find-venues': (context) {
            final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>?;
            return AuthGuard(requiredRole: 'player', child: FindVenuesScreen(initialSport: args?['sport']));
          },
          '/venue-detail': (context) {
            final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
            return AuthGuard(requiredRole: 'player', child: VenueDetailScreen(venueId: args['venueId']));
          },
          '/find-opponents': (_) => const AuthGuard(requiredRole: 'player', child: FindOpponentsScreen()),
          '/team-rankings': (_) => const AuthGuard(requiredRole: 'player', child: TeamRankingsScreen()),
          '/tournaments': (_) => const AuthGuard(requiredRole: 'player', child: TournamentsScreen()),
          '/assistant': (_) => const AuthGuard(requiredRole: 'player', child: AssistantScreen()),
          // Not role-guarded: a tournament page is public reading (SRS FE-8), and the
          // organiser controls on it are gated by the server's own `organiser` block
          // rather than by which role opened the route.
          '/tournament-detail': (ctx) {
            final a = ModalRoute.of(ctx)!.settings.arguments as Map<String, dynamic>;
            return TournamentDetailScreen(
              tournamentId: a['tournamentId'] as String,
              autoRegister: a['autoRegister'] == true,
            );
          },
          '/booking-detail': (ctx) {
            final args = ModalRoute.of(ctx)!.settings.arguments as Map<String, dynamic>;
            return AuthGuard(requiredRole: 'player', child: PlayerBookingDetailScreen(bookingId: args['bookingId']));
          },
          '/owner-scan-qr': (_) => const AuthGuard(requiredRole: 'owner', child: OwnerQrScannerScreen()),
          '/owner-wallet': (_) => const AuthGuard(requiredRole: 'owner', child: OwnerWalletScreen()),
          '/owner-verify-matches': (_) => const AuthGuard(requiredRole: 'owner', child: OwnerMatchVerifyScreen()),
          '/owner-tournaments': (_) => const AuthGuard(requiredRole: 'owner', child: OwnerTournamentsScreen()),
          '/owner-create-tournament': (ctx) {
            final a = ModalRoute.of(ctx)!.settings.arguments as Map<String, dynamic>?;
            return AuthGuard(
              requiredRole: 'owner',
              child: OwnerCreateTournamentScreen(venueId: a?['venueId'] as String?),
            );
          },
          // ── S.7 Wave C — the deep-link surface ───────────────────────────
          //
          // EVERY route `notificationTypes.js` can emit MUST exist here.
          // `check_notifications.js` asserts exactly that by string-matching this
          // file, because the failure it prevents is invisible: a notification whose
          // route was never registered renders perfectly, buzzes the phone, and then
          // does nothing at all when tapped. That is the class of silent breakage
          // this sprint exists to close, so the check is a hard gate rather than a
          // review note.
          //
          // NONE OF THESE IS ROLE-GUARDED MORE TIGHTLY THAN ITS AUDIENCE.
          // `AuthGuard` answers a role mismatch with `pushNamedAndRemoveUntil` —
          // it WIPES the stack and sends you to your own home. On an ordinary
          // mis-tap that is fine; on a notification tap it would throw away the very
          // thing the user opened. So a route reachable by more than one role carries
          // no `requiredRole`, and `/wallet` — which owners genuinely receive
          // withdrawal notifications for — resolves to the right screen per role
          // instead of bouncing the owner off it.
          '/notifications': (_) => const AuthGuard(child: NotificationsScreen()),
          '/notification-prefs': (_) => const AuthGuard(child: NotificationPrefsScreen()),
          '/chats': (_) => const AuthGuard(child: ChatsScreen()),
          '/chat-thread': (ctx) {
            final a = (ModalRoute.of(ctx)!.settings.arguments as Map?) ?? const {};
            final channelId = a['channelId']?.toString();
            final refId = a['refId']?.toString();
            // A thread needs one of the two (the constructor asserts it). A link with
            // neither is a registry bug, not a user error, so it lands on the inbox
            // rather than tripping an assert in a release build.
            if (channelId == null && refId == null) return const AuthGuard(child: ChatsScreen());
            return AuthGuard(
              child: ChatThreadScreen(
                type: ChatChannelType.parse(a['type']?.toString()),
                title: a['title']?.toString() ?? 'Chat',
                channelId: channelId,
                refId: refId,
                imageUrl: a['imageUrl']?.toString(),
                contextLine: a['contextLine']?.toString(),
              ),
            );
          },
          '/match-center': (ctx) {
            final a = (ModalRoute.of(ctx)!.settings.arguments as Map?) ?? const {};
            // `matchId` rides along in the link but the centre is a list screen: it
            // opens on the team's fixtures, which is where the match in question is.
            // `teamName` is optional — the registry forwards it only when the emitting
            // call site had it, and the screen loads the team regardless.
            return AuthGuard(
              requiredRole: 'player',
              child: MatchCenterScreen(
                teamId: a['teamId']?.toString() ?? '',
                teamName: a['teamName']?.toString(),
              ),
            );
          },
          '/team-roster': (ctx) {
            final a = (ModalRoute.of(ctx)!.settings.arguments as Map?) ?? const {};
            return AuthGuard(
              requiredRole: 'player',
              child: TeamRosterScreen(
                teamId: a['teamId']?.toString(),
                teamName: a['teamName']?.toString(),
              ),
            );
          },
          // Owners withdraw too (`POST /api/wallet/withdraw` is open to any
          // authenticated user, which is how a venue owner is paid), so the one
          // `/wallet` route the registry emits has to mean "my wallet" for both.
          '/wallet': (ctx) {
            final role = Provider.of<AuthProvider>(ctx, listen: false).userRole;
            return AuthGuard(
              child: role == 'owner' ? const OwnerWalletScreen() : const WalletScreen(),
            );
          },
          // The requests list, not one request: the owner-side booking screens are a
          // tabbed list and the notification's `bookingId` is the row they land on.
          '/owner-bookings': (_) =>
              const AuthGuard(requiredRole: 'owner', child: OwnerBookingRequestsScreen()),
          // -- S.7 Wave D / D5 -- the admin desk and the financial export ---
          //
          // Every one of these is `requiredRole: 'admin'` except the owner's own
          // report: the notification registry emits none of them (checked -- it
          // routes to `/chats`, `/match-center`, `/wallet` and friends only), so
          // there is no deep link here that a role bounce could throw away, and the
          // tight guard is the right one. `AuthGuard` wiping the stack on a mismatch
          // is exactly the wanted behaviour for a mis-tapped admin URL.
          //
          // The dispute DETAIL route takes its id as an argument and is also pushed
          // directly by the queue with `MaterialPageRoute`, which is what lets it
          // return `true` so the queue re-reads itself after a ruling. It is named
          // here as well so the case file is linkable.
          '/admin-disputes': (_) =>
              const AuthGuard(requiredRole: 'admin', child: AdminDisputesScreen()),
          '/admin-dispute': (ctx) {
            final a = (ModalRoute.of(ctx)!.settings.arguments as Map?) ?? const {};
            final id = a['disputeId']?.toString();
            // No id means the link is malformed, not that the admin wants a blank
            // case file -- so it lands on the queue.
            if (id == null || id.isEmpty) {
              return const AuthGuard(requiredRole: 'admin', child: AdminDisputesScreen());
            }
            return AuthGuard(
              requiredRole: 'admin',
              child: AdminDisputeDetailScreen(disputeId: id),
            );
          },
          '/admin-users': (_) =>
              const AuthGuard(requiredRole: 'admin', child: AdminUsersScreen()),
          '/admin-settings': (_) =>
              const AuthGuard(requiredRole: 'admin', child: AdminSettingsScreen()),
          // One screen, two scopes: the owner's own venues, and the platform-wide
          // report with commission per owner. The route decides the scope rather than
          // the screen reading the signed-in role, because an admin who also owns
          // venues is entitled to both reports.
          '/admin-reports': (_) => const AuthGuard(
                requiredRole: 'admin',
                child: OwnerReportsScreen(platform: true),
              ),
          '/owner-reports': (_) =>
              const AuthGuard(requiredRole: 'owner', child: OwnerReportsScreen()),
          '/owner-venue-reviews': (context) {
            final a = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
            return AuthGuard(
              requiredRole: 'owner',
              child: OwnerVenueReviewsScreen(venueId: a['venueId'] as String, venueName: a['venueName'] as String?),
            );
          },
        },
        ),
      ),
    );
  }
}
