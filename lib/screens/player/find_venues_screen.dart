import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/connectivity_provider.dart';
import '../../services/api_service.dart';
import '../../services/location_service.dart';
import '../../services/offline_cache.dart';
import '../../utils/num_util.dart';
import '../../utils/reconnect_refresh.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/offline_banner.dart';
import 'venue_detail_screen.dart';

class FindVenuesScreen extends StatefulWidget {
  final String? initialSport;
  const FindVenuesScreen({super.key, this.initialSport});
  @override
  State<FindVenuesScreen> createState() => _FindVenuesScreenState();
}

class _FindVenuesScreenState extends State<FindVenuesScreen>
    with ReconnectRefresh<FindVenuesScreen> {
  final _api = ApiClient();
  final _searchCtrl = TextEditingController();
  final _location = LocationService();
  // The user's coordinates, fetched once best-effort. Null means location was off or
  // declined, in which case the recommendation rail keeps its relevance order.
  double? _lat;
  double? _lng;
  List<Map<String, dynamic>> _venues = [];
  List<Map<String, dynamic>> _recommended = [];
  String _recommendationSource = 'heuristic';
  String _recommendationLabel = 'For you';
  // Which rule chose the rail, as reported by GET /venues/recommended:
  // model · stated · relaxed · none. Only 'relaxed' is surfaced, because that is
  // the one case where the rail deliberately ignores the player's stated sports
  // and would otherwise look like a recommender that does not listen.
  String _recommendationPreference = 'model';
  bool _loading = true;
  // The sentence to show when the venue list itself could not be fetched, so a
  // failed request is reported as a failure with a retry rather than as an empty
  // search. Null whenever the last load succeeded.
  String? _error;
  String _selectedSport = '';
  static const _sports = ['All', 'Football', 'Cricket'];

  /// Set while the venues on screen were restored from disk.
  DateTime? _cachedAt;

  /// Whether the current view is the plain catalogue — no search text, no sport,
  /// default price and rating bounds.
  ///
  /// Gates the cache write. A filtered response saved under the same key would be
  /// read back on the next cold open as if it were everything the city had, which
  /// is the silent-wrong-data failure this whole pass exists to remove.
  bool get _isUnfilteredView =>
      _searchCtrl.text.trim().isEmpty &&
      _selectedSport.isEmpty &&
      _minPrice == 0 &&
      _maxPrice == 10000 &&
      _minRating == 0;

  // Filter states
  double _minPrice = 0;
  double _maxPrice = 10000;
  double _minRating = 0;
  String _sort = 'rating';

  @override
  void initState() {
    super.initState();
    _selectedSport = widget.initialSport ?? '';
    // Concurrent, not chained — see [_hydrateFromCache].
    _load();
    _hydrateFromCache();
    _searchCtrl.addListener(_onSearch);
  }

  /// Draw the last known catalogue if it arrives before the network does, so the
  /// screen opens with venues instead of a spinner — and still shows them when
  /// there is no connection at all.
  ///
  /// Two guards, both load-bearing. Only an unfiltered view hydrates, or a cached
  /// full list would appear underneath an active filter showing venues the filter
  /// excludes. And an already-populated list is left alone, so a disk read that
  /// loses the race to the response cannot overwrite it.
  Future<void> _hydrateFromCache() async {
    if (!_isUnfilteredView) return;
    final cached = await OfflineCache.read(OfflineCache.venues);
    if (!mounted || cached == null || _venues.isNotEmpty) return;
    final rows = cached.asRows();
    if (rows.isEmpty) return;
    setState(() {
      _venues = rows;
      _cachedAt = cached.at;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearch);
    _searchCtrl.dispose();
    super.dispose();
  }

  // Only refetch on reconnect when the last load actually failed; a spurious
  // socket blip must not reset an active search or the filters mid-browse.
  @override
  void onReconnect() {
    if (_error != null) _load();
  }

  String _lastSearch = '';

  void _onSearch() {
    final query = _searchCtrl.text.trim();
    // Rebuild on every keystroke, not only when a fetch is due: the clear button and
    // the search/browse mode switch (which hides the recommendation rail) both read
    // the field directly, so without this the first character typed would change
    // neither until a second one arrived.
    if (mounted) setState(() {});
    if (query == _lastSearch) return;
    if (query.isEmpty) {
      _lastSearch = '';
      _load();
    } else if (query.length >= 2) {
      _lastSearch = query;
      _load();
    }
  }

  List<String> _userPrefs = [];

  /// The preference auto-select is a one-time courtesy on first open, not a rule.
  ///
  /// It used to run on every [_load], which made the "All" chip unusable: tapping All
  /// sets [_selectedSport] to empty, the reload then saw an empty sport and instantly
  /// re-applied the player's stated preference, so All appeared to jump to Cricket and
  /// a cricket player could never widen their search. Seeding a default once is
  /// helpful; overriding a deliberate choice every fetch is not.
  bool _didAutoSelectSport = false;

  /// Set the moment the player taps a sport chip (including All) or clears filters.
  ///
  /// The seed below runs in `_load`'s async continuation, after the profile fetch
  /// has been awaited. On a slow or cold backend that continuation can land AFTER
  /// the player has already tapped a chip, and `_selectedSport.isEmpty` cannot tell
  /// "never chose" apart from "chose All" — so without this flag the first load's
  /// deferred seed overwrites a just-tapped All and the filter appears to jump back
  /// to the preferred sport. A deliberate choice, once made, is never seeded over.
  bool _userTouchedSport = false;

  /// True while the player has an active query. Search is a different mode from
  /// browsing: the rail is suppressed and the list is titled as results.
  bool get _isSearching => _searchCtrl.text.trim().isNotEmpty;

  /// The venues the list renders.
  ///
  /// While the rail is showing, venues already in it are excluded so the same ground
  /// is not presented twice in one scroll — the rail is the ranked few and the list is
  /// the rest, rather than two overlapping views of the same catalogue.
  List<Map<String, dynamic>> get _listVenues {
    if (_isSearching || _recommended.isEmpty) return _venues;
    final railIds = _recommended.map((v) => v['id'].toString()).toSet();
    return _venues.where((v) => !railIds.contains(v['id'].toString())).toList();
  }

  /// How many filters are narrowing the list, for the context row's summary.
  int get _activeFilterCount {
    var n = 0;
    if (_selectedSport.isNotEmpty) n++;
    if (_minPrice > 0 || _maxPrice < 10000) n++;
    if (_minRating > 0) n++;
    if (_sort != 'rating') n++;
    return n;
  }

  void _clearAllFilters() {
    setState(() {
      _searchCtrl.clear();
      _selectedSport = '';
      _minPrice = 0;
      _maxPrice = 10000;
      _minRating = 0;
      _sort = 'rating';
    });
    // Clearing to the full catalogue is a deliberate "show all", so the seed must
    // not quietly re-narrow it on the next load.
    _userTouchedSport = true;
    _load();
  }

  Future<void> _load() async {
    // Keep cached venues visible while a refresh runs behind them; the spinner is
    // only for a screen that has nothing to draw.
    if (_venues.isEmpty) {
      setState(() => _loading = true);
    }

    // The profile read only seeds the sport auto-select; its failure is tolerated,
    // exactly as the recommendation rail's is, and never blocks the venue list.
    if (_userPrefs.isEmpty) {
      final pResp = await _api.get('/users/me/player');
      if (pResp['success'] == true && pResp['data']?['sport_preferences'] != null) {
        _userPrefs = List<String>.from(pResp['data']['sport_preferences']);
      }
    }

    // Seed the chip from the player's stated preference, once — and never over a
    // choice the player has already made (see [_userTouchedSport]).
    if (!_didAutoSelectSport) {
      _didAutoSelectSport = true;
      if (!_userTouchedSport &&
          widget.initialSport == null &&
          _selectedSport.isEmpty &&
          _userPrefs.isNotEmpty) {
        final pref = _userPrefs.first.toLowerCase();
        if (_sports.any((s) => s.toLowerCase() == pref)) {
          // Stored lower case: every comparison on this field lower-cases it, and
          // assigning the capitalised label here made the field's case inconsistent.
          _selectedSport = pref;
        }
      }
    }

    final params = <String, String>{};
    if (_searchCtrl.text.trim().isNotEmpty) params['search'] = _searchCtrl.text.trim();
    if (_selectedSport.isNotEmpty && _selectedSport.toLowerCase() != 'all') params['sport'] = _selectedSport.toLowerCase();

    if (_minPrice > 0) params['min_price'] = _minPrice.toString();
    if (_maxPrice < 10000) params['max_price'] = _maxPrice.toString();
    if (_minRating > 0) params['min_rating'] = _minRating.toString();
    if (_sort != 'rating') params['sort'] = _sort;

    // The user's location, taken once and best-effort: when it is known, the "For you"
    // rail asks the server to re-rank its picks nearest-first and label each with a
    // distance. A declined or unavailable location changes nothing — the rail stays in
    // the recommender's relevance order.
    if (_lat == null) {
      final loc = await _location.current();
      if (loc != null) {
        _lat = loc.lat;
        _lng = loc.lng;
      }
    }
    final recoParams = <String, String>{'limit': '5'};
    if (_lat != null && _lng != null) {
      recoParams['lat'] = '$_lat';
      recoParams['lng'] = '$_lng';
      recoParams['sort'] = 'nearest';
      // The browse list is annotated too, so a card under "Nearby Venues" can state
      // how far away it is. Only annotated — the list keeps the player's chosen sort
      // unless they explicitly pick Nearest, which the filter sheet offers.
      params['lat'] = '$_lat';
      params['lng'] = '$_lng';
    }

    // The venue list is required; the recommendation rail is optional. Both are
    // requested together, but only the list's failure becomes the screen's error —
    // a list that renders without its "For you" rail is the correct degradation.
    final results = await Future.wait([
      _api.get('/venues', queryParams: params),
      _api.get('/venues/recommended', queryParams: recoParams),
    ]);
    final data = results[0];
    final recoData = results[1];

    if (!mounted) return;
    final ok = data['success'] == true;
    setState(() {
      if (ok) {
        _error = null;
        _cachedAt = null;
        _venues = List<Map<String, dynamic>>.from(data['data'] as List);
        final payload = recoData['success'] == true ? recoData['data'] : null;
        _recommended = payload is Map && payload['venues'] is List
            ? List<Map<String, dynamic>>.from(payload['venues']) : [];
        _recommendationSource = payload is Map ? (payload['source'] ?? 'heuristic').toString() : 'heuristic';
        _recommendationLabel = payload is Map ? (payload['label'] ?? 'For you').toString() : 'For you';
        _recommendationPreference = payload is Map ? (payload['preferenceApplied'] ?? 'model').toString() : 'model';
      } else {
        // The request failed. Surface the reason `ApiClient` translated (a 500, a
        // dropped connection, a cold-start timeout) instead of an empty list that
        // reads as "no venues here" — unless cached venues are already drawn, in
        // which case they stay and the offline strip carries the explanation.
        _error = _venues.isNotEmpty
            ? null
            : data['message'] as String? ?? 'Could not load venues.';
      }
      _loading = false;
    });
    if (ok) {
      context.read<ConnectivityProvider>().markReachable();
      // Only the unfiltered, unsearched list is cached. A cache keyed on nothing
      // but filled from a filtered response would hand the next cold open a
      // narrowed list presented as the whole catalogue.
      if (_isUnfilteredView) {
        await OfflineCache.write(OfflineCache.venues, _venues);
      }
    } else if (data['statusCode'] == 0) {
      if (mounted) context.read<ConnectivityProvider>().markUnreachable();
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
                  runSpacing: 8,
                  children: [
                    _filterChip('Top Rated', 'rating', _sort == 'rating', () => setModalState(() => _sort = 'rating')),
                    // Offered only when a location is actually known — a sort the
                    // server would ignore is worse than one that is absent.
                    if (_lat != null && _lng != null)
                      _filterChip('Nearest', 'nearest', _sort == 'nearest', () => setModalState(() => _sort = 'nearest')),
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
    'football' || 'futsal' => AppColors.accent,
    'cricket' => AppColors.warning,
    _ => AppColors.sportOther,
  };

  IconData _sportIcon(String sport) => switch (sport.toLowerCase()) {
    'football' || 'futsal' => Icons.sports_soccer,
    'cricket' => Icons.sports_cricket,
    _ => Icons.sports,
  };

  @override
  Widget build(BuildContext context) {
    // Resolved once per build: the getter filters a list, and reading it from a
    // sliver's itemBuilder would re-filter on every row.
    final listVenues = _listVenues;
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
        OfflineBanner(cachedAt: _cachedAt),
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
            // Sport selector. A segmented control rather than loose chips: the three
            // options are mutually exclusive and cover the whole catalogue, so one
            // enclosed track with a filled selection states that better than three
            // free-floating pills where "none selected" and "All" look alike.
            Container(
              height: 40,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: _sports.map((s) {
                  final isAll = s == 'All';
                  final active = isAll
                      ? _selectedSport.isEmpty || _selectedSport.toLowerCase() == 'all'
                      : _selectedSport.toLowerCase() == s.toLowerCase();
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        final next = isAll ? '' : s.toLowerCase();
                        // A deliberate tap, even back to the same chip, is user
                        // intent the preference seed must never override.
                        _userTouchedSport = true;
                        if (next == _selectedSport) return;
                        setState(() => _selectedSport = next);
                        _load();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        decoration: BoxDecoration(
                          color: active ? AppColors.accent : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(s,
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ]),
        ),

        // Results
        Expanded(
          child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
            : _error != null
              ? RefreshIndicator(
                  color: AppColors.accent,
                  onRefresh: _load,
                  child: NetworkErrorView(message: _error!, onRetry: _load),
                )
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
                      onPressed: _clearAllFilters,
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
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      // The "For you" rail is browse furniture, not a search result.
                      // While a query is active it is hidden: the rail plus its header
                      // stand ~300px tall, which pushed every match below the fold and
                      // under the keyboard, so the player had to dismiss the keyboard
                      // to see what they had just searched for.
                      if (!_isSearching && _recommended.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (_recommendationSource == 'model') ...[
                                      const Icon(Icons.auto_awesome, color: AppColors.accent, size: 20),
                                      const SizedBox(width: 8),
                                    ],
                                    // Expanded, not bare: the label is server-supplied and
                                    // wraps instead of overflowing when the system text
                                    // scale is large.
                                    Expanded(
                                      child: Text(_recommendationLabel,
                                        style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                                    ),
                                  ],
                                ),
                                // Said out loud rather than left to look like a bug: the
                                // player follows a sport that has no venue on the platform
                                // yet, so the rail is showing everything instead of nothing.
                                if (_recommendationPreference == 'relaxed')
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      'No venues for the sports you follow yet — showing all sports.',
                                      style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            // A horizontal list bounds its children's height, so the
                            // rail card cannot grow on its own: at a large system text
                            // scale its text block would overflow. The height tracks
                            // the scale, clamped so an extreme setting cannot eat the
                            // whole screen.
                            height: 140 +
                                110 *
                                    MediaQuery.textScalerOf(context)
                                        .scale(1)
                                        .clamp(1.0, 1.8),
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              scrollDirection: Axis.horizontal,
                              itemCount: _recommended.length,
                              itemBuilder: (_, i) => _aiRecommendedCard(_recommended[i]),
                            ),
                          ),
                        ),
                      ],
                      // Hidden entirely when the rail already accounts for every
                      // venue, rather than printing a "Nearby Venues · 0 venues"
                      // header above nothing.
                      if (listVenues.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _isSearching ? 'Search results' : 'Nearby Venues',
                                    style: GoogleFonts.poppins(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary),
                                  ),
                                ),
                                Text(
                                  listVenues.length == 1
                                      ? '1 venue'
                                      : '${listVenues.length} venues',
                                  style: GoogleFonts.poppins(
                                      fontSize: 12, color: AppColors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Active filters, stated plainly with one way out. Without
                        // this a narrow result reads as "there are no grounds"
                        // rather than "you are looking through three filters".
                        if (_activeFilterCount > 0)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                              child: Row(
                                children: [
                                  const Icon(Icons.filter_alt_outlined,
                                      size: 14, color: AppColors.textSecondary),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      _activeFilterCount == 1
                                          ? '1 filter applied'
                                          : '$_activeFilterCount filters applied',
                                      style: GoogleFonts.poppins(
                                          fontSize: 11, color: AppColors.textSecondary),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _clearAllFilters,
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(48, 48),
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                    ),
                                    child: Text('Clear',
                                        style: GoogleFonts.poppins(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.accent)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) => Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                              child: _venueCard(listVenues[i]),
                            ),
                            childCount: listVenues.length,
                          ),
                        ),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
        ),
      ]),
    );
  }

  /// The rail card: one of the few venues picked for this player.
  ///
  /// Its job is different from [_venueCard]'s. The list answers "what is there"; the
  /// rail answers "why this one, for you" — so the match percentage and the reasons
  /// the recommender gave are the card's subject, not an afterthought. `match_pct`
  /// and `reasons` are rendered only when the server actually sent them: the rail
  /// also serves the heuristic and cold-start paths, which carry no score, and a
  /// fabricated percentage beside a real one would make both untrustworthy.
  Widget _aiRecommendedCard(Map<String, dynamic> v) {
    final sportType = (v['sport_type'] ?? 'sport').toString();
    final matchPct = v['match_pct'];
    final rating = asNum(v['rating']);
    final reasons = v['reasons'] is List ? List<String>.from(v['reasons']) : <String>[];

    return Container(
      width: 272,
      margin: const EdgeInsets.only(right: 14),
      child: Material(
        color: AppColors.cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => VenueDetailScreen(venueId: v['id']))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 108,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _venuePhoto(v, sportType),
                    // The match score, where the eye lands first — this is the one
                    // card whose reason for existing is that number.
                    if (matchPct != null)
                      Positioned(
                        top: 9,
                        left: 9,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.auto_awesome,
                                color: AppColors.white, size: 11),
                            const SizedBox(width: 4),
                            Text('$matchPct% match',
                                style: GoogleFonts.poppins(
                                    color: AppColors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold)),
                          ]),
                        ),
                      ),
                    if (rating > 0)
                      Positioned(
                        top: 9,
                        right: 9,
                        child: _photoBadge(
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.star_rounded,
                                color: AppColors.warning, size: 12),
                            const SizedBox(width: 3),
                            Text(rating.toStringAsFixed(1),
                                style: GoogleFonts.poppins(
                                    color: AppColors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold)),
                          ]),
                        ),
                      ),
                    if (v['distance_km'] != null)
                      Positioned(
                        bottom: 9,
                        right: 9,
                        child: _photoBadge(
                          child: Text('${v['distance_km']} km',
                              style: GoogleFonts.poppins(
                                  color: AppColors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v['name'] ?? 'Venue',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.location_on_outlined,
                            color: AppColors.textSecondary, size: 12),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(v['address'] ?? v['city'] ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(
                                  fontSize: 11, color: AppColors.textSecondary)),
                        ),
                      ],
                    ),
                    if (reasons.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (final r in reasons.take(2)) ...[
                            Flexible(child: _amenityChip(r)),
                            const SizedBox(width: 6),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                text: 'PKR ${asNum(v['price_per_hour']).toStringAsFixed(0)}',
                                style: GoogleFonts.poppins(
                                    color: AppColors.textPrimary,
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.bold),
                              ),
                              TextSpan(
                                text: ' /hr',
                                style: GoogleFonts.poppins(
                                    color: AppColors.textSecondary, fontSize: 10.5),
                              ),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.arrow_forward_rounded,
                            color: AppColors.accent, size: 16),
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

  /// The amenities a venue actually advertises, as display labels.
  ///
  /// `venues.amenities` is JSONB shaped as a map (migration 003): a boolean value
  /// means "has it", and any other non-empty value (a count, a note) is shown as a
  /// label too. Keys are snake_case in the database and read as words here, exactly
  /// as the venue detail screen renders them. Returns empty for a venue that lists
  /// none — the card then omits the row rather than inventing facilities.
  List<String> _amenityLabels(Map<String, dynamic> v) {
    final raw = v['amenities'];
    Map<String, dynamic> m;
    if (raw is Map) {
      m = Map<String, dynamic>.from(raw);
    } else if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return const [];
        m = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return const [];
      }
    } else {
      return const [];
    }
    final out = <String>[];
    for (final e in m.entries) {
      final val = e.value;
      if (val is bool) {
        if (!val) continue;
      } else if (val == null || val.toString().trim().isEmpty) {
        continue;
      }
      final words = e.key.toString().replaceAll('_', ' ').trim();
      if (words.isEmpty) continue;
      out.add(words[0].toUpperCase() + words.substring(1));
    }
    return out;
  }

  /// The cover image for a venue, or a sport glyph on the brand field when there is
  /// no photo or the URL will not load. Always drawn inside a parent that has given
  /// it a bounded height.
  Widget _venuePhoto(Map<String, dynamic> v, String sportType) {
    final photos = v['venue_photos'];
    final first = (photos is List && photos.isNotEmpty) ? photos.first?.toString() : null;
    final url = (first != null && first.isNotEmpty) ? first : (v['image_url'] as String?);
    final fallback = ColoredBox(
      color: AppColors.primaryDark,
      child: Center(
        child: Icon(_sportIcon(sportType),
            color: AppColors.white.withValues(alpha: 0.22), size: 44),
      ),
    );
    if (url == null || url.isEmpty) return fallback;
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => fallback,
    );
  }

  /// A badge laid over a venue photo: translucent dark ground, white content, so it
  /// reads on any image.
  Widget _photoBadge({required Widget child}) => DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.photoScrim,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: child,
        ),
      );

  /// One amenity pill under the venue's name.
  Widget _amenityChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
                fontSize: 10,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500)),
      );

  /// The one list card for a venue: a photo band with its badges, then the facts.
  ///
  /// Laid out as a Column over a fixed-height photo rather than a Row of a stretched
  /// image beside a text block. That is not only a visual choice: the previous card
  /// stretched its photo to the row's height, which inside a `SliverList` is
  /// unbounded, so the image was handed an infinite height constraint and the card
  /// threw at layout — leaving the list empty whichever sport was selected. A photo
  /// with its own height can never be given an unbounded one.
  ///
  /// Facts are ordered by what a player decides on — what sport, how good, how far,
  /// what it is called, where, what it offers, what it costs. Every one is a real
  /// column; a venue with no rating, no photo, no amenities or no known distance
  /// simply shows fewer of them.
  Widget _venueCard(Map<String, dynamic> v) {
    final sportType = (v['sport_type'] ?? 'sport').toString();
    final sportColor = _sportColor(sportType);
    final rating = asNum(v['rating']);
    final reviews = asNum(v['total_reviews']).toInt();
    final distance = v['distance_km'];
    final verified = v['is_verified'] == true;
    final amenities = _amenityLabels(v);

    return Material(
      color: AppColors.cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => VenueDetailScreen(venueId: v['id']))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 150,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _venuePhoto(v, sportType),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: sportColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_sportIcon(sportType), color: AppColors.white, size: 12),
                        const SizedBox(width: 5),
                        Text(sportType.toUpperCase(),
                            style: GoogleFonts.poppins(
                                color: AppColors.white,
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5)),
                      ]),
                    ),
                  ),
                  // An unrated venue says "New" rather than showing a zero, which
                  // would read as a bad score instead of an absent one.
                  Positioned(
                    top: 10,
                    right: 10,
                    child: _photoBadge(
                      child: rating > 0
                          ? Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.star_rounded,
                                  color: AppColors.warning, size: 13),
                              const SizedBox(width: 3),
                              Text(rating.toStringAsFixed(1),
                                  style: GoogleFonts.poppins(
                                      color: AppColors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                              if (reviews > 0) ...[
                                const SizedBox(width: 3),
                                Text('($reviews)',
                                    style: GoogleFonts.poppins(
                                        color: AppColors.white, fontSize: 10)),
                              ],
                            ])
                          : Text('New',
                              style: GoogleFonts.poppins(
                                  color: AppColors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600)),
                    ),
                  ),
                  if (distance != null)
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: _photoBadge(
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.near_me_rounded,
                              color: AppColors.white, size: 11),
                          const SizedBox(width: 4),
                          Text('$distance km',
                              style: GoogleFonts.poppins(
                                  color: AppColors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(v['name'] ?? 'Venue',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                                fontWeight: FontWeight.bold,
                                fontSize: 15.5,
                                color: AppColors.textPrimary)),
                      ),
                      // Only shown when the venue really is verified; its absence is
                      // not an accusation, so nothing is drawn in its place.
                      if (verified) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.verified_rounded,
                            color: AppColors.accent, size: 16),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.location_on_outlined,
                          color: AppColors.textSecondary, size: 13),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(v['address'] ?? v['city'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                                fontSize: 11.5, color: AppColors.textSecondary)),
                      ),
                    ],
                  ),
                  if (amenities.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final a in amenities.take(2)) ...[
                          Flexible(child: _amenityChip(a)),
                          const SizedBox(width: 6),
                        ],
                        if (amenities.length > 2)
                          _amenityChip('+${amenities.length - 2}'),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: 'PKR ${asNum(v['price_per_hour']).toStringAsFixed(0)}',
                              style: GoogleFonts.poppins(
                                  color: AppColors.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold),
                            ),
                            TextSpan(
                              text: ' /hr',
                              style: GoogleFonts.poppins(
                                  color: AppColors.textSecondary, fontSize: 11),
                            ),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Not its own button: the whole card opens the venue, which is
                      // where slots are picked, so a second tap target to the same
                      // place would be noise. This states where the tap leads.
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text('Book',
                              style: GoogleFonts.poppins(
                                  color: AppColors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 3),
                          const Icon(Icons.arrow_forward_rounded,
                              color: AppColors.white, size: 13),
                        ]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
