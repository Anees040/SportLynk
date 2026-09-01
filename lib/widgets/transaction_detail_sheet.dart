import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../utils/num_util.dart';

// Shared transaction vocabulary
//
// The label / icon / credit maps below used to exist three times over, in
// wallet_screen, wallet_history_screen and owner_wallet_screen — and all three
// copies were missing `escrow_release` and `escrow_received`, so a late
// cancellation or an owner receiving a deposit rendered as a bare
// "Transaction" with a generic arrow. One copy, all twelve types.
//
// The twelve types are exactly the `txn_type` enum: seven from schema.sql:120,
// escrow_release / escrow_received added by migration 007, and the three
// tournament types added by migration 019 (tournament_entry,
// tournament_commission, tournament_prize).

/// Human label for a `transactions.type` value.
String txnLabel(String type) => switch (type) {
  'topup' => 'Wallet Top-up',
  'booking_payment' => 'Booking Payment',
  'security_deposit' => 'Security Deposit',
  'refund' => 'Refund',
  'no_show_penalty' => 'No-Show Penalty',
  'owner_payout' => 'Owner Payout',
  'withdrawal' => 'Withdrawal',
  'escrow_release' => 'Escrow Released',
  'escrow_received' => 'Escrow Received',
  'tournament_entry' => 'Tournament Entry',
  'tournament_commission' => 'Tournament Earnings',
  'tournament_prize' => 'Prize Money',
  _ => 'Transaction',
};

/// Icon for a `transactions.type` value. Arrows follow the money: south-west
/// arrives, north-east leaves.
IconData txnIcon(String type) => switch (type) {
  'topup' => Icons.south_west,
  'booking_payment' => Icons.north_east,
  'security_deposit' => Icons.lock_outline,
  'refund' => Icons.replay,
  'no_show_penalty' => Icons.cancel_outlined,
  'owner_payout' => Icons.account_balance,
  'withdrawal' => Icons.north_east,
  'escrow_release' => Icons.lock_open_outlined,
  'escrow_received' => Icons.south_west,
  'tournament_entry' => Icons.confirmation_number_outlined,
  'tournament_commission' => Icons.storefront_outlined,
  'tournament_prize' => Icons.emoji_events_outlined,
  _ => Icons.swap_horiz,
};

/// True when this type puts money *into* the wallet.
///
/// Matches the backend's signs exactly: `refund`, `escrow_received`,
/// `tournament_commission` and `tournament_prize` are always logged positive,
/// everything else negative (see routes/bookings.js, jobs/noShowJob.js and
/// services/tournamentService.js).
///
/// `tournament_prize` is positive in both of the places it is written — into the
/// organiser's *frozen* balance when the bracket is drawn, and into the champion's
/// and runner-up's spendable balance when the final settles. The row's own
/// `description` says which, so this sheet prints that rather than guessing.
bool isCreditTxn(String type) =>
    type == 'topup' ||
    type == 'refund' ||
    type == 'escrow_received' ||
    type == 'tournament_commission' ||
    type == 'tournament_prize';

/// True when this type parks money in the frozen bucket instead of spending it,
/// so its row is coloured orange and worded "held" rather than "money out".
///
/// Both members are logged negative (`balance −X, frozen +X`): a booking's
/// security deposit, released at check-in, and a tournament entry fee, released
/// into the prize pool when the bracket is drawn.
bool isHeldTxn(String type) =>
    type == 'booking_payment' || type == 'tournament_entry';

/// The label a ledger row shows.
///
/// `booking_payment` is the one type the app renames — the ledger calls it a
/// payment, the user is told it is a deposit. A tournament entry keeps its own
/// name, because calling an entry fee a security deposit would be a lie.
String txnRowLabel(String type) =>
    type == 'booking_payment' ? 'Security Deposit' : txnLabel(type);

/// Format a backend timestamp for display, in the phone's local time.
///
/// The backend stores plain UTC (`NOW()` on a UTC server) and node-postgres
/// serialises it with a `Z`, so `DateTime.parse` yields a UTC instant.
/// `.toLocal()` is what turns it into PKT — without it these screens showed
/// times five hours behind, which is the "store UTC, convert in Flutter" rule
/// being half-applied.
String fmtTxnDate(String? iso, {bool withTime = true}) {
  if (iso == null) return '—';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '—';
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final date = '${dt.day} ${m[dt.month - 1]}, ${dt.year}';
  if (!withTime) return date;
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$date • $h:$min';
}

