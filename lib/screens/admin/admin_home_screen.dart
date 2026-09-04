import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/notification_bell.dart';
import '../../services/review_service.dart';
import 'admin_registration_detail_screen.dart';
import 'admin_moderation_screen.dart';
import '../../services/admin_service.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});
  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _pending = [];
  List<Map<String, dynamic>> _approved = [];
  List<Map<String, dynamic>> _rejected = [];
  List<Map<String, dynamic>> _pendingVenues = [];
  bool _loadingStats = true;
  bool _loadingList = true;
  int _openFlags = 0; // reviews awaiting moderation (not yet hidden)
  // Open disputes, for the desk tile. There is no cheap count for this: the queue
  // is a keyset page sorted by what is at stake, so one page is read and the tile
  // says "50+" rather than inventing a total the server never sent.
  int _openDisputes = 0;
  bool _moreDisputes = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 5, vsync: this);
    _tab.addListener(() {
      if (!_tab.indexIsChanging) {
        final statuses = ['pending', 'approved', 'rejected'];
        if (_tab.index > 0 && _tab.index < 4) {
          _loadList(statuses[_tab.index - 1]);
        } else if (_tab.index == 4) {
          _loadVenues();
        }
      }
    });
    _loadStats();
    _loadList('pending');
    _loadVenues();
    _loadFlags();
    _loadDisputes();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String get _base => ApiConstants.baseUrl;
  String get _token =>
      Provider.of<AuthProvider>(context, listen: false).token ?? '';

  Future<void> _loadStats() async {
    try {
      final r = await http.get(
        Uri.parse('$_base/admin/stats'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        setState(() {
          _stats = d['data'];
          _loadingStats = false;
        });
      } else {
        if (mounted) {
          _snack('Failed to load stats: ${d['message'] ?? 'Unknown error'}');
          setState(() => _loadingStats = false);
        }
      }
    } catch (e) {
      if (mounted) {
        _snack('Error loading stats: $e');
        setState(() => _loadingStats = false);
      }
    }
  }

  Future<void> _loadList(String status) async {
    if (mounted) setState(() => _loadingList = true);
    try {
      final r = await http.get(
        Uri.parse('$_base/admin/registrations?status=$status'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        final list = List<Map<String, dynamic>>.from(d['data']);
        setState(() {
          if (status == 'pending') _pending = list;
          if (status == 'approved') _approved = list;
          if (status == 'rejected') _rejected = list;
          _loadingList = false;
        });
      } else {
        if (mounted) {
          _snack('Failed to load $status list: ${d['message'] ?? 'Unknown error'}');
          setState(() => _loadingList = false);
        }
      }
    } catch (e) {
      if (mounted) {
        _snack('Error loading $status list: $e');
        setState(() => _loadingList = false);
      }
    }
  }

  Future<void> _loadVenues() async {
    if (mounted) setState(() => _loadingList = true);
    try {
      final r = await http.get(
        Uri.parse('$_base/admin/venues/pending'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        setState(() {
          _pendingVenues = List<Map<String, dynamic>>.from(d['data']);
          _loadingList = false;
        });
      } else {
        if (mounted) setState(() => _loadingList = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  // Moderation queue badge count. The count covers only reviews still awaiting a
  // decision (not yet hidden) — a review the admin already hid is "handled"
  // and should not keep the badge lit. Failure is silent: the badge simply
  // stays at its last value, never blocking the dashboard.
  Future<void> _loadDisputes() async {
    final page = await AdminService().disputes(_token, limit: 50);
    if (mounted) {
      setState(() {
        _openDisputes = page.items.length;
        _moreDisputes = page.hasMore;
      });
    }
  }

  Future<void> _loadFlags() async {
    try {
      final q = await ReviewService().moderationQueue(_token);
      if (mounted) setState(() => _openFlags = q.where((r) => !r.hidden).length);
    } catch (_) {/* keep prior count; moderation is reachable regardless */}
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // Opens the moderation queue and refreshes the badge on return, so acting on
  // a review (hide/dismiss) is reflected the moment the admin comes back.
  Future<void> _openModeration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AdminModerationScreen()),
    );
    _loadFlags();
  }

  // AppBar entry to the moderation queue with a live open-flag badge.
  Widget _moderationAction() => IconButton(
        tooltip: 'Moderation queue',
        onPressed: _openModeration,
        icon: Stack(clipBehavior: Clip.none, children: [
          const Icon(Icons.flag_outlined, color: Colors.white),
          if (_openFlags > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 16),
                decoration: BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: AppColors.primary, width: 1.5),
                ),
                child: Text(
                  _openFlags > 99 ? '99+' : '$_openFlags',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                      color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ]),
      );


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.admin_panel_settings, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Text('Admin Panel',
              style: GoogleFonts.poppins(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        ]),
        actions: [
          // Admins receive notifications like anyone else -- a dispute
          // raised, an owner application, a suspension they issued -- and this is
          // also the widget that starts the notification stack for the session,
          // which is why it is on all three home screens and not just the two
          // player-facing ones.
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Center(child: NotificationBell()),
          ),
          _moderationAction(),
          Container(
            margin: const EdgeInsets.only(right: 14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
            child: Text('ADMIN',
                style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
          ),
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: () {
              Provider.of<AuthProvider>(context, listen: false).logout();
              Navigator.pushNamedAndRemoveUntil(context, '/welcome', (r) => false);
            },
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: AppColors.accent,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle:
              GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: 'DASHBOARD'),
            Tab(text: 'OWNERS (P)'),
            Tab(text: 'OWNERS (A)'),
            Tab(text: 'OWNERS (R)'),
            Tab(text: 'VENUES'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildDashboard(),
          _buildList('pending'),
          _buildList('approved'),
          _buildList('rejected'),
          _buildVenueList(),
        ],
      ),
    );
  }

  // Dashboard tab
  Widget _buildDashboard() {
    if (_loadingStats) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    final s = _stats ?? {};
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () async {
        await _loadStats();
        await _loadList('pending');
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header Banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SportLynk Control Center',
                  style: GoogleFonts.poppins(
                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Manage owner registrations and platform activity',
                  style: GoogleFonts.poppins(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 16),
              Row(children: [
                _heroBadge(Icons.pending_actions_outlined,
                    '${s['pendingRegistrations'] ?? 0}', 'Pending', AppColors.warning),
                const SizedBox(width: 10),
                _heroBadge(Icons.check_circle_outline,
                    '${s['approvedOwners'] ?? 0}', 'Approved', AppColors.accent),
                const SizedBox(width: 10),
                _heroBadge(Icons.cancel_outlined,
                    '${s['rejectedOwners'] ?? 0}', 'Rejected', AppColors.error),
              ]),
            ]),
          ),
          const SizedBox(height: 20),

          Text('Platform Overview',
              style: GoogleFonts.poppins(
                  fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 12),

          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.6,
            children: [
              _statCard(Icons.person_outline, 'Total Players',
                  '${s['totalPlayers'] ?? 0}', const Color(0xFF6366F1)),
              _statCard(Icons.stadium_outlined, 'Active Venues',
                  '${s['activeVenues'] ?? 0}', AppColors.accent),
              _statCard(Icons.calendar_today_outlined, 'Active Bookings',
                  '${s['activeBookings'] ?? 0}', const Color(0xFFF59E0B)),
              _statCard(Icons.pending_actions_outlined, 'Pending Review',
                  '${s['pendingRegistrations'] ?? 0}', AppColors.error),
            ],
          ),
          const SizedBox(height: 20),

          // Quick actions
          Text('Quick Actions',
              style: GoogleFonts.poppins(
                  fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          _quickAction(Icons.pending_actions, 'Review Pending Registrations',
              '${s['pendingRegistrations'] ?? 0} awaiting review',
              () => _tab.animateTo(1)),
          const SizedBox(height: 8),
          _quickAction(Icons.flag_outlined, 'Moderation Queue',
              _openFlags == 0
                  ? 'No reviews awaiting moderation'
                  : '$_openFlags ${_openFlags == 1 ? 'review' : 'reviews'} awaiting moderation',
              _openModeration),
          const SizedBox(height: 8),
          // The admin desk
          // Disputes first: a disputed match is frozen until someone rules on it, so
          // it is the only queue here where waiting costs the players something.
          _quickAction(Icons.gavel_rounded, 'Match Disputes',
              _openDisputes == 0
                  ? 'Nothing waiting'
                  : '$_openDisputes${_moreDisputes ? '+' : ''} '
                      '${_openDisputes == 1 && !_moreDisputes ? 'match' : 'matches'} '
                      'waiting on a ruling',
              () async {
            await Navigator.pushNamed(context, '/admin-disputes');
            if (mounted) await _loadDisputes();
          }),
          const SizedBox(height: 8),
          _quickAction(Icons.manage_accounts_outlined, 'Users',
              'Search, suspend and reinstate accounts',
              () => Navigator.pushNamed(context, '/admin-users')),
          const SizedBox(height: 8),
          _quickAction(Icons.tune_rounded, 'Platform Settings',
              'Commission, deposits, Elo, sports -- applies with no restart',
              () => Navigator.pushNamed(context, '/admin-settings')),
          const SizedBox(height: 8),
          _quickAction(Icons.summarize_outlined, 'Platform Report',
              'Commission earned per owner, exportable as CSV',
              () => Navigator.pushNamed(context, '/admin-reports')),
          const SizedBox(height: 8),
          _quickAction(Icons.refresh_rounded, 'Refresh Stats', 'Pull latest data',
              () async {
            await _loadStats();
            await _loadList('pending');
            await _loadFlags();
          }),
        ]),
      ),
    );
  }

  Widget _heroBadge(IconData icon, String value, String label, Color color) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(value,
                style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            Text(label,
                style: GoogleFonts.poppins(color: Colors.white60, fontSize: 10)),
          ]),
        ),
      );

  Widget _statCard(IconData icon, String label, String value, Color color) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ],
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value,
                  style: GoogleFonts.poppins(
                      fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
              Text(label,
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      );

  Widget _quickAction(IconData icon, String title, String sub, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            Icon(icon, color: AppColors.accent, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: GoogleFonts.poppins(
                        fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                Text(sub,
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
              ]),
            ),
            const Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textSecondary),
          ]),
        ),
      );

  // Registrations list tab
  Widget _buildList(String status) {
    final list = status == 'approved'
        ? _approved
        : status == 'rejected'
            ? _rejected
            : _pending;

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () => _loadList(status),
      child: _loadingList
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : list.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.inbox_outlined,
                        size: 56, color: AppColors.textSecondary.withValues(alpha: 0.4)),
                    const SizedBox(height: 12),
                    Text('No $status registrations',
                        style: GoogleFonts.poppins(
                            color: AppColors.textSecondary, fontSize: 15)),
                  ]),
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics()),
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _regCard(list[i]),
                ),
    );
  }

  String _getInitial(String? name) {
    if (name == null || name.trim().isEmpty) return 'O';
    return name.trim()[0].toUpperCase();
  }

  Widget _regCard(Map<String, dynamic> reg) {
    final vstatus = reg['verification_status'] as String? ?? 'pending';
    final Color statusColor = vstatus == 'approved'
        ? AppColors.accent
        : vstatus == 'rejected'
            ? AppColors.error
            : AppColors.warning;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AdminRegistrationDetailScreen(
            registration: reg,
            onReviewed: () => _loadList(vstatus),
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ],
        ),
        child: Row(children: [
          // Avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
                color: AppColors.primary, borderRadius: BorderRadius.circular(12)),
            child: Center(
              child: Text(
                _getInitial(reg['owner_name']),
                style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(reg['owner_name'] ?? 'Unknown',
                  style: GoogleFonts.poppins(
                      fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
              const SizedBox(height: 2),
              Text(reg['ground_name'] ?? reg['business_name'] ?? 'Unnamed Ground',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.location_on_outlined,
                      size: 12, color: AppColors.textSecondary),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(reg['city'] ?? '—',
                        style: GoogleFonts.poppins(
                            fontSize: 11, color: AppColors.textSecondary),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  const Icon(Icons.currency_rupee, size: 12, color: AppColors.textSecondary),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text('PKR ${reg['price_per_hour'] ?? '—'}/hr',
                        style: GoogleFonts.poppins(
                            fontSize: 11, color: AppColors.textSecondary),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ]),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(vstatus.toUpperCase(),
                  style: GoogleFonts.poppins(
                      color: statusColor, fontSize: 9, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 6),
            const Icon(Icons.arrow_forward_ios,
                size: 12, color: AppColors.textSecondary),
          ]),
        ]),
      ),
    );
  }

  Future<void> _approveVenue(String venueId) async {
    try {
      final r = await http.patch(
        Uri.parse('$_base/admin/venues/$venueId/approve'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        _snack('Venue approved and is now live!');
        _loadVenues();
        _loadStats();
      } else {
        if (mounted) _snack(d['message'] ?? 'Failed');
      }
    } catch (e) {
      if (mounted) _snack('Network error');
    }
  }

  Widget _buildVenueList() {
    if (_loadingList) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_pendingVenues.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.stadium_outlined, size: 64, color: AppColors.disabled),
          const SizedBox(height: 12),
          Text('No pending venues',
              style: GoogleFonts.poppins(fontSize: 16, color: AppColors.textSecondary)),
        ]),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadVenues,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _pendingVenues.length,
        itemBuilder: (_, i) => _venueCard(_pendingVenues[i]),
      ),
    );
  }

  Widget _venueCard(Map<String, dynamic> v) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            backgroundColor: AppColors.accentLight,
            child: const Icon(Icons.stadium, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v['name'] ?? 'Venue',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15)),
              Text('Owner: ${v['owner_name'] ?? 'Unknown'}',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.location_on_outlined, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Expanded(child: Text('${v['city'] ?? ''} - ${v['address'] ?? ''}', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary))),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => _approveVenue(v['id']),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: Text('Approve Venue', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
    );
  }
}
