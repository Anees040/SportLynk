import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../services/api_service.dart';
import '../utils/num_util.dart';
import 'transaction_detail_sheet.dart' show fmtTxnDate;

/// FR7.4 / ER1.6 — request a payout, and see the one in flight.
///
/// Money timing (mirrors the comment in `backend/src/routes/wallet.js`): the
/// amount leaves the available balance the moment the request is made, not when
/// the payout completes — otherwise a player could spend money they had already
/// asked to withdraw. Cancelling refunds it as a real `refund` ledger row.
///
/// Only one withdrawal may be pending at a time, and that is enforced by a
/// partial unique index in the database (migration 014), not by a check in this
/// widget — so two fast taps cannot both succeed. When one is pending, this
/// sheet shows its state and a Cancel button instead of the form. Without that
/// Cancel button a single test withdrawal would lock the feature for a whole
/// settlement window, mid-demo.
class WithdrawSheet extends StatefulWidget {
  final String token;

  /// Spendable balance, i.e. `wallets.balance` — escrow is already excluded.
  final double available;

  const WithdrawSheet({super.key, required this.token, required this.available});

  /// Returns `true` when the wallet changed and the caller should reload.
  static Future<bool> show(
    BuildContext context, {
    required String token,
    required double available,
  }) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => WithdrawSheet(token: token, available: available),
    );
    return changed ?? false;
  }

  @override
  State<WithdrawSheet> createState() => _WithdrawSheetState();
}

// Mirrors PAYOUT_METHODS / the CHECK constraint in migration 014.
const _methods = <String, String>{
  'easypaisa': 'Easypaisa',
  'jazzcash': 'JazzCash',
  'bank': 'Bank Account',
};

class _WithdrawSheetState extends State<WithdrawSheet> {
  final _api = ApiClient();
  final _amountCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _numberCtrl = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  String? _error;

  Map<String, dynamic>? _pending;
  double _minAmount = 200;
  int _settleMinutes = 24 * 60;
  String _method = 'easypaisa';

