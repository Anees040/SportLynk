# PROMPT 5 — Teams Screens (UI ONLY — No Backend)
# Run AFTER Prompt 4. Pure Flutter UI. No http calls. Static/mock data only.
# Agent: Do NOT add any backend routes. Do NOT call any API. Pure UI demonstration.

---

## FILE 1: lib/screens/player/teams_screen.dart  (REPLACE stub)

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';
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
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.15),
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
            Expanded(child: _actionCard(Icons.emoji_events_outlined,
              'Rankings', 'See city leaderboard', AppColors.warning,
              () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const TeamRankingsScreen())))),
            const SizedBox(width: 10),
            Expanded(child: _actionCard(Icons.add_circle_outline,
              'New Team', 'Create a team', AppColors.accent,
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
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.poppins(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ])));

  Widget _actionCard(IconData icon, String title, String sub,
    Color color, VoidCallback onTap) =>
    GestureDetector(onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 22)),
          const SizedBox(height: 10),
          Text(title, style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textPrimary)),
          Text(sub, style: GoogleFonts.poppins(
            fontSize: 11, color: AppColors.textSecondary)),
        ])));

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
          decoration: BoxDecoration(color: AppColors.inputFill, shape: BoxShape.circle),
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
            color: (isConfirmed ? AppColors.accent : AppColors.warning).withOpacity(0.1),
            borderRadius: BorderRadius.circular(6)),
          child: Text(status, style: GoogleFonts.poppins(fontSize: 10,
            fontWeight: FontWeight.bold,
            color: isConfirmed ? AppColors.accent : AppColors.warning))),
      ]),
    );
  }

  Widget _resultCard(String match, String score, String time, String pts, bool won) =>
    Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border)),
      child: Row(children: [
        Container(width: 42, height: 42,
          decoration: BoxDecoration(
            color: (won ? AppColors.success : AppColors.error).withOpacity(0.1),
            shape: BoxShape.circle),
          child: Icon(won ? Icons.emoji_events : Icons.close,
            color: won ? AppColors.success : AppColors.error, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(match, style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13)),
          Text('$score · $time', style: GoogleFonts.poppins(
            fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Text(pts, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.bold,
          color: won ? AppColors.success : AppColors.error)),
      ]),
    );
}
```

---

## FILE 2: lib/screens/player/create_team_screen.dart

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';

class CreateTeamScreen extends StatefulWidget {
  const CreateTeamScreen({super.key});
  @override
  State<CreateTeamScreen> createState() => _CreateTeamScreenState();
}

class _CreateTeamScreenState extends State<CreateTeamScreen> {
  final _nameCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  String _sport = 'football';
  bool _isPublic = true;

  @override
  void dispose() { _nameCtrl.dispose(); _bioCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Create Your Team', style: GoogleFonts.poppins(
          color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.background,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── LOGO PICKER ─────────────────────────────────
          Center(child: GestureDetector(
            onTap: () {},
            child: Container(width: 100, height: 100,
              decoration: BoxDecoration(
                color: AppColors.inputFill, shape: BoxShape.circle,
                border: Border.all(color: AppColors.border, width: 2,
                  style: BorderStyle.solid)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.camera_alt_outlined, color: AppColors.textSecondary, size: 28),
                const SizedBox(height: 4),
                Text('Upload Team\nLogo', textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
              ])),
          )),
          const SizedBox(height: 28),

          // ── TEAM NAME ───────────────────────────────────
          Text('TEAM NAME', style: GoogleFonts.poppins(
            fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary,
            letterSpacing: 1)),
          const SizedBox(height: 8),
          TextField(controller: _nameCtrl,
            style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'e.g. Islamabad United',
              hintStyle: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.inputFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.accent, width: 1.5)))),
          const SizedBox(height: 20),

          // ── SPORT ───────────────────────────────────────
          Text('SPORT', style: GoogleFonts.poppins(
            fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary,
            letterSpacing: 1)),
          const SizedBox(height: 8),
          Row(children: [
            _sportChip('⚽', 'Football', 'football'),
            const SizedBox(width: 12),
            _sportChip('🏏', 'Cricket', 'cricket'),
          ]),
          const SizedBox(height: 20),

          // ── VISIBILITY ──────────────────────────────────
          Text('VISIBILITY', style: GoogleFonts.poppins(
            fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary,
            letterSpacing: 1)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: GestureDetector(
              onTap: () => setState(() => _isPublic = true),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _isPublic ? AppColors.accent : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Public', style: GoogleFonts.poppins(
                      color: _isPublic ? Colors.white : AppColors.textPrimary,
                      fontWeight: FontWeight.bold)),
                    if (_isPublic) const Icon(Icons.check, color: Colors.white, size: 16),
                  ]),
                  Align(alignment: Alignment.centerLeft,
                    child: Text('Visible to AI Recs',
                      style: GoogleFonts.poppins(fontSize: 10,
                        color: _isPublic ? Colors.white70 : AppColors.textSecondary))),
                ]),
              ))),
            const SizedBox(width: 10),
            Expanded(child: GestureDetector(
              onTap: () => setState(() => _isPublic = false),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: !_isPublic ? AppColors.primary : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Private', style: GoogleFonts.poppins(
                      color: !_isPublic ? Colors.white : AppColors.textPrimary,
                      fontWeight: FontWeight.bold)),
                    Icon(Icons.lock_outline,
                      color: !_isPublic ? Colors.white : AppColors.textSecondary,
                      size: 16),
                  ]),
                  Align(alignment: Alignment.centerLeft,
                    child: Text('Invite only',
                      style: GoogleFonts.poppins(fontSize: 10,
                        color: !_isPublic ? Colors.white70 : AppColors.textSecondary))),
                ]),
              ))),
          ]),
          const SizedBox(height: 20),

          // ── TEAM BIO ─────────────────────────────────────
          Text('TEAM BIO', style: GoogleFonts.poppins(
            fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary,
            letterSpacing: 1)),
          const SizedBox(height: 8),
          TextField(controller: _bioCtrl, maxLines: 3,
            style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Enter team philosophy, goals, or requirements...',
              hintStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.inputFill,
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.accent, width: 1.5)))),
          const SizedBox(height: 32),

          // ── CREATE BUTTON ────────────────────────────────
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text('Create Team', style: GoogleFonts.poppins(
                fontSize: 15, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 15)),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Teams feature coming soon!',
                    style: GoogleFonts.poppins(color: Colors.white)),
                  backgroundColor: AppColors.accent,
                  behavior: SnackBarBehavior.floating));
              })),
          const SizedBox(height: 10),
          Center(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.shield_outlined, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Text('You will be assigned as Captain', style: GoogleFonts.poppins(
              fontSize: 12, color: AppColors.textSecondary)),
          ])),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  Widget _sportChip(String emoji, String label, String val) {
    final selected = _sport == val;
    return Expanded(child: GestureDetector(
      onTap: () => setState(() => _sport = val),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.inputFill,
          borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Text(label, style: GoogleFonts.poppins(
            color: selected ? Colors.white : AppColors.textPrimary,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
        ])),
    ));
  }
}
```

