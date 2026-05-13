import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';

class OwnerBookingRequestsScreen extends StatefulWidget {
  const OwnerBookingRequestsScreen({super.key});
  @override
  State<OwnerBookingRequestsScreen> createState() => _OwnerBookingRequestsScreenState();
}

class _OwnerBookingRequestsScreenState extends State<OwnerBookingRequestsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  final _tabs = ['pending', 'confirmed', 'rejected'];
  final _lists = <String, List<Map<String, dynamic>>>{
    'pending': [],
    'confirmed': [],
    'rejected': [],
  };
  bool _loading = true;
  static String get _base => ApiConstants.baseUrl;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _loadAll();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    if (mounted) setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      for (final status in _tabs) {
        final resp = await http.get(
          Uri.parse('$_base/owner/bookings?status=$status'),
          headers: {'Authorization': 'Bearer $token'},
        );
        final data = jsonDecode(resp.body);
        if (mounted && data['success'] == true) {
          _lists[status] = List<Map<String, dynamic>>.from(data['data']);
        }
      }
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _approve(String bookingId) async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(
        Uri.parse('$_base/owner/bookings/$bookingId/approve'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          _snack('Booking approved! Player notified.', AppColors.accent);
          _loadAll();
        } else {
          _snack(data['message'] ?? 'Failed', AppColors.error);
        }
      }
    } catch (_) {
      if (mounted) _snack('Network error', AppColors.error);
    }
  }

  Future<void> _reject(String bookingId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Reject Booking?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        content: Text(
          'The player will receive a full refund to their wallet.',
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Reject', style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(
        Uri.parse('$_base/owner/bookings/$bookingId/reject'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          _snack('Booking rejected. Player refunded.', AppColors.warning);
          _loadAll();
        } else {
          _snack(data['message'] ?? 'Failed', AppColors.error);
        }
      }
    } catch (_) {
      if (mounted) _snack('Network error', AppColors.error);
    }
  }

  void _snack(String msg, Color c) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: c,
          behavior: SnackBarBehavior.floating,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.primary,
        elevation: 0,
        title: Text(
          'Booking Requests',
          style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: AppColors.accent,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
          unselectedLabelStyle: GoogleFonts.poppins(fontSize: 13),
          tabs: [
            Tab(text: 'Pending (${_lists['pending']?.length ?? 0})'),
            const Tab(text: 'Confirmed'),
            const Tab(text: 'Rejected'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : TabBarView(
              controller: _tab,
              children: [
                _buildList('pending'),
                _buildList('confirmed'),
                _buildList('rejected'),
              ],
            ),
    );
  }

  Widget _buildList(String status) {
    final items = _lists[status] ?? [];
    if (items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            status == 'pending' ? Icons.inbox_outlined : Icons.event_busy_outlined,
            size: 64,
            color: AppColors.disabled,
          ),
          const SizedBox(height: 12),
          Text(
            'No $status bookings',
            style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textSecondary),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadAll,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (_, i) => _bookingCard(items[i], status),
      ),
    );
  }

  Widget _bookingCard(Map<String, dynamic> b, String status) {
    final trust = (b['trust_score'] as num?)?.toInt() ?? 100;
    final isPending = status == 'pending';
    final isConfirmed = status == 'confirmed';
    final trustLabel = trust >= 80 ? 'HIGH TRUST' : trust >= 50 ? 'NEW USER' : 'LOW TRUST';
    final trustColor = trust >= 80 ? AppColors.accent : trust >= 50 ? AppColors.warning : AppColors.error;
    final sports = (b['sport_preferences'] as List?)?.take(2).join(', ') ?? 'Football';
    final name = b['player_name'] ?? 'Player';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(children: [
        // ── HEADER ────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: AppColors.accentLight,
              child: Text(
                name[0].toUpperCase(),
                style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.accent),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14)),
                Row(children: [
                  const Icon(Icons.sports_soccer_outlined, size: 12, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      sports,
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: trustColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: trustColor.withValues(alpha: 0.3)),
              ),
              child: Text(
                trustLabel,
                style: GoogleFonts.poppins(color: trustColor, fontSize: 9, fontWeight: FontWeight.bold),
              ),
            ),
          ]),
        ),

        // ── AUTO-APPROVE NOTICE (pending only) ─────────────
        if (isPending)
          Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              const Icon(Icons.timer_outlined, color: AppColors.warning, size: 14),
              const SizedBox(width: 6),
              Text(
                'Auto-approves in 2 hours',
                style: GoogleFonts.poppins(fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.w500),
              ),
            ]),
          ),

        // ── BOOKING DETAILS ────────────────────────────────
        Container(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.inputFill, borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              const Icon(Icons.calendar_today_outlined, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _fmtDate(b['slot_date']),
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                Text(
                  '${(b['start_time'] ?? '').toString().length >= 5 ? b['start_time'].toString().substring(0, 5) : ''} – ${(b['end_time'] ?? '').toString().length >= 5 ? b['end_time'].toString().substring(0, 5) : ''}',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                ),
              ]),
            ]),
            Text(
              'PKR ${_parseNum(b['total_amount']).toStringAsFixed(0)}',
              style: GoogleFonts.poppins(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ]),
        ),

        // ── ACTIONS ────────────────────────────────────────
        if (isPending)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _reject(b['id']),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text('Reject', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _approve(b['id']),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    'Approve',
                    style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ),
            ]),
          ),

        if (isConfirmed)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: Text(
                  'Scan QR to Check In',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => Navigator.pushNamed(context, '/owner-scan-qr'),
              ),
            ),
          ),
      ]),
    );
  }

  String _fmtDate(dynamic d) {
    if (d == null) return '';
    final dt = DateTime.tryParse(d.toString());
    if (dt == null) return d.toString();
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) return 'Today';
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dt.day} ${m[dt.month - 1]}';
  }

  double _parseNum(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }
}
