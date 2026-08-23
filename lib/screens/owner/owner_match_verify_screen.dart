import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/match.dart';
import '../../providers/auth_provider.dart';
import '../../services/match_service.dart';
import '../../services/realtime_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';

/// The venue owner's verification queue (ER2.2).
///
/// A result only becomes real — and only moves ratings — when the owner of the
/// pitch it was played on confirms it. That is the whole point of the step: two
/// captains agreeing is a claim, and the venue is the one party with no stake in
/// which team wins.
///
/// Both submissions are shown side by side and identically. The owner is being
/// asked "is this what happened on your pitch", not "which team do you believe",
/// so there is no score field here and no way to enter a third answer. If the
/// owner disagrees with what both captains reported, the honest action is to leave
/// it and let a captain flag it — which is why the screen says so instead of
/// offering an override it has no authority for.
class OwnerMatchVerifyScreen extends StatefulWidget {
  const OwnerMatchVerifyScreen({super.key});

  @override
  State<OwnerMatchVerifyScreen> createState() => _OwnerMatchVerifyScreenState();
}

class _OwnerMatchVerifyScreenState extends State<OwnerMatchVerifyScreen> {
  final _service = MatchService();
  StreamSubscription? _sub;

  List<MatchModel> _items = const [];
  bool _loading = true;
  final _busy = <String>{};

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    _sub = RealtimeService().matchUpdates.listen((_) {
      if (mounted) _load(silent: true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final r = await _service.ownerPending(_token);
    if (!mounted) return;
    setState(() {
      _items = r;
      _loading = false;
    });
  }

  Future<void> _verify(MatchModel m) async {
    if (_busy.contains(m.id)) return;

    final line = m.scoreline ?? '—';
    final outcome = m.isDraw || m.winnerTeam == null
        ? 'a draw'
        : '${m.winnerTeam == m.challenger.id ? m.challenger.name : m.opponent.name} winning';

    final sure = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Confirm this result?',
            style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text(
          '${m.challenger.name} $line ${m.opponent.name} — $outcome.\n\nBoth teams\' ratings change as soon as you confirm, and both captains are notified with the points they gained or lost.',
          style: GoogleFonts.poppins(
              fontSize: 13, height: 1.45, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not yet')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;

    setState(() => _busy.add(m.id));
    final r = await _service.verify(_token, m.id);
    if (!mounted) return;
    setState(() => _busy.remove(m.id));

    if (r['success'] == true) {
      // The backend's own sentence distinguishes "ratings updated" from "one of
      // these teams is frozen, so no points changed hands" (ER2.3) — a difference
      // the owner will otherwise be asked about by a confused captain.
      SnackbarUtil.showSuccess(
          context, r['message']?.toString() ?? 'Result verified.');
      await _load(silent: true);
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not verify this result.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Verify Results',
            style:
                GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _items.isEmpty
                  ? const MatchEmptyState(
                      icon: Icons.task_alt,
                      text:
                          'Nothing to verify.\n\nWhen both captains report the same score for a match at one of your venues, it appears here for you to confirm.',
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                      itemCount: _items.length,
                      itemBuilder: (_, i) => _card(_items[i]),
                    ),
            ),
    );
  }

  Widget _card(MatchModel m) {
    final busy = _busy.contains(m.id);
    final b = m.booking;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Where and when — the owner's anchor. They are verifying a slot on their
          // own pitch, so that is the first thing they need to recognise.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: const BoxDecoration(
              color: AppColors.inputFill,
              borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
            ),
            child: Row(
              children: [
                const Icon(Icons.stadium_outlined, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    b == null
                        ? 'Booking unavailable'
                        : '${b.venueName ?? 'Venue'}  ·  ${b.slotDate == null ? '' : '${b.slotDate!.day}/${b.slotDate!.month}/${b.slotDate!.year}'}  ·  ${b.timeRange}',
                    maxLines: 2,
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                // The agreed scoreline, big — it is the thing being confirmed.
                Row(
                  children: [
                    Expanded(child: _side(m.challenger)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        m.scoreline ?? '–',
                        style: GoogleFonts.poppins(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    Expanded(child: _side(m.opponent)),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1, color: AppColors.divider),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'WHAT EACH CAPTAIN REPORTED',
                    style: GoogleFonts.poppins(
                      fontSize: 9,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ...m.submissions.map((s) => _submissionRow(m, s)),
                if (m.submissions.length < 2)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 13, color: AppColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Only ${m.submissions.length} of 2 submissions loaded.',
                            style: GoogleFonts.poppins(
                                fontSize: 11, color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.verified, size: 18),
                    label: Text(busy ? 'Verifying…' : 'Verify result',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(46),
                      shape:
                          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: busy ? null : () => _verify(m),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Not what happened on your pitch? Leave it unverified and tell the teams — a captain can flag the result for an admin. You cannot change the score here.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 10.5,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _side(MatchSide s) => Column(
        children: [
          TeamCrest(logoUrl: s.logoUrl, radius: 22),
          const SizedBox(height: 7),
          Text(
            s.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              height: 1.25,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.ranked ? 'ELO ${s.elo}' : 'Unranked',
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      );

  Widget _submissionRow(MatchModel m, MatchSubmission s) {
    // Both submissions agree by the time a match reaches this queue — a conflict
    // sends it to `disputed` instead, and this screen never shows those. Printing
    // each one anyway is what lets the owner see that for themselves rather than
    // taking the app's word for it.
    final winner = s.winnerTeam == null
        ? 'Draw'
        : '${s.winnerTeam == m.challenger.id ? m.challenger.name : m.opponent.name} won';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.accentLight.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.how_to_reg, size: 15, color: AppColors.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.teamName ?? 'Team',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  winner,
                  style: GoogleFonts.poppins(
                      fontSize: 10.5, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Text(
            s.scoreline,
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
