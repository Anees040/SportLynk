import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/reco.dart';
import '../../models/team.dart';
import '../../models/team_stats.dart';
import '../../providers/auth_provider.dart';
import '../../services/cloudinary_service.dart';
import '../../services/realtime_service.dart';
import '../../services/team_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/reco_widgets.dart';
import '../../widgets/team_stat_widgets.dart';

/// The team's "Group info" — the WhatsApp screen reached by tapping the chat
/// header. It is both a profile (logo, record, roster) and the admin console
/// (invite links, join-request approval, roles, leave). What each viewer can do
/// is decided by their own role, re-checked by the backend on every write:
///
///   • captain      — everything: roles, removal, edit, invites, requests
///   • vice captain  — invites and join requests
///   • member       — read + leave
///
/// It listens to `team:update` so a change made by anyone (or to me) reflects
/// here live; if I discover I'm no longer on the roster, it backs out to chat,
/// which in turn backs out to the teams list.
class TeamRosterScreen extends StatefulWidget {
  final String? teamId;
  final String? teamName;
  const TeamRosterScreen({super.key, this.teamId, this.teamName});

  @override
  State<TeamRosterScreen> createState() => _TeamRosterScreenState();
}

class _TeamRosterScreenState extends State<TeamRosterScreen> {
  final _service = TeamService();
  final _picker = ImagePicker();

  Team? _team;
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _invites = [];

  /// FR2.8 — the suggested-players rail. Three-way state kept apart from the two
  /// lists above because the rail draws a different sentence for each: a genuine
  /// empty pool is not the same as a failed read is not the same as still loading.
  SuggestedPlayers _suggested = SuggestedPlayers.empty;
  bool _suggestLoading = false;
  bool _suggestFailed = false;

  /// These arrive inside the same `GET /teams/:id` payload as the
  /// team, but they cannot live on [Team]: `elo` there is a `num` defaulting to
  /// the 1000 seed, which has no way to say "Unranked" (FR2.6). [TeamStats]
  /// carries `ranked` + `displayElo` so the profile can say it.
  TeamStats? _stats;
  List<EloPoint> _history = const [];

  bool _loading = true;
  String? _error;
  bool _busy = false; // guards a write in flight

