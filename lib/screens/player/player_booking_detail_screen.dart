import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';

class PlayerBookingDetailScreen extends StatefulWidget {
  final String bookingId;
  const PlayerBookingDetailScreen({super.key, required this.bookingId});
  @override
  State<PlayerBookingDetailScreen> createState() => _PlayerBookingDetailScreenState();
}

class _PlayerBookingDetailScreenState extends State<PlayerBookingDetailScreen> {
  Map<String, dynamic>? _booking;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/bookings/${widget.bookingId}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        setState(() {
          _booking = data['data'];
          _loading = false;
        });
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancelBooking() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Cancel Booking?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        content: Text(
          'Cancellations within 12 hours of slot time forfeit your deposit. Early cancellations get a full refund.',
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Keep Booking', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Cancel Booking', style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/bookings/${widget.bookingId}/cancel'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(data['message'] ?? 'Cancelled', style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: data['success'] == true ? AppColors.accent : AppColors.error,
          behavior: SnackBarBehavior.floating,
        ));
        if (data['success'] == true) Navigator.pop(context);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(backgroundColor: AppColors.primary, iconTheme: const IconThemeData(color: Colors.white)),
        body: const Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }

    if (_booking == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(backgroundColor: AppColors.primary, iconTheme: const IconThemeData(color: Colors.white)),
        body: Center(child: Text('Booking not found', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
      );
    }

    final status = (_booking!['status'] as String?) ?? '';
    final qrCode = _booking!['qr_code'] as String?;
    final isConfirmed = status == 'confirmed';
    final isCheckedIn = status == 'checked_in';
    final isPending = status == 'pending';
    final canCancel = isPending || isConfirmed;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Booking Details', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          if (canCancel)
            TextButton(
              onPressed: _cancelBooking,
              child: Text('Cancel', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            // ── STATUS BANNER ──────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _statusColor(status).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _statusColor(status).withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                Icon(_statusIcon(status), color: _statusColor(status), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      _statusTitle(status),
                      style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14, color: _statusColor(status)),
                    ),
                    Text(
                      _statusSub(status),
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            // ── QR CODE (confirmed/checked_in) ─────────────
            if ((isConfirmed || isCheckedIn) && qrCode != null) ...[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(children: [
                  Text(
                    isCheckedIn ? '✅ Checked In' : 'Show this QR to the venue owner',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      color: isCheckedIn ? AppColors.success : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ColorFiltered(
                    colorFilter: isCheckedIn
                        ? const ColorFilter.mode(Colors.grey, BlendMode.saturation)
                        : const ColorFilter.mode(Colors.transparent, BlendMode.saturation),
                    child: QrImageView(
                      data: qrCode,
                      version: QrVersions.auto,
                      size: 200,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!isCheckedIn)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(20)),
                      child: Text(
                        'Valid for your booking slot only',
                        style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 11),
                      ),
                    ),
                  if (isCheckedIn)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(20)),
                      child: Text(
                        'QR code used — enjoy your game! 🎮',
                        style: GoogleFonts.poppins(color: AppColors.success, fontSize: 11),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // ── PENDING STATE ──────────────────────────────
            if (isPending) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(children: [
                  Row(children: [
                    const Icon(Icons.hourglass_top, color: AppColors.warning, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Waiting for venue owner approval',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.warning),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'Your money is frozen and safe. It will be automatically approved within 2 hours or fully refunded if rejected.',
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // ── BOOKING DETAILS ────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Booking Details', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _detRow(Icons.stadium_outlined, 'Venue', _booking!['venue_name'] ?? '—'),
                _detRow(Icons.location_on_outlined, 'Location', _booking!['city'] ?? _booking!['address'] ?? '—'),
                _detRow(
                  Icons.calendar_today_outlined,
                  'Date',
                  _booking!['slot_date']?.toString().split('T').first ?? '—',
                ),
                _detRow(
                  Icons.access_time_outlined,
                  'Time',
                  '${(_booking!['start_time'] ?? '').toString().length >= 5 ? (_booking!['start_time']).toString().substring(0, 5) : '—'} – ${(_booking!['end_time'] ?? '').toString().length >= 5 ? (_booking!['end_time']).toString().substring(0, 5) : '—'}',
                ),
                const Divider(color: AppColors.border),
                _detRow(
                  Icons.currency_rupee,
                  'Amount Paid (Deposit)',
                  'PKR ${_parseNum(_booking!['security_deposit'], _parseNum(_booking!['total_amount'], 0)).toStringAsFixed(0)}',
                  valueColor: AppColors.accent,
                ),
              ]),
            ),

            const SizedBox(height: 32),
          ]),
        ),
      ),
    );
  }

  Widget _detRow(IconData icon, String label, String value, {Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(label, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: valueColor ?? AppColors.textPrimary),
                ),
              ),
            ]),
          ),
        ]),
      );

  double _parseNum(dynamic val, [double fallback = 0]) {
    if (val == null) return fallback;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? fallback;
  }

  Color _statusColor(String s) => switch (s) {
        'confirmed' => AppColors.accent,
        'checked_in' => AppColors.success,
        'pending' => AppColors.warning,
        'cancelled' => AppColors.error,
        'no_show' => AppColors.error,
        _ => AppColors.textSecondary,
      };

  IconData _statusIcon(String s) => switch (s) {
        'confirmed' => Icons.check_circle_outline,
        'checked_in' => Icons.verified,
        'pending' => Icons.hourglass_top,
        'cancelled' => Icons.cancel_outlined,
        'no_show' => Icons.person_off_outlined,
        _ => Icons.info_outline,
      };

  String _statusTitle(String s) => switch (s) {
        'confirmed' => 'Booking Confirmed',
        'checked_in' => 'Checked In — Enjoy!',
        'pending' => 'Pending Approval',
        'cancelled' => 'Booking Cancelled',
        'no_show' => 'Marked as No-Show',
        _ => s.toUpperCase(),
      };

  String _statusSub(String s) => switch (s) {
        'confirmed' => 'Show QR code to the venue owner on arrival',
        'checked_in' => 'Payment transferred to venue owner',
        'pending' => 'Owner will approve within 2 hours',
        'cancelled' => 'Refund has been added to your wallet',
        'no_show' => 'Deposit was forfeited',
        _ => '',
      };
}
