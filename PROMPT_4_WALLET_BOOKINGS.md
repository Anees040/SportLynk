# PROMPT 4 — Wallet Screen + Wallet History + My Bookings Screen
# Run AFTER Prompt 3. Real Dart code only.

---

## FILE 1: lib/screens/player/wallet_screen.dart  (REPLACE stub)

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../providers/auth_provider.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _txns = [];
  bool _loading = true;
  static const _base = 'http://10.0.2.2:3000/api';
  static const _amounts = [500.0, 1000.0, 2000.0, 5000.0];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final walletResp = await http.get(Uri.parse('$_base/wallet/me'),
        headers: {'Authorization': 'Bearer $token'});
      final txnResp = await http.get(Uri.parse('$_base/wallet/transactions?limit=5'),
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
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(Uri.parse('$_base/wallet/topup'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'amount': amount}));
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          _snack('PKR ${amount.toStringAsFixed(0)} added to wallet!', AppColors.accent);
          _load();
        } else {
          _snack(data['message'] ?? 'Top-up failed', AppColors.error);
        }
      }
    } catch (e) { _snack('Error: $e', AppColors.error); }
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

  void _snack(String msg, Color c) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: c, behavior: SnackBarBehavior.floating));

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
                    Text('PKR ${(_wallet?['balance'] ?? 0).toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(color: Colors.white,
                        fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 20),
                    Row(children: [
                      Expanded(child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
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
                          Text('PKR ${(_wallet?['balance'] ?? 0).toStringAsFixed(0)}',
                            style: GoogleFonts.poppins(color: AppColors.accent,
                              fontSize: 16, fontWeight: FontWeight.bold)),
                        ])),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
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
                          Text('PKR ${(_wallet?['frozen_balance'] ?? 0).toStringAsFixed(0)}',
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
    final amount = (t['amount'] as num).toDouble();
    final isCredit = ['topup', 'refund'].contains(type);
    final icon = _txnIcon(type);
    final color = _txnColor(type);
    final label = _txnLabel(type);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border)),
      child: Row(children: [
        Container(width: 42, height: 42,
          decoration: BoxDecoration(color: color.withOpacity(0.12),
            shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.poppins(
            fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.textPrimary)),
          Text(_fmtDate(t['created_at']),
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Text('${isCredit ? '+' : '-'}PKR ${amount.abs().toStringAsFixed(0)}',
          style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
            color: isCredit ? AppColors.success : AppColors.error)),
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

  Color _txnColor(String t) => switch (t) {
    'topup' => AppColors.success,
    'booking_payment' => AppColors.error,
    'security_deposit' => AppColors.warning,
    'refund' => AppColors.accent,
    'no_show_penalty' => AppColors.error,
    _ => AppColors.textSecondary,
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
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Enter amount between PKR 100 and 50,000')));
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
```

---

## FILE 2: lib/screens/player/wallet_history_screen.dart (NEW)

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../providers/auth_provider.dart';

class WalletHistoryScreen extends StatefulWidget {
  const WalletHistoryScreen({super.key});
  @override
  State<WalletHistoryScreen> createState() => _WalletHistoryScreenState();
}

class _WalletHistoryScreenState extends State<WalletHistoryScreen> {
  List<Map<String, dynamic>> _txns = [];
  bool _loading = true;
  String _filter = 'all';
  static const _base = 'http://10.0.2.2:3000/api';
  static const _filters = [
    ('all', 'All'), ('topup', 'Top-ups'),
    ('booking_payment', 'Bookings'), ('refund', 'Refunds'),
  ];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final f = _filter == 'all' ? '' : '&type=$_filter';
      final resp = await http.get(
        Uri.parse('$_base/wallet/transactions?limit=50$f'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted) setState(() {
        _txns = data['success'] == true
          ? List<Map<String,dynamic>>.from(data['data']) : [];
        _loading = false;
      });
    } catch (_) { if (mounted) setState(() => _loading = false); }
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
                      color: active ? AppColors.accent : Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(16)),
                    child: Text(f.$2, style: GoogleFonts.poppins(color: Colors.white,
                      fontSize: 12, fontWeight: active ? FontWeight.w600 : FontWeight.normal))),
                );
              }).toList())))),
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
        : _txns.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.receipt_long_outlined, size: 64, color: AppColors.disabled),
              const SizedBox(height: 12),
              Text('No transactions found', style: GoogleFonts.poppins(
                fontSize: 15, color: AppColors.textSecondary)),
            ]))
          : RefreshIndicator(color: AppColors.accent, onRefresh: _load,
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: _txns.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _txnCard(_txns[i]),
              )),
    );
  }

  Widget _txnCard(Map<String, dynamic> t) {
    final type = t['type'] as String;
    final amount = (t['amount'] as num).toDouble();
    final isCredit = ['topup', 'refund'].contains(type);
    final label = _label(type);
    final color = isCredit ? AppColors.success : AppColors.error;
    return GestureDetector(
      onTap: () => _showDetail(t),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border)),
        child: Row(children: [
          Container(width: 44, height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(_icon(type), color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 2),
            Text(t['counterparty_name'] ?? '',
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(_fmtDate(t['created_at']),
              style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${isCredit ? '+' : ''}PKR ${amount.abs().toStringAsFixed(0)}',
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
                color: color)),
            if (t['reference_id'] != null)
              Text('#${(t['reference_id'] as String).replaceAll('TRX-','')}',
                style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary)),
          ]),
        ]),
      ),
    );
  }

  void _showDetail(Map<String, dynamic> t) {
    final type = t['type'] as String;
    final amount = (t['amount'] as num).toDouble();
    final isCredit = ['topup', 'refund'].contains(type);
    showModalBottomSheet(context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4,
            decoration: BoxDecoration(color: AppColors.border,
              borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('TRANSACTION ID', style: GoogleFonts.poppins(
                fontSize: 10, color: AppColors.textSecondary, letterSpacing: 0.5)),
              Text(t['reference_id'] ?? '—', style: GoogleFonts.poppins(
                fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            ]),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: (isCredit ? AppColors.accent : AppColors.error).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
              child: Text(isCredit ? 'CREDIT' : 'DEBIT',
                style: GoogleFonts.poppins(
                  color: isCredit ? AppColors.accent : AppColors.error,
                  fontWeight: FontWeight.bold, fontSize: 11))),
          ]),
          const SizedBox(height: 20),
          const Divider(color: AppColors.border),
          _detailRow('Amount',
            'PKR ${amount.abs().toStringAsFixed(0)}',
            valueColor: isCredit ? AppColors.success : AppColors.error),
          _detailRow('Type', _label(type)),
          if (t['counterparty_name'] != null)
            _detailRow('Counterparty', t['counterparty_name']),
          _detailRow('Timestamp', _fmtDate(t['created_at'])),
          if (t['balance_after'] != null)
            _detailRow('Balance After',
              'PKR ${(t['balance_after'] as num).toStringAsFixed(0)}'),
          const SizedBox(height: 24),
        ]),
      ));
  }

  Widget _detailRow(String l, String? v, {Color? valueColor}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(l, style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      const SizedBox(width: 16),
      Flexible(child: Text(v ?? '—', textAlign: TextAlign.end,
        style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600,
          color: valueColor ?? AppColors.textPrimary))),
    ]));

  IconData _icon(String t) => switch(t) {
    'topup' => Icons.south_west, 'booking_payment' => Icons.north_east,
    'security_deposit' => Icons.lock_outline, 'refund' => Icons.replay,
    'no_show_penalty' => Icons.cancel_outlined, _ => Icons.swap_horiz,
  };

  String _label(String t) => switch(t) {
    'topup' => 'Wallet Top-up', 'booking_payment' => 'Booking Payment',
    'security_deposit' => 'Security Deposit', 'refund' => 'Booking Refund',
    'no_show_penalty' => 'No-Show Penalty', _ => 'Transaction',
  };

  String _fmtDate(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${m[dt.month-1]}, ${dt.year} • ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }
}
```

---

## FILE 3: lib/screens/player/bookings_screen.dart  (REPLACE stub)

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../providers/auth_provider.dart';

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});
  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<Map<String, dynamic>> _upcoming = [], _past = [];
  bool _loading = true;
  static const _base = 'http://10.0.2.2:3000/api';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(Uri.parse('$_base/bookings/my'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        final all = List<Map<String,dynamic>>.from(data['data']);
        final now = DateTime.now();
        setState(() {
          _upcoming = all.where((b) {
            final d = DateTime.tryParse(b['slot_date'] ?? '');
            return d != null && !d.isBefore(DateTime(now.year, now.month, now.day))
              && ['confirmed','pending'].contains(b['status']);
          }).toList();
          _past = all.where((b) {
            final d = DateTime.tryParse(b['slot_date'] ?? '');
            return d == null || d.isBefore(DateTime(now.year, now.month, now.day))
              || ['cancelled','no_show','checked_in','refunded'].contains(b['status']);
          }).toList();
          _loading = false;
        });
      } else if (mounted) setState(() => _loading = false);
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _cancel(String bookingId) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Cancel Booking?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      content: Text('You will receive a full refund to your wallet.',
        style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text('Keep', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),
          child: Text('Cancel Booking',
            style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600))),
      ],
    ));
    if (ok != true) return;
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(Uri.parse('$_base/bookings/$bookingId/cancel'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Booking cancelled. Refund added to wallet.',
              style: GoogleFonts.poppins(color: Colors.white)),
            backgroundColor: AppColors.accent, behavior: SnackBarBehavior.floating));
          _load();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(data['message'] ?? 'Failed',
              style: GoogleFonts.poppins(color: Colors.white)),
            backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating));
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Bookings', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        bottom: TabBar(controller: _tab,
          indicatorColor: AppColors.accent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
          tabs: const [Tab(text: 'Upcoming'), Tab(text: 'Past')]),
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
        : TabBarView(controller: _tab, children: [
            _buildList(_upcoming, upcoming: true),
            _buildList(_past, upcoming: false),
          ]),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> items, {required bool upcoming}) {
    if (items.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.event_busy, size: 64, color: AppColors.disabled),
        const SizedBox(height: 12),
        Text(upcoming ? 'No upcoming bookings' : 'No past bookings',
          style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textSecondary)),
        if (upcoming) ...[
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => Navigator.pushNamed(context, '/find-venues'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
            child: Text('Find Venues', style: GoogleFonts.poppins(color: Colors.white))),
        ],
      ]));
    }
    return RefreshIndicator(color: AppColors.accent, onRefresh: _load,
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (_, i) => _bookingCard(items[i], upcoming: upcoming),
      ));
  }

  Widget _bookingCard(Map<String, dynamic> b, {required bool upcoming}) {
    final status = b['status'] as String;
    final statusColor = _statusColor(status);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
          blurRadius: 6, offset: const Offset(0,2))]),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(b['venue_name'] ?? 'Venue',
              style: GoogleFonts.poppins(color: Colors.white,
                fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: statusColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: statusColor.withOpacity(0.5))),
              child: Text(status.toUpperCase(), style: GoogleFonts.poppins(
                color: statusColor, fontSize: 9, fontWeight: FontWeight.bold))),
          ]),
        ),
        // Body
        Padding(padding: const EdgeInsets.all(14), child: Column(children: [
          Row(children: [
            _infoItem(Icons.calendar_today_outlined,
              b['slot_date'] ?? ''),
            const SizedBox(width: 20),
            _infoItem(Icons.access_time_outlined,
              '${(b['start_time'] ?? '').toString().substring(0, 5)} – '
              '${(b['end_time'] ?? '').toString().substring(0, 5)}'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _infoItem(Icons.location_on_outlined, b['city'] ?? ''),
            const SizedBox(width: 20),
            _infoItem(Icons.currency_rupee,
              'PKR ${(b['total_amount'] as num?)?.toStringAsFixed(0) ?? '0'}'),
          ]),
          if (upcoming && status == 'confirmed') ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => _cancel(b['id']),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(vertical: 10)),
                child: Text('Cancel', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600, fontSize: 12)))),
            ]),
          ],
        ])),
      ]),
    );
  }

  Widget _infoItem(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 13, color: AppColors.textSecondary),
    const SizedBox(width: 4),
    Text(text, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
  ]);

  Color _statusColor(String s) => switch(s) {
    'confirmed' => AppColors.accent, 'pending' => AppColors.warning,
    'cancelled' => AppColors.error, 'checked_in' => AppColors.success,
    'no_show' => AppColors.error, _ => AppColors.textSecondary,
  };
}
```

---

## AFTER IMPLEMENTING
Run: flutter analyze — 0 errors
Test top-up: tap Wallet tab → Top Up → select PKR 2000 → balance updates
Test bookings: after booking a venue → appears in Upcoming tab
Test cancel: tap Cancel in Upcoming → refund added to wallet
