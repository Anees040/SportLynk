import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/reco.dart';
import '../../providers/auth_provider.dart';
import '../../services/team_service.dart';
import '../../utils/snackbar_util.dart';

/// Invite specific players into a team (migration 039).
///
/// The captain-side counterpart to "Find a team to join": a squad short of players
/// browses recommended players — the same rating/activity-ranked rail the roster
/// screen shows — and sends a direct invite that lands in the player's inbox. A row
/// becomes "Invited" on success and stays that way on a 409 (an invite already
/// stands) and across revisits, read from the team's pending invites on load.
class InvitePlayersScreen extends StatefulWidget {
  final String teamId;
  final String teamName;
  const InvitePlayersScreen({super.key, required this.teamId, required this.teamName});

  @override
  State<InvitePlayersScreen> createState() => _InvitePlayersScreenState();
}

class _InvitePlayersScreenState extends State<InvitePlayersScreen> {
  final TeamService _service = TeamService();
  final TextEditingController _search = TextEditingController();

  late final String _token;
  List<PlayerSuggestion>? _players;
  bool _loading = true;
  String? _error;
  String _query = '';
  final Set<String> _invited = <String>{};
  final Set<String> _sending = <String>{};

  @override
  void initState() {
    super.initState();
    _token = context.read<AuthProvider>().token ?? '';
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    // The ranked recommendations (the roster rail's own endpoint) and the invites
    // already sent, so a player we have invited reads "Invited" on first paint.
    final sug = await _service.suggestedPlayers(_token, widget.teamId);
    final sent = await _service.sentPlayerInvites(_token, widget.teamId);
    if (!mounted) return;
    if (sug == null) {
      setState(() { _loading = false; _error = 'Could not load players. Pull to retry.'; });
      return;
    }
    final invited = <String>{};
    if (sent['success'] == true) {
      for (final r in (sent['data'] as List? ?? const [])) {
        if (r is Map && r['user_id'] != null) invited.add(r['user_id'].toString());
      }
    }
    setState(() {
      _players = sug.suggestions;
      _invited
        ..clear()
        ..addAll(invited);
      _loading = false;
    });
  }

  Future<void> _invite(PlayerSuggestion p) async {
    final id = p.userId;
    if (id.isEmpty || _sending.contains(id) || _invited.contains(id)) return;
    setState(() => _sending.add(id));
    final r = await _service.invitePlayer(_token, widget.teamId, id);
    if (!mounted) return;
    final ok = r['success'] == true;
    // A 409 means an invite to this player already stands; the button should read
    // "Invited" either way, so both outcomes mark the row invited.
    final duplicate = !ok && r['statusCode'] == 409;
    setState(() {
      _sending.remove(id);
      if (ok || duplicate) _invited.add(id);
    });
    if (ok) {
      SnackbarUtil.showSuccess(context, 'Invite sent to ${p.name}.');
    } else if (duplicate) {
      SnackbarUtil.showInfo(context, '${p.name} already has an invite.');
    } else {
      SnackbarUtil.showError(context, r['message']?.toString() ?? 'Could not send the invite.');
    }
  }

  List<PlayerSuggestion> get _filtered {
    final all = _players ?? const <PlayerSuggestion>[];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Invite players'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search players by name',
              prefixIcon: const Icon(Icons.search, size: 20),
              filled: true,
              fillColor: AppColors.inputFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.border),
              ),
            ),
          ),
        ),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return _centered(Icons.cloud_off_rounded, error, TextButton.icon(
          onPressed: _load, icon: const Icon(Icons.refresh, size: 18), label: const Text('Try again')));
    }
    final players = _filtered;
    if (players.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          const SizedBox(height: 120),
          _centered(Icons.person_search_outlined,
              _query.isEmpty
                  ? 'No players to recommend right now.\nShare your invite link instead.'
                  : 'No players match "${_query.trim()}".',
              null),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: players.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (_, i) => _row(players[i]),
      ),
    );
  }

  Widget _row(PlayerSuggestion p) {
    final id = p.userId;
    final name = p.name;
    final sports = p.sports.isEmpty ? 'Player' : p.sports.join(' · ');
    final pct = p.matchPct;
    final url = (p.avatarUrl ?? '').trim();
    final avatar = url.isEmpty ? null : CachedNetworkImageProvider(url);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.inputFill,
          foregroundImage: avatar,
          child: avatar == null ? const Icon(Icons.person, color: AppColors.textSecondary) : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 2),
            Text(pct == null ? sports : '$sports  ·  $pct% match',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ]),
        ),
        const SizedBox(width: 12),
        _inviteButton(id, p),
      ]),
    );
  }

  Widget _inviteButton(String id, PlayerSuggestion p) {
    if (_sending.contains(id)) {
      return const SizedBox(
        width: 92, height: 36,
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (_invited.contains(id)) {
      return const SizedBox(
        width: 92, height: 36,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.check, size: 16, color: AppColors.textSecondary),
          SizedBox(width: 4),
          Text('Invited', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        ]),
      );
    }
    return SizedBox(
      width: 92, height: 36,
      child: FilledButton(
        onPressed: () => _invite(p),
        style: FilledButton.styleFrom(padding: EdgeInsets.zero, backgroundColor: AppColors.primary),
        child: const Text('Invite', style: TextStyle(fontSize: 13)),
      ),
    );
  }

  Widget _centered(IconData icon, String text, Widget? action) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: AppColors.textSecondary),
          const SizedBox(height: 14),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, height: 1.4)),
          if (action != null) ...[const SizedBox(height: 10), action],
        ]),
      ),
    );
  }
}
