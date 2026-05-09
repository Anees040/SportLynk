# PROMPT 2 (FIXED) — Player Home + Profile Screens
# Previous attempt failed due to pseudocode. This is REAL DART CODE.
# Agent: write EXACTLY this code. Do not improvise layout.

---

## FILE 1: lib/screens/player/player_home_screen.dart

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../providers/auth_provider.dart';
import 'player_profile_screen.dart';
import 'bookings_screen.dart';
import 'wallet_screen.dart';

class PlayerHomeScreen extends StatefulWidget {
  const PlayerHomeScreen({super.key});
  @override
  State<PlayerHomeScreen> createState() => _PlayerHomeScreenState();
}

class _PlayerHomeScreenState extends State<PlayerHomeScreen> {
  int _tab = 0;
  Map<String, dynamic>? _homeData;
  bool _loading = true;
  static const _base = 'http://10.0.2.2:3000/api';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) return;
      final resp = await http.get(
        Uri.parse('$_base/player/home'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        setState(() { _homeData = data['data']; _loading = false; });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _tab,
        children: [
          _buildHome(auth),
          const BookingsScreen(),
          _teamsStub(),
          const WalletScreen(),
          const PlayerProfileScreen(),
        ],
      ),
      bottomNavigationBar: _buildNav(),
    );
  }

  Widget _buildNav() {
    final items = [
      ('Home', Icons.home_rounded, Icons.home_outlined),
      ('Bookings', Icons.calendar_month, Icons.calendar_month_outlined),
      ('Teams', Icons.groups, Icons.groups_outlined),
      ('Wallet', Icons.account_balance_wallet, Icons.account_balance_wallet_outlined),
      ('Profile', Icons.person, Icons.person_outline),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(items.length, (i) {
            final selected = _tab == i;
            return GestureDetector(
              onTap: () => setState(() => _tab = i),
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(selected ? items[i].$2 : items[i].$3,
                    color: selected ? AppColors.accent : AppColors.textSecondary, size: 24),
                  const SizedBox(height: 3),
                  Text(items[i].$1,
                    style: GoogleFonts.poppins(fontSize: 10,
                      color: selected ? AppColors.accent : AppColors.textSecondary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
                ]),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildHome(AuthProvider auth) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    final venues = (_homeData?['featuredVenues'] as List?) ?? [];
    final bookings = (_homeData?['upcomingBookings'] as List?) ?? [];
    final userName = auth.currentUser?.name ?? 'Player';
    final initial = userName.isNotEmpty ? userName[0].toUpperCase() : 'P';

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        // ── APP BAR ───────────────────────────────────────────
        SliverAppBar(
          expandedHeight: 145,
          pinned: true,
          backgroundColor: AppColors.primary,
          elevation: 0,
          automaticallyImplyLeading: false,
          flexibleSpace: FlexibleSpaceBar(
            collapseMode: CollapseMode.pin,
            background: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      CircleAvatar(radius: 20, backgroundColor: AppColors.accent,
                        child: Text(initial,
                          style: GoogleFonts.poppins(color: Colors.white,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Hello, ${userName.split(' ').first}! 👋',
                          style: GoogleFonts.poppins(color: Colors.white,
                            fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('Find and book venues',
                          style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11)),
                      ])),
                      IconButton(
                        icon: const Icon(Icons.notifications_outlined, color: Colors.white),
                        onPressed: () {},
                      ),
                    ]),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () => Navigator.pushNamed(context, '/find-venues'),
                      child: Container(
                        height: 42,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(21),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(children: [
                          const Icon(Icons.search, color: Colors.white70, size: 18),
                          const SizedBox(width: 8),
                          Text('Search venues, sports...',
                            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),

        // ── QUICK ACTIONS ──────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Quick Actions',
                style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _quickAction(Icons.sports_soccer, 'Football', const Color(0xFF22C55E), 'football'),
                _quickAction(Icons.sports_cricket, 'Cricket', const Color(0xFFF59E0B), 'cricket'),
                _quickAction(Icons.sports_tennis, 'Badminton', const Color(0xFF3B82F6), 'badminton'),
                _quickAction(Icons.sports, 'All', const Color(0xFFEC4899), ''),
              ]),
            ]),
          ),
        ),

        // ── UPCOMING BOOKINGS ──────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Upcoming Bookings',
                  style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary)),
                TextButton(
                  onPressed: () => setState(() => _tab = 1),
                  child: Text('View All',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent,
                      fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 8),
              bookings.isEmpty
                ? _emptyBookings()
                : SizedBox(
                    height: 110,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: bookings.length,
                      itemBuilder: (_, i) => _bookingCard(bookings[i]),
                    ),
                  ),
            ]),
          ),
        ),

        // ── POPULAR VENUES ─────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Popular Venues',
                style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
              TextButton(
                onPressed: () => Navigator.pushNamed(context, '/find-venues'),
                child: Text('See All',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent,
                    fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),

        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _venueCard(venues[i]),
            ),
            childCount: venues.length,
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(24)),
      ],
    );
  }

  Widget _quickAction(IconData icon, String label, Color color, String sport) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/find-venues',
        arguments: {'sport': sport}),
      child: Column(children: [
        Container(width: 58, height: 58,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color, size: 26)),
        const SizedBox(height: 6),
        Text(label, style: GoogleFonts.poppins(fontSize: 11,
          color: AppColors.textSecondary)),
      ]),
    );
  }

  Widget _emptyBookings() {
    return Container(
      height: 90,
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.calendar_today_outlined, color: AppColors.textSecondary, size: 24),
        const SizedBox(height: 6),
        Text('No upcoming bookings',
          style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/find-venues'),
          child: Text('Book now →',
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent,
              fontWeight: FontWeight.w600)),
        ),
      ])),
    );
  }

  Widget _bookingCard(Map<String, dynamic> b) {
    return Container(
      width: 240,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0A1F13), Color(0xFF166534)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(b['venue_name'] ?? 'Venue',
          style: GoogleFonts.poppins(color: Colors.white,
            fontWeight: FontWeight.bold, fontSize: 13),
          maxLines: 1, overflow: TextOverflow.ellipsis),
        Text('${b['slot_date'] ?? ''} · ${(b['start_time'] ?? '').toString().substring(0, 5)}',
          style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
          child: Text((b['status'] ?? 'confirmed').toString().toUpperCase(),
            style: GoogleFonts.poppins(color: Colors.white,
              fontSize: 9, fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }

  Widget _venueCard(Map<String, dynamic> v) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/venue-detail',
        arguments: {'venueId': v['id']}),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
            blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Container(
              height: 130, width: double.infinity,
              color: const Color(0xFF0A1F13),
              child: Stack(children: [
                const Center(child: Icon(Icons.stadium_outlined,
                  color: Colors.white24, size: 52)),
                Positioned(top: 10, right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black54,
                      borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star, color: Colors.amber, size: 12),
                      const SizedBox(width: 3),
                      Text('${v['rating'] ?? 'N/A'}',
                        style: GoogleFonts.poppins(color: Colors.white,
                          fontSize: 11, fontWeight: FontWeight.bold)),
                    ]),
                  )),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v['name'] ?? 'Venue',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 14),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.location_on_outlined,
                    color: AppColors.textSecondary, size: 13),
                  const SizedBox(width: 3),
                  Flexible(child: Text(v['city'] ?? '',
                    style: GoogleFonts.poppins(fontSize: 11,
                      color: AppColors.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.accentLight,
                    borderRadius: BorderRadius.circular(6)),
                  child: Text((v['sport_type'] ?? 'SPORT').toUpperCase(),
                    style: GoogleFonts.poppins(color: AppColors.accent,
                      fontSize: 9, fontWeight: FontWeight.bold)),
                ),
              ])),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('PKR ${(v['price_per_hour'] ?? 0).toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(color: AppColors.accent,
                    fontSize: 14, fontWeight: FontWeight.bold)),
                Text('/hour', style: GoogleFonts.poppins(fontSize: 10,
                  color: AppColors.textSecondary)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _teamsStub() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.groups_outlined, size: 72, color: AppColors.disabled),
        const SizedBox(height: 16),
        Text('Teams Coming Soon',
          style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold,
            color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Text('Challenge teams and track rankings',
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
          textAlign: TextAlign.center),
      ]),
    );
  }
}
```

---

## FILE 2: lib/screens/player/player_profile_screen.dart

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
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
  File? _avatarFile;
  List<String> _sports = [];
  static const _allSports = ['Football', 'Cricket', 'Futsal', 'Badminton', 'Basketball'];
  static const _base = 'http://10.0.2.2:3000/api';

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
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (token == null) return;
      final resp = await http.get(Uri.parse('$_base/users/me/player'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        final d = data['data'] as Map<String, dynamic>;
        setState(() {
          _profile = d;
          _nameCtrl.text = d['name'] ?? '';
          _emailCtrl.text = d['email'] ?? '';
          _sports = List<String>.from(d['sport_preferences'] ?? []);
          _loading = false;
        });
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().length < 3) {
      _snack('Name must be at least 3 characters', AppColors.error);
      return;
    }
    setState(() => _saving = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(Uri.parse('$_base/users/me/update'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': _nameCtrl.text.trim(),
          'email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
          'sportPreferences': _sports,
        }));
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

  Future<void> _pickAvatar() async {
    final p = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (p != null && mounted) setState(() => _avatarFile = File(p.path));
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
        TextButton(onPressed: _load, child: Text('Retry',
          style: GoogleFonts.poppins(color: AppColors.accent))),
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
                    _sports = List<String>.from(_profile!['sport_preferences'] ?? []);
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
                  GestureDetector(
                    onTap: _editing ? _pickAvatar : null,
                    child: Stack(children: [
                      CircleAvatar(radius: 50,
                        backgroundColor: AppColors.accentLight,
                        backgroundImage: _avatarFile != null ? FileImage(_avatarFile!) : null,
                        child: _avatarFile == null
                          ? Text(initial, style: GoogleFonts.poppins(
                              fontSize: 36, fontWeight: FontWeight.bold, color: AppColors.accent))
                          : null),
                      if (_editing)
                        Positioned(bottom: 0, right: 0,
                          child: CircleAvatar(radius: 16, backgroundColor: AppColors.accent,
                            child: const Icon(Icons.camera_alt, size: 14, color: Colors.white))),
                    ]),
                  ),
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
                  _stat('⚡', '${(_profile!['elo_rating'] ?? 1000).round()}', 'ELO Rating'),
                  Container(width: 1, height: 36, color: AppColors.border),
                  _stat('🛡️', '${_profile!['trust_score'] ?? 100}', 'Trust Score'),
                  Container(width: 1, height: 36, color: AppColors.border),
                  _stat('💰', 'Rs.${(_profile!['balance'] ?? 0).round()}', 'Wallet'),
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
                            border: Border.all(color: AppColors.accent.withOpacity(0.3))),
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
                child: CustomButton('Save Changes', _save, isLoading: _saving),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(32)),
        ],
      ),
    );
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
    if (iso == null) return 'Unknown';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return 'Unknown';
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }
}
```

