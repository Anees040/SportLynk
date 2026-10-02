import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/team.dart';
import '../../providers/auth_provider.dart';
import '../../services/team_service.dart';
import '../../utils/snackbar_util.dart';

/// Browse PUBLIC teams and ask to join one.
///
/// The backend has had the whole join path for a while — `GET /teams/discover` lists
/// public teams the caller is not already in, and `POST /teams/:id/join-request`
/// files a request the captain approves on the roster screen — but nothing in the app
/// let a player reach it except an invite link a captain had to send first. This screen
/// is the missing front door: a player finds a public team themselves and requests in,
/// which is also where Scout's `find_teams` recommendations are meant to land.
///
/// A request is one-way and idempotent. The button becomes "Requested" on success and
/// stays that way on a 409 (a pending request already stands), so a double tap cannot
/// read as a failure. Approval happens on the captain's side; this screen only asks.
class DiscoverTeamsScreen extends StatefulWidget {
  const DiscoverTeamsScreen({super.key});

  @override
  State<DiscoverTeamsScreen> createState() => _DiscoverTeamsScreenState();
}

class _DiscoverTeamsScreenState extends State<DiscoverTeamsScreen> {
  final TeamService _service = TeamService();
  final TextEditingController _search = TextEditingController();

  late final String _token;
  List<Team>? _teams;
  bool _loading = true;
  String? _error;
  final Set<String> _requested = <String>{};
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final teams = await _service.discover(_token, q: _search.text);
      if (!mounted) return;
      setState(() {
        _teams = teams;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load teams. Check your connection and try again.';
        _loading = false;
      });
    }
  }

  Future<void> _request(Team t) async {
    if (_sending.contains(t.id) || _requested.contains(t.id)) return;
    setState(() => _sending.add(t.id));
    final r = await _service.joinRequest(_token, t.id);
    if (!mounted) return;
    final ok = r['success'] == true;
    // A 409 means a request to this team already stands; the button should read
    // "Requested" either way, so both outcomes mark the row asked.
    final duplicate = !ok && r['statusCode'] == 409;
    setState(() {
      _sending.remove(t.id);
      if (ok || duplicate) _requested.add(t.id);
    });
    if (ok) {
      SnackbarUtil.showSuccess(context, 'Request sent to ${t.name}. The captain will review it.');
    } else if (duplicate) {
      SnackbarUtil.showInfo(context, 'You have already asked to join ${t.name}.');
    } else {
      SnackbarUtil.showError(
        context, r['message']?.toString() ?? 'Could not send the request. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Find a team to join'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          _searchBar(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _load(),
        decoration: InputDecoration(
          hintText: 'Search teams by name',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    _search.clear();
                    _load();
                  },
                ),
          filled: true,
          fillColor: AppColors.inputFill,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
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

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return _centered(
        icon: Icons.cloud_off_rounded,
        title: error,
        action: TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Try again'),
        ),
      );
    }
    final teams = _teams ?? const <Team>[];
    if (teams.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            _centered(
              icon: Icons.groups_outlined,
              title: _search.text.isEmpty
                  ? 'No public teams are looking for players right now.'
                  : 'No public teams match "${_search.text.trim()}".',
              subtitle: 'Got an invite link instead? Use "Join with link" on the Teams tab.',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: teams.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _teamCard(teams[i]),
      ),
    );
  }

  Widget _centered({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 14, height: 1.4)),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4)),
            ],
            if (action != null) ...[const SizedBox(height: 10), action],
          ],
        ),
      ),
    );
  }

  Widget _teamCard(Team t) {
    final played = (t.wins + t.losses + t.draws).toInt();
    final record = played == 0 ? 'No matches yet' : '${t.wins}W · ${t.losses}L · ${t.draws}D';
    final members = '${t.memberCount} member${t.memberCount == 1 ? '' : 's'}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.primary,
            backgroundImage: (t.logoUrl != null && t.logoUrl!.isNotEmpty)
                ? NetworkImage(t.logoUrl!)
                : null,
            child: (t.logoUrl == null || t.logoUrl!.isEmpty)
                ? Text(
                    t.name.isNotEmpty ? t.name.substring(0, 1).toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('${_titleCase(t.sport)}  ·  $members',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text(record, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                if (t.bio != null && t.bio!.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(t.bio!.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 12.5, height: 1.35)),
                ],
                const SizedBox(height: 10),
                _requestButton(t),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _requestButton(Team t) {
    final requested = _requested.contains(t.id);
    final sending = _sending.contains(t.id);
    if (requested) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.check_circle, size: 18, color: AppColors.success),
          SizedBox(width: 6),
          Text('Requested',
              style: TextStyle(color: AppColors.success, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      );
    }
    return SizedBox(
      height: 40,
      child: ElevatedButton.icon(
        onPressed: sending ? null : () => _request(t),
        icon: sending
            ? const SizedBox(
                width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.group_add, size: 18),
        label: Text(sending ? 'Sending…' : 'Request to join'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
