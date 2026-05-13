import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';
import '../../utils/snackbar_util.dart';

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
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: _sports.map((s) => GestureDetector(
          onTap: () => setState(() => _sport = s),
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: _sport == s ? AppColors.accent : Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20)),
            child: Text(s, style: GoogleFonts.poppins(fontSize: 12,
              color: Colors.white,
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
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.3))),
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
              value: (_toInt(o['score'], 0) / 100.0).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppColors.inputFill,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent)))),
          const SizedBox(width: 10),
          Text('${_toInt(o['score'], 0)}%', style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.accent)),
        ]),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity,
          child: ElevatedButton(
            onPressed: () => SnackbarUtil.showSuccess(context, 'Challenge sent to ${o['name']}! (Demo)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.symmetric(vertical: 10)),
            child: Text('Challenge', style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)))),
      ]),
    );
  }

  int _toInt(dynamic value, int fallback) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }
}
