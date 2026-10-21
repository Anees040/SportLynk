import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../models/match.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../services/chat_service.dart';
import '../../services/match_service.dart';
import '../../services/offline_cache.dart';
import '../../services/pricing_service.dart';
import '../../services/realtime_service.dart';
import '../../utils/reconnect_refresh.dart';
import '../../utils/slot_time.dart';
import '../../widgets/ai_price_suggestion_banner.dart';
import '../../widgets/apply_price_sheet.dart';
import '../../widgets/header_actions.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/notification_bell.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/pricing_widgets.dart';
import '../../widgets/swipe_page_view.dart';
import '../../widgets/stable_refresh_indicator.dart';
import '../shared/chats_screen.dart';
import 'owner_booking_requests_screen.dart';
import 'owner_match_verify_screen.dart';
import 'owner_slot_calendar_screen.dart';
import 'owner_my_venues_screen.dart';
import 'owner_profile_screen.dart';

class OwnerHomeScreen extends StatefulWidget {
  const OwnerHomeScreen({super.key});
  @override
  State<OwnerHomeScreen> createState() => _OwnerHomeScreenState();
}

class _OwnerHomeScreenState extends State<OwnerHomeScreen>
    with ReconnectRefresh<OwnerHomeScreen> {
  int _tab = 0;

  /// Drives the swipeable tab pages and feeds the bottom bar the fractional
  /// position it reads to slide its indicator with a drag.
  late final PageController _pageController;
  Map<String, dynamic>? _data;
  bool _loading = true;
  static String get _base => ApiConstants.baseUrl;

  /// When the figures on screen were fetched, when they came from the cache rather
  /// than from this session's request. Drives the banner's "saved 10 min ago", so a
  /// revenue total from this morning is never read as the current one.
  DateTime? _cachedAt;

  /// The failure sentence for a load that had nothing cached to fall back on.
  ///
  /// Only that case earns a full error view. Before this existed a failed dashboard
  /// left [_data] null and the body rendered every figure through `?? 0` — so an
  /// outage displayed "REVENUE TODAY / PKR 0" and "BOOKINGS 0", which is not a
  /// quiet empty state but a wrong number an owner would act on.
  String? _error;

  /// Set once a fetch has returned real figures.
  ///
  /// Guards the cache hydration against a race it would otherwise lose silently:
  /// the two run concurrently, and a slow disk read landing after a fast response
  /// would replace this session's figures with saved ones and re-label them stale.
  bool _networkAnswered = false;

  // Match results awaiting this owner's verification (ER2.2)
  // Kept out of /owner/dashboard on purpose: a failure fetching matches must not
  // be able to blank the revenue and bookings the owner opened the app for.
  final _matchService = MatchService();
  List<MatchModel> _toVerify = const [];
  StreamSubscription? _matchSub;

  // AI price suggestion (FR4.17)
  // Loaded on its own, after the dashboard, because the venue id it needs comes out
  // of the dashboard payload and because a slow or dead ml-service must never delay
  // the revenue figures. `_priceLoading` starts false: there is nothing to load
  // until the venue is known.
  final _pricingService = PricingService();
  PriceSuggestion? _price;
  bool _priceLoading = false;
  String? _priceVenueId;
  DateTime? _priceDismissedUntil;
  Timer? _clockTimer;

  String? get _priceDismissalKey {
    final ownerId = context.read<AuthProvider>().currentUser?.id;
    if (ownerId == null || _priceVenueId == null) return null;
    return 'owner_price_snooze_v1:$ownerId:$_priceVenueId';
  }

  bool get _priceSuggestionVisible =>
      _priceVenueId != null &&
      (_priceDismissedUntil == null ||
          !DateTime.now().isBefore(_priceDismissedUntil!));

  // Chat
  // An owner's inbox is mostly booking rooms — the player asking whether the floodlights
  // work, half an hour before they arrive. That is a message an owner cannot afford to miss,
  // which is why the count is live rather than fetched when the inbox opens.
  final ChatService _chat = ChatService();
  int _chatUnread = 0;
  StreamSubscription? _msgSub;
  Timer? _badgeDebounce;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    // Both started together, deliberately NOT chained. Reading the cache is disk
    // I/O, and awaiting it before the request would delay every online load by
    // however long shared_preferences takes to answer — paying an offline cost on
    // a connection that is fine. Whichever resolves first paints; [_hydrateFromCache]
    // stands down if the network already answered.
    _load();
    _hydrateFromCache();
    _loadToVerify();
    // The card should appear the moment the second captain submits, without the
    // owner having to pull to refresh. The socket is already connected for every
    // signed-in role, so this costs nothing when there is nothing to say.
    _matchSub = RealtimeService().matchUpdates.listen((_) {
      if (mounted) _loadToVerify();
    });
    _watchChat();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _matchSub?.cancel();
    _badgeDebounce?.cancel();
    _msgSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // Recover a dashboard that failed to load while offline, and re-read the chat
  // badge for anything that arrived during the outage. A dashboard already loaded
  // from the network is left alone so a transient socket blip cannot blank the
  // revenue figures; cached figures are refreshed, because stale is exactly what
  // reconnecting is the chance to fix.
  @override
  void onReconnect() {
    if (_data == null || _cachedAt != null) _refreshAll();
    _loadChatBadge();
  }

  /// The badge is re-read on activity rather than counted up here: the server is what
  /// decides what counts (muted rooms out, my own messages out), and a second copy of
  /// that rule on the client is how a badge starts disagreeing with the list it opens.
  /// The debounce keeps a busy room from turning into a request per message.
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

  Future<void> _openChats() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatsScreen()),
    );
    if (mounted) _loadChatBadge();
  }

  Future<void> _refreshAll() => Future.wait([_load(), _loadToVerify()]);

  /// Fetches the suggestion for [venueId]. The server picks the date (PKT today) and
  /// the hour (the venue's own peak-adjacent hour) — deliberately not duplicated
  /// here, because two implementations of "which hour do we mean" is two answers.
  Future<void> _loadPricing(String venueId) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null || token.isEmpty) return;
    final venueChanged = _priceVenueId != venueId;
    setState(() {
      _priceLoading = true;
      _priceVenueId = venueId;
      if (venueChanged) {
        _price = null;
        _priceDismissedUntil = null;
      }
    });
    if (venueChanged) {
      final key = _priceDismissalKey;
      if (key != null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final savedUntil = prefs.getInt(key);
          if (!mounted || _priceVenueId != venueId) return;
          if (savedUntil != null && _priceDismissedUntil == null) {
            setState(
              () => _priceDismissedUntil = DateTime.fromMillisecondsSinceEpoch(
                savedUntil,
              ),
            );
          }
        } catch (_) {}
      }
    }
    final s = await _pricingService.suggestion(token, venueId);
    if (!mounted || _priceVenueId != venueId) return;
    setState(() {
      _price = s;
      _priceLoading = false;
    });
  }

  Future<void> _dismissPriceSuggestion() async {
    final until = DateTime.now().add(const Duration(hours: 6));
    final key = _priceDismissalKey;
    setState(() => _priceDismissedUntil = until);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Price suggestion hidden for 6 hours. Your prices are unchanged.',
        ),
      ),
    );
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, until.millisecondsSinceEpoch);
    } catch (_) {}
  }

  void _showPriceDetails() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: AiPriceCard(
            suggestion: _price,
            loading: _priceLoading,
            onApply: (_price != null && _price!.isModel && _price!.isActionable)
                ? () async {
                    Navigator.pop(sheetContext);
                    await _openApply();
                  }
                : null,
          ),
        ),
      ),
    );
  }

  /// Opens the slot picker. Returns only after the sheet closes, so the card and the
  /// dashboard both refresh against the prices that were written — the
  /// server drops its cached suggestion for this venue on a successful apply, so the
  /// re-fetch is guaranteed to be recomputed rather than served stale.
  Future<void> _openApply() async {
    final s = _price;
    final venueId = _priceVenueId;
    if (s == null || venueId == null) return;
    final applied = await showApplyPriceSheet(
      context,
      venueId: venueId,
      suggestion: s,
    );
    if (applied == true && mounted) {
      await _load();
      if (mounted) await _loadPricing(venueId);
    }
  }

  Future<void> _loadToVerify() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null || token.isEmpty) return;
    final list = await _matchService.ownerPending(token);
    if (mounted) setState(() => _toVerify = list);
  }

  Future<void> _openVerify() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OwnerMatchVerifyScreen()),
    );
    await _loadToVerify();
  }

  /// Draw the last good dashboard if it arrives before the network does.
  ///
  /// Runs alongside the fetch rather than before it, so the cache adds no disk
  /// latency to an online load, and stands down when the network has already
  /// answered rather than overwriting fresher figures with saved ones.
  Future<void> _hydrateFromCache() async {
    final cached = await OfflineCache.read(OfflineCache.ownerHome);
    if (!mounted || cached == null || _networkAnswered) return;
    final data = cached.asMap();
    if (data == null) return;
    setState(() {
      _data = data;
      _cachedAt = cached.at;
      _error = null;
      _loading = false;
    });
  }

  Future<void> _load() async {
    // The spinner is only for a screen with nothing to show. With cached figures
    // already drawn, a refresh happens underneath them — replacing the revenue
    // total with a spinner on every resume is the flicker this avoids.
    final hadData = _data != null;
    if (!hadData && mounted) setState(() => _loading = true);

    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final resp = await http
          .get(
            Uri.parse('$_base/owner/dashboard'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final json = jsonDecode(resp.body);
      if (json['success'] == true) {
        final data = json['data'];
        _networkAnswered = true;
        setState(() {
          _data = data is Map ? Map<String, dynamic>.from(data) : null;
          _cachedAt =
              null; // on screen is now this session's data, not a saved copy
          _error = null;
          _loading = false;
        });
        context.read<ConnectivityProvider>().markReachable();
        await OfflineCache.write(OfflineCache.ownerHome, _data);
        if (!mounted) return;
        // Chained rather than parallel: the venue id only exists once this landed.
        // Not awaited by the caller's refresh indicator either — the spinner should
        // stop when the revenue numbers are on screen, not when the ML service
        // finishes thinking.
        final venueId = (_data?['venue']?['id'])?.toString();
        if (venueId != null && venueId.isNotEmpty) _loadPricing(venueId);
        return;
      }
      // The server answered and refused. That is a fault worth a sentence, not a
      // connection the owner might go and re-check, so connectivity is left alone.
      setState(() {
        _loading = false;
        _error = hadData
            ? null
            : (json['message'] as String? ?? 'Could not load your dashboard.');
      });
    } catch (_) {
      // No answer reached us — a timeout, a dead socket, or a body that did not
      // parse. The figures already on screen stay, and the offline strip carries
      // the explanation; only a load with nothing cached earns the error view.
      if (!mounted) return;
      context.read<ConnectivityProvider>().markUnreachable();
      setState(() {
        _loading = false;
        _error = hadData
            ? null
            : 'Could not reach the server. Check your connection and try again.';
      });
    }
  }

  /// Jump straight to [index] with no slide. A bar tap in a messaging app
  /// switches instantly; only a finger drag animates the pages. The settle
  /// bookkeeping still runs through [_onPageSettled], which the jump fires.
  void _goToTab(int index) {
    if (index == _tab) return;
    _pageController.jumpToPage(index);
  }

  /// The single point the shell learns its tab changed, by tap or by swipe. The
  /// child tabs load their own data on first build, so there is nothing to reload
  /// here beyond recording which tab now shows.
  void _onPageSettled(int index) {
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = index);
  }

  @override
  Widget build(BuildContext context) {
    // A back gesture off the Dashboard tab returns to it rather than closing the
    // app; only a back press while already on Dashboard exits.
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
            _dashboardTab(),
            const OwnerBookingRequestsScreen(),
            const OwnerSlotCalendarScreen(),
            const OwnerMyVenuesScreen(), // multi-venue list
            const OwnerProfileScreen(),
          ],
        ),
        bottomNavigationBar: _buildNav(),
      ),
    );
  }

  // Bottom navigation bar
  //
  // The accent tracks the page controller's fractional position: a finger drag
  // carries the highlight across with it, while a tap jumps the page and the
  // highlight lands on the new tab at once. At rest the fraction is whole and the
  // active item reads exactly as before the bar was swipeable.
  Widget _buildNav() {
    final items = [
      ('DASHBOARD', Icons.grid_view_rounded, Icons.grid_view_outlined),
      ('BOOKINGS', Icons.pending_actions, Icons.pending_actions_outlined),
      ('SCHEDULE', Icons.calendar_month, Icons.calendar_month_outlined),
      ('VENUES', Icons.stadium, Icons.stadium_outlined),
      ('PROFILE', Icons.person, Icons.person_outline),
    ];
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: AppColors.border)),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Material(
          color: Colors.transparent,
          child: AnimatedBuilder(
            animation: _pageController,
            builder: (context, _) {
              final page = swipePage(_pageController, _tab);
              return Row(
                children: [
                  for (var index = 0; index < items.length; index++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final progress = (1.0 - (page - index).abs()).clamp(
                            0.0,
                            1.0,
                          );
                          final color = Color.lerp(
                            AppColors.textSecondary,
                            AppColors.primary,
                            progress,
                          )!;
                          return Semantics(
                            selected: _tab == index,
                            button: true,
                            child: InkWell(
                              onTap: () => _goToTab(index),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 9,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 50,
                                      height: 30,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: AppColors.accent.withValues(
                                          alpha: 0.14 * progress,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        progress > 0.5
                                            ? items[index].$2
                                            : items[index].$3,
                                        color: color,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        items[index].$1,
                                        style: GoogleFonts.poppins(
                                          fontSize: 9,
                                          color: color,
                                          fontWeight: FontWeight.lerp(
                                            FontWeight.w500,
                                            FontWeight.w700,
                                            progress,
                                          ),
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _dashboardTab() {
    final auth = context.watch<AuthProvider>();
    final name = auth.currentUser?.name ?? 'Owner';
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 17
        ? 'Good Afternoon'
        : 'Good Evening';
    final stats = _data?['stats'] as Map<String, dynamic>? ?? {};
    final upcoming = ((_data?['upcomingBookings'] as List?) ?? [])
        .whereType<Map>()
        .map((booking) => Map<String, dynamic>.from(booking))
        .where((booking) => !isSlotPast(booking))
        .toList();
    final wallet = _data?['wallet'] as Map<String, dynamic>? ?? {};
    final venue = _data?['venue'] as Map<String, dynamic>?;
    final pendingEscrow = _parseNum(_data?['pendingEscrow']);
    final pendingCount = _parseNum(stats['pendingCount']).toInt();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Dashboard',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              venue?['name'] ?? 'Your Venue',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          HeaderIconButton(
            icon: Icons.chat_bubble_outline,
            tooltip: 'Chats',
            badge: _chatUnread,
            onTap: _openChats,
          ),
          const SizedBox(width: 8),
          const NotificationBell(),
          const SizedBox(width: 14),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : _error != null && _data == null
          ? NetworkErrorView(message: _error!, onRetry: _refreshAll)
          : StableRefreshIndicator(
              onRefresh: _refreshAll,
              child: CustomScrollView(
                key: const PageStorageKey('owner-dashboard'),
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(child: OfflineBanner(cachedAt: _cachedAt)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$greeting, ${name.split(' ').first}!',
                            style: GoogleFonts.poppins(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${DateFormat('EEEE, d MMMM').format(DateTime.now())} · Your venue at a glance',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _revenueCard(stats),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _statCard(
                                'BOOKINGS',
                                '${stats['bookingsToday'] ?? 0}',
                                Icons.calendar_month_outlined,
                                const Color(0xFF2563EB),
                                subtitle: 'Today’s schedule',
                                onTap: () => _goToTab(2),
                              ),
                              const SizedBox(width: 12),
                              _statCard(
                                'PENDING',
                                '${stats['pendingCount'] ?? 0}',
                                Icons.pending_actions_outlined,
                                AppColors.warningText,
                                subtitle: 'Awaiting approval',
                                onTap: () => _goToTab(1),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (pendingCount > 0)
                    SliverToBoxAdapter(child: _pendingCard(pendingCount)),
                  if (_toVerify.isNotEmpty)
                    SliverToBoxAdapter(child: _verifyCard()),
                  SliverToBoxAdapter(
                    child: _sectionHeader(
                      'Next Bookings',
                      action: 'VIEW SCHEDULE',
                      onTap: () => _goToTab(2),
                    ),
                  ),
                  if (upcoming.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Container(
                          padding: const EdgeInsets.all(22),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.event_available_outlined,
                                size: 30,
                                color: AppColors.primary,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'No upcoming bookings today',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.poppins(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (_, index) => Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: _bookingRow(upcoming[index]),
                        ),
                        childCount: upcoming.length,
                      ),
                    ),
                  SliverToBoxAdapter(child: _sectionHeader('Wallet & Payouts')),
                  SliverToBoxAdapter(
                    child: _walletCard(wallet, upcoming, pendingEscrow),
                  ),
                  SliverToBoxAdapter(child: _sectionHeader('Quick Actions')),
                  SliverToBoxAdapter(child: _buildQuickActions()),
                  if (_priceSuggestionVisible)
                    SliverToBoxAdapter(
                      child: _sectionHeader('Pricing Insights'),
                    ),
                  if (_priceSuggestionVisible)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Dismissible(
                          key: ValueKey('owner-price-$_priceVenueId'),
                          direction: DismissDirection.horizontal,
                          onDismissed: (_) => _dismissPriceSuggestion(),
                          child: AiPriceSuggestionBanner(
                            suggestion: _price,
                            loading: _priceLoading,
                            onDismiss: _dismissPriceSuggestion,
                            onDetails: _showPriceDetails,
                            onRetry: _priceVenueId == null
                                ? null
                                : () => _loadPricing(_priceVenueId!),
                          ),
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 28)),
                ],
              ),
            ),
    );
  }

  /// The verification queue entry point. Deliberately loud — an unverified result
  /// is two teams waiting on this owner, and their ratings do not move until they
  /// get it. The count is the whole message, so it leads.
  Widget _verifyCard() {
    final n = _toVerify.length;
    final first = _toVerify.first;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _openVerify,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.45),
              ),
              color: AppColors.warning.withValues(alpha: 0.06),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.fact_check_outlined,
                    color: Color(0xFFB45309),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n == 1
                            ? 'Match result to verify'
                            : '$n match results to verify',
                        style: GoogleFonts.poppins(
                          fontSize: 13.5,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        n == 1
                            ? '${first.challenger.name} vs ${first.opponent.name} — both captains agreed on the score.'
                            : 'Both captains have agreed on the score. Ratings move once you confirm.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          height: 1.35,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.warning,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$n',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {String? action, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                action,
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _revenueCard(Map<String, dynamic> stats) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.primaryDark, AppColors.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: InkWell(
          onTap: () => Navigator.pushNamed(context, '/owner-reports'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.payments_outlined,
                      color: Colors.white70,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'REVENUE TODAY',
                        style: GoogleFonts.poppins(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.arrow_outward_rounded,
                      color: Colors.white70,
                      size: 19,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'PKR ${_parseNum(stats['revenueToday']).toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'View earnings & reports',
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pendingCard(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Material(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _goToTab(1),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.3),
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.pending_actions_outlined,
                  color: AppColors.warningText,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        count == 1
                            ? '1 booking needs your approval'
                            : '$count bookings need your approval',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.warningText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Review requests to keep your schedule moving',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.warningText,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _walletCard(
    Map<String, dynamic> wallet,
    List<dynamic> upcoming,
    double pendingEscrow,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.pushNamed(context, '/owner-wallet'),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: AppColors.accentLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.account_balance_wallet_outlined,
                        color: AppColors.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'WALLET BALANCE',
                            style: GoogleFonts.poppins(
                              color: AppColors.textSecondary,
                              fontSize: 10,
                              letterSpacing: 0.6,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'PKR ${_parseNum(wallet['balance']).toStringAsFixed(0)}',
                            style: GoogleFonts.poppins(
                              color: AppColors.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'From ${upcoming.where((booking) => booking['status'] == 'checked_in').length} check-ins',
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (pendingEscrow > 0)
                      _balanceChip(
                        Icons.hourglass_top_rounded,
                        'Escrow: PKR ${pendingEscrow.toStringAsFixed(0)}',
                        AppColors.warningText,
                        const Color(0xFFFEF3C7),
                      ),
                    _balanceChip(
                      Icons.lock_outline_rounded,
                      'Frozen: PKR ${_parseNum(wallet['frozen_balance']).toStringAsFixed(0)}',
                      AppColors.textSecondary,
                      AppColors.inputFill,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () =>
                        Navigator.pushNamed(context, '/owner-wallet'),
                    icon: const Icon(Icons.south_west_rounded, size: 16),
                    label: Text(
                      'Withdraw',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: AppColors.primary,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _balanceChip(
    IconData icon,
    String label,
    Color color,
    Color background,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: GoogleFonts.poppins(color: color, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(
    String label,
    String value,
    IconData icon,
    Color color, {
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: color, size: 21),
                    const Spacer(),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textSecondary,
                      size: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  value,
                  style: GoogleFonts.poppins(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: color,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    final actions = [
      (
        Icons.qr_code_scanner_rounded,
        'Scan QR',
        const Color(0xFF7C3AED),
        () => Navigator.pushNamed(context, '/owner-scan-qr'),
      ),
      (
        Icons.pending_actions_rounded,
        'Requests',
        AppColors.warningText,
        () => _goToTab(1),
      ),
      (Icons.stadium_rounded, 'My Venue', AppColors.primary, () => _goToTab(3)),
      (
        Icons.calendar_month_rounded,
        'Schedule',
        const Color(0xFF2563EB),
        () => _goToTab(2),
      ),
      (
        Icons.emoji_events_rounded,
        'Tournaments',
        const Color(0xFFB45309),
        () => Navigator.pushNamed(context, '/owner-tournaments'),
      ),
      (
        Icons.rule_rounded,
        'Verify Results',
        const Color(0xFF4338CA),
        () => Navigator.pushNamed(context, '/owner-verify-matches'),
      ),
      (
        Icons.summarize_outlined,
        'Earnings Report',
        const Color(0xFF334155),
        () => Navigator.pushNamed(context, '/owner-reports'),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 8.0;
          final textScale = MediaQuery.textScalerOf(context).scale(11.5) / 11.5;
          final minTileWidth = 88.0 * (textScale < 1 ? 1 : textScale);
          final columns =
              ((constraints.maxWidth + spacing) / (minTileWidth + spacing))
                  .floor()
                  .clamp(1, 3);
          // Equal-width tiles stay compact on phones. Content sets each row's
          // height, so larger accessibility text can wrap without clipping.
          return Column(
            children: [
              for (var start = 0; start < actions.length; start += columns)
                Padding(
                  padding: EdgeInsets.only(top: start == 0 ? 0 : spacing),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var column = 0; column < columns; column++) ...[
                          if (column > 0) const SizedBox(width: spacing),
                          Expanded(
                            child: start + column < actions.length
                                ? _quickActionTile(
                                    actions[start + column].$1,
                                    actions[start + column].$2,
                                    actions[start + column].$3,
                                    actions[start + column].$4,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _quickActionTile(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 108),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: Center(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookingRow(Map<String, dynamic> booking) {
    final trust = num.tryParse('${booking['trust_score']}')?.toInt() ?? 100;
    final trustLabel = trust >= 80
        ? 'HIGH TRUST'
        : trust >= 60
        ? 'FAIR'
        : 'LOW TRUST';
    final trustColor = trust >= 80
        ? AppColors.primary
        : trust >= 60
        ? AppColors.warningText
        : AppColors.error;
    final isPending = booking['status'] == 'pending';
    final startTime = (booking['start_time'] ?? '00:00').toString();
    final endTime = (booking['end_time'] ?? '00:00').toString();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isPending
              ? AppColors.warning.withValues(alpha: 0.4)
              : AppColors.border,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final identity = Row(
            children: [
              Container(
                width: 4,
                height: 44,
                decoration: BoxDecoration(
                  color: isPending ? AppColors.warning : AppColors.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      booking['player_name'] ?? 'Player',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        const Icon(
                          Icons.access_time_outlined,
                          size: 13,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '${startTime.length >= 5 ? startTime.substring(0, 5) : startTime} – ${endTime.length >= 5 ? endTime.substring(0, 5) : endTime}',
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
          final trustBadge = Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: trustColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              trustLabel,
              style: GoogleFonts.poppins(
                fontSize: 9,
                color: trustColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
          final scan = IconButton(
            tooltip: 'Scan booking QR',
            onPressed: () => Navigator.pushNamed(context, '/owner-scan-qr'),
            style: IconButton.styleFrom(
              backgroundColor: AppColors.accentLight,
              foregroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
          );
          if (constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(11) > 16) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                identity,
                const SizedBox(height: 12),
                Row(
                  children: [
                    Flexible(child: trustBadge),
                    const Spacer(),
                    scan,
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: identity),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [trustBadge, const SizedBox(height: 6), scan],
              ),
            ],
          );
        },
      ),
    );
  }

  double _parseNum(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }
}
