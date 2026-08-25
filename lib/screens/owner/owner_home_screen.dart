import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../models/match.dart';
import '../../providers/auth_provider.dart';
import '../../services/match_service.dart';
import '../../services/pricing_service.dart';
import '../../services/realtime_service.dart';
import '../../widgets/apply_price_sheet.dart';
import '../../widgets/pricing_widgets.dart';
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

class _OwnerHomeScreenState extends State<OwnerHomeScreen> {
  int _tab = 0;
  Map<String, dynamic>? _data;
  bool _loading = true;
  static String get _base => ApiConstants.baseUrl;

  // ── Match results awaiting this owner's verification (ER2.2) ──
  // Kept out of /owner/dashboard on purpose: a failure fetching matches must not
  // be able to blank the revenue and bookings the owner actually opened the app for.
  final _matchService = MatchService();
  List<MatchModel> _toVerify = const [];
  StreamSubscription? _matchSub;

  // ── AI price suggestion (FR4.17) ──────────────────────────
  // Loaded on its own, AFTER the dashboard, because the venue id it needs comes out
  // of the dashboard payload and because a slow or dead ml-service must never delay
  // the revenue figures. `_priceLoading` starts false: there is nothing to load
  // until we know which venue.
  final _pricingService = PricingService();
  PriceSuggestion? _price;
  bool _priceLoading = false;
  String? _priceVenueId;

  @override
  void initState() {
    super.initState();
    _load();
    _loadToVerify();
    // The card should appear the moment the second captain submits, without the
    // owner having to pull to refresh. The socket is already connected for every
    // signed-in role, so this costs nothing when there is nothing to say.
    _matchSub = RealtimeService().matchUpdates.listen((_) {
      if (mounted) _loadToVerify();
    });
  }

  @override
  void dispose() {
    _matchSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() => Future.wait([_load(), _loadToVerify()]);

  /// Fetches the suggestion for [venueId]. The server picks the date (PKT today) and
  /// the hour (the venue's own peak-adjacent hour) — deliberately not duplicated
  /// here, because two implementations of "which hour do we mean" is two answers.
  Future<void> _loadPricing(String venueId) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null || token.isEmpty) return;
    setState(() {
      _priceLoading = true;
      _priceVenueId = venueId;
    });
    final s = await _pricingService.suggestion(token, venueId);
    if (!mounted) return;
    setState(() {
      _price = s;
      _priceLoading = false;
    });
  }

  /// Opens the slot picker. Returns only after the sheet closes, so the card and the
  /// dashboard both refresh against the prices that were actually written — the
  /// server drops its cached suggestion for this venue on a successful apply, so the
  /// re-fetch is guaranteed to be recomputed rather than served stale.
  Future<void> _openApply() async {
    final s = _price;
    final venueId = _priceVenueId;
    if (s == null || venueId == null) return;
    final applied = await showApplyPriceSheet(context, venueId: venueId, suggestion: s);
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
        // Chained rather than parallel: the venue id only exists once this landed.
        // Not awaited by the caller's refresh indicator either — the spinner should
        // stop when the revenue numbers are on screen, not when the ML service
        // finishes thinking.
        final venueId = (json['data']?['venue']?['id'])?.toString();
        if (venueId != null && venueId.isNotEmpty) _loadPricing(venueId);
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
    final pendingEscrow = _parseNum(_data?['pendingEscrow']);

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _refreshAll,
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

          // ── MATCH RESULTS TO VERIFY (ER2.2) ──────────────
          // Only rendered when the queue is non-empty: it is a task, not a
          // statistic, so an empty version of it would be noise every other day.
          if (_toVerify.isNotEmpty)
            SliverToBoxAdapter(child: _verifyCard()),

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

          // ── AI PRICE SUGGESTION (FR4.17) ─────────────────
          // Real model output, not `base × 1.12`. The card decides for itself what it
          // is allowed to claim from the payload's `source`, and Apply is the only
          // path from a suggestion to a price a player will actually be charged.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: AiPriceCard(
                suggestion: _price,
                loading: _priceLoading,
                onRetry: _priceVenueId == null ? null : () => _loadPricing(_priceVenueId!),
                // Nullable on purpose: no button at all unless there is a real,
                // actionable model suggestion to apply. A rule-of-thumb price is
                // shown for information; it is not something to write to slots.
                onApply: (_price != null && _price!.isModel && _price!.isActionable)
                    ? _openApply
                    : null,
              ),
            ),
          ),

          // ── WALLET CARD ──────────────────────────────────
          SliverToBoxAdapter(
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/owner-wallet'),
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
                      if (pendingEscrow > 0)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.hourglass_top, color: AppColors.warning, size: 13),
                            const SizedBox(width: 4),
                            Text(
                              'Escrow: PKR ${pendingEscrow.toStringAsFixed(0)}',
                              style: GoogleFonts.poppins(color: AppColors.warning, fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ]),
                        ),
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
                        onPressed: () => Navigator.pushNamed(context, '/owner-wallet'),
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
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
              color: AppColors.warning.withValues(alpha: 0.06),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.fact_check_outlined,
                    color: Color(0xFFB45309), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    n == 1 ? 'Match result to verify' : '$n match results to verify',
                    style: GoogleFonts.poppins(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    n == 1
                        ? '${first.challenger.name} vs ${first.opponent.name} — both captains agreed on the score.'
                        : 'Both captains have agreed on the score. Ratings move once you confirm.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                        fontSize: 11, height: 1.35, color: AppColors.textSecondary),
                  ),
                ]),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.warning,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('$n',
                    style: GoogleFonts.poppins(
                        color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 20),
            ]),
          ),
        ),
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
