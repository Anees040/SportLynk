import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../providers/data_sync_provider.dart';
import 'player_profile_screen.dart';
import 'bookings_screen.dart';
import 'wallet_screen.dart';
import 'teams_screen.dart';
import '../../services/api_service.dart';
import '../../services/chat_service.dart';
import '../../services/offline_cache.dart';
import '../../services/realtime_service.dart';
import '../../utils/booking_grouping.dart';
import '../../utils/reconnect_refresh.dart';
import '../../widgets/assistant/scout_fab.dart';
import '../../widgets/header_actions.dart';
import '../../widgets/notification_bell.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/swipe_page_view.dart';
import '../shared/chats_screen.dart';
import 'assistant_screen.dart';

class PlayerHomeScreen extends StatefulWidget {
  /// Which bottom tab to open on. Lets a push to `/player-home` land on Bookings
  /// (tab 1) rather than Home — the booking-confirmation screen's "View in Booking
  /// History" uses it.
  final int initialTab;
  const PlayerHomeScreen({super.key, this.initialTab = 0});
  @override
  State<PlayerHomeScreen> createState() => _PlayerHomeScreenState();
}

class _PlayerHomeScreenState extends State<PlayerHomeScreen>
    with ReconnectRefresh<PlayerHomeScreen> {
  late int _tab;
  late int _prevTab;

  /// Drives the swipeable tab pages and feeds the bottom bar the fractional
  /// position it reads to slide its indicator with a drag.
  late final PageController _pageController;
  Map<String, dynamic>? _homeData;

  /// App-wide data-change signal. Reloads the dashboard's upcoming-bookings strip
  /// and stat count when a booking is made or cancelled anywhere else in the app.
  DataSyncProvider? _sync;
  int _lastBookingsRev = 0;

  /// When [_homeData] came from the cache rather than this session's network call,
  /// so the strip can say how old the figures on screen are.
  DateTime? _homeCachedAt;

  /// The failure sentence for a dashboard that has never loaded. Only set while
  /// [_homeData] is null — with a cached payload the stats stay on screen and the
  /// offline strip is the whole explanation.
  String? _homeError;

  /// Reaches into the live Bookings tab so a booking made in the chat can be pulled
  /// in immediately. The tab is a kept-alive page inside the [SwipePageView], so its
  /// State outlives every tab switch once built — the key is the only handle to it.
  /// It is null until Bookings has been shown once, which the callers tolerate: a
  /// tab that has never built has nothing stale to refresh.
  final GlobalKey<BookingsScreenState> _bookingsKey = GlobalKey<BookingsScreenState>();

  final ChatService _chat = ChatService();

  /// The header's chat badge. Muted rooms are already excluded server-side, so
  /// this total is "what the user asked to be told about" and never needs
  /// filtering here.
  int _chatUnread = 0;
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  Timer? _badgeDebounce;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _prevTab = widget.initialTab;
    _pageController = PageController(initialPage: widget.initialTab);
    // Concurrent, not chained — see [_hydrateFromCache].
    _load();
    _hydrateFromCache();
    _watchChat();
    _sync = context.read<DataSyncProvider>();
    _lastBookingsRev = _sync!.bookingsRevision;
    _sync!.addListener(_onDataSync);
  }

  @override
  void dispose() {
    _badgeDebounce?.cancel();
    _msgSub?.cancel();
    _sync?.removeListener(_onDataSync);
    _pageController.dispose();
    super.dispose();
  }

  // Recover a home payload that failed to load while offline, and re-read the chat
  // badge for anything that arrived during the outage. A payload already loaded is
  // left alone so a transient socket blip cannot blank the dashboard.
  @override
  void onReconnect() {
    if (_homeData == null) _load();
    _loadChatBadge();
  }

  // Reload the dashboard when a booking changed elsewhere (a cancellation on the
  // Bookings tab or detail screen, a booking through Scout), so the upcoming strip
  // and the stat count stay honest without the user returning to this tab. The
  // revision guard skips a wallet-only change.
  void _onDataSync() {
    final sync = _sync;
    if (!mounted || sync == null) return;
    if (sync.bookingsRevision != _lastBookingsRev) {
      _lastBookingsRev = sync.bookingsRevision;
      _load();
    }
  }

  /// Keep the header badge honest for as long as this screen lives.
  ///
  /// The socket is opened here, not in the chat screens: a badge that only moves
  /// while the inbox is already open is not a badge. The service is a
  /// singleton and connecting is idempotent, so a thread screen re-using it costs
  /// nothing — and the notification bell hangs off this same connection.
  ///
  /// The count is re-read rather than incremented, because the server decides what
  /// counts (muted rooms out, my own messages out) and a second copy of that rule
  /// here is how a badge starts disagreeing with the list it links to. The debounce
  /// is what keeps the re-read from being one request per message in a busy team
  /// chat.
  void _watchChat() {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null || token.isEmpty) return;
    RealtimeService().ensureConnected(token);
    _msgSub = RealtimeService().messages.listen((_) {
      _badgeDebounce?.cancel();
      _badgeDebounce = Timer(const Duration(seconds: 3), _loadChatBadge);
    });
    _loadChatBadge();
  }

  Future<void> _loadChatBadge() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null || token.isEmpty) return;
    final u = await _chat.unreadCount(token);
    if (!mounted || u.total == _chatUnread) return;
    setState(() => _chatUnread = u.total);
  }

  /// Chats opens full-screen from the header rather than as a sixth bottom tab:
  /// five is already as many as a bottom bar can label legibly, and the inbox is
  /// somewhere the user visits and comes back from, not somewhere they stay.
  Future<void> _openChats() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatsScreen()),
    );
    if (mounted) _loadChatBadge();
  }

  Future<void> _load() async {
    final res = await ApiClient().get('/player/home');
    if (!mounted) return;
    if (res['success'] == true && res['data'] is Map) {
      final data = Map<String, dynamic>.from(res['data'] as Map);
      setState(() {
        _homeData = data;
        _homeCachedAt = null;
        _homeError = null;
      });
      context.read<ConnectivityProvider>().markReachable();
      await OfflineCache.write(OfflineCache.playerHome, data);
      return;
    }
    // Previously this whole branch was `debugPrint` and nothing else: the dashboard
    // rendered half-empty and the user was never told why. There is still no error
    // view here on purpose — the header, the quick actions and Scout work without
    // the payload, so blanking the screen for a failed read would remove more than
    // it explains. The offline strip carries the message instead, and a cached
    // payload keeps the stats on screen.
    if (res['statusCode'] == 0) {
      context.read<ConnectivityProvider>().markUnreachable();
    }
    if (_homeData == null) {
      setState(() => _homeError = res['message'] as String? ??
          'Could not load your dashboard.');
    }
  }

  /// Draw the last good dashboard if it arrives before the network does, so a
  /// reopen or an offline start shows the user's real stats instead of the
  /// zero-state defaults the null payload falls back to.
  ///
  /// Started alongside the fetch, never before it: awaiting disk first would add
  /// the cache's latency to every online load. The `_homeData == null` guard is
  /// what makes losing the race harmless — a response that already landed is never
  /// replaced by a saved copy.
  Future<void> _hydrateFromCache() async {
    final cached = await OfflineCache.read(OfflineCache.playerHome);
    if (!mounted || cached == null || _homeData != null) return;
    final map = cached.asMap();
    if (map == null) return;
    setState(() {
      _homeData = map;
      _homeCachedAt = cached.at;
    });
  }

  /// Jump straight to [index] with no slide. A bar tap in a messaging app
  /// switches instantly; only a finger drag animates the pages. The bookkeeping
  /// and per-tab reloads still run through [_onPageSettled], which the jump fires.
  void _goToTab(int index) {
    if (index == _tab) return;
    _pageController.jumpToPage(index);
  }

  /// The single point the shell learns its tab changed, by tap or by swipe. A
  /// returning tab reloads what may have gone stale while it was off screen: the
  /// dashboard strip on Home, the list on Bookings.
  void _onPageSettled(int index) {
    if (!mounted) return;
    HapticFeedback.selectionClick();
    _prevTab = _tab;
    setState(() => _tab = index);
    if (index == 0 && _prevTab != 0) _load();
    if (index == 1 && _prevTab != 1) _bookingsKey.currentState?.refreshIfNeeded();
  }

  /// Open Scout, then act on what it hands back.
  ///
  /// Two things can have happened in there. A booking may have been made or cancelled
  /// — the same rows the Bookings tab is showing — so that tab is reloaded outright
  /// rather than left to its staleness guard. And Scout may have answered "that lives
  /// on the Wallet screen", in which case the trip continues here instead of dead-ending
  /// in the chat.
  Future<void> _openScout() async {
    final exit = await Navigator.of(context).pushNamed('/assistant');
    if (!mounted) return;
    if (exit is! ScoutExit) return;
    if (exit.bookingsChanged) {
      _bookingsKey.currentState?.reloadNow();
      // The home tab prints an upcoming-bookings strip from its own payload.
      if (_tab == 0) _load();
    }
    final target = exit.screen == null ? null : _tabOf(exit.screen!);
    if (target != null && target != _tab) _goToTab(target);
  }

  static int? _tabOf(String screen) => switch (screen) {
        'home' => 0,
        'bookings' => 1,
        'teams' => 2,
        'wallet' => 3,
        'profile' => 4,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    // A back gesture off the Home tab returns to Home rather than closing the app;
    // only a back press while already on Home is allowed to exit, matching the
    // convention of a phone's home-as-root shell.
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _tab != 0) _goToTab(0);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SwipePageView(
          controller: _pageController,
          onPageChanged: _onPageSettled,
          children: [
            _buildHome(auth),
            BookingsScreen(key: _bookingsKey),
            const TeamsScreen(),
            const WalletScreen(),
            const PlayerProfileScreen(),
          ],
        ),
        // Scout rides the shell, not the individual tabs, so it survives tab switches
        // and keeps one instance. It is hidden on Teams — that tab has its own FAB and
        // two stacked circles is a design bug, not a feature — and on Profile, which is
        // settings, where a chat button is only noise.
        floatingActionButton: (_tab == 2 || _tab == 4) ? null : ScoutFab(onTap: _openScout),
        bottomNavigationBar: _buildNav(),
      ),
    );
  }

  // Bottom navigation bar
  //
  // The highlight tracks the page controller's fractional position: a finger drag
  // carries the accent and the pill across with it, while a tap jumps the page and
  // the highlight lands on the new tab at once. At rest the fraction is a whole
  // number and the active item reads exactly as it did before the bar was swipeable.
  Widget _buildNav() {
    const unselected = Color(0xFF94A3B8);
    final items = [
      ('Home', Icons.home_rounded, Icons.home_outlined),
      ('Bookings', Icons.calendar_month, Icons.calendar_month_outlined),
      ('Teams', Icons.groups, Icons.groups_outlined),
      ('Wallet', Icons.account_balance_wallet, Icons.account_balance_wallet_outlined),
      ('Profile', Icons.person, Icons.person_outline),
    ];
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 16, offset: const Offset(0, -4),
        )],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: AnimatedBuilder(
            animation: _pageController,
            builder: (context, _) {
              final page = swipePage(_pageController, _tab);
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(items.length, (i) {
                  // 1 when this item is the current page, 0 a whole tab away, and
                  // a fraction mid-drag so the accent transfers smoothly.
                  final t = (1.0 - (page - i).abs()).clamp(0.0, 1.0);
                  final color = Color.lerp(unselected, AppColors.accent, t)!;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => _goToTab(i),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          // The active icon lifts onto a round accent halo. Both the
                          // lift and the halo track the drag, so mid-swipe they hand
                          // across from the leaving tab to the arriving one.
                          Transform.translate(
                            offset: Offset(0, -6 * t),
                            child: Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.18 * t),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(t > 0.5 ? items[i].$2 : items[i].$3,
                                  color: color, size: 24),
                            ),
                          ),
                          const SizedBox(height: 2),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(items[i].$1,
                              style: GoogleFonts.poppins(fontSize: 10,
                                color: color,
                                fontWeight: FontWeight.lerp(
                                    FontWeight.normal, FontWeight.w700, t))),
                          ),
                        ]),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
        ),
      ),
    );
  }

  // Home tab
  //
  // The header is a fixed [Column] child above the scrollable body, not the first
  // sliver in it: a sliver header scrolls away with the list, and under
  // [BouncingScrollPhysics] an overscroll opens a band of background above it.
  // Lifted out, the header cannot move and the status bar keeps its green backdrop.
  Widget _buildHome(AuthProvider auth) {    final firstName = (auth.currentUser?.name ?? 'Player').split(' ').first;
    final profile = _homeData?['profile'] as Map<String, dynamic>?;
    // Fold multi-slot groups into one entry each — the same collapse the Bookings
    // tab uses — so a 3-slot booking is one card and counts once, not three.
    final upcoming = collapseBookingGroups(
      ((_homeData?['upcomingBookings'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
    final trustScore = _parseNum(profile?['trust_score'], 100).round();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Column(children: [
        _fixedHeader(),
        OfflineBanner(cachedAt: _homeCachedAt),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.accent,
            onRefresh: _load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics()),
              slivers: [
                SliverToBoxAdapter(child: _greetingBlock(firstName)),
                // A dashboard that has never loaded says so, once, above the
                // zero-state figures it would otherwise present as real. The rest
                // of the tab stays usable: the quick actions and Scout do not need
                // this payload, so replacing the whole screen with an error would
                // take away more than it explains.
                if (_homeData == null && _homeError != null)
                  SliverToBoxAdapter(child: _dashboardUnavailable(_homeError!)),
                SliverToBoxAdapter(child: _statsRow(upcoming.length, trustScore)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                    child: ScoutAskBanner(onTap: _openScout),
                  ),
                ),
                SliverToBoxAdapter(child: _quickActions()),
                SliverToBoxAdapter(child: _buildUpcomingBookings(upcoming)),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  // Helpers
  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Morning';
    if (h < 17) return 'Afternoon';
    return 'Evening';
  }

  num _parseNum(dynamic val, num fallback) {
    if (val == null) return fallback;
    if (val is num) return val;
    return num.tryParse(val.toString()) ?? fallback;
  }

  /// The fixed brand header: wordmark on the left, the live actions on the
  /// right. The wallet balance, the greeting and the stat strip that used to sit
  /// here have moved onto the scrollable canvas below; a header that never moves
  /// carries identity and the destinations the bottom bar cannot reach — the
  /// matchmaking request inbox, the chat inbox and the bell — and nothing that
  /// scrolls.
  Widget _fixedHeader() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primaryDark, AppColors.primary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const BrandWordmark(),
                Row(children: [
                  HeaderIconButton(
                    icon: Icons.handshake_outlined,
                    tooltip: 'Play requests',
                    onTap: () => Navigator.pushNamed(context, '/requests-inbox'),
                  ),
                  const SizedBox(width: 10),
                  HeaderIconButton(
                    icon: Icons.chat_bubble_outline,
                    tooltip: 'Chats',
                    badge: _chatUnread,
                    onTap: _openChats,
                  ),
                  const SizedBox(width: 10),
                  const NotificationBell(),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The greeting, lifted off the header and onto the light canvas. It scrolls
  /// with the content now, which is the point: the fixed header stays terse.
  Widget _greetingBlock(String firstName) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Good ${_greeting()},',
            style: GoogleFonts.poppins(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text('$firstName 👋',
            style: GoogleFonts.poppins(
                color: AppColors.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                height: 1.1)),
      ]),
    );
  }

  /// The one-line notice shown when the dashboard payload has never arrived.
  ///
  /// Deliberately a card rather than a full-screen takeover: the figures below it
  /// are the null-payload defaults, so the user is told they are not real, while
  /// everything on the tab that works without the payload stays reachable.
  Widget _dashboardUnavailable(String message) => Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          const Icon(Icons.cloud_off_outlined, size: 20, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your dashboard could not load',
                    style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(message,
                    style: GoogleFonts.poppins(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          TextButton(
            onPressed: _load,
            child: Text('Retry',
                style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent)),
          ),
        ]),
      );

  /// Upcoming bookings and trust score — the two header stats that survived the
  /// wallet figure's removal — as cards on the canvas. The bookings card is
  /// tappable and jumps to that tab; trust score has no screen of its own.
  Widget _statsRow(int upcomingCount, int trustScore) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(children: [
        Expanded(
          child: _statCard(
            icon: Icons.event_available_rounded,
            value: '$upcomingCount',
            label: upcomingCount == 1 ? 'Upcoming booking' : 'Upcoming bookings',
            onTap: () => _goToTab(1),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _statCard(
            icon: Icons.verified_user_rounded,
            value: '$trustScore',
            label: 'Trust score',
          ),
        ),
      ]),
    );
  }
  Widget _statCard({
    required IconData icon,
    required String value,
    required String label,
    VoidCallback? onTap,
  }) {
    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
              color: AppColors.accentLight,
              borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: AppColors.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value,
                  style: GoogleFonts.poppins(
                      fontSize: 18, fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(label,
                  style: GoogleFonts.poppins(
                      fontSize: 10.5, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ]),
    );
    if (onTap == null) return card;
    return GestureDetector(onTap: onTap, child: card);
  }
  /// The 2×2 quick-action grid. Icons, colours and routes are deliberately
  /// unchanged — the request was to keep these tiles as they were — so this is the
  /// old sliver's body moved verbatim into its own helper, nothing more.
  Widget _quickActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Quick Actions',
            style: GoogleFonts.poppins(
                fontSize: 16, fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        const SizedBox(height: 14),
        Row(children: [
          _quickTile(
            Icons.stadium_rounded, 'Book Venue', 'Find & book grounds',
            const Color(0xFF22C55E), const Color(0xFFDCFCE7),
            () => Navigator.pushNamed(context, '/find-venues'),
          ),
          const SizedBox(width: 12),
          _quickTile(
            Icons.sports_kabaddi, 'Find Opponent', 'Challenge players',
            const Color(0xFF6366F1), const Color(0xFFE0E7FF),
            () => Navigator.pushNamed(context, '/find-opponents'),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _quickTile(
            Icons.emoji_events_rounded, 'Tournaments', 'Join competitions',
            const Color(0xFFF59E0B), const Color(0xFFFEF3C7),
            () => Navigator.pushNamed(context, '/tournaments'),
          ),
          const SizedBox(width: 12),
          _quickTile(
            Icons.leaderboard_rounded, 'Rankings', 'Team leaderboard',
            const Color(0xFFEC4899), const Color(0xFFFCE7F3),
            () => Navigator.pushNamed(context, '/team-rankings'),
          ),
        ]),
      ]),
    );
  }

  Widget _quickTile(
    IconData icon, String title, String subtitle,
    Color iconColor, Color bgColor, VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
            boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 12, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(height: 12),
            Text(title, style: GoogleFonts.poppins(
              fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 2),
            Text(subtitle, style: GoogleFonts.poppins(
              fontSize: 10, color: AppColors.textSecondary)),
          ]),
        ),
      ),
    );
  }

  Widget _buildUpcomingBookings(List<Map<String, dynamic>> bookings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Upcoming Bookings',
            style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800,
              color: AppColors.textPrimary)),
          GestureDetector(
            onTap: () => _goToTab(1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accentLight, borderRadius: BorderRadius.circular(10)),
              child: Text('View All', style: GoogleFonts.poppins(
                fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        bookings.isEmpty
            ? Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(children: [
                  Container(
                    width: 52, height: 52,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0D3B20), Color(0xFF166534)]),
                      borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.calendar_today_outlined, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('No upcoming bookings',
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => Navigator.pushNamed(context, '/find-venues'),
                      child: Text('Book a venue now →', style: GoogleFonts.poppins(
                        fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
                    ),
                  ])),
                ]),
              )
            : Column(
                children: bookings.take(3).map(_bookingCard).toList(),
              ),
      ]),
    );
  }

  Widget _bookingCard(Map<String, dynamic> b) {
    final status = b['status'] as String? ?? 'confirmed';
    final Color statusColor = status == 'confirmed'
        ? AppColors.accent
        : status == 'pending'
            ? const Color(0xFFF59E0B)
            : AppColors.textSecondary;
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/booking-detail',
        arguments: {'bookingId': b['id']}),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0A1F13), Color(0xFF166534)]),
              borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.stadium_outlined, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b['venue_name'] ?? 'Venue',
              style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 13,
                color: AppColors.textPrimary),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.calendar_today_outlined, size: 11, color: Color(0xFF94A3B8)),
              const SizedBox(width: 4),
              Text(_fmtSlotDate(b['slot_date']),
                style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFF94A3B8))),
              const SizedBox(width: 10),
              const Icon(Icons.access_time, size: 11, color: Color(0xFF94A3B8)),
              const SizedBox(width: 4),
              Flexible(
                child: Text(_cardTimeLabel(b),
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFF94A3B8))),
              ),
            ]),
            if (((b['_groupCount'] as int?) ?? 1) > 1) ...[
              const SizedBox(height: 4),
              Text('${b['_groupCount']} slots booked together',
                style: GoogleFonts.poppins(
                  fontSize: 10, color: AppColors.accent, fontWeight: FontWeight.w600)),
            ],
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8)),
            child: Text(status.toUpperCase(), style: GoogleFonts.poppins(
              fontSize: 9, color: statusColor, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
          ),
        ]),
      ),
    );
  }

  /// The time cell for a dashboard booking card: a single slot shows its start, a
  /// collapsed multi-slot group shows the whole run's start-to-end window.
  String _cardTimeLabel(Map<String, dynamic> b) {
    final count = (b['_groupCount'] as int?) ?? 1;
    if (count > 1) {
      return '${_formatTime(b['start_time'])} – ${_formatTime(b['_groupEnd'])}';
    }
    return _formatTime(b['start_time']);
  }

  String _formatTime(dynamic t) {
    if (t == null) return '';
    final str = t.toString();
    if (str.length >= 5) return str.substring(0, 5);
    return str;
  }

  String _fmtSlotDate(dynamic d) {
    if (d == null) return '';
    final str = d.toString();
    final dt = DateTime.tryParse(str);
    if (dt == null) return str.length > 10 ? str.substring(0, 10) : str;
    final localDt = dt.toLocal();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${localDt.day} ${months[localDt.month-1]}, ${localDt.year}';
  }
}