---

## FILE 3: lib/screens/player/team_roster_screen.dart

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';

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
    {'name': 'Leo Sterling', 'match': '88%', 'elo': 1200},
    {'name': 'Max Haris', 'match': '82%', 'elo': 1160},
    {'name': 'Ali Raza', 'match': '79%', 'elo': 1140},
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
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.accent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 12)),
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Invite feature coming soon!',
                  style: GoogleFonts.poppins(color: Colors.white)),
                backgroundColor: AppColors.accent, behavior: SnackBarBehavior.floating)))),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
```

---

## FILE 4: lib/screens/player/find_opponents_screen.dart

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';

class FindOpponentsScreen extends StatefulWidget {
  const FindOpponentsScreen({super.key});
  @override
  State<FindOpponentsScreen> createState() => _FindOpponentsScreenState();
}

class _FindOpponentsScreenState extends State<FindOpponentsScreen> {
  String _sport = 'Football';
  static const _sports = ['Football', 'Cricket'];

  static const _opponents = [
    {'name': 'Urban Strikers', 'record': 'W12 L4', 'elo': 1310, 'score': 87,
     'trusted': true, 'emoji': '⚡'},
    {'name': 'Titan United', 'record': 'W9 L7', 'elo': 1198, 'score': 62,
     'trusted': true, 'emoji': '🦁'},
    {'name': 'Phoenix FC', 'record': 'W6 L8', 'elo': 1120, 'score': 54,
     'trusted': false, 'emoji': '🔥'},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Find Opponents', style: GoogleFonts.poppins(
          color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.background,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        elevation: 0,
        actions: _sports.map((s) => GestureDetector(
          onTap: () => setState(() => _sport = s),
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: _sport == s ? AppColors.primary : AppColors.inputFill,
              borderRadius: BorderRadius.circular(20)),
            child: Text(s, style: GoogleFonts.poppins(fontSize: 12,
              color: _sport == s ? Colors.white : AppColors.textSecondary,
              fontWeight: _sport == s ? FontWeight.bold : FontWeight.normal))),
        )).toList(),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // My team info
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.inputFill,
              borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Text('🛡️', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Falcon FC', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold, fontSize: 13)),
                Text('MANAGER VIEW', style: GoogleFonts.poppins(
                  fontSize: 10, color: AppColors.textSecondary, letterSpacing: 0.5)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: AppColors.primary,
                  borderRadius: BorderRadius.circular(20)),
                child: Text('ELO 1,240', style: GoogleFonts.poppins(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
            ]),
          ),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Suggested Opponents', style: GoogleFonts.poppins(
              fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const Icon(Icons.tune, color: AppColors.textSecondary, size: 20),
          ]),
          const SizedBox(height: 12),
          ..._opponents.map((o) => _opponentCard(context, o)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.accentLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.accent.withOpacity(0.3))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('⭐', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Text('PRO RECOMMENDATION', style: GoogleFonts.poppins(
                  fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.accent,
                  letterSpacing: 0.5)),
              ]),
              const SizedBox(height: 8),
              Text("Based on Falcon FC's recent form, teams in the 'Silver' tier "
                "(ELO 1,150–1,300) will provide the best competitive experience.",
                style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary,
                  height: 1.5)),
            ])),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  Widget _opponentCard(BuildContext context, Map<String,dynamic> o) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 48, height: 48,
            decoration: BoxDecoration(color: AppColors.inputFill,
              borderRadius: BorderRadius.circular(10)),
            child: Center(child: Text(o['emoji'] as String,
              style: const TextStyle(fontSize: 24)))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(o['name'] as String, style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold, fontSize: 14)),
            Row(children: [
              Text(o['record'] as String, style: GoogleFonts.poppins(
                fontSize: 11, color: AppColors.textSecondary)),
              if (o['trusted'] == true) ...[
                const SizedBox(width: 8),
                const Icon(Icons.verified, color: AppColors.accent, size: 14),
                const SizedBox(width: 2),
                Text('Trusted', style: GoogleFonts.poppins(
                  fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w600)),
              ],
            ]),
          ])),
        ]),
        const SizedBox(height: 12),
        Text('COMPETITIVENESS', style: GoogleFonts.poppins(
          fontSize: 9, color: AppColors.textSecondary, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (o['score'] as int) / 100,
              minHeight: 8,
              backgroundColor: AppColors.inputFill,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent)))),
          const SizedBox(width: 10),
          Text('${o['score']}%', style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.accent)),
        ]),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity,
          child: ElevatedButton(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Challenge sent to ${o['name']}! (Demo)',
                style: GoogleFonts.poppins(color: Colors.white)),
              backgroundColor: AppColors.accent, behavior: SnackBarBehavior.floating)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.symmetric(vertical: 10)),
            child: Text('Challenge', style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)))),
      ]),
    );
  }
}
```

