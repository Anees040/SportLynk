import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';
import 'create_team_screen.dart';
import 'team_roster_screen.dart';
import 'find_opponents_screen.dart';
import 'team_rankings_screen.dart';

class TeamsScreen extends StatelessWidget {
  const TeamsScreen({super.key});

  // Mock: current user has a team
  static const _myTeam = {
    'name': 'Falcon FC',
    'sport': 'Football',
    'elo': 1240,
    'wins': 12, 'losses': 4,
    'winRate': '75%',
    'city': 'Islamabad',
    'memberCount': 11,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Teams', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.emoji_events_outlined, color: Colors.white),
            onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const TeamRankingsScreen())),
          ),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── MY TEAM CARD ────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 52, height: 52,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12)),
                  child: const Center(child: Text('🦅', style: TextStyle(fontSize: 28)))),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_myTeam['name'] as String, style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(_myTeam['sport'] as String, style: GoogleFonts.poppins(
                    color: Colors.white70, fontSize: 12)),
                ])),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.accent,
                    borderRadius: BorderRadius.circular(20)),
                  child: Text('ELO ${_myTeam['elo']}', style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                _statBadge('W: ${_myTeam['wins']}', Colors.white),
                const SizedBox(width: 12),
                _statBadge('L: ${_myTeam['losses']}', Colors.white70),
                const SizedBox(width: 12),
                _statBadge('WR: ${_myTeam['winRate']}', AppColors.accent),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: _teamBtn('Team Roster', Icons.groups_outlined,
                  () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const TeamRosterScreen())))),
                const SizedBox(width: 10),
                Expanded(child: _teamBtn('Find Opponents', Icons.sports_kabaddi_outlined,
                  () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const FindOpponentsScreen())))),
              ]),
            ]),
          ),
          const SizedBox(height: 20),

          // ── QUICK ACTIONS ───────────────────────────────
          Text('Quick Actions', style: GoogleFonts.poppins(
            fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _actionCard('🏆', 'Rankings', 'See city leaderboard',
              [const Color(0xFFF59E0B), const Color(0xFFD97706)],
              () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const TeamRankingsScreen())))),
            const SizedBox(width: 10),
            Expanded(child: _actionCard('➕', 'New Team', 'Create a team',
              [const Color(0xFF22C55E), const Color(0xFF16A34A)],
              () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const CreateTeamScreen())))),
          ]),
          const SizedBox(height: 20),

          // ── UPCOMING CHALLENGES ─────────────────────────
          Text('Upcoming Challenges', style: GoogleFonts.poppins(
            fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          _challengeCard('Titan United', 'Tomorrow • 6:00 PM', 'Diamond Turf', 'Pending'),
          _challengeCard('Urban Strikers', 'Sun May 12 • 8:00 PM', 'Elite Arena', 'Confirmed'),
          const SizedBox(height: 20),

          // ── RECENT RESULTS ──────────────────────────────
          Text('Recent Results', style: GoogleFonts.poppins(
            fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          _resultCard('VS Titan FC', 'Won 2-1', 'Yesterday', '+12 pts', true),
          _resultCard('VS Raven Squad', 'Lost 0-2', '3 days ago', '-8 pts', false),
          _resultCard('VS City Warriors', 'Won 3-0', '1 week ago', '+15 pts', true),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  Widget _statBadge(String text, Color color) => Text(text,
    style: GoogleFonts.poppins(color: color, fontSize: 12, fontWeight: FontWeight.w600));

  Widget _teamBtn(String label, IconData icon, VoidCallback onTap) =>
    GestureDetector(onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.poppins(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ])));

  Widget _actionCard(String emoji, String title, String sub,
    List<Color> colors, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(
            color: colors.first.withValues(alpha: 0.3),
            blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            Text(sub, style: GoogleFonts.poppins(
              color: Colors.white70, fontSize: 11)),
          ])),
          const Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 14),
        ]),
      ),
    );

  Widget _challengeCard(String opp, String time, String venue, String status) {
    final isConfirmed = status == 'Confirmed';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border)),
      child: Row(children: [
        Container(width: 42, height: 42,
          decoration: const BoxDecoration(color: AppColors.inputFill, shape: BoxShape.circle),
          child: const Center(child: Text('⚔️', style: TextStyle(fontSize: 20)))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('VS $opp', style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold, fontSize: 13)),
          Text('$time · $venue', style: GoogleFonts.poppins(
            fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isConfirmed ? AppColors.accentLight : AppColors.inputFill,
            borderRadius: BorderRadius.circular(6)),
          child: Text(status, style: GoogleFonts.poppins(
            color: isConfirmed ? AppColors.accent : AppColors.textSecondary,
            fontSize: 10, fontWeight: FontWeight.bold))),
      ]),
    );
  }

  Widget _resultCard(String opp, String score, String time, String pts, bool won) =>
    Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border)),
      child: Row(children: [
        Container(width: 42, height: 42,
          decoration: BoxDecoration(
            color: won ? AppColors.accentLight : const Color(0xFFFEE2E2),
            shape: BoxShape.circle),
          child: Center(child: Text(won ? 'W' : 'L', style: GoogleFonts.poppins(
            color: won ? AppColors.accent : AppColors.error,
            fontWeight: FontWeight.bold, fontSize: 16)))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(opp, style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold, fontSize: 13)),
          Text('$score · $time', style: GoogleFonts.poppins(
            fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Text(pts, style: GoogleFonts.poppins(
          color: won ? AppColors.accent : AppColors.error,
          fontSize: 12, fontWeight: FontWeight.bold)),
      ]),
    );
}
