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
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) {
        if (mounted) setState(() { _loading = false; _error = 'Not authenticated'; });
        return;
      }
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/player/home'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted && data['success'] == true) {
          setState(() { _homeData = data['data']; _loading = false; });
        } else {
          if (mounted) setState(() { _loading = false; _error = data['message']; });
        }
      } else {
        if (mounted) setState(() { _loading = false; _error = 'Server error (${resp.statusCode})'; });
      }
    } catch (e) {
      debugPrint('Home load error: $e');
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
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
        setState(() { _loading = true; _error = null; });
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

          // ── QUICK ACTIONS ──────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick Actions',
                  style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  _quickAction(Icons.sports_soccer, 'Football', const Color(0xFF22C55E), () =>
                    Navigator.pushNamed(context, '/find-venues', arguments: {'sport': 'football'})),
                  _quickAction(Icons.sports_cricket, 'Cricket', const Color(0xFFF59E0B), () =>
                    Navigator.pushNamed(context, '/find-venues', arguments: {'sport': 'cricket'})),
                  _quickAction(Icons.calendar_month, 'My Bookings', const Color(0xFF3B82F6), () =>
                    setState(() => _tab = 1)),
                  _quickAction(Icons.account_balance_wallet, 'Wallet', const Color(0xFF8B5CF6), () =>
                    setState(() => _tab = 3)),
                ]),
              ]),
            ),
          ),

          // ── UPCOMING BOOKINGS ──────────────────────────────────
          SliverToBoxAdapter(
            child: _buildUpcomingBookings(),
          ),

          // ── POPULAR VENUES HEADER ──────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Popular Venues',
                  style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
                GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/find-venues'),
                  child: Text('See All',
                    style: GoogleFonts.poppins(fontSize: 13, color: AppColors.accent,
                      fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),

          // ── VENUE CARDS OR LOADING/ERROR STATE ─────────────────
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator(color: AppColors.accent)),
              ),
            )
          else if (_error != null && (_homeData == null))
            SliverToBoxAdapter(child: _errorState())
          else ...[
            _buildVenueList(),
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  // ── QUICK ACTION BUTTON ─────────────────────────────────────
  Widget _quickAction(IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(width: 64, height: 64,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.15)),
          ),
          child: Icon(icon, color: color, size: 28)),
        const SizedBox(height: 8),
        Text(label, style: GoogleFonts.poppins(fontSize: 11,
          color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
      ]),
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

  // ── EMPTY BOOKINGS ──────────────────────────────────────────
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

  // ── BOOKING CARD ────────────────────────────────────────────
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

  // ── VENUE LIST ──────────────────────────────────────────────
  Widget _buildVenueList() {
    final venues = (_homeData?['featuredVenues'] as List?) ?? [];
    if (venues.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(children: [
              const Icon(Icons.stadium_outlined, size: 48, color: AppColors.disabled),
              const SizedBox(height: 12),
              Text('No venues available yet',
                style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text('Check back soon for new venues near you',
                style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
            ]),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (_, i) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: _venueCard(venues[i]),
        ),
        childCount: venues.length,
      ),
    );
  }

  // ── VENUE CARD ──────────────────────────────────────────────
  Widget _venueCard(Map<String, dynamic> v) {
    final sportType = (v['sport_type'] ?? 'sport').toString();
    final sportColor = _sportColor(sportType);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 10, offset: const Offset(0, 2),
        )],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Image placeholder
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Container(
            height: 120, width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [const Color(0xFF0A1F13), sportColor.withValues(alpha: 0.7)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
            ),
            child: Stack(children: [
              Center(child: Icon(_sportIcon(sportType),
                color: Colors.white.withValues(alpha: 0.15), size: 64)),
              // Rating badge
              Positioned(top: 10, right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.star_rounded, color: Colors.amber, size: 14),
                    const SizedBox(width: 3),
                    Text('${v['rating'] ?? 'New'}',
                      style: GoogleFonts.poppins(color: Colors.white,
                        fontSize: 12, fontWeight: FontWeight.bold)),
                  ]),
                )),
              // Sport type badge
              Positioned(bottom: 10, left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: sportColor,
                    borderRadius: BorderRadius.circular(8)),
                  child: Text(sportType.toUpperCase(),
                    style: GoogleFonts.poppins(color: Colors.white,
                      fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                )),
            ]),
          ),
        ),
        // Info section
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v['name'] ?? 'Venue',
                style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.location_on_outlined,
                  color: AppColors.textSecondary, size: 14),
                const SizedBox(width: 3),
                Flexible(child: Text(v['city'] ?? v['address'] ?? '',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
            ])),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('PKR ${_formatPrice(v['price_per_hour'])}',
                style: GoogleFonts.poppins(color: AppColors.accent,
                  fontSize: 15, fontWeight: FontWeight.bold)),
              Text('/hour', style: GoogleFonts.poppins(fontSize: 10,
                color: AppColors.textSecondary)),
            ]),
          ]),
        ),
      ]),
    );
  }

  String _formatPrice(dynamic price) {
    if (price == null) return '0';
    if (price is num) return price.toStringAsFixed(0);
    return price.toString();
  }

  Color _sportColor(String sport) {
    switch (sport.toLowerCase()) {
      case 'football': return const Color(0xFF22C55E);
      case 'cricket': return const Color(0xFFF59E0B);
      case 'badminton': return const Color(0xFF3B82F6);
      case 'futsal': return const Color(0xFFEC4899);
      case 'basketball': return const Color(0xFFF97316);
      default: return const Color(0xFF8B5CF6);
    }
  }

  IconData _sportIcon(String sport) {
    switch (sport.toLowerCase()) {
      case 'football': return Icons.sports_soccer;
      case 'cricket': return Icons.sports_cricket;
      case 'badminton': return Icons.sports_tennis;
      case 'futsal': return Icons.sports_soccer;
      case 'basketball': return Icons.sports_basketball;
      default: return Icons.sports;
    }
  }

  // ── ERROR STATE ─────────────────────────────────────────────
  Widget _errorState() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          const Icon(Icons.cloud_off_outlined, size: 48, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text('Could not load venues',
            style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600,
              color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text('Pull down to refresh',
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

}
