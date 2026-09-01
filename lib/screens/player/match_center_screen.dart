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
import '../../widgets/match_result_dialog.dart';
import '../../widgets/match_widgets.dart';
import '../shared/chat_thread_screen.dart';
import 'find_opponents_screen.dart';
import 'rate_experience_screen.dart';

/// A team's Match Center (FR5.16) — challenges, fixtures, and results in one place.
///
/// Three tabs because a match means three different things depending on where it
/// is: a decision (accept or decline, on a 48-hour clock), a commitment (be at the
/// pitch, then report the score), and a record (what it did to the rating, and
/// whether it was right). Mixing those into one feed would bury the only tab that
/// is ever urgent.
///
/// Opened from the team's chat header rather than the bottom bar. Matches are
/// per-team, and a fifth global tab would have had to ask "which team?" every
/// time — the same question the caller has already answered.
class MatchCenterScreen extends StatefulWidget {
  final String teamId;
  /// Nullable since S.7 Wave C: a notification deep link carries the match's
  /// `teamId` but not always a name (`notificationTypes.matchLink` only forwards
  /// what the emitting call site put in its payload). The screen loads the team
  /// anyway, so the name is a header nicety, not a prerequisite -- and requiring it
  /// would have forced the deep-link route to invent a placeholder like "My team"
  /// and show that instead of nothing.
  final String? teamName;

  const MatchCenterScreen({super.key, required this.teamId, this.teamName});

  @override
  State<MatchCenterScreen> createState() => _MatchCenterScreenState();
}

