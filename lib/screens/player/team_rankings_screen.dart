import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class TeamRankingsScreen extends StatelessWidget {
  const TeamRankingsScreen({super.key});

  static const _teams = [
    {'rank': 1, 'name': 'Urban Strikers', 'elo': 1450, 'sport': 'Football',
     'city': 'Islamabad', 'wins': 24, 'losses': 4, 'emoji': '⚡'},
    {'rank': 2, 'name': 'Falcon FC', 'elo': 1240, 'sport': 'Football',
     'city': 'Islamabad', 'wins': 12, 'losses': 4, 'emoji': '🦅', 'isMe': true},
    {'rank': 3, 'name': 'Titan United', 'elo': 1198, 'sport': 'Football',
     'city': 'Islamabad', 'wins': 9, 'losses': 7, 'emoji': '🦁'},
    {'rank': 4, 'name': 'Stump Kings', 'elo': 1380, 'sport': 'Cricket',
     'city': 'Islamabad', 'wins': 18, 'losses': 6, 'emoji': '🏏'},
    {'rank': 5, 'name': 'Phoenix FC', 'elo': 1120, 'sport': 'Football',
     'city': 'Islamabad', 'wins': 6, 'losses': 8, 'emoji': '🔥'},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Rankings', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.notifications_outlined), onPressed: () {}),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // My team highlight
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              Container(width: 52, height: 52,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10)),
                child: const Center(child: Text('🦅', style: TextStyle(fontSize: 26)))),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Falcon FC', style: GoogleFonts.poppins(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(6)),
                  child: Text('FOOTBALL', style: GoogleFonts.poppins(
                    color: AppColors.accent, fontSize: 9, fontWeight: FontWeight.bold))),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.accent,
                    borderRadius: BorderRadius.circular(12)),
                  child: Text('⭐ #2 in Islamabad', style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('ELO RATING', style: GoogleFonts.poppins(
                  color: Colors.white60, fontSize: 9, letterSpacing: 0.5)),
                Text('1,240', style: GoogleFonts.poppins(
                  color: AppColors.accent, fontSize: 28, fontWeight: FontWeight.bold)),
              ]),
            ]),
          ),
          const SizedBox(height: 20),
          Text('Islamabad Leaderboard', style: GoogleFonts.poppins(
            fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          ..._teams.asMap().entries.map((e) => _rankCard(e.value)),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  int _toInt(dynamic value, int fallback) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  Widget _rankCard(Map<String, dynamic> t) {
    final isMe = t['isMe'] == true;
    final rank = _toInt(t['rank'], 0);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isMe ? AppColors.accentLight : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isMe ? AppColors.accent : AppColors.border,
          width: isMe ? 1.5 : 1)),
      child: Row(children: [
        // Rank
        SizedBox(width: 32, child: Center(child: rank <= 3
          ? Text(['🥇','🥈','🥉'][rank-1], style: const TextStyle(fontSize: 20))
          : Text('#$rank', style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold, fontSize: 14,
              color: AppColors.textSecondary)))),
        const SizedBox(width: 10),
        // Avatar
        Container(width: 42, height: 42,
          decoration: BoxDecoration(
            color: isMe ? AppColors.accent.withValues(alpha: 0.2) : AppColors.inputFill,
            borderRadius: BorderRadius.circular(10)),
          child: Center(child: Text(t['emoji'] as String,
            style: const TextStyle(fontSize: 22)))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(t['name'] as String, style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold, fontSize: 13,
              color: isMe ? AppColors.primary : AppColors.textPrimary)),
            if (isMe) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: AppColors.accent,
                  borderRadius: BorderRadius.circular(4)),
                child: Text('YOU', style: GoogleFonts.poppins(
                  color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold))),
            ],
          ]),
          Text('W: ${t['wins']}  L: ${t['losses']}  ${t['sport']}',
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Text('${_toInt(t['elo'], 0) >= 1000 ? _toInt(t['elo'], 0).toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},') : _toInt(t['elo'], 0)}',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15,
            color: isMe ? AppColors.primary : AppColors.textPrimary)),
      ]),
    );
  }
}
