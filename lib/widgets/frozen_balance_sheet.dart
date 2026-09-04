import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../services/api_service.dart';
import '../utils/num_util.dart';
import 'transaction_detail_sheet.dart' show fmtSlotDate, fmtSlotTime;

/// FR7.2 — "where exactly is my frozen money?"
///
/// The wallet card shows a single FROZEN figure, which is the most-asked-about
/// number in the app: players see PKR 4,800 they cannot spend and have no way to
/// find out why. This sheet lists one row per booking currently holding escrow.
///
/// The breakdown is computed by `GET /api/wallet/frozen`, not by filtering
/// bookings client-side, so the server can also return `delta` — the gap between
/// the per-booking sum and `wallets.frozen_balance`. A non-zero delta means rows
/// escrowed under the old 30% deposit rule. Showing it beats a
/// breakdown that quietly disagrees with the headline number.
class FrozenBalanceSheet extends StatefulWidget {
  final String token;
  const FrozenBalanceSheet({super.key, required this.token});

  static Future<void> show(BuildContext context, String token) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => FrozenBalanceSheet(token: token),
    );
  }

  @override
  State<FrozenBalanceSheet> createState() => _FrozenBalanceSheetState();
}

class _FrozenBalanceSheetState extends State<FrozenBalanceSheet> {
  final _api = ApiClient();

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = [];
  double _itemsTotal = 0;
  double _walletFrozen = 0;
  double _delta = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await _api.get('/wallet/frozen', token: widget.token);
    if (!mounted) return;
    if (res['success'] != true) {
      setState(() {
        _loading = false;
        _error = (res['message'] ?? 'Could not load your escrow breakdown.').toString();
      });
      return;
    }
    final d = res['data'] as Map<String, dynamic>;
    setState(() {
      _items = List<Map<String, dynamic>>.from(d['items'] ?? const []);
      _itemsTotal = asNum(d['itemsTotal']);
      _walletFrozen = asNum(d['walletFrozen']);
      _delta = asNum(d['delta']);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 18, color: AppColors.warning),
                const SizedBox(width: 8),
                Text(
                  'Frozen in Escrow',
                  style: GoogleFonts.poppins(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                if (!_loading && _error == null)
                  Text(
                    'PKR ${_walletFrozen.toStringAsFixed(0)}',
                    style: GoogleFonts.poppins(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: AppColors.warning,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Money held for your active bookings. It is released when you '
              'check in — or refunded if the booking is cancelled or rejected.',
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.accent),
                ),
              )
            else if (_error != null)
              _message(Icons.error_outline, _error!, AppColors.error, retry: true)
            else if (_items.isEmpty)
              _message(
                Icons.check_circle_outline,
                _walletFrozen > 0
                    ? 'No active bookings are holding escrow, but PKR '
                          '${_walletFrozen.toStringAsFixed(0)} is still marked frozen. '
                          'Pull to refresh your wallet, or contact support if it stays.'
                    : 'Nothing is frozen right now — your whole balance is available to spend.',
                _walletFrozen > 0 ? AppColors.warning : AppColors.success,
              )
            else ...[
              // Bounded so a player with 20 bookings still gets a usable sheet.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.42,
                ),
                child: SingleChildScrollView(
                  child: Column(children: _items.map(_bookingRow).toList()),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(color: AppColors.border, height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Text(
                      '${_items.length} booking${_items.length == 1 ? '' : 's'}',
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'PKR ${_itemsTotal.toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              // Only appears when the itemised rows do not add up to the wallet's
              // own figure. Now that rows itemise security_deposit — the amount
              // in escrow — this means genuine drift: frozen money no
              // active booking accounts for. Backend fix:
              // node src/scripts/reconcile_wallets.js --apply
              if (_delta.abs() >= 0.01) ...[
                const SizedBox(height: 12),
                _message(
                  Icons.info_outline,
                  'PKR ${_delta.abs().toStringAsFixed(0)} of your frozen balance '
                      '${_delta > 0 ? 'is not linked to any active booking' : 'is less than your bookings are holding'}. '
                      'Contact support so it can be released — no money has been lost.',
                  AppColors.warning,
                ),
              ],
            ],
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _bookingRow(Map<String, dynamic> b) {
    final status = (b['status'] ?? '').toString();
    final pending = status == 'pending';
    final start = fmtSlotTime(b['start_time']);
    final end = fmtSlotTime(b['end_time']);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (b['venue_name'] ?? 'Venue').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${fmtSlotDate(b['slot_date']?.toString())}'
                  '${start.isEmpty ? '' : ' • $start'}'
                  '${end.isEmpty ? '' : ' – $end'}',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'PKR ${asNum(b['escrow_held']).toStringAsFixed(0)}',
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              // A booking made before the deposit rules changed froze only part of
              // the slot price. Show the price too, struck through, so the row
              // explains itself instead of looking like the wrong number.
              if ((asNum(b['slot_price']) - asNum(b['escrow_held'])).abs() >= 0.01)
                Text(
                  'of PKR ${asNum(b['slot_price']).toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(
                    fontSize: 10.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (pending ? AppColors.warning : AppColors.success)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  pending ? 'AWAITING OWNER' : 'CONFIRMED',
                  style: GoogleFonts.poppins(
                    fontSize: 8.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                    color: pending ? AppColors.warning : AppColors.success,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _message(IconData icon, String text, Color color, {bool retry = false}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: AppColors.textPrimary,
                height: 1.4,
              ),
            ),
          ),
          if (retry)
            TextButton(
              onPressed: _load,
              child: Text(
                'Retry',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
