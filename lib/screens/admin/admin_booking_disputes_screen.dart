import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_service.dart';

/// The admin queue for player booking disputes (migration 032).
///
/// Separate from the match-dispute desk: a booking dispute is one player against one
/// booking, resolved into a refund or a rejection. Upholding one refunds the player's
/// held escrow in full — the server does the money in a transaction (bookingDispute
/// Service.resolve); this screen only shows the queue and sends the verdict.
class AdminBookingDisputesScreen extends StatefulWidget {
  const AdminBookingDisputesScreen({super.key});

  @override
  State<AdminBookingDisputesScreen> createState() => _AdminBookingDisputesScreenState();
}

class _AdminBookingDisputesScreenState extends State<AdminBookingDisputesScreen> {
  final AdminService _service = AdminService();
  late final String _token;
  List<Map<String, dynamic>>? _rows;
  String? _error;
  String _status = 'open';
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _token = context.read<AuthProvider>().token ?? '';
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _rows = null;
      _error = null;
    });
    try {
      final rows = await _service.bookingDisputes(_token, status: _status);
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load disputes. Try again.');
    }
  }

  Future<void> _resolve(Map<String, dynamic> d, bool uphold) async {
    final id = d['id']?.toString() ?? '';
    if (id.isEmpty || _busy.contains(id)) return;
    final notes = await _confirm(d, uphold);
    if (notes == null || !mounted) return; // cancelled
    setState(() => _busy.add(id));
    final r = await _service.resolveBookingDispute(_token, id, uphold: uphold, notes: notes);
    if (!mounted) return;
    setState(() => _busy.remove(id));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r['message']?.toString() ?? (r['success'] == true ? 'Done.' : 'Failed.'),
          style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: r['success'] == true ? AppColors.accent : AppColors.error,
      behavior: SnackBarBehavior.floating,
    ));
    if (r['success'] == true) await _load();
  }

  /// Returns the notes string (possibly empty) on confirm, or null on cancel.
  Future<String?> _confirm(Map<String, dynamic> d, bool uphold) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(uphold ? 'Uphold & refund?' : 'Reject dispute?',
            style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              uphold
                  ? 'The player is refunded the amount still held in escrow for this booking, '
                      'and the booking is cancelled. This cannot be undone.'
                  : 'The dispute is closed with no refund. The player is told it was reviewed.',
              style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 2,
              maxLength: 1000,
              style: GoogleFonts.poppins(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Optional note (shown in the record)',
                hintStyle: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text('Back', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, ctrl.text.trim()),
            child: Text(uphold ? 'Uphold' : 'Reject',
                style: GoogleFonts.poppins(
                    color: uphold ? AppColors.accent : AppColors.error,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Booking Disputes',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          _filterRow(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _filterRow() {
    const options = ['open', 'upheld', 'rejected', 'all'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          for (final s in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(s[0].toUpperCase() + s.substring(1)),
                selected: _status == s,
                onSelected: (_) {
                  if (_status == s) return;
                  setState(() => _status = s);
                  _load();
                },
                selectedColor: AppColors.accent,
                labelStyle: GoogleFonts.poppins(
                  fontSize: 12.5,
                  color: _status == s ? Colors.white : AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return _centered(_error!, TextButton.icon(
        onPressed: _load,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Try again'),
      ));
    }
    final rows = _rows;
    if (rows == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          const SizedBox(height: 140),
          _centered(_status == 'open'
              ? 'No disputes are waiting on a ruling.'
              : 'Nothing to show here.', null),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _card(rows[i]),
      ),
    );
  }

  Widget _centered(String text, Widget? action) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.gavel_rounded, size: 40, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 13.5, color: AppColors.textPrimary)),
          if (action != null) ...[const SizedBox(height: 10), action],
        ]),
      ),
    );
  }

  Widget _card(Map<String, dynamic> d) {
    final id = d['id']?.toString() ?? '';
    final status = d['status']?.toString() ?? 'open';
    final isOpen = status == 'open';
    final sending = _busy.contains(id);
    final refund = d['refund_amount'];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${d['player_name'] ?? 'Player'} · ${d['venue_name'] ?? 'Venue'}',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
              _statusBadge(status),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (d['slot_date'] != null) d['slot_date'].toString().split('T').first,
              if (d['start_time'] != null) d['start_time'].toString(),
              if (d['booking_status'] != null) 'booking: ${d['booking_status']}',
            ].join('  ·  '),
            style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(d['reason']?.toString() ?? '',
              style: GoogleFonts.poppins(fontSize: 13, height: 1.35)),
          if (!isOpen && (d['resolution_notes']?.toString().isNotEmpty ?? false)) ...[
            const SizedBox(height: 6),
            Text('Note: ${d['resolution_notes']}',
                style: GoogleFonts.poppins(
                    fontSize: 12, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
          ],
          if (!isOpen && refund != null && (num.tryParse('$refund') ?? 0) > 0) ...[
            const SizedBox(height: 4),
            Text('Refunded PKR $refund',
                style: GoogleFonts.poppins(
                    fontSize: 12, color: AppColors.success, fontWeight: FontWeight.w600)),
          ],
          if (isOpen) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: sending ? null : () => _resolve(d, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text('Reject', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: sending ? null : () => _resolve(d, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: sending
                      ? const SizedBox(
                          width: 15, height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text('Uphold & refund',
                          style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _statusBadge(String status) {
    final color = status == 'upheld'
        ? AppColors.success
        : status == 'rejected'
            ? AppColors.error
            : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(status.toUpperCase(),
          style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
    );
  }
}