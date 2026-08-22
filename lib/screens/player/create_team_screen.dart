import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../../constants/colors.dart';
import '../../utils/snackbar_util.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/cloudinary_service.dart';
import '../../services/team_service.dart';

class CreateTeamScreen extends StatefulWidget {
  const CreateTeamScreen({super.key});
  @override
  State<CreateTeamScreen> createState() => _CreateTeamScreenState();
}

class _CreateTeamScreenState extends State<CreateTeamScreen> {
  final _service = TeamService();
  final _picker = ImagePicker();
  bool _saving = false;
  bool _uploadingLogo = false;
  String? _logoUrl;
  final _nameCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  String _sport = 'football';
  bool _isPublic = true;

  @override
  void dispose() { _nameCtrl.dispose(); _bioCtrl.dispose(); super.dispose(); }

  /// Pick a logo from the gallery and upload it to Cloudinary's `teams` folder.
  /// We store only the returned https URL — the raw file never touches our API.
  Future<void> _pickLogo() async {
    final picked = await _picker.pickImage(
        source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
    if (picked == null) return;
    setState(() => _uploadingLogo = true);
    final url = await CloudinaryService().uploadImage(picked.path, folder: 'teams');
    if (!mounted) return;
    setState(() {
      _uploadingLogo = false;
      _logoUrl = url;
    });
    if (url == null) SnackbarUtil.showError(context, 'Could not upload the logo. Try again.');
  }

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
            onTap: _uploadingLogo ? null : _pickLogo,
            child: Container(width: 100, height: 100,
              decoration: BoxDecoration(
                color: AppColors.inputFill, shape: BoxShape.circle,
                image: _logoUrl != null
                  ? DecorationImage(image: NetworkImage(_logoUrl!), fit: BoxFit.cover)
                  : null,
                border: Border.all(color: AppColors.border, width: 2,
                  style: BorderStyle.solid)),
              child: _uploadingLogo
                ? const Center(child: SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2)))
                : _logoUrl != null
                  ? const Align(alignment: Alignment.bottomRight,
                      child: CircleAvatar(radius: 14, backgroundColor: AppColors.accent,
                        child: Icon(Icons.edit, size: 14, color: Colors.white)))
                  : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
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
              onPressed: _saving ? null : () async {
                if (_nameCtrl.text.trim().length < 3) { SnackbarUtil.showError(context, 'Enter a team name.'); return; }
                setState(() => _saving = true);
                final response = await _service.create(context.read<AuthProvider>().token ?? '', name: _nameCtrl.text.trim(), sport: _sport, isPublic: _isPublic, bio: _bioCtrl.text.trim().isEmpty ? null : _bioCtrl.text.trim(), logo: _logoUrl);
                if (!context.mounted) return;
                setState(() => _saving = false);
                if (response['success'] == true) {
                  SnackbarUtil.showSuccess(context, 'Team created.');
                  Navigator.pop(context, true);
                } else {
                  SnackbarUtil.showError(context,
                      response['message']?.toString() ?? 'Could not create team.');
                }
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
