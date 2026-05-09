import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/api_constants.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});
  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tc;
  List<dynamic> _upcoming = [];
  List<dynamic> _past = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tc = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/bookings/my'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted && data['success'] == true) {
          final all = (data['data'] as List?) ?? [];
          final now = DateTime.now();
          setState(() {
            _upcoming = all.where((b) {
              final d = DateTime.tryParse(b['slot_date'] ?? '') ?? DateTime(2000);
              return d.isAfter(now.subtract(const Duration(days: 1))) &&
                (b['status'] == 'confirmed' || b['status'] == 'pending');
            }).toList();
            _past = all.where((b) {
              final d = DateTime.tryParse(b['slot_date'] ?? '') ?? DateTime(2000);
              return d.isBefore(now) || b['status'] == 'cancelled' || b['status'] == 'completed';
            }).toList();
            _loading = false;
          });
          return;
        }
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      debugPrint('Bookings load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Bookings',
          style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        bottom: TabBar(
          controller: _tc,
          indicatorColor: AppColors.accent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
          unselectedLabelStyle: GoogleFonts.poppins(fontSize: 13),
          tabs: const [Tab(text: 'Upcoming'), Tab(text: 'Past')],
        ),
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
        : RefreshIndicator(
            color: AppColors.accent,
            onRefresh: () async { setState(() => _loading = true); await _load(); },
            child: TabBarView(
              controller: _tc,
              children: [
                _buildList(_upcoming, isUpcoming: true),
                _buildList(_past, isUpcoming: false),
              ],
            ),
          ),
    );
  }

  Widget _buildList(List<dynamic> items, {required bool isUpcoming}) {
    if (items.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: AppColors.accentLight, borderRadius: BorderRadius.circular(18)),
            child: const Icon(Icons.calendar_today_outlined,
              size: 34, color: AppColors.accent),
          ),
          const SizedBox(height: 16),
          Text(isUpcoming ? 'No upcoming bookings' : 'No past bookings',
            style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600,
              color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Text(isUpcoming ? 'Book a venue and it will appear here' : 'Your completed bookings will show here',
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        ])),
      ]);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (_, i) => _bookingCard(items[i], isUpcoming: isUpcoming),
    );
  }

  Widget _bookingCard(Map<String, dynamic> b, {required bool isUpcoming}) {
    final status = (b['status'] ?? 'pending').toString();
    final statusColor = _statusColor(status);
    final date = _formatDate(b['slot_date']);
    final startTime = _fmtTime(b['start_time']);
    final endTime = _fmtTime(b['end_time']);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 10, offset: const Offset(0, 2),
        )],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF0A1F13), Color(0xFF14532D)],
              begin: Alignment.centerLeft, end: Alignment.centerRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(
              child: Text(b['venue_name'] ?? 'Venue',
                style: GoogleFonts.poppins(color: Colors.white,
                  fontWeight: FontWeight.bold, fontSize: 15),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: statusColor.withValues(alpha: 0.4)),
              ),
              child: Text(status.toUpperCase(),
                style: GoogleFonts.poppins(color: statusColor,
                  fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            ),
          ]),
        ),
        // Details
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            _detailRow(Icons.calendar_today_outlined, 'Date', date),
            const SizedBox(height: 8),
            _detailRow(Icons.access_time_outlined, 'Time', '$startTime – $endTime'),
            const SizedBox(height: 8),
            _detailRow(Icons.location_on_outlined, 'Location', b['city'] ?? b['address'] ?? 'N/A'),
            if (b['total_amount'] != null) ...[
              const SizedBox(height: 8),
              _detailRow(Icons.payments_outlined, 'Amount',
                'PKR ${_formatAmount(b['total_amount'])}'),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) => Row(children: [
    Icon(icon, size: 16, color: AppColors.textSecondary),
    const SizedBox(width: 8),
    Text('$label: ', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
    Expanded(child: Text(value,
      style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500,
        color: AppColors.textPrimary),
      maxLines: 1, overflow: TextOverflow.ellipsis)),
  ]);

  Color _statusColor(String s) {
    switch (s) {
      case 'confirmed': return const Color(0xFF22C55E);
      case 'pending': return const Color(0xFFF59E0B);
      case 'cancelled': return AppColors.error;
      case 'completed': return const Color(0xFF3B82F6);
      default: return AppColors.textSecondary;
    }
  }

  String _formatDate(String? d) {
    if (d == null) return '—';
    final dt = DateTime.tryParse(d);
    if (dt == null) return d;
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${m[dt.month - 1]} ${dt.year}';
  }

  String _fmtTime(dynamic t) {
    if (t == null) return '—';
    final s = t.toString();
    return s.length >= 5 ? s.substring(0, 5) : s;
  }

  String _formatAmount(dynamic a) {
    if (a == null) return '0';
    if (a is num) return a.toStringAsFixed(0);
    return a.toString();
  }
}
