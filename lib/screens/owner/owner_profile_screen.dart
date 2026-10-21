import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../shared/circle_crop_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/stable_refresh_indicator.dart';

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
    setState(
      () =>
          _dontShowLogout = prefs.getBool('owner_skip_logout_confirm') ?? false,
    );
  }

  Future<void> _doLogout() async {
    Provider.of<AuthProvider>(context, listen: false).logout();
    Navigator.pushNamedAndRemoveUntil(context, '/welcome', (r) => false);
  }

  Future<void> _handleLogout() async {
    if (_dontShowLogout) {
      _doLogout();
      return;
    }

    bool dontShowAgain = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Log Out?',
            style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Are you sure you want to log out from SportLynk?',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => setSt(() => dontShowAgain = !dontShowAgain),
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: dontShowAgain ? AppColors.accent : Colors.white,
                        border: Border.all(
                          color: dontShowAgain
                              ? AppColors.accent
                              : AppColors.border,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: dontShowAgain
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 14,
                            )
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "Don't ask me again",
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'Stay',
                style: GoogleFonts.poppins(color: AppColors.textSecondary),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                'Log Out',
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
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
        title: Text(
          'Profile',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      body: ScrollConfiguration(
        behavior: stableScrollBehavior(context),
        child: SingleChildScrollView(
          key: const PageStorageKey('owner-profile'),
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          child: SafeArea(
            top: false,
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Colors.white, Color(0xFFF0FDF4)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFDCEAE0)),
                    boxShadow: const [
                      BoxShadow(
                        color: AppColors.shadow,
                        blurRadius: 16,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final avatar = _profileAvatar(
                        auth.currentUser?.avatarUrl,
                        initial,
                      );
                      final identity = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: GoogleFonts.poppins(
                              color: AppColors.textPrimary,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            auth.currentUser?.email ?? '',
                            style: GoogleFonts.poppins(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accentLight,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.stadium_outlined,
                                  size: 15,
                                  color: AppColors.primary,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    'VENUE OWNER',
                                    style: GoogleFonts.poppins(
                                      color: AppColors.primary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                      if (constraints.maxWidth < 260 ||
                          MediaQuery.textScalerOf(context).scale(12) > 18) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            avatar,
                            const SizedBox(height: 16),
                            identity,
                          ],
                        );
                      }
                      return Row(
                        children: [
                          avatar,
                          const SizedBox(width: 14),
                          Expanded(child: identity),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 22),
                _sectionTitle('Account Details'),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      _infoCard(
                        Icons.phone_outlined,
                        'Phone',
                        auth.currentUser?.phone ?? 'Not set',
                      ),
                      const Divider(height: 1, indent: 58, endIndent: 16),
                      _infoCard(
                        Icons.verified_user_outlined,
                        'Account Status',
                        'Verified & Active ✓',
                      ),
                      const Divider(height: 1, indent: 58, endIndent: 16),
                      _infoCard(Icons.stadium_outlined, 'Role', 'Venue Owner'),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                _sectionTitle('Profile & Security'),
                const SizedBox(height: 10),
                _actionTile(
                  Icons.edit_outlined,
                  'Edit Profile',
                  _showEditProfile,
                  subtitle: 'Update your name and email address',
                ),
                _actionTile(
                  Icons.lock_outline,
                  'Change Password',
                  _showChangePassword,
                  subtitle: 'Keep your account secure',
                ),
                const SizedBox(height: 14),
                _sectionTitle('Support & Session'),
                const SizedBox(height: 10),
                _actionTile(
                  Icons.help_outline,
                  'Help & Support',
                  _showHelp,
                  subtitle: 'Contact the SportLynk team',
                ),
                _actionTile(
                  Icons.logout_rounded,
                  'Log Out',
                  _handleLogout,
                  subtitle: 'Sign out of your account',
                  isDestructive: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileAvatar(String? avatarUrl, String initial) {
    final fallback = Center(
      child: Text(
        initial,
        style: GoogleFonts.poppins(
          color: AppColors.primary,
          fontSize: 32,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return Tooltip(
      message: 'Change profile photo',
      child: Semantics(
        button: true,
        label: 'Change profile photo',
        child: GestureDetector(
          onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
          child: SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: ClipOval(
                    child: _uploadingAvatar
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primary,
                              strokeWidth: 2,
                            ),
                          )
                        : avatarUrl != null && avatarUrl.isNotEmpty
                        ? Image.network(
                            avatarUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => fallback,
                          )
                        : fallback,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.primary, width: 2),
                  ),
                  child: const Icon(
                    Icons.camera_alt_outlined,
                    color: AppColors.primary,
                    size: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.poppins(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    );
  }

  Widget _infoCard(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 21),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: label == 'Account Status'
                        ? AppColors.primary
                        : AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile(
    IconData icon,
    String title,
    VoidCallback onTap, {
    required String subtitle,
    bool isDestructive = false,
  }) {
    final color = isDestructive ? AppColors.error : AppColors.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isDestructive ? const Color(0xFFFEF2F2) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDestructive
                    ? AppColors.error.withValues(alpha: 0.15)
                    : AppColors.border,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDestructive ? color : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: color, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Avatar Upload
  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 600,
    );
    if (picked == null || !mounted) return;
    final cropped = await cropToCircle(context, picked);
    if (cropped == null || !mounted) return;

    // Capture context-dependent references before any async gap
    final authProv = Provider.of<AuthProvider>(context, listen: false);
    final token = authProv.token!;

    setState(() => _uploadingAvatar = true);
    try {
      final url = await _cloudinary.uploadImage(
        cropped.path,
        folder: 'owner_avatars',
      );
      if (url == null) {
        if (mounted) {
          _showSnack('Upload failed. Check Cloudinary config.', isError: true);
        }
        return;
      }
      // Save to backend
      final resp = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/users/me/update'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
        backgroundColor: isError ? AppColors.error : AppColors.accent,
        behavior: SnackBarBehavior.floating,
      ),
    );
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
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Help & Support',
          style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '📧 Email: support@sportlynk.pk',
              style: GoogleFonts.poppins(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              '📞 Phone: +92-300-SPORTLYNK',
              style: GoogleFonts.poppins(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              '🌐 Hours: Mon-Fri 9AM-6PM',
              style: GoogleFonts.poppins(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: GoogleFonts.poppins(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }
}

// Change Password Sheet

class _OwnerChangePasswordSheet extends StatefulWidget {
  const _OwnerChangePasswordSheet();
  @override
  State<_OwnerChangePasswordSheet> createState() =>
      _OwnerChangePasswordSheetState();
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
      _showError('Please fill in all fields.');
      return;
    }
    if (newP == cur) {
      _showError('New password must be different from current.');
      return;
    }
    if (newP.length < 8) {
      _showError('Password must be at least 8 characters.');
      return;
    }
    if (!RegExp(r'[A-Z]').hasMatch(newP)) {
      _showError('Password must contain at least one uppercase letter.');
      return;
    }
    if (!RegExp(r'[0-9]').hasMatch(newP)) {
      _showError('Password must contain at least one number.');
      return;
    }
    if (newP != conf) {
      _showError('Passwords do not match.');
      return;
    }

    setState(() => _saving = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http
          .post(
            Uri.parse('${ApiConstants.baseUrl}/users/me/change-password'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'currentPassword': cur, 'newPassword': newP}),
          )
          .timeout(const Duration(seconds: 8));

      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() => _saving = false);
        if (data['success'] == true) {
          Navigator.pop(context);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: Colors.white,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Password changed successfully!',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                backgroundColor: AppColors.accent,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                margin: const EdgeInsets.all(16),
              ),
            );
          });
        } else {
          _showError(data['message'] ?? 'Failed to change password');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errorMsg = 'Network error. Check your connection.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strength = _getStrength(_newCtrl.text);
    final match = _confCtrl.text.isNotEmpty && _newCtrl.text == _confCtrl.text;

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Container(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
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
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Change Password',
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Secure your account by updating your password.',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),

            TextField(
              controller: _curCtrl,
              obscureText: _obsCur,
              onChanged: (_) => setState(() => _errorMsg = null),
              style: GoogleFonts.poppins(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Current Password',
                labelStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
                prefixIcon: const Icon(Icons.lock_outline, size: 20),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obsCur ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obsCur = !_obsCur),
                ),
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
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
                labelStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
                prefixIcon: const Icon(Icons.vpn_key_outlined, size: 20),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obsNew ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obsNew = !_obsNew),
                ),
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Strength Bar
            Row(
              children: List.generate(
                4,
                (i) => Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    height: 4,
                    decoration: BoxDecoration(
                      color: strength > (i * 0.25)
                          ? _getStrengthColor(strength)
                          : AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_errorMsg != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.error.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: AppColors.error,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMsg!,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            TextField(
              controller: _confCtrl,
              obscureText: true,
              onChanged: (_) => setState(() => _errorMsg = null),
              style: GoogleFonts.poppins(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Confirm Password',
                labelStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
                prefixIcon: const Icon(Icons.lock_outline, size: 20),
                suffixIcon: match
                    ? const Icon(
                        Icons.check_circle,
                        color: AppColors.success,
                        size: 20,
                      )
                    : null,
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Update Password',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Edit Profile Sheet

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
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Name must be at least 3 chars',
            style: GoogleFonts.poppins(color: Colors.white),
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/users/me/update'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': _nameCtrl.text.trim(),
          'email': _emailCtrl.text.trim(),
        }),
      );
      final data = jsonDecode(resp.body);
      if (!mounted) return;
      setState(() => _saving = false);
      if (data['success'] == true) {
        Provider.of<AuthProvider>(
          context,
          listen: false,
        ).updateLocalUser(data['data'] as Map<String, dynamic>);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Profile updated!',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Container(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Edit Profile',
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Keep your contact details up to date.',
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameCtrl,
              style: GoogleFonts.poppins(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Full Name',
                labelStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
                prefixIcon: const Icon(Icons.person_outline, size: 20),
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailCtrl,
              style: GoogleFonts.poppins(fontSize: 14),
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email Address',
                labelStyle: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
                prefixIcon: const Icon(Icons.email_outlined, size: 20),
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Save Changes',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
