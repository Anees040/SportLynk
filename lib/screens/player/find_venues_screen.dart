import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
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
  static const _sports = ['All', 'Football', 'Cricket'];

  // Filter states
  double _minPrice = 0;
  double _maxPrice = 10000;
  double _minRating = 0;
  String _sort = 'rating';

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
      if (_selectedSport.isNotEmpty && _selectedSport.toLowerCase() != 'all') params['sport'] = _selectedSport.toLowerCase();
      
      if (_minPrice > 0) params['min_price'] = _minPrice.toString();
      if (_maxPrice < 10000) params['max_price'] = _maxPrice.toString();
      if (_minRating > 0) params['min_rating'] = _minRating.toString();
      if (_sort != 'rating') params['sort'] = _sort;

      final uri = Uri.parse('${ApiConstants.baseUrl}/venues').replace(queryParameters: params);
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

  double _parseDouble(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }

  void _showFilterModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).padding.bottom + 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Filters', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                
                // Sort By
                Text('Sort By', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    _filterChip('Top Rated', 'rating', _sort == 'rating', () => setModalState(() => _sort = 'rating')),
                    _filterChip('Price: Low to High', 'price_low', _sort == 'price_low', () => setModalState(() => _sort = 'price_low')),
                    _filterChip('Price: High to Low', 'price_high', _sort == 'price_high', () => setModalState(() => _sort = 'price_high')),
                  ],
                ),
                const SizedBox(height: 24),

                // Price Range
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Price Range (PKR/hr)', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    Text('${_minPrice.toInt()} - ${_maxPrice.toInt()}+', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
                  ],
                ),
                RangeSlider(
                  values: RangeValues(_minPrice, _maxPrice),
                  min: 0,
                  max: 10000,
                  divisions: 20,
                  activeColor: AppColors.accent,
                  inactiveColor: AppColors.accentLight,
                  onChanged: (RangeValues values) {
                    setModalState(() {
                      _minPrice = values.start;
                      _maxPrice = values.end;
                    });
                  },
                ),
                const SizedBox(height: 20),

                // Minimum Rating
                Text('Minimum Rating', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    _filterChip('Any', 0, _minRating == 0, () => setModalState(() => _minRating = 0)),
                    _filterChip('3.0+', 3, _minRating == 3, () => setModalState(() => _minRating = 3)),
                    _filterChip('4.0+', 4, _minRating == 4, () => setModalState(() => _minRating = 4)),
                    _filterChip('4.5+', 4.5, _minRating == 4.5, () => setModalState(() => _minRating = 4.5)),
                  ],
                ),
                const SizedBox(height: 32),

                // Buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          setModalState(() {
                            _minPrice = 0;
                            _maxPrice = 10000;
                            _minRating = 0;
                            _sort = 'rating';
                          });
                        },
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: AppColors.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text('Reset', style: GoogleFonts.poppins(color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _load();
                        },
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: AppColors.accent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text('Apply Filters', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _filterChip(String label, dynamic value, bool isSelected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label, style: GoogleFonts.poppins(
        color: isSelected ? Colors.white : AppColors.textPrimary,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        fontSize: 12,
      )),
      selected: isSelected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.primary,
      backgroundColor: AppColors.inputFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: isSelected ? AppColors.primary : AppColors.border),
      ),
    );
  }

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
            Row(
              children: [
                Expanded(
                  child: Container(
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
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _showFilterModal,
                  child: Container(
                    height: 48,
                    width: 48,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Icon(Icons.tune, color: Colors.white, size: 20),
                        if (_minPrice > 0 || _maxPrice < 10000 || _minRating > 0 || _sort != 'rating')
                          Positioned(
                            top: 10,
                            right: 10,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: AppColors.error,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Sport filter chips
            SizedBox(height: 36,
              child: ListView(scrollDirection: Axis.horizontal, children: _sports.map((s) {
                final isAll = s == 'All';
                final active = isAll ? _selectedSport.isEmpty || _selectedSport.toLowerCase() == 'all' : _selectedSport.toLowerCase() == s.toLowerCase();
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedSport = isAll ? '' : s.toLowerCase());
                    _load();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: active ? AppColors.accent : Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: active ? AppColors.accent : Colors.white.withValues(alpha: 0.2))),
                    child: Center(child: Text(s, style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.normal))),
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
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.inputFill,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.search_off_outlined, size: 48, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  Text('No venues found',
                    style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
                  const SizedBox(height: 6),
                  Text('Try a different search or filter criteria',
                    style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
                  const SizedBox(height: 24),
                  if (_searchCtrl.text.isNotEmpty || _selectedSport.isNotEmpty || _minPrice > 0 || _maxPrice < 10000 || _minRating > 0)
                    OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _searchCtrl.clear();
                          _selectedSport = '';
                          _minPrice = 0;
                          _maxPrice = 10000;
                          _minRating = 0;
                          _sort = 'rating';
                        });
                        _load();
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.accent),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      child: Text('Clear All Filters', style: GoogleFonts.poppins(color: AppColors.accent)),
                    )
                ]))
              : RefreshIndicator(
                  color: AppColors.accent,
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _venues.length,
                    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                    itemBuilder: (_, i) => _venueCard(_venues[i]),
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _venueCard(Map<String, dynamic> v) {
    final sportType = (v['sport_type'] ?? 'sport').toString();
    final sportColor = _sportColor(sportType);
    
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => VenueDetailScreen(venueId: v['id']))),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10, offset: const Offset(0, 4))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Image
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Container(height: 160, width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [const Color(0xFF0A1F13), sportColor.withValues(alpha: 0.7)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: Stack(children: [
                Center(child: Icon(_sportIcon(sportType),
                  color: Colors.white.withValues(alpha: 0.15), size: 72)),
                // Rating badge
                Positioned(top: 12, right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black54,
                      borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star_rounded, color: Colors.amber, size: 14),
                      const SizedBox(width: 4),
                      Text('${v['rating'] ?? 'N/A'}',
                        style: GoogleFonts.poppins(color: Colors.white,
                          fontSize: 12, fontWeight: FontWeight.bold)),
                    ]),
                  )),
                // Sport badge
                Positioned(bottom: 12, left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: sportColor,
                      borderRadius: BorderRadius.circular(8)),
                    child: Text(sportType.toUpperCase(),
                      style: GoogleFonts.poppins(color: Colors.white,
                        fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)))),
              ]),
            ),
          ),
          // Info
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v['name'] ?? 'Venue',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 16),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.location_on_outlined,
                    color: AppColors.textSecondary, size: 14),
                  const SizedBox(width: 4),
                  Flexible(child: Text(v['address'] ?? v['city'] ?? '',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
                if (v['total_reviews'] != null) ...[
                  const SizedBox(height: 6),
                  Text('${v['total_reviews']} reviews',
                    style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
                ],
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('PKR ${_parseDouble(v['price_per_hour']).toStringAsFixed(0)}',
                  style: GoogleFonts.poppins(color: AppColors.accent,
                    fontSize: 16, fontWeight: FontWeight.bold)),
                Text('/hour', style: GoogleFonts.poppins(
                  fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(color: AppColors.accentLight,
                    borderRadius: BorderRadius.circular(10)),
                  child: Text('Book', style: GoogleFonts.poppins(
                    color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.bold))),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
