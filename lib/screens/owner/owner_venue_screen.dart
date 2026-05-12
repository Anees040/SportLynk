import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';

class OwnerVenueScreen extends StatefulWidget {
  const OwnerVenueScreen({super.key});
  @override
  State<OwnerVenueScreen> createState() => _OwnerVenueScreenState();
}

class _OwnerVenueScreenState extends State<OwnerVenueScreen> {
  Map<String, dynamic>? _venue;
  Map<String, dynamic>? _analytics;
  bool _loading = true;
  static String get _base => ApiConstants.baseUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final venueResp = http.get(Uri.parse('$_base/owner/venue'), headers: {'Authorization': 'Bearer $token'});
      final analyticsResp = http.get(Uri.parse('$_base/owner/analytics'), headers: {'Authorization': 'Bearer $token'});
      final results = await Future.wait([venueResp, analyticsResp]);
      if (mounted) {
        final vData = jsonDecode(results[0].body);
        final aData = jsonDecode(results[1].body);
        setState(() {
          _venue = vData['success'] == true ? vData['data'] : null;
          _analytics = aData['success'] == true ? aData['data'] : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  double _parseNum(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.accent));

    final monthTotal = _parseNum(_analytics?['monthTotal']);
    final weeklyData = (_analytics?['weeklyRevenue'] as List?) ?? [];
    final maxRevenue = weeklyData.isEmpty
        ? 1.0
        : weeklyData.map((w) => _parseNum(w['revenue'])).reduce((a, b) => a > b ? a : b);

    final groundPhotos = (_venue?['venue_photos'] as List?) ?? [];
    final sportType = _venue?['sport_type'] as String?;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Venue Operations', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
            child: Text('LIVE', style: GoogleFonts.poppins(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── ANALYTICS ────────────────────────────────
            Text('Analytics', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      'REVENUE TREND (THIS MONTH)',
                      style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary, letterSpacing: 0.4),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'PKR ${monthTotal.toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                  ]),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.trending_up, color: AppColors.accent, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        weeklyData.isNotEmpty ? '+12%' : '0%',
                        style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ]),
                  ),
                ]),
                const SizedBox(height: 20),
                // Revenue bar chart
                weeklyData.isEmpty
                    ? Container(
                        height: 80,
                        decoration: BoxDecoration(color: AppColors.inputFill, borderRadius: BorderRadius.circular(8)),
                        child: Center(
                          child: Text(
                            'No check-ins yet. Revenue shows after player scans.',
                            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : SizedBox(
                        height: 80,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: weeklyData.asMap().entries.map((e) {
                            final revenue = _parseNum(e.value['revenue']);
                            final h = maxRevenue > 0 ? (revenue / maxRevenue) * 70 : 4.0;
                            return Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                              Container(
                                width: 32,
                                height: h.clamp(4.0, 70.0),
                                decoration: BoxDecoration(
                                  color: AppColors.accent.withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text('W${e.key + 1}', style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
                            ]);
                          }).toList(),
                        ),
                      ),
              ]),
            ),
            const SizedBox(height: 20),

            // ── VENUE IMAGE GALLERY ───────────────────────
            Text('Venue Image Gallery', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            groundPhotos.isEmpty
                ? _buildPhotoPlaceholders(sportType)
                : SizedBox(
                    height: 130,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: groundPhotos.length + 1,
                      itemBuilder: (_, i) {
                        if (i == groundPhotos.length) return _addPhotoBtn();
                        final label = ['Main Court', 'Training Zone', 'Entrance'][i % 3];
                        return Container(
                          width: 140,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(12)),
                          child: Stack(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(
                                groundPhotos[i].toString(),
                                width: double.infinity,
                                height: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (_, e, st) => Container(color: AppColors.primary, child: const Icon(Icons.image_outlined, color: Colors.white24, size: 40)),
                              ),
                            ),
                            Positioned(
                              bottom: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                                child: Text(label, style: GoogleFonts.poppins(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
            const SizedBox(height: 20),

            // ── VENUE DETAILS ─────────────────────────────
            Text('Venue Details', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
              child: Column(children: [
                _infoRow(Icons.business_outlined, 'Name', _venue?['name'] ?? '—'),
                const Divider(color: AppColors.border),
                _infoRow(Icons.location_on_outlined, 'Address', _venue?['address'] ?? '—'),
                const Divider(color: AppColors.border),
                _infoRow(
                  Icons.access_time_outlined,
                  'Hours',
                  '${_venue?['operating_hours_from'] ?? '06:00'} – ${_venue?['operating_hours_to'] ?? '23:00'}',
                ),
                const Divider(color: AppColors.border),
                _infoRow(
                  Icons.currency_rupee,
                  'Price/Hour',
                  'PKR ${_parseNum(_venue?['price_per_hour']).toStringAsFixed(0)}',
                ),
                if (sportType != null) ...[
                  const Divider(color: AppColors.border),
                  Row(children: [
                    const Icon(Icons.sports, size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(6)),
                      child: Text(
                        sportType,
                        style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ]),
                ],
              ]),
            ),
            const SizedBox(height: 20),

            // ── FINANCIALS ────────────────────────────────
            Text('Financials', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
              child: Column(children: [
                _finRow('This Month Revenue', 'PKR ${monthTotal.toStringAsFixed(0)}', AppColors.success),
                const Divider(color: AppColors.border),
                _finRow(
                  'Total Bookings (Month)',
                  '${weeklyData.fold(0, (s, w) => s + (int.tryParse(w['total_bookings']?.toString() ?? '') ?? 0))}',
                  AppColors.accent,
                ),
                const Divider(color: AppColors.border),
                _finRow(
                  'Avg per Booking',
                  weeklyData.isEmpty ? 'PKR 0' : 'PKR ${(monthTotal / weeklyData.length).toStringAsFixed(0)}',
                  AppColors.textPrimary,
                ),
              ]),
            ),
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }

  Widget _buildPhotoPlaceholders(String? sportType) {
    final labels = ['Main Court', 'Training Zone'];
    return SizedBox(
      height: 130,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        ...List.generate(2, (i) => Container(
          width: 140,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(12)),
          child: Stack(children: [
            Center(child: Icon(Icons.stadium_outlined, color: Colors.white24, size: 40)),
            Positioned(
              bottom: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                child: Text(labels[i], style: GoogleFonts.poppins(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        )),
        _addPhotoBtn(),
      ]),
    );
  }

  Widget _addPhotoBtn() => Container(
        width: 120,
        height: 120,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.add_photo_alternate_outlined, color: AppColors.accent, size: 28),
          const SizedBox(height: 4),
          Text('Add Photo', style: GoogleFonts.poppins(fontSize: 11, color: AppColors.accent)),
        ]),
      );

  Widget _infoRow(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
              const SizedBox(height: 2),
              Text(value, style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textPrimary)),
            ]),
          ),
        ]),
      );

  Widget _finRow(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
          Text(value, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        ]),
      );
}
