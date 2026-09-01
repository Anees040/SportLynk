import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../utils/num_util.dart';
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
  List<Map<String, dynamic>> _recommended = [];
  String _recommendationSource = 'heuristic';
  String _recommendationLabel = 'For you';
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

  List<String> _userPrefs = [];

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      
      // Fetch profile for AI recommendations if needed
      if (_userPrefs.isEmpty) {
        try {
          final pResp = await http.get(
            Uri.parse('${ApiConstants.baseUrl}/users/me/player'),
            headers: {'Authorization': 'Bearer $token'});
          if (pResp.statusCode == 200) {
            final pData = jsonDecode(pResp.body)['data'];
            if (pData['sport_preferences'] != null) {
              _userPrefs = List<String>.from(pData['sport_preferences']);
            }
          }
        } catch (_) {}
      }

      // If no initial sport is selected, auto-select based on AI prefs
      if (widget.initialSport == null && _selectedSport == '' && _userPrefs.isNotEmpty) {
        final pref = _userPrefs.first.toLowerCase();
        if (_sports.any((s) => s.toLowerCase() == pref)) {
          _selectedSport = _sports.firstWhere((s) => s.toLowerCase() == pref);
        }
      }

      final params = <String, String>{};
      if (_searchCtrl.text.trim().isNotEmpty) params['search'] = _searchCtrl.text.trim();
      if (_selectedSport.isNotEmpty && _selectedSport.toLowerCase() != 'all') params['sport'] = _selectedSport.toLowerCase();
      
      if (_minPrice > 0) params['min_price'] = _minPrice.toString();
      if (_maxPrice < 10000) params['max_price'] = _maxPrice.toString();
      if (_minRating > 0) params['min_rating'] = _minRating.toString();
      if (_sort != 'rating') params['sort'] = _sort;

      final uri = Uri.parse('${ApiConstants.baseUrl}/venues').replace(queryParameters: params);
      final responses = await Future.wait([
        http.get(uri, headers: {'Authorization': 'Bearer $token'}),
        http.get(Uri.parse('${ApiConstants.baseUrl}/venues/recommended?limit=5'), headers: {'Authorization': 'Bearer $token'}),
      ]);
      final resp = responses[0];
      final data = jsonDecode(resp.body);
      final recoData = responses[1].statusCode == 200 ? jsonDecode(responses[1].body) : null;
      
      if (mounted) {
        setState(() {
          if (data['success'] == true) {
            _venues = List<Map<String, dynamic>>.from(data['data']);
            final payload = recoData?['data'];
            _recommended = payload is Map && payload['venues'] is List
                ? List<Map<String, dynamic>>.from(payload['venues']) : [];
            _recommendationSource = payload is Map ? (payload['source'] ?? 'heuristic').toString() : 'heuristic';
            _recommendationLabel = payload is Map ? (payload['label'] ?? 'For you').toString() : 'For you';
          } else {
            _venues = [];
          }
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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
        // Search + filter
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

        // Results
        Expanded(
          child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
            : _venues.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
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
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                    slivers: [
                      if (_recommended.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                            child: Row(
                              children: [
                                if (_recommendationSource == 'model') ...[
                                  const Icon(Icons.auto_awesome, color: AppColors.accent, size: 20),
                                  const SizedBox(width: 8),
                                ],
                                Text(_recommendationLabel,
                                  style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                              ],
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 240,
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              scrollDirection: Axis.horizontal,
                              itemCount: _recommended.length,
                              itemBuilder: (_, i) => _aiRecommendedCard(_recommended[i]),
                            ),
                          ),
                        ),
                      ],
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                          child: Text('Nearby Venues',
                            style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                        ),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, i) {
                            // Not de-duplicated against the recommended rail above, so a venue can appear
                            // in both. The rail is a ranking of a few; this list is coverage of everything.
                            final venue = _venues[i];
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                              child: _nearbyVenueCard(venue),
                            );
                          },
                          childCount: _venues.length,
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _aiRecommendedCard(Map<String, dynamic> v) {
    final sportType = (v['sport_type'] ?? 'sport').toString();
    final matchPct = v['match_pct'];
    final reasons = v['reasons'] is List ? List<String>.from(v['reasons']) : <String>[];
    
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => VenueDetailScreen(venueId: v['id']))),
      child: Container(
        width: 280,
        margin: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              // Background Image/Gradient
              Container(
                decoration: BoxDecoration(color: const Color(0xFF0A1F13)),
                child: (v['venue_photos'] != null && (v['venue_photos'] as List).isNotEmpty)
                    ? Image.network(v['venue_photos'][0], fit: BoxFit.cover, width: double.infinity, height: double.infinity,
                        errorBuilder: (ctx, err, stack) => Center(child: Icon(_sportIcon(sportType), color: Colors.white.withValues(alpha: 0.1), size: 100)))
                    : Center(child: Icon(_sportIcon(sportType), color: Colors.white.withValues(alpha: 0.1), size: 100)),
              ),
              // Gradient Overlay
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.black87],
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    stops: [0.4, 1.0],
                  ),
                ),
              ),
              // Rating Badge
              Positioned(
                top: 12, right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(matchPct != null ? Icons.auto_awesome : Icons.star_rounded, color: Colors.amber, size: 14),
                    const SizedBox(width: 4),
                    Text(matchPct != null ? '$matchPct% match' : '${v['rating'] ?? 'N/A'}',
                      style: GoogleFonts.poppins(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
              // Content
              Positioned(
                bottom: 16, left: 16, right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v['name'] ?? 'Venue',
                      style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.location_on, color: Colors.white70, size: 14),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(v['address'] ?? v['city'] ?? '',
                            style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (reasons.isNotEmpty) ...[
                      Wrap(spacing: 5, runSpacing: 4, children: reasons.take(3).map((reason) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
                        child: Text(reason, style: GoogleFonts.poppins(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w500)),
                      )).toList()),
                      const SizedBox(height: 7),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('PKR ${asNum(v['price_per_hour']).toStringAsFixed(0)}/hr',
                          style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 14, fontWeight: FontWeight.bold)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
                          child: Text('Book', style: GoogleFonts.poppins(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nearbyVenueCard(Map<String, dynamic> v) {
    final sportType = (v['sport_type'] ?? 'sport').toString();
    final sportColor = _sportColor(sportType);
    
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => VenueDetailScreen(venueId: v['id']))),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))]),
        child: Row(
          children: [
            // Image Left
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
              child: Container(
                width: 120, height: 120,
                decoration: BoxDecoration(color: const Color(0xFF0A1F13)),
                child: (v['venue_photos'] != null && (v['venue_photos'] as List).isNotEmpty)
                    ? Image.network(v['venue_photos'][0], fit: BoxFit.cover, width: 120, height: 120,
                        errorBuilder: (ctx, err, stack) => Center(child: Icon(_sportIcon(sportType), color: Colors.white.withValues(alpha: 0.2), size: 48)))
                    : Center(child: Icon(_sportIcon(sportType), color: Colors.white.withValues(alpha: 0.2), size: 48)),
              ),
            ),
            // Details Right
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: sportColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                          child: Text(sportType.toUpperCase(),
                            style: GoogleFonts.poppins(color: sportColor, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                        ),
                        Row(
                          children: [
                            const Icon(Icons.star_rounded, color: Colors.amber, size: 14),
                            const SizedBox(width: 4),
                            Text('${v['rating'] ?? 'N/A'}', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(v['name'] ?? 'Venue', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.location_on_outlined, color: AppColors.textSecondary, size: 14),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(v['address'] ?? v['city'] ?? '', style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('PKR ${asNum(v['price_per_hour']).toStringAsFixed(0)}/hr', style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
