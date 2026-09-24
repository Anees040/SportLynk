import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/api_constants.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import 'player_profile_screen.dart';
import 'bookings_screen.dart';
import 'wallet_screen.dart';
import 'teams_screen.dart';
import '../../services/chat_service.dart';
import '../../services/realtime_service.dart';
import '../../widgets/assistant/scout_fab.dart';
import '../../widgets/header_actions.dart';
import '../../widgets/notification_bell.dart';
import '../shared/chats_screen.dart';
import 'assistant_screen.dart';

class PlayerHomeScreen extends StatefulWidget {
  const PlayerHomeScreen({super.key});
  @override
  State<PlayerHomeScreen> createState() => _PlayerHomeScreenState();
}

class _PlayerHomeScreenState extends State<PlayerHomeScreen> {
  int _tab = 0;
  int _prevTab = 0;
  Map<String, dynamic>? _homeData;

  /// Reaches into the live Bookings tab so a booking made in the chat can be pulled
  /// in immediately. The tab is inside an [IndexedStack] with `wantKeepAlive`, so its
  /// State outlives every tab switch — the key is the only handle to it.
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
    _load();
    _watchChat();
  }

  @override
  void dispose() {
    _badgeDebounce?.cancel();
    _msgSub?.cancel();
    super.dispose();
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
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) return;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/player/home'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted && data['success'] == true) {
          setState(() => _homeData = data['data']);
        }
      }
    } catch (e) {
      debugPrint('Home load error: $e');
    }
  }

  void _onTabChanged(int index) {
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
    if (target != null && target != _tab) _onTabChanged(target);
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
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _tab,
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
    );
  }

  // Bottom navigation bar
  Widget _buildNav() {
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(items.length, (i) {
              final selected = _tab == i;
              return Expanded(
                child: GestureDetector(
                  onTap: () => _onTabChanged(i),
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.accent.withValues(alpha: 0.1) : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(selected ? items[i].$2 : items[i].$3,
                        color: selected ? AppColors.accent : const Color(0xFF94A3B8),
                        size: 24),
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(items[i].$1,
                          style: GoogleFonts.poppins(fontSize: 10,
                            color: selected ? AppColors.accent : const Color(0xFF94A3B8),
                            fontWeight: selected ? FontWeight.w700 : FontWeight.normal)),
                      ),
                    ]),
                  ),
                ),
              );
            }),
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
  Widget _buildHome(AuthProvider auth) {
    final firstName = (auth.currentUser?.name ?? 'Player').split(' ').first;
    final profile = _homeData?['profile'] as Map<String, dynamic>?;
    final upcoming = (_homeData?['upcomingBookings'] as List?) ?? [];
    final trustScore = _parseNum(profile?['trust_score'], 100).round();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Column(children: [
        _fixedHeader(),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.accent,
            onRefresh: _load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics()),
              slivers: [
                SliverToBoxAdapter(child: _greetingBlock(firstName)),
                SliverToBoxAdapter(child: _statsRow(upcoming.length, trustScore)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                    child: ScoutAskBanner(onTap: _openScout),
                  ),
                ),
                SliverToBoxAdapter(child: _quickActions()),
                SliverToBoxAdapter(child: _buildUpcomingBookings()),
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

  /// The fixed brand header: wordmark on the left, the two live actions on the
  /// right. The wallet balance, the greeting and the stat strip that used to sit
  /// here have moved onto the scrollable canvas below; a header that never moves
  /// carries identity and the two destinations the bottom bar cannot reach — the
  /// inbox and the bell — and nothing that scrolls.
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
            onTap: () => _onTabChanged(1),
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

  Widget _buildUpcomingBookings() {
    final bookings = (_homeData?['upcomingBookings'] as List?) ?? [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Upcoming Bookings',
            style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800,
              color: AppColors.textPrimary)),
          GestureDetector(
            onTap: () => _onTabChanged(1),
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
                children: bookings.take(3).map((b) =>
                  _bookingCard(b as Map<String, dynamic>)).toList(),
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
              Text(_formatTime(b['start_time']),
                style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFF94A3B8))),
            ]),
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
