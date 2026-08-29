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
import '../../widgets/assistant/scout_fab.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
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
    final initial = userName.isNotEmpty ? userName[0].toUpperCase() : 'P';
    final avatarUrl = auth.currentUser?.avatarUrl;

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
                      // Top row: logo + avatar
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        // Logo + brand
                        Row(children: [
                          Container(
                            width: 38, height: 38,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1.5),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.asset('assets/images/logo.png', fit: BoxFit.cover,
                                errorBuilder: (a, b, c) => Container(
                                  color: AppColors.accent,
                                  child: Center(child: Text('S',
                                    style: GoogleFonts.poppins(color: Colors.white,
                                      fontSize: 16, fontWeight: FontWeight.bold))))),
                            ),
                          ),
                          const SizedBox(width: 10),
                          RichText(text: TextSpan(children: [
                            TextSpan(text: 'Sport',
                              style: GoogleFonts.poppins(color: Colors.white,
                                fontSize: 16, fontWeight: FontWeight.w800)),
                            TextSpan(text: 'Lynk',
                              style: GoogleFonts.poppins(color: AppColors.accent,
                                fontSize: 16, fontWeight: FontWeight.w800)),
                          ])),
                        ]),

                        // Avatar + notification bell
                        Row(children: [
                          Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                            ),
                            child: const Icon(Icons.notifications_outlined, color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: () => _onTabChanged(4),
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: AppColors.accent, width: 2.5),
                              ),
                              child: CircleAvatar(
                                radius: 20,
                                backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                                backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty)
                                    ? NetworkImage(avatarUrl) : null,
                                child: (avatarUrl == null || avatarUrl.isEmpty)
                                    ? Text(initial, style: GoogleFonts.poppins(
                                        color: AppColors.accent, fontSize: 16, fontWeight: FontWeight.bold))
                                    : null,
                              ),
                            ),
                          ),
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