class _MatchCenterScreenState extends State<MatchCenterScreen>
    with SingleTickerProviderStateMixin {
  final _service = MatchService();
  late final TabController _tabs = TabController(length: 3, vsync: this);

  StreamSubscription? _sub;
  MatchCenterData _data = MatchCenterData.empty;
  bool _loading = true;
  bool _failed = false;

  /// Ids currently mid-flight, so a double tap cannot send two responses.
  final _busy = <String>{};

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    // `match:update` carries only an id, so any of them means "re-read". A captain
    // watching this screen while the other side accepts should see it land.
    _sub = RealtimeService().matchUpdates.listen((_) {
      if (mounted) _load(silent: true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final d = await _service.center(_token, widget.teamId);
    if (!mounted) return;
    setState(() {
      _data = d;
      _loading = false;
      _failed = d.teamId.isEmpty;
    });
  }

  // Actions

  Future<void> _respond(MatchModel m, String action) async {
    if (_busy.contains(m.id)) return;

    if (action == 'reject') {
      final sure = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Decline this challenge?',
              style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16)),
          content: Text(
            '${m.challenger.name} will be told you declined. They can challenge again with a different slot.',
            style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.error),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Decline'),
            ),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }

    setState(() => _busy.add(m.id));
    final r = await _service.respond(_token, m.id, action);
    if (!mounted) return;
    setState(() => _busy.remove(m.id));

    if (r['success'] == true) {
      SnackbarUtil.showSuccess(
        context,
        action == 'accept'
            ? 'Match on. ${m.challenger.name} has been told.'
            : 'Challenge declined.',
      );
      await _load(silent: true);
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not send your response.');
    }
  }

  Future<void> _submitResult(MatchModel m) async {
    final ok = await showMatchResultSheet(context, match: m, token: _token);
    if (ok == true && mounted) await _load(silent: true);
  }

  Future<void> _dispute(MatchModel m) async {
    final ok = await showMatchDisputeSheet(
      context,
      match: m,
      token: _token,
      windowHours: _data.disputeWindowHours,
    );
    if (ok == true && mounted) await _load(silent: true);
  }

  Future<void> _findOpponents() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FindOpponentsScreen(teamId: widget.teamId)),
    );
    if (mounted) _load(silent: true);
  }

  // Frame

  @override
  Widget build(BuildContext context) {
    final pending = _data.pendingCount;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Match Center',
                style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
            if ((widget.teamName ?? '').isNotEmpty)
              Text(
                widget.teamName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.accent,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white.withValues(alpha: 0.6),
          labelStyle: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.bold),
          unselectedLabelStyle: GoogleFonts.poppins(fontSize: 12.5),
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Challenges'),
                  if (pending > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$pending',
                          style: GoogleFonts.poppins(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: 'Upcoming'),
            const Tab(text: 'History'),
          ],
        ),
      ),
      floatingActionButton: _data.amCaptain
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.sports_kabaddi),
              label: const Text('Challenge'),
              onPressed: _findOpponents,
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? RefreshIndicator(
                  onRefresh: _load,
                  child: const MatchEmptyState(
                    icon: Icons.cloud_off,
                    text: 'Could not load matches. Pull down to try again.',
                  ),
                )
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _challengesTab(),
                    _listTab(
                      _data.upcoming,
                      icon: Icons.event_available,
                      empty:
                          'No confirmed matches yet.\n\nOnce a challenge is accepted it appears here with the venue and kickoff time.',
                      builder: _upcomingCard,
                    ),
                    _listTab(
                      _data.history,
                      icon: Icons.history,
                      empty:
                          'Nothing played yet.\n\nVerified results land here with the points they moved.',
                      builder: _historyCard,
                    ),
                  ],
                ),
    );
  }

  Widget _listTab(
    List<MatchModel> items, {
    required IconData icon,
    required String empty,
    required Widget Function(MatchModel) builder,
  }) =>
      RefreshIndicator(
        onRefresh: _load,
        child: items.isEmpty
            ? MatchEmptyState(icon: icon, text: empty)
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
                itemCount: items.length,
                itemBuilder: (_, i) => builder(items[i]),
              ),
      );

  // Tab 1 · Challenges

  Widget _challengesTab() {
    final incoming = _data.incoming;
    final outgoing = _data.outgoing;

    if (incoming.isEmpty && outgoing.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: MatchEmptyState(
          icon: Icons.mail_outline,
          text: _data.amCaptain
              ? 'No open challenges.\n\nFind a team at your level and send one — it stays open for 48 hours.'
              : 'No open challenges right now.',
          action: _data.amCaptain
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                  icon: const Icon(Icons.search),
                  label: const Text('Find opponents'),
                  onPressed: _findOpponents,
                )
              : null,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
        children: [
          if (incoming.isNotEmpty) ...[
            _sectionLabel('TO ANSWER', incoming.length),
            ...incoming.map(_incomingCard),
            const SizedBox(height: 6),
          ],
          if (outgoing.isNotEmpty) ...[
            _sectionLabel('SENT', outgoing.length),
            ...outgoing.map(_outgoingCard),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String text, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          '$text · $count',
          style: GoogleFonts.poppins(
            fontSize: 9.5,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      );

  Widget _incomingCard(MatchModel m) {
    final busy = _busy.contains(m.id);
    final canAct = _data.amCaptain;

    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _opponentRow(m, m.challenger, 'CHALLENGED YOU'),
          const SizedBox(height: 10),
          _slotLine(m),
          const SizedBox(height: 10),
          CompetitivenessBar(score: m.competitiveness, compact: true),
          if ((m.previewText ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            MatchPreviewBlock(label: m.previewLabel, text: m.previewText!),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              ChallengeCountdown(expiresAt: m.challengeExpiresAt),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 10),
          if (canAct)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: BorderSide(color: AppColors.error.withValues(alpha: 0.4)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: busy ? null : () => _respond(m, 'reject'),
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: busy ? null : () => _respond(m, 'accept'),
                    child: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text('Accept',
                            style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            )
          else
            _hint('A captain needs to answer this one.', Icons.lock_outline),
        ],
      ),
    );
  }

  Widget _outgoingCard(MatchModel m) => _shell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _opponentRow(m, m.opponent, 'WAITING ON THEM'),
            const SizedBox(height: 10),
            _slotLine(m),
            const SizedBox(height: 10),
            Row(
              children: [
                ChallengeCountdown(expiresAt: m.challengeExpiresAt, compact: true),
                const Spacer(),
                MatchStatusChip(status: m.shownStatus),
              ],
            ),
          ],
        ),
      );

  // Tab 2 · Upcoming

  /// Open the match's coordination room.
  ///
  /// The room was created when the challenge was accepted, so no id is resolved
  /// first — the thread screen asks the server for it and says plainly when there
  /// is none (a match accepted before chat shipped). The team is passed through so
  /// the thread header can offer the jump back to the match centre.
  void _openCoordinate(MatchModel m) {
    final where = m.venueName;
    final when = m.slotDateLabel;
    final line = [?when, ?where].join(' · ');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen.forMatch(
          matchId: m.id,
          title: 'vs ${m.theirTeam.name}',
          contextLine: line.isEmpty ? null : line,
          teamId: m.myTeamId,
          teamName: m.myTeam.name,
        ),
      ),
    );
  }

  Widget _upcomingCard(MatchModel m) {
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _opponentRow(m, m.theirTeam, 'VS'),
          const SizedBox(height: 10),
          _slotLine(m),
          const SizedBox(height: 10),
          Row(
            children: [
              MatchStatusChip(status: m.shownStatus),
              const SizedBox(width: 8),
              if (m.competitiveness != null)
                Expanded(child: CompetitivenessBar(score: m.competitiveness, compact: true)),
            ],
          ),
          const SizedBox(height: 12),

          // Coordinate
          // Where "which gate?" and "we're ten minutes out" belong. Shown only to
          // the people the room admits — both teams' captains and
          // vice-captains — so it is never a tap into a room the viewer is not in.
          if (_data.isTeamOfficial) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openCoordinate(m),
                icon: const Icon(Icons.forum_outlined, size: 16),
                label: const Text('Coordinate'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.accent),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],

          if (m.canSubmitResult)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.scoreboard_outlined, size: 17),
                label: const Text('Submit result'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
                onPressed: _data.amCaptain
                    ? () => _submitResult(m)
                    : () => SnackbarUtil.showInfo(
                        context, 'Only a captain can report the score.'),
              ),
            )
          else if (m.waitingOnOwner)
            _hint(
                'Both captains agreed. ${m.isTournamentMatch ? 'The organiser' : (m.venueName ?? 'The venue')} is verifying — ratings move once they do.',
                Icons.verified_user_outlined)
          else if (m.waitingOnOpponent)
            _hint('Your score is in. Waiting for ${m.theirTeam.name} to report theirs.',
                Icons.hourglass_bottom)
          else if (!m.slotStarted)
            _hint('You can report the score once kickoff has passed.',
                Icons.schedule),
        ],
      ),
    );
  }

  // Tab 3 · History

  Widget _historyCard(MatchModel m) {
    final won = m.iWon;
    final accent = m.isDisputed
        ? AppColors.error
        : m.isDead
            ? AppColors.textSecondary
            : m.isDraw
                ? AppColors.warning
                : won == true
                    ? AppColors.success
                    : won == false
                        ? AppColors.error
                        : AppColors.textSecondary;

    return _shell(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TeamCrest(logoUrl: m.theirTeam.logoUrl, radius: 19),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.theirTeam.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _historySubtitle(m),
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (m.isCompleted && m.myScore != null)
                Text(
                  '${m.myScore} – ${m.theirScore}',
                  style: GoogleFonts.poppins(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              MatchStatusChip(status: m.shownStatus),
              const SizedBox(width: 8),
              if (m.isCompleted)
                EloDeltaChip(delta: m.myDelta, frozen: m.myTeam.eloFrozen),
              const Spacer(),
              // Captain-to-captain conduct review (M24). Only a captain, only after
              // the match is done, and only if it is tied to a booking the backend
              // can derive the opposing captain from.
              if (_data.amCaptain && m.isCompleted && m.booking != null)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.sports_handball_rounded, size: 15),
                  label: Text('Rate',
                      style: GoogleFonts.poppins(
                          fontSize: 11.5, fontWeight: FontWeight.w600)),
                  onPressed: () {
                    final b = m.booking!;
                    final when = b.slotDate == null
                        ? null
                        : '${b.slotDate!.day}/${b.slotDate!.month}/${b.slotDate!.year}';
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => RateExperienceScreen(
                        bookingId: b.id,
                        opponentTeamName: m.theirTeam.name,
                        canReviewVenue: false,
                        canReviewOpponent: true,
                        dateLabel: when,
                      ),
                    ));
                  },
                ),
              // FR5.17 — the flag only exists while it can still be acted on. A
              // permanently visible icon that silently starts failing after a day
              // is worse than no icon.
              if (m.canDispute(_data.disputeWindowHours) && _data.amCaptain)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.error,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.flag_outlined, size: 15),
                  label: Text('Flag',
                      style: GoogleFonts.poppins(
                          fontSize: 11.5, fontWeight: FontWeight.w600)),
                  onPressed: () => _dispute(m),
                ),
            ],
          ),
          if (m.isDisputed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _hint(
                'Under review. No ratings move on a disputed match until an admin resolves it.',
                Icons.gavel,
                color: AppColors.error,
              ),
            ),
        ],
      ),
    );
  }

  String _historySubtitle(MatchModel m) {
    final stage = m.tournament?.stageLine;
    return [?m.slotDateLabel, ?m.venueName, ?stage].join('  ·  ');
  }

  // Shared bits

  Widget _shell({required Widget child, Color? accent}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
          // A hairline in the result's colour, so a scan down History reads
          // won/lost/disputed without stopping on any one row.
          boxShadow: accent == null
              ? null
              : [BoxShadow(color: accent.withValues(alpha: 0.14), blurRadius: 0, spreadRadius: 0.6)],
        ),
        child: child,
      );

  Widget _opponentRow(MatchModel m, MatchSide side, String tag) => Row(
        children: [
          TeamCrest(logoUrl: side.logoUrl, radius: 21),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tag,
                  style: GoogleFonts.poppins(
                    fontSize: 8.5,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  side.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 14.5,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          EloPill(side: side),
        ],
      );

  Widget _slotLine(MatchModel m) {
    if (m.hasNoSlot) {
      return _hint(
          m.isTournamentMatch
              ? 'This fixture has no slot yet.'
              : 'The linked booking is no longer available.',
          Icons.error_outline,
          color: AppColors.warning);
    }
    final when = m.slotDateLabel ?? '';
    final stage = m.tournament?.stageLine;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.stadium_outlined, size: 15, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.venueName ?? 'Venue',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  '$when  ·  ${m.timeRange}',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                // Which cup and which round. A knockout captain's next question
                // after "where" is always "what is this one for" — and the one
                // after that is "who do I play if I win", which is the bracket,
                // so the line is the way through to it.
                if (stage != null && stage.isNotEmpty)
                  InkWell(
                    onTap: () => Navigator.pushNamed(
                      context,
                      '/tournament-detail',
                      arguments: {'tournamentId': m.tournament!.id},
                    ),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            stage,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 13, color: AppColors.accent),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint(String text, IconData icon, {Color color = AppColors.textSecondary}) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.poppins(fontSize: 11.5, height: 1.4, color: color),
            ),
          ),
        ],
      );
}
