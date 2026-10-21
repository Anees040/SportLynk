import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/notification_bell.dart';
import '../../widgets/stable_refresh_indicator.dart';
import '../../services/review_service.dart';
import '../../utils/reconnect_refresh.dart';
import 'admin_registration_detail_screen.dart';
import 'admin_moderation_screen.dart';
import 'admin_overview_data_screen.dart';
import '../../services/admin_service.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});
  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen>
    with ReconnectRefresh<AdminHomeScreen> {
  int _navIndex = 0;
  String _ownerStatus = 'pending';
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _pending = [];
  List<Map<String, dynamic>> _approved = [];
  List<Map<String, dynamic>> _rejected = [];
  List<Map<String, dynamic>> _pendingVenues = [];
  bool _loadingStats = true;
  final Set<String> _loadingOwnerStatuses = {'pending'};
  bool _loadingVenues = true;

  /// The failure sentence for a dashboard-stats load with no prior figures to
  /// keep. Reserved for that case: with stats already on screen a transient
  /// failure leaves them rather than blanking the control center.
  String? _statsError;
  int _openFlags = 0; // reviews awaiting moderation (not yet hidden)
  // Open disputes, for the desk tile. There is no cheap count for this: the queue
  // is a keyset page sorted by what is at stake, so one page is read and the tile
  // says "50+" rather than inventing a total the server never sent.
  int _openDisputes = 0;
  bool _moreDisputes = false;

  // Permission gating (migration 040). Computed once from the signed-in admin: the
  // super admin sees every surface, a sub-admin only its granted ones. The backend
  // enforces the same keys; these only decide what the dashboard offers and which
  // tabs exist, so a sub-admin is never shown a control that would 403 on use.
  bool _isSuper = false;
  bool _canOwner = false;
  bool _canReview = false;
  bool _canMatchDisputes = false;
  bool _canBookingDisputes = false;
  bool _canUsers = false;
  bool _canSettings = false;
  bool _canReports = false;

  @override
  void initState() {
    super.initState();
    final u = Provider.of<AuthProvider>(context, listen: false).user;
    bool can(String key) =>
        (u?.isSuperAdmin ?? false) || (u?.permissions.contains(key) ?? false);
    _isSuper = u?.isSuperAdmin ?? false;
    _canOwner = can('owner_approvals');
    _canReview = can('review_moderation');
    _canMatchDisputes = can('match_disputes');
    _canBookingDisputes = can('booking_disputes');
    _canUsers = can('user_management');
    _canSettings = can('platform_settings');
    _canReports = can('financial_reports');

    // Only an owner-approvals admin gets the owner lists / venues destinations;
    // every other admin has the dashboard alone. The in-body destinations are now
    // driven by [_navIndex] and the sidebar rather than a TabController.
    _loadStats();
    if (_canOwner) {
      _loadList('pending');
      _loadVenues();
    }
    if (_canReview) _loadFlags();
    if (_canMatchDisputes) _loadDisputes();
  }

  void _selectNav(int index, {String? ownerStatus}) {
    setState(() {
      _navIndex = index;
      if (ownerStatus != null) _ownerStatus = ownerStatus;
    });
    if (index == 1) {
      _loadList(_ownerStatus);
    } else if (index == 2) {
      _loadVenues();
    }
  }

  void _selectOwnerStatus(String status) {
    if (status == _ownerStatus) return;
    setState(() => _ownerStatus = status);
    _loadList(status);
  }

  // On reconnect refresh the desk tiles and whichever list the current destination
  // shows, so an admin who was offline sees the real queue without a manual pull.
  @override
  void onReconnect() {
    _loadStats();
    if (_canReview) _loadFlags();
    if (_canMatchDisputes) _loadDisputes();
    if (!_canOwner) return;
    if (_navIndex == 1) {
      _loadList(_ownerStatus);
    } else if (_navIndex == 2) {
      _loadVenues();
    } else {
      _loadList('pending');
    }
  }

  String get _base => ApiConstants.baseUrl;
  String get _token =>
      Provider.of<AuthProvider>(context, listen: false).token ?? '';

  Future<void> _loadStats() async {
    // Spinner only when there is nothing on screen yet; a reconnect refresh over
    // existing figures happens underneath them rather than blanking the dashboard.
    if (_stats == null && mounted) setState(() => _loadingStats = true);
    try {
      final r = await http
          .get(
            Uri.parse('$_base/admin/stats'),
            headers: {'Authorization': 'Bearer $_token'},
          )
          .timeout(const Duration(seconds: 10));
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        setState(() {
          _stats = d['data'] is Map
              ? Map<String, dynamic>.from(d['data'] as Map)
              : null;
          _statsError = null;
          _loadingStats = false;
        });
      } else {
        if (mounted) {
          setState(() {
            _loadingStats = false;
            // Only an outright error view when there is no prior stats to keep on
            // screen. Before this, a failed load left [_stats] null and the hero
            // badges rendered "0 / 0 / 0" — an empty approval queue presented to the
            // admin as fact, with only a disappearing snackbar to the contrary.
            _statsError = _stats != null
                ? null
                : (d['message'] as String? ?? 'Could not load the dashboard.');
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingStats = false;
          _statsError = _stats != null
              ? null
              : 'Could not reach the server. Check your connection and try again.';
        });
      }
    }
  }

  Future<void> _loadList(String status) async {
    if (mounted) setState(() => _loadingOwnerStatuses.add(status));
    try {
      final r = await http.get(
        Uri.parse('$_base/admin/registrations?status=$status'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        final list = List<Map<String, dynamic>>.from(d['data']);
        setState(() {
          if (status == 'pending') _pending = list;
          if (status == 'approved') _approved = list;
          if (status == 'rejected') _rejected = list;
          _loadingOwnerStatuses.remove(status);
        });
      } else {
        if (mounted) {
          _snack(
            'Failed to load $status list: ${d['message'] ?? 'Unknown error'}',
          );
          setState(() => _loadingOwnerStatuses.remove(status));
        }
      }
    } catch (e) {
      if (mounted) {
        _snack('Error loading $status list: $e');
        setState(() => _loadingOwnerStatuses.remove(status));
      }
    }
  }

  Future<void> _loadVenues() async {
    if (mounted) setState(() => _loadingVenues = true);
    try {
      final r = await http.get(
        Uri.parse('$_base/admin/venues/pending'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        setState(() {
          _pendingVenues = List<Map<String, dynamic>>.from(d['data']);
          _loadingVenues = false;
        });
      } else {
        if (mounted) setState(() => _loadingVenues = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingVenues = false);
    }
  }

  // Moderation queue badge count. The count covers only reviews still awaiting a
  // decision (not yet hidden) — a review the admin already hid is "handled"
  // and should not keep the badge lit. Failure is silent: the badge simply
  // stays at its last value, never blocking the dashboard.
  Future<void> _loadDisputes() async {
    final page = await AdminService().disputes(_token, limit: 50);
    if (mounted) {
      setState(() {
        _openDisputes = page.items.length;
        _moreDisputes = page.hasMore;
      });
    }
  }

  Future<void> _loadFlags() async {
    try {
      final q = await ReviewService().moderationQueue(_token);
      if (mounted) {
        setState(() => _openFlags = q.where((r) => !r.hidden).length);
      }
    } catch (_) {
      /* keep prior count; moderation is reachable regardless */
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // Opens the moderation queue and refreshes the badge on return, so acting on
  // a review (hide/dismiss) is reflected the moment the admin comes back.
  Future<void> _openModeration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AdminModerationScreen()),
    );
    _loadFlags();
  }

  // AppBar entry to the moderation queue with a live open-flag badge.
  Widget _moderationAction() => IconButton(
    tooltip: 'Moderation queue',
    onPressed: _openModeration,
    icon: Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.flag_outlined, color: Colors.white),
        if (_openFlags > 0)
          Positioned(
            right: -4,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 16),
              decoration: BoxDecoration(
                color: AppColors.error,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.primary, width: 1.5),
              ),
              child: Text(
                _openFlags > 99 ? '99+' : '$_openFlags',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    // A back gesture off the Dashboard returns to it rather than closing the app;
    // only a back press while already on Dashboard exits.
    return PopScope(
      canPop: !_canOwner || _navIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canOwner && _navIndex != 0) _selectNav(0);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        drawer: _buildDrawer(),
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
          titleSpacing: 4,
          title: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _navTitle,
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          actions: [
            // Admins receive notifications like anyone else -- a dispute
            // raised, an owner application, a suspension they issued -- and this is
            // also the widget that starts the notification stack for the session,
            // which is why it is on all three home screens and not just the two
            // player-facing ones.
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Center(child: NotificationBell()),
            ),
            if (_canReview) _moderationAction(),
            const SizedBox(width: 8),
          ],
        ),
        // The in-body destinations keep their state across switches (IndexedStack
        // rather than swapping widgets), so returning to a half-scrolled list does
        // not reset it. Non-owner admins have only the dashboard.
        body: _canOwner
            ? IndexedStack(
                index: _navIndex,
                children: [
                  _buildDashboard(),
                  _buildOwners(),
                  _buildVenueList(),
                ],
              )
            : _buildDashboard(),
      ),
    );
  }

  /// The title names the current in-body destination, so the sidebar selection is
  /// echoed in the bar after the drawer closes.
  String get _navTitle {
    if (!_canOwner) return 'Admin Panel';
    switch (_navIndex) {
      case 1:
        return 'Owners';
      case 2:
        return 'Venues';
      default:
        return 'Admin Panel';
    }
  }

  /// The sidebar that replaced the cramped five-tab header. It lists every surface
  /// the signed-in admin may use — the in-body destinations an owner-approvals
  /// admin has, plus the external pages, each gated by the SAME permission flag the
  /// dashboard quick action and the route guard use, so a sub-admin never sees an
  /// entry that would 403.
  Widget _buildDrawer() {
    final logout = Provider.of<AuthProvider>(context, listen: false);
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.admin_panel_settings,
                    color: Colors.white,
                    size: 32,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'SportLynk Admin',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _isSuper ? 'Super admin' : 'Administrator',
                    style: GoogleFonts.poppins(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _navItem(
                    Icons.dashboard_outlined,
                    'Dashboard',
                    selected: _navIndex == 0,
                    onTap: () => _goNav(0),
                  ),
                  if (_canOwner) ...[
                    _navItem(
                      Icons.people_outline_rounded,
                      'Owners',
                      selected: _navIndex == 1,
                      onTap: () => _goNav(1),
                    ),
                    _navItem(
                      Icons.stadium_outlined,
                      'Venues',
                      selected: _navIndex == 2,
                      onTap: () => _goNav(2),
                    ),
                  ],
                  if (_canReview ||
                      _canMatchDisputes ||
                      _canBookingDisputes ||
                      _canUsers ||
                      _canSettings ||
                      _canReports ||
                      _isSuper)
                    const Divider(height: 16),
                  if (_canReview)
                    _navItem(
                      Icons.flag_outlined,
                      'Moderation Queue',
                      onTap: () {
                        Navigator.pop(context);
                        _openModeration();
                      },
                    ),
                  if (_canMatchDisputes)
                    _navItem(
                      Icons.gavel_rounded,
                      'Match Disputes',
                      onTap: () async {
                        Navigator.pop(context);
                        await Navigator.pushNamed(context, '/admin-disputes');
                        if (mounted) await _loadDisputes();
                      },
                    ),
                  if (_canBookingDisputes)
                    _navItem(
                      Icons.receipt_long_outlined,
                      'Booking Disputes',
                      onTap: () => _pushRoute('/admin-booking-disputes'),
                    ),
                  if (_canUsers)
                    _navItem(
                      Icons.manage_accounts_outlined,
                      'Users',
                      onTap: () => _pushRoute('/admin-users'),
                    ),
                  if (_canSettings)
                    _navItem(
                      Icons.tune_rounded,
                      'Platform Settings',
                      onTap: () => _pushRoute('/admin-settings'),
                    ),
                  if (_canReports)
                    _navItem(
                      Icons.summarize_outlined,
                      'Platform Report',
                      onTap: () => _pushRoute('/admin-reports'),
                    ),
                  if (_isSuper)
                    _navItem(
                      Icons.admin_panel_settings_outlined,
                      'Manage Admins',
                      onTap: () => _pushRoute('/admin-admins'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            _navItem(
              Icons.logout,
              'Log out',
              danger: true,
              onTap: () {
                logout.logout();
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/welcome',
                  (r) => false,
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Switch to an in-body destination and close the drawer.
  void _goNav(int i) {
    Navigator.pop(context);
    _selectNav(i);
  }

  /// Close the drawer, then open an external admin page.
  void _pushRoute(String route) {
    Navigator.pop(context);
    Navigator.pushNamed(context, route);
  }

  Widget _navItem(
    IconData icon,
    String label, {
    required VoidCallback onTap,
    bool selected = false,
    bool danger = false,
  }) {
    final color = danger
        ? AppColors.error
        : selected
        ? AppColors.primary
        : AppColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: selected ? AppColors.accentLight : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Icon(icon, color: color, size: 22),
          title: Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: color,
            ),
          ),
          onTap: onTap,
          minLeadingWidth: 24,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ),
    );
  }

  // Dashboard
  Widget _buildDashboard() {
    if (_loadingStats) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    // A failed first load is an error with a retry, not a control center reading
    // zero across the board — an admin acting on "0 pending" would conclude there
    // is nothing to approve.
    if (_statsError != null && _stats == null) {
      return NetworkErrorView(message: _statsError!, onRetry: _loadStats);
    }
    final s = _stats ?? {};
    return StableRefreshIndicator(
      color: AppColors.accent,
      onRefresh: () async {
        await _loadStats();
        if (_canOwner) await _loadList('pending');
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SportLynk Control Center',
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Manage owner registrations and platform activity',
                        style: GoogleFonts.poppins(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          _heroBadge(
                            Icons.pending_actions_outlined,
                            '${s['pendingRegistrations'] ?? 0}',
                            'Pending',
                            AppColors.warning,
                          ),
                          const SizedBox(width: 10),
                          _heroBadge(
                            Icons.check_circle_outline,
                            '${s['approvedOwners'] ?? 0}',
                            'Approved',
                            AppColors.accent,
                          ),
                          const SizedBox(width: 10),
                          _heroBadge(
                            Icons.cancel_outlined,
                            '${s['rejectedOwners'] ?? 0}',
                            'Rejected',
                            AppColors.error,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                Text(
                  'Platform Overview',
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),

                _twoColumnCards([
                  _statCard(
                    Icons.person_outline,
                    'Total Players',
                    '${s['totalPlayers'] ?? 0}',
                    const Color(0xFF6366F1),
                    _canUsers
                        ? () => _openOverview(AdminOverviewData.players)
                        : null,
                  ),
                  _statCard(
                    Icons.stadium_outlined,
                    'Active Venues',
                    '${s['activeVenues'] ?? 0}',
                    AppColors.primary,
                    _canOwner
                        ? () => _openOverview(AdminOverviewData.venues)
                        : null,
                  ),
                  _statCard(
                    Icons.calendar_today_outlined,
                    'Active Bookings',
                    '${s['activeBookings'] ?? 0}',
                    AppColors.warningText,
                    _canBookingDisputes
                        ? () => _openOverview(AdminOverviewData.bookings)
                        : null,
                  ),
                  _statCard(
                    Icons.pending_actions_outlined,
                    'Pending Review',
                    '${s['pendingRegistrations'] ?? 0}',
                    AppColors.error,
                    _canOwner
                        ? () => _selectNav(1, ownerStatus: 'pending')
                        : null,
                  ),
                ]),
                const SizedBox(height: 20),

                // Quick actions
                Text(
                  'Quick Actions',
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                _twoColumnCards(_quickActions(s)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _heroBadge(IconData icon, String value, String label, Color color) {
    return Expanded(
      child: Material(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _canOwner
              ? () => _selectNav(1, ownerStatus: label.toLowerCase())
              : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openOverview(AdminOverviewData data) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => AdminOverviewDataScreen(data: data),
      ),
    );
    if (mounted) await _loadStats();
  }

  // Natural row heights let labels wrap at large text sizes while keeping two
  // equal-width cards on phones, tablets and desktop windows.
  Widget _twoColumnCards(List<Widget> cards) => Column(
    children: [
      for (var i = 0; i < cards.length; i += 2) ...[
        if (i > 0) const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cards[i]),
              const SizedBox(width: 12),
              Expanded(
                child: i + 1 < cards.length
                    ? cards[i + 1]
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ],
    ],
  );

  Widget _dashboardCard({
    required String label,
    required Widget child,
    required VoidCallback? onTap,
    Color color = AppColors.accent,
  }) => Semantics(
    button: onTap != null,
    child: Material(
      key: ValueKey('admin-card-$label'),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: color.withValues(alpha: 0.18)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      ),
    ),
  );

  Widget _cardIcon(IconData icon, Color color, {required bool actionable}) =>
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          Icon(
            actionable
                ? Icons.arrow_outward_rounded
                : Icons.lock_outline_rounded,
            size: 16,
            color: AppColors.textSecondary,
          ),
        ],
      );

  Widget _statCard(
    IconData icon,
    String label,
    String value,
    Color color,
    VoidCallback? onTap,
  ) => _dashboardCard(
    label: label,
    color: color,
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _cardIcon(icon, color, actionable: onTap != null),
        const SizedBox(height: 14),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    ),
  );

  // The dashboard actions, each gated by the permission its route enforces, so a
  // sub-admin sees only what it can act on. 'Manage Admins' is the super admin's
  // alone; 'Refresh Stats' is available to every admin.
  List<Widget> _quickActions(Map<String, dynamic> s) {
    final tiles = <Widget>[];
    void add(Widget w) {
      tiles.add(w);
    }

    if (_canOwner) {
      add(
        _quickAction(
          Icons.pending_actions,
          'Review Pending Registrations',
          '${s['pendingRegistrations'] ?? 0} awaiting review',
          () => _selectNav(1, ownerStatus: 'pending'),
        ),
      );
    }
    if (_canReview) {
      add(
        _quickAction(
          Icons.flag_outlined,
          'Moderation Queue',
          _openFlags == 0
              ? 'No reviews awaiting moderation'
              : '$_openFlags ${_openFlags == 1 ? 'review' : 'reviews'} awaiting moderation',
          _openModeration,
        ),
      );
    }
    if (_canMatchDisputes) {
      // Disputes first among the desk tiles: a disputed match is frozen until someone
      // rules on it, so waiting costs the players something.
      add(
        _quickAction(
          Icons.gavel_rounded,
          'Match Disputes',
          _openDisputes == 0
              ? 'Nothing waiting'
              : '$_openDisputes${_moreDisputes ? '+' : ''} '
                    '${_openDisputes == 1 && !_moreDisputes ? 'match' : 'matches'} '
                    'waiting on a ruling',
          () async {
            await Navigator.pushNamed(context, '/admin-disputes');
            if (mounted) await _loadDisputes();
          },
        ),
      );
    }
    if (_canBookingDisputes) {
      add(
        _quickAction(
          Icons.receipt_long_outlined,
          'Booking Disputes',
          'Players reporting a problem with a booking — uphold to refund',
          () => Navigator.pushNamed(context, '/admin-booking-disputes'),
        ),
      );
    }
    if (_canUsers) {
      add(
        _quickAction(
          Icons.manage_accounts_outlined,
          'Users',
          'Search, suspend and reinstate accounts',
          () => Navigator.pushNamed(context, '/admin-users'),
        ),
      );
    }
    if (_canSettings) {
      add(
        _quickAction(
          Icons.tune_rounded,
          'Platform Settings',
          'Manage fees, deposits and sports',
          () => Navigator.pushNamed(context, '/admin-settings'),
        ),
      );
    }
    if (_canReports) {
      add(
        _quickAction(
          Icons.summarize_outlined,
          'Platform Report',
          'View earnings and export reports',
          () => Navigator.pushNamed(context, '/admin-reports'),
        ),
      );
    }
    if (_isSuper) {
      add(
        _quickAction(
          Icons.admin_panel_settings_outlined,
          'Manage Admins',
          'Manage your team and permissions',
          () => Navigator.pushNamed(context, '/admin-admins'),
        ),
      );
    }
    add(
      _quickAction(
        Icons.refresh_rounded,
        'Refresh Stats',
        'Pull latest data',
        () async {
          await _loadStats();
          if (_canOwner) await _loadList('pending');
          if (_canReview) await _loadFlags();
        },
      ),
    );
    return tiles;
  }

  Widget _quickAction(
    IconData icon,
    String title,
    String sub,
    VoidCallback onTap,
  ) => _dashboardCard(
    label: title,
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _cardIcon(icon, AppColors.accent, actionable: true),
        const SizedBox(height: 14),
        Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          sub,
          style: GoogleFonts.poppins(
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    ),
  );

  Widget _buildOwners() {
    final statusIndex = _ownerStatus == 'approved'
        ? 1
        : _ownerStatus == 'rejected'
        ? 2
        : 0;
    final filters = [
      ('pending', 'Pending', _stats?['pendingRegistrations']),
      ('approved', 'Approved', _stats?['approvedOwners']),
      ('rejected', 'Rejected', _stats?['rejectedOwners']),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Owner Registrations',
                style: GoogleFonts.poppins(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Review applications and manage venue owners',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final filter in filters)
                    ChoiceChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(filter.$2),
                          if (filter.$3 != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              '${filter.$3}',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                      selected: _ownerStatus == filter.$1,
                      onSelected: (_) => _selectOwnerStatus(filter.$1),
                      showCheckmark: false,
                      selectedColor: AppColors.accentLight,
                      backgroundColor: AppColors.inputFill,
                      side: BorderSide(
                        color: _ownerStatus == filter.$1
                            ? AppColors.primary.withValues(alpha: 0.3)
                            : Colors.transparent,
                      ),
                      labelStyle: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _ownerStatus == filter.$1
                            ? AppColors.primary
                            : AppColors.textSecondary,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 7,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: statusIndex,
            children: [
              _buildList('pending'),
              _buildList('approved'),
              _buildList('rejected'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList(String status) {
    final list = status == 'approved'
        ? _approved
        : status == 'rejected'
        ? _rejected
        : _pending;
    if (_loadingOwnerStatuses.contains(status)) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    return StableRefreshIndicator(
      onRefresh: () => _loadList(status),
      child: list.isEmpty
          ? CustomScrollView(
              key: PageStorageKey('admin-owners-$status-empty'),
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 56,
                          color: AppColors.textSecondary.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No $status registrations',
                          style: GoogleFonts.poppins(
                            color: AppColors.textSecondary,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : ListView.builder(
              key: PageStorageKey('admin-owners-$status'),
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              itemBuilder: (_, index) => _regCard(list[index]),
            ),
    );
  }

  String _getInitial(String? name) {
    if (name == null || name.trim().isEmpty) return 'O';
    return name.trim()[0].toUpperCase();
  }

  Widget _regCard(Map<String, dynamic> reg) {
    final vstatus = reg['verification_status'] as String? ?? 'pending';
    final Color statusColor = vstatus == 'approved'
        ? AppColors.accent
        : vstatus == 'rejected'
        ? AppColors.error
        : AppColors.warning;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AdminRegistrationDetailScreen(
            registration: reg,
            onReviewed: () => _loadList(vstatus),
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  _getInitial(reg['owner_name']),
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reg['owner_name'] ?? 'Unknown',
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reg['ground_name'] ??
                        reg['business_name'] ??
                        'Unnamed Ground',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on_outlined,
                            size: 12,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              reg['city'] ?? '—',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(
                            Icons.payments_outlined,
                            size: 12,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              'PKR ${reg['price_per_hour'] ?? '—'}/hr',
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    vstatus.toUpperCase(),
                    style: GoogleFonts.poppins(
                      color: statusColor,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Icon(
                  Icons.arrow_forward_ios,
                  size: 12,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _approveVenue(String venueId) async {
    try {
      final r = await http.patch(
        Uri.parse('$_base/admin/venues/$venueId/approve'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final d = jsonDecode(r.body);
      if (mounted && d['success'] == true) {
        _snack('Venue approved and is now live!');
        _loadVenues();
        _loadStats();
      } else {
        if (mounted) _snack(d['message'] ?? 'Failed');
      }
    } catch (e) {
      if (mounted) _snack('Network error');
    }
  }

  Widget _buildVenueList() {
    if (_loadingVenues) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    if (_pendingVenues.isEmpty) {
      return StableRefreshIndicator(
        onRefresh: _loadVenues,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.stadium_outlined,
                      size: 64,
                      color: AppColors.disabled,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No pending venues',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return StableRefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadVenues,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.all(16),
        itemCount: _pendingVenues.length,
        itemBuilder: (_, i) => _venueCard(_pendingVenues[i]),
      ),
    );
  }

  Widget _venueCard(Map<String, dynamic> v) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.accentLight,
                child: const Icon(Icons.stadium, color: AppColors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v['name'] ?? 'Venue',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      'Owner: ${v['owner_name'] ?? 'Unknown'}',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.location_on_outlined,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${v['city'] ?? ''} - ${v['address'] ?? ''}',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => _approveVenue(v['id']),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
              ),
              child: Text(
                'Approve Venue',
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
