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

class PlayerHomeScreen extends StatefulWidget {
  const PlayerHomeScreen({super.key});
  @override
  State<PlayerHomeScreen> createState() => _PlayerHomeScreenState();
}

class _PlayerHomeScreenState extends State<PlayerHomeScreen> {
  int _tab = 0;
  Map<String, dynamic>? _homeData;

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
          setState(() { _homeData = data['data']; });
        }
      }
    } catch (e) {
      debugPrint('Home load error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _tab,
        children: [
          _buildHome(auth),
          const BookingsScreen(),
          const TeamsScreen(),
          const WalletScreen(),
          const PlayerProfileScreen(),
        ],
      ),
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
          color: Colors.black.withValues(alpha: 0.06),
          blurRadius: 12, offset: const Offset(0, -3),
        )],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(items.length, (i) {
              final selected = _tab == i;
              return GestureDetector(
                onTap: () => setState(() => _tab = i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(selected ? items[i].$2 : items[i].$3,
                      color: selected ? AppColors.accent : AppColors.textSecondary,
                      size: selected ? 26 : 24),
                    const SizedBox(height: 2),
                    Text(items[i].$1,
                      style: GoogleFonts.poppins(fontSize: 10,
                        color: selected ? AppColors.accent : AppColors.textSecondary,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
                    if (selected)
                      Container(
                        margin: const EdgeInsets.only(top: 3),
                        width: 4, height: 4,
                        decoration: const BoxDecoration(
                          color: AppColors.accent, shape: BoxShape.circle),
                      ),
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

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () async {
        await _load();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          // ── HEADER ────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF0A1F13), Color(0xFF14532D)],
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Top row: logo + greeting + notification
                    Row(children: [
                      // Logo
                      Container(
                        width: 42, height: 42,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.3),
                            blurRadius: 8, offset: const Offset(0, 2),
                          )],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset('assets/images/logo.png', fit: BoxFit.cover,
                            errorBuilder: (a, b, c) => Container(
                              color: AppColors.accent,
                              child: Center(child: Text('S',
                                style: GoogleFonts.poppins(color: Colors.white,
                                  fontSize: 18, fontWeight: FontWeight.bold))),
                            )),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Hello, $firstName! 👋',
                          style: GoogleFonts.poppins(color: Colors.white,
                            fontSize: 18, fontWeight: FontWeight.bold)),
                        Text('Ready to play today?',
                          style: GoogleFonts.poppins(color: Colors.white60, fontSize: 12)),
                      ])),
                      // Avatar
                      GestureDetector(
                        onTap: () => setState(() => _tab = 4),
                        child: CircleAvatar(radius: 20,
                          backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                          child: Text(initial,
                            style: GoogleFonts.poppins(color: AppColors.accent,
                              fontSize: 16, fontWeight: FontWeight.bold))),
                      ),
                    ]),
                    const SizedBox(height: 18),
                    // Search bar
                    GestureDetector(
                      onTap: () => Navigator.pushNamed(context, '/find-venues'),
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(children: [
                          Icon(Icons.search_rounded,
                            color: Colors.white.withValues(alpha: 0.5), size: 20),
                          const SizedBox(width: 10),
                          Text('Search venues, sports...',
                            style: GoogleFonts.poppins(
                              color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),

          // ── QUICK ACTIONS (2x2 GRID) ─────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick Actions',
                  style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _bigActionCard(
                    Icons.stadium_outlined, 'Book a Venue', const Color(0xFFD0E0FF),
                    () => Navigator.pushNamed(context, '/find-venues'))),
                  const SizedBox(width: 14),
                  Expanded(child: _bigActionCard(
                    Icons.search_rounded, 'Find an\nOpponent', const Color(0xFFD0E0FF),
                    () => Navigator.pushNamed(context, '/find-opponents'))),
                ]),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _bigActionCard(
                    Icons.emoji_events_outlined, 'Join\nTournament', const Color(0xFFD0E0FF),
                    () => Navigator.pushNamed(context, '/tournaments'))),
                  const SizedBox(width: 14),
                  Expanded(child: _bigActionCard(
                    Icons.bar_chart_rounded, 'View\nRankings', const Color(0xFFD0E0FF),
                    () => Navigator.pushNamed(context, '/team-rankings'))),
                ]),
              ]),
            ),
          ),

          // ── UPCOMING BOOKINGS ──────────────────────────────────
          SliverToBoxAdapter(
            child: _buildUpcomingBookings(),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _bigActionCard(IconData icon, String label, Color bgColor, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, color: const Color(0xFF475569), size: 28),
          ),
          const SizedBox(height: 16),
          Text(label, textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B), height: 1.2)),
        ]),
      ),
    );
  }

  // ── UPCOMING BOOKINGS SECTION ───────────────────────────────
  Widget _buildUpcomingBookings() {
    final bookings = (_homeData?['upcomingBookings'] as List?) ?? [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Upcoming Bookings',
            style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700,
              color: AppColors.textPrimary)),
          GestureDetector(
            onTap: () => setState(() => _tab = 1),
            child: Text('View All',
              style: GoogleFonts.poppins(fontSize: 13, color: AppColors.accent,
                fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 12),
        bookings.isEmpty ? _emptyBookings() : SizedBox(
          height: 120,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: bookings.length,
            itemBuilder: (_, i) => _bookingCard(bookings[i]),
          ),
        ),
      ]),
    );
  }

  Widget _emptyBookings() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            color: AppColors.accentLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.calendar_today_outlined,
            color: AppColors.accent, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('No upcoming bookings',
            style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600,
              color: AppColors.textPrimary)),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/find-venues'),
            child: Text('Book a venue now →',
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent,
                fontWeight: FontWeight.w500)),
          ),
        ])),
      ]),
    );
  }

  Widget _bookingCard(Map<String, dynamic> b) {
    return Container(
      width: 250,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0A1F13), Color(0xFF166534)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(b['venue_name'] ?? 'Venue',
          style: GoogleFonts.poppins(color: Colors.white,
            fontWeight: FontWeight.bold, fontSize: 14),
          maxLines: 1, overflow: TextOverflow.ellipsis),
        Row(children: [
          const Icon(Icons.access_time, color: Colors.white54, size: 14),
          const SizedBox(width: 4),
          Text('${b['slot_date'] ?? ''} · ${_formatTime(b['start_time'])}',
            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11)),
        ]),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
          child: Text((b['status'] ?? 'confirmed').toString().toUpperCase(),
            style: GoogleFonts.poppins(color: Colors.white,
              fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
        ),
      ]),
    );
  }

  String _formatTime(dynamic t) {
    if (t == null) return '';
    final str = t.toString();
    if (str.length >= 5) return str.substring(0, 5);
    return str;
  }
}
