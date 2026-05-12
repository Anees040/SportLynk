import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../services/cloudinary_service.dart';

class OwnerProfileScreen extends StatefulWidget {
  const OwnerProfileScreen({super.key});
  @override
  State<OwnerProfileScreen> createState() => _OwnerProfileScreenState();
}

class _OwnerProfileScreenState extends State<OwnerProfileScreen> {
  bool _dontShowLogout = false;
  bool _uploadingAvatar = false;
  final _cloudinary = CloudinaryService();

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _dontShowLogout = prefs.getBool('owner_skip_logout_confirm') ?? false);
  }

  Future<void> _doLogout() async {
    Provider.of<AuthProvider>(context, listen: false).logout();
    Navigator.pushNamedAndRemoveUntil(context, '/welcome', (r) => false);
  }

  Future<void> _handleLogout() async {
    if (_dontShowLogout) { _doLogout(); return; }

    bool dontShowAgain = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Log Out?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Are you sure you want to log out from SportLynk?',
              style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => setSt(() => dontShowAgain = !dontShowAgain),
              child: Row(children: [
                Container(
                  width: 20, height: 20,
                  decoration: BoxDecoration(
                    color: dontShowAgain ? AppColors.accent : Colors.white,
                    border: Border.all(color: dontShowAgain ? AppColors.accent : AppColors.border),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: dontShowAgain ? const Icon(Icons.check, color: Colors.white, size: 14) : null,
                ),
                const SizedBox(width: 8),
                Text("Don't ask me again", style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
              ]),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: Text('Stay', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: Text('Log Out', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600))),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (dontShowAgain) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('owner_skip_logout_confirm', true);
      }
      if (mounted) _doLogout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final name = auth.currentUser?.name ?? 'Owner';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'O';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Profile', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(children: [
          // Header Section with tappable avatar
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0A1F13), Color(0xFF14532D)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
            child: Column(children: [
              GestureDetector(
                onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
                child: Stack(alignment: Alignment.bottomRight, children: [
                  Container(
                    width: 88, height: 88,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.accent, width: 2.5),
                    ),
                    child: ClipOval(
                      child: () {
                        final avatarUrl = auth.currentUser?.avatarUrl;
                        if (_uploadingAvatar) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.accent, strokeWidth: 2));
                        }
                        if (avatarUrl != null && avatarUrl.isNotEmpty) {
                          return Image.network(avatarUrl, fit: BoxFit.cover,
                            errorBuilder: (ctx, err, stack) => Center(
                              child: Text(initial,
                                style: GoogleFonts.poppins(color: AppColors.accent,
                                  fontSize: 32, fontWeight: FontWeight.bold))));
                        }
                        return Center(child: Text(initial,
                          style: GoogleFonts.poppins(color: AppColors.accent,
                            fontSize: 32, fontWeight: FontWeight.bold)));
                      }(),
                    ),
                  ),
                  // Camera badge
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      color: AppColors.accent, shape: BoxShape.circle),
                    child: const Icon(Icons.camera_alt, color: Colors.white, size: 14),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              Text(name, style: GoogleFonts.poppins(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(auth.currentUser?.email ?? '', style: GoogleFonts.poppins(color: Colors.white60, fontSize: 13)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(20)),
                child: Text('VENUE OWNER', style: GoogleFonts.poppins(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ),
            ]),
          ),

          // Rounded white section
          Transform.translate(
            offset: const Offset(0, -16),
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(children: [
                // Info Cards
                _infoCard(Icons.phone_outlined, 'Phone', auth.currentUser?.phone ?? 'Not set'),
                const SizedBox(height: 10),
                _infoCard(Icons.verified_outlined, 'Account Status', 'Verified & Active ✓'),
                const SizedBox(height: 10),
                _infoCard(Icons.stadium_outlined, 'Role', 'Venue Owner'),
                const SizedBox(height: 20),

                // Action Tiles
                _actionTile(Icons.lock_outline, 'Change Password', () => _showChangePassword()),
                _actionTile(Icons.edit_outlined, 'Edit Profile', () => _showEditProfile()),
                _actionTile(Icons.help_outline, 'Help & Support', () => _showHelp()),
                _actionTile(Icons.logout, 'Log Out', _handleLogout, isDestructive: true),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _infoCard(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, color: AppColors.accent, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
          Text(value, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        ])),
      ]),
    );
  }

  Widget _actionTile(IconData icon, String title, VoidCallback onTap, {bool isDestructive = false}) {
    final color = isDestructive ? AppColors.error : AppColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDestructive ? AppColors.error.withValues(alpha: 0.3) : AppColors.border),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDestructive ? AppColors.error.withValues(alpha: 0.1) : AppColors.accentLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: isDestructive ? AppColors.error : AppColors.accent, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title,
              style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: color))),
            Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 18),
          ]),
        ),
      ),
    );
  }

  // ── Avatar Upload ─────────────────────────────────────────────────────────
  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery, imageQuality: 80, maxWidth: 600);
    if (picked == null) return;
    if (!mounted) return;

    // Capture context-dependent references BEFORE any async gap
    final authProv = Provider.of<AuthProvider>(context, listen: false);
    final token = authProv.token!;

    setState(() => _uploadingAvatar = true);
    try {
      final url = await _cloudinary.uploadImage(picked.path, folder: 'owner_avatars');
      if (url == null) {
        if (mounted) _showSnack('Upload failed. Check Cloudinary config.', isError: true);
        return;
      }
      // Save to backend
      final resp = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/users/me/update'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'avatarUrl': url}),
      );
      final data = jsonDecode(resp.body);
      if (data['success'] == true && mounted) {
        authProv.updateLocalUser({'avatarUrl': url});
        _showSnack('Profile photo updated!');
      }
    } catch (e) {
      if (mounted) _showSnack('Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: isError ? AppColors.error : AppColors.accent,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showChangePassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _OwnerChangePasswordSheet(),
    );
  }

  void _showEditProfile() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _OwnerEditProfileSheet(),
    );
  }

  void _showHelp() {
    showDialog(context: context, builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Help & Support', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('📧 Email: support@sportlynk.pk', style: GoogleFonts.poppins(fontSize: 13)),
        const SizedBox(height: 8),
        Text('📞 Phone: +92-300-SPORTLYNK', style: GoogleFonts.poppins(fontSize: 13)),
        const SizedBox(height: 8),
        Text('🌐 Hours: Mon-Fri 9AM-6PM', style: GoogleFonts.poppins(fontSize: 13)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context),
        child: Text('Close', style: GoogleFonts.poppins(color: AppColors.accent)))],
    ));
  }
}

