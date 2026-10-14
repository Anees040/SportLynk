import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/match.dart' show LinkableBooking;
import '../../models/open_challenge.dart';
import '../../models/team.dart';
import '../../providers/auth_provider.dart';
import '../../services/match_service.dart';
import '../../services/open_challenge_service.dart';
import '../../services/team_service.dart';
import '../../utils/reconnect_refresh.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart' show MatchEmptyState, TeamCrest;
import '../../widgets/network_error_view.dart';

/// The Live Challenge Feed (item 9 / "Open Cards"). A public board of confirmed
/// slots captains have offered to any opponent: browse them, claim one to lock a
/// match instantly, or post one of your own confirmed bookings.
///
/// Claiming reuses the ordinary match flow server-side — the first captain to accept
/// locks the slot and a captains' prep room opens — so a claimed card and a direct
/// challenge are the same fixture afterwards.
class OpenChallengesScreen extends StatefulWidget {
  const OpenChallengesScreen({super.key});

  @override
  State<OpenChallengesScreen> createState() => _OpenChallengesScreenState();
}

class _OpenChallengesScreenState extends State<OpenChallengesScreen>
    with ReconnectRefresh<OpenChallengesScreen> {
  final _svc = OpenChallengeService();
  final _teams = TeamService();
  final _matches = MatchService();

  String get _token => context.read<AuthProvider>().token ?? '';

  List<OpenChallenge>? _cards; // null while first load runs / after a failure
  bool _loading = true;
  bool _failed = false;

  /// The viewer's teams, loaded once to decide which cards they can accept and
  /// whether they can post. Only teams they captain can act.
  List<Team> _myTeams = const [];

  final Set<String> _busy = {}; // open-challenge ids with an action in flight

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadTeams();
    });
  }

  @override
  void onReconnect() {
    if (_failed) _load();
  }

  Future<void> _loadTeams() async {
    final mine = await _teams.mine(_token);
    if (mounted) setState(() => _myTeams = mine);
  }

  Future<void> _load() async {
    setState(() {
      _loading = _cards == null;
      _failed = false;
    });
    final cards = await _svc.board(_token);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = cards == null;
      if (cards != null) _cards = cards;
    });
  }

  /// My teams that captain-eligibly match [sport] and are not [excludeTeamId].
  List<Team> _eligibleTeams(String sport, {String? excludeTeamId}) {
    final s = sport.toLowerCase();
    return _myTeams
        .where((t) =>
            t.role == 'captain' &&
            t.sport.toLowerCase() == s &&
            t.id != excludeTeamId)
        .toList();
  }

  // Accept

  Future<void> _accept(OpenChallenge card) async {
    if (_busy.contains(card.id)) return;
    final eligible = _eligibleTeams(card.sport, excludeTeamId: card.team.id);
    if (eligible.isEmpty) {
      SnackbarUtil.showInfo(context,
          'You need to captain a ${card.sport} team (other than theirs) to accept this.');
      return;
    }
    final team = eligible.length == 1
        ? eligible.first
        : await _pickTeam('Accept as which team?', eligible);
    if (team == null || !mounted) return;
    await _doClaim(card, team.id);
  }

  Future<void> _doClaim(OpenChallenge card, String teamId) async {
    setState(() => _busy.add(card.id));
    final r = await _svc.claim(_token, openId: card.id, teamId: teamId);
    if (!mounted) return;
    setState(() => _busy.remove(card.id));
    if (r['success'] == true) {
      SnackbarUtil.showSuccess(
          context, r['message']?.toString() ?? 'Match locked. Coordinate in the captains\' room.');
      _load();
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not accept this challenge.');
      // A 409 (claimed/taken/withdrawn) means the board moved on — refresh it.
      if (r['statusCode'] == 409) _load();
    }
  }

  // Withdraw my own card

  Future<void> _withdraw(OpenChallenge card) async {
    if (_busy.contains(card.id)) return;
    setState(() => _busy.add(card.id));
    final r = await _svc.cancel(_token, card.id);
    if (!mounted) return;
    setState(() => _busy.remove(card.id));
    if (r['success'] == true) {
      SnackbarUtil.showSuccess(context, 'Open challenge withdrawn.');
      _load();
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not withdraw this.');
      if (r['statusCode'] == 409) _load();
    }
  }

  // Post a slot

  Future<void> _post() async {
    final captained = _myTeams.where((t) => t.role == 'captain').toList();
    if (captained.isEmpty) {
      SnackbarUtil.showInfo(context,
          'Only a team captain can post a slot. Create a team first.');
      return;
    }
    final team = captained.length == 1
        ? captained.first
        : await _pickTeam('Post as which team?', captained);
    if (team == null || !mounted) return;

    final bookings = await _matches.linkableBookings(_token, team.id);
    if (!mounted) return;
    if (bookings.isEmpty) {
      SnackbarUtil.showInfo(context,
          'No confirmed upcoming booking to post. Book a slot for ${team.name} first, '
          'then offer it here.');
      return;
    }
    final booking = await _pickBooking(bookings);
    if (booking == null || !mounted) return;

    final r = await _svc.post(_token, teamId: team.id, bookingId: booking.id);
    if (!mounted) return;
    if (r['success'] == true) {
      SnackbarUtil.showSuccess(context,
          r['message']?.toString() ?? 'Your slot is on the open board.');
      _load();
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not post this slot.');
    }
  }

  Future<Team?> _pickTeam(String title, List<Team> teams) {
    return showModalBottomSheet<Team>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(title,
                  style: GoogleFonts.poppins(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            ...teams.map((t) => ListTile(
                  leading: TeamCrest(logoUrl: t.logoUrl, radius: 18),
                  title: Text(t.name, style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                  subtitle: Text('${t.sport.toUpperCase()} · ELO ${t.elo}',
                      style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                  onTap: () => Navigator.pop(context, t),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<LinkableBooking?> _pickBooking(List<LinkableBooking> bookings) {
    return showModalBottomSheet<LinkableBooking>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Which booking do you want to offer?',
                  style: GoogleFonts.poppins(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            ...bookings.map((b) => ListTile(
                  leading: const Icon(Icons.event_available, color: AppColors.accent),
                  title: Text(b.venueName ?? 'Venue',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                  subtitle: Text('${b.prettyDate}  ·  ${b.timeRange}',
                      style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                  onTap: () => Navigator.pop(context, b),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Open Challenges',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.campaign_outlined),
        label: const Text('Post a slot'),
        onPressed: _post,
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading && _cards == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed && _cards == null) {
      return NetworkErrorView(
        message: 'Could not load the open challenge board. Check your connection and try again.',
        onRetry: _load,
      );
    }
    final cards = _cards ?? const [];
    if (cards.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: const MatchEmptyState(
          icon: Icons.sports_kabaddi,
          text: 'No open challenges right now.\n\nPost one of your confirmed slots with '
              '"Post a slot", or check back — the first team to accept locks the match.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: cards.length,
        itemBuilder: (_, i) => _card(cards[i]),
      ),
    );
  }

  Widget _card(OpenChallenge c) {
    final busy = _busy.contains(c.id);
    final when = [
      if ((c.booking.slotDate ?? '').isNotEmpty) c.booking.slotDate!,
      if ((c.booking.startTime ?? '').isNotEmpty) _to12(c.booking.startTime!),
    ].join('  ·  ');

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: c.mine ? AppColors.accent.withValues(alpha: 0.4) : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TeamCrest(logoUrl: c.team.logoUrl, radius: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.team.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        c.sport.toUpperCase(),
                        if (c.team.city != null && c.team.city!.isNotEmpty) c.team.city!,
                        c.team.record,
                      ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _OpenEloPill(elo: c.team.elo, played: c.team.played),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow(Icons.place_outlined,
              [c.booking.venueName, c.booking.venueCity].where((e) => (e ?? '').isNotEmpty).join(', ')),
          const SizedBox(height: 6),
          _infoRow(Icons.schedule, when.isEmpty ? 'Upcoming slot' : when),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: c.mine
                ? OutlinedButton.icon(
                    onPressed: busy ? null : () => _withdraw(c),
                    icon: busy
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.close, size: 16),
                    label: Text(busy ? 'Withdrawing…' : 'Withdraw (your post)',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: const BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                  )
                : FilledButton.icon(
                    onPressed: busy ? null : () => _accept(c),
                    icon: busy
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.sports_kabaddi, size: 16),
                    label: Text(busy ? 'Locking…' : 'Accept challenge',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text.isEmpty ? '—' : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary)),
          ),
        ],
      );

  String _to12(String t) {
    final parts = t.split(':');
    if (parts.length < 2) return t;
    var h = int.tryParse(parts[0]) ?? 0;
    final m = parts[1];
    final ampm = h >= 12 ? 'PM' : 'AM';
    if (h == 0) {
      h = 12;
    } else if (h > 12) {
      h -= 12;
    }
    return '$h:$m $ampm';
  }
}

/// A compact ELO pill that reads "Unranked" before a team has a played record,
/// matching the honesty rule the rest of matchmaking follows (no invented rating).
class _OpenEloPill extends StatelessWidget {
  final int elo;
  final int played;
  const _OpenEloPill({required this.elo, required this.played});

  @override
  Widget build(BuildContext context) {
    final ranked = played > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ranked ? AppColors.accentLight : AppColors.inputFill,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        ranked ? 'ELO $elo' : 'Unranked',
        style: GoogleFonts.poppins(
          fontSize: 11.5,
          fontWeight: FontWeight.bold,
          color: ranked ? AppColors.primary : AppColors.textSecondary,
        ),
      ),
    );
  }
}