---

## FILE 5: lib/screens/player/team_rankings_screen.dart

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';

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
          color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.background,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
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
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10)),
                child: const Center(child: Text('🦅', style: TextStyle(fontSize: 26)))),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Falcon FC', style: GoogleFonts.poppins(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.accent.withOpacity(0.3),
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

  Widget _rankCard(Map<String, dynamic> t) {
    final isMe = t['isMe'] == true;
    final rank = t['rank'] as int;
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
            color: isMe ? AppColors.accent.withOpacity(0.2) : AppColors.inputFill,
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
        Text('${(t['elo'] as int) >= 1000 ? (t['elo'] as int).toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},') : t['elo']}',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15,
            color: isMe ? AppColors.primary : AppColors.textPrimary)),
      ]),
    );
  }
}
```

---

## UPDATE player_home_screen.dart — Replace _teamsStub with TeamsScreen

In player_home_screen.dart, update the import and IndexedStack:
```dart
import 'teams_screen.dart'; // add this import

// In IndexedStack children, replace _teamsStub() with:
const TeamsScreen(),
```

## AFTER IMPLEMENTING
Run: flutter analyze — 0 errors
Teams tab shows with team card, upcoming challenges, results
Create Team → fills form, taps Create (shows "coming soon" snackbar)
Team Roster → shows members list + AI recommendations
Find Opponents → shows competitiveness bars, Challenge button works (demo snackbar)
Rankings → shows leaderboard with your team highlighted
