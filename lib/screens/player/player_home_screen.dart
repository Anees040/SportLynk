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
  int _prevTab = 0;
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

  void _onTabChanged(int index) {
    _prevTab = _tab;
    setState(() => _tab = index);
    // Auto-refresh when switching TO home or bookings tab
    if (index == 0 && _prevTab != 0) _load();
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
                onTap: () => _onTabChanged(i),
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
                  child: Row(children: [
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
                    // Avatar — shows Cloudinary photo if set, else initial
                    GestureDetector(
                      onTap: () => _onTabChanged(4),
                      child: () {
                        final avatarUrl = auth.currentUser?.avatarUrl;
                        if (avatarUrl != null && avatarUrl.isNotEmpty) {
                          return CircleAvatar(
                            radius: 22,
                            backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                            backgroundImage: NetworkImage(avatarUrl),
                          );
                        }
                        return CircleAvatar(
                          radius: 22,
                          backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                          child: Text(initial,
                            style: GoogleFonts.poppins(color: AppColors.accent,
                              fontSize: 16, fontWeight: FontWeight.bold)),
                        );
                      }(),
                    ),
                  ]),
                ),
              ),
            ),
          ),

          // ── SEARCH BAR ────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/find-venues'),
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 12, offset: const Offset(0, 4))],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    const Icon(Icons.search_rounded, color: AppColors.accent, size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text('Search venues, sports, opponents...',
                      style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 13))),
                    const Icon(Icons.tune_rounded, color: AppColors.textSecondary, size: 18),
                  ]),
                ),
              ),
            ),
          ),

          // ── LIVE STATS STRIP ──────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(children: [
                _miniStat(Icons.calendar_today_outlined, '$upcomingCount', 'Bookings', AppColors.accent),
                const SizedBox(width: 10),
                _miniStat(Icons.account_balance_wallet_outlined, 'PKR $balance', 'Balance', const Color(0xFF3B82F6)),
                const SizedBox(width: 10),
                _miniStat(Icons.shield_outlined, '$trustScore', 'Trust Score', AppColors.success),
              ]),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick Actions', style: GoogleFonts.poppins(
                  fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const SizedBox(height: 14),
                Row(children: [
                  _quickActionTile(
                    Icons.search_rounded,
                    'Book Venue',
                    const Color(0xFF22C55E),
                    const Color(0xFFDCFCE7),
                    () => Navigator.pushNamed(context, '/find-venues'),
                  ),
                  const SizedBox(width: 10),
                  _quickActionTile(
                    Icons.sports_kabaddi,
                    'Opponent',
                    const Color(0xFF6366F1),
                    const Color(0xFFE0E7FF),
                    () => Navigator.pushNamed(context, '/find-opponents'),
                  ),
                  const SizedBox(width: 10),
                  _quickActionTile(
                    Icons.emoji_events_rounded,
                    'Tournament',
                    const Color(0xFFF59E0B),
                    const Color(0xFFFEF3C7),
                    () => Navigator.pushNamed(context, '/tournaments'),
                  ),
                  const SizedBox(width: 10),
                  _quickActionTile(
                    Icons.leaderboard_rounded,
                    'Rankings',
                    const Color(0xFFEC4899),
                    const Color(0xFFFCE7F3),
                    () => Navigator.pushNamed(context, '/team-rankings'),
                  ),
                ]),
              ]),
            ),
          ),

          // ── UPCOMING BOOKINGS ──────────────────────────────────
          SliverToBoxAdapter(child: _buildUpcomingBookings()),

          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  // ── HELPERS ─────────────────────────────────────────────────
  num _parseNum(dynamic val, num fallback) {
    if (val == null) return fallback;
    if (val is num) return val;
    return num.tryParse(val.toString()) ?? fallback;
  }

  Widget _miniStat(IconData icon, String value, String label, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(value,
            style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.bold,
              color: AppColors.textPrimary),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(label, style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _quickActionTile(
    IconData icon,
    String label,
    Color iconColor,
    Color bgColor,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                height: 1.2,
              ),
            ),
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
            style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700,
              color: AppColors.textPrimary)),
          GestureDetector(
            onTap: () => _onTabChanged(1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accentLight,
                borderRadius: BorderRadius.circular(8)),
              child: Text('View All',
                style: GoogleFonts.poppins(
                  fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        bookings.isEmpty
            ? Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(children: [
                  Container(
                    width: 52, height: 52,
                    decoration: BoxDecoration(
                      color: AppColors.accentLight,
                      borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.calendar_today_outlined,
                      color: AppColors.accent, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('No upcoming bookings',
                      style: GoogleFonts.poppins(
                        fontSize: 14, fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => Navigator.pushNamed(context, '/find-venues'),
                      child: Text('Book a venue now →',
                        style: GoogleFonts.poppins(
                          fontSize: 12, color: AppColors.accent,
                          fontWeight: FontWeight.w500)),
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
            ? AppColors.warning
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
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0A1F13), Color(0xFF166534)]),
              borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.stadium_outlined,
              color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b['venue_name'] ?? 'Venue',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.bold, fontSize: 13,
                color: AppColors.textPrimary),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Row(children: [
              const Icon(Icons.calendar_today_outlined,
                size: 11, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(_fmtSlotDate(b['slot_date']),
                style: GoogleFonts.poppins(
                  fontSize: 11, color: AppColors.textSecondary)),
              const SizedBox(width: 10),
              const Icon(Icons.access_time,
                size: 11, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(_formatTime(b['start_time']),
                style: GoogleFonts.poppins(
                  fontSize: 11, color: AppColors.textSecondary)),
            ]),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8)),
            child: Text(status.toUpperCase(),
              style: GoogleFonts.poppins(
                fontSize: 9, color: statusColor,
                fontWeight: FontWeight.bold, letterSpacing: 0.3)),
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
