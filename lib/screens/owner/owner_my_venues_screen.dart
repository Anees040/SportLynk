import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../services/offline_cache.dart';
import '../../utils/reconnect_refresh.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/offline_banner.dart';

import 'owner_add_venue_screen.dart';
import 'owner_venue_management_screen.dart';

class OwnerMyVenuesScreen extends StatefulWidget {
  const OwnerMyVenuesScreen({super.key});
  @override
  State<OwnerMyVenuesScreen> createState() => _OwnerMyVenuesScreenState();
}

class _OwnerMyVenuesScreenState extends State<OwnerMyVenuesScreen>
    with ReconnectRefresh<OwnerMyVenuesScreen> {
  List<Map<String, dynamic>> _venues = [];
  bool _loading = true;

  /// When the rows on screen were fetched, when they came from the cache. Drives
  /// the banner's "saved 10 min ago", so the pending and today's-bookings counts on
  /// each card are never mistaken for current ones.
  DateTime? _cachedAt;

  /// The failure sentence for a load that had nothing cached to fall back on.
  ///
  /// Only that case earns a full error view. Before this existed a failed request
  /// was swallowed into a `debugPrint` and the screen rendered "No venues yet —
  /// your approved venues will appear here", which tells an owner with three
  /// venues that they have none and offers to register a fourth.
  String? _error;

  /// Set once a fetch has returned rows, so a slow cache read cannot overwrite
  /// fresher ones and re-label them stale.
  bool _networkAnswered = false;

  @override
  void initState() {
    super.initState();
    // Concurrent, not chained: awaiting the disk before the request would add
    // offline latency to every online load.
    _load();
    _hydrateFromCache();
  }

  // A venue list opened offline fills itself in once the socket reconnects.
  @override
  void onReconnect() => _load();

  /// Draw the last good rows if they arrive before the network does.
  Future<void> _hydrateFromCache() async {
    final cached = await OfflineCache.read(OfflineCache.ownerVenues);
    if (!mounted || cached == null || _networkAnswered) return;
    final rows = cached.asRows();
    if (rows.isEmpty) return;
    setState(() {
      _venues = rows;
      _cachedAt = cached.at;
      _error = null;
      _loading = false;
    });
  }

  Future<void> _load() async {
    // A refresh over rows that are already drawn happens underneath them; only a
    // screen with nothing to show gets the spinner.
    final hadRows = _venues.isNotEmpty;
    if (!hadRows && mounted) setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/owner/venues'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode == 200 && data['success'] == true) {
        final raw = data['data'];
        final rows = raw is List
            ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
            : <Map<String, dynamic>>[];
        _networkAnswered = true;
        setState(() {
          _venues = rows;
          _cachedAt = null;  // on screen is now this session's data, not a saved copy
          _error = null;
          _loading = false;
        });
        context.read<ConnectivityProvider>().markReachable();
        await OfflineCache.write(OfflineCache.ownerVenues, rows);
        return;
      }
      // The server answered and refused. Connectivity is left alone: a rejected
      // request is a fault to name, not a network the owner should go and check.
      setState(() {
        _loading = false;
        _error = hadRows
            ? null
            : (data['message'] as String? ?? 'Could not load your venues.');
      });
    } catch (_) {
      // Nothing came back. The rows already on screen stay, under the offline
      // strip; only a load with no cache behind it earns the error view.
      if (!mounted) return;
      context.read<ConnectivityProvider>().markUnreachable();
      setState(() {
        _loading = false;
        _error = hadRows
            ? null
            : 'Could not reach the server. Check your connection and try again.';
      });
    }
  }

  double _parseNum(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  Future<void> _addVenue() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OwnerAddVenueScreen()),
    );
    if (result == true) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Venues', style: GoogleFonts.poppins(
            color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          OfflineBanner(cachedAt: _cachedAt),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
                // The error view replaces the list only when there was no cache to
                // fall back on, so an outage with saved rows keeps showing them.
                : _error != null
                    ? NetworkErrorView(message: _error!, onRetry: _load)
                    : RefreshIndicator(
                        color: AppColors.accent,
                        onRefresh: _load,
                        child: _venues.isEmpty ? _buildEmpty() : _buildList(),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addVenue,
        backgroundColor: AppColors.accent,
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text('Add Venue', style: GoogleFonts.poppins(
            color: Colors.white, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(28),
          decoration: const BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
          child: const Icon(Icons.stadium_outlined, size: 56, color: AppColors.accent),
        ),
        const SizedBox(height: 20),
        Text('No venues yet', style: GoogleFonts.poppins(
            fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        const SizedBox(height: 8),
        Text('Your approved venues will appear here.',
            style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _addVenue,
          icon: const Icon(Icons.add, color: Colors.white),
          label: Text('Register a Venue', style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ]),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      itemCount: _venues.length,
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      itemBuilder: (_, i) => _venueCard(_venues[i]),
    );
  }

  Widget _venueCard(Map<String, dynamic> v) {
    final photos = (v['venue_photos'] as List?) ?? [];
    final pending = _parseNum(v['pending_bookings']).toInt();
    final todays = _parseNum(v['todays_bookings']).toInt();
    final sport = (v['sport_type'] ?? 'sport').toString();
    final rating = _parseNum(v['rating']);

    return GestureDetector(
      onTap: () async {
        final res = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => OwnerVenueManagementScreen(venue: v)),
        );
        if (res == true) _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 12, offset: const Offset(0, 4))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Photo header
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          child: SizedBox(
            height: 160,
            width: double.infinity,
            child: photos.isNotEmpty
                ? Image.network(photos[0], fit: BoxFit.cover,
                    errorBuilder: (ctx, err, stack) => _sportPlaceholder(sport))
                : _sportPlaceholder(sport),
          ),
        ),

        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Name + sport chip
            Row(children: [
              Expanded(
                child: Text(v['name'] ?? 'Venue',
                    style: GoogleFonts.poppins(fontSize: 16,
                        fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
              ),
              if (v['is_active'] == false || v['is_active'] == 'false')
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.hourglass_top, color: AppColors.warning, size: 12),
                    const SizedBox(width: 4),
                    Text('PENDING',
                        style: GoogleFonts.poppins(
                            color: AppColors.warning, fontSize: 10, fontWeight: FontWeight.bold)),
                  ]),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight, borderRadius: BorderRadius.circular(20)),
                  child: Text(sport.toUpperCase(),
                      style: GoogleFonts.poppins(
                          color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ]),

            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.location_on_outlined, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Expanded(child: Text('${v['city'] ?? ''} — ${v['address'] ?? ''}',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),

            const SizedBox(height: 12),

            // Stats row
            Row(children: [
              _statBadge(Icons.pending_actions_rounded,
                  '$pending', 'Pending', const Color(0xFFFEF3C7), const Color(0xFFD97706)),
              const SizedBox(width: 10),
              _statBadge(Icons.today_rounded,
                  '$todays', 'Today', AppColors.accentLight, AppColors.accent),
              const SizedBox(width: 10),
              _statBadge(Icons.star_rounded,
                  rating > 0 ? rating.toStringAsFixed(1) : 'New', 'Rating',
                  const Color(0xFFFFFBEB), Colors.amber),
            ]),

            const SizedBox(height: 12),

            // Price + operating hours
            Row(children: [
              const Icon(Icons.payments_outlined, size: 14, color: AppColors.accent),
              const SizedBox(width: 4),
              Text('PKR ${_parseNum(v['price_per_hour']).toStringAsFixed(0)}/hr',
                  style: GoogleFonts.poppins(
                      fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.accent)),
              const Spacer(),
              const Icon(Icons.access_time_outlined, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text('${v['operating_hours_from'] ?? '06:00'} – ${v['operating_hours_to'] ?? '23:00'}',
                  style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
            ]),
          ]),
        ),
      ]),
      ),
    );
  }

  Widget _statBadge(IconData icon, String value, String label, Color bg, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: 4),
          Text(value, style: GoogleFonts.poppins(
              fontSize: 13, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: GoogleFonts.poppins(fontSize: 9, color: color)),
        ]),
      ),
    );
  }

  Widget _sportPlaceholder(String sport) {
    final icons = {
      'cricket': Icons.sports_cricket,
      'football': Icons.sports_soccer,
      'basketball': Icons.sports_basketball,
      'badminton': Icons.sports_tennis,
    };
    return Container(
      color: const Color(0xFF0A1F13),
      child: Center(
        child: Icon(icons[sport.toLowerCase()] ?? Icons.stadium,
            color: Colors.white.withValues(alpha: 0.15), size: 80),
      ),
    );
  }
}
