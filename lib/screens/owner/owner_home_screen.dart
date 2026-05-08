import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';

class OwnerHomeScreen extends StatefulWidget {
  const OwnerHomeScreen({super.key});

  @override
  State<OwnerHomeScreen> createState() => _OwnerHomeScreenState();
}

class _OwnerHomeScreenState extends State<OwnerHomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _DashboardTab(),
          _ScheduleTab(),
          _MyVenueTab(),
          _OwnerProfileTab(),
        ],
      ),
      bottomNavigationBar: Container(
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
                _navItem(Icons.dashboard_outlined, Icons.dashboard, 'Dashboard', 0),
                _navItem(Icons.schedule_outlined, Icons.schedule, 'Schedule', 1),
                _navItem(Icons.stadium_outlined, Icons.stadium, 'My Venue', 2),
                _navItem(Icons.person_outline, Icons.person, 'Profile', 3),
              ],
            ),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(sel ? filled : outline, color: sel ? AppColors.accent : AppColors.textSecondary, size: 24),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: sel ? FontWeight.w600 : FontWeight.w400, color: sel ? AppColors.accent : AppColors.textSecondary)),
        ]),
      ),
    );
  }
}

class _DashboardTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Container(
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
                child: Center(child: Text((auth.currentUser?.name ?? 'O')[0].toUpperCase(), style: const TextStyle(color: AppColors.accent, fontSize: 20, fontWeight: FontWeight.w700))),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Hello, ${auth.currentUser?.name.split(' ').first ?? 'Owner'} 👋', style: const TextStyle(color: AppColors.white, fontSize: 20, fontWeight: FontWeight.w600)),
                Text('Manage your venues', style: TextStyle(color: AppColors.white.withValues(alpha: 0.7), fontSize: 13)),
              ])),
              Container(
                decoration: BoxDecoration(color: AppColors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                child: IconButton(onPressed: () {}, icon: const Icon(Icons.notifications_outlined, color: AppColors.white, size: 22)),
              ),
            ]),
          ]),
        ),
      ),
      // Stats cards
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(children: [
            _statCard("Today's\nBookings", '0', Icons.calendar_today, AppColors.accent),
            const SizedBox(width: 12),
            _statCard('Pending\nApprovals', '0', Icons.pending_actions, const Color(0xFFF59E0B)),
            const SizedBox(width: 12),
            _statCard("Today's\nEarnings", 'Rs.0', Icons.payments, const Color(0xFF3B82F6)),
          ]),
        ),
      ),
      // Quick actions
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Quick Actions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 14),
            _actionCard(Icons.add_business, 'Add New Venue', 'Create a new sports venue', () {}),
            const SizedBox(height: 10),
            _actionCard(Icons.calendar_month, 'Manage Slots', 'Set availability for your venues', () {}),
            const SizedBox(height: 10),
            _actionCard(Icons.qr_code_scanner, 'Scan QR Check-in', 'Verify player bookings', () {}),
            const SizedBox(height: 10),
            _actionCard(Icons.list_alt, 'View Bookings', 'Approve or reject bookings', () {}),
          ]),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }

  Widget _statCard(String label, String value, IconData icon, Color c) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.divider)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: c.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: c, size: 18),
          ),
          const SizedBox(height: 10),
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.3)),
        ]),
      ),
    );
  }

  Widget _actionCard(IconData icon, String title, String sub, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.divider)),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: AppColors.accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 2),
            Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ])),
          const Icon(Icons.chevron_right, color: AppColors.disabled),
        ]),
      ),
    );
  }
}

class _ScheduleTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.schedule, size: 64, color: AppColors.disabled),
      SizedBox(height: 16),
      Text('Schedule', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Slot management coming soon', style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
    ]));
  }
}

class _MyVenueTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.stadium, size: 64, color: AppColors.disabled),
      SizedBox(height: 16),
      Text('My Venues', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Your venues will appear here', style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
    ]));
  }
}

class _OwnerProfileTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
      const SizedBox(height: 20),
      Container(
        width: 90, height: 90,
        decoration: BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle, border: Border.all(color: AppColors.accent, width: 3)),
        child: Center(child: Text((auth.currentUser?.name ?? 'O')[0].toUpperCase(), style: const TextStyle(color: AppColors.accent, fontSize: 36, fontWeight: FontWeight.w700))),
      ),
      const SizedBox(height: 16),
      Text(auth.currentUser?.name ?? 'Owner', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      const SizedBox(height: 4),
      Text(auth.currentUser?.email ?? '', style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(12)),
        child: const Text('VENUE OWNER', style: TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 32),
      _item(Icons.phone_outlined, 'Phone', auth.currentUser?.phone ?? 'Not set'),
      _item(Icons.business, 'Business', 'Sports Complex'),
      _item(Icons.verified_outlined, 'Verification', 'Verified ✓'),
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

  Widget _item(IconData icon, String label, String value) {
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
