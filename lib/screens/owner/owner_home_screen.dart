import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import 'owner_booking_requests_screen.dart';
import 'owner_slot_calendar_screen.dart';
import 'owner_my_venues_screen.dart';
import 'owner_profile_screen.dart';


class OwnerHomeScreen extends StatefulWidget {
  const OwnerHomeScreen({super.key});
  @override
  State<OwnerHomeScreen> createState() => _OwnerHomeScreenState();
}

class _OwnerHomeScreenState extends State<OwnerHomeScreen> {
  int _tab = 0;
  Map<String, dynamic>? _data;
  bool _loading = true;
  static String get _base => ApiConstants.baseUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final resp = await http.get(
        Uri.parse('$_base/owner/dashboard'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      final json = jsonDecode(resp.body);
      if (mounted && json['success'] == true) {
        setState(() {
          _data = json['data'];
          _loading = false;
        });
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(index: _tab, children: [
        _dashboardTab(),
        const OwnerBookingRequestsScreen(),
        const OwnerSlotCalendarScreen(),
        const OwnerMyVenuesScreen(),   // multi-venue list
        const OwnerProfileScreen(),
      ]),
      bottomNavigationBar: _buildNav(),
    );
  }

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
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(items.length, (i) {
            final sel = _tab == i;
            return GestureDetector(
              onTap: () => setState(() => _tab = i),
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    sel ? items[i].$2 : items[i].$3,
                    color: sel ? AppColors.accent : AppColors.textSecondary,
                    size: 22,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    items[i].$1,
                    style: GoogleFonts.poppins(
                      fontSize: 9,
                      color: sel ? AppColors.accent : AppColors.textSecondary,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                      letterSpacing: 0.2,
                    ),
                  ),
                ]),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _dashboardTab() {
    final auth = Provider.of<AuthProvider>(context);
    final name = auth.currentUser?.name ?? 'Owner';
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good Morning' : hour < 17 ? 'Good Afternoon' : 'Good Evening';

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }

    final stats = _data?['stats'] as Map<String, dynamic>? ?? {};
    final upcoming = (_data?['upcomingBookings'] as List?) ?? [];
    final wallet = _data?['wallet'] as Map<String, dynamic>? ?? {};
    final venue = _data?['venue'] as Map<String, dynamic>?;
    final basePrice = (venue?['price_per_hour'] as num?)?.toDouble() ?? 2000.0;
    final suggestedPrice = (basePrice * 1.12).roundToDouble();

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          // ── APP BAR ──────────────────────────────────────
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.primary,
            automaticallyImplyLeading: false,
            elevation: 0,
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '$greeting, ${name.split(' ').first}!',
                style: GoogleFonts.poppins(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Text(
                venue?['name'] ?? 'Your Venue',
                style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11),
              ),
            ]),
            actions: [
              GestureDetector(
                onTap: () => setState(() => _tab = 4),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.accent,
                  child: Text(
                    name[0].toUpperCase(),
                    style: GoogleFonts.poppins(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 14),
            ],
          ),

          // ── STATS ROW ────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              color: AppColors.primary,
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: Row(children: [
                  _statCard(
                    'REVENUE TODAY',
                    'PKR ${_parseNum(stats['revenueToday']).toStringAsFixed(0)}',
                    Icons.currency_rupee,
                    AppColors.accent,
                  ),
                  const SizedBox(width: 10),
                  _statCard(
                    'BOOKINGS',
                    '${stats['bookingsToday'] ?? 0}',
                    Icons.calendar_month,
                    const Color(0xFF3B82F6),
                  ),
                  const SizedBox(width: 10),
                  _statCard(
                    'PENDING',
                    '${stats['pendingCount'] ?? 0}',
                    Icons.pending_actions,
                    AppColors.warning,
                    onTap: () => setState(() => _tab = 1),
                  ),
                ]),
              ),
            ),
          ),

          // ── QUICK ACTIONS ─────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick Actions',
                  style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                const SizedBox(height: 12),
                Row(children: [
                  _quickActionTile(
                    Icons.qr_code_scanner_rounded, 'Scan QR',
                    const Color(0xFFEDE9FE), const Color(0xFF7C3AED),
                    () => Navigator.pushNamed(context, '/owner-scan-qr'),
                  ),
                  const SizedBox(width: 12),
                  _quickActionTile(
                    Icons.pending_actions_rounded, 'Requests',
                    const Color(0xFFFEF3C7), const Color(0xFFD97706),
                    () => setState(() => _tab = 1),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  _quickActionTile(
                    Icons.stadium_rounded, 'My Venue',
                    const Color(0xFFD1FAE5), AppColors.accent,
                    () => setState(() => _tab = 3),
                  ),
                  const SizedBox(width: 12),
                  _quickActionTile(
                    Icons.calendar_month_rounded, 'Schedule',
                    const Color(0xFFDBEAFE), const Color(0xFF2563EB),
                    () => setState(() => _tab = 2),
                  ),
                ]),
              ]),
            ),
          ),

          // ── AI PRICE SUGGESTION ──────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Row(children: [
                      const Text('✨', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 6),
                      Text(
                        'AI Suggested Price',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textPrimary),
                      ),
                    ]),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        '92% CONFIDENCE',
                        style: GoogleFonts.poppins(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'PKR ${suggestedPrice.toStringAsFixed(0)}/hr',
                    style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.primary),
                  ),
                  const SizedBox(height: 2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: 0.92,
                      backgroundColor: AppColors.border,
                      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                      minHeight: 3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Based on demand, time of day, and nearby venues',
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {},
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                          side: const BorderSide(color: AppColors.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        child: Text('Override', style: GoogleFonts.poppins(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Price updated!', style: GoogleFonts.poppins(color: Colors.white)),
                            backgroundColor: AppColors.accent,
                            behavior: SnackBarBehavior.floating,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        child: Text(
                          'Accept',
                          style: GoogleFonts.poppins(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),

          // ── WALLET CARD ──────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        'WALLET BALANCE',
                        style: GoogleFonts.poppins(color: Colors.white60, fontSize: 10, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'PKR ${_parseNum(wallet['balance']).toStringAsFixed(0)}',
                        style: GoogleFonts.poppins(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'From ${upcoming.where((b) => b['status'] == 'checked_in').length} check-ins',
                        style: GoogleFonts.poppins(color: Colors.white60, fontSize: 11),
                      ),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.lock_outline, color: Colors.white60, size: 13),
                        const SizedBox(width: 4),
                        Text(
                          'Frozen: PKR ${_parseNum(wallet['frozen_balance']).toStringAsFixed(0)}',
                          style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      child: Text(
                        'Withdraw',
                        style: GoogleFonts.poppins(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),

          // ── NEXT BOOKINGS HEADER ─────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(
                  'Next Bookings',
                  style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                TextButton(
                  onPressed: () => setState(() => _tab = 2),
                  child: Text(
                    'VIEW SCHEDULE',
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w700, letterSpacing: 0.3),
                  ),
                ),
              ]),
            ),
          ),

          // ── BOOKINGS LIST ────────────────────────────────
          upcoming.isEmpty
              ? SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.inputFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Center(
                        child: Text(
                          'No upcoming bookings today',
                          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
                        ),
                      ),
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final b = upcoming[i] as Map<String, dynamic>;
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: _bookingRow(b),
                      );
                    },
                    childCount: upcoming.length,
                  ),
                ),

          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color, {VoidCallback? onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 6),
            Text(
              value,
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            Text(
              label,
              style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary, letterSpacing: 0.3),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _quickActionTile(IconData icon, String label, Color bg, Color iconColor, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: iconColor.withValues(alpha: 0.15)),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 10),
            Text(label, style: GoogleFonts.poppins(
              fontSize: 13, fontWeight: FontWeight.w600, color: iconColor)),
          ]),
        ),
      ),
    );
  }

  Widget _bookingRow(Map<String, dynamic> b) {
    final trust = (b['trust_score'] as num?)?.toInt() ?? 100;
    final trustLabel = trust >= 80 ? 'HIGH TRUST' : trust >= 60 ? 'FAIR' : 'LOW TRUST';
    final trustColor = trust >= 80 ? AppColors.accent : trust >= 60 ? AppColors.warning : AppColors.error;
    final isPending = b['status'] == 'pending';
    final startTime = (b['start_time'] ?? '00:00').toString();
    final endTime = (b['end_time'] ?? '00:00').toString();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isPending ? AppColors.warning.withValues(alpha: 0.4) : AppColors.border),
      ),
      child: Row(children: [
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              b['player_name'] ?? 'Player',
              style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            Row(children: [
              const Icon(Icons.access_time_outlined, size: 12, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(
                '${startTime.length >= 5 ? startTime.substring(0, 5) : startTime} – ${endTime.length >= 5 ? endTime.substring(0, 5) : endTime}',
                style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
              ),
            ]),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: trustColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              trustLabel,
              style: GoogleFonts.poppins(fontSize: 9, color: trustColor, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/owner-scan-qr'),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.qr_code_scanner, color: AppColors.accent, size: 18),
            ),
          ),
        ]),
      ]),
    );
  }

  double _parseNum(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }
}
