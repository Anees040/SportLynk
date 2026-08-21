import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../utils/num_util.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/transaction_detail_sheet.dart';

class WalletHistoryScreen extends StatefulWidget {
  const WalletHistoryScreen({super.key});
  @override
  State<WalletHistoryScreen> createState() => _WalletHistoryScreenState();
}

class _WalletHistoryScreenState extends State<WalletHistoryScreen> {
  final _api = ApiClient();

  List<Map<String, dynamic>> _txns = [];
  bool _loading = true;
  String? _error;
  String _filter = 'all';
  static const _filters = [
    ('all', 'All'), ('topup', 'Top-ups'),
    ('booking_payment', 'Bookings'), ('refund', 'Refunds'),
  ];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) {
      setState(() { _loading = false; _error = 'Please log in again to see your history.'; });
      return;
    }
    // Via ApiClient so this screen gets the shared timeout and the friendly
    // error text. The old raw http.get had no timeout, and it swallowed every
    // failure into an empty list — a 401 or a dead server both showed
    // "No transactions found", which is a lie the user cannot act on.
    final res = await _api.get('/wallet/transactions', token: token, queryParams: {
      'limit': '50',
      if (_filter != 'all') 'type': _filter,
    });
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['success'] == true) {
        _txns = List<Map<String, dynamic>>.from(res['data'] ?? const []);
      } else {
        _txns = [];
        _error = (res['message'] ?? 'Could not load your transactions.').toString();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Transaction History', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(48),
          child: Container(color: AppColors.primary,
            child: SingleChildScrollView(scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(children: _filters.map((f) {
                final active = _filter == f.$1;
                return GestureDetector(
                  onTap: () { setState(() => _filter = f.$1); _load(); },
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? AppColors.accent : Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16)),
                    child: Text(f.$2, style: GoogleFonts.poppins(color: Colors.white,
                      fontSize: 12, fontWeight: active ? FontWeight.w600 : FontWeight.normal))),
                );
              }).toList())))),
      ),
      body: _loading
        ? const CustomLoader()
        : _txns.isEmpty
          ? Center(child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(_error == null ? Icons.receipt_long_outlined : Icons.cloud_off,
                  size: 64, color: _error == null ? AppColors.disabled : AppColors.error),
                const SizedBox(height: 12),
                Text(_error ?? 'No transactions found', textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textSecondary)),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(onPressed: _load,
                    icon: const Icon(Icons.refresh, size: 18, color: AppColors.accent),
                    label: Text('Try again', style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600, color: AppColors.accent))),
                ],
              ])))
          : RefreshIndicator(color: AppColors.accent, onRefresh: _load,
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: _txns.length,
                separatorBuilder: (_, index) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _txnCard(_txns[i]),
              )),
    );
  }

  /// One ledger row. Label, icon, credit-direction and the PKT timestamp all
  /// come from widgets/transaction_detail_sheet.dart — this screen used to keep
  /// its own copies, which were missing escrow_release / escrow_received and
  /// printed timestamps in UTC.
  Widget _txnCard(Map<String, dynamic> t) {
    final type = (t['type'] ?? '').toString();
    final amount = asNum(t['amount']);
    final isCredit = isCreditTxn(type);
    final isFrozen = type == 'booking_payment';

    final label = isFrozen ? 'Security Deposit' : txnLabel(type);
    final color = isFrozen ? Colors.orange : (isCredit ? AppColors.success : AppColors.error);
    final iconData = isFrozen ? Icons.lock_outline : txnIcon(type);

    return GestureDetector(
      onTap: () => TransactionDetailSheet.show(context, t),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border)),
        child: Row(children: [
          Container(width: 44, height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(iconData, color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 2),
            Text(t['counterparty_name'] ?? '',
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(fmtTxnDate(t['created_at'] as String?),
              style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(isFrozen ? 'Frozen ${amount.abs().toStringAsFixed(0)}' : '${isCredit ? '+' : ''}PKR ${amount.abs().toStringAsFixed(0)}',
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
                color: color)),
            if (t['reference_id'] != null)
              Text('#${(t['reference_id'] as String).replaceAll('TRX-','')}',
                style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary)),
            const Icon(Icons.chevron_right, size: 14, color: AppColors.textSecondary),
          ]),
        ]),
      ),
    );
  }
}
