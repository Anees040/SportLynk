import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../utils/num_util.dart';
import '../../utils/snackbar_util.dart';

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});
  @override
  State<BookingsScreen> createState() => BookingsScreenState();
}

class BookingsScreenState extends State<BookingsScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  late TabController _tab;
  List<Map<String, dynamic>> _upcoming = [], _past = [];
  bool _loading = true;
  DateTime? _lastLoadTime;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tab.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshIfStale();
  }

  /// Called by parent (PlayerHomeScreen) when Bookings tab becomes active
  void refreshIfNeeded() => _refreshIfStale();

  void _refreshIfStale() {
    final now = DateTime.now();
    if (_lastLoadTime == null || now.difference(_lastLoadTime!).inSeconds > 5) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _lastLoadTime = DateTime.now();
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(Uri.parse('${ApiConstants.baseUrl}/bookings/my'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        final all = List<Map<String,dynamic>>.from(data['data']);
        final now = DateTime.now();
        setState(() {
          _upcoming = all.where((b) {
            final d = DateTime.tryParse(b['slot_date'] ?? '')?.toLocal();
            return d != null && !d.isBefore(DateTime(now.year, now.month, now.day))
              && ['confirmed','pending'].contains(b['status']);
          }).toList();
          _past = all.where((b) {
            final d = DateTime.tryParse(b['slot_date'] ?? '')?.toLocal();
            return d == null || d.isBefore(DateTime(now.year, now.month, now.day))
              || ['cancelled','rejected','no_show','checked_in','completed','refunded'].contains(b['status']);
          }).toList();
          _loading = false;
        });
      } else if (mounted) { setState(() => _loading = false); }
    } catch (_) { if (mounted) { setState(() => _loading = false); } }
  }

  Future<void> _cancel(String bookingId) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Cancel Booking?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      content: Text('You will receive a full refund to your wallet.',
        style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text('Keep', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),
          child: Text('Cancel Booking',
            style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600))),
      ],
    ));
    if (ok != true) return;
    if (!mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(Uri.parse('${ApiConstants.baseUrl}/bookings/$bookingId/cancel'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          SnackbarUtil.showSuccess(context, 'Booking cancelled. Refund added to wallet.');
          _load();
        } else {
          SnackbarUtil.showError(context, data['message'] ?? 'Failed');
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Bookings', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        bottom: TabBar(controller: _tab,
          indicatorColor: AppColors.accent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
          tabs: const [Tab(text: 'Upcoming'), Tab(text: 'Past')]),
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
        : TabBarView(controller: _tab, children: [
            _buildList(_upcoming, upcoming: true),
            _buildList(_past, upcoming: false),
          ]),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> items, {required bool upcoming}) {
    if (items.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.event_busy, size: 64, color: AppColors.disabled),
        const SizedBox(height: 12),
        Text(upcoming ? 'No upcoming bookings' : 'No past bookings',
          style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textSecondary)),
        if (upcoming) ...[
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => Navigator.pushNamed(context, '/find-venues'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
            child: Text('Find Venues', style: GoogleFonts.poppins(color: Colors.white))),
        ],
      ]));
    }
    return RefreshIndicator(color: AppColors.accent, onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (_, i) => _bookingCard(items[i], upcoming: upcoming),
      ));
  }

  String _fmtSlotDate(String isoStr) {
    final d = DateTime.tryParse(isoStr);
    if (d == null) return isoStr;
    return DateFormat('dd MMM, yyyy').format(d.toLocal());
  }

  String _safeTime(dynamic t) {
    if (t == null) return '—';
    final s = t.toString();
    if (s.length >= 5) return s.substring(0, 5);
    return s;
  }

  Widget _bookingCard(Map<String, dynamic> b, {required bool upcoming}) {
    final status = b['status'] as String;
    final statusColor = _statusColor(status);
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/booking-detail',
          arguments: {'bookingId': b['id']}),
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03),
          blurRadius: 6, offset: const Offset(0,2))]),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(b['venue_name'] ?? 'Venue',
              style: GoogleFonts.poppins(color: Colors.white,
                fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: statusColor.withValues(alpha: 0.5))),
              child: Text(status.toUpperCase(), style: GoogleFonts.poppins(
                color: statusColor, fontSize: 9, fontWeight: FontWeight.bold))),
          ]),
        ),
        // Body
        Padding(padding: const EdgeInsets.all(14), child: Column(children: [
          Row(children: [
            _infoItem(Icons.calendar_today_outlined,
              _fmtSlotDate(b['slot_date'] ?? '')),
            const SizedBox(width: 20),
            _infoItem(Icons.access_time_outlined,
              '${_safeTime(b['start_time'])} – ${_safeTime(b['end_time'])}'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _infoItem(Icons.location_on_outlined, b['city'] ?? ''),
            const SizedBox(width: 20),
            _infoItem(Icons.currency_rupee,
              'PKR ${asNum(b['total_amount']).toStringAsFixed(0)}'),
          ]),
          if (upcoming && status == 'confirmed') ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => _cancel(b['id']),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(vertical: 10)),
                child: Text('Cancel', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600, fontSize: 12)))),
            ]),
          ],
        ])),
      ]),
    ),
    );
  }

  Widget _infoItem(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 13, color: AppColors.textSecondary),
    const SizedBox(width: 4),
    Text(text, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
  ]);

  Color _statusColor(String s) => switch(s) {
    'confirmed' => AppColors.accent, 'pending' => AppColors.warning,
    'cancelled' => AppColors.error, 'checked_in' => AppColors.success,
    'rejected' => AppColors.error,
    'no_show' => AppColors.error, _ => AppColors.textSecondary,
  };
}
