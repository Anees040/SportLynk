import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/match.dart';
import '../../models/team.dart';
import '../../providers/auth_provider.dart';
import '../../services/match_service.dart';
import '../../services/team_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';
import 'create_team_screen.dart';
import 'match_challenge_screen.dart';

/// Opponent discovery (FR5.3 – FR5.5).
///
/// The list is always *relative to one of my teams*, which is the change that
/// makes it useful: closest rating first (FR5.3), a competitiveness score per row
/// (FR5.4), and the opponent roster's trust badge (FR5.5) — none of which mean
/// anything without a "my team" to compare against.
///
/// That is also why the sport chips are gone. Sport is no longer a browsing filter
/// but a property of the pairing: my football team can only play football teams,
/// and the backend refuses a cross-sport challenge outright. Switching which team
/// I am playing as is what switches the sport now, and it does so honestly.
class FindOpponentsScreen extends StatefulWidget {
  /// Pre-selects the team to search on behalf of — passed when arriving from a
  /// team's Match Center, so the user does not re-pick what they just tapped.
  final String? teamId;

  const FindOpponentsScreen({super.key, this.teamId});

  @override
  State<FindOpponentsScreen> createState() => _FindOpponentsScreenState();
}

class _FindOpponentsScreenState extends State<FindOpponentsScreen> {
  final _matches = MatchService();
  final _teams = TeamService();
  final _searchCtrl = TextEditingController();

  String get _token => context.read<AuthProvider>().token ?? '';

  List<Team>? _myTeams;
  String? _teamId;
  String _query = '';

