# PROMPT 3 — Find Venues + Venue Detail + Confirm Booking
# Run AFTER Prompt 2 compiles clean.
# All code is REAL DART. Write exactly as shown.

---

## FILE 1: lib/screens/player/find_venues_screen.dart

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../providers/auth_provider.dart';
import 'venue_detail_screen.dart';

class FindVenuesScreen extends StatefulWidget {
  final String? initialSport;
  const FindVenuesScreen({super.key, this.initialSport});
  @override
  State<FindVenuesScreen> createState() => _FindVenuesScreenState();
}

class _FindVenuesScreenState extends State<FindVenuesScreen> {
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _venues = [];
  bool _loading = true;
  String _selectedSport = '';
  static const _base = 'http://10.0.2.2:3000/api';
  static const _sports = ['All', 'Football', 'Cricket'];

  @override
  void initState() {
    super.initState();
    _selectedSport = widget.initialSport ?? '';
    _load();
    _searchCtrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearch);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch() {
    if (_searchCtrl.text.length >= 2 || _searchCtrl.text.isEmpty) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final params = <String, String>{};
      if (_searchCtrl.text.trim().isNotEmpty) params['search'] = _searchCtrl.text.trim();
      if (_selectedSport.isNotEmpty) params['sport'] = _selectedSport.toLowerCase();
      final uri = Uri.parse('$_base/venues').replace(queryParameters: params);
      final resp = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() {
          _venues = data['success'] == true
            ? List<Map<String, dynamic>>.from(data['data'])
            : [];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Find Venues', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(children: [
        // ── SEARCH + FILTER ─────────────────────────────────
        Container(
          color: AppColors.primary,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(children: [
            // Search
            Container(
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: TextField(
                controller: _searchCtrl,
                style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search venues, sports, locations...',
                  hintStyle: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
                  prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary, size: 20),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18, color: AppColors.textSecondary),
                        onPressed: () { _searchCtrl.clear(); _load(); })
                    : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Sport filter chips
            SizedBox(height: 34,
              child: ListView(scrollDirection: Axis.horizontal, children: _sports.map((s) {
                final isAll = s == 'All';
                final active = isAll ? _selectedSport.isEmpty : _selectedSport == s.toLowerCase();
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedSport = isAll ? '' : s.toLowerCase());
                    _load();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: active ? AppColors.accent : Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(
                        color: active ? AppColors.accent : Colors.white.withOpacity(0.4))),
                    child: Center(child: Text(s, style: GoogleFonts.poppins(
                      color: active ? Colors.white : Colors.white,
                      fontSize: 12, fontWeight: active ? FontWeight.w600 : FontWeight.normal))),
                  ),
                );
              }).toList()),
            ),
          ]),
        ),

        // ── RESULTS ─────────────────────────────────────────
        Expanded(
          child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
            : _venues.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.stadium_outlined, size: 64, color: AppColors.disabled),
                  const SizedBox(height: 12),
                  Text('No venues found',
                    style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold,
                      color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  Text('Try a different search or filter',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                ]))
              : RefreshIndicator(
                  color: AppColors.accent,
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _venues.length,
                    physics: const BouncingScrollPhysics(),
                    itemBuilder: (_, i) => _venueCard(_venues[i]),
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _venueCard(Map<String, dynamic> v) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => VenueDetailScreen(venueId: v['id']))),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
            blurRadius: 6, offset: const Offset(0, 2))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Image
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Container(height: 150, width: double.infinity,
              color: AppColors.primary,
              child: Stack(children: [
                const Center(child: Icon(Icons.stadium_outlined,
                  color: Colors.white24, size: 56)),
                // Rating badge
                Positioned(top: 10, right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black54,
                      borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star, color: Colors.amber, size: 13),
                      const SizedBox(width: 3),
                      Text('${v['rating'] ?? 'N/A'}',
                        style: GoogleFonts.poppins(color: Colors.white,
                          fontSize: 11, fontWeight: FontWeight.bold)),
                    ]),
                  )),
                // Sport badge
                Positioned(bottom: 10, left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(8)),
                    child: Text((v['sport_type'] ?? 'SPORT').toUpperCase(),
                      style: GoogleFonts.poppins(color: Colors.white,
                        fontSize: 10, fontWeight: FontWeight.bold)))),
              ]),
            ),
          ),
          // Info
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v['name'] ?? 'Venue',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.location_on_outlined,
                    color: AppColors.textSecondary, size: 13),
                  const SizedBox(width: 3),
                  Flexible(child: Text(v['address'] ?? v['city'] ?? '',
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
                if (v['total_reviews'] != null) ...[
                  const SizedBox(height: 4),
                  Text('${v['total_reviews']} reviews',
                    style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
                ],
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('PKR ${(v['price_per_hour'] ?? 0).toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(color: AppColors.accent,
                    fontSize: 15, fontWeight: FontWeight.bold)),
                Text('/hour', style: GoogleFonts.poppins(
                  fontSize: 10, color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.accent,
                    borderRadius: BorderRadius.circular(8)),
                  child: Text('Book', style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
```

---

## FILE 2: lib/screens/player/venue_detail_screen.dart

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
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
  static const _base = 'http://10.0.2.2:3000/api';

  @override
  void initState() { super.initState(); _load(); }

  String _dateStr(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  Future<void> _load([DateTime? date]) async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final d = date ?? _selectedDate;
      final resp = await http.get(
        Uri.parse('$_base/venues/${widget.venueId}?date=${_dateStr(d)}'),
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
    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: _bottomBar(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── HERO ────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            backgroundColor: AppColors.primary,
            iconTheme: const IconThemeData(color: Colors.white),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(children: [
                Container(width: double.infinity, height: double.infinity,
                  color: AppColors.primary,
                  child: const Center(child: Icon(Icons.stadium_outlined,
                    color: Colors.white24, size: 80))),
                // Gradient overlay at bottom
                Positioned.fill(child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.transparent,
                        Colors.black.withOpacity(0.5)])))),
              ]),
            ),
          ),

          // ── VENUE INFO ────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_venue!['name'] ?? '', style: GoogleFonts.poppins(
                      fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.star, color: Colors.amber, size: 16),
                      const SizedBox(width: 4),
                      Text('${_venue!['rating'] ?? 0}',
                        style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 13)),
                      Text(' (${_venue!['total_reviews'] ?? 0} reviews)',
                        style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
                    ]),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: [
                      _chip((_venue!['sport_type'] ?? 'sport').toUpperCase()),
                      if (_venue!['ground_type'] != null)
                        _chip((_venue!['ground_type']).toString().toUpperCase()),
                    ]),
                  ])),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('PKR ${(_venue!['price_per_hour'] ?? 0).toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(color: AppColors.accent,
                        fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('/hour', style: GoogleFonts.poppins(
                      fontSize: 11, color: AppColors.textSecondary)),
                  ]),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  const Icon(Icons.location_on_outlined,
                    color: AppColors.textSecondary, size: 16),
                  const SizedBox(width: 6),
                  Expanded(child: Text(_venue!['address'] ?? _venue!['city'] ?? '',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                    maxLines: 2)),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.access_time_outlined,
                    color: AppColors.textSecondary, size: 16),
                  const SizedBox(width: 6),
                  Text('${_venue!['operating_hours_from'] ?? '06:00'} – ${_venue!['operating_hours_to'] ?? '23:00'}',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ]),
            ),
          ),

          // ── DATE SELECTOR ──────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Select Date', style: GoogleFonts.poppins(
                    fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                  Text(_monthYear(_selectedDate), style: GoogleFonts.poppins(
                    fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 10),
                SizedBox(height: 72,
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
                        child: Container(
                          width: 52, margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: selected ? AppColors.primary : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected ? AppColors.primary : AppColors.border)),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text(isToday ? 'TODAY' : _weekday(date),
                              style: GoogleFonts.poppins(fontSize: 9,
                                color: selected ? Colors.white70 : AppColors.textSecondary,
                                fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text('${date.day}', style: GoogleFonts.poppins(
                              fontSize: 18, fontWeight: FontWeight.bold,
                              color: selected ? Colors.white : AppColors.textPrimary)),
                          ]),
                        ),
                      );
                    },
                  )),
              ]),
            ),
          ),

          // ── SLOTS ─────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Available Slots', style: GoogleFonts.poppins(
                  fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                Row(children: [
                  _legend(AppColors.accent, 'Free'),
                  const SizedBox(width: 10),
                  _legend(Colors.grey.shade300, 'Booked'),
                ]),
              ]),
            ),
          ),

          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final slot = _slots[i];
                  final booked = slot['status'] == 'booked';
                  final selected = _selectedSlotId == slot['id'];
                  final time = (slot['start_time'] as String).substring(0, 5);
                  return GestureDetector(
                    onTap: booked ? null : () => setState(() {
                      _selectedSlotId = selected ? null : slot['id'];
                      _selectedSlot = selected ? null : slot;
                    }),
                    child: Container(
                      decoration: BoxDecoration(
                        color: booked ? Colors.grey.shade100
                          : selected ? AppColors.primary : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: booked ? Colors.grey.shade300
                            : selected ? AppColors.primary : AppColors.border,
                          width: selected ? 2 : 1),
                      ),
                      child: Center(child: Text(time,
                        style: GoogleFonts.poppins(
                          fontSize: 13, fontWeight: FontWeight.w600,
                          color: booked ? Colors.grey.shade400
                            : selected ? Colors.white : AppColors.textPrimary,
                          decoration: booked ? TextDecoration.lineThrough : null))),
                    ),
                  );
                },
                childCount: _slots.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, crossAxisSpacing: 10,
                mainAxisSpacing: 10, childAspectRatio: 2.4),
            ),
          ),

          if (_slots.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Text('No slots available for this date',
                  style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary))),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))]),
      child: SafeArea(top: false,
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
            Text('TOTAL AMOUNT', style: GoogleFonts.poppins(
              fontSize: 10, color: AppColors.textSecondary, letterSpacing: 0.5)),
            Text(_selectedSlot != null
                ? 'PKR ${(_selectedSlot!['price'] ?? 0).toStringAsFixed(0)}'
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

  Widget _chip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: AppColors.accentLight,
      borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: GoogleFonts.poppins(
      color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold)));

  Widget _legend(Color color, String label) => Row(children: [
    Container(width: 10, height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 4),
    Text(label, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
  ]);

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
```

---

## FILE 3: lib/screens/player/confirm_booking_screen.dart

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../providers/auth_provider.dart';

class ConfirmBookingScreen extends StatefulWidget {
  final Map<String, dynamic> venue;
  final Map<String, dynamic> slot;
  final DateTime selectedDate;
  const ConfirmBookingScreen({
    super.key,
    required this.venue,
    required this.slot,
    required this.selectedDate,
  });
  @override
  State<ConfirmBookingScreen> createState() => _ConfirmBookingScreenState();
}

class _ConfirmBookingScreenState extends State<ConfirmBookingScreen> {
  bool _loading = false;
  double _walletBalance = 0;
  bool _walletLoaded = false;
  static const _base = 'http://10.0.2.2:3000/api';

  @override
  void initState() { super.initState(); _loadWallet(); }

  Future<void> _loadWallet() async {
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(Uri.parse('$_base/wallet/me'),
        headers: {'Authorization': 'Bearer $token'});
      final data = jsonDecode(resp.body);
      if (mounted && data['success'] == true) {
        setState(() {
          _walletBalance = (data['data']['balance'] as num).toDouble();
          _walletLoaded = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _confirmBooking() async {
    final price = (widget.slot['price'] as num?)?.toDouble() ?? 0;
    if (_walletBalance < price) {
      _snack('Insufficient wallet balance. Please top up your wallet.', AppColors.error);
      return;
    }
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(Uri.parse('$_base/bookings'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'slotId': widget.slot['id'],
          'venueId': widget.venue['id'],
        }));
      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() => _loading = false);
        if (data['success'] == true) {
          _showSuccessDialog(data['data']);
        } else {
          _snack(data['message'] ?? 'Booking failed', AppColors.error);
        }
      }
    } catch (e) {
      if (mounted) { setState(() => _loading = false); _snack('Error: $e', AppColors.error); }
    }
  }

  void _showSuccessDialog(Map<String, dynamic> booking) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(width: 72, height: 72,
            decoration: BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle, color: AppColors.accent, size: 40)),
          const SizedBox(height: 16),
          Text('Booking Confirmed!', textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold,
              color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Text('Your slot has been booked successfully.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 20),
          Container(padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.inputFill,
              borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              _confirmRow('Venue', widget.venue['name'] ?? ''),
              _confirmRow('Date', _fmtDate(widget.selectedDate)),
              _confirmRow('Time',
                '${(widget.slot['start_time'] as String).substring(0,5)} – '
                '${(widget.slot['end_time'] as String).substring(0,5)}'),
              _confirmRow('Amount',
                'PKR ${(widget.slot['price'] as num?)?.toStringAsFixed(0) ?? '0'}'),
            ])),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop();
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text('View My Bookings', style: GoogleFonts.poppins(
                color: Colors.white, fontWeight: FontWeight.w600)),
            )),
        ]),
      ),
    );
  }

  void _snack(String msg, Color c) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: c, behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final price = (widget.slot['price'] as num?)?.toDouble() ?? 0;
    final deposit = (price * 0.2).roundToDouble();
    final remaining = _walletBalance - price;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Confirm Booking', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        decoration: const BoxDecoration(color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))]),
        child: SafeArea(top: false,
          child: ElevatedButton(
            onPressed: _loading ? null : _confirmBooking,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Text('Confirm & Pay PKR ${price.toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 15)),
          )),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── BOOKING SUMMARY ──────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border)),
            child: Row(children: [
              Container(width: 72, height: 72,
                decoration: BoxDecoration(color: AppColors.primary,
                  borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.stadium_outlined, color: Colors.white38, size: 36)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.venue['name'] ?? '', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold, fontSize: 15),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.calendar_today_outlined, size: 13,
                    color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text(_fmtDate(widget.selectedDate), style: GoogleFonts.poppins(
                    fontSize: 12, color: AppColors.textSecondary)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  const Icon(Icons.access_time_outlined, size: 13,
                    color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text('${(widget.slot['start_time'] as String).substring(0,5)} – '
                    '${(widget.slot['end_time'] as String).substring(0,5)}',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ])),
            ]),
          ),
          const SizedBox(height: 16),

          // ── PAYMENT BREAKDOWN ─────────────────────────────
          _section('Payment Breakdown', [
            _row('Base Price', 'PKR ${price.toStringAsFixed(0)}'),
            _row('Security Deposit', 'PKR ${deposit.toStringAsFixed(0)}',
              sub: 'REFUNDABLE', subColor: AppColors.accent),
            const Divider(color: AppColors.border),
            _row('Total Amount', 'PKR ${price.toStringAsFixed(0)}',
              bold: true, valueColor: AppColors.accent),
          ]),
          const SizedBox(height: 16),

          // ── PAYMENT METHOD ────────────────────────────────
          _section('Payment Method', [
            Row(children: [
              Container(width: 42, height: 42,
                decoration: BoxDecoration(color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.account_balance_wallet,
                  color: AppColors.accent, size: 22)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('SportLynk Wallet', style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w600, fontSize: 13)),
                Text('Available: PKR ${_walletBalance.toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
              ])),
              const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
            ]),
            if (_walletLoaded) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.inputFill,
                  borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Expanded(child: Column(children: [
                    Text('PAYABLE', style: GoogleFonts.poppins(fontSize: 9,
                      color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 2),
                    Text('- PKR ${price.toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
                        color: AppColors.error)),
                  ])),
                  Container(width: 1, height: 32, color: AppColors.border),
                  Expanded(child: Column(children: [
                    Text('REMAINING', style: GoogleFonts.poppins(fontSize: 9,
                      color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 2),
                    Text('PKR ${remaining.toStringAsFixed(0)}',
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold,
                        color: remaining >= 0 ? AppColors.success : AppColors.error)),
                  ])),
                ]),
              ),
              if (remaining < 0) ...[
                const SizedBox(height: 8),
                Container(padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_outlined, color: AppColors.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Insufficient balance. Top up your wallet to proceed.',
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.error))),
                  ])),
              ],
            ],
          ]),
          const SizedBox(height: 20),

          // ── CANCELLATION POLICY ───────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.warning.withOpacity(0.4))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, color: AppColors.warning, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(
                'Cancel at least 2 hours before your slot for a full refund. '
                'No-shows may affect your trust score.',
                style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFF92400E)))),
            ]),
          ),
          const SizedBox(height: 100),
        ]),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: GoogleFonts.poppins(
        fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
      const SizedBox(height: 10),
      ...children,
    ]),
  );

  Widget _row(String label, String value,
    {String? sub, Color? subColor, bool bold = false, Color? valueColor}) =>
    Padding(padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Text(label, style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
          if (sub != null) ...[
            const SizedBox(width: 6),
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: (subColor ?? AppColors.accent).withOpacity(0.1),
                borderRadius: BorderRadius.circular(4)),
              child: Text(sub, style: GoogleFonts.poppins(fontSize: 9,
                color: subColor ?? AppColors.accent, fontWeight: FontWeight.bold))),
          ],
        ]),
        Text(value, style: GoogleFonts.poppins(fontSize: 13,
          fontWeight: bold ? FontWeight.bold : FontWeight.w500,
          color: valueColor ?? AppColors.textPrimary)),
      ]));

  Widget _confirmRow(String l, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(l, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary)),
      Text(v, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600,
        color: AppColors.textPrimary)),
    ]));

  String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month-1]}, ${d.year}';
  }
}
```

---

## ROUTES — Add in main.dart
```dart
'/find-venues': (ctx) {
  final args = ModalRoute.of(ctx)!.settings.arguments as Map<String,dynamic>?;
  return AuthGuard(child: FindVenuesScreen(initialSport: args?['sport']));
},
'/venue-detail': (ctx) {
  final args = ModalRoute.of(ctx)!.settings.arguments as Map<String,dynamic>;
  return AuthGuard(child: VenueDetailScreen(venueId: args['venueId']));
},
```
ConfirmBookingScreen is pushed via Navigator.push (not named route) since it needs objects.

## VERIFY
1. flutter analyze — 0 errors
2. Tap a sport on home → find venues opens filtered
3. Tap a venue card → venue detail opens with slots grid
4. Select a slot → price shows in bottom bar
5. Tap Book Now → confirm screen opens with payment breakdown
6. Tap Confirm & Pay → success dialog appears
