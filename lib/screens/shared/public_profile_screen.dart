import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/public_profile.dart';
import '../../providers/auth_provider.dart';
import '../../services/user_service.dart';
import '../../utils/reconnect_refresh.dart';
import '../../widgets/network_error_view.dart';
import '../player/trust_score_screen.dart';

/// Another player's public profile (module 8c).
///
/// Reached by tapping a player anywhere they appear as a row — the request inbox, the
/// discover-players list, a team roster — so a player can see who they are about to
/// ask, accept or invite. Shared between roles because a captain (player) and a
/// player both land here.
///
/// The visibility rule is the server's; this screen only renders the decision. A
/// public profile shows the full detail (sports, bio, teams, activity). A private one
/// shows only the header — avatar, name, trust and ELO — behind a plain "this profile
/// is private" notice, never a spinner that never resolves or a blank where the detail
/// would be. The four states (loading, error+retry, loaded-public, loaded-private) are
/// all explicit, per the project's list-state rule.
class PublicProfileScreen extends StatefulWidget {
  final String userId;

  /// Optional, so the header can paint from what the caller already knows while the
  /// full profile loads — the same trick the chat room uses for its title.
  final String? name;
  final String? avatarUrl;

  const PublicProfileScreen({
    super.key,
    required this.userId,
    this.name,
    this.avatarUrl,
  });

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen>
    with ReconnectRefresh<PublicProfileScreen> {
  final _service = UserService();

  PublicProfile? _profile;
  bool _loading = true;
  bool _failed = false;

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  // Heal a failed first load the moment the socket returns; a good load is left alone.
  @override
  void onReconnect() {
    if (_failed) _load();
  }

  Future<void> _load() async {
    if (mounted && _profile == null) setState(() => _loading = true);
    final p = await _service.publicProfile(_token, widget.userId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = p == null;
      _profile = p;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Profile',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading && _profile == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_profile == null) {
      return RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _load,
        child: NetworkErrorView(
          title: 'Could not load profile',
          message: 'Check your connection and try again.',
          onRetry: _load,
        ),
      );
    }

    final p = _profile!;
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          _header(p),
          const SizedBox(height: 16),
          _statsRow(p),
          const SizedBox(height: 16),
          if (p.isDetailVisible) ..._detail(p) else _privateNotice(),
        ],
      ),
    );
  }

  Widget _header(PublicProfile p) {
    // Prefer the freshest known values, falling back to what the caller passed so the
    // avatar and name are never blank even for a split second.
    final url = (p.avatarUrl ?? widget.avatarUrl)?.trim() ?? '';
    final avatar = url.isEmpty ? null : CachedNetworkImageProvider(url);
    final name = p.name.isNotEmpty ? p.name : (widget.name ?? 'Player');
    final joined = p.memberSince;
    return Column(
      children: [
        CircleAvatar(
          radius: 48,
          backgroundColor: AppColors.accentLight,
          foregroundImage: avatar,
          child: avatar == null
              ? Text(
                  name.isNotEmpty ? name[0].toUpperCase() : 'P',
                  style: GoogleFonts.poppins(
                      fontSize: 34, fontWeight: FontWeight.bold, color: AppColors.accent),
                )
              : null,
        ),
        const SizedBox(height: 12),
        Text(name,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
                fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        if (joined != null) ...[
          const SizedBox(height: 4),
          Text('Member since ${_monthYear(joined)}',
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        ],
        if (!p.isPublic) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 13, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text('Private profile',
                  style: GoogleFonts.poppins(
                      fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            ],
          ),
        ],
      ],
    );
  }

  /// The three headline numbers, shown whether public or private. Trust is tappable
  /// into the full breakdown; a null trust reads "—" rather than a fabricated zero.
  Widget _statsRow(PublicProfile p) {
    final trust = p.trustScore == null
        ? '—'
        : (p.trustScore! % 1 == 0
            ? p.trustScore!.toInt().toString()
            : p.trustScore!.toStringAsFixed(1));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _stat('⚡', '${p.eloRating}', 'ELO'),
          _divider(),
          // The trust number is always shown; the full breakdown (individual
          // reviews) is detail, so it is only reachable on a profile whose detail is
          // visible — never for a private stranger.
          _stat('🛡️', trust, 'Trust', onTap: p.isDetailVisible ? () => _openTrust(p) : null),
          if (p.isDetailVisible && p.bookings30d != null) ...[
            _divider(),
            _stat('📅', '${p.bookings30d}', 'This month'),
          ],
        ],
      ),
    );
  }

  Widget _divider() => Container(width: 1, height: 36, color: AppColors.border);

  Widget _stat(String emoji, String value, String label, {VoidCallback? onTap}) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 5),
            Text(value,
                style: GoogleFonts.poppins(
                    fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary)),
            if (onTap != null) ...[
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 14, color: AppColors.textSecondary),
            ],
          ],
        ),
      ],
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: content),
    );
  }

  // The public detail: sports, bio, teams, and a link into the trust breakdown.
  List<Widget> _detail(PublicProfile p) {
    return [
      if (p.sports.isNotEmpty) ...[
        _sectionLabel('Plays'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: p.sports
              .map((s) => Chip(
                    label: Text(_titleCase(s),
                        style: GoogleFonts.poppins(
                            fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.accent)),
                    backgroundColor: AppColors.accentLight,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10), side: BorderSide.none),
                  ))
              .toList(),
        ),
        const SizedBox(height: 16),
      ],
      if (p.bio != null && p.bio!.trim().isNotEmpty) ...[
        _sectionLabel('About'),
        const SizedBox(height: 8),
        Text(p.bio!.trim(),
            style: GoogleFonts.poppins(
                fontSize: 13.5, height: 1.45, color: AppColors.textPrimary)),
        const SizedBox(height: 16),
      ],
      _sectionLabel('Teams'),
      const SizedBox(height: 8),
      if (p.teams.isEmpty)
        Text('Not on any team yet.',
            style: GoogleFonts.poppins(
                fontSize: 13, fontStyle: FontStyle.italic, color: AppColors.textSecondary))
      else
        ...p.teams.map(_teamTile),
      const SizedBox(height: 16),
      _trustTile(p),
    ];
  }

  Widget _privateNotice() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          const Icon(Icons.lock_outline, size: 36, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text('This profile is private',
              style: GoogleFonts.poppins(
                  fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Text(
            'Their sports, bio and teams are hidden, and they are not accepting play requests.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 12.5, height: 1.4, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _teamTile(ProfileTeam t) {
    final has = t.logoUrl != null && t.logoUrl!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: AppColors.inputFill,
            foregroundImage: has ? CachedNetworkImageProvider(t.logoUrl!) : null,
            child: has
                ? null
                : const Icon(Icons.shield_outlined, size: 20, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                        fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  '${_roleLabel(t.role)} · ${t.record}',
                  style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (t.elo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: AppColors.inputFill, borderRadius: BorderRadius.circular(8)),
              child: Text('ELO ${t.elo}',
                  style: GoogleFonts.poppins(
                      fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
            ),
        ],
      ),
    );
  }

  Widget _trustTile(PublicProfile p) {
    return InkWell(
      onTap: () => _openTrust(p),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.verified_user_outlined, color: AppColors.primary, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Trust & reviews',
                  style: GoogleFonts.poppins(
                      fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  void _openTrust(PublicProfile p) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TrustScoreScreen(
          userId: p.id,
          displayName: p.name,
          avatarUrl: p.avatarUrl,
          isSelf: p.isSelf,
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: GoogleFonts.poppins(
          fontSize: 10.5,
          letterSpacing: 1,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
        ),
      );

  static String _monthYear(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${d.year}';
  }

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _roleLabel(String? role) => switch (role) {
        'captain' => 'Captain',
        'vice_captain' => 'Vice captain',
        _ => 'Member',
      };
}
