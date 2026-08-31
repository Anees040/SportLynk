import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
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
  /// The socket is opened HERE, not in the chat screens: a badge that only moves
  /// while you are already looking at the inbox is not a badge. The service is a
  /// singleton and connecting is idempotent, so a thread screen re-using it costs
  /// nothing — and Wave C's bell hangs off this same connection.
  ///
  /// The count is RE-READ rather than incremented, because the server decides what
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

  /// Chats opens FULL-SCREEN from the header rather than as a sixth bottom tab:
  /// five is already as many as a bottom bar can label legibly, and the inbox is
  /// somewhere you go and come back from, not somewhere you live.
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

  // ── BOTTOM NAV BAR ──────────────────────────────────────────
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
              return GestureDetector(
                onTap: () => _onTabChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent.withValues(alpha: 0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(selected ? items[i].$2 : items[i].$3,
                      color: selected ? AppColors.accent : const Color(0xFF94A3B8),
                      size: 24),
                    const SizedBox(height: 3),
                    Text(items[i].$1,
                      style: GoogleFonts.poppins(fontSize: 10,
                        color: selected ? AppColors.accent : const Color(0xFF94A3B8),
                        fontWeight: selected ? FontWeight.w700 : FontWeight.normal)),
                  ]),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  // ── HOME TAB ────────────────────────────────────────────────
  Widget _buildHome(AuthProvider auth) {
    final userName = auth.currentUser?.name ?? 'Player';
    final firstName = userName.split(' ').first;

    final wallet = _homeData?['wallet'] as Map<String, dynamic>?;
    final profile = _homeData?['profile'] as Map<String, dynamic>?;
    final upcomingBookings = (_homeData?['upcomingBookings'] as List?) ?? [];
    final balance = _parseNum(wallet?['balance'], 0);
    final trustScore = _parseNum(profile?['trust_score'], 100).round();
    final upcomingCount = upcomingBookings.length;

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          // ── HERO HEADER ──────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF052010), Color(0xFF0D3B20), Color(0xFF166534)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(children: [
                // Decorative circles
                Positioned(right: -30, top: -30,
                  child: Container(width: 160, height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.04)))),
                Positioned(right: 60, top: 60,
                  child: Container(width: 80, height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent.withValues(alpha: 0.08)))),

                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Top row: the wordmark, and the two live actions.
                      //
                      // The logo tile and the profile avatar are both gone on
                      // purpose. The tile and the wordmark said the same thing
                      // twice — and the asset fell back to a letter in a green
                      // square whenever it failed to load — while the avatar was
                      // a second route to a tab that is already in the bottom bar.
                      // What takes their place is the two things this screen has
                      // no other way to reach: the inbox and the bell.
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const BrandWordmark(),
                        Row(children: [
                          HeaderIconButton(
                            icon: Icons.chat_bubble_outline,
                            tooltip: 'Chats',
                            badge: _chatUnread,
                            onTap: _openChats,
                          ),
                          const SizedBox(width: 10),
                          // Live from Wave C. The bell also boots the notification
                          // stack for the session -- see NotificationBell.
                          const NotificationBell(),
                        ]),
                      ]),

                      const SizedBox(height: 20),

                      // Greeting
                      Text('Good ${_greeting()}, $firstName! 👋',
                        style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text('Ready to\nPlay Today?',
                        style: GoogleFonts.poppins(color: Colors.white,
                          fontSize: 28, fontWeight: FontWeight.w800, height: 1.15)),

                      const SizedBox(height: 20),

                      // Stats strip inside header
                      Row(children: [
                        _headerStat('$upcomingCount', 'Bookings', Icons.calendar_month_rounded),
                        _headerDivider(),
                        _headerStat('$trustScore', 'Trust Score', Icons.shield_rounded),
                        _headerDivider(),
                        _headerStat('PKR ${balance.toStringAsFixed(0)}', 'Balance', Icons.account_balance_wallet_rounded),
                      ]),
                    ]),
                  ),
                ),
              ]),
            ),
          ),

          // ── SEARCH BAR ───────────────────────────────────────
          SliverToBoxAdapter(
            child: Transform.translate(
              offset: const Offset(0, -1),
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/find-venues'),
                  child: Container(
                    height: 54,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.15),
                        blurRadius: 16, offset: const Offset(0, 4))],
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.2)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.search_rounded, color: Colors.white, size: 16),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Find venues, sports, opponents...',
                        style: GoogleFonts.poppins(color: const Color(0xFF94A3B8), fontSize: 13))),
                      const Icon(Icons.tune_rounded, color: AppColors.accent, size: 18),
                    ]),
                  ),
                ),
              ),
            ),
          ),

          // ── ASK SCOUT ─────────────────────────────────────────
          // Above Quick Actions, because it is the shortest path to every one of
          // them: "koi ground milega kal shaam" beats four taps through the grid.
          // The FAB handles discovery on the other tabs; this is the pitch.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: ScoutAskBanner(onTap: _openScout),
            ),
          ),

          // ── QUICK ACTIONS ─────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick Actions',
                  style: GoogleFonts.poppins(
                    fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                const SizedBox(height: 14),
                // 2×2 Grid
                Row(children: [
                  _quickTile(
                    Icons.stadium_rounded, 'Book Venue',
                    'Find & book grounds',
                    const Color(0xFF22C55E), const Color(0xFFDCFCE7),
                    () => Navigator.pushNamed(context, '/find-venues'),
                  ),
                  const SizedBox(width: 12),
                  _quickTile(
                    Icons.sports_kabaddi, 'Find Opponent',
                    'Challenge players',
                    const Color(0xFF6366F1), const Color(0xFFE0E7FF),
                    () => Navigator.pushNamed(context, '/find-opponents'),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  _quickTile(
                    Icons.emoji_events_rounded, 'Tournaments',
                    'Join competitions',
                    const Color(0xFFF59E0B), const Color(0xFFFEF3C7),
                    () => Navigator.pushNamed(context, '/tournaments'),
                  ),
                  const SizedBox(width: 12),
                  _quickTile(
                    Icons.leaderboard_rounded, 'Rankings',
                    'Team leaderboard',
                    const Color(0xFFEC4899), const Color(0xFFFCE7F3),
                    () => Navigator.pushNamed(context, '/team-rankings'),
                  ),
                ]),
              ]),
            ),
          ),

          // ── UPCOMING BOOKINGS ─────────────────────────────────
          SliverToBoxAdapter(child: _buildUpcomingBookings()),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  // ── HELPERS ─────────────────────────────────────────────────
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

  Widget _headerStat(String value, String label, IconData icon) {
    return Expanded(
      child: Column(children: [
        Icon(icon, color: AppColors.accent, size: 16),
        const SizedBox(height: 4),
        Text(value, style: GoogleFonts.poppins(
          color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(label, style: GoogleFonts.poppins(color: Colors.white54, fontSize: 10)),
      ]),
    );
  }

  Widget _headerDivider() => Container(
    width: 1, height: 36,
    color: Colors.white.withValues(alpha: 0.15),
    margin: const EdgeInsets.symmetric(horizontal: 4),
  );

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
