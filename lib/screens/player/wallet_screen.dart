import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../services/api_service.dart';
import '../../services/offline_cache.dart';
import '../../utils/num_util.dart';
import '../../utils/reconnect_refresh.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/frozen_balance_sheet.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/transaction_detail_sheet.dart';
import '../../widgets/withdraw_sheet.dart';
import 'wallet_history_screen.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> with ReconnectRefresh<WalletScreen> {
  final _api = ApiClient();
  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _txns = [];
  bool _loading = true;
  String? _error;

  /// Set while the figures on screen came from disk rather than this session.
  DateTime? _cachedAt;
  static const _amounts = [500.0, 1000.0, 2000.0, 5000.0];

  @override
  void initState() {
    super.initState();
    // Concurrent, not chained — see [_hydrateFromCache].
    _load();
    _hydrateFromCache();
  }

  // Balance and transactions can move while the app sits backgrounded or offline;
  // a returning connection refetches them without a manual pull.
  @override
  void onReconnect() => _load();

  /// Show the last known balance if it arrives before the network does.
  ///
  /// A balance is the one figure where staleness has to be visible, so the strip
  /// carries the "saved N min ago" wording whenever these numbers came from disk:
  /// a cached balance that silently reads as current is how a player plans a
  /// booking they can no longer afford.
  ///
  /// The `_wallet != null` guard means a response that already landed wins; the
  /// cache never demotes fresh money figures to stale ones.
  Future<void> _hydrateFromCache() async {
    final cached = await OfflineCache.read(OfflineCache.wallet);
    if (!mounted || cached == null || _wallet != null) return;
    final map = cached.asMap();
    if (map == null || map['wallet'] is! Map) return;
    setState(() {
      _wallet = Map<String, dynamic>.from(map['wallet'] as Map);
      final txns = map['txns'];
      _txns = txns is List
          ? txns.whereType<Map>().map(Map<String, dynamic>.from).toList()
          : const [];
      _cachedAt = cached.at;
      _loading = false;
    });
  }

  Future<void> _load() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) {
      // No verified identity: the screen shows its error branch and a retry
      // rather than dereferencing a null token and crashing the host shell.
      setState(() { _loading = false; _error = 'Please sign in again to view your wallet.'; });
      return;
    }
    // Only spin when there is nothing to look at; a cached balance stays put while
    // the refresh runs behind it.
    if (_wallet == null) setState(() => _loading = true);
    final walletResp = await _api.get('/wallet/me', token: token);
    final txnResp =
        await _api.get('/wallet/transactions', token: token, queryParams: {'limit': '5'});
    if (!mounted) return;
    final ok = walletResp['success'] == true && walletResp['data'] is Map;
    setState(() {
      if (ok) {
        _wallet = Map<String, dynamic>.from(walletResp['data'] as Map);
        _txns = txnResp['success'] == true && txnResp['data'] is List
            ? List<Map<String, dynamic>>.from(txnResp['data'] as List)
            : const [];
        _error = null;
        _cachedAt = null;
      } else {
        // A balance is never shown as a fabricated zero: on failure the screen
        // keeps whatever it last held and offers a retry rather than inventing 0.
        // With a cached balance present the retry is replaced by the offline
        // strip, which explains the staleness without hiding the figure.
        _error = _wallet != null
            ? null
            : '${walletResp['message'] ?? 'Could not load your wallet.'}';
      }
      _loading = false;
    });
    if (ok) {
      context.read<ConnectivityProvider>().markReachable();
      await OfflineCache.write(
          OfflineCache.wallet, {'wallet': _wallet, 'txns': _txns});
    } else if (walletResp['statusCode'] == 0) {
      if (mounted) context.read<ConnectivityProvider>().markUnreachable();
    }
  }

  Future<void> _topUp(double amount) async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PaymentSimulationDialog(),
    );
    await Future.delayed(const Duration(seconds: 3));

    final resp = await _api.post('/wallet/topup', {'amount': amount}, token: token);
    if (!mounted) return;
    Navigator.pop(context); // close simulation dialog
    if (resp['success'] == true) {
      SnackbarUtil.showSuccess(context, 'PKR ${amount.toStringAsFixed(0)} added to wallet!');
      _load();
    } else {
      // ApiClient phrases connectivity and server errors for display, so an
      // offline top-up reads as a calm sentence, not a raw exception.
      SnackbarUtil.showError(context, '${resp['message'] ?? 'Top-up failed'}');
    }
  }

  void _showTopUpSheet() async {
    // Guarded before the sheet opens rather than after the amount is chosen: a
    // simulated three-second payment dialog that ends in a connection error is a
    // worse experience than being told up front, and a top-up must never appear to
    // have been accepted for later.
    if (!await OfflineActionNotice.guard(context, 'Adding money to your wallet')) {
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _TopUpSheet(amounts: _amounts, onTopUp: (amt) {
        Navigator.pop(context);
        _topUp(amt);
      }));
  }

  // FR7.4 / ER1.6 — withdraw
  // Replaces the "available after launch" stub. The sheet decides for itself
  // whether to show the request form or the pending withdrawal, because that
  // depends on server state this screen does not load.
  Future<void> _showWithdrawSheet() async {
    // Same reasoning as the top-up, with more at stake: a withdrawal moves money
    // out at request time, and the sheet's own "available" figure comes from a
    // balance that may be a cached one.
    if (!await OfflineActionNotice.guard(context, 'Requesting a withdrawal')) {
      return;
    }
    if (!mounted) return;
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) return;
    final changed = await WithdrawSheet.show(
      context,
      token: token,
      available: asNum(_wallet?['balance']),
    );
    if (changed && mounted) _load();
  }

  // FR7.2 — itemised escrow breakdown
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
      body: Column(children: [
        OfflineBanner(cachedAt: _cachedAt),
        Expanded(
          child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
            : _wallet == null
              ? RefreshIndicator(color: AppColors.accent, onRefresh: _load,
                  child: NetworkErrorView(
                    title: 'Could not load wallet',
                    message: _error ?? 'Please try again.',
                    onRetry: _load,
                  ))
              : RefreshIndicator(color: AppColors.accent, onRefresh: _load,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    // Balance card
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
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('PKR ${asNum(_wallet?['balance']).toStringAsFixed(0)}',
                        style: GoogleFonts.poppins(color: Colors.white,
                          fontSize: 36, fontWeight: FontWeight.bold)),
                    ),
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
                            const SizedBox(width: 4),
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text('AVAILABLE FUNDS', style: GoogleFonts.poppins(
                                  color: Colors.white60, fontSize: 9, letterSpacing: 0.5)),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('PKR ${asNum(_wallet?['balance']).toStringAsFixed(0)}',
                              style: GoogleFonts.poppins(color: AppColors.accent,
                                fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
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
                            const SizedBox(width: 4),
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text('FROZEN', style: GoogleFonts.poppins(
                                  color: Colors.white60, fontSize: 9, letterSpacing: 0.5)),
                              ),
                            ),
                            const SizedBox(width: 2),
                            const Icon(Icons.chevron_right,
                              color: Colors.white38, size: 13),
                          ]),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('PKR ${asNum(_wallet?['frozen_balance']).toStringAsFixed(0)}',
                              style: GoogleFonts.poppins(color: Colors.white70,
                                fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ])),
                      )),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),

                // ACTIONS
                Row(children: [
                  Expanded(child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8)),
                    onPressed: _showTopUpSheet,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('Top Up Wallet', style: GoogleFonts.poppins(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                        ),
                      ],
                    ),
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      side: const BorderSide(color: AppColors.accent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8)),
                    onPressed: _showWithdrawSheet,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.north_east, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('Withdraw', style: GoogleFonts.poppins(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                        ),
                      ],
                    ),
                  )),
                ]),
                const SizedBox(height: 24),

                // Recent transactions
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Expanded(
                    child: Text('Recent Transactions', style: GoogleFonts.poppins(
                      fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  ),
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
        ),
      ]),
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
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(isFrozen ? 'Frozen ${amount.abs().toStringAsFixed(0)}' : '${isCredit ? '+' : ''}PKR ${amount.abs().toStringAsFixed(0)}',
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
                color: color)),
          ),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, size: 16, color: AppColors.textSecondary),
      ]),
      ),
    );
  }
}

// Top up sheet

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
