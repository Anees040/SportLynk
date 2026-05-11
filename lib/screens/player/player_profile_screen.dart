import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import '../../constants/api_constants.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/custom_button.dart';
import '../../services/cloudinary_service.dart';
import 'trust_score_screen.dart';
import '../../utils/snackbar_util.dart';
import 'help_support_screen.dart';

class PlayerProfileScreen extends StatefulWidget {
  const PlayerProfileScreen({super.key});
  @override
  State<PlayerProfileScreen> createState() => _PlayerProfileScreenState();
}

class _PlayerProfileScreenState extends State<PlayerProfileScreen> {
  Map<String, dynamic>? _profile;
  bool _loading = true, _saving = false;
  bool _isEditing = false;

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  List<String> _sports = [];
  static const _allowedSports = ['Football', 'Cricket'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    try {
      final token = auth.token;
      if (token == null) {
        _setFromAuth(auth);
        return;
      }
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/users/me/player'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted && data['success'] == true) {
          final d = data['data'] as Map<String, dynamic>;
          setState(() {
            _profile = d;
            _nameCtrl.text = d['name'] ?? '';
            _emailCtrl.text = d['email'] ?? '';
            final prefs = d['sport_preferences'];
            if (prefs is List) {
              _sports = prefs.map((e) => e.toString()).where((s) => _allowedSports.contains(s)).toList();
            } else {
              _sports = [];
            }
            _loading = false;
          });
          return;
        }
      }
      _setFromAuth(auth);
    } catch (e) {
      debugPrint('Profile load error: $e');
      _setFromAuth(auth);
    }
  }

  void _setFromAuth(AuthProvider auth) {
    if (!mounted) return;
    final user = auth.currentUser;
    setState(() {
      _profile = {
        'name': user?.name ?? 'Player',
        'email': user?.email,
        'phone': user?.phone ?? '',
        'avatar_url': user?.avatarUrl,
        'created_at': DateTime.now().toIso8601String(),
        'elo_rating': 1000,
        'trust_score': 100,
        'balance': 0,
        'sport_preferences': [],
      };
      _nameCtrl.text = _profile!['name'] ?? '';
      _emailCtrl.text = _profile!['email'] ?? '';
      _sports = [];
      _loading = false;
    });
  }

  Future<void> _pickAvatar() async {
    if (!_isEditing) return;
    if (kIsWeb) {
      _snack('Avatar upload is currently only supported on the mobile app.', AppColors.warning);
      return;
    }
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 80);
      if (pickedFile == null) return;

      setState(() => _saving = true);

      final url = await CloudinaryService().uploadImage(pickedFile.path, folder: 'avatars');
      if (url == null) {
        setState(() => _saving = false);
        _snack('Failed to upload image. Check Cloudinary settings.', AppColors.error);
        return;
      }

      await _saveProfile(avatarUrl: url);
    } catch (e) {
      setState(() => _saving = false);
      _snack('Error selecting image: $e', AppColors.error);
    }
  }

  Future<void> _saveProfile({String? avatarUrl}) async {
    if (_nameCtrl.text.trim().length < 3) {
      _snack('Name must be at least 3 characters', AppColors.error);
      return;
    }
    setState(() => _saving = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final body = {
        'name': _nameCtrl.text.trim(),
        'email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
        'sportPreferences': _sports,
      };
      if (avatarUrl != null) {
        body['avatarUrl'] = avatarUrl;
      }

      final resp = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/users/me/update'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 8));

      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() => _saving = false);
        if (data['success'] == true) {
          Provider.of<AuthProvider>(context, listen: false)
            .updateLocalUser(data['data'] as Map<String, dynamic>);
          setState(() {
            _profile = {...?_profile, ...data['data'] as Map<String, dynamic>};
            _isEditing = false;
          });
          _snack('Profile updated successfully!', AppColors.success);
        } else {
          _snack(data['message'] ?? 'Update failed', AppColors.error);
        }
      }
    } catch (e) {
      if (mounted) { setState(() => _saving = false); _snack('Error: $e', AppColors.error); }
    }
  }

  void _showChangePasswordModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ChangePasswordSheet(),
    );
  }

  void _snack(String msg, Color color) {
    if (color == AppColors.error) {
      SnackbarUtil.showError(context, msg);
    } else {
      SnackbarUtil.showSuccess(context, msg);
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Log Out?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      content: Text('You will need to log in again.',
        style: GoogleFonts.poppins(color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),
          child: Text('Log Out', style: GoogleFonts.poppins(color: AppColors.error,
            fontWeight: FontWeight.w600))),
      ],
    ));
    if (ok == true && mounted) {
      Provider.of<AuthProvider>(context, listen: false).logout();
      Navigator.pushNamedAndRemoveUntil(context, '/welcome', (_) => false);
    }
  }

  num _parseNum(dynamic val, num fallback) {
    if (val == null) return fallback;
    if (val is num) return val;
    if (val is String) return num.tryParse(val) ?? fallback;
    return fallback;
  }

  String _formatDate(dynamic dateString) {
    if (dateString == null) return 'Unknown';
    try {
      final date = DateTime.parse(dateString.toString());
      return DateFormat('MMM d, yyyy').format(date);
    } catch (_) {
      return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_profile == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, color: AppColors.error, size: 48),
        const SizedBox(height: 12),
        Text('Could not load profile',
          style: GoogleFonts.poppins(color: AppColors.textSecondary)),
        const SizedBox(height: 12),
        TextButton(onPressed: () { setState(() => _loading = true); _load(); },
          child: Text('Retry', style: GoogleFonts.poppins(color: AppColors.accent))),
      ]));
    }

    final avatarUrl = _profile!['avatar_url'] as String?;
    final name = _profile!['name'] ?? 'Player';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    final joinedDate = _formatDate(_profile!['created_at']);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Profile', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                if (_isEditing) {
                  // Cancel changes
                  _nameCtrl.text = _profile!['name'] ?? '';
                  _emailCtrl.text = _profile!['email'] ?? '';
                  final prefs = _profile!['sport_preferences'];
                  if (prefs is List) {
                    _sports = prefs.map((e) => e.toString()).where((s) => _allowedSports.contains(s)).toList();
                  } else {
                    _sports = [];
                  }
                }
                _isEditing = !_isEditing;
              });
            },
            child: Text(
              _isEditing ? 'Cancel' : 'Edit',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.bold,
                color: _isEditing ? AppColors.textSecondary : AppColors.accent,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(children: [
          Container(
            color: Colors.white,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _pickAvatar,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 54,
                        backgroundColor: AppColors.accentLight,
                        backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                        child: avatarUrl == null
                            ? Text(initial, style: GoogleFonts.poppins(fontSize: 40, fontWeight: FontWeight.bold, color: AppColors.accent))
                            : null,
                      ),
                      if (_isEditing)
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(color: AppColors.accent, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                          child: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!_isEditing) ...[
                  Text(name, style: GoogleFonts.poppins(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_profile!['email'] ?? 'No email linked', style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text('Joined $joinedDate', style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 12)),
                ] else ...[
                  _editField('Full Name', _nameCtrl, Icons.person_outline),
                  const SizedBox(height: 12),
                  _editField('Email Address', _emailCtrl, Icons.email_outlined, type: TextInputType.emailAddress),
                ]
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Stats Row
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _statItem('⚡', '${_parseNum(_profile!['elo_rating'], 1000).round()}', 'ELO Rating', onTap: () {}),
              Container(width: 1, height: 40, color: AppColors.border),
              _statItem('🛡️', '${_parseNum(_profile!['trust_score'], 100).round()}/100', 'Trust Score', onTap: () {
                if (!_isEditing) {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => TrustScoreScreen(profile: _profile!)));
                }
              }),
            ]),
          ),

          const SizedBox(height: 12),

          // Interests
          Container(
            color: Colors.white,
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Interests', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                const SizedBox(height: 12),
                if (!_isEditing && _sports.isEmpty)
                  Text('No interests added.', style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 13, fontStyle: FontStyle.italic)),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _isEditing
                    ? _allowedSports.map((s) {
                        final selected = _sports.contains(s);
                        return FilterChip(
                          label: Text(s, style: GoogleFonts.poppins(fontSize: 13, color: selected ? Colors.white : AppColors.textPrimary, fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                          selected: selected,
                          selectedColor: AppColors.accent,
                          checkmarkColor: Colors.white,
                          backgroundColor: AppColors.inputFill,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide.none),
                          onSelected: (val) {
                            setState(() {
                              if (val) { _sports.add(s); } else { _sports.remove(s); }
                            });
                          },
                        );
                      }).toList()
                    : _sports.map((s) => Chip(
                        label: Text(s, style: GoogleFonts.poppins(fontSize: 13, color: AppColors.accent, fontWeight: FontWeight.bold)),
                        backgroundColor: AppColors.accentLight,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide.none),
                      )).toList(),
                ),
              ],
            ),
          ),

          if (_isEditing) ...[
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: CustomButton(
                text: 'Save Changes',
                isLoading: _saving,
                onPressed: () => _saveProfile(),
              ),
            ),
            const SizedBox(height: 40),
          ] else ...[
            const SizedBox(height: 12),
            Container(
              color: Colors.white,
              child: Column(
                children: [
                  _actionTile(Icons.lock_outline, 'Change Password', onTap: _showChangePasswordModal),
                  const Divider(height: 1, indent: 56),
                  _actionTile(Icons.help_outline, 'Help & Support', onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpSupportScreen()));
                  }),
                  const Divider(height: 1, indent: 56),
                  _actionTile(Icons.logout, 'Log Out', isDestructive: true, onTap: _logout),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ]
        ]),
      ),
    );
  }

  Widget _editField(String label, TextEditingController ctrl, IconData icon, {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      style: GoogleFonts.poppins(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
        prefixIcon: Icon(icon, size: 20, color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.inputFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.accent)),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }

  Widget _statItem(String emoji, String val, String label, {required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 6),
            Text(val, style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          ],
        ),
        const SizedBox(height: 4),
        Text(label, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
      ]),
    );
  }

  Widget _actionTile(IconData icon, String title, {bool isDestructive = false, required VoidCallback onTap}) {
    final color = isDestructive ? AppColors.error : AppColors.textPrimary;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDestructive ? AppColors.error.withValues(alpha: 0.1) : AppColors.inputFill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(title, style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: color)),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 20),
      onTap: onTap,
    );
  }
}

class _ChangePasswordSheet extends StatefulWidget {
  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _curCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confCtrl = TextEditingController();
  bool _saving = false;
  bool _obsCur = true;
  bool _obsNew = true;
  String? _errorMsg;

  void _showError(String msg) => setState(() => _errorMsg = msg);

  @override
  void dispose() {
    _curCtrl.dispose();
    _newCtrl.dispose();
    _confCtrl.dispose();
    super.dispose();
  }

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
          // Pop the sheet first
          Navigator.pop(context);
          // Then show success snackbar on the parent scaffold
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
    final noMatch = _confCtrl.text.isNotEmpty && _newCtrl.text != _confCtrl.text;

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
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: noMatch ? const BorderSide(color: AppColors.error) : BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: noMatch ? const BorderSide(color: AppColors.error) : BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: noMatch ? const BorderSide(color: AppColors.error) : const BorderSide(color: AppColors.accent),
              ),
            ),
          ),
          if (noMatch)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12),
              child: Text('Passwords do not match', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.error)),
            ),

          const SizedBox(height: 32),
          CustomButton(
            text: 'Change Password',
            isLoading: _saving,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
