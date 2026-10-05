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
                    if (v['distance_km'] != null) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(Icons.near_me_rounded, color: Colors.white70, size: 12),
                          const SizedBox(width: 4),
                          Text('${v['distance_km']} km away',
                            style: GoogleFonts.poppins(
                                color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ],
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

  /// The one list card for a venue: photo left, facts right.
  ///
  /// Used for every row in the browse and search list, and the recommendation rail
  /// uses a compact variant of the same anatomy so the screen reads as one system.
  /// Facts are ordered by what a player decides on — sport, name, where, how far,
  /// what it costs — rather than by what happens to be in the payload.
  Widget _venueCard(Map<String, dynamic> v) {
    final sportType = (v['sport_type'] ?? 'sport').toString();
    final sportColor = _sportColor(sportType);
    final rating = asNum(v['rating']);
    final distance = v['distance_km'];

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => VenueDetailScreen(venueId: v['id']))),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))]),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
              child: SizedBox(
                width: 112,
                child: Container(
                  color: AppColors.primaryDark,
                  child: (v['venue_photos'] != null && (v['venue_photos'] as List).isNotEmpty)
                      ? Image.network(v['venue_photos'][0], fit: BoxFit.cover,
                          errorBuilder: (ctx, err, stack) => Center(child: Icon(_sportIcon(sportType), color: Colors.white.withValues(alpha: 0.2), size: 40)))
                      : Center(child: Icon(_sportIcon(sportType), color: Colors.white.withValues(alpha: 0.2), size: 40)),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: sportColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                            child: Text(sportType.toUpperCase(),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(color: sportColor, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // An unrated venue shows "New" rather than a zero, which would
                        // read as a bad score instead of an absent one.
                        if (rating > 0) ...[
                          const Icon(Icons.star_rounded, color: Colors.amber, size: 15),
                          const SizedBox(width: 3),
                          Text(rating.toStringAsFixed(1),
                            maxLines: 1,
                            style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                        ] else
                          Text('New', maxLines: 1, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(v['name'] ?? 'Venue',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.location_on_outlined, color: AppColors.textSecondary, size: 13),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(v['address'] ?? v['city'] ?? '',
                            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Price and distance share one line, so both have to survive a
                    // large system text scale inside ~254 logical pixels. The price
                    // is Flexible and ellipsises; the distance chip keeps its natural
                    // width because an elided distance says nothing. Laid out as one
                    // Text.rich rather than two Texts so the unit cannot be orphaned
                    // onto its own overflowing line.
                    Row(
                      children: [
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                text: 'PKR ${asNum(v['price_per_hour']).toStringAsFixed(0)}',
                                style: GoogleFonts.poppins(
                                    color: AppColors.accent,
                                    fontSize: 15,
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
                        if (distance != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.inputFill,
                              borderRadius: BorderRadius.circular(6)),
                            child: Text('$distance km',
                              maxLines: 1,
                              style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    ),
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
