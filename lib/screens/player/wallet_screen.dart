import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../utils/num_util.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/frozen_balance_sheet.dart';
import '../../widgets/transaction_detail_sheet.dart';
import '../../widgets/withdraw_sheet.dart';
import 'wallet_history_screen.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _txns = [];
  bool _loading = true;
  static const _amounts = [500.0, 1000.0, 2000.0, 5000.0];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final walletResp = await http.get(Uri.parse('${ApiConstants.baseUrl}/wallet/me'),
        headers: {'Authorization': 'Bearer $token'});
      final txnResp = await http.get(Uri.parse('${ApiConstants.baseUrl}/wallet/transactions?limit=5'),
        headers: {'Authorization': 'Bearer $token'});
      if (mounted) {
        final wData = jsonDecode(walletResp.body);
        final tData = jsonDecode(txnResp.body);
        setState(() {
          _wallet = wData['success'] == true ? wData['data'] : null;
          _txns = tData['success'] == true
            ? List<Map<String,dynamic>>.from(tData['data']) : [];
          _loading = false;
        });
      }
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _topUp(double amount) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token!;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PaymentSimulationDialog(),
    );
    await Future.delayed(const Duration(seconds: 3));

    try {
      final resp = await http.post(Uri.parse('${ApiConstants.baseUrl}/wallet/topup'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'amount': amount}));
      final data = jsonDecode(resp.body);
      if (mounted) {
        Navigator.pop(context); // close simulation dialog
        if (data['success'] == true) {
          SnackbarUtil.showSuccess(context, 'PKR ${amount.toStringAsFixed(0)} added to wallet!');
          _load();
        } else {
          SnackbarUtil.showError(context, data['message'] ?? 'Top-up failed');
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        SnackbarUtil.showError(context, 'Error: $e');
      }
    }
  }

  void _showTopUpSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _TopUpSheet(amounts: _amounts, onTopUp: (amt) {
        Navigator.pop(context);
        _topUp(amt);
      }));
  }

  // ── FR7.4 / ER1.6 — withdraw ───────────────────────────────
  // Replaces the "available after launch" stub. The sheet decides for itself
  // whether to show the request form or the pending withdrawal, because that
  // depends on server state this screen does not load.
  Future<void> _showWithdrawSheet() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) return;
    final changed = await WithdrawSheet.show(
      context,
      token: token,
      available: asNum(_wallet?['balance']),
    );
    if (changed && mounted) _load();
  }

  // ── FR7.2 — itemised escrow breakdown ──────────────────────
  void _showFrozenSheet() {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) return;
    FrozenBalanceSheet.show(context, token);
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
        automaticallyImplyLeading: false,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.help_outline, color: Colors.white70),
            onPressed: () => _snack(
              'Wallet balance is used to book venues. Top up via the button below.',
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
                      // Tappable: FR7.2's breakdown. A bare number here is the
                      // single most-asked-about figure in the app.
                      Expanded(child: InkWell(
                        onTap: _showFrozenSheet,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
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
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right,
                              color: Colors.white38, size: 13),
                          ]),
                          const SizedBox(height: 4),
                          Text('PKR ${asNum(_wallet?['frozen_balance']).toStringAsFixed(0)}',
                            style: GoogleFonts.poppins(color: Colors.white70,
                              fontSize: 16, fontWeight: FontWeight.bold)),
                        ])),
                      )),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),

                // ── ACTIONS ────────────────────────────────
                Row(children: [
                  Expanded(child: ElevatedButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: Text('Top Up Wallet', style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600, fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                      padding: const EdgeInsets.symmetric(vertical: 13)),
                    onPressed: _showTopUpSheet,
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: OutlinedButton.icon(
                    icon: const Icon(Icons.north_east, size: 18),
                    label: Text('Withdraw', style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600, fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      side: const BorderSide(color: AppColors.accent),
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

  Widget _txnTile(Map<String, dynamic> t) {
    final type = t['type'] as String;
    final amount = asNum(t['amount']);
    final isCredit = isCreditTxn(type);
    final isFrozen = isHeldTxn(type);

    final icon = isFrozen ? Icons.lock_outline : txnIcon(type);
    final color = isFrozen ? Colors.orange : (isCredit ? AppColors.success : AppColors.error);
    final label = txnRowLabel(type);

    // FR7.9 — tap for the full receipt. No extra request: GET
    // /wallet/transactions already returns every field the sheet shows.
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

// ── TOP UP SHEET ─────────────────────────────────────────────

class _TopUpSheet extends StatefulWidget {
  final List<double> amounts;
  final void Function(double) onTopUp;
  const _TopUpSheet({required this.amounts, required this.onTopUp});
  @override
  State<_TopUpSheet> createState() => _TopUpSheetState();
}

class _TopUpSheetState extends State<_TopUpSheet> {
  double? _selected;
  final _customCtrl = TextEditingController();

  @override
  void dispose() { _customCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20,
        20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4,
          decoration: BoxDecoration(color: AppColors.border,
            borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Text('Top Up Wallet', style: GoogleFonts.poppins(
          fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        const SizedBox(height: 6),
        Text('Select amount or enter custom amount',
          style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 16),
        // Quick amounts
        GridView.count(crossAxisCount: 2, shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 3.0,
          children: widget.amounts.map((amt) {
            final sel = _selected == amt;
            return GestureDetector(
              onTap: () => setState(() { _selected = amt; _customCtrl.clear(); }),
              child: Container(
                decoration: BoxDecoration(
                  color: sel ? AppColors.accent : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: sel ? AppColors.accent : AppColors.border,
                    width: sel ? 2 : 1)),
                child: Center(child: Text('PKR ${amt.toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(
                    color: sel ? Colors.white : AppColors.textPrimary,
                    fontWeight: FontWeight.w600, fontSize: 14))),
              ),
            );
          }).toList()),
        const SizedBox(height: 12),
        // Custom amount
        TextField(
          controller: _customCtrl,
          keyboardType: TextInputType.number,
          onChanged: (v) => setState(() => _selected = null),
          style: GoogleFonts.poppins(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Or enter custom amount (PKR 100 – 50,000)',
            hintStyle: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
            prefixText: 'PKR ',
            prefixStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14),
            filled: true, fillColor: AppColors.inputFill,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: () {
              double? amt = _selected;
              if (amt == null && _customCtrl.text.isNotEmpty) {
                amt = double.tryParse(_customCtrl.text);
              }
              if (amt == null || amt < 100 || amt > 50000) {
                SnackbarUtil.showError(context, 'Enter amount between PKR 100 and 50,000');
                return;
              }
              widget.onTopUp(amt);
            },
            child: Text('Add to Wallet', style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
          )),
        const SizedBox(height: 8),
      ]),
    );
  }
}

class _PaymentSimulationDialog extends StatefulWidget {
  const _PaymentSimulationDialog();
  @override
  State<_PaymentSimulationDialog> createState() => _PaymentSimulationDialogState();
}

class _PaymentSimulationDialogState extends State<_PaymentSimulationDialog> {
  String _status = 'Initializing secure gateway...';

  @override
  void initState() {
    super.initState();
    _simulate();
  }

  Future<void> _simulate() async {
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) setState(() => _status = 'Verifying bank details...');
    await Future.delayed(const Duration(milliseconds: 1000));
    if (mounted) setState(() => _status = 'Processing payment...');
    await Future.delayed(const Duration(milliseconds: 1000));
    if (mounted) setState(() => _status = 'Payment successful!');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.accent),
            const SizedBox(height: 20),
            Text(
              _status,
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
