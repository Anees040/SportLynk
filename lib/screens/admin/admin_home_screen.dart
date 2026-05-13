import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import 'admin_registration_detail_screen.dart';

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
  bool _loadingStats = true;
  bool _loadingList = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(() {
      if (!_tab.indexIsChanging) {
        final statuses = ['pending', 'approved', 'rejected'];
        if (_tab.index > 0) {
          _loadList(statuses[_tab.index - 1]);
        }
      }
    });
    _loadStats();
    _loadList('pending');
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

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }


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
            Tab(text: 'PENDING'),
            Tab(text: 'APPROVED'),
            Tab(text: 'REJECTED'),
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
        ],
      ),
    );
  }

  // ── DASHBOARD TAB ────────────────────────────────────────────
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
          _quickAction(Icons.refresh_rounded, 'Refresh Stats', 'Pull latest data',
              () async {
            await _loadStats();
            await _loadList('pending');
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

  // ── REGISTRATIONS LIST TAB ─────────────────────────────────
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
}
