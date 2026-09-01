import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_service.dart';
import '../../widgets/match_widgets.dart';
import 'admin_dispute_detail_screen.dart';

/// The dispute queue (FR10.6). Every match whose two captains filed different
/// results, newest stake first.
///
/// The order is the server's and so is the severity. `severityElo` is the rating
/// that moves if this case is ruled — computed by the backend with the
/// same pure `elo.rate()` the match engine uses, at the live K factor. The queue is
/// sorted by it and only then by age, which is why the cursor is a
/// `"<severityElo>~<createdAt>~<id>"` triple and is passed back untouched. Nothing
/// here recomputes any of that: two teams 300 points apart produce a very
/// different number from two teams level, and a screen that guessed would triage
/// the wrong case first.
class AdminDisputesScreen extends StatefulWidget {
  const AdminDisputesScreen({super.key});

  @override
  State<AdminDisputesScreen> createState() => _AdminDisputesScreenState();
}

class _AdminDisputesScreenState extends State<AdminDisputesScreen> {
  final AdminService _service = AdminService();

  /// Server vocabulary, not a local enum — these strings go in the query string.
  static const _statuses = <String, String>{
    'open': 'Open',
    'resolved': 'Resolved',
    'dismissed': 'Dismissed',
    'all': 'All',
  };

  final List<DisputeRow> _rows = [];
  String _status = 'open';
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;

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
    final page = await _service.disputes(token, status: _status);
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
    final cursor = _cursor;
    if (token == null || cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    final page = await _service.disputes(token, status: _status, cursor: cursor);
    if (!mounted) return;
    setState(() {
      _rows.addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _loadingMore = false;
    });
  }

  Future<void> _open(DisputeRow row) async {
    final ruled = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AdminDisputeDetailScreen(disputeId: row.id),
      ),
    );
    if (!mounted) return;
    // A ruling closes the case and every sibling dispute on the same match, so the
    // queue is re-read rather than patched in place.
    if (ruled == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Disputes',
            style: GoogleFonts.poppins(
                color: Colors.white, fontWeight: FontWeight.bold)),
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
                    child: _rows.isEmpty
                        ? MatchEmptyState(
                            icon: Icons.gavel_outlined,
                            text: _status == 'open'
                                ? 'No open disputes.\nEvery result the captains disagreed on has been ruled.'
                                : 'Nothing with this status.',
                          )
                        : ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(
                                parent: BouncingScrollPhysics()),
                            padding: const EdgeInsets.all(16),
                            itemCount: _rows.length + (_hasMore ? 1 : 0),
                            itemBuilder: (_, i) =>
                                i >= _rows.length ? _moreButton() : _card(_rows[i]),
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _filterBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: AppColors.background,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _statuses.entries.map((e) {
            final on = _status == e.key;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: on
                    ? null
                    : () {
                        setState(() => _status = e.key);
                        _load();
                      },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: on ? AppColors.primary : AppColors.cardBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: on ? AppColors.primary : AppColors.border),
                  ),
                  child: Text(
                    e.value,
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: on ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _moreButton() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accent),
              )
            : OutlinedButton(
                onPressed: _loadMore,
                child: Text('Load more',
                    style: GoogleFonts.poppins(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
      ),
    );
  }

  /// Red / amber / grey by what is at stake. The thresholds are display-only — the
  /// order already came from the server, this just makes the top of the list look
  /// like the top of the list.
  static Color _severityColor(int elo) {
    if (elo >= 24) return AppColors.error;
    if (elo >= 12) return AppColors.warning;
    return AppColors.textSecondary;
  }

  Widget _card(DisputeRow d) {
    final sev = _severityColor(d.severityElo);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(d),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: sev.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.trending_up_rounded, size: 13, color: sev),
                          const SizedBox(width: 4),
                          Text('${d.severityElo} pts at stake',
                              style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: sev)),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Text(d.ageLabel,
                        style: GoogleFonts.poppins(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
                const SizedBox(height: 10),
                _teamsRow(d),
                if (d.reason != null) ...[
                  const SizedBox(height: 10),
                  Text(d.reason!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
                const SizedBox(height: 10),
                _chips(d),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _teamsRow(DisputeRow d) {
    Widget side(DisputeTeam t, {required bool alignRight}) {
      return Expanded(
        child: Column(
          crossAxisAlignment:
              alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment:
                  alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                if (!alignRight) TeamCrest(logoUrl: t.logoUrl, radius: 14),
                if (!alignRight) const SizedBox(width: 7),
                Flexible(
                  child: Text(t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: alignRight ? TextAlign.right : TextAlign.left,
                      style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                ),
                if (alignRight) const SizedBox(width: 7),
                if (alignRight) TeamCrest(logoUrl: t.logoUrl, radius: 14),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              t.frozen ? '${t.elo} · frozen' : '${t.elo}',
              style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: t.frozen ? AppColors.warning : AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        side(d.challenger, alignRight: false),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: [
              Text(d.match.scoreline ?? 'vs',
                  style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              Text('${d.match.resultsIn}/2 filed',
                  style: GoogleFonts.poppins(
                      fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ),
        side(d.opponent, alignRight: true),
      ],
    );
  }

  Widget _chips(DisputeRow d) {
    Widget chip(String label, IconData icon, Color color) => Container(
          margin: const EdgeInsets.only(right: 6, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ],
          ),
        );

    return Wrap(
      children: [
        MatchStatusChip(status: d.match.status),
        const SizedBox(width: 6),
        if (d.match.isFixture)
          chip(d.match.tournamentName ?? 'Tournament fixture',
              Icons.emoji_events_outlined, AppColors.primary),
        if (d.bothSidesDisputed)
          chip('Both sides disputed', Icons.people_alt_outlined, AppColors.error),
        // An already-rated match needs the ruling to correct points rather than
        // award them. Flagged here so the admin knows before they open the case.
        if (d.match.eloApplied)
          chip('Already rated', Icons.history_rounded, AppColors.warning),
        if (d.raisedByTeamName != null)
          chip('Raised by ${d.raisedByTeamName}', Icons.flag_outlined,
              AppColors.textSecondary),
        if (!d.isOpen && d.ruling != null)
          chip('Ruled: ${d.ruling}', Icons.gavel_rounded, AppColors.success),
      ],
    );
  }
}
