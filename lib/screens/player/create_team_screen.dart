import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';
import '../../utils/snackbar_util.dart';

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
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
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
                SnackbarUtil.showSuccess(context, 'Teams feature coming soon!');
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
