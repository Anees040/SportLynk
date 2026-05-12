import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../utils/snackbar_util.dart';
import '../player/wallet_history_screen.dart';

class OwnerWalletScreen extends StatefulWidget {
  const OwnerWalletScreen({super.key});
  @override
  State<OwnerWalletScreen> createState() => _OwnerWalletScreenState();
}

class _OwnerWalletScreenState extends State<OwnerWalletScreen> {
  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _txns = [];
  bool _loading = true;

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

  double _parseDouble(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
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
                    Text('PKR ${_parseDouble(_wallet?['balance']).toStringAsFixed(0)}',
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
                          Text('PKR ${_parseDouble(_wallet?['balance']).toStringAsFixed(0)}',
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
                          Text('PKR ${_parseDouble(_wallet?['frozen_balance']).toStringAsFixed(0)}',
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
                    onPressed: () => _snack(
                      'Withdrawals will be available after launch.', AppColors.primary),
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
    final amount = _parseDouble(t['amount']);
    final isCredit = ['topup', 'refund', 'escrow_received'].contains(type);
    final isFrozen = type == 'booking_payment';

    final icon = isFrozen ? Icons.lock_outline : _txnIcon(type);
    final color = isFrozen ? Colors.orange : (isCredit ? AppColors.success : AppColors.error);
    final label = isFrozen ? 'Security Deposit' : _txnLabel(type);
    
    return Container(
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
          Text(_fmtDate(t['created_at']),
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Text(isFrozen ? 'Frozen ${amount.abs().toStringAsFixed(0)}' : '${isCredit ? '+' : ''}PKR ${amount.abs().toStringAsFixed(0)}',
          style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
            color: color)),
      ]),
    );
  }

  IconData _txnIcon(String t) => switch (t) {
    'topup' => Icons.south_west,
    'booking_payment' => Icons.north_east,
    'security_deposit' => Icons.lock_outline,
    'refund' => Icons.replay,
    'no_show_penalty' => Icons.cancel_outlined,
    _ => Icons.swap_horiz,
  };


  String _txnLabel(String t) => switch (t) {
    'topup' => 'Wallet Top-up',
    'booking_payment' => 'Booking Payment',
    'security_deposit' => 'Security Deposit',
    'refund' => 'Booking Refund',
    'no_show_penalty' => 'No-Show Penalty',
    'owner_payout' => 'Owner Payout',
    'withdrawal' => 'Withdrawal',
    _ => 'Transaction',
  };

  String _fmtDate(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour.toString().padLeft(2,'0');
    final min = dt.minute.toString().padLeft(2,'0');
    return '${dt.day} ${m[dt.month-1]}, ${dt.year} • $h:$min';
  }
}