---

## FILE 3: lib/screens/player/trust_score_screen.dart

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';

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
              border: Border.all(color: AppColors.accent.withOpacity(0.3))),
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
```

---

## STUB FILES (create empty stubs so app compiles)

### lib/screens/player/bookings_screen.dart
```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';

class BookingsScreen extends StatelessWidget {
  const BookingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(title: Text('My Bookings',
      style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: AppColors.primary, automaticallyImplyLeading: false),
    body: const Center(child: Text('Bookings coming in next prompt')),
  );
}
```

### lib/screens/player/wallet_screen.dart
```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/app_colors.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(title: Text('My Wallet',
      style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: AppColors.primary, automaticallyImplyLeading: false),
    body: const Center(child: Text('Wallet coming in next prompt')),
  );
}
```

---

## ROUTES — Add in main.dart
```dart
'/player-home': (_) => AuthGuard(child: const PlayerHomeScreen()),
'/trust-score': (_) => AuthGuard(child: const TrustScoreScreen(profile: {})),
```
Note: TrustScoreScreen is pushed via Navigator.push directly (not named route) since it needs profile data.

## AFTER IMPLEMENTING
Run: flutter analyze
Expected: 0 errors.
Check: http://10.0.2.2:3000/api/player/home returns data.
The home screen shows venues loaded from DB.
Profile screen shows player name, phone, stats loaded from DB.