  late final String _token;
  late final String _myId;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _token = auth.token ?? '';
    _myId = auth.currentUser?.id ?? '';
    _sub = RealtimeService().teamUpdates.listen((e) {
      if ('${e['teamId']}' == widget.teamId) _refresh(fromEvent: true);
    });
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.teamId;
    if (id == null || id.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Team not found.';
      });
      return;
    }
    final r = await _service.detail(_token, id);
    if (!mounted) return;
    if (r['success'] == true && r['data'] is Map) {
      final data = Map<String, dynamic>.from(r['data'] as Map);
      final team = Team.fromJson(data);
      setState(() {
        _team = team;
        _absorbStats(data);
        _loading = false;
        _error = null;
      });
      if (team.amAdmin) _loadAdminExtras();
    } else {
      setState(() {
        _loading = false;
        _error = r['message']?.toString() ?? 'Could not load this team.';
      });
    }
  }

  /// The two extra stat blocks. Parsed in one place so `_load` and `_refresh`
  /// cannot end up reading different keys — a live `team:update` refresh that
  /// silently dropped the chart would be a hard bug to spot.
  /// Call inside setState.
  void _absorbStats(Map<String, dynamic> data) {
    final s = data['stats'];
    if (s is Map) _stats = TeamStats.fromJson(Map<String, dynamic>.from(s));
    _history = EloPoint.listFrom(data['eloHistory']);
  }

  /// Re-fetch after a change. When triggered by a live event, a role of `null`
  /// means I was removed — leave the screen the same way a self-leave does.
  Future<void> _refresh({bool fromEvent = false}) async {
    final id = widget.teamId;
    if (id == null) return;
    final r = await _service.detail(_token, id);
    if (!mounted) return;
    if (r['success'] == true && r['data'] is Map) {
      final data = Map<String, dynamic>.from(r['data'] as Map);
      final team = Team.fromJson(data);
      if (fromEvent && team.role == null && _team?.role != null) {
        SnackbarUtil.showError(context, 'You are no longer in this team.');
        Navigator.pop(context, 'left');
        return;
      }
      setState(() {
        _team = team;
        _absorbStats(data);
      });
      if (team.amAdmin) _loadAdminExtras();
    } else if (fromEvent && r['statusCode'] == 403) {
      // A private team I was removed from now refuses me entirely.
      Navigator.pop(context, 'left');
    }
  }

  Future<void> _loadAdminExtras() async {
    final id = widget.teamId!;
    final results = await Future.wait([
      _service.requests(_token, id),
      _service.invitesList(_token, id),
    ]);
    if (!mounted) return;
    setState(() {
      _requests = _listOf(results[0]);
      _invites = _listOf(results[1]);
    });
    _loadSuggested();
  }

  /// FR2.8. Kept out of the [Future.wait] above for two reasons: it returns a
  /// typed [SuggestedPlayers], not the raw map the other two do, and a slow ML
  /// round-trip must not hold the requests and invites lists hostage — the rail
  /// shows its own spinner while the rest of the console is already usable.
  Future<void> _loadSuggested() async {
    if (!mounted) return;
    setState(() {
      _suggestLoading = true;
      _suggestFailed = false;
    });
    final s = await _service.suggestedPlayers(_token, widget.teamId!);
    if (!mounted) return;
    setState(() {
      _suggestLoading = false;
      _suggestFailed = s == null; // null = request failed; empty = nobody to suggest
      _suggested = s ?? SuggestedPlayers.empty;
    });
  }

  List<Map<String, dynamic>> _listOf(Map<String, dynamic> r) =>
      r['success'] == true
          ? (r['data'] as List? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];

  // Writes
  Future<void> _run(Future<Map<String, dynamic>> Function() action,
      {String? success}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['success'] == true) {
      if (success != null) SnackbarUtil.showSuccess(context, success);
      await _refresh();
    } else {
      SnackbarUtil.showError(context, r['message']?.toString() ?? 'That didn\'t work.');
    }
  }

  void _memberAction(TeamMember m, String action, String verb) =>
      _run(() => _service.memberAction(_token, _team!.id, m.id, action),
          success: '${m.name} — $verb.');

  Future<void> _leave() async {
    final confirmed = await _confirm(
      title: 'Leave ${_team!.name}?',
      message: _team!.amCaptain
          ? 'If you are the only captain, promote someone else first.'
          : 'You will stop receiving this team\'s messages.',
      confirmLabel: 'Leave',
      danger: true,
    );
    if (confirmed != true) return;
    final r = await _service.leave(_token, _team!.id);
    if (!mounted) return;
    if (r['success'] == true) {
      SnackbarUtil.showSuccess(context, r['message']?.toString() ?? 'You left the team.');
      Navigator.pop(context, 'left');
    } else {
      SnackbarUtil.showError(context, r['message']?.toString() ?? 'Could not leave.');
    }
  }

  // Invite link
  /// Mint a single-use link. [note] is set only from the suggested-players rail,
  /// where it tags the link with the player's name so the invites list reads as
  /// "for that player"; the plain Invite button passes nothing. Same link either
  /// way — the schema has no per-user invite, so this is always a link the captain
  /// sends the player themselves.
  Future<void> _createInvite([String? note]) async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await _service.invite(_token, _team!.id, note: note);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['success'] == true && r['data'] is Map) {
      final data = Map<String, dynamic>.from(r['data'] as Map);
      _showInviteDialog(
        link: '${data['link'] ?? ''}',
        token: '${data['token'] ?? ''}',
        expiresAt: _parseDate(data['expires_at']),
      );
      _loadAdminExtras();
    } else {
      SnackbarUtil.showError(context, r['message']?.toString() ?? 'Could not create an invite.');
    }
  }

  void _showInviteDialog(
      {required String link, required String token, DateTime? expiresAt}) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Invite link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Share this with the player you want to add. They open '
              'SportLynk → Teams → "Join with link" and paste it.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.inputFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: SelectableText(link,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary)),
            ),
            if (expiresAt != null) ...[
              const SizedBox(height: 8),
              Text('Expires ${DateFormat('d MMM, h:mm a').format(expiresAt)}',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy link'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.pop(context);
              SnackbarUtil.showSuccess(context, 'Invite link copied.');
            },
          ),
        ],
      ),
    );
  }

  // Edit team (captain)
  Future<void> _editTeam() async {
    final bioCtrl = TextEditingController(text: _team!.bio ?? '');
    final cityCtrl = TextEditingController(text: _team!.city ?? '');
    var isPublic = _team!.isPublic;
    String? newLogo;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
              left: 20, right: 20, top: 18,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 16),
              const Text('Edit team',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: () async {
                    final url = await _pickLogo();
                    if (url != null) setSheet(() => newLogo = url);
                  },
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: AppColors.inputFill,
                    backgroundImage: _logoImage(newLogo ?? _team!.logoUrl),
                    child: (newLogo ?? _team!.logoUrl) == null
                        ? const Icon(Icons.camera_alt_outlined,
                            color: AppColors.textSecondary)
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Center(
                  child: Text('Tap to change logo',
                      style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary))),
              const SizedBox(height: 16),
              const Text('BIO',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      letterSpacing: 1, color: AppColors.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: bioCtrl,
                maxLines: 3,
                maxLength: 300,
                decoration: InputDecoration(
                  hintText: 'Team philosophy, level, home ground…',
                  filled: true,
                  fillColor: AppColors.inputFill,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 6),
              const Text('CITY',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      letterSpacing: 1, color: AppColors.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: cityCtrl,
                maxLength: 60,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Lahore',
                  counterText: '',
                  helperText: 'Groups your team under a city on the leaderboard',
                  helperStyle: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                  prefixIcon: const Icon(Icons.location_city_outlined,
                      size: 20, color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.inputFill,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: AppColors.accent,
                title: const Text('Public team'),
                subtitle: const Text('Visible in rankings and discovery'),
                value: isPublic,
                onChanged: (v) => setSheet(() => isPublic = v),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save changes'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;
    await _run(
      () => _service.update(_token, _team!.id,
          bio: bioCtrl.text.trim(),
          isPublic: isPublic,
          city: cityCtrl.text.trim(),
          logo: newLogo),
      success: 'Team updated.',
    );
  }

  /// Pick + upload a logo to Cloudinary's `teams` folder; returns the secure URL.
  Future<String?> _pickLogo() async {
    final picked = await _picker.pickImage(
        source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
    if (picked == null) return null;
    if (mounted) SnackbarUtil.showSuccess(context, 'Uploading logo…');
    final url = await CloudinaryService().uploadImage(picked.path, folder: 'teams');
    if (url == null && mounted) {
      SnackbarUtil.showError(context, 'Could not upload the logo.');
    }
    return url;
  }

  // Build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Group info'),
        actions: [
          if (_team?.amCaptain == true)
            IconButton(
              tooltip: 'Edit team',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : _editTeam,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      _header(),
                      if ((_team!.bio ?? '').isNotEmpty) _bioCard(),
                      if (_team!.amAdmin) ...[
                        _sectionTitle('Invite'),
                        _inviteSection(),
                      ],
                      if (_team!.amAdmin && _requests.isNotEmpty) ...[
                        _sectionTitle('Requests to join (${_requests.length})'),
                        ..._requests.map(_requestTile),
                      ],
                      // FR2.8 — suggested players. Admin-only (the server gates it
                      // too), and sat between the invite console and the team's own
                      // stats: it is a captain's tool, so it belongs with the other
                      // captain's tools, not down among the record a visitor came for.
                      if (_team!.amAdmin) ...[
                        _sectionTitle('Suggested players'),
                        SuggestedPlayersRail(
                          data: _suggested,
                          loading: _suggestLoading,
                          failed: _suggestFailed,
                          busy: _busy,
                          onRetry: _loadSuggested,
                          onInvite: (p) => _createInvite('Suggested: ${p.name}'),
                        ),
                      ],
                      // Placed below the admin console so a captain's actions stay
                      // where they were, and above Members because a visitor
                      // arriving from the leaderboard came for the record, not the
                      // roster.
                      if (_stats != null) ...[
                        _sectionTitle('Form'),
                        _formCard(_stats!),
                      ],
                      _sectionTitle('Rating history'),
                      _chartCard(),
                      if (_history.isNotEmpty) ...[
                        _sectionTitle('Recent matches (${_history.length})'),
                        _historyCard(),
                      ],
                      _sectionTitle('Members (${_team!.roster.length})'),
                      _membersCard(),
                      const SizedBox(height: 20),
                      // Only a member can leave. This screen is now reachable from
                      // the leaderboard, so a visitor would otherwise be offered a
                      // button that can only fail.
                      if (_team!.role != null) _leaveButton(),
                    ],
                  ),
                ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: AppColors.textSecondary),
              const SizedBox(height: 14),
              Text(_error!, textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );

  Widget _header() {
    final t = _team!;
    final s = _stats;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 42,
            backgroundColor: AppColors.accentLight,
            backgroundImage: _logoImage(t.logoUrl),
            child: t.logoUrl == null
                ? const Icon(Icons.shield_outlined, size: 38, color: AppColors.primary)
                : null,
          ),
          const SizedBox(height: 12),
          Text(t.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              _chip(t.sport.toUpperCase(), AppColors.primary),
              _chip(t.isPublic ? 'PUBLIC' : 'PRIVATE',
                  t.isPublic ? AppColors.accent : AppColors.textSecondary),
              if (t.city != null && t.city!.isNotEmpty)
                _chip(t.city!.toUpperCase(), AppColors.textSecondary),
            ],
          ),
          const SizedBox(height: 16),
          // FR5.15. The rating comes from `_stats` (which knows whether the team
          // is ranked) and falls back to the team's own record only for the
          // counts, never for the rating: printing `t.elo` here showed every new
          // team a confident "1000" it had not earned.
          Row(
            children: [
              StatTile(
                label: s != null && !s.ranked ? 'Rating' : 'ELO',
                valueWidget: s != null
                    ? RatingText(s, size: 15)
                    : const Text('—',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary)),
              ),
              StatTile(label: 'Won', value: '${s?.wins ?? t.wins}'),
              StatTile(label: 'Lost', value: '${s?.losses ?? t.losses}'),
              StatTile(label: 'Drew', value: '${s?.draws ?? t.draws}'),
              StatTile(label: 'Win %', value: '${s?.winRate ?? t.winRate}%'),
            ],
          ),
          if (s != null && s.eloFrozen) ...[
            const SizedBox(height: 12),
            _frozenNotice(),
          ],
        ],
      ),
    );
  }

  /// ER2.3 — a team over the dispute ratio keeps playing but stops moving. Saying
  /// so on the profile is the difference between a rule and a mystery.
  Widget _frozenNotice() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.ac_unit, size: 15, color: AppColors.warning),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Rating frozen — too many disputed results. Matches still count; '
                'points resume once disputes are resolved.',
                style: TextStyle(fontSize: 11.5, height: 1.35, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );

  // Stats cards

  /// Last-5 form + 30-day activity — the two features the recommender reads,
  /// shown here so they are visibly real rather than only present in JSON.
  Widget _formCard(TeamStats s) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Last 5',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                const Spacer(),
                FormRow(s.form, size: 24),
              ],
            ),
            const Divider(height: 20, color: AppColors.border),
            Row(
              children: [
                const Icon(Icons.local_fire_department_outlined,
                    size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.activity30d == 0
                        ? 'No matches in the last ${s.activityWindowDays} days'
                        : '${s.activity30d} ${s.activity30d == 1 ? 'match' : 'matches'} in the last ${s.activityWindowDays} days',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
                Text('${s.played} total',
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.primary)),
              ],
            ),
          ],
        ),
      );

  /// FR5.14 — the ELO line chart over the last 10 terminal matches.
  Widget _chartCard() => Container(
        padding: const EdgeInsets.fromLTRB(8, 16, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: EloHistoryChart(_history),
      );

  /// FR5.16 — opponent, "Won 2–1", date, "+18 ELO".
  Widget _historyCard() => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            // Newest first here, the opposite of the chart's left-to-right axis —
            // a list is read from the top, a chart from the left.
            for (var i = _history.length - 1; i >= 0; i--) ...[
              if (i < _history.length - 1)
                const Divider(height: 1, indent: 12, endIndent: 12, color: AppColors.border),
              MatchHistoryTile(_history[i]),
            ],
          ],
        ),
      );

  Widget _bioCard() => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(_team!.bio!,
            style: const TextStyle(fontSize: 13.5, height: 1.45, color: AppColors.textPrimary)),
      );

  Widget _inviteSection() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Create invite link'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accent,
              side: const BorderSide(color: AppColors.accent),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            ),
            onPressed: _busy ? null : _createInvite,
          ),
        ),
        if (_invites.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _invites.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: AppColors.border),
                  _inviteTile(_invites[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _inviteTile(Map<String, dynamic> inv) {
    final expires = _parseDate(inv['expires_at']);
    return ListTile(
      leading: const Icon(Icons.vpn_key_outlined, color: AppColors.textSecondary),
      title: Text('Code ${inv['token_prefix'] ?? ''}…',
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      subtitle: Text(
        expires != null
            ? 'Expires ${DateFormat('d MMM, h:mm a').format(expires)}'
            : 'Active',
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: TextButton(
        onPressed: _busy
            ? null
            : () => _run(
                () => _service.revokeInvite(_token, _team!.id, '${inv['id']}'),
                success: 'Invite revoked.'),
        child: const Text('Revoke', style: TextStyle(color: AppColors.error)),
      ),
    );
  }

  Widget _requestTile(Map<String, dynamic> req) {
    final name = '${req['name'] ?? 'Player'}';
    final elo = asNum(req['player_elo']);
    final message = '${req['message'] ?? ''}'.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.accentLight,
                backgroundImage: _logoImage(req['avatar_url'] as String?),
                child: (req['avatar_url'] == null)
                    ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: AppColors.accent, fontWeight: FontWeight.bold))
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    Text('ELO $elo', style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('"$message"',
                style: const TextStyle(
                    fontSize: 12.5, fontStyle: FontStyle.italic, color: AppColors.textSecondary)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: const BorderSide(color: AppColors.disabled)),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => _service.decideRequest(_token, _team!.id, '${req['id']}', 'reject'),
                          success: 'Request declined.'),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => _service.decideRequest(_token, _team!.id, '${req['id']}', 'approve'),
                          success: '$name added.'),
                  child: const Text('Approve'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _membersCard() {
    final roster = _team!.roster;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < roster.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.border),
            _memberTile(roster[i]),
          ],
        ],
      ),
    );
  }

  Widget _memberTile(TeamMember m) {
    final isMe = m.id == _myId;
    final canManage = _team!.amCaptain && !isMe;
    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.accentLight,
            backgroundImage: _logoImage(m.avatarUrl),
            child: m.avatarUrl == null
                ? Text(m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 18))
                : null,
          ),
          if (_isOnline(m))
            Positioned(
              right: 0, bottom: 0,
              child: Container(
                width: 12, height: 12,
                decoration: BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(isMe ? '${m.name} (You)' : m.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          ),
        ],
      ),
      subtitle: Text('ELO ${m.elo}', style: const TextStyle(fontSize: 11.5)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _roleBadge(m.role),
          if (canManage)
            IconButton(
              icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
              onPressed: _busy ? null : () => _memberSheet(m),
            ),
        ],
      ),
    );
  }

  void _memberSheet(TeamMember m) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Text(m.name,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  _roleBadge(m.role),
                ],
              ),
            ),
            const Divider(height: 1),
            if (!m.isCaptain)
              _sheetAction(Icons.workspace_premium_outlined, 'Make captain',
                  () => _memberAction(m, 'captain', 'promoted to captain')),
            if (m.role != 'vice_captain')
              _sheetAction(Icons.star_outline, 'Make vice captain',
                  () => _memberAction(m, 'vice_captain', 'made vice captain')),
            if (m.role != 'member')
              _sheetAction(Icons.person_outline, 'Make member',
                  () => _memberAction(m, 'member', 'set as member')),
            _sheetAction(Icons.person_remove_outlined, 'Remove from team',
                () async {
              final ok = await _confirm(
                title: 'Remove ${m.name}?',
                message: 'They will lose access to the team chat.',
                confirmLabel: 'Remove',
                danger: true,
              );
              if (ok == true) _memberAction(m, 'remove', 'removed');
            }, danger: true),
          ],
        ),
      ),
    );
  }

  Widget _sheetAction(IconData icon, String label, VoidCallback onTap,
      {bool danger = false}) {
    final color = danger ? AppColors.error : AppColors.textPrimary;
    return ListTile(
      leading: Icon(icon, color: danger ? AppColors.error : AppColors.primary),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
    );
  }

  Widget _leaveButton() => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('Leave team'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            side: const BorderSide(color: AppColors.error),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          ),
          onPressed: _busy ? null : _leave,
        ),
      );

  // Small pieces
  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 22, 2, 10),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      );

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _roleBadge(String role) {
    final (label, color) = switch (role) {
      'captain' => ('CAPTAIN', AppColors.accent),
      'vice_captain' => ('VICE', AppColors.primary),
      _ => ('MEMBER', AppColors.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: color)),
    );
  }

  ImageProvider? _logoImage(String? url) =>
      (url != null && url.isNotEmpty) ? CachedNetworkImageProvider(url) : null;

  bool _isOnline(TeamMember m) {
    final seen = m.lastSeenAt;
    if (seen == null) return false;
    return DateTime.now().difference(seen).inMinutes < 3;
  }

  DateTime? _parseDate(dynamic v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title),
        content: Text(message, style: const TextStyle(height: 1.4)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: danger ? AppColors.error : AppColors.primary),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
}
