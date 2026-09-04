// admin_dispute_detail_screen.dart — D5 / FR10.6, FR10.7.
//
// The case file. Everything an admin needs to overrule two captains, on one
// screen, in the order a human reads it: what each side claims, whether
// they agree, who was on the pitch, what the venue's check-in says, what the two
// of them said to each other in the captain channel, and what the ratings did.
//
// The screen decides nothing. Severity, the age, whether a correction is even
// possible, which submissions exist, whether the bracket has moved on — all of it
// arrives from `GET /api/admin/disputes/:id`. The five ruling actions are offered
// or disabled from `capabilities` and from the presence of a submission, because
// the server refuses the same cases (`'That team never submitted a result, so
// there is nothing to adopt.'`) and a button that fails on submit is worse than a
// button that is visibly unavailable with the reason next to it.
//
// A NOTE is mandatory, server-side, minimum three characters. It is quoted to both
// captains and stored in `admin_audit`, so the dialog asks for it rather than
// letting the admin discover the 400.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';

class AdminDisputeDetailScreen extends StatefulWidget {
  const AdminDisputeDetailScreen({super.key, required this.disputeId});

  final String disputeId;

  @override
  State<AdminDisputeDetailScreen> createState() =>
      _AdminDisputeDetailScreenState();
}

class _AdminDisputeDetailScreenState extends State<AdminDisputeDetailScreen> {
  final _svc = AdminService();

  DisputeCase? _case;
  bool _loading = true;
  bool _ruling = false;

  String? get _token =>
      Provider.of<AuthProvider>(context, listen: false).token;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    setState(() => _loading = true);
    final c = await _svc.disputeCase(token, widget.disputeId);
    if (!mounted) return;
    setState(() {
      _case = c;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _case;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Dispute', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : c == null
              ? const Center(
                  child: MatchEmptyState(
                    text: 'This case could not be loaded.',
                    icon: Icons.gavel_outlined,
                  ),
                )
              : RefreshIndicator(
                  color: AppColors.accent,
                  onRefresh: _load,
                  child: _body(c),
                ),
      bottomNavigationBar: c == null ? null : _rulingBar(c),
    );
  }

