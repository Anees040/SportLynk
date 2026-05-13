import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';

import 'owner_add_venue_screen.dart';
import 'owner_venue_management_screen.dart';

class OwnerMyVenuesScreen extends StatefulWidget {
  const OwnerMyVenuesScreen({super.key});
  @override
  State<OwnerMyVenuesScreen> createState() => _OwnerMyVenuesScreenState();
}

class _OwnerMyVenuesScreenState extends State<OwnerMyVenuesScreen> {
  List<Map<String, dynamic>> _venues = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/owner/venues'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (mounted && resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['success'] == true) {
          setState(() => _venues = List<Map<String, dynamic>>.from(data['data']));
        }
      }
    } catch (e) {
      debugPrint('Venues load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
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
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : RefreshIndicator(
              color: AppColors.accent,
              onRefresh: _load,
              child: _venues.isEmpty ? _buildEmpty() : _buildList(),
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
