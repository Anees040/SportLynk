import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class TrustScoreScreen extends StatelessWidget {
  final Map<String, dynamic> profile;
  const TrustScoreScreen({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    final score = (profile['trust_score'] ?? 100) as num;
    final elo = (profile['elo_rating'] ?? 1000) as num;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Trust Score', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          const SizedBox(height: 20),
          // ── SCORE RING ─────────────────────────────────────
          SizedBox(width: 180, height: 180,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(width: 180, height: 180,
                child: CircularProgressIndicator(
                  value: score.toDouble() / 100,
                  strokeWidth: 14,
                  backgroundColor: AppColors.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    score >= 80 ? AppColors.accent
                    : score >= 60 ? AppColors.warning
                    : AppColors.error),
                )),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${score.round()}',
                  style: GoogleFonts.poppins(fontSize: 48,
                    fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                Text('/100', style: GoogleFonts.poppins(
                  fontSize: 14, color: AppColors.textSecondary)),
              ]),
            ]),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(color: AppColors.accentLight,
              borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.verified_outlined, color: AppColors.accent, size: 16),
              const SizedBox(width: 6),
              Text(_label(score.toInt()), style: GoogleFonts.poppins(
                color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 32),
          // ── FACTORS ────────────────────────────────────────
          _factorCard([
            _factor('📋', 'Attendance Rate', '95%', 'Show up to booked sessions'),
            _factor('⭐', 'ELO Rating', '${elo.round()}', 'Competitive performance score'),
            _factor('🚫', 'No-shows', '0', 'Missed bookings without cancelling'),
            _factor('📅', 'Account Age', 'Active', 'Time since you joined SportLynk'),
          ]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.3))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('💡 How to improve',
                style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14,
                  color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              Text(
                '• Always attend booked sessions on time\n'
                '• Cancel at least 2 hours before if you can\'t make it\n'
                '• Be respectful to other players and venue owners\n'
                '• Keep your profile complete with phone verified',
                style: GoogleFonts.poppins(fontSize: 13,
                  color: AppColors.textSecondary, height: 1.7)),
            ]),
          ),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }

  Widget _factorCard(List<Widget> children) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Text('Score Breakdown', style: GoogleFonts.poppins(
          fontSize: 14, fontWeight: FontWeight.bold))),
      const Divider(color: AppColors.border, height: 1),
      ...children,
    ]),
  );

  Widget _factor(String emoji, String title, String value, String desc) =>
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Text(emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13)),
          Text(desc, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        ])),
        Text(value, style: GoogleFonts.poppins(
          fontWeight: FontWeight.bold, color: AppColors.accent, fontSize: 14)),
      ]));

  String _label(int s) =>
    s >= 90 ? 'Highly Trusted' : s >= 75 ? 'Trusted' : s >= 60 ? 'Fair' : 'Needs Improvement';
}