  Widget _body(DisputeCase c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _headerCard(c),
        const SizedBox(height: 12),
        _submissionsCard(c),
        const SizedBox(height: 12),
        if (c.booking != null) ...[_bookingCard(c.booking!), const SizedBox(height: 12)],
        _rosterCard(c),
        const SizedBox(height: 12),
        if (c.eloHistory.isNotEmpty) ...[_eloCard(c), const SizedBox(height: 12)],
        _chatCard(c),
        if (c.otherDisputes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _relatedCard(c),
        ],
        if (!c.dispute.isOpen) ...[const SizedBox(height: 12), _rulingRecordCard(c.dispute)],
      ],
    );
  }

  // Shared shell
  Widget _card({required String title, String? hint, required Widget child, Widget? trailing}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(
              hint,
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _kv(String k, String v, {Color? color, bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              k,
              style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: color ?? AppColors.textPrimary,
                fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Text(
            text,
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // 1 · What is at stake
  Widget _headerCard(DisputeCase c) {
    final d = c.dispute;
    final m = d.match;
    return _card(
      title: '${d.challenger.name}  vs  ${d.opponent.name}',
      hint: '${m.sport ?? 'match'} · raised ${d.ageLabel}'
          '${d.raisedByTeamName != null ? ' by ${d.raisedByTeamName}' : ''}',
      trailing: MatchStatusChip(status: m.status),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill('${d.severityElo} pts at stake', AppColors.warning, icon: Icons.trending_up),
              _pill('${m.resultsIn}/2 filed', AppColors.textSecondary),
              if (c.submissionsAgree)
                _pill('Both sides agree', AppColors.success, icon: Icons.check)
              else if (c.submissionCount == 2)
                _pill('Submissions conflict', AppColors.error, icon: Icons.close),
              if (d.bothSidesDisputed)
                _pill('Both sides disputed', AppColors.error, icon: Icons.flag_outlined),
              if (m.eloApplied)
                _pill('Ratings already applied', AppColors.error, icon: Icons.lock_outline),
              if (m.isFixture)
                _pill(m.tournamentName ?? 'Tournament fixture', AppColors.accent,
                    icon: Icons.emoji_events_outlined),
              if (d.challenger.frozen || d.opponent.frozen)
                _pill('Rating frozen', AppColors.warning, icon: Icons.ac_unit),
            ],
          ),
          const SizedBox(height: 10),
          _kv('Reason given', (d.reason ?? '').trim().isEmpty ? '—' : d.reason!.trim()),
          if (d.raisedByCaptainName != null)
            _kv('Raised by', '${d.raisedByCaptainName} · ${d.raisedByTeamName ?? ''}'),
          _kv('Recorded result', m.scoreline ?? 'none on the match yet', mono: true),
          _kv('Ratings now',
              '${d.challenger.name} ${d.challenger.elo}  ·  '
              '${d.opponent.name} ${d.opponent.elo}',
              mono: true),
        ],
      ),
    );
  }

  // 2 · Side by side
  /// The two `match_results` rows next to each other. `UNIQUE (match_id,
  /// submitted_by_team)` guarantees at most one per side, so a missing column is
  /// a side that never filed — which is itself the evidence, and is said out loud
  /// rather than left blank.
  Widget _submissionsCard(DisputeCase c) {
    return _card(
      title: 'What each side filed',
      hint: c.submissionsAgree
          ? 'Both submissions match — the disagreement is about something else.'
          : c.submissionCount == 2
              ? 'The two submissions do not match.'
              : 'Only one side filed a result.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _submissionColumn(
              c.dispute.challenger, c.challengerSubmission, 'Challenger'),
          ),
          Container(width: 1, height: 96, color: AppColors.border),
          Expanded(
            child: _submissionColumn(
              c.dispute.opponent, c.opponentSubmission, 'Opponent'),
          ),
        ],
      ),
    );
  }

  Widget _submissionColumn(DisputeTeam team, DisputeSubmission? s, String role) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          TeamCrest(logoUrl: team.logoUrl, radius: 18),
          const SizedBox(height: 6),
          Text(
            team.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          Text(
            role,
            style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            s?.scoreline ?? '—',
            style: GoogleFonts.poppins(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: s == null ? AppColors.textSecondary : AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s == null
                ? 'never filed'
                : s.captainName != null
                    ? 'filed by ${s.captainName}'
                    : 'filed',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
          ),
          if (s?.submittedAt != null)
            Text(
              _stamp(s!.submittedAt!),
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }

  // 3 · The venue's evidence
  /// Check-in is the only third-party fact in the case: the owner scanned a QR (or
  /// did not) at a time neither captain controls. It outranks both submissions
  /// when they disagree, so it gets its own card rather than a line in a summary.
  Widget _bookingCard(CaseBooking b) {
    final checked = b.checkedInAt != null;
    return _card(
      title: 'Venue evidence',
      hint: '${b.venueName ?? 'venue'}'
          '${b.venueCity != null ? ' · ${b.venueCity}' : ''}',
      trailing: _pill(
        checked ? (b.hadQr ? 'QR check-in' : 'manual check-in') : 'no check-in',
        checked
            ? (b.hadQr ? AppColors.success : AppColors.warning)
            : AppColors.error,
        icon: checked ? Icons.verified_outlined : Icons.help_outline,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Slot', '${b.slotDate ?? '—'}  ${b.startTime ?? ''}–${b.endTime ?? ''}',
              mono: true),
          _kv('Booking status', b.status),
          if (b.checkedInAt != null) _kv('Checked in', _stamp(b.checkedInAt!)),
          if (b.noShowAt != null)
            _kv('Marked no-show', _stamp(b.noShowAt!), color: AppColors.error),
          if (b.cancellationReason != null) _kv('Cancelled', b.cancellationReason!),
          _kv('Price', 'PKR ${b.totalAmount.toStringAsFixed(0)}'
              ' · deposit ${b.depositAmount.toStringAsFixed(0)}', mono: true),
          if (b.ownerName != null)
            _kv('Owner', '${b.ownerName}${b.ownerPhone != null ? ' · ${b.ownerPhone}' : ''}'),
        ],
      ),
    );
  }

  // 4 · Who was on the pitch
  Widget _rosterCard(DisputeCase c) {
    return _card(
      title: 'Rosters',
      hint: 'Trust score is the platform’s, not a rating. A dash means never rated.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _rosterBlock(c.dispute.challenger.name, c.challengerRoster),
          const SizedBox(height: 10),
          _rosterBlock(c.dispute.opponent.name, c.opponentRoster),
        ],
      ),
    );
  }

  Widget _rosterBlock(String teamName, List<RosterMember> members) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          teamName,
          style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        if (members.isEmpty)
          Text(
            'No members on record.',
            style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
          )
        else
          ...members.map(
            (m) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    m.isCaptain
                        ? Icons.star
                        : m.isViceCaptain
                            ? Icons.star_border
                            : Icons.person_outline,
                    size: 14,
                    color: m.isCaptain ? AppColors.accent : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: m.isCaptain ? FontWeight.w600 : FontWeight.w400,
                        decoration: m.suspended ? TextDecoration.lineThrough : null,
                        color: m.suspended ? AppColors.textSecondary : AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (m.suspended) ...[
                    _pill('suspended', AppColors.error),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    m.trustScore == null ? '—' : m.trustScore!.toStringAsFixed(0),
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      color: AppColors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // 5 · What the ratings already did
  /// `elo_history` for this match. Present only when the rating was applied before
  /// the dispute landed, which is exactly the case where a ruling must reverse
  /// before it re-applies — so the admin sees the exchange they are about to undo.
  Widget _eloCard(DisputeCase c) {
    return _card(
      title: 'Rating already exchanged',
      hint: 'A ruling reverses these and re-applies the ruled result.',
      child: Column(
        children: c.eloHistory
            .map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.teamName ?? e.teamId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(fontSize: 12),
                      ),
                    ),
                    Text(
                      '${e.before ?? '—'} → ${e.after ?? '—'}',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    EloDeltaChip(delta: e.delta),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  // 6 · The captain channel, archived
  /// FR10.6 verbatim: the chat log is part of the evidence. A tombstone stays in
  /// the transcript as "message deleted" — a deletion after a dispute was raised
  /// is itself worth seeing, and silently dropping the row would hide it.
  Widget _chatCard(DisputeCase c) {
    return _card(
      title: 'Captain channel',
      hint: c.chatChannelId == null
          ? 'No captain channel exists for this match.'
          : c.chatTruncated
              ? 'Showing the most recent messages — the log is longer.'
              : '${c.chat.length} message${c.chat.length == 1 ? '' : 's'}',
      child: c.chat.isEmpty
          ? Text(
              'Nothing was said in this channel.',
              style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
            )
          : Column(
              children: c.chat
                  .map((m) => _chatLine(m, c.dispute.challenger.id))
                  .toList(),
            ),
    );
  }

  Widget _chatLine(ArchiveMessage m, String challengerTeamId) {
    if (m.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Text(
            m.body ?? '',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      );
    }
    final mine = m.teamId != null && m.teamId == challengerTeamId;
    final body = m.deleted
        ? 'message deleted'
        : (m.body ?? '').trim().isNotEmpty
            ? m.body!.trim()
            : m.hasMedia
                ? '[${m.mediaMime ?? 'attachment'}]'
                : '';
    return Align(
      alignment: mine ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 250),
        decoration: BoxDecoration(
          color: mine ? AppColors.accent.withValues(alpha: 0.08) : AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            Text(
              m.senderName ?? 'unknown',
              style: GoogleFonts.poppins(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              body,
              style: GoogleFonts.poppins(
                fontSize: 12,
                fontStyle: m.deleted ? FontStyle.italic : FontStyle.normal,
                color: m.deleted ? AppColors.textSecondary : AppColors.textPrimary,
              ),
            ),
            if (m.createdAt != null)
              Text(
                _stamp(m.createdAt!),
                style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }

  // 7 · Siblings, and the record once it is closed
  Widget _relatedCard(DisputeCase c) {
    return _card(
      title: 'Other disputes on this match',
      hint: 'One ruling closes all of them.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: c.otherDisputes
            .map(
              (r) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pill(r.status, AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${r.teamName ?? 'a team'} — ${(r.reason ?? '').trim().isEmpty ? 'no reason given' : r.reason!.trim()}',
                        style: GoogleFonts.poppins(fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _rulingRecordCard(DisputeRow d) {
    final ruled = d.ruledScoreChallenger != null && d.ruledScoreOpponent != null;
    return _card(
      title: 'How it was ruled',
      trailing: _pill(d.ruling ?? d.status, AppColors.accent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ruled)
            _kv('Ruled scoreline',
                '${d.ruledScoreChallenger}–${d.ruledScoreOpponent}', mono: true),
          if (d.resolvedByName != null) _kv('Ruled by', d.resolvedByName!),
          if (d.resolvedAt != null) _kv('Ruled at', _stamp(d.resolvedAt!)),
          if (d.resolutionNotes != null) _kv('Note', d.resolutionNotes!),
        ],
      ),
    );
  }

  // The ruling bar
  /// Offered only while the dispute is open and the server says this admin may
  /// rule. `canChangeResult` is the narrower gate: when the rating was already
  /// applied, changing the result means reversing it, and that needs migration
  /// 022's columns — `correctionBlockedBy` names the file if they are missing.
  /// `dismiss` is exempt because it changes no result at all.
  Widget? _rulingBar(DisputeCase c) {
    if (!c.dispute.isOpen) return null;
    final caps = c.capabilities;
    if (!caps.canRule) return null;
    final blocked = !caps.canChangeResult;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (blocked)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: AppColors.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'The rating was already applied and this database cannot reverse '
                        'it yet (${caps.correctionBlockedBy ?? 'a migration is missing'}). '
                        'Only Dismiss is available.',
                        style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ruling ? null : () => _confirm(c, 'dismiss'),
                    icon: const Icon(Icons.block, size: 16),
                    label: const Text('Dismiss'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _ruling || blocked ? null : () => _pickRuling(c),
                    icon: _ruling
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.gavel, size: 16),
                    label: Text(_ruling ? 'Ruling…' : 'Rule this dispute'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The four result-changing actions. Adopting a side is offered only when that
  /// side filed a scoreline — the server refuses otherwise with
  /// "there is nothing to adopt", and this sheet says so before the round trip.
  Future<void> _pickRuling(DisputeCase c) async {
    final cs = c.challengerSubmission;
    final os = c.opponentSubmission;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(
              'Which result stands?',
              style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _rulingTile(
              sheetContext,
              icon: Icons.arrow_back,
              title: '${c.dispute.challenger.name}’s result',
              subtitle: cs?.scoreline == null
                  ? 'They never filed a scoreline'
                  : 'Adopt ${cs!.scoreline}',
              enabled: cs?.scoreline != null,
              value: 'rule_challenger',
            ),
            _rulingTile(
              sheetContext,
              icon: Icons.arrow_forward,
              title: '${c.dispute.opponent.name}’s result',
              subtitle: os?.scoreline == null
                  ? 'They never filed a scoreline'
                  : 'Adopt ${os!.scoreline}',
              enabled: os?.scoreline != null,
              value: 'rule_opponent',
            ),
            _rulingTile(
              sheetContext,
              icon: Icons.horizontal_rule,
              title: 'A draw',
              subtitle: c.hasDrawnSubmission
                  ? 'Adopt the drawn scoreline that was filed'
                  : 'You will be asked for the drawn scoreline',
              enabled: true,
              value: 'rule_draw',
            ),
            _rulingTile(
              sheetContext,
              icon: Icons.edit_outlined,
              title: 'A scoreline of your own',
              subtitle: 'Neither submission stands',
              enabled: true,
              value: 'rule_custom',
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    await _confirm(c, action);
  }

  Widget _rulingTile(
    BuildContext sheetContext, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    required String value,
  }) {
    return ListTile(
      enabled: enabled,
      leading: Icon(icon, size: 20, color: enabled ? AppColors.accent : AppColors.textSecondary),
      title: Text(
        title,
        style: GoogleFonts.poppins(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: enabled ? AppColors.textPrimary : AppColors.textSecondary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
      ),
      onTap: enabled ? () => Navigator.pop(sheetContext, value) : null,
    );
  }

  /// The confirm dialog. It collects the mandatory note, and a scoreline when the
  /// action needs one — `rule_custom` always, `rule_draw` only when no drawn
  /// submission exists to adopt (the server never invents 0–0). The bounds here
  /// are the server's own: 0–200, and equal halves for a draw.
  Future<void> _confirm(DisputeCase c, String action) async {
    final needsScore = action == 'rule_custom' ||
        (action == 'rule_draw' && !c.hasDrawnSubmission);
    final note = TextEditingController();
    final scA = TextEditingController();
    final scB = TextEditingController();
    String? error;

    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            _actionTitle(action, c),
            style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _actionBlurb(action, c),
                  style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
                ),
                if (needsScore) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _scoreField(scA, c.dispute.challenger.name)),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('–'),
                      ),
                      Expanded(child: _scoreField(scB, c.dispute.opponent.name)),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 1000,
                  style: GoogleFonts.poppins(fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Why (both captains are told)',
                    labelStyle: GoogleFonts.poppins(fontSize: 12),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.error),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text('Cancel', style: GoogleFonts.poppins(fontSize: 13)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: action == 'dismiss' ? AppColors.textSecondary : AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                final problem = _validate(action, needsScore, note.text, scA.text, scB.text);
                if (problem != null) {
                  setLocal(() => error = problem);
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              child: Text(
                action == 'dismiss' ? 'Dismiss it' : 'Rule it',
                style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );

    if (go != true || !mounted) return;
    await _submit(
      action: action,
      note: note.text.trim(),
      scoreChallenger: needsScore ? int.tryParse(scA.text.trim()) : null,
      scoreOpponent: needsScore ? int.tryParse(scB.text.trim()) : null,
    );
  }

  Widget _scoreField(TextEditingController c, String label) {
    return TextField(
      controller: c,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
      style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.poppins(fontSize: 10),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  /// The same rules the service applies, checked here so the admin is told before
  /// the round trip rather than by a 400.
  String? _validate(String action, bool needsScore, String note, String a, String b) {
    if (note.trim().length < 3) {
      return 'A note is required — it is quoted to both captains.';
    }
    if (!needsScore) return null;
    final x = int.tryParse(a.trim());
    final y = int.tryParse(b.trim());
    if (x == null || y == null) return 'Both scores are needed.';
    if (x < 0 || y < 0 || x > 200 || y > 200) return 'Scores must be between 0 and 200.';
    if (action == 'rule_draw' && x != y) return 'A drawn ruling needs an equal scoreline.';
    return null;
  }

  String _actionTitle(String action, DisputeCase c) {
    switch (action) {
      case 'rule_challenger':
        return 'Rule for ${c.dispute.challenger.name}';
      case 'rule_opponent':
        return 'Rule for ${c.dispute.opponent.name}';
      case 'rule_draw':
        return 'Rule a draw';
      case 'rule_custom':
        return 'Rule your own scoreline';
      default:
        return 'Dismiss this dispute';
    }
  }

  /// What this action will do, said before it is taken. The rating clause
  /// is the one an admin most needs: on a match that was already rated, a ruling
  /// reverses the old exchange and applies the new one, and every open dispute on
  /// the match closes with it.
  String _actionBlurb(String action, DisputeCase c) {
    if (action == 'dismiss') {
      return 'The result the teams filed stands, ratings are untouched, and the match '
          'goes back to whoever still has to finish it. '
          '${_alsoCloses(c)}';
    }
    final rated = c.dispute.match.eloApplied
        ? 'The rating already applied will be reversed and re-applied on this result. '
        : 'Ratings will be applied on this result. ';
    final bracket = c.dispute.match.isFixture
        ? 'If the bracket has not moved past this fixture, it advances. '
        : '';
    return '$rated${bracket}Both captains are notified and told your note. '
        '${_alsoCloses(c)}';
  }

  String _alsoCloses(DisputeCase c) => c.otherDisputes.isEmpty
      ? 'This cannot be undone from the app.'
      : '${c.otherDisputes.length + 1} disputes on this match close together. '
          'This cannot be undone from the app.';

  Future<void> _submit({
    required String action,
    required String note,
    int? scoreChallenger,
    int? scoreOpponent,
  }) async {
    final token = _token;
    if (token == null) return;
    setState(() => _ruling = true);
    final res = await _svc.ruleDispute(
      token,
      widget.disputeId,
      action: action,
      scoreChallenger: scoreChallenger,
      scoreOpponent: scoreOpponent,
      note: note,
    );
    if (!mounted) return;
    setState(() => _ruling = false);

    final ok = res['success'] == true;
    final message = (res['message'] ?? '').toString().trim();
    if (!ok) {
      SnackbarUtil.showError(
        context,
        message.isEmpty ? 'The ruling could not be saved.' : message,
      );
      // A refusal is usually a fact that changed underneath the screen -- another
      // admin ruled first, or the bracket moved -- so the case is re-read.
      await _load();
      return;
    }
    SnackbarUtil.showSuccess(
      context,
      message.isEmpty ? 'Ruling saved.' : message,
    );
    Navigator.pop(context, true);
  }

  /// `YYYY-MM-DD HH:MM`, local. Short enough to sit under a chat bubble, precise
  /// enough to order two submissions filed minutes apart.
  String _stamp(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
