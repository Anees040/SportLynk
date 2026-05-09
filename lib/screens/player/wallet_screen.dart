import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/api_constants.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _wallet;
  List<dynamic> _transactions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/wallet'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted && data['success'] == true) {
          setState(() {
            _wallet = data['data']?['wallet'] ?? data['data'];
            _transactions = (data['data']?['transactions'] as List?) ?? [];
            _loading = false;
          });
          return;
        }
      }
      if (mounted) setState(() { _loading = false; _wallet = {'balance': 0, 'frozen_balance': 0}; });
    } catch (e) {
      debugPrint('Wallet load error: $e');
      if (mounted) setState(() { _loading = false; _wallet = {'balance': 0, 'frozen_balance': 0}; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = _numVal(_wallet?['balance'], 0);
    final frozen = _numVal(_wallet?['frozen_balance'], 0);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () async { setState(() => _loading = true); await _load(); },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
            // ── HEADER ─────────────────────────────────────────
            SliverToBoxAdapter(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF0A1F13), Color(0xFF14532D)],
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                    child: _loading
                      ? const Center(child: Padding(
                          padding: EdgeInsets.all(40),
                          child: CircularProgressIndicator(color: AppColors.accent)))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('My Wallet',
                            style: GoogleFonts.poppins(color: Colors.white60, fontSize: 14)),
                          const SizedBox(height: 4),
                          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('PKR ',
                              style: GoogleFonts.poppins(color: Colors.white60, fontSize: 18)),
                            Text('$balance',
                              style: GoogleFonts.poppins(color: Colors.white,
                                fontSize: 42, fontWeight: FontWeight.bold, height: 1.0)),
                          ]),
                          const SizedBox(height: 6),
                          if (frozen > 0)
                            Text('PKR $frozen on hold',
                              style: GoogleFonts.poppins(color: Colors.white38, fontSize: 12)),
                          const SizedBox(height: 24),
                          Row(children: [
                            Expanded(child: _actionBtn(
                              Icons.add_rounded, 'Add Money', AppColors.accent, () {
                                _showComingSoon('Add Money');
                              })),
                            const SizedBox(width: 12),
                            Expanded(child: _actionBtn(
                              Icons.send_rounded, 'Withdraw', Colors.white24, () {
                                _showComingSoon('Withdraw');
                              })),
                          ]),
                        ]),
                  ),
                ),
              ),
            ),

            // ── TRANSACTIONS HEADER ─────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Text('Transaction History',
                  style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
              ),
            ),

            // ── TRANSACTIONS LIST OR EMPTY ──────────────────────
            if (!_loading && _transactions.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(children: [
                      Container(
                        width: 64, height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.accentLight, borderRadius: BorderRadius.circular(16)),
                        child: const Icon(Icons.receipt_long_outlined,
                          size: 32, color: AppColors.accent),
                      ),
                      const SizedBox(height: 14),
                      Text('No transactions yet',
                        style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                      const SizedBox(height: 4),
                      Text('Your transaction history will appear here',
                        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                        textAlign: TextAlign.center),
                    ]),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _txCard(_transactions[i]),
                  childCount: _transactions.length,
                ),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(label, style: GoogleFonts.poppins(color: Colors.white,
            fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _txCard(Map<String, dynamic> tx) {
    final type = (tx['type'] ?? 'credit').toString();
    final isCredit = type == 'credit' || type == 'refund';
    final amount = _numVal(tx['amount'], 0);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: (isCredit ? const Color(0xFF22C55E) : AppColors.error).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(isCredit ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
            color: isCredit ? const Color(0xFF22C55E) : AppColors.error, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tx['description'] ?? type.toUpperCase(),
            style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w500,
              color: AppColors.textPrimary),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(_formatDate(tx['created_at']),
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Text('${isCredit ? '+' : '-'}PKR $amount',
          style: GoogleFonts.poppins(
            color: isCredit ? const Color(0xFF22C55E) : AppColors.error,
            fontSize: 14, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$feature feature coming soon!',
        style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: AppColors.primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  int _numVal(dynamic v, int fallback) {
    if (v == null) return fallback;
    if (v is num) return v.round();
    return int.tryParse(v.toString()) ?? fallback;
  }

  String _formatDate(dynamic d) {
    if (d == null) return '—';
    final dt = DateTime.tryParse(d.toString());
    if (dt == null) return d.toString();
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${m[dt.month - 1]} ${dt.year}';
  }
}
