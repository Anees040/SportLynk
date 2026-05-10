import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../utils/snackbar_util.dart';

class ConfirmBookingScreen extends StatefulWidget {
  final Map<String, dynamic> venue;
  final Map<String, dynamic> slot;
  final DateTime selectedDate;
  const ConfirmBookingScreen({
    super.key,
    required this.venue,
    required this.slot,
    required this.selectedDate,
  });
  @override
  State<ConfirmBookingScreen> createState() => _ConfirmBookingScreenState();
}

class _ConfirmBookingScreenState extends State<ConfirmBookingScreen> {
  bool _loading = false;
  double _walletBalance = 0;
  bool _walletLoaded = false;

  @override
  void initState() { super.initState(); _loadWallet(); }

  Future<void> _loadWallet() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(Uri.parse('${ApiConstants.baseUrl}/wallet/me'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        setState(() {
          _walletBalance = _parseDouble(data['data']['balance']);
          _walletLoaded = true;
        });
      }
    } catch (_) {}
  }

  double _parseDouble(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }

  String _safeTime(dynamic t) {
    if (t == null) return '—';
    final s = t.toString();
    if (s.length >= 5) return s.substring(0, 5);
    return s;
  }

  Future<void> _confirmBooking() async {
    final price = _parseDouble(widget.slot['price']);
    final deposit = double.parse((price * 0.30).toStringAsFixed(2));
    if (_walletBalance < deposit) {
      _snack('Insufficient wallet balance. Please top up your wallet.', AppColors.error);
      return;
    }
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(Uri.parse('${ApiConstants.baseUrl}/bookings'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'slotId': widget.slot['id'],
          'venueId': widget.venue['id'],
        }));
      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() => _loading = false);
        if (data['success'] == true) {
          _showSuccessDialog(data['data']);
        } else {
          _snack(data['message'] ?? 'Booking failed', AppColors.error);
        }
      }
    } catch (e) {
      if (mounted) { setState(() => _loading = false); _snack('Error: $e', AppColors.error); }
    }
  }

  void _showSuccessDialog(Map<String, dynamic> booking) {
    final bookingId = booking['id'] as String? ?? 'UNKNOWN';
    final manualCode = bookingId.length >= 6 ? bookingId.substring(0, 6).toUpperCase() : bookingId.toUpperCase();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Text('Booking Confirmed!', textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold,
              color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Text('Show this QR code at the venue.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 16),
          // QR Code
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border)),
            child: QrImageView(
              data: bookingId,
              version: QrVersions.auto,
              size: 140.0,
            ),
          ),
          const SizedBox(height: 12),
          Text('Manual Entry Code:', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
          Text(manualCode, style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 2)),
          const SizedBox(height: 20),
          Container(padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.inputFill,
              borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              _confirmRow('Venue', widget.venue['name'] ?? ''),
              _confirmRow('Date', _fmtDate(widget.selectedDate)),
              _confirmRow('Time',
                '${_safeTime(widget.slot['start_time'])} – '
                '${_safeTime(widget.slot['end_time'])}'),
            ])),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop();
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text('Done', style: GoogleFonts.poppins(
                color: Colors.white, fontWeight: FontWeight.w600)),
            )),
        ]),
      ),
    );
  }

  void _snack(String msg, Color c) {
    if (c == AppColors.error) {
      SnackbarUtil.showError(context, msg);
    } else {
      SnackbarUtil.showSuccess(context, msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = _parseDouble(widget.slot['price']);
    final deposit = double.parse((price * 0.30).toStringAsFixed(2));
    final payAtVenue = price - deposit;
    final remainingWallet = _walletBalance - deposit;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Confirm Booking', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        decoration: const BoxDecoration(color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))]),
        child: SafeArea(top: false,
          child: ElevatedButton(
            onPressed: _loading ? null : _confirmBooking,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Text('Pay Deposit PKR ${deposit.toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 15)),
          )),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── BOOKING SUMMARY ──────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border)),
            child: Row(children: [
              Container(width: 72, height: 72,
                decoration: BoxDecoration(color: AppColors.primary,
                  borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.stadium_outlined, color: Colors.white38, size: 36)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.venue['name'] ?? '', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold, fontSize: 15),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.calendar_today_outlined, size: 13,
                    color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text(_fmtDate(widget.selectedDate), style: GoogleFonts.poppins(
                    fontSize: 12, color: AppColors.textSecondary)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  const Icon(Icons.access_time_outlined, size: 13,
                    color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text('${_safeTime(widget.slot['start_time'])} – '
                    '${_safeTime(widget.slot['end_time'])}',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ])),
            ]),
          ),
          const SizedBox(height: 16),

          // ── PAYMENT BREAKDOWN ─────────────────────────────
          _section('Payment Breakdown', [
            _row('Base Price', 'PKR ${price.toStringAsFixed(0)}'),
            _row('Security Deposit', 'PKR ${deposit.toStringAsFixed(0)}',
              sub: 'REFUNDABLE', subColor: AppColors.accent),
            const Divider(color: AppColors.border),
            _row('Total Amount', 'PKR ${price.toStringAsFixed(0)}',
              bold: true, valueColor: AppColors.accent),
          ]),
          const SizedBox(height: 16),

          // ── PAYMENT METHOD ────────────────────────────────
          _section('Payment Method', [
            Row(children: [
              Container(width: 42, height: 42,
                decoration: BoxDecoration(color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.account_balance_wallet,
                  color: AppColors.accent, size: 22)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('SportLynk Wallet', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600, fontSize: 13)),
                Text('Available: PKR ${_walletBalance.toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
              ])),
              const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
            ]),
            if (_walletLoaded) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.inputFill,
                  borderRadius: BorderRadius.circular(10)),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Total Slot Price', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                    Text('PKR ${price.toStringAsFixed(0)}', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Pay at Venue (70%)', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                    Text('PKR ${payAtVenue.toStringAsFixed(0)}', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.bold)),
                  ]),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider(height: 1)),
                  Row(children: [
                    Expanded(child: Column(children: [
                      Text('ADVANCE (30%)', style: GoogleFonts.poppins(fontSize: 9,
                        color: AppColors.textSecondary, letterSpacing: 0.5)),
                      const SizedBox(height: 2),
                      Text('- PKR ${deposit.toStringAsFixed(0)}',
                        style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
                          color: AppColors.error)),
                    ])),
                    Container(width: 1, height: 32, color: AppColors.border),
                    Expanded(child: Column(children: [
                      Text('WALLET AFTER', style: GoogleFonts.poppins(fontSize: 9,
                        color: AppColors.textSecondary, letterSpacing: 0.5)),
                      const SizedBox(height: 2),
                      Text('PKR ${remainingWallet.toStringAsFixed(0)}',
                        style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
                          color: remainingWallet >= 0 ? AppColors.success : AppColors.error)),
                    ])),
                  ]),
                ]),
              ),
              if (remainingWallet < 0) ...[
                const SizedBox(height: 8),
                Container(padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_outlined, color: AppColors.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Insufficient balance. Top up your wallet to proceed.',
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.error))),
                  ])),
              ],
            ],
          ]),
          const SizedBox(height: 20),

          // ── CANCELLATION POLICY ───────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.4))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, color: AppColors.warning, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(
                'Cancel at least 2 hours before your slot for a full refund. '
                'No-shows may affect your trust score.',
                style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFF92400E)))),
            ]),
          ),
          const SizedBox(height: 100),
        ]),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: GoogleFonts.poppins(
        fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
      const SizedBox(height: 10),
      ...children,
    ]),
  );

  Widget _row(String label, String value,
    {String? sub, Color? subColor, bool bold = false, Color? valueColor}) =>
    Padding(padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Text(label, style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
          if (sub != null) ...[
            const SizedBox(width: 6),
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: (subColor ?? AppColors.accent).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4)),
              child: Text(sub, style: GoogleFonts.poppins(fontSize: 9,
                color: subColor ?? AppColors.accent, fontWeight: FontWeight.bold))),
          ],
        ]),
        Text(value, style: GoogleFonts.poppins(fontSize: 13,
          fontWeight: bold ? FontWeight.bold : FontWeight.w500,
          color: valueColor ?? AppColors.textPrimary)),
      ]));

  Widget _confirmRow(String l, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(l, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
      Text(v, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600,
        color: AppColors.textPrimary)),
    ]));

  String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month-1]}, ${d.year}';
  }
}
