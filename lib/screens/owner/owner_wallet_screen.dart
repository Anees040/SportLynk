import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../utils/num_util.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/transaction_detail_sheet.dart';
import '../../widgets/withdraw_sheet.dart';
import '../player/wallet_history_screen.dart';

class OwnerWalletScreen extends StatefulWidget {
  const OwnerWalletScreen({super.key});
  @override
  State<OwnerWalletScreen> createState() => _OwnerWalletScreenState();
}

class _OwnerWalletScreenState extends State<OwnerWalletScreen> {
  final _api = ApiClient();

  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _txns = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) {
      setState(() { _loading = false; _error = 'Please log in again to see your wallet.'; });
      return;
    }
    // Both calls at once instead of one after the other, and through ApiClient
    // so a hung request times out. The old version caught every failure and
    // left `_wallet` null, which renders as "PKR 0" — an owner seeing zero
    // after a network hiccup has no way to tell that from actually losing money.
    final results = await Future.wait([
      _api.get('/wallet/me', token: token),
      _api.get('/wallet/transactions', token: token, queryParams: {'limit': '5'}),
    ]);
    if (!mounted) return;
    final wRes = results[0];
    final tRes = results[1];
    setState(() {
      _loading = false;
      if (wRes['success'] == true) {
        _wallet = wRes['data'] as Map<String, dynamic>?;
      } else {
        _wallet = null;
        _error = (wRes['message'] ?? 'Could not load your wallet.').toString();
      }
      _txns = tRes['success'] == true
        ? List<Map<String, dynamic>>.from(tRes['data'] ?? const [])
        : [];
    });
  }

  /// Owners are the ones who actually accumulate money — the escrow moves 100%
  /// of the booking to them at check-in — so the withdraw button here matters
  /// more than the player one. The endpoint and the sheet are role-agnostic, so
  /// this is the same flow, not a second implementation.
  Future<void> _showWithdrawSheet() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) return;
    final changed = await WithdrawSheet.show(context, token: token,
      available: asNum(_wallet?['balance']));
    if (changed && mounted) _load();
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Wallet', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: true,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.help_outline, color: Colors.white70),
            onPressed: () => _snack(
              'Earnings land here when a player checks in. Frozen means a booking '
              'is still active. Withdraw available funds with the button below.',
              AppColors.primary)),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
        : RefreshIndicator(color: AppColors.accent, onRefresh: _load,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                // A failed load must never look like a zero balance.
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.error.withValues(alpha: 0.25))),
                    child: Row(children: [
                      const Icon(Icons.cloud_off, size: 17, color: AppColors.error),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_error!, style: GoogleFonts.poppins(
                        fontSize: 12, color: AppColors.textPrimary, height: 1.4))),
                      TextButton(onPressed: _load, child: Text('Retry',
                        style: GoogleFonts.poppins(fontSize: 12,
                          fontWeight: FontWeight.w600, color: AppColors.accent))),
                    ])),
                  const SizedBox(height: 12),
                ],
                // ── BALANCE CARD ───────────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                      begin: Alignment.topLeft, end: Alignment.bottomRight),
                    borderRadius: BorderRadius.circular(20)),
                  child: Column(children: [
                    Text('TOTAL BALANCE', style: GoogleFonts.poppins(
                      color: Colors.white60, fontSize: 11, letterSpacing: 1)),
                    const SizedBox(height: 6),
                    Text('PKR ${asNum(_wallet?['balance']).toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(color: Colors.white,
                        fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 20),
                    Row(children: [
                      Expanded(child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12)),
                        child: Column(children: [
                          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Icon(Icons.account_balance_wallet,
                              color: AppColors.accent, size: 16),
                            const SizedBox(width: 6),
                            Text('AVAILABLE FUNDS', style: GoogleFonts.poppins(
                              color: Colors.white60, fontSize: 9, letterSpacing: 0.5)),
                          ]),
                          const SizedBox(height: 4),
                          Text('PKR ${asNum(_wallet?['balance']).toStringAsFixed(0)}',
                            style: GoogleFonts.poppins(color: AppColors.accent,
                              fontSize: 16, fontWeight: FontWeight.bold)),
                        ])),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12)),
                        child: Column(children: [
                          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Icon(Icons.lock_outline,
                              color: Colors.white60, size: 14),
                            const SizedBox(width: 6),
                            Text('FROZEN', style: GoogleFonts.poppins(
                              color: Colors.white60, fontSize: 9, letterSpacing: 0.5)),
                          ]),
                          const SizedBox(height: 4),
                          Text('PKR ${asNum(_wallet?['frozen_balance']).toStringAsFixed(0)}',
                            style: GoogleFonts.poppins(color: Colors.white70,
                              fontSize: 16, fontWeight: FontWeight.bold)),
                        ])),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),

                // ── ACTIONS ────────────────────────────────
                Row(children: [
                  Expanded(child: ElevatedButton.icon(
                    icon: const Icon(Icons.north_east, size: 18),
                    label: Text('Withdraw Funds', style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600, fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                      padding: const EdgeInsets.symmetric(vertical: 13)),
                    onPressed: _showWithdrawSheet,
                  )),
                ]),
                const SizedBox(height: 24),

                // ── RECENT TRANSACTIONS ────────────────────
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Recent Transactions', style: GoogleFonts.poppins(
                    fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => const WalletHistoryScreen())),
                    child: Text('View All', style: GoogleFonts.poppins(
                      fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600))),
                ]),
                const SizedBox(height: 8),
                _txns.isEmpty
                  ? Container(height: 80,
                      decoration: BoxDecoration(color: AppColors.inputFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border)),
                      child: Center(child: Text('No transactions yet',
                        style: GoogleFonts.poppins(
                          fontSize: 13, color: AppColors.textSecondary))))
                  : Column(children: _txns.map(_txnTile).toList()),
                const SizedBox(height: 24),
              ]),
            )),
    );
  }

  /// One ledger row. Label, icon, credit-direction and the PKT timestamp come
  /// from widgets/transaction_detail_sheet.dart. The private copies this screen
  /// used to hold had no `escrow_received` case — which is the single most
  /// common row in an *owner's* ledger, since that is how a check-in pays them.
  /// It rendered as a bare "Transaction" with a generic arrow.
  Widget _txnTile(Map<String, dynamic> t) {
    final type = (t['type'] ?? '').toString();
    final amount = asNum(t['amount']);
    final isCredit = isCreditTxn(type);
    final isFrozen = type == 'booking_payment';

    final icon = isFrozen ? Icons.lock_outline : txnIcon(type);
    final color = isFrozen ? Colors.orange : (isCredit ? AppColors.success : AppColors.error);
    final label = isFrozen ? 'Security Deposit' : txnLabel(type);

    return InkWell(
      onTap: () => TransactionDetailSheet.show(context, t),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border)),
        child: Row(children: [
          Container(width: 42, height: 42,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.textPrimary)),
            Text(fmtTxnDate(t['created_at'] as String?),
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
          ])),
          Text(isFrozen ? 'Frozen ${amount.abs().toStringAsFixed(0)}' : '${isCredit ? '+' : ''}PKR ${amount.abs().toStringAsFixed(0)}',
            style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
              color: color)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 16, color: AppColors.textSecondary),
        ]),
      ),
    );
  }
}


