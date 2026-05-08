import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';

class PlayerHomeScreen extends StatefulWidget {
  const PlayerHomeScreen({super.key});

  @override
  State<PlayerHomeScreen> createState() => _PlayerHomeScreenState();
}

class _PlayerHomeScreenState extends State<PlayerHomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _HomeTab(),
          _PlaceholderTab(icon: Icons.calendar_today, title: 'My Bookings', sub: 'Your bookings will appear here'),
          _PlaceholderTab(icon: Icons.lock_outline, title: 'Teams Coming Soon', sub: 'Available in FYP-2'),
          _PlaceholderTab(icon: Icons.account_balance_wallet, title: 'Wallet Coming Soon', sub: 'View balance & transactions'),
          _ProfileTab(),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 16, offset: const Offset(0, -4))],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(Icons.home_outlined, Icons.home, 'Home', 0),
              _navItem(Icons.calendar_today_outlined, Icons.calendar_today, 'Bookings', 1),
              _navItem(Icons.groups_outlined, Icons.groups, 'Teams', 2),
              _navItem(Icons.account_balance_wallet_outlined, Icons.account_balance_wallet, 'Wallet', 3),
              _navItem(Icons.person_outline, Icons.person, 'Profile', 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(IconData outline, IconData filled, String label, int idx) {
    final sel = _currentIndex == idx;
    return InkWell(
      onTap: () => setState(() => _currentIndex = idx),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(sel ? filled : outline, color: sel ? AppColors.accent : AppColors.textSecondary, size: 24),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: sel ? FontWeight.w600 : FontWeight.w400, color: sel ? AppColors.accent : AppColors.textSecondary)),
        ]),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(child: _header(context, auth)),
      SliverToBoxAdapter(child: _quickActions()),
      SliverToBoxAdapter(child: _venuesPlaceholder()),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }

  Widget _header(BuildContext context, AuthProvider auth) {
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 16, left: 20, right: 20, bottom: 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF143D20), AppColors.primary]),
        borderRadius: BorderRadius.only(bottomLeft: Radius.circular(24), bottomRight: Radius.circular(24)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 46, height: 46,
            decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.2), shape: BoxShape.circle),
            child: Center(child: Text((auth.currentUser?.name ?? 'U')[0].toUpperCase(), style: const TextStyle(color: AppColors.accent, fontSize: 20, fontWeight: FontWeight.w700))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Hello, ${auth.currentUser?.name.split(' ').first ?? 'Player'} 👋', style: const TextStyle(color: AppColors.white, fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Find and book sports venues', style: TextStyle(color: AppColors.white.withValues(alpha: 0.7), fontSize: 13)),
          ])),
          Container(
            decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
            child: IconButton(onPressed: () {}, icon: const Icon(Icons.notifications_outlined, color: AppColors.white, size: 22)),
          ),
        ]),
        const SizedBox(height: 20),
        Container(
          decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14)),
          child: TextField(
            readOnly: true,
            decoration: InputDecoration(
              hintText: 'Search venues, sports...', hintStyle: TextStyle(color: AppColors.white.withValues(alpha: 0.5), fontSize: 14),
              prefixIcon: Icon(Icons.search, color: AppColors.white.withValues(alpha: 0.6)),
              border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _quickActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Quick Actions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        const SizedBox(height: 14),
        Row(children: [
          _chip(Icons.sports_soccer, 'Football', AppColors.accent),
          const SizedBox(width: 12),
          _chip(Icons.sports_cricket, 'Cricket', const Color(0xFFF59E0B)),
          const SizedBox(width: 12),
          _chip(Icons.sports_tennis, 'Badminton', const Color(0xFF3B82F6)),
          const SizedBox(width: 12),
          _chip(Icons.sports, 'Futsal', const Color(0xFFEF4444)),
        ]),
      ]),
    );
  }

  Widget _chip(IconData icon, String label, Color c) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: c.withValues(alpha: 0.15))),
        child: Column(children: [
          Icon(icon, color: c, size: 28), const SizedBox(height: 6),
          Text(label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _venuesPlaceholder() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Popular Venues', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          TextButton(onPressed: () {}, child: const Text('See All', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600, fontSize: 13))),
        ]),
        const SizedBox(height: 8),
        Container(
          height: 160,
          decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.divider)),
          child: const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.stadium, size: 48, color: AppColors.disabled),
            SizedBox(height: 8),
            Text('Venue list loading...', style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          ])),
        ),
      ]),
    );
  }
}

class _PlaceholderTab extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  const _PlaceholderTab({required this.icon, required this.title, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 80, height: 80,
        decoration: const BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
        child: Icon(icon, size: 40, color: AppColors.accent),
      ),
      const SizedBox(height: 20),
      Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      const SizedBox(height: 8),
      Text(sub, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
    ]));
  }
}

class _ProfileTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
      const SizedBox(height: 20),
      Container(
        width: 90, height: 90,
        decoration: BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle, border: Border.all(color: AppColors.accent, width: 3)),
        child: Center(child: Text((auth.currentUser?.name ?? 'U')[0].toUpperCase(), style: const TextStyle(color: AppColors.accent, fontSize: 36, fontWeight: FontWeight.w700))),
      ),
      const SizedBox(height: 16),
      Text(auth.currentUser?.name ?? 'User', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      const SizedBox(height: 4),
      Text(auth.currentUser?.email ?? '', style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(12)),
        child: Text(auth.currentUser?.role.toUpperCase() ?? 'PLAYER', style: const TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 32),
      _profileItem(Icons.phone_outlined, 'Phone', auth.currentUser?.phone ?? 'Not set'),
      _profileItem(Icons.sports_soccer, 'Favourite Sport', 'Football'),
      _profileItem(Icons.star_outline, 'Trust Score', '100/100'),
      const SizedBox(height: 32),
      SizedBox(
        width: double.infinity, height: 50,
        child: ElevatedButton.icon(
          onPressed: () { auth.logout(); Navigator.pushNamedAndRemoveUntil(context, '/welcome', (r) => false); },
          icon: const Icon(Icons.logout, size: 20),
          label: const Text('Logout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.error.withValues(alpha: 0.1), foregroundColor: AppColors.error, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        ),
      ),
    ])));
  }

  Widget _profileItem(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.divider)),
      child: Row(children: [
        Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: AppColors.accent, size: 20)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        ])),
      ]),
    );
  }
}
