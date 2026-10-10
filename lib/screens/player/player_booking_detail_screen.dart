import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../providers/data_sync_provider.dart';
import '../../services/chat_service.dart';
import '../../utils/cancellation_message.dart';
import '../../widgets/network_error_view.dart';
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

  /// The failure sentence for a load that could not reach the server or was
  /// refused.
  ///
  /// Distinguished from a genuine absence on purpose. Before this existed, every
  /// failure left [_booking] null and the screen rendered "Booking not found" — so
  /// a dropped connection told the player a booking they are looking at from their
  /// own list does not exist. "Not found" is now reserved for a server that
  /// answered and had no such booking; anything else is an error with a retry.
  String? _error;

  /// The booking's chat room, or null when there is none.
  ///
  /// This is resolved rather than inferred from the status. A room is created when the
  /// booking is confirmed, so a booking cancelled while still pending never had one,
  /// while a booking cancelled after confirmation still does — and that room is
  /// exactly where the cancellation notice was posted. Asking the server removes the
  /// guess: the button appears if and only if there is something behind it, and the
  /// tap opens the thread with the id already in hand.
  String? _chatChannelId;

  /// The sibling bookings when this one is part of a multi-slot group, newest
  /// slot last. Null (or length 1) means a single booking, which renders exactly
  /// as before. A group renders as one booking — all its slots, one QR, one
  /// cancel — because that is how the player made it.
  List<Map<String, dynamic>>? _group;

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
    if (mounted) setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/bookings/${widget.bookingId}'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (data['success'] == true) {
        setState(() {
          _booking = data['data'] is Map
              ? Map<String, dynamic>.from(data['data'] as Map)
              : null;
          _error = null;
          _loading = false;
        });
        context.read<ConnectivityProvider>().markReachable();
        // If this booking was made as part of a multi-slot group, pull its
        // siblings so the screen can show the whole run as one booking.
        final gid = _booking?['booking_group_id']?.toString();
        if (gid != null && gid.isNotEmpty && gid != 'null') _loadGroup(gid);
      } else {
        // The server answered and declined. Its message carries the real reason —
        // a genuine "not found", or a permission error — rather than the blanket
        // absence the screen used to show for every failure.
        setState(() {
          _loading = false;
          _error = data['message'] as String? ?? 'Could not load this booking.';
        });
      }
    } catch (_) {
      // Nothing came back. This is the case that used to read as "Booking not
      // found"; it is a connection failure, and it says so with a way to retry.
      if (!mounted) return;
      context.read<ConnectivityProvider>().markUnreachable();
      setState(() {
        _loading = false;
        _error = 'Could not reach the server. Check your connection and try again.';
      });
    }
  }

  /// Load the sibling bookings of a multi-slot group.
  ///
  /// A failed fetch leaves the single-booking view untouched — the booking the
  /// screen already holds is still correct — so it is not surfaced as an error.
  /// Only a genuine group (more than one row) switches the screen into group mode.
  Future<void> _loadGroup(String groupId) async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null || token.isEmpty) return;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/bookings/group/$groupId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (data['success'] == true && data['data'] is List) {
        final rows = (data['data'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (rows.length > 1) setState(() => _group = rows);
      }
    } catch (_) {
      // Group view is an enhancement; the single booking still shows.
    }
  }

  bool get _isGroup => (_group?.length ?? 0) > 1;
  int get _groupCount => _group?.length ?? 1;
  String? get _groupId => _booking?['booking_group_id']?.toString();

  /// The escrow held across the whole group — the sum of the rows, which is what
  /// the player paid, not any one slot's share.
  double get _groupEscrowTotal => (_group ?? const <Map<String, dynamic>>[]).fold<double>(
        0,
        (s, b) => s + _parseNum(b['security_deposit'], _parseNum(b['total_amount'], 0)),
      );

  String _hhmm(dynamic t) {
    final s = (t ?? '').toString();
    return s.length >= 5 ? s.substring(0, 5) : s;
  }

  /// The group's playing window: the first slot's start to the last slot's end.
  /// The server returns the rows in slot order, so first and last are the ends.
  String get _groupTimeRange {
    final g = _group;
    if (g == null || g.isEmpty) return '';
    return '${_hhmm(g.first['start_time'])} – ${_hhmm(g.last['end_time'])}';
  }

  Future<void> _cancelBooking() async {
    final group = _isGroup;
    final count = _groupCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(group ? 'Cancel all $count slots?' : 'Cancel Booking?',
            style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        content: Text(
          group
              ? 'All $count slots in this booking will be cancelled together. Each slot '
                  'is refunded by its own window — at least 24 hours before the slot is a '
                  'full refund; within 24 hours the venue keeps that slot\'s 20% deposit.'
              : 'Cancel at least 24 hours before slot time for a full refund. Within 24 hours '
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
            child: Text(group ? 'Cancel all' : 'Cancel Booking',
                style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      // One atomic request for the whole group, so the player can never be left with
      // a half-cancelled booking; the single endpoint for a lone booking.
      final uri = (group && _groupId != null)
          ? Uri.parse('${ApiConstants.baseUrl}/bookings/group/$_groupId/cancel')
          : Uri.parse('${ApiConstants.baseUrl}/bookings/${widget.bookingId}/cancel');
      final resp = await http.patch(uri, headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted) {
        final ok = data['success'] == true;
        // The unified cancellation line: refund, the venue's deduction if the
        // cancellation was late, and the resulting wallet balance — the same wording
        // the Bookings list uses, so the two never disagree.
        final text = ok
            ? cancellationMessage(
                data['data'] is Map ? data['data'] as Map : const {},
                count: group ? count : 1)
            : (data['message']?.toString() ?? 'Could not cancel. Try again.');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(text, style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: ok ? AppColors.accent : AppColors.error,
          behavior: SnackBarBehavior.floating,
        ));
        if (ok) {
          // Announce so the Home dashboard, the Bookings list and the Wallet all
          // re-read as the user returns to them.
          context.read<DataSyncProvider>().bookingsChanged();
          Navigator.pop(context);
        }
      }
    } catch (_) {
      // Previously an empty catch: a cancellation that failed told the player
      // nothing, and the booking stayed where it was. The failure is surfaced.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not cancel. Check your connection and try again.',
              style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<void> _reportProblem() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReportProblemDialog(),
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/bookings/${widget.bookingId}/dispute'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'reason': reason.trim()}),
      );
      final data = jsonDecode(resp.body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          data['message']?.toString() ?? 'Could not submit. Try again.',
          style: GoogleFonts.poppins(color: Colors.white),
        ),
        backgroundColor: data['success'] == true ? AppColors.accent : AppColors.error,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not submit the report. Check your connection.',
              style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
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
        // An error with a retry when the load failed; the bare "not found" only
        // when the server actually answered with no such booking (no [_error]).
        body: _error != null
            ? NetworkErrorView(message: _error!, onRetry: _load)
            : Center(child: Text('Booking not found', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
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
          IconButton(
            tooltip: 'Report a problem',
            icon: const Icon(Icons.report_problem_outlined, color: Colors.white, size: 20),
            onPressed: _reportProblem,
          ),
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
            // STATUS banner
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
            
            // Message the VENUE
            // Rendered only once the room is known to exist — see [_chatChannelId].
            // It sits above the QR on purpose: on the day of the slot this is what
            // the player reaches for, and it must not be below a 200px fold.
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

            // QR code (confirmed/checked_in)
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
                        // One scan settles the whole group, so this QR covers every
                        // slot in the booking — the owner scans it once at the gate.
                        _isGroup
                            ? 'One scan checks in all $_groupCount slots'
                            : 'Valid for your booking slot only',
                        style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 11),
                        textAlign: TextAlign.center,
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

            // Pending state
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

            // BOOKING details
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
                  // A group shows the whole run (first start to last end); a single
                  // booking shows its own slot.
                  _isGroup
                      ? _groupTimeRange
                      : '${(_booking!['start_time'] ?? '').toString().length >= 5 ? (_booking!['start_time']).toString().substring(0, 5) : '—'} – ${(_booking!['end_time'] ?? '').toString().length >= 5 ? (_booking!['end_time']).toString().substring(0, 5) : '—'}',
                ),
                if (_isGroup)
                  _detRow(Icons.layers_outlined, 'Slots',
                      '$_groupCount consecutive slots'),
                const Divider(color: AppColors.border),
                _detRow(
                  Icons.payments_outlined,
                  'Amount Held in Escrow',
                  // The group total — what the player actually paid — not one slot's
                  // share.
                  'PKR ${(_isGroup ? _groupEscrowTotal : _parseNum(_booking!['security_deposit'], _parseNum(_booking!['total_amount'], 0))).toStringAsFixed(0)}',
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

/// The reason prompt for reporting a problem with a booking.
///
/// A dedicated StatefulWidget so its TextEditingController is disposed with the dialog
/// rather than by the caller the instant the route begins animating out — the pattern
/// the rest of the app settled on after a controller-used-after-dispose crash.
class _ReportProblemDialog extends StatefulWidget {
  const _ReportProblemDialog();

  @override
  State<_ReportProblemDialog> createState() => _ReportProblemDialogState();
}

class _ReportProblemDialogState extends State<_ReportProblemDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Report a problem', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tell us what went wrong. An admin reviews it, and if the dispute is upheld '
            'your payment is refunded to your wallet.',
            style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            maxLines: 3,
            maxLength: 1000,
            style: GoogleFonts.poppins(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'e.g. the slot was double-booked, or the ground was closed',
              hintStyle: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.inputFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.border),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Back', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text('Submit',
              style: GoogleFonts.poppins(color: AppColors.accent, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
