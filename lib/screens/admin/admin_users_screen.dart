// admin_users_screen.dart — S.7 Wave D · D5 / FR10.8.
//
// Find an account, see what it is doing on the platform, suspend it or bring it
// back. Search is server-side (`q` matches name, email or phone) and paging is
// keyset on `(created_at, id)` — an admin suspending accounts while paging would
// otherwise watch rows shift under their thumb.
//
// SUSPENSION IS NOT A FLAG, IT IS A CASCADE. `PATCH /users/:id/suspend` cancels
// the user's upcoming bookings with refunds, expires their open challenges,
// withdraws them from tournaments and — for an owner — deactivates their venues
// and refunds the pending requests. That receipt comes back in the response, and
// this screen shows it, because "suspended" without "and here is the money that
// moved" is the version an admin cannot defend afterwards.
//
// Two things it deliberately does NOT decide: the server refuses a self-suspension
// and refuses to suspend another admin. Those buttons are hidden here as well, but
// the refusal is the server's and its message is what gets shown.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _svc = AdminService();
  final _search = TextEditingController();
  Timer? _debounce;

  final List<AdminUserRow> _rows = [];
  String _role = '';
  String _status = 'all';
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _busy = false;

  String? get _token => Provider.of<AuthProvider>(context, listen: false).token;
  String? get _myId => Provider.of<AuthProvider>(context, listen: false).currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    setState(() => _loading = true);
    final page = await _svc.users(
      token,
      q: _search.text.trim().isEmpty ? null : _search.text.trim(),
      role: _role.isEmpty ? null : _role,
      status: _status,
    );
    if (!mounted) return;
    setState(() {
      _rows
        ..clear()
        ..addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    final token = _token;
    if (token == null || _cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    final page = await _svc.users(
      token,
      q: _search.text.trim().isEmpty ? null : _search.text.trim(),
      role: _role.isEmpty ? null : _role,
      status: _status,
      cursor: _cursor,
    );
    if (!mounted) return;
    setState(() {
      _rows.addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Users', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      // The cascade is a transaction that cancels bookings and moves money; a second
      // tap while it runs would be a second suspension attempt, so the screen is
      // blocked rather than merely showing a spinner somewhere.
      body: Stack(
        children: [
          Column(
            children: [
              _searchBar(),
              _filterBar(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _rows.isEmpty
                    ? const Center(
                        child: MatchEmptyState(
                          text: 'No accounts match this search.',
                          icon: Icons.person_search_outlined,
                        ),
                      )
                    : RefreshIndicator(
                        color: AppColors.accent,
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: _rows.length + (_hasMore ? 1 : 0),
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (_, i) =>
                              i >= _rows.length ? _moreButton() : _card(_rows[i]),
                        ),
                      ),
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.25),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: _search,
        onChanged: _onSearchChanged,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _load(),
        style: GoogleFonts.poppins(fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Name, email or phone',
          hintStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _search.clear();
                    _load();
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.border),
          ),
        ),
      ),
    );
  }

  /// Both filter rows use the SERVER's vocabulary (`player|owner|admin`, and
  /// `active|suspended|all`) so what the chip says and what the query sends cannot
  /// drift apart.
  Widget _filterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          ...{
            '': 'All roles',
            'player': 'Players',
            'owner': 'Owners',
            'admin': 'Admins',
          }.entries.map(
            (e) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _chip(e.value, _role == e.key, () {
                setState(() => _role = e.key);
                _load();
              }),
            ),
          ),
          Container(
            width: 1,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: AppColors.border,
          ),
          ...{'all': 'Any', 'active': 'Active', 'suspended': 'Suspended'}.entries.map(
            (e) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _chip(e.value, _status == e.key, () {
                setState(() => _status = e.key);
                _load();
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? AppColors.accent : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? AppColors.accent : AppColors.border),
        ),
        child: Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.w500,
            color: on ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _moreButton() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: _loadMore,
                child: Text('Load more', style: GoogleFonts.poppins(fontSize: 12.5)),
              ),
      ),
    );
  }

  // ── One account ────────────────────────────────────────────────────────────
  Widget _card(AdminUserRow u) {
    final isMe = u.id == _myId;
    return InkWell(
      onTap: () => _openSheet(u),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: u.suspended ? AppColors.error.withValues(alpha: 0.4) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            TeamCrest(logoUrl: u.avatarUrl, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          u.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            decoration: u.suspended ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _pill(u.role, AppColors.accent),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        _pill('you', AppColors.textSecondary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [u.email, u.phone].where((s) => (s ?? '').isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (u.bookings > 0) _pill('${u.bookings} bookings', AppColors.textSecondary),
                      if (u.venues > 0) _pill('${u.venues} venues', AppColors.textSecondary),
                      if (u.walletBalance != 0 || u.walletFrozen != 0)
                        _pill(
                          'PKR ${u.walletBalance.toStringAsFixed(0)}'
                          '${u.walletFrozen != 0 ? ' (+${u.walletFrozen.toStringAsFixed(0)} held)' : ''}',
                          AppColors.textSecondary,
                        ),
                      if (u.suspended) _pill('suspended', AppColors.error, icon: Icons.block),
                    ],
                  ),
                  if (u.suspended && (u.suspendedReason ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      u.suspendedReason!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.error),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: color), const SizedBox(width: 3)],
          Text(
            text,
            style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  // ── The account sheet ──────────────────────────────────────────────────────
  void _openSheet(AdminUserRow u) {
    final isMe = u.id == _myId;
    final protected = isMe || u.role == 'admin';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TeamCrest(logoUrl: u.avatarUrl, radius: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          u.name,
                          style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${u.role}${u.email != null ? ' · ${u.email}' : ''}',
                          style: GoogleFonts.poppins(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (u.suspended) ...[
                _sheetLine(
                  Icons.block,
                  'Suspended${u.suspendedAt != null ? ' on ${_day(u.suspendedAt!)}' : ''}'
                  '${u.suspendedByName != null ? ' by ${u.suspendedByName}' : ''}',
                  AppColors.error,
                ),
                if ((u.suspendedReason ?? '').isNotEmpty)
                  _sheetLine(Icons.notes, u.suspendedReason!, AppColors.error),
              ] else
                _sheetLine(Icons.check_circle_outline, 'Active', AppColors.success),
              if (u.createdAt != null)
                _sheetLine(
                  Icons.calendar_today_outlined,
                  'Joined ${_day(u.createdAt!)}',
                  AppColors.textSecondary,
                ),
              _sheetLine(
                Icons.receipt_long_outlined,
                '${u.bookings} bookings · ${u.venues} venues',
                AppColors.textSecondary,
              ),
              _sheetLine(
                Icons.account_balance_wallet_outlined,
                'Wallet PKR ${u.walletBalance.toStringAsFixed(2)}'
                ' · held ${u.walletFrozen.toStringAsFixed(2)}',
                AppColors.textSecondary,
              ),
              const SizedBox(height: 14),
              if (protected)
                Text(
                  isMe
                      ? 'You cannot suspend your own account.'
                      : 'Admin accounts cannot be suspended from here.',
                  style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: u.suspended
                      ? ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.success,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _reinstateFlow(u);
                          },
                          icon: const Icon(Icons.undo, size: 16),
                          label: const Text('Reinstate this account'),
                        )
                      : ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.error,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _suspendFlow(u);
                          },
                          icon: const Icon(Icons.block, size: 16),
                          label: const Text('Suspend this account'),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetLine(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: GoogleFonts.poppins(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }

  // ── Suspend ────────────────────────────────────────────────────────────────
  /// A reason is mandatory (the server refuses without one) and the user is told
  /// it, so the sheet asks for it in the same words the player will read.
  Future<void> _suspendFlow(AdminUserRow u) async {
    final reason = TextEditingController();
    String? error;
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            'Suspend ${u.name}?',
            style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                u.role == 'owner'
                    ? 'Their venues go offline, pending requests are rejected and '
                          'refunded, upcoming bookings are cancelled with refunds, and '
                          'their existing login stops working on the next request.'
                    : 'Their upcoming bookings are cancelled with refunds, open '
                          'challenges expire, they are withdrawn from upcoming '
                          'tournaments, and their existing login stops working on the '
                          'next request.',
                style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                style: GoogleFonts.poppins(fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Reason (the user is told this)',
                  labelStyle: GoogleFonts.poppins(fontSize: 12),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (error != null)
                Text(error!, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.error)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text('Cancel', style: GoogleFonts.poppins(fontSize: 13)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (reason.text.trim().length < 3) {
                  setLocal(() => error = 'A reason is required — the user is told it.');
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              child: Text(
                'Suspend',
                style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;

    final token = _token;
    if (token == null) return;
    setState(() => _busy = true);
    final res = await _svc.suspend(token, u.id, reason: reason.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    await _afterWrite(res, showCascade: true);
  }

  // ── Reinstate ──────────────────────────────────────────────────────────────
  /// The note is optional here: reinstating takes nothing away, and the audit row
  /// records who did it either way. Refunded bookings are NOT re-created — that is
  /// said out loud, because an owner coming back will ask.
  Future<void> _reinstateFlow(AdminUserRow u) async {
    final note = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Reinstate ${u.name}?',
          style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              u.role == 'owner'
                  ? 'They can log in again and their venues come back online. '
                        'Bookings that were cancelled and refunded are not restored.'
                  : 'They can log in again. Bookings that were cancelled and refunded '
                        'are not restored.',
              style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLength: 500,
              style: GoogleFonts.poppins(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Note for the audit log (optional)',
                labelStyle: GoogleFonts.poppins(fontSize: 12),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel', style: GoogleFonts.poppins(fontSize: 13)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              'Reinstate',
              style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    final token = _token;
    if (token == null) return;
    setState(() => _busy = true);
    final res = await _svc.reinstate(token, u.id, note: note.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    await _afterWrite(res, showCascade: false);
  }

  /// One exit for both writes. The server's own message is what is shown — a
  /// refused self-suspension, a 404, or the sentence that names the refunds.
  Future<void> _afterWrite(Map<String, dynamic> res, {required bool showCascade}) async {
    final ok = res['success'] == true;
    final message = (res['message'] ?? '').toString().trim();
    if (!ok) {
      SnackbarUtil.showError(context, message.isEmpty ? 'That did not go through.' : message);
      return;
    }
    final data = res['data'];
    final result = data is Map<String, dynamic> ? SuspensionResult.fromJson(data, message) : null;
    await _load();
    if (!mounted) return;
    final cascade = result?.cascade;
    if (showCascade && result != null && cascade != null && !cascade.isEmpty) {
      await _showCascade(result, cascade);
      return;
    }
    if (!mounted) return;
    SnackbarUtil.showSuccess(context, message.isEmpty ? 'Done.' : message);
  }

  /// The receipt. Everything the suspension actually moved, itemised — this is the
  /// screen an admin screenshots when the owner phones to ask what happened.
  Future<void> _showCascade(SuspensionResult r, SuspensionCascade c) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '${r.name ?? 'Account'} suspended',
          style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.message,
                style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 10),
              if (c.refundedTotal > 0)
                _cascadeLine(
                  Icons.payments_outlined,
                  'PKR ${c.refundedTotal.toStringAsFixed(2)} refunded in total',
                  AppColors.success,
                ),
              for (final b in c.bookingsCancelled)
                _cascadeLine(
                  Icons.event_busy_outlined,
                  '${b.venueName ?? 'booking'} cancelled'
                  '${b.refunded > 0 ? ' · PKR ${b.refunded.toStringAsFixed(0)} back' : ''}'
                  '${b.penalty > 0 ? ' · PKR ${b.penalty.toStringAsFixed(0)} kept${b.late ? ' (late)' : ''}' : ''}',
                  AppColors.textPrimary,
                ),
              for (final s in c.bookingsLeftAlone)
                _cascadeLine(
                  Icons.info_outline,
                  '${s.venueName ?? 'booking'}${s.slotDate != null ? ' on ${s.slotDate}' : ''} '
                  'left alone — ${s.reason}',
                  AppColors.warning,
                ),
              if (c.challengesExpired.isNotEmpty)
                _cascadeLine(
                  Icons.sports_outlined,
                  '${c.challengesExpired.length} open challenge'
                  '${c.challengesExpired.length == 1 ? '' : 's'} expired',
                  AppColors.textPrimary,
                ),
              for (final t in c.tournamentsWithdrawn)
                _cascadeLine(
                  Icons.emoji_events_outlined,
                  'Withdrawn from ${t.name ?? 'a tournament'}',
                  AppColors.textPrimary,
                ),
              for (final t in c.tournamentsLeftAlone)
                _cascadeLine(
                  Icons.emoji_events_outlined,
                  '${t.name ?? 'A tournament'} left alone'
                  '${t.reason != null ? ' — ${t.reason}' : ''}',
                  AppColors.warning,
                ),
              for (final v in c.venuesDeactivated)
                _cascadeLine(
                  Icons.storefront_outlined,
                  '${v.name ?? 'Venue'} taken offline',
                  AppColors.textPrimary,
                ),
              if (c.requestsRejected > 0)
                _cascadeLine(
                  Icons.cancel_outlined,
                  '${c.requestsRejected} pending request'
                  '${c.requestsRejected == 1 ? '' : 's'} rejected and refunded',
                  AppColors.textPrimary,
                ),
              if (c.confirmedBookingsLeftAlone > 0)
                _cascadeLine(
                  Icons.warning_amber_outlined,
                  '${c.confirmedBookingsLeftAlone} confirmed booking'
                  '${c.confirmedBookingsLeftAlone == 1 ? '' : 's'} at their venues were '
                  'left in place — those players still have a game',
                  AppColors.warning,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Done', style: GoogleFonts.poppins(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _cascadeLine(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: GoogleFonts.poppins(fontSize: 11.5, color: color)),
          ),
        ],
      ),
    );
  }

  String _day(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}';
  }
}
