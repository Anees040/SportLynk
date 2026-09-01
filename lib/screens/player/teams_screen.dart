import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/team.dart';
import '../../models/tournament.dart' show TeamTournamentRecord;
import '../../providers/auth_provider.dart';
import '../../services/realtime_service.dart';
import '../../services/team_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/tournament_widgets.dart' show TeamRecordLine;
import '../shared/chat_thread_screen.dart';
import 'create_team_screen.dart';
import 'match_center_screen.dart';
import 'team_rankings_screen.dart';

/// The user's teams — the WhatsApp "Chats" tab of SportLynk. Each row opens the
/// team's group chat directly; group info (roster, roles, invites) lives one tap
/// deeper, inside the chat, exactly like WhatsApp. A team can also be joined here
/// by pasting an invite link.
class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key});
  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  final _service = TeamService();
  late Future<List<Team>> _future;
  StreamSubscription? _sub;

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _service.mine(_token);
  }

  @override
  void initState() {
    super.initState();
    // A team I'm added to / removed from elsewhere should surface here without a
    // manual pull-to-refresh.
    _sub = RealtimeService().teamUpdates.listen((_) {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _future = _service.mine(_token));

  Future<void> _openChat(Team t) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen.team(
          teamId: t.id,
          teamName: t.name,
          channelId: t.channelId,
          logoUrl: t.logoUrl,
        ),
      ),
    );
    _reload(); // membership may have changed (e.g. left from group info)
  }

  // Join with an invite link
  Future<void> _joinByLink() async {
    final ctrl = TextEditingController();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Join with link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Paste the invite link a captain shared with you.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'sportlynk://team/join/…',
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    // Accept either the full deep link or a bare token.
    final raw = ctrl.text.trim();
    final invite = raw.contains('/') ? raw.split('/').last.trim() : raw;
    if (invite.isEmpty || !mounted) return;

    final preview = await _service.previewInvite(_token, invite);
    if (!mounted) return;
    if (preview['success'] != true || preview['data'] is! Map) {
      SnackbarUtil.showError(
          context, preview['message']?.toString() ?? 'That link is invalid or expired.');
      return;
    }
    final data = Map<String, dynamic>.from(preview['data'] as Map);
    final teamName = '${data['name'] ?? 'this team'}';
    final members = asNum(data['member_count']);
    final sport = data['sport'] != null ? '${data['sport']}'.toUpperCase() : '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Join $teamName?'),
        content: Text(
          '$members member${members == 1 ? '' : 's'}${sport.isEmpty ? '' : ' · $sport'}',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final join = await _service.joinByToken(_token, invite);
    if (!mounted) return;
    if (join['success'] == true && join['data'] is Map) {
      final jd = Map<String, dynamic>.from(join['data'] as Map);
      SnackbarUtil.showSuccess(context, 'Welcome to $teamName!');
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen.team(
            teamId: '${jd['teamId']}',
            teamName: teamName,
            channelId: jd['channelId']?.toString(),
          ),
        ),
      );
      _reload();
    } else {
      SnackbarUtil.showError(
          context, join['message']?.toString() ?? 'Could not join this team.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Teams'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: 'Join with link',
            icon: const Icon(Icons.link),
            onPressed: _joinByLink,
          ),
          IconButton(
            tooltip: 'Rankings',
            icon: const Icon(Icons.emoji_events_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const TeamRankingsScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New team'),
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const CreateTeamScreen()));
          _reload();
        },
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<Team>>(
          future: _future,
          builder: (context, s) {
            if (s.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (s.hasError) return _empty('Could not load your teams', Icons.cloud_off);
            final teams = s.data ?? [];
            if (teams.isEmpty) {
              return _empty(
                  'Create a team to start competing and chatting together.\n\nGot an invite link? Tap the link icon above.',
                  Icons.groups_outlined);
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: teams.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _card(teams[i]),
            );
          },
        ),
      ),
    );
  }

  Widget _empty(String text, IconData icon) => ListView(
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * .2),
          Icon(icon, size: 64, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16, color: AppColors.textSecondary, height: 1.4)),
          ),
        ],
      );

  Widget _card(Team t) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openChat(t),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 27,
                  backgroundColor: AppColors.inputFill,
                  backgroundImage: (t.logoUrl != null && t.logoUrl!.isNotEmpty)
                      ? CachedNetworkImageProvider(t.logoUrl!)
                      : null,
                  child: (t.logoUrl == null || t.logoUrl!.isEmpty)
                      ? const Icon(Icons.shield_outlined, color: AppColors.primary)
                      : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.name,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(
                          '${t.sport.toUpperCase()}  •  ${t.role?.replaceAll('_', ' ') ?? 'member'}',
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      const SizedBox(height: 8),
                      Row(children: [
                        _stat('ELO', t.elo),
                        _stat('W', t.wins),
                        _stat('L', t.losses),
                        _stat('D', t.draws),
                      ]),
                      // Counted achievements rather than a second rating: a
                      // tournament match moves this same ELO harder (K 40–56)
                      // instead of feeding a separate ladder, so "2 titles" is
                      // what distinguishes a cup squad. The line hides
                      // itself for a team that has never entered one.
                      if (!t.tournamentRecord.isEmpty) ...[
                        const SizedBox(height: 6),
                        TeamRecordLine(t.tournamentRecord, dense: true),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chat_bubble_outline, color: AppColors.accent.withValues(alpha: 0.8)),
                // Matches are per-team, so the way in is from a team — not a
                // global tab that would have to ask which one every time.
                IconButton(
                  tooltip: 'Match Center',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.sports_kabaddi, color: AppColors.primary),
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            MatchCenterScreen(teamId: t.id, teamName: t.name),
                      ),
                    );
                    _reload();
                  },
                ),
              ],
            ),
          ),
        ),
      );

  Widget _stat(String label, num value) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Text('$label $value',
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary)),
      );
}