/// Format a `slot_date` (a date-only column) without pretending to know a time.
String fmtSlotDate(String? iso) => fmtTxnDate(iso, withTime: false);

/// Trim a `TIME` column ("18:00:00") down to "18:00".
String fmtSlotTime(dynamic t) {
  if (t == null) return '';
  final s = t.toString();
  return s.length >= 5 ? s.substring(0, 5) : s;
}

// FR7.9 — transaction detail

/// The receipt for one ledger row.
///
/// Needs no new endpoint: `GET /api/wallet/transactions` already selects `t.*`
/// joined to `venue_name` / `slot_date` / `start_time` / `end_time`, and
/// `reference_id` is generated as `TRX-xxxxxxxx` by the schema default. Every
/// field below is optional, so this renders correctly for a top-up (no booking)
/// and for a booking payment alike.
class TransactionDetailSheet extends StatelessWidget {
  final Map<String, dynamic> txn;
  const TransactionDetailSheet({super.key, required this.txn});

  static Future<void> show(BuildContext context, Map<String, dynamic> txn) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => TransactionDetailSheet(txn: txn),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = (txn['type'] ?? '').toString();
    final amount = asNum(txn['amount']);
    final credit = isCreditTxn(type);
    // booking_payment is money moved into escrow, not spent — the wallet screens
    // colour it orange and call it a deposit, so this sheet must agree.
    // A tournament entry fee is the same ledger shape (`balance −E, frozen +E`),
    // so it gets the same orange "held" treatment — but not the same words: an
    // entry fee is released into the pool when the bracket is drawn, and nobody
    // checks in for it.
    final frozen = isHeldTxn(type);
    final title = txnRowLabel(type);
    final accent = frozen
        ? AppColors.warning
        : (credit ? AppColors.success : AppColors.error);

    final venue = txn['venue_name'] as String?;
    final slotDate = txn['slot_date'] as String?;
    final start = fmtSlotTime(txn['start_time']);
    final end = fmtSlotTime(txn['end_time']);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
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
            const SizedBox(height: 20),

            // Headline: icon, label, signed amount.
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    frozen ? Icons.lock_outline : txnIcon(type),
                    color: accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        frozen
                            ? 'Held in escrow'
                            : (credit ? 'Money in' : 'Money out'),
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${credit ? '+' : '−'}PKR ${amount.abs().toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: AppColors.border, height: 1),

            _row('Reference', txn['reference_id']?.toString()),
            _row('Date & time', fmtTxnDate(txn['created_at']?.toString())),
            if (txn['description'] != null)
              _row('Details', txn['description'].toString()),
            if (txn['counterparty_name'] != null)
              _row('Counterparty', txn['counterparty_name'].toString()),
            if (venue != null) _row('Venue', venue),
            if (slotDate != null)
              _row(
                'Slot',
                start.isEmpty
                    ? fmtSlotDate(slotDate)
                    : '${fmtSlotDate(slotDate)}, $start${end.isEmpty ? '' : ' – $end'}',
              ),
            if (txn['balance_after'] != null)
              _row(
                'Balance after',
                'PKR ${asNum(txn['balance_after']).toStringAsFixed(0)}',
              ),

            const SizedBox(height: 8),
            // Escrow is the one thing users ask about, so say it here rather
            // than making them find the help icon.
            if (type == 'booking_payment')
              _note(
                'This amount is held in escrow, not spent. It is released when '
                'you check in at the venue.',
              ),
            if (type == 'tournament_entry')
              _note(
                'This entry fee is held, not spent. You get it back in full if '
                'you withdraw before the registration deadline, if the organiser '
                'turns your team down, or if the tournament is called off. Once '
                'the bracket is drawn it goes into the prize pool.',
              ),
            if (type == 'tournament_commission')
              _note(
                'This covers the venue hours your fixtures reserved, plus your '
                'margin on top. The prize money is held separately until the '
                'final is settled.',
              ),
            if (type == 'withdrawal')
              _note(
                'The amount left your available balance when you requested the '
                'withdrawal. Payout completes within 24 hours.',
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 11),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value == null || value.isEmpty ? '—' : value,
            textAlign: TextAlign.end,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _note(String text) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.inputFill,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 15, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}