  /// Set once anything succeeds, so closing the sheet tells the wallet to reload.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _nameCtrl.dispose();
    _numberCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await _api.get('/wallet/withdrawals', token: widget.token);
    if (!mounted) return;
    if (res['success'] != true) {
      setState(() {
        _loading = false;
        _error = (res['message'] ?? 'Could not load your withdrawals.').toString();
      });
      return;
    }
    final d = res['data'] as Map<String, dynamic>;
    setState(() {
      _pending = d['pending'] as Map<String, dynamic>?;
      _minAmount = asNum(d['minAmount'], fallback: 200);
      _settleMinutes = asInt(d['settleMinutes'], fallback: 24 * 60);
      _loading = false;
    });
  }

  Future<void> _submit() async {
    final amount = asNumOrNull(_amountCtrl.text);
    // Validated here for a fast, field-level message; the server validates the
    // same rules again because this check can be bypassed and the balance can
    // change between the two.
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter the amount you want to withdraw.');
      return;
    }
    if (amount < _minAmount) {
      setState(() => _error =
          'Minimum withdrawal is PKR ${_minAmount.toStringAsFixed(0)}.');
      return;
    }
    if (amount > widget.available) {
      setState(() => _error =
          'You can withdraw up to PKR ${widget.available.toStringAsFixed(0)}.');
      return;
    }
    if (_numberCtrl.text.replaceAll(' ', '').length < 6) {
      setState(() => _error = _method == 'bank'
          ? 'Enter your bank account number.'
          : 'Enter the mobile number registered with ${_methods[_method]}.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await _api.post('/wallet/withdraw', {
      'amount': amount,
      'method': _method,
      'accountName': _nameCtrl.text.trim(),
      'accountNumber': _numberCtrl.text.trim(),
    }, token: widget.token);
    if (!mounted) return;

    if (res['success'] != true) {
      // A 409 means another request won the race for the single pending slot —
      // reload so the sheet shows that request instead of a stale form.
      final conflict = res['statusCode'] == 409;
      setState(() {
        _busy = false;
        _error = (res['message'] ?? 'Withdrawal failed.').toString();
      });
      if (conflict) await _load();
      return;
    }

    _changed = true;
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _cancel() async {
    final id = _pending?['id']?.toString();
    if (id == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await _api.delete('/wallet/withdraw/$id', token: widget.token);
    if (!mounted) return;
    if (res['success'] != true) {
      setState(() {
        _busy = false;
        _error = (res['message'] ?? 'Could not cancel the withdrawal.').toString();
      });
      return;
    }
    _changed = true;
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  /// "24 hours" / "1 hour 30 min" / "1 min" — mirrors describeDelay() in
  /// escrow.js so a SL_TEST_SETTLE_MINUTES demo does not promise 24 hours.
  String get _settleText {
    final m = _settleMinutes;
    if (m < 60) return '$m minute${m == 1 ? '' : 's'}';
    final h = m ~/ 60;
    final rem = m % 60;
    final hours = '$h hour${h == 1 ? '' : 's'}';
    return rem == 0 ? hours : '$hours $rem min';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
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
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.accent),
                ),
              )
            else if (_pending != null)
              ..._pendingView()
            else
              ..._formView(),
          ],
        ),
      ),
    );
  }

  // ── One withdrawal already in flight ──────────────────────────────────────
  List<Widget> _pendingView() {
    final w = _pending!;
    final amount = asNum(w['amount']);
    final method = _methods[w['method']?.toString()] ?? 'your account';
    final number = (w['account_number'] ?? '').toString();
    final tail = number.length > 4 ? '••••${number.substring(number.length - 4)}' : number;

    return [
      Text(
        'Withdrawal in Progress',
        style: GoogleFonts.poppins(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      const SizedBox(height: 16),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Text(
              'PKR ${amount.toStringAsFixed(0)}',
              style: GoogleFonts.poppins(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'to $method${tail.isEmpty ? '' : ' $tail'}',
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.schedule, size: 13, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Text(
                    'PROCESSING',
                    style: GoogleFonts.poppins(
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: AppColors.warning,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Requested ${fmtTxnDate(w['requested_at']?.toString())}',
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _note(
        'The amount has already left your available balance. Payout completes '
        'within $_settleText. Cancel to put it straight back in your wallet.',
      ),
      if (_error != null) ...[const SizedBox(height: 12), _errorBox(_error!)],
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          icon: _busy
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.error,
                  ),
                )
              : const Icon(Icons.close, size: 17),
          label: Text(
            _busy ? 'Cancelling…' : 'Cancel Withdrawal',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            side: const BorderSide(color: AppColors.error),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          onPressed: _busy ? null : _cancel,
        ),
      ),
      const SizedBox(height: 6),
      Center(
        child: TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, _changed),
          child: Text(
            'Close',
            style: GoogleFonts.poppins(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    ];
  }

  // ── No pending withdrawal: the request form ───────────────────────────────
  List<Widget> _formView() {
    final canAfford = widget.available >= _minAmount;

    return [
      Text(
        'Withdraw Funds',
        style: GoogleFonts.poppins(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'Available to withdraw: PKR ${widget.available.toStringAsFixed(0)}',
        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
      ),
      const SizedBox(height: 16),

      if (!canAfford)
        _note(
          'You need at least PKR ${_minAmount.toStringAsFixed(0)} in available '
          'balance to withdraw. Money held in escrow for active bookings cannot '
          'be withdrawn until those bookings finish.',
        )
      else ...[
        _label('Amount'),
        TextField(
          controller: _amountCtrl,
          keyboardType: TextInputType.number,
          enabled: !_busy,
          style: GoogleFonts.poppins(fontSize: 14),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: _fieldStyle(
            'Min ${_minAmount.toStringAsFixed(0)} · max ${widget.available.toStringAsFixed(0)}',
            prefix: 'PKR ',
          ),
        ),
        const SizedBox(height: 6),
        // "All" is the button people actually want, and typing the exact balance
        // by hand is the easiest way to land on an off-by-one rejection.
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _amountCtrl.text = widget.available.toStringAsFixed(0);
                    _error = null;
                  }),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
            ),
            child: Text(
              'Withdraw all (PKR ${widget.available.toStringAsFixed(0)})',
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),

        _label('Payout method'),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppColors.inputFill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _method,
              isExpanded: true,
              borderRadius: BorderRadius.circular(12),
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
              items: _methods.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _method = v ?? 'easypaisa';
                      _error = null;
                    }),
            ),
          ),
        ),
        const SizedBox(height: 14),

        _label(_method == 'bank' ? 'Account number' : 'Mobile number'),
        TextField(
          controller: _numberCtrl,
          keyboardType: TextInputType.phone,
          enabled: !_busy,
          style: GoogleFonts.poppins(fontSize: 14),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: _fieldStyle(
            _method == 'bank' ? 'e.g. PK00 ABCD 0000 0000 0000' : 'e.g. 03001234567',
          ),
        ),
        const SizedBox(height: 14),

        _label('Account holder name (optional)'),
        TextField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          enabled: !_busy,
          style: GoogleFonts.poppins(fontSize: 14),
          decoration: _fieldStyle('As registered with your provider'),
        ),
        const SizedBox(height: 14),
        _note(
          'The amount leaves your available balance immediately and is paid out '
          'within $_settleText. You can cancel any time before it completes.',
        ),
        if (_error != null) ...[const SizedBox(height: 12), _errorBox(_error!)],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              disabledBackgroundColor: AppColors.disabled,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    'Request Withdrawal',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
          ),
        ),
      ],
      if (!canAfford && _error != null) ...[
        const SizedBox(height: 12),
        _errorBox(_error!),
      ],
      const SizedBox(height: 8),
    ];
  }

  // ── small shared pieces ───────────────────────────────────────────────────

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: GoogleFonts.poppins(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
    ),
  );

  InputDecoration _fieldStyle(String hint, {String? prefix}) => InputDecoration(
    hintText: hint,
    hintStyle: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
    prefixText: prefix,
    prefixStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14),
    filled: true,
    fillColor: AppColors.inputFill,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
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

  Widget _errorBox(String text) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.error.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 15, color: AppColors.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 12,
              color: AppColors.error,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}
