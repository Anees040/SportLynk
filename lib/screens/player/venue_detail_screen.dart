import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import 'confirm_booking_screen.dart';

class VenueDetailScreen extends StatefulWidget {
  final String venueId;
  const VenueDetailScreen({super.key, required this.venueId});
  @override
  State<VenueDetailScreen> createState() => _VenueDetailScreenState();
}

class _VenueDetailScreenState extends State<VenueDetailScreen> {
  Map<String, dynamic>? _venue;
  List<Map<String, dynamic>> _slots = [];
  bool _loading = true;
  DateTime _selectedDate = DateTime.now();
  String? _selectedSlotId;
  Map<String, dynamic>? _selectedSlot;
  int _galleryPage = 0;
  final PageController _galleryCtrl = PageController();

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _galleryCtrl.dispose(); super.dispose(); }

  String _dateStr(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  Future<void> _load([DateTime? date]) async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final d = date ?? _selectedDate;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/venues/${widget.venueId}?date=${_dateStr(d)}'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        setState(() {
          _venue = data['data'];
          _slots = List<Map<String,dynamic>>.from(data['data']['slots'] ?? []);
          _loading = false;
          _selectedSlotId = null; _selectedSlot = null;
        });
      } else { if (mounted) setState(() => _loading = false); }
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  double _parseDouble(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }

  /// Convert "HH:MM:SS" or "HH:MM" to 12-hour AM/PM format
  String _to12Hour(dynamic t) {
    if (t == null) return '';
    final str = t.toString();
    final parts = str.split(':');
    if (parts.length < 2) return str;
    int hour = int.tryParse(parts[0]) ?? 0;
    final min = parts[1];
    final ampm = hour >= 12 ? 'PM' : 'AM';
    if (hour == 0) {
      hour = 12;
    } else if (hour > 12) {
      hour -= 12;
    }
    return '$hour:$min $ampm';
  }

  /// Get gallery images from venue_photos array
  List<String> get _galleryImages {
    if (_venue == null) return [];
    final photos = _venue!['venue_photos'];
    if (photos is List && photos.isNotEmpty) {
      return photos.map((e) => e.toString()).toList();
    }
    // Fallback to single image_url
    if (_venue!['image_url'] != null) return [_venue!['image_url'].toString()];
    return [];
  }

  /// Parse amenities from JSONB
  Map<String, dynamic> get _amenities {
    if (_venue == null) return {};
    final a = _venue!['amenities'];
    if (a is Map) return Map<String, dynamic>.from(a);
    if (a is String) {
      try { return Map<String, dynamic>.from(jsonDecode(a)); } catch(_) {}
    }
    return {};
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(backgroundColor: AppColors.background,
        body: const Center(child: CircularProgressIndicator(color: AppColors.accent)));
    }
    if (_venue == null) {
      return Scaffold(appBar: AppBar(backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white)),
        body: Center(child: Text('Venue not found',
          style: GoogleFonts.poppins(color: AppColors.textSecondary))));
    }

    final price = _parseDouble(_venue!['price_per_hour']);
    final sportType = (_venue!['sport_type'] ?? 'sport').toString();
    final images = _galleryImages;

    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: _bottomBar(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── HERO GALLERY ─────────────────────────────────────
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: AppColors.primary,
            iconTheme: const IconThemeData(color: Colors.white),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(children: [
                if (images.isNotEmpty)
                  PageView.builder(
                    controller: _galleryCtrl,
                    itemCount: images.length,
                    onPageChanged: (i) => setState(() => _galleryPage = i),
                    itemBuilder: (_, i) => Image.network(images[i],
                      fit: BoxFit.cover, width: double.infinity,
                      errorBuilder: (_, e, st) => _gradientPlaceholder(sportType)),
                  )
                else
                  _gradientPlaceholder(sportType),
                // Gradient overlay at bottom
                Positioned.fill(child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      stops: const [0.4, 1.0],
                      colors: [Colors.transparent,
                        Colors.black.withValues(alpha: 0.75)])))),
                // Page indicator dots
                if (images.length > 1)
                  Positioned(bottom: 70, left: 0, right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(images.length, (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: _galleryPage == i ? 24 : 8, height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: _galleryPage == i ? Colors.white : Colors.white54,
                          borderRadius: BorderRadius.circular(4)),
                      )),
                    ),
                  ),
                // Photo count badge
                if (images.length > 1)
                  Positioned(top: 100, right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black54,
                        borderRadius: BorderRadius.circular(10)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.photo_library_outlined, color: Colors.white, size: 14),
                        const SizedBox(width: 4),
                        Text('${_galleryPage + 1}/${images.length}',
                          style: GoogleFonts.poppins(color: Colors.white,
                            fontSize: 12, fontWeight: FontWeight.w600)),
                      ]))),
                // Rating badge
                Positioned(top: 100, left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black45,
                      borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                      const SizedBox(width: 4),
                      Text('${_venue!['rating'] ?? '0.0'}',
                        style: GoogleFonts.poppins(color: Colors.white,
                          fontSize: 13, fontWeight: FontWeight.bold)),
                      Text(' (${_venue!['total_reviews'] ?? 0})',
                        style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11)),
                    ]))),
                // Venue name at bottom of hero
                Positioned(bottom: 16, left: 16, right: 16,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _sportColor(sportType),
                        borderRadius: BorderRadius.circular(8)),
                      child: Text(sportType.toUpperCase(),
                        style: GoogleFonts.poppins(color: Colors.white,
                          fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5))),
                    const SizedBox(height: 8),
                    Text(_venue!['name'] ?? '', style: GoogleFonts.poppins(
                      fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                  ])),
              ]),
            ),
          ),

          // ── VENUE INFO CARD ──────────────────────────────
          SliverToBoxAdapter(
            child: Transform.translate(offset: const Offset(0, -20),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 16, offset: const Offset(0, 4))]),
                child: Column(children: [
                  // Price row
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Row(children: [
                      Container(padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: AppColors.accentLight,
                          borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.payments_outlined, color: AppColors.accent, size: 20)),
                      const SizedBox(width: 10),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Price per Hour', style: GoogleFonts.poppins(
                          fontSize: 11, color: AppColors.textSecondary)),
                        Text('PKR ${price.toStringAsFixed(0)}',
                          style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold,
                            color: AppColors.accent)),
                      ]),
                    ]),
                    if (_venue!['ground_type'] != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: AppColors.inputFill,
                          borderRadius: BorderRadius.circular(8)),
                        child: Text((_venue!['ground_type']).toString().toUpperCase(),
                          style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.bold,
                            color: AppColors.textSecondary, letterSpacing: 0.5))),
                  ]),
                  const Divider(color: AppColors.border, height: 24),
                  // Location
                  _infoRow(Icons.location_on_outlined,
                    _venue!['address'] ?? _venue!['city'] ?? ''),
                  const SizedBox(height: 8),
                  // Hours
                  _infoRow(Icons.access_time_outlined,
                    '${_venue!['operating_hours_from'] ?? '06:00'} – ${_venue!['operating_hours_to'] ?? '23:00'}'),
                  if (_venue!['owner_name'] != null) ...[
                    const SizedBox(height: 8),
                    _infoRow(Icons.person_outline, 'Managed by ${_venue!['owner_name']}'),
                  ],
                ]),
              )),
          ),

          // ── AMENITIES SECTION ──────────────────────────────
          if (_amenities.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10, offset: const Offset(0, 2))]),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: const Color(0xFFE0E7FF),
                          borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.checklist_rounded, color: Color(0xFF6366F1), size: 20),
                      ),
                      const SizedBox(width: 10),
                      Text('Amenities & Facilities', style: GoogleFonts.poppins(
                        fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    ]),
                    const SizedBox(height: 16),
                    ..._amenities.entries.map((e) {
                      final key = e.key.toString();
                      final val = e.value;
                      final isBool = val is bool;
                      final displayKey = key.replaceAll('_', ' ');
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(children: [
                          Icon(
                            isBool ? (val ? Icons.check_circle : Icons.cancel)
                              : Icons.info_outline,
                            color: isBool
                              ? (val ? AppColors.accent : AppColors.error)
                              : AppColors.textSecondary,
                            size: 18),
                          const SizedBox(width: 10),
                          Expanded(child: Text(
                            displayKey[0].toUpperCase() + displayKey.substring(1),
                            style: GoogleFonts.poppins(fontSize: 13,
                              color: AppColors.textPrimary, fontWeight: FontWeight.w500))),
                          Text(isBool ? (val ? 'Yes' : 'No') : val.toString(),
                            style: GoogleFonts.poppins(fontSize: 13,
                              color: isBool
                                ? (val ? AppColors.accent : AppColors.error)
                                : AppColors.textSecondary,
                              fontWeight: FontWeight.w600)),
                        ]),
                      );
                    }),
                  ]),
                ),
              ),
            ),

          // ── DATE SELECTOR ──────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Select Date', style: GoogleFonts.poppins(
                    fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: AppColors.accentLight,
                      borderRadius: BorderRadius.circular(8)),
                    child: Text(_monthYear(_selectedDate), style: GoogleFonts.poppins(
                      fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.bold))),
                ]),
                const SizedBox(height: 12),
                SizedBox(height: 78,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: 14,
                    itemBuilder: (_, i) {
                      final date = DateTime.now().add(Duration(days: i));
                      final isToday = i == 0;
                      final selected = _dateStr(date) == _dateStr(_selectedDate);
                      return GestureDetector(
                        onTap: () {
                          setState(() { _selectedDate = date; });
                          _load(date);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 56, margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            gradient: selected ? const LinearGradient(
                              colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                              begin: Alignment.topLeft, end: Alignment.bottomRight)
                              : null,
                            color: selected ? null : Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: selected ? AppColors.primary : AppColors.border,
                              width: selected ? 0 : 1),
                            boxShadow: selected ? [BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.3),
                              blurRadius: 8, offset: const Offset(0, 3))] : null),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text(isToday ? 'TODAY' : _weekday(date),
                              style: GoogleFonts.poppins(fontSize: 9,
                                color: selected ? Colors.white70 : AppColors.textSecondary,
                                fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                            const SizedBox(height: 4),
                            Text('${date.day}', style: GoogleFonts.poppins(
                              fontSize: 20, fontWeight: FontWeight.bold,
                              color: selected ? Colors.white : AppColors.textPrimary)),
                          ]),
                        ),
                      );
                    },
                  )),
              ]),
            ),
          ),

          // ── SLOTS HEADER + LEGEND ──────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Available Slots', style: GoogleFonts.poppins(
                  fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                const SizedBox(height: 8),
                Wrap(spacing: 16, runSpacing: 6, children: [
                  _legend(const Color(0xFF22C55E), 'Available'),
                  _legend(const Color(0xFFF59E0B), 'Booked'),
                  _legend(const Color(0xFFEF4444), 'Blocked'),
                  _legend(const Color(0xFF3B82F6), 'Temp Locked'),
                ]),
              ]),
            ),
          ),

          // ── SLOT GRID ──────────────────────────────────────
          if (_slots.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (_, i) {
                    final slot = _slots[i];
                    final status = (slot['status'] ?? 'available').toString();
                    final isAvailable = status == 'available';
                    final selected = _selectedSlotId == slot['id'];
                    final time12 = _to12Hour(slot['start_time']);
                    final slotPrice = _parseDouble(slot['price']);
                    final statusColor = _slotStatusColor(status);

                    return GestureDetector(
                      onTap: isAvailable ? () => setState(() {
                        _selectedSlotId = selected ? null : slot['id'];
                        _selectedSlot = selected ? null : slot;
                      }) : null,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          gradient: selected ? const LinearGradient(
                            colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                            begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
                          color: selected ? null
                            : isAvailable ? Colors.white
                            : statusColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected ? AppColors.primary
                              : isAvailable ? AppColors.border
                              : statusColor.withValues(alpha: 0.3),
                            width: selected ? 2 : 1),
                          boxShadow: selected ? [BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.25),
                            blurRadius: 8, offset: const Offset(0, 3))] : null,
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(time12,
                            style: GoogleFonts.poppins(
                              fontSize: 12, fontWeight: FontWeight.bold,
                              color: selected ? Colors.white
                                : isAvailable ? AppColors.textPrimary
                                : statusColor,
                              decoration: !isAvailable ? TextDecoration.lineThrough : null)),
                          const SizedBox(height: 2),
                          if (isAvailable) Text('PKR ${slotPrice.toStringAsFixed(0)}',
                            style: GoogleFonts.poppins(fontSize: 9,
                              color: selected ? Colors.white70 : AppColors.textSecondary))
                          else Text(
                            _slotStatusLabel(status),
                            style: GoogleFonts.poppins(fontSize: 8,
                              color: statusColor, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    );
                  },
                  childCount: _slots.length,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 10,
                  mainAxisSpacing: 10, childAspectRatio: 2.0),
              ),
            ),

          if (_slots.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.event_busy_outlined, size: 48,
                    color: AppColors.textSecondary.withValues(alpha: 0.5)),
                  const SizedBox(height: 12),
                  Text('No slots available',
                    style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
                  const SizedBox(height: 4),
                  Text('Try selecting a different date',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                ])),
              ),
            ),
        ],
      ),
    );
  }

  Widget _gradientPlaceholder(String sportType) {
    return Container(width: double.infinity, height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [const Color(0xFF0A1F13), _sportColor(sportType).withValues(alpha: 0.6)],
          begin: Alignment.topCenter, end: Alignment.bottomRight)),
      child: Center(child: Icon(_sportIcon(sportType),
        color: Colors.white.withValues(alpha: 0.08), size: 160)));
  }

  Widget _bottomBar() {
    final slotPrice = _selectedSlot != null ? _parseDouble(_selectedSlot!['price']) : 0.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 12, offset: const Offset(0, -4))]),
      child: SafeArea(top: false,
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
            Text('TOTAL AMOUNT', style: GoogleFonts.poppins(
              fontSize: 10, color: AppColors.textSecondary, letterSpacing: 0.5)),
            Text(_selectedSlot != null
                ? 'PKR ${slotPrice.toStringAsFixed(0)}'
                : 'Select a slot',
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold,
                color: _selectedSlot != null ? AppColors.textPrimary : AppColors.textSecondary)),
          ]),
          const SizedBox(width: 16),
          Expanded(child: ElevatedButton(
            onPressed: _selectedSlot == null ? null : _goToConfirm,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              disabledBackgroundColor: AppColors.disabled,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              elevation: _selectedSlot != null ? 4 : 0,
              shadowColor: AppColors.accent.withValues(alpha: 0.4),
            ),
            child: Text('Book Now', style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
          )),
        ]),
      ),
    );
  }

  void _goToConfirm() {
    if (_selectedSlot == null || _venue == null) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ConfirmBookingScreen(
        venue: _venue!,
        slot: _selectedSlot!,
        selectedDate: _selectedDate,
      )));
  }

  Widget _infoRow(IconData icon, String text) => Row(children: [
    Icon(icon, color: AppColors.textSecondary, size: 16),
    const SizedBox(width: 8),
    Expanded(child: Text(text,
      style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
      maxLines: 2, overflow: TextOverflow.ellipsis)),
  ]);

  Widget _legend(Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 10, height: 10,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
    const SizedBox(width: 4),
    Text(label, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
  ]);

  Color _slotStatusColor(String status) => switch (status) {
    'available' => const Color(0xFF22C55E),
    'booked' => const Color(0xFFF59E0B),
    'blocked' => const Color(0xFFEF4444),
    'temporarily_locked' => const Color(0xFF3B82F6),
    _ => AppColors.disabled,
  };

  String _slotStatusLabel(String status) => switch (status) {
    'booked' => 'BOOKED',
    'blocked' => 'BLOCKED',
    'temporarily_locked' => 'LOCKED',
    _ => status.toUpperCase(),
  };

  Color _sportColor(String sport) => switch (sport.toLowerCase()) {
    'football' || 'futsal' => const Color(0xFF22C55E),
    'cricket' => const Color(0xFFF59E0B),
    _ => const Color(0xFF3B82F6),
  };

  IconData _sportIcon(String sport) => switch (sport.toLowerCase()) {
    'football' || 'futsal' => Icons.sports_soccer,
    'cricket' => Icons.sports_cricket,
    _ => Icons.sports,
  };

  String _monthYear(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month-1]} ${d.year}';
  }

  String _weekday(DateTime d) {
    const days = ['MON','TUE','WED','THU','FRI','SAT','SUN'];
    return days[d.weekday - 1];
  }
}
