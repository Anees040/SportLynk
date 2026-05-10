import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
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
        Uri.parse('${ApiConstants.baseUrl}/wallet/transactions?limit=50$f'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() {
          _txns = data['success'] == true
            ? List<Map<String,dynamic>>.from(data['data']) : [];
          _loading = false;
        });
      }
    } catch (_) { if (mounted) { setState(() => _loading = false); } }
  }

  double _parseDouble(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
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
                separatorBuilder: (_, index) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _txnCard(_txns[i]),
              )),
    );
  }

  Widget _txnCard(Map<String, dynamic> t) {
    final type = t['type'] as String;
    final amount = _parseDouble(t['amount']);
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
              color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
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
    final amount = _parseDouble(t['amount']);
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
                color: (isCredit ? AppColors.accent : AppColors.error).withValues(alpha: 0.1),
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
    'no_show_penalty' => 'No-Show Penalty', 'owner_payout' => 'Owner Payout',
    'withdrawal' => 'Withdrawal', _ => 'Transaction',
  };

  String _fmtDate(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${m[dt.month-1]}, ${dt.year} • ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }
}
