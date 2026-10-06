import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../services/api_service.dart';
import '../../services/offline_cache.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/offline_banner.dart';
import '../../services/cloudinary_service.dart';
import 'trust_score_screen.dart';
import '../../utils/reconnect_refresh.dart';
import '../../utils/snackbar_util.dart';
import 'help_support_screen.dart';

class PlayerProfileScreen extends StatefulWidget {
  const PlayerProfileScreen({super.key});
  @override
  State<PlayerProfileScreen> createState() => _PlayerProfileScreenState();
}

class _PlayerProfileScreenState extends State<PlayerProfileScreen>
    with ReconnectRefresh<PlayerProfileScreen> {
  final _api = ApiClient();

  Map<String, dynamic>? _profile;
  bool _loading = true, _saving = false;
  bool _isEditing = false;
  // The human-readable reason the last load failed, or null when it succeeded.
  // A non-null error with no cached profile is what drives the retry view — the
  // screen never invents stats to fill the gap.
  String? _error;

  /// When the shown profile came from the cache rather than this session's fetch.
  /// Drives the offline strip's "saved 10 min ago", so an ELO or trust score read
  /// from disk is never mistaken for a live one.
  DateTime? _cachedAt;

  /// Set once the network has answered, so a slow cache read landing afterwards
  /// cannot overwrite the fresher profile and re-label it stale.
  bool _networkAnswered = false;

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  List<String> _sports = [];
  static const _allowedSports = ['Football', 'Cricket'];

  @override
  void initState() {
    super.initState();
    // Concurrent, not chained: the cache paints the last profile instantly while
    // the fetch refreshes it, so a cold or offline open is never a spinner.
    _load();
    _hydrateFromCache();
  }

  // Fill in the moment connectivity returns. A cached profile is refreshed too
  // (its stats are stale and nothing else updates elo/trust), unlike a live one
  // which AuthProvider already keeps current for the identity fields.
  @override
  void onReconnect() {
    if (_profile == null || _cachedAt != null) _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  /// Draw the last good profile if it arrives before the network does.
  Future<void> _hydrateFromCache() async {
    final cached = await OfflineCache.read(OfflineCache.playerProfile);
    if (!mounted || cached == null || _networkAnswered) return;
    final data = cached.asMap();
    if (data == null) return;
    setState(() {
      _profile = data;
      _cachedAt = cached.at;
      _error = null;
      _nameCtrl.text = data['name'] ?? '';
      _emailCtrl.text = data['email'] ?? '';
      final prefs = data['sport_preferences'];
      _sports = prefs is List
          ? prefs.map((e) => e.toString()).where((s) => _allowedSports.contains(s)).toList()
          : [];
      _loading = false;
    });
  }

  Future<void> _load() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token == null || token.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Your session has expired. Please log in again.';
        });
      }
      return;
    }
    if (mounted && _profile == null) setState(() => _loading = true);
    // ApiClient owns the cold/warm timeout and never throws: a slow or absent
    // server comes back as {success: false, message: <sentence>}, which becomes
    // the retry view rather than a fabricated set of stats.
    final resp = await _api.get('/users/me/player', token: token);
    if (!mounted) return;
    if (resp['success'] == true && resp['data'] is Map) {
      final d = Map<String, dynamic>.from(resp['data'] as Map);
      _networkAnswered = true;
      setState(() {
        _profile = d;
        _cachedAt = null;  // on screen is now this session's data, not a saved copy
        _error = null;
        _nameCtrl.text = d['name'] ?? '';
        _emailCtrl.text = d['email'] ?? '';
        final prefs = d['sport_preferences'];
        _sports = prefs is List
            ? prefs.map((e) => e.toString()).where((s) => _allowedSports.contains(s)).toList()
            : [];
        _loading = false;
      });
      context.read<ConnectivityProvider>().markReachable();
      await OfflineCache.write(OfflineCache.playerProfile, d);
    } else {
      // `statusCode == 0` is ApiClient's transport failure — the offline case, so
      // the cached profile (if any) stays under the strip and only a load with
      // nothing cached becomes the retry view.
      if (resp['statusCode'] == 0) {
        context.read<ConnectivityProvider>().markUnreachable();
      }
      setState(() {
        _loading = false;
        _error = _profile != null
            ? null
            : '${resp['message'] ?? 'Could not load your profile.'}';
      });
    }
  }

  Future<void> _pickAvatar() async {
    if (!_isEditing) return;
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

  Future<void> _saveProfile({String? avatarUrl}) async {    if (_nameCtrl.text.trim().length < 3) {
      _snack('Name must be at least 3 characters', AppColors.error);
      return;
    }
    setState(() => _saving = true);
    final token = Provider.of<AuthProvider>(context, listen: false).token!;
    final body = <String, dynamic>{
      'name': _nameCtrl.text.trim(),
      'email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
      'sportPreferences': _sports,
    };
    if (avatarUrl != null) body['avatarUrl'] = avatarUrl;

    final data = await _api.patch('/users/me/update', body, token: token);
    if (!mounted) return;
    setState(() => _saving = false);
    if (data['success'] == true && data['data'] is Map) {
      final updated = Map<String, dynamic>.from(data['data'] as Map);
      Provider.of<AuthProvider>(context, listen: false).updateLocalUser(updated);
      setState(() {
        _profile = {...?_profile, ...updated};
        _isEditing = false;
      });
      // Keep the saved copy in step with the edit, so a reopen offline shows the
      // new name/avatar rather than the pre-edit profile.
      await OfflineCache.write(OfflineCache.playerProfile, _profile);
      _snack('Profile updated successfully!', AppColors.success);
    } else {
      // ApiClient's message is already phrased for the user (offline, timeout, or
      // the server's own validation text) — surface it as-is rather than a red block.
      _snack('${data['message'] ?? 'Update failed'}', AppColors.error);
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

  /// Flip the profile between public and private. The switch moves at once so the
  /// control feels live; a failed write reverts it and surfaces the reason, rather
  /// than leaving the toggle claiming a state the server did not accept.
  Future<void> _setVisibility(bool value) async {
    if (_profile == null) return;
    final prev = _profile!['is_public'] != false;
    if (prev == value) return;
    setState(() => _profile!['is_public'] = value);
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) return;
    final data = await _api.patch('/users/me/update', {'isPublic': value}, token: token);
    if (!mounted) return;
    if (data['success'] != true) {
      setState(() => _profile!['is_public'] = prev);
      _snack('${data['message'] ?? 'Could not update visibility.'}', AppColors.error);
    }
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

  /// The bare title bar used by the error state, which has no profile to edit.
  /// Inherits the app-wide green [AppBarTheme] rather than overriding it to white,
  /// so the Profile screen reads with the same header as every other screen.
  AppBar _appBar() => AppBar(
        title: Text('My Profile', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      );

  @override
  Widget build(BuildContext context) {
    // Watch, not read: when `_refreshProfile` populates the full identity
    // (name/email/avatar) after the app opened on the JWT alone, this rebuilds
    // with the real values instead of waiting for a manual pull.
    final auth = context.watch<AuthProvider>();

    if (_loading && _profile == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_profile == null) {
      // No stats to show and the fetch failed: the mandated retry state, never
      // invented numbers standing in for a profile that did not load.
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: _appBar(),
        body: RefreshIndicator(
          color: AppColors.accent,
          onRefresh: _load,
          child: NetworkErrorView(
            title: 'Could not load profile',
            message: _error ?? 'Please try again.',
            onRetry: _load,
          ),
        ),
      );
    }

    // Profile-first, identity from the provider as the fallback — so a field the
    // player endpoint omits still shows the value already known from the session.
    final user = auth.currentUser;
    final avatarUrl = (_profile!['avatar_url'] as String?) ?? user?.avatarUrl;
    final name = '${_profile!['name'] ?? user?.name ?? 'Player'}';
    final email = (_profile!['email'] as String?) ?? user?.email;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    final joinedDate = _formatDate(_profile!['created_at']);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Profile', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
        elevation: 0,
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
                // On the green header the accent green read poorly; white (and a
                // dimmed white for Cancel) matches the inherited foreground.
                color: _isEditing ? Colors.white70 : Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          OfflineBanner(cachedAt: _cachedAt),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.accent,
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
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
                  Text(email ?? 'No email linked', style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 14)),
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
                  Navigator.push(context, MaterialPageRoute(builder: (_) => TrustScoreScreen(
                    userId: context.read<AuthProvider>().currentUser?.id,
                    profile: _profile!,
                    displayName: _profile!['name']?.toString(),
                    isSelf: true,
                  )));
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
              child: SwitchListTile(
                value: _profile!['is_public'] != false,
                onChanged: _setVisibility,
                activeThumbColor: AppColors.accent,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                secondary: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.inputFill,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _profile!['is_public'] != false ? Icons.public : Icons.lock_outline,
                    color: AppColors.textPrimary, size: 20),
                ),
                title: Text('Public profile',
                    style: GoogleFonts.poppins(
                        fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                subtitle: Text(
                  _profile!['is_public'] != false
                      ? 'Anyone can see your sports and teams and send you play requests.'
                      : 'Only your name, photo and scores are visible. Others cannot open your profile or ask you to play.',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                ),
              ),
            ),
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
              ),
            ),
          ],
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
    final token = Provider.of<AuthProvider>(context, listen: false).token!;
    final data = await ApiClient().post(
      '/users/me/change-password',
      {'currentPassword': cur, 'newPassword': newP},
      token: token,
    );
    if (!mounted) return;
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
      // ApiClient's message already reads for a user offline or on a bad password.
      _showError('${data['message'] ?? 'Failed to change password'}');
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