  bool _loadingTeams = true;
  bool _loadingList = false;
  OpponentList _list = OpponentList.empty;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _teamId = widget.teamId;
    // A frame late so `context.read` is legal and the first paint is the spinner.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final mine = await _teams.mine(_token);
    if (!mounted) return;
    setState(() {
      _myTeams = mine;
      _loadingTeams = false;
      // Keep an explicitly passed team; otherwise default to the first one the
      // user actually captains, since that is the only team they can challenge
      // with — landing on a team whose Challenge buttons are all disabled would
      // read as the feature being broken.
      if (_teamId == null || !mine.any((t) => t.id == _teamId)) {
        final captained = mine.where((t) => t.role == 'captain');
        _teamId = captained.isNotEmpty
            ? captained.first.id
            : (mine.isNotEmpty ? mine.first.id : null);
      }
    });
    if (_teamId != null) await _load();
  }

  Future<void> _load() async {
    final id = _teamId;
    if (id == null) return;
    setState(() {
      _loadingList = true;
      _failed = false;
    });
    final r = await _matches.opponents(_token, id, q: _query.isEmpty ? null : _query);
    if (!mounted) return;
    setState(() {
      _list = r;
      _loadingList = false;
      // An empty payload with no team echoed back means the read itself failed
      // (offline, or not a member any more) — distinct from "nobody to play".
      _failed = r.myTeam == null;
    });
  }

  void _pickTeam(String id) {
    if (id == _teamId) return;
    setState(() {
      _teamId = id;
      _list = OpponentList.empty;
    });
    _load();
  }

  Future<void> _challenge(OpponentCandidate c) async {
    final myId = _teamId;
    final mine = _list.myTeam;
    if (myId == null || mine == null) return;

    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MatchChallengeScreen(
          myTeamId: myId,
          myTeam: mine,
          opponent: c.team,
        ),
      ),
    );
    if (sent == true && mounted) {
      // The opponent is now off the list (a live match holds the pairing), so a
      // re-read is not cosmetic.
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Find Opponents',
          style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _loadingTeams
          ? const Center(child: CircularProgressIndicator())
          : (_myTeams == null || _myTeams!.isEmpty)
              ? MatchEmptyState(
                  icon: Icons.groups_outlined,
                  text:
                      'Matchmaking works team-to-team.\n\nCreate or join a team first, then come back to find opponents at your level.',
                  action: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                    icon: const Icon(Icons.add),
                    label: const Text('Create a team'),
                    onPressed: () async {
                      await Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const CreateTeamScreen()));
                      if (mounted) _bootstrap();
                    },
                  ),
                )
              : Column(
                  children: [
                    _teamStrip(),
                    _searchField(),
                    if (_list.myTeam != null && !_list.canChallenge) _captainNotice(),
                    Expanded(child: _body()),
                  ],
                ),
    );
  }

  // ── Header ─────────────────────────────────────────────────

  /// "Playing as" — the whole list is relative to this choice, so it sits above
  /// everything and shows my own standing next to the picker.
  Widget _teamStrip() {
    final teams = _myTeams!;
    final me = _list.myTeam;

    return Container(
      width: double.infinity,
      color: AppColors.primary,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PLAYING AS',
            style: GoogleFonts.poppins(
              fontSize: 9.5,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 8),
          if (teams.length > 1)
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: teams.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final t = teams[i];
                  final on = t.id == _teamId;
                  return GestureDetector(
                    onTap: () => _pickTeam(t.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on ? AppColors.accent : Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        t.name,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: on ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            )
          else
            Text(
              teams.first.name,
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          if (me != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    me.ranked ? 'ELO ${me.elo}' : 'Unranked',
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                Text(
                  me.record,
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
                if (me.eloFrozen)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.ac_unit, size: 12, color: AppColors.warning),
                      const SizedBox(width: 3),
                      Text(
                        'Rating frozen',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.warning,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: TextField(
          controller: _searchCtrl,
          textInputAction: TextInputAction.search,
          onSubmitted: (v) {
            _query = v.trim();
            _load();
          },
          decoration: InputDecoration(
            hintText: 'Search teams…',
            prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
            suffixIcon: _searchCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchCtrl.clear();
                      _query = '';
                      _load();
                    },
                  ),
            filled: true,
            fillColor: AppColors.inputFill,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );

  /// FR2.10 allows more than one captain, and only a captain may issue a
  /// challenge. Saying so up front beats letting every button fail with a 403.
  Widget _captainNotice() => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Only a captain can send challenges. You can still scout who is out there.',
                style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
      );

  // ── List ───────────────────────────────────────────────────

  Widget _body() {
    if (_loadingList && _list.opponents.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return RefreshIndicator(
        onRefresh: _load,
        child: const MatchEmptyState(
          icon: Icons.cloud_off,
          text: 'Could not load opponents. Pull down to try again.',
        ),
      );
    }

    final list = _list.opponents;
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: MatchEmptyState(
          icon: _query.isEmpty ? Icons.sports_soccer : Icons.search_off,
          text: _query.isEmpty
              ? 'No public teams available to challenge right now.\n\nTeams already booked into a live match with you are hidden until it finishes.'
              : 'No teams match "$_query".',
        ),
      );
    }

    // FR5.3 — the server orders by |rating gap| ascending, so every in-band team
    // is already ahead of every out-of-band one. The divider just names the
    // boundary the ordering has produced; it is not a second sort.
    final firstOutOfBand = list.indexWhere((o) => !o.withinBand);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        itemCount: list.length,
        itemBuilder: (_, i) => Column(
          children: [
            if (i == firstOutOfBand && i > 0) _bandDivider(),
            _opponentCard(list[i]),
          ],
        ),
      ),
    );
  }

  Widget _bandDivider() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            const Expanded(child: Divider(color: AppColors.border)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'OUTSIDE YOUR ±${_list.preferredBand} RANGE',
                style: GoogleFonts.poppins(
                  fontSize: 9,
                  letterSpacing: 0.9,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const Expanded(child: Divider(color: AppColors.border)),
          ],
        ),
      );

  Widget _opponentCard(OpponentCandidate c) {
    final t = c.team;
    final subtitle = [
      if (t.city != null && t.city!.isNotEmpty) t.city!,
      if (t.memberCount != null) '${t.memberCount} member${t.memberCount == 1 ? '' : 's'}',
      t.record,
    ].join('  ·  ');

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: c.withinBand
              ? AppColors.accent.withValues(alpha: 0.35)
              : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TeamCrest(logoUrl: t.logoUrl, radius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              EloPill(side: t),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TrustBadgeChip(
                band: t.trustBand,
                label: t.trustLabel,
                score: t.trustScore,
                showScore: true,
              ),
              const SizedBox(width: 6),
              if (t.ranked && _list.myTeam?.ranked == true)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.inputFill,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${c.eloGap} apart',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          CompetitivenessBar(
            score: c.competitiveness,
            unrankedNote: t.ranked
                ? 'Your team needs a verified match first'
                : 'They have no verified matches yet',
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: _list.canChallenge
                ? FilledButton.icon(
                    icon: const Icon(Icons.sports_kabaddi, size: 16),
                    label: const Text('Challenge'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    onPressed: () => _challenge(c),
                  )
                : OutlinedButton.icon(
                    icon: const Icon(Icons.lock_outline, size: 16),
                    label: const Text('Captains only'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: const BorderSide(color: AppColors.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    onPressed: () => SnackbarUtil.showInfo(context,
                        'Ask a captain of ${_list.myTeam?.name ?? 'your team'} to send this challenge.'),
                  ),
          ),
        ],
      ),
    );
  }
}