// ── Change Password Sheet ──────────────────────────────────────────────────

class _OwnerChangePasswordSheet extends StatefulWidget {
  const _OwnerChangePasswordSheet();
  @override
  State<_OwnerChangePasswordSheet> createState() => _OwnerChangePasswordSheetState();
}

class _OwnerChangePasswordSheetState extends State<_OwnerChangePasswordSheet> {
  final _curCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confCtrl = TextEditingController();
  bool _saving = false;
  bool _obsCur = true;
  bool _obsNew = true;
  String? _errorMsg;

  @override
  void dispose() {
    _curCtrl.dispose();
    _newCtrl.dispose();
    _confCtrl.dispose();
    super.dispose();
  }

  void _showError(String msg) => setState(() => _errorMsg = msg);

  double _getStrength(String p) {
    if (p.isEmpty) return 0;
    double s = 0;
    if (p.length >= 8) s += 0.25;
    if (RegExp(r'[A-Z]').hasMatch(p)) s += 0.25;
    if (RegExp(r'[0-9]').hasMatch(p)) s += 0.25;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(p)) s += 0.25;
    return s;
  }

  Color _getStrengthColor(double s) {
    if (s <= 0.25) return AppColors.error;
    if (s <= 0.5) return AppColors.warning;
    if (s <= 0.75) return Colors.blue;
    return AppColors.success;
  }

  Future<void> _submit() async {
    final cur = _curCtrl.text;
    final newP = _newCtrl.text;
    final conf = _confCtrl.text;

    if (cur.isEmpty || newP.isEmpty || conf.isEmpty) {
      _showError('Please fill in all fields.'); return;
    }
    if (newP == cur) {
      _showError('New password must be different from current.'); return;
    }
    if (newP.length < 8) {
      _showError('Password must be at least 8 characters.'); return;
    }
    if (!RegExp(r'[A-Z]').hasMatch(newP)) {
      _showError('Password must contain at least one uppercase letter.'); return;
    }
    if (!RegExp(r'[0-9]').hasMatch(newP)) {
      _showError('Password must contain at least one number.'); return;
    }
    if (newP != conf) {
      _showError('Passwords do not match.'); return;
    }

    setState(() => _saving = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/users/me/change-password'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'currentPassword': cur, 'newPassword': newP}),
      ).timeout(const Duration(seconds: 8));

      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() => _saving = false);
        if (data['success'] == true) {
          Navigator.pop(context);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Row(children: [
                const Icon(Icons.check_circle, color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Text('Password changed successfully!',
                    style: GoogleFonts.poppins(color: Colors.white, fontSize: 13)),
              ]),
              backgroundColor: AppColors.accent,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              margin: const EdgeInsets.all(16),
            ));
          });
        } else {
          _showError(data['message'] ?? 'Failed to change password');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _saving = false; _errorMsg = 'Network error. Check your connection.'; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strength = _getStrength(_newCtrl.text);
    final match = _confCtrl.text.isNotEmpty && _newCtrl.text == _confCtrl.text;

    return Container(
      padding: EdgeInsets.only(
        left: 24, right: 24, top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          Text('Change Password', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Text('Secure your account by updating your password.', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 24),

          TextField(
            controller: _curCtrl,
            obscureText: _obsCur,
            onChanged: (_) => setState(() => _errorMsg = null),
            style: GoogleFonts.poppins(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Current Password',
              labelStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.lock_outline, size: 20),
              suffixIcon: IconButton(
                icon: Icon(_obsCur ? Icons.visibility_off : Icons.visibility, size: 20),
                onPressed: () => setState(() => _obsCur = !_obsCur),
              ),
              filled: true, fillColor: AppColors.inputFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _newCtrl,
            obscureText: _obsNew,
            onChanged: (_) => setState(() => _errorMsg = null),
            style: GoogleFonts.poppins(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'New Password',
              labelStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.vpn_key_outlined, size: 20),
              suffixIcon: IconButton(
                icon: Icon(_obsNew ? Icons.visibility_off : Icons.visibility, size: 20),
                onPressed: () => setState(() => _obsNew = !_obsNew),
              ),
              filled: true, fillColor: AppColors.inputFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 8),
          // Strength Bar
          Row(
            children: List.generate(4, (i) => Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                height: 4,
                decoration: BoxDecoration(
                  color: strength > (i * 0.25) ? _getStrengthColor(strength) : AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            )),
          ),
          const SizedBox(height: 16),
          if (_errorMsg != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline, color: AppColors.error, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_errorMsg!,
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.error))),
              ]),
            ),

          TextField(
            controller: _confCtrl,
            obscureText: true,
            onChanged: (_) => setState(() => _errorMsg = null),
            style: GoogleFonts.poppins(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Confirm Password',
              labelStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.lock_outline, size: 20),
              suffixIcon: match ? const Icon(Icons.check_circle, color: AppColors.success, size: 20) : null,
              filled: true, fillColor: AppColors.inputFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('Update Password', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Edit Profile Sheet ─────────────────────────────────────────────────────

class _OwnerEditProfileSheet extends StatefulWidget {
  const _OwnerEditProfileSheet();
  @override
  State<_OwnerEditProfileSheet> createState() => _OwnerEditProfileSheetState();
}

class _OwnerEditProfileSheetState extends State<_OwnerEditProfileSheet> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final auth = Provider.of<AuthProvider>(context, listen: false);
    _nameCtrl.text = auth.currentUser?.name ?? '';
    _emailCtrl.text = auth.currentUser?.email ?? '';
  }

  @override
  void dispose() { _nameCtrl.dispose(); _emailCtrl.dispose(); super.dispose(); }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Name must be at least 3 chars', style: GoogleFonts.poppins(color: Colors.white)),
        backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _saving = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/users/me/update'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'name': _nameCtrl.text.trim(), 'email': _emailCtrl.text.trim()}));
      final data = jsonDecode(resp.body);
      if (!mounted) return;
      setState(() => _saving = false);
      if (data['success'] == true) {
        Provider.of<AuthProvider>(context, listen: false).updateLocalUser(data['data'] as Map<String, dynamic>);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Profile updated!', style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: AppColors.accent, behavior: SnackBarBehavior.floating));
      }
    } catch(_) { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Text('Edit Profile', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        TextField(controller: _nameCtrl, style: GoogleFonts.poppins(fontSize: 14),
          decoration: InputDecoration(
            labelText: 'Full Name',
            labelStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
            prefixIcon: const Icon(Icons.person_outline, size: 20),
            filled: true, fillColor: AppColors.inputFill,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 12),
        TextField(controller: _emailCtrl, style: GoogleFonts.poppins(fontSize: 14), keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: 'Email Address',
            labelStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
            prefixIcon: const Icon(Icons.email_outlined, size: 20),
            filled: true, fillColor: AppColors.inputFill,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)), padding: const EdgeInsets.symmetric(vertical: 14)),
          child: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : Text('Save Changes', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)))),
      ]),
    );
  }
}
