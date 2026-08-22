import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/team.dart';
import '../../providers/auth_provider.dart';
import '../../services/team_service.dart';

/// Global team leaderboard, ordered by ELO (highest first) straight from the
/// backend. The top team gets a hero card; my own teams are badged "YOU".
class TeamRankingsScreen extends StatefulWidget {
  const TeamRankingsScreen({super.key});
  @override
  State<TeamRankingsScreen> createState() => _TeamRankingsScreenState();
}

class _TeamRankingsScreenState extends State<TeamRankingsScreen> {
  final _service = TeamService();
  late Future<List<Team>> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _service.rankings(context.read<AuthProvider>().token ?? '');
  }

  void _reload() => setState(
      () => _future = _service.rankings(context.read<AuthProvider>().token ?? ''));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Rankings',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<Team>>(
          future: _future,
          builder: (context, s) {
            if (s.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (s.hasError) return _message('Could not load rankings.', Icons.cloud_off);
            final teams = s.data ?? [];
            if (teams.isEmpty) {
              return _message('No ranked teams yet. Be the first to compete!',
                  Icons.emoji_events_outlined);
            }
            return ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                _hero(teams.first),
                const SizedBox(height: 20),
                Text('Leaderboard',
                    style: GoogleFonts.poppins(
                        fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                const SizedBox(height: 12),
                for (var i = 0; i < teams.length; i++) _rankCard(i + 1, teams[i]),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _message(String text, IconData icon) => ListView(
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * .25),
          Icon(icon, size: 64, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(text,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textSecondary)),
          ),
        ],
      );

  Widget _hero(Team t) => Container(
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: AppColors.accent, borderRadius: BorderRadius.circular(12)),
                    child: Text('⭐ #1 ${t.sport.toUpperCase()}',
                        style: GoogleFonts.poppins(
                            color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('ELO',
                    style: GoogleFonts.poppins(
                        color: Colors.white60, fontSize: 9, letterSpacing: 0.5)),
                Text(_elo(t.elo),
                    style: GoogleFonts.poppins(
                        color: AppColors.accent, fontSize: 26, fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      );

  Widget _rankCard(int rank, Team t) {
    final isMe = t.role != null; // rankings includes my role when I'm a member
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isMe ? AppColors.accentLight : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isMe ? AppColors.accent : AppColors.border, width: isMe ? 1.5 : 1),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Center(
              child: rank <= 3
                  ? Text(['🥇', '🥈', '🥉'][rank - 1], style: const TextStyle(fontSize: 20))
                  : Text('#$rank',
                      style: GoogleFonts.poppins(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: AppColors.textSecondary)),
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
                            color: AppColors.accent, borderRadius: BorderRadius.circular(4)),
                        child: Text('YOU',
                            style: GoogleFonts.poppins(
                                color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ],
                ),
                Text(
                    'W ${t.wins}  L ${t.losses}  D ${t.draws}  ·  ${t.sport}${t.city != null && t.city!.isNotEmpty ? '  ·  ${t.city}' : ''}',
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Text(_elo(t.elo),
              style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: isMe ? AppColors.primary : AppColors.textPrimary)),
        ],
      ),
    );
  }

  /// 1240 → "1,240"
  String _elo(num v) => v.toInt().toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
}
