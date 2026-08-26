import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/review.dart';
import '../../providers/auth_provider.dart';
import '../../services/review_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';
import '../../widgets/trust_widgets.dart';

/// The moderation queue. Every review that needs an eye lands here — a player or
/// owner *reported* it, the sentiment model *auto-flagged* it, or an admin already
/// *hid* it. Each is a distinct source and the card says which, because the action
/// differs: an auto-flag with no human report is often a false positive to dismiss,
/// a pile of manual reports usually is not.
///
/// The three verbs map straight to `PATCH /api/admin/reviews/:id`:
///   • Hide    → take it off the venue/profile (still restorable).
///   • Restore → put a hidden review back.
///   • Dismiss → "this is fine" — clear the flag, leave the review visible.
/// Hiding or restoring changes trust/venue inputs, so the backend recomputes those in
/// the same transaction. After any action we reload from the server, which is the
/// authority on what remains in the queue.
class AdminModerationScreen extends StatefulWidget {
  const AdminModerationScreen({super.key});

  @override
  State<AdminModerationScreen> createState() => _AdminModerationScreenState();
}

enum _Filter { all, reported, auto, hidden }

class _AdminModerationScreenState extends State<AdminModerationScreen> {
  final ReviewService _service = ReviewService();

  List<FlaggedReview> _queue = [];
  final Set<String> _busy = {}; // review ids with an action in flight
  bool _loading = true;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _token => Provider.of<AuthProvider>(context, listen: false).token;

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final q = await _service.moderationQueue(token);
    if (!mounted) return;
    setState(() {
      _queue = q;
      _loading = false;
    });
  }

  List<FlaggedReview> get _visible {
    switch (_filter) {
      case _Filter.reported:
        return _queue.where((r) => r.hasManualReports).toList();
      case _Filter.auto:
        return _queue.where((r) => r.isAutoFlagged).toList();
      case _Filter.hidden:
        return _queue.where((r) => r.hidden).toList();
      case _Filter.all:
        return _queue;
    }
  }

  Future<void> _act(FlaggedReview r, String action) async {
    final token = _token;
    if (token == null) return;
    setState(() => _busy.add(r.id));
    final res = await _service.moderate(token, r.id, action);
    if (!mounted) return;
    setState(() => _busy.remove(r.id));
    if (res['success'] == true) {
      SnackbarUtil.showSuccess(context, res['message']?.toString() ?? 'Done.');
      await _load();
    } else {
      SnackbarUtil.showError(context, res['message']?.toString() ?? 'Action failed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _visible;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Moderation', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : Column(
              children: [
                _filterBar(),
                Expanded(
                  child: RefreshIndicator(
                    color: AppColors.accent,
                    onRefresh: _load,
                    child: list.isEmpty
                        ? MatchEmptyState(
                            icon: Icons.verified_user_outlined,
                            text: _queue.isEmpty
                                ? 'Queue is clear.\nNo reviews are waiting for moderation.'
                                : 'Nothing in this filter.',
                          )
                        : ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                            padding: const EdgeInsets.all(16),
                            itemCount: list.length,
                            itemBuilder: (_, i) => _card(list[i]),
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _filterBar() {
    Widget chip(_Filter f, String label, int count) {
      final on = _filter == f;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => setState(() => _filter = f),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: on ? AppColors.primary : AppColors.cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: on ? AppColors.primary : AppColors.border),
            ),
            child: Text(
              '$label ($count)',
              style: GoogleFonts.poppins(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: on ? Colors.white : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    final reported = _queue.where((r) => r.hasManualReports).length;
    final auto = _queue.where((r) => r.isAutoFlagged).length;
    final hidden = _queue.where((r) => r.hidden).length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: AppColors.background,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip(_Filter.all, 'All', _queue.length),
            chip(_Filter.reported, 'Reported', reported),
            chip(_Filter.auto, 'Auto-flagged', auto),
            chip(_Filter.hidden, 'Hidden', hidden),
          ],
        ),
      ),
    );
  }

  Widget _card(FlaggedReview r) {
    final busy = _busy.contains(r.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: r.hidden ? AppColors.error.withValues(alpha: 0.4) : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Subject + status chips
          Row(
            children: [
              Icon(r.isOpponent ? Icons.sports_handball_rounded : Icons.stadium_rounded,
                  size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  r.isOpponent ? 'Conduct review of ${r.subjectLabel}' : 'Review of ${r.subjectLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (r.hidden) _statusChip('HIDDEN', AppColors.error),
            ],
          ),
          const SizedBox(height: 12),
          // Reviewer line
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.inputFill,
                child: Text(
                  (r.reviewerName?.trim().isNotEmpty == true ? r.reviewerName!.trim()[0] : '?').toUpperCase(),
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.reviewerName ?? 'A user',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              StarsDisplay(rating: r.stars.toDouble(), size: 14),
            ],
          ),
          if (r.createdAt != null) ...[
            const SizedBox(height: 4),
            Text(
              _ago(r.createdAt!),
              style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
            ),
          ],
          // Review text
          if (r.text != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.inputFill,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                r.text!,
                style: GoogleFonts.poppins(fontSize: 13, height: 1.45, color: AppColors.textPrimary),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // Sentiment verdict
          Align(
            alignment: Alignment.centerLeft,
            child: SentimentChip(
              label: r.sentimentLabel,
              score: r.sentimentScore,
              flagged: r.flagged && !r.hasManualReports,
            ),
          ),
          const SizedBox(height: 12),
          _reports(r),
          const SizedBox(height: 14),
          _actions(r, busy),
        ],
      ),
    );
  }

  Widget _reports(FlaggedReview r) {
    if (r.hasManualReports) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${r.openFlagCount > 0 ? r.openFlagCount : r.flags.length} '
            'report${(r.openFlagCount > 0 ? r.openFlagCount : r.flags.length) == 1 ? '' : 's'}',
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: AppColors.warning,
            ),
          ),
          const SizedBox(height: 6),
          ...r.flags.take(4).map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.outlined_flag, size: 13, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${f.reason ?? 'No reason given'}'
                        '${f.flaggedByName != null ? ' · ${f.flaggedByName}' : ''}',
                        style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      );
    }
    // Model escalation, no human report.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Text('🤖', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Auto-flagged by the sentiment model — no human report. '
              'Dismiss if it reads fine.',
              style: GoogleFonts.poppins(fontSize: 11.5, height: 1.35, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(FlaggedReview r, bool busy) {
    if (busy) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.accent),
          ),
        ),
      );
    }
    if (r.hidden) {
      return Row(
        children: [
          Expanded(child: _actionBtn('Restore', Icons.visibility_outlined, AppColors.accent, () => _act(r, 'restore'))),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: _actionBtn('Hide', Icons.visibility_off_outlined, AppColors.error, () => _act(r, 'hide'))),
        const SizedBox(width: 10),
        Expanded(child: _actionBtn('Dismiss', Icons.check_circle_outline, AppColors.textSecondary, () => _act(r, 'dismiss'), outlined: true)),
      ],
    );
  }

  Widget _actionBtn(String label, IconData icon, Color color, VoidCallback onTap, {bool outlined = false}) {
    return SizedBox(
      height: 42,
      child: outlined
          ? OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 17, color: color),
              label: Text(label,
                  style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: color.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            )
          : ElevatedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 17, color: Colors.white),
              label: Text(label,
                  style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
    );
  }

  Widget _statusChip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: GoogleFonts.poppins(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: color),
        ),
      );

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${(d.inDays / 7).floor()}w ago';
  }
}
