import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/team_stats.dart';
import '../../providers/auth_provider.dart';
import '../../services/team_service.dart';
import '../../widgets/team_stat_widgets.dart';
import 'team_roster_screen.dart';

/// Global team leaderboard — FR5.13.
///
/// S2 Wave D rebuilt this on the ranked-only endpoint. Three things changed, and
/// each fixed something that was quietly wrong:
///
///   • It reads [RankingsPage], not `List<Team>`. Only teams with a verified
///     match appear (FR2.6), so the board can no longer be padded out with teams
///     sitting on the untouched 1000 seed.
///   • The "YOU" badge comes from the server's `is_mine`. It used to be guessed
///     from a `role` field this endpoint never sent, so it could never appear.
///   • Every row carries its movement over the last 7 days, and city chips filter
///     the board — built from the cities that hold ranked teams, so a
///     chip can never lead to an empty screen.
class TeamRankingsScreen extends StatefulWidget {
  const TeamRankingsScreen({super.key});
  @override
  State<TeamRankingsScreen> createState() => _TeamRankingsScreenState();
}

class _TeamRankingsScreenState extends State<TeamRankingsScreen> {
  final _service = TeamService();

  RankingsPage? _page;
  bool _loading = true;
  String? _error;

  /// null = "All cities". Held here rather than in the page so the chip row can
  /// stay put and stay responsive while a filtered fetch is in flight.
  String? _city;

  /// The chips from the last unfiltered load. Keeping them means picking a city
  /// does not make the row just tapped disappear and come back.
  List<CityCount> _chips = const [];

  late final String _token;

  @override
  void initState() {
    super.initState();
    _token = context.read<AuthProvider>().token ?? '';
    _load();
  }

  Future<void> _load() async {
    final page = await _service.rankings(_token, city: _city);
    if (!mounted) return;
    setState(() {
      _loading = false;
      // null means the request failed, which is not the same as an empty board —
      // keep the last good page on screen rather than blanking it out.
      if (page == null) {
        _error = 'Could not load rankings.';
      } else {
        _page = page;
        _error = null;
        // The endpoint returns the full chip list regardless of the active
        // filter, so this stays complete; the guard is only for a failed request.
        if (page.cities.isNotEmpty) _chips = page.cities;
      }
    });
  }

  Future<void> _refresh() => _load();

  void _pickCity(String? city) {
    if (_city == city) return;
    setState(() {
      _city = city;
      _loading = true;
    });
    _load();
  }

