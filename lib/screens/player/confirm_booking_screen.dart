import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
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
  String _paymentType = 'upfront'; // 'upfront' or 'full'

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
    final upfrontPct = _parseDouble(widget.venue['upfront_percent'] ?? 30);
    final discountPct = _parseDouble(widget.venue['discount_percent'] ?? 0);
    final upfrontAmount = price * (upfrontPct / 100);
    final fullAmount = price * (1 - (discountPct / 100));
    final amountToPay = _paymentType == 'upfront' ? upfrontAmount : fullAmount;

    if (_walletBalance < amountToPay) {
      SnackbarUtil.showError(context, 'Insufficient wallet balance. Please top up your wallet.');
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
          'paymentType': _paymentType,
        }));
      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() => _loading = false);
        if (data['success'] == true) {
          _showSuccessScreen(data['data']);
        } else {
          SnackbarUtil.showError(context, data['message'] ?? 'Booking failed');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        SnackbarUtil.showError(context, 'Network error. Please try again.');
      }
    }
  }

  /// Navigate to a full success screen instead of a dialog to avoid render issues
  void _showSuccessScreen(Map<String, dynamic> booking) {
    final bookingId = (booking['id'] ?? booking['qr_code'] ?? 'UNKNOWN').toString();
    final manualCode = bookingId.length >= 6
        ? bookingId.substring(0, 6).toUpperCase()
        : bookingId.toUpperCase();

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _BookingSuccessScreen(
          bookingId: bookingId,
          manualCode: manualCode,
          venueName: widget.venue['name'] ?? '',
          date: _fmtDate(widget.selectedDate),
          time: '${_safeTime(widget.slot['start_time'])} – ${_safeTime(widget.slot['end_time'])}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final price = _parseDouble(widget.slot['price']);
    final upfrontPct = _parseDouble(widget.venue['upfront_percent'] ?? 30);
    final discountPct = _parseDouble(widget.venue['discount_percent'] ?? 0);
    final upfrontAmount = double.parse((price * (upfrontPct / 100)).toStringAsFixed(2));
    final fullAmount = double.parse((price * (1 - (discountPct / 100))).toStringAsFixed(2));
    final amountToPay = _paymentType == 'upfront' ? upfrontAmount : fullAmount;
    final remainingWallet = _walletBalance - amountToPay;

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
            onPressed: (_loading || remainingWallet < 0) ? null : _confirmBooking,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              disabledBackgroundColor: AppColors.disabled,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Text('Pay PKR ${amountToPay.toStringAsFixed(0)}',
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

          // ── PAYMENT OPTIONS ───────────────────────────────
          _section('Payment Options', [
            // Upfront option
            GestureDetector(
              onTap: () => setState(() => _paymentType = 'upfront'),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _paymentType == 'upfront' ? AppColors.accentLight : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _paymentType == 'upfront' ? AppColors.accent : AppColors.border),
                ),
                child: Row(children: [
                  Container(
                    margin: const EdgeInsets.only(right: 12),
                    width: 20, height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: _paymentType == 'upfront' ? AppColors.accent : AppColors.textSecondary, width: 2),
                    ),
                    child: _paymentType == 'upfront' ? Center(child: Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accent))) : null,
                  ),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Pay Upfront (${upfrontPct.toStringAsFixed(0)}%)', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14)),
                    Text('Pay remaining PKR ${(price - upfrontAmount).toStringAsFixed(0)} at venue', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
                  ])),
                  Text('PKR ${upfrontAmount.toStringAsFixed(0)}', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.accent)),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            // Full Advance option
            GestureDetector(
              onTap: () => setState(() => _paymentType = 'full'),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _paymentType == 'full' ? AppColors.accentLight : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _paymentType == 'full' ? AppColors.accent : AppColors.border),
                ),
                child: Row(children: [
                  Container(
                    margin: const EdgeInsets.only(right: 12),
                    width: 20, height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: _paymentType == 'full' ? AppColors.accent : AppColors.textSecondary, width: 2),
                    ),
                    child: _paymentType == 'full' ? Center(child: Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accent))) : null,
                  ),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Pay Full Advance', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14)),
                    if (discountPct > 0)
                      Text('Get ${discountPct.toStringAsFixed(0)}% OFF!', style: GoogleFonts.poppins(fontSize: 11, color: Colors.green, fontWeight: FontWeight.bold))
                    else
                      Text('Skip the payment at venue', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
                  ])),
                  Text('PKR ${fullAmount.toStringAsFixed(0)}', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.accent)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // ── PAYMENT METHOD ────────────────────────────────
          _section('Wallet Balance', [
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
            ]),
            if (_walletLoaded) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.inputFill,
                  borderRadius: BorderRadius.circular(10)),
                child: Column(children: [
                  Row(children: [
                    Expanded(child: Column(children: [
                      Text('PAYMENT', style: GoogleFonts.poppins(fontSize: 9,
                        color: AppColors.textSecondary, letterSpacing: 0.5)),
                      const SizedBox(height: 2),
                      Text('- PKR ${amountToPay.toStringAsFixed(0)}',
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



  String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month-1]}, ${d.year}';
  }
}

// ── BOOKING SUCCESS SCREEN ──────────────────────────────────
// Full-screen success page — shows reservation confirmed (pending owner approval)
// QR code is revealed in booking history AFTER owner approves the booking
class _BookingSuccessScreen extends StatelessWidget {
  final String bookingId;
  final String manualCode;
  final String venueName;
  final String date;
  final String time;

  const _BookingSuccessScreen({
    required this.bookingId,
    required this.manualCode,
    required this.venueName,
    required this.date,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                // Hourglass icon (pending, not check)
                Container(
                  width: 90, height: 90,
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.12),
                    shape: BoxShape.circle),
                  child: const Icon(Icons.lock_clock_rounded,
                    color: AppColors.warning, size: 52),
                ),
                const SizedBox(height: 24),
                Text('Slot Reserved!', style: GoogleFonts.poppins(
                  fontSize: 26, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                const SizedBox(height: 8),
                Text('Awaiting owner approval',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(fontSize: 14, color: AppColors.warning, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('Your slot is reserved and your payment is held safely in escrow.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
                const SizedBox(height: 32),

                // Booking summary card
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.border),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 16, offset: const Offset(0, 4))]),
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(10)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.hourglass_top, color: AppColors.warning, size: 16),
                        const SizedBox(width: 6),
                        Text('PENDING OWNER APPROVAL', style: GoogleFonts.poppins(
                          fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                      ]),
                    ),
                    const SizedBox(height: 20),
                    _infoRow(Icons.stadium_outlined, venueName),
                    const SizedBox(height: 8),
                    _infoRow(Icons.calendar_today_outlined, date),
                    const SizedBox(height: 8),
                    _infoRow(Icons.access_time_outlined, time),
                    const SizedBox(height: 16),
                    const Divider(color: AppColors.border),
                    const SizedBox(height: 12),
                    // Note about QR code
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.qr_code_2, color: AppColors.textSecondary, size: 20),
                      const SizedBox(width: 10),
                      Expanded(child: Text(
                        'Your QR check-in code will appear in Booking History once the owner approves your booking.',
                        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary))),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),
                // Escrow info
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    borderRadius: BorderRadius.circular(12)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.lock_outline, color: AppColors.accent, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      'Your deposit is frozen safely. If the owner rejects or doesn\'t approve within 2 hours, you get a full automatic refund.',
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.primary))),
                  ]),
                ),
                const SizedBox(height: 32),
                // View Bookings button
                SizedBox(width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pushNamedAndRemoveUntil('/player-home', (route) => false);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: Text('Back to Home', style: GoogleFonts.poppins(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  )),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pushNamedAndRemoveUntil('/player-home', (route) => false);
                    // Navigate to bookings tab — home screen will handle this via route
                  },
                  child: Text('View in Booking History →', style: GoogleFonts.poppins(
                    color: AppColors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) => Row(children: [
    Icon(icon, size: 16, color: AppColors.textSecondary),
    const SizedBox(width: 8),
    Expanded(child: Text(text, style: GoogleFonts.poppins(
      fontSize: 13, color: AppColors.textPrimary, fontWeight: FontWeight.w500))),
  ]);
}


