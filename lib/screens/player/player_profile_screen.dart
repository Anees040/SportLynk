import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/api_constants.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/custom_button.dart';
import 'trust_score_screen.dart';

class PlayerProfileScreen extends StatefulWidget {
  const PlayerProfileScreen({super.key});
  @override
  State<PlayerProfileScreen> createState() => _PlayerProfileScreenState();
}

class _PlayerProfileScreenState extends State<PlayerProfileScreen> {
  Map<String, dynamic>? _profile;
  bool _loading = true, _editing = false, _saving = false;
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  List<String> _sports = [];
  static const _allSports = ['Football', 'Cricket', 'Futsal', 'Badminton', 'Basketball'];

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
        // Use local auth data as fallback
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
              _sports = prefs.map((e) => e.toString()).toList();
            } else {
              _sports = [];
            }
            _loading = false;
          });
          return;
        }
      }
      // API failed — use local data
      _setFromAuth(auth);
    } catch (e) {
      debugPrint('Profile load error: $e');
      _setFromAuth(auth);
    }
  }

  /// Fallback: build profile from AuthProvider's cached user data
  void _setFromAuth(AuthProvider auth) {
    if (!mounted) return;
    final user = auth.currentUser;
    setState(() {
      _profile = {
        'name': user?.name ?? 'Player',
        'email': user?.email,
        'phone': user?.phone ?? '',
        'avatar_url': user?.avatarUrl,
        'created_at': null,
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

  Future<void> _save() async {
    if (_nameCtrl.text.trim().length < 3) {
      _snack('Name must be at least 3 characters', AppColors.error);
      return;
    }
    setState(() => _saving = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/users/me/update'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': _nameCtrl.text.trim(),
          'email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
          'sportPreferences': _sports,
        }),
      ).timeout(const Duration(seconds: 8));
      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() => _saving = false);
        if (data['success'] == true) {
          Provider.of<AuthProvider>(context, listen: false)
            .updateLocalUser(data['data'] as Map<String, dynamic>);
          setState(() {
            _editing = false;
            _profile = {...?_profile, ...data['data'] as Map<String, dynamic>};
          });
          _snack('Profile updated!', AppColors.accent);
        } else {
          _snack(data['message'] ?? 'Update failed', AppColors.error);
        }
      }
    } catch (e) {
      if (mounted) { setState(() => _saving = false); _snack('Error: $e', AppColors.error); }
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: color, behavior: SnackBarBehavior.floating,
    ));
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
    final name = _profile!['name'] ?? 'Player';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── APP BAR ─────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            automaticallyImplyLeading: false,
            backgroundColor: AppColors.primary,
            actions: [
              if (!_editing)
                TextButton(onPressed: () => setState(() => _editing = true),
                  child: Text('Edit', style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.w600)))
              else
                TextButton(
                  onPressed: () => setState(() {
                    _editing = false;
                    _nameCtrl.text = _profile!['name'] ?? '';
                    _emailCtrl.text = _profile!['email'] ?? '';
                    final prefs = _profile!['sport_preferences'];
                    _sports = prefs is List ? prefs.map((e) => e.toString()).toList() : [];
                  }),
                  child: Text('Cancel', style: GoogleFonts.poppins(color: Colors.white70))),
            ],
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight)),
                child: SafeArea(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center, children: [
                  const SizedBox(height: 16),
                  CircleAvatar(radius: 50,
                    backgroundColor: AppColors.accentLight,
                    child: Text(initial, style: GoogleFonts.poppins(
                      fontSize: 36, fontWeight: FontWeight.bold, color: AppColors.accent))),
                  const SizedBox(height: 10),
                  Text(name, style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_profile!['phone'] ?? '', style: GoogleFonts.poppins(
                    color: Colors.white70, fontSize: 12)),
                ])),
              ),
            ),
          ),

          // ── STATS ROW ────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              color: AppColors.primary,
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _stat('⚡', '${_numVal(_profile!['elo_rating'], 1000)}', 'ELO Rating'),
                  Container(width: 1, height: 36, color: AppColors.border),
                  _stat('🛡️', '${_numVal(_profile!['trust_score'], 100)}', 'Trust Score'),
                  Container(width: 1, height: 36, color: AppColors.border),
                  _stat('💰', 'Rs.${_numVal(_profile!['balance'], 0)}', 'Wallet'),
                ]),
              ),
            ),
          ),

          // ── TRUST SCORE BTN ──────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.shield_outlined, size: 16),
                label: Text('View Trust Score Details',
                  style: GoogleFonts.poppins(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side: const BorderSide(color: AppColors.accent),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => TrustScoreScreen(profile: _profile!))),
              ),
            ),
          ),

          // ── ACCOUNT INFO ─────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _card('Account Information', [
                _infoRow(Icons.person_outline, 'Full Name',
                  _editing
                    ? _editField(_nameCtrl, 'Your full name')
                    : Text(_profile!['name'] ?? '—', style: _val())),
                const Divider(color: AppColors.border, height: 1),
                _infoRow(Icons.phone_android, 'Phone',
                  Row(children: [
                    Text(_profile!['phone'] ?? '—', style: _val()),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.accentLight,
                        borderRadius: BorderRadius.circular(4)),
                      child: Text('Verified', style: GoogleFonts.poppins(
                        color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold))),
                  ])),
                const Divider(color: AppColors.border, height: 1),
                _infoRow(Icons.mail_outline, 'Email',
                  _editing
                    ? _editField(_emailCtrl, 'Add email (optional)',
                        keyboardType: TextInputType.emailAddress)
                    : Text(_profile!['email'] ?? 'Not added',
                        style: _val().copyWith(
                          color: _profile!['email'] != null
                            ? AppColors.textPrimary : AppColors.textSecondary,
                          fontStyle: _profile!['email'] != null
                            ? FontStyle.normal : FontStyle.italic))),
                const Divider(color: AppColors.border, height: 1),
                _infoRow(Icons.calendar_today_outlined, 'Member Since',
                  Text(_fmt(_profile!['created_at']), style: _val())),
              ]),
            ),
          ),

          // ── SPORTS ───────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _card('Sports Preferences', [
                if (!_editing)
                  _sports.isEmpty
                    ? Text('No sports added yet. Tap Edit to add.',
                        style: GoogleFonts.poppins(fontSize: 13,
                          color: AppColors.textSecondary, fontStyle: FontStyle.italic))
                    : Wrap(spacing: 8, runSpacing: 8,
                        children: _sports.map((s) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: AppColors.accentLight,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.accent.withValues(alpha: 0.3))),
                          child: Text(s, style: GoogleFonts.poppins(
                            color: AppColors.accent, fontSize: 12,
                            fontWeight: FontWeight.w500)),
                        )).toList())
                else
                  Wrap(spacing: 8, runSpacing: 8,
                    children: _allSports.map((s) => FilterChip(
                      label: Text(s, style: GoogleFonts.poppins(fontSize: 12)),
                      selected: _sports.contains(s),
                      onSelected: (v) => setState(() =>
                        v ? _sports.add(s) : _sports.remove(s)),
                      selectedColor: AppColors.accentLight,
                      checkmarkColor: AppColors.accent,
                      backgroundColor: AppColors.inputFill,
                      side: BorderSide(color: _sports.contains(s)
                        ? AppColors.accent : AppColors.border),
                    )).toList()),
              ]),
            ),
          ),

          // ── LOGOUT ───────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _card('Account', [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout, color: AppColors.error),
                  title: Text('Log Out', style: GoogleFonts.poppins(
                    color: AppColors.error, fontWeight: FontWeight.w500)),
                  onTap: _logout,
                ),
              ]),
            ),
          ),

          // ── SAVE ─────────────────────────────────────────────
          if (_editing)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                child: CustomButton(text: 'Save Changes', onPressed: _save, isLoading: _saving),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  int _numVal(dynamic v, int fallback) {
    if (v == null) return fallback;
    if (v is num) return v.round();
    return int.tryParse(v.toString()) ?? fallback;
  }

  Widget _stat(String emoji, String val, String label) => Column(children: [
    Text(emoji, style: const TextStyle(fontSize: 20)),
    const SizedBox(height: 4),
    Text(val, style: GoogleFonts.poppins(fontSize: 17,
      fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
    Text(label, style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
  ]);

  Widget _card(String title, List<Widget> children) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Text(title, style: GoogleFonts.poppins(
          fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary))),
      const Divider(color: AppColors.border, height: 1),
      Padding(padding: const EdgeInsets.all(12),
        child: Column(children: children)),
    ]),
  );

  Widget _infoRow(IconData icon, String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: AppColors.textSecondary),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 3),
        value,
      ])),
    ]),
  );

  Widget _editField(TextEditingController ctrl, String hint,
    {TextInputType keyboardType = TextInputType.text}) =>
    TextFormField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
        filled: true, fillColor: AppColors.inputFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
      ),
    );

  TextStyle _val() => GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary);

  String _fmt(String? iso) {
    if (iso == null) return 'Recently joined';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return 'Recently joined';
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }
}