  void _openTeam(RankedTeam t) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TeamRosterScreen(teamId: t.id, teamName: t.name),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final page = _page;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Rankings',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          if (_chips.isNotEmpty) _cityFilter(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: _body(page),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(RankingsPage? page) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && page == null) {
      return _message(_error!, Icons.cloud_off,
          action: TextButton(
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
            child: Text('Try again',
                style:
                    GoogleFonts.poppins(fontWeight: FontWeight.w600, color: AppColors.accent)),
          ));
    }
    if (page == null || page.isEmpty) return _emptyBoard(page);

    final teams = page.teams;
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        // A refresh failed but the previous board is still held. Say so instead of
        // showing week-old ranks as though they were live.
        if (_error != null) _staleBanner(),
        _hero(teams.first),
        const SizedBox(height: 20),
        Row(
          children: [
            Text('Leaderboard',
                style: GoogleFonts.poppins(
                    fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const Spacer(),
            Text('${teams.length} ranked',
                style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary)),
          ],
        ),
        const SizedBox(height: 6),
        _columnHint(page),
        const SizedBox(height: 10),
        for (final t in teams) _rankCard(t),
        const SizedBox(height: 14),
        _footnote(page),
        const SizedBox(height: 24),
      ],
    );
  }

  // City filter (FR5.13)
  Widget _cityFilter() => Container(
        width: double.infinity,
        color: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              _filterChip('All cities', _city == null, () => _pickCity(null)),
              for (final c in _chips) ...[
                const SizedBox(width: 8),
                _filterChip(
                  '${c.city} (${c.teams})',
                  _city != null && _city!.toLowerCase() == c.city.toLowerCase(),
                  () => _pickCity(c.city),
                ),
              ],
            ],
          ),
        ),
      );

  /// Same shape as the venue filters so the two screens feel like one app.
  Widget _filterChip(String label, bool isSelected, VoidCallback onTap) => ChoiceChip(
        label: Text(label,
            style: GoogleFonts.poppins(
              color: isSelected ? Colors.white : AppColors.textPrimary,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              fontSize: 12,
            )),
        selected: isSelected,
        onSelected: (_) => onTap(),
        selectedColor: AppColors.primary,
        backgroundColor: AppColors.inputFill,
        showCheckmark: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: isSelected ? AppColors.primary : AppColors.border),
        ),
      );

  /// Shown when a refresh failed while an earlier board is still on screen.
  Widget _staleBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 14, color: AppColors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Showing the last loaded board — pull down to retry.',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
            ),
          ],
        ),
      );

  /// A one-line key for the two columns that are not self-explanatory.
  Widget _columnHint(RankingsPage page) => Row(
        children: [
          const Icon(Icons.swap_vert, size: 13, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Text('Movement vs ${page.movementWindowDays} days ago',
              style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary)),
        ],
      );

  Widget _footnote(RankingsPage page) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 15, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'A team joins the rankings after ${page.rankedMinMatches == 1 ? 'its first verified match' : '${page.rankedMinMatches} verified matches'}. '
                'Ratings update the moment a venue owner verifies a result.',
                style: GoogleFonts.poppins(
                    fontSize: 11, color: AppColors.textSecondary, height: 1.4),
              ),
            ),
          ],
        ),
      );

  // Empty / error
  /// Two different empty boards, because they need two different answers: one is
  /// "nobody has played yet", the other is "nobody in Multan has".
  Widget _emptyBoard(RankingsPage? page) {
    if (_city != null) {
      return _message(
        'No ranked teams in $_city yet.\nTry another city, or clear the filter.',
        Icons.location_off_outlined,
        action: TextButton(
          onPressed: () => _pickCity(null),
          child: Text('Show all cities',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: AppColors.accent)),
        ),
      );
    }
    final min = page?.rankedMinMatches ?? 1;
    return _message(
      'No ranked teams yet.\nA team appears here after ${min == 1 ? 'its first verified match' : '$min verified matches'} — challenge someone and be the first.',
      Icons.emoji_events_outlined,
    );
  }

  Widget _message(String text, IconData icon, {Widget? action}) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * .2),
          Icon(icon, size: 64, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(text,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                    fontSize: 14.5, color: AppColors.textSecondary, height: 1.5)),
          ),
          if (action != null) Center(child: action),
        ],
      );

  // Cards
  Widget _hero(RankedTeam t) => InkWell(
        onTap: () => _openTeam(t),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: Colors.white.withValues(alpha: 0.15),
                backgroundImage: (t.logoUrl != null && t.logoUrl!.isNotEmpty)
                    ? CachedNetworkImageProvider(t.logoUrl!)
                    : null,
                child: (t.logoUrl == null || t.logoUrl!.isEmpty)
                    ? const Text('🏆', style: TextStyle(fontSize: 24))
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.circular(12)),
                          child: Text(
                              '⭐ #1 ${t.sport.toUpperCase()}${_city != null ? ' · ${_city!.toUpperCase()}' : ''}',
                              style: GoogleFonts.poppins(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold)),
                        ),
                        if (t.isMine)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12)),
                            child: Text('YOUR TEAM',
                                style: GoogleFonts.poppins(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w800)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('ELO',
                      style: GoogleFonts.poppins(
                          color: Colors.white60, fontSize: 9, letterSpacing: 0.5)),
                  Text(t.eloLabel,
                      style: GoogleFonts.poppins(
                          color: AppColors.accent, fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  MovementBadge(t.movement, compact: true),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _rankCard(RankedTeam t) {
    final isMe = t.isMine;
    final rank = t.rank;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isMe ? AppColors.accentLight : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isMe ? AppColors.accent : AppColors.border, width: isMe ? 1.5 : 1),
      ),
      child: InkWell(
        onTap: () => _openTeam(t),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Column(
                  children: [
                    rank <= 3
                        ? Text(['🥇', '🥈', '🥉'][rank - 1],
                            style: const TextStyle(fontSize: 20))
                        : Text('#$rank',
                            style: GoogleFonts.poppins(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: AppColors.textSecondary)),
                    const SizedBox(height: 3),
                    MovementBadge(t.movement, compact: true),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              CircleAvatar(
                radius: 21,
                backgroundColor:
                    isMe ? AppColors.accent.withValues(alpha: 0.2) : AppColors.inputFill,
                backgroundImage: (t.logoUrl != null && t.logoUrl!.isNotEmpty)
                    ? CachedNetworkImageProvider(t.logoUrl!)
                    : null,
                child: (t.logoUrl == null || t.logoUrl!.isEmpty)
                    ? const Icon(Icons.shield_outlined, color: AppColors.primary, size: 20)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(t.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: isMe ? AppColors.primary : AppColors.textPrimary)),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius: BorderRadius.circular(4)),
                            child: Text('YOU',
                                style: GoogleFonts.poppins(
                                    color: Colors.white,
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                        if (t.eloFrozen) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.ac_unit, size: 12, color: AppColors.warning),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                        'W ${t.wins}  L ${t.losses}  D ${t.draws}  ·  ${t.winRate}%  ·  ${t.sport}'
                        '${t.city != null && t.city!.isNotEmpty ? '  ·  ${t.city}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              RatingText(t,
                  size: 15, color: isMe ? AppColors.primary : AppColors.textPrimary),
            ],
          ),
        ),
      ),
    );
  }
}
