import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class TeamRosterScreen extends StatelessWidget {
  const TeamRosterScreen({super.key});

  static const _members = [
    {'name': 'Muhammad Anees', 'role': 'captain', 'elo': 1240, 'avatar': '👨‍💼'},
    {'name': 'Hamza Khan', 'role': 'member', 'elo': 1180, 'avatar': '👨'},
    {'name': 'Zubair Shah', 'role': 'member', 'elo': 1150, 'avatar': '🧑'},
    {'name': 'Hania Ali', 'role': 'member', 'elo': 1120, 'avatar': '👩'},
    {'name': 'Umair Saleem', 'role': 'member', 'elo': 1090, 'avatar': '👦'},
  ];

  static const _recommended = [
    {'name': 'Salar Wasil', 'match': '88%', 'elo': 1200},
    {'name': 'Mudassar', 'match': '82%', 'elo': 1160},
    {'name': 'Uzair', 'match': '79%', 'elo': 1140},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Team Roster', style: GoogleFonts.poppins(
          color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.background,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── TEAM HEADER ─────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border)),
            child: Row(children: [
              Container(width: 56, height: 56,
                decoration: BoxDecoration(color: AppColors.primary,
                  borderRadius: BorderRadius.circular(12)),
                child: const Center(child: Text('🦅', style: TextStyle(fontSize: 28)))),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Falcon FC', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold, fontSize: 16)),
                Text('W: 12  L: 4  WR: 75%', style: GoogleFonts.poppins(
                  fontSize: 12, color: AppColors.textSecondary)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: AppColors.primary,
                  borderRadius: BorderRadius.circular(20)),
                child: Text('ELO: 1,240', style: GoogleFonts.poppins(
                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))),
            ]),
          ),
          const SizedBox(height: 20),

          // ── AI RECOMMENDED ──────────────────────────────
          Row(children: [
            const Text('✨', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 6),
            Text('AI Recommended for You', style: GoogleFonts.poppins(
              fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          ]),
          const SizedBox(height: 10),
          SizedBox(height: 110,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _recommended.length,
              itemBuilder: (_, i) {
                final r = _recommended[i];
                return Container(
                  width: 90, margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    CircleAvatar(radius: 22, backgroundColor: AppColors.accentLight,
                      child: Text(r['name'].toString()[0], style: GoogleFonts.poppins(
                        color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 18))),
                    const SizedBox(height: 6),
                    Text(r['name'].toString().split(' ').first,
                      style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.accentLight,
                        borderRadius: BorderRadius.circular(4)),
                      child: Text('${r['match']} match', style: GoogleFonts.poppins(
                        color: AppColors.accent, fontSize: 9, fontWeight: FontWeight.bold))),
                  ]),
                );
              },
            )),
          const SizedBox(height: 20),

          // ── TEAM MEMBERS ────────────────────────────────
          Text('Team Members', style: GoogleFonts.poppins(
            fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border)),
            child: Column(
              children: List.generate(_members.length, (i) {
                final m = _members[i];
                final isCaptain = m['role'] == 'captain';
                return Column(children: [
                  ListTile(
                    leading: CircleAvatar(radius: 22, backgroundColor: AppColors.accentLight,
                      child: Text(m['avatar'] as String,
                        style: const TextStyle(fontSize: 20))),
                    title: Text(m['name'] as String,
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13)),
                    subtitle: isCaptain
                      ? Text('CAPTAIN', style: GoogleFonts.poppins(
                          color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold))
                      : Text('MEMBER', style: GoogleFonts.poppins(
                          color: AppColors.textSecondary, fontSize: 10)),
                    trailing: isCaptain ? null : IconButton(
                      icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
                      onPressed: () {}),
                  ),
                  if (i < _members.length - 1)
                    const Divider(height: 1, color: AppColors.border),
                ]);
              }),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: Text('Invite Player', style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                side: const BorderSide(color: AppColors.accent)),
              onPressed: () {},
            )),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
