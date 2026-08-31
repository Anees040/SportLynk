import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../services/chat_service.dart';
import '../shared/chat_thread_screen.dart';
import 'rate_experience_screen.dart';

class PlayerBookingDetailScreen extends StatefulWidget {
  final String bookingId;
  const PlayerBookingDetailScreen({super.key, required this.bookingId});
  @override
  State<PlayerBookingDetailScreen> createState() => _PlayerBookingDetailScreenState();
}

class _PlayerBookingDetailScreenState extends State<PlayerBookingDetailScreen> {
  Map<String, dynamic>? _booking;
  bool _loading = true;

  /// The booking's chat room, or null when there is none.
  ///
  /// This is RESOLVED rather than inferred from the status. A room is created when the
  /// booking is confirmed, so a booking cancelled while still pending never had one,
  /// while a booking cancelled after confirmation still does — and that room is
  /// exactly where the cancellation notice was posted. Asking the server removes the
  /// guess: the button appears if and only if there is something behind it, and the
  /// tap opens the thread with the id already in hand.
  String? _chatChannelId;

  @override
  void initState() {
    super.initState();
    _load();
    _loadChat();
  }

  Future<void> _loadChat() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null || token.isEmpty) return;
    final id = await ChatService().channelForBooking(token, widget.bookingId);
    if (!mounted || id == null || id.isEmpty) return;
    setState(() => _chatChannelId = id);
  }

  /// The room is titled with the venue, not the booking: it is a conversation with a
  /// place, and the slot is already the line underneath.
  String get _chatTitle {
    final v = _booking?['venue_name']?.toString();
    return (v == null || v.isEmpty) ? 'Venue chat' : v;
  }

  /// The thread header's second line, from the fields already on this screen.
  String? get _chatContextLine {
    final b = _booking;
    if (b == null) return null;
    final date = b['slot_date']?.toString().split('T').first;
    final start = b['start_time']?.toString();
    final hhmm = (start != null && start.length >= 5) ? start.substring(0, 5) : null;
    final parts = [
      if (date != null && date.isNotEmpty) date,
      ?hhmm,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Future<void> _openChat() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen.booking(
          bookingId: widget.bookingId,
          title: _chatTitle,
          channelId: _chatChannelId,
          contextLine: _chatContextLine,
        ),
      ),
    );
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
          'Cancel at least 24 hours before slot time for a full refund. Within 24 hours '
          'you get 80% back and the 20% deposit goes to the venue.',
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
            
            // ── MESSAGE THE VENUE ─────────────────
            // Rendered only once the room is known to exist — see [_chatChannelId].
            // It sits above the QR on purpose: on the day of the slot this is what
            // you reach for, and it must not be below a 200px fold.
            if (_chatChannelId != null) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openChat,
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: Text(
                    'Message venue',
                    style: GoogleFonts.poppins(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: const BorderSide(color: AppColors.accent),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
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
                  'Amount Held in Escrow',
                  'PKR ${_parseNum(_booking!['security_deposit'], _parseNum(_booking!['total_amount'], 0)).toStringAsFixed(0)}',
                  valueColor: AppColors.accent,
                ),
              ]),
            ),

            // Once the player is checked in, the slot has been played — invite the
            // review. This is the entry point for the venue rating + the live
            // sentiment chip (M24).
            if (isCheckedIn) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.rate_review_outlined, color: AppColors.accent, size: 18),
                    const SizedBox(width: 8),
                    Text('How was it?', style: GoogleFonts.poppins(
                        fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.primary)),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    'Rate the venue and leave a comment — it helps other players and '
                    'builds the venue\'s reputation.',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.primary.withValues(alpha: 0.8)),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(context, MaterialPageRoute(
                          builder: (_) => RateExperienceScreen(
                            bookingId: widget.bookingId,
                            venueName: _booking!['venue_name']?.toString(),
                            canReviewVenue: true,
                            dateLabel: _booking!['slot_date']?.toString().split('T').first,
                          ),
                        ));
                      },
                      icon: const Icon(Icons.star_rounded, color: Colors.white, size: 18),
                      label: Text('Rate Your Experience', style: GoogleFonts.poppins(
                          fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ]),
              ),
            ],

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
        'rejected' => AppColors.error,
        'no_show' => AppColors.error,
        _ => AppColors.textSecondary,
      };

  IconData _statusIcon(String s) => switch (s) {
        'confirmed' => Icons.check_circle_outline,
        'checked_in' => Icons.verified,
        'pending' => Icons.hourglass_top,
        'cancelled' => Icons.cancel_outlined,
        'rejected' => Icons.block_outlined,
        'no_show' => Icons.person_off_outlined,
        _ => Icons.info_outline,
      };

  String _statusTitle(String s) => switch (s) {
        'confirmed' => 'Booking Confirmed',
        'checked_in' => 'Checked In — Enjoy!',
        'pending' => 'Pending Approval',
        'cancelled' => 'Booking Cancelled',
        'rejected' => 'Request Rejected',
        'no_show' => 'Marked as No-Show',
        _ => s.toUpperCase(),
      };

  String _statusSub(String s) => switch (s) {
        'confirmed' => 'Show QR code to the venue owner on arrival',
        'checked_in' => 'Payment transferred to venue owner',
        'pending' => 'Owner will approve within 2 hours',
        'cancelled' => 'Refund has been added to your wallet',
        'rejected' => 'Full amount refunded to your wallet',
        'no_show' => '20% deposit forfeited, 80% refunded',
        _ => '',
      };
}
