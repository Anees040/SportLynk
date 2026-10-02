import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../models/review.dart';
import '../../providers/auth_provider.dart';
import '../../services/review_service.dart';
import '../../utils/num_util.dart';

import '../../widgets/custom_loader.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/trust_widgets.dart';
import 'confirm_booking_screen.dart';
import 'venue_reviews_screen.dart';

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
  /// Grid-only loading, shown while an uncached date is fetched. Distinct from
  /// [_loading] (the first full-screen venue load) so switching dates never blanks
  /// the gallery, the "about" block, or the date rail — only the slot grid waits.
  bool _slotLoading = false;
  /// Set when a load fails, so the screen can show an error with a retry instead
  /// of the empty-slot view. Without it a failed request reads as "No slots
  /// available" — a venue the backend is serving fine then looks unbookable, and
  /// a first-load failure reads as "Venue not found". Cleared on every success.
  String? _loadError;
  /// Slots and any load error, cached per date (YYYY-MM-DD). Revisiting a date is
  /// instant from here, so fast back-and-forth on the rail never re-waits on the
  /// network; a background fetch still refreshes the cache behind the shown data.
  final Map<String, List<Map<String, dynamic>>> _slotsByDate = {};
  final Map<String, String?> _errorByDate = {};
  /// Free-slot count per date (YYYY-MM-DD) for the rail chips, from one
  /// `/availability` call — so a chip can read "3 left" or "Full" before it is
  /// tapped. A date absent from the map is treated as unknown, not zero.
  final Map<String, int> _freeByDate = {};
  DateTime _selectedDate = DateTime.now();
  String? _selectedSlotId;
  Map<String, dynamic>? _selectedSlot;
  int _galleryPage = 0;
  final PageController _galleryCtrl = PageController();

  /// FR3.7 — the grid re-reads itself while it is open, so another player's
  /// hold or booking shows up here without the player touching anything.
  static const Duration _refreshEvery = Duration(seconds: 30);
  Timer? _refreshTimer;

  /// Cached at init so the checkout hold can still be released from dispose(),
  /// where reading a provider off `context` is no longer safe.
  String? _token;

  /// Reviews summary shown between "about this venue" and the booking flow.
  /// Loaded independently of the slot grid and its auto-refresh: a reviews
  /// failure must never blank the slots the player came here to book, so this
  /// keeps [VenueReviews.empty] and the sliver simply doesn't render.
  final ReviewService _reviewService = ReviewService();
  VenueReviews _reviews = VenueReviews.empty;

  @override
  void initState() {
    super.initState();
    _token = Provider.of<AuthProvider>(context, listen: false).token;
    _load();
    _loadAvailability();
    _loadReviews();
    _startAutoRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    // Leaving checkout hands the slot straight back instead of making the next
    // player wait out the 5-minute expiry.
    final held = _selectedSlotId;
    if (held != null) _releaseLock(held);
    _galleryCtrl.dispose();
    super.dispose();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshEvery, (_) {
      if (mounted) _load();
    });
  }

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Load the slots for [date] (or the selected date), keeping the page responsive.
  ///
  /// Three things make date switching feel instant rather than blanking the screen:
  ///   - the full-screen loader shows only on the very first venue load; a date
  ///     change keeps the gallery/about/rail and waits only in the grid;
  ///   - a date whose slots are cached paints immediately, and the network fetch
  ///     then refreshes that cache quietly;
  ///   - a stale-response guard: a reply is applied to the grid only if its date is
  ///     still the selected one, so fast back-and-forth can't let an older date's
  ///     slots land on top of a newer selection.
  Future<void> _load([DateTime? date]) async {
    final d = date ?? _selectedDate;
    final key = _dateStr(d);
    final isFirstLoad = _venue == null;

    setState(() {
      if (isFirstLoad) {
        _loading = true;
      } else if (_slotsByDate.containsKey(key)) {
        // Cached: show it now, refresh in the background without a spinner.
        _slots = _slotsByDate[key]!;
        _loadError = _errorByDate[key];
        _slotLoading = false;
      } else {
        // Uncached date: wait in the grid only, not the whole screen. Clear the
        // old date's slots so the loader shows rather than a stale grid.
        _slotLoading = true;
        _loadError = null;
        _slots = [];
      }
    });

    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(
        Uri.parse(
          '${ApiConstants.baseUrl}/venues/${widget.venueId}?date=$key',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (!mounted) return;

      if (data['success'] == true) {
        final slots =
            List<Map<String, dynamic>>.from(data['data']['slots'] ?? []);
        _slotsByDate[key] = slots;
        _errorByDate[key] = null;
        final stillSelected = _dateStr(_selectedDate) == key;
        final prevSelectedId = _selectedSlotId;
        var lostSelection = false;
        setState(() {
          _venue = data['data'];
          _loading = false;
          if (!stillSelected) return; // cache updated; the shown date moved on
          _slots = slots;
          _loadError = null;
          _slotLoading = false;
          if (prevSelectedId != null) {
            // Keep a live selection across an auto-refresh of the same date.
            final found =
                slots.where((s) => s['id'] == prevSelectedId).toList();
            if (found.isNotEmpty && _isSelectable(found.first)) {
              _selectedSlot = found.first;
            } else {
              _selectedSlotId = null;
              _selectedSlot = null;
              lostSelection = true;
            }
          }
        });
        if (lostSelection) {
          _snack('That slot was just taken by another player. Pick another one.');
        }
      } else {
        // A reached server that answered with something other than success. A real
        // 404 means the venue is gone and a retry cannot help, so that alone keeps
        // the "Venue not found" view; anything else is surfaced with a retry rather
        // than swallowed into "No slots available".
        final msg = resp.statusCode == 404
            ? null
            : (data['message'] ?? 'Could not load this venue. Please try again.')
                .toString();
        _errorByDate[key] = msg;
        if (_dateStr(_selectedDate) == key) {
          setState(() {
            _loading = false;
            _slotLoading = false;
            _loadError = msg;
            _slots = _slotsByDate[key] ?? [];
          });
        }
      }
    } catch (_) {
      // The request never completed: no connection, a timeout, or a non-JSON body.
      // On the phone this is most often adb reverse not being set up.
      if (!mounted) return;
      const msg = 'Could not reach the server. Check your connection and try again.';
      _errorByDate[key] = msg;
      if (_dateStr(_selectedDate) == key) {
        setState(() {
          _loading = false;
          _slotLoading = false;
          _loadError = msg;
          _slots = _slotsByDate[key] ?? [];
        });
      }
    }
  }

  /// One call fills the rail chips with each date's free-slot count, so a player
  /// sees which days are open without opening each. Silent on failure — the chips
  /// simply omit the count and the grid remains the source of truth.
  Future<void> _loadAvailability() async {
    final token = _token;
    if (token == null) return;
    try {
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/venues/${widget.venueId}/availability?days=14'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (!mounted || data['success'] != true) return;
      final list = List<Map<String, dynamic>>.from(data['data']['byDate'] ?? []);
      setState(() {
        _freeByDate.clear();
        for (final row in list) {
          _freeByDate[row['date'].toString()] = (row['free'] as num?)?.toInt() ?? 0;
        }
      });
    } catch (_) {
      // No chip counts; not worth surfacing.
    }
  }

  /// Jump to any date in the booking window via the calendar, for days past the
  /// 14-chip rail. Switching clears any hold the same way a rail tap does.
  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 60)),
    );
    if (picked == null || !mounted) return;
    if (_dateStr(picked) == _dateStr(_selectedDate)) return;
    final held = _selectedSlotId;
    setState(() {
      _selectedDate = picked;
      _selectedSlotId = null;
      _selectedSlot = null;
    });
    if (held != null) _releaseLock(held);
    _load(picked);
  }

  /// Venue-wide review aggregates + the first page (only the top 3 are previewed
  /// here). Only the first page is fetched with page 1; "View all" opens the
  /// dedicated paginated screen. Silent on failure by design.
  Future<void> _loadReviews() async {
    final token = _token;
    if (token == null) return;
    final r = await _reviewService.venueReviews(
      token,
      widget.venueId,
      page: 1,
      limit: 20,
    );
    if (mounted) setState(() => _reviews = r);
  }

  /// Green (free) or a hold this player owns — anything else belongs to somebody
  /// else. `effective_status` is derived server-side from `slots.locked_until`.
  bool _isSelectable(Map<String, dynamic> slot) {
    final status = (slot['effective_status'] ?? slot['status'] ?? 'available')
        .toString();
    return status == 'available' || slot['locked_by_me'] == true;
  }

  Future<void> _onSlotTap(
    Map<String, dynamic> slot,
    bool isCurrentlySelected,
  ) async {
    final slotId = slot['id'].toString();

    // Tapping the selected slot again clears it and hands the hold back.
    if (isCurrentlySelected) {
      setState(() {
        _selectedSlotId = null;
        _selectedSlot = null;
      });
      _releaseLock(slotId);
      return;
    }

    // Optimistic selection: the tap registers instantly and Book Now lights up at
    // once, the way a real booking app feels. The 5-minute checkout hold is taken
    // in the background rather than awaited — the hold is only a courtesy so two
    // players don't fill the same form, and the booking itself re-checks the slot
    // under a row lock, so a selection that loses the hold still fails safely at
    // confirm time rather than letting the player pay twice.
    final previous = _selectedSlotId;
    setState(() {
      _selectedSlotId = slotId;
      _selectedSlot = slot;
    });
    if (previous != null && previous != slotId) _releaseLock(previous);
    _acquireHoldInBackground(slotId);
  }

  /// Takes the checkout hold without blocking the tap. If the slot was already held
  /// or booked by someone else, this reverts just that selection (and only while it
  /// is still the selected one) and repaints so the Blue/Amber state shows — it
  /// never blocks the player from tapping a different slot in the meantime.
  Future<void> _acquireHoldInBackground(String slotId) async {
    final failure = await _lockSlot(slotId);
    if (!mounted || failure == null) return;
    if (_selectedSlotId == slotId) {
      setState(() {
        _selectedSlotId = null;
        _selectedSlot = null;
      });
      _snack(failure);
      _load();
    }
  }

  /// Holds the slot for 5 minutes. Returns null on success, otherwise the
  /// server's reason (409 = another player is already in checkout on it).
  Future<String?> _lockSlot(String slotId) async {
    try {
      final resp = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/slots/$slotId/lock'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final data = jsonDecode(resp.body);
      if (data['success'] == true) return null;
      return (data['message'] ?? 'Could not hold this slot').toString();
    } catch (_) {
      return 'Network error. Please try again.';
    }
  }

  /// Best-effort by design — the hold also expires on its own after 5 minutes,
  /// so a failed release is never worth interrupting the player over.
  void _releaseLock(String slotId) {
    final token = _token;
    if (token == null) return;
    http
        .delete(
          Uri.parse('${ApiConstants.baseUrl}/slots/$slotId/lock'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .ignore();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
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
      try {
        return Map<String, dynamic>.from(jsonDecode(a));
      } catch (_) {}
    }
    return {};
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: const CustomLoader(),
      );
    }
    if (_venue == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        // A failed first load is a reachability problem, not a missing venue, so
        // it offers a retry instead of the dead end "Venue not found" was.
        body: _loadError != null
            ? NetworkErrorView(message: _loadError!, onRetry: () => _load())
            : Center(
                child: Text(
                  'Venue not found',
                  style: GoogleFonts.poppins(color: AppColors.textSecondary),
                ),
              ),
      );
    }

    final price = asNum(_venue!['price_per_hour']);
    final sportType = (_venue!['sport_type'] ?? 'sport').toString();
    final images = _galleryImages;

    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: _bottomBar(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // Hero gallery
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: AppColors.primary,
            iconTheme: const IconThemeData(color: Colors.white),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                children: [
                  if (images.isNotEmpty)
                    PageView.builder(
                      controller: _galleryCtrl,
                      itemCount: images.length,
                      onPageChanged: (i) => setState(() => _galleryPage = i),
                      itemBuilder: (_, i) => Image.network(
                        images[i],
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, e, st) =>
                            _gradientPlaceholder(sportType),
                      ),
                    )
                  else
                    _gradientPlaceholder(sportType),
                  // Gradient overlay at bottom
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.3, 1.0],
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.85),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Page indicator dots
                  if (images.length > 1)
                    Positioned(
                      bottom: 90,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          images.length,
                          (i) => AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: _galleryPage == i ? 24 : 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: _galleryPage == i
                                  ? Colors.white
                                  : Colors.white54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Photo count badge
                  if (images.length > 1)
                    Positioned(
                      top: 90,
                      right: 16,
                      child: SafeArea(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.photo_library_outlined,
                                color: Colors.white,
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${_galleryPage + 1}/${images.length}',
                                style: GoogleFonts.poppins(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // Rating badge
                  Positioned(
                    top: 90,
                    left: 16,
                    child: SafeArea(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.star_rounded,
                              color: Colors.amber,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${_venue!['rating'] ?? '0.0'}',
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              ' (${_venue!['total_reviews'] ?? 0})',
                              style: GoogleFonts.poppins(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Venue name at bottom of hero
                  Positioned(
                    bottom: 16,
                    left: 16,
                    right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _sportColor(sportType),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            sportType.toUpperCase(),
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _venue!['name'] ?? '',
                          style: GoogleFonts.poppins(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // VENUE INFO card
          SliverToBoxAdapter(
            child: Transform.translate(
              offset: const Offset(0, 0),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Price row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColors.accentLight,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.payments_outlined,
                                color: AppColors.accent,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Price per Hour',
                                  style: GoogleFonts.poppins(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                                Text(
                                  'PKR ${price.toStringAsFixed(0)}',
                                  style: GoogleFonts.poppins(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (_venue!['ground_type'] != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.inputFill,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              (_venue!['ground_type']).toString().toUpperCase(),
                              style: GoogleFonts.poppins(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textSecondary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const Divider(color: AppColors.border, height: 24),
                    // Location
                    _infoRow(
                      Icons.location_on_outlined,
                      _venue!['address'] ?? _venue!['city'] ?? '',
                    ),
                    const SizedBox(height: 8),
                    // Hours
                    _infoRow(
                      Icons.access_time_outlined,
                      '${_venue!['operating_hours_from'] ?? '06:00'} – ${_venue!['operating_hours_to'] ?? '23:00'}',
                    ),
                    if (_venue!['owner_name'] != null) ...[
                      const SizedBox(height: 8),
                      _infoRow(
                        Icons.person_outline,
                        'Managed by ${_venue!['owner_name']}',
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // Amenities section
          if (_amenities.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0E7FF),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.checklist_rounded,
                              color: Color(0xFF6366F1),
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Amenities & Facilities',
                            style: GoogleFonts.poppins(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ..._amenities.entries.map((e) {
                        final key = e.key.toString();
                        final val = e.value;
                        final isBool = val is bool;
                        final displayKey = key.replaceAll('_', ' ');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Icon(
                                isBool
                                    ? (val ? Icons.check_circle : Icons.cancel)
                                    : Icons.info_outline,
                                color: isBool
                                    ? (val ? AppColors.accent : AppColors.error)
                                    : AppColors.textSecondary,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  displayKey[0].toUpperCase() +
                                      displayKey.substring(1),
                                  style: GoogleFonts.poppins(
                                    fontSize: 13,
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              Text(
                                isBool ? (val ? 'Yes' : 'No') : val.toString(),
                                style: GoogleFonts.poppins(
                                  fontSize: 13,
                                  color: isBool
                                      ? (val
                                            ? AppColors.accent
                                            : AppColors.error)
                                      : AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),

          // Reviews summary
          // Sits with the other "about this venue" content, above the date/slot
          // booking flow. Aggregates are venue-wide; only the top 3 preview here.
          SliverToBoxAdapter(child: _reviewsSummary()),

          // Date selector
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Select Date',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accentLight,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _monthYear(_selectedDate),
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: AppColors.accent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          // A calendar jump for dates past the 14-day rail.
                          IconButton(
                            onPressed: _pickDate,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            icon: const Icon(
                              Icons.calendar_month_outlined,
                              size: 20,
                              color: AppColors.accent,
                            ),
                            tooltip: 'Pick a date',
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 78,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: 14,
                      itemBuilder: (_, i) {
                        final date = DateTime.now().add(Duration(days: i));
                        final isToday = i == 0;
                        final selected =
                            _dateStr(date) == _dateStr(_selectedDate);
                        return GestureDetector(
                          onTap: () {
                            if (_dateStr(date) == _dateStr(_selectedDate)) return;
                            // Switching dates abandons any hold taken on the old
                            // date's slot and clears the selection — a hold belongs
                            // to the day it was taken on.
                            final held = _selectedSlotId;
                            setState(() {
                              _selectedDate = date;
                              _selectedSlotId = null;
                              _selectedSlot = null;
                            });
                            if (held != null) _releaseLock(held);
                            _load(date);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 56,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              gradient: selected
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF0A1F13),
                                        Color(0xFF166534),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    )
                                  : null,
                              color: selected ? null : Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: selected
                                    ? AppColors.primary
                                    : AppColors.border,
                                width: selected ? 0 : 1,
                              ),
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                        color: AppColors.primary.withValues(
                                          alpha: 0.3,
                                        ),
                                        blurRadius: 8,
                                        offset: const Offset(0, 3),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  isToday ? 'TODAY' : _weekday(date),
                                  style: GoogleFonts.poppins(
                                    fontSize: 9,
                                    color: selected
                                        ? Colors.white70
                                        : AppColors.textSecondary,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${date.day}',
                                  style: GoogleFonts.poppins(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: selected
                                        ? Colors.white
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                _dateChipAvailability(_dateStr(date), selected),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          // SLOTS HEADER + legend
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Available Slots',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.auto_graph_rounded,
                          size: 12, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Prices vary by time — peak hours cost more',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 6,
                    children: [
                      _legend(const Color(0xFF22C55E), 'Available'),
                      _legend(const Color(0xFFF59E0B), 'Booked'),
                      _legend(const Color(0xFFEF4444), 'Blocked'),
                      _legend(const Color(0xFF3B82F6), 'Held'),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Slot GRID
          if (_slotLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              ),
            )
          else if (_slots.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((_, i) {
                  final slot = _slots[i];
                  // Server-derived: folds a live checkout hold into 'locked'.
                  final status =
                      (slot['effective_status'] ??
                              slot['status'] ??
                              'available')
                          .toString();
                  final selectable = _isSelectable(slot);
                  final selected = _selectedSlotId == slot['id'];
                  final time12 = _to12Hour(slot['start_time']);
                  final slotPrice = asNum(slot['price']);
                  final statusColor = _slotStatusColor(status);

                  return GestureDetector(
                    onTap: (selectable || selected)
                        ? () => _onSlotTap(slot, selected)
                        : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        gradient: selected
                            ? const LinearGradient(
                                colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              )
                            : null,
                        color: selected
                            ? null
                            : selectable
                            ? Colors.white
                            : statusColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? AppColors.primary
                              : selectable
                              ? AppColors.border
                              : statusColor.withValues(alpha: 0.3),
                          width: selected ? 2 : 1,
                        ),
                        boxShadow: selected
                            ? [
                                BoxShadow(
                                  color: AppColors.primary.withValues(
                                    alpha: 0.25,
                                  ),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ]
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            time12,
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: selected
                                  ? Colors.white
                                  : selectable
                                  ? AppColors.textPrimary
                                  : statusColor,
                              decoration: !selectable
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 2),
                          if (selectable)
                            Text(
                              'PKR ${slotPrice.toStringAsFixed(0)}',
                              style: GoogleFonts.poppins(
                                fontSize: 9,
                                color: selected
                                    ? Colors.white70
                                    : AppColors.textSecondary,
                              ),
                            )
                          else
                            Text(
                              _slotStatusLabel(status),
                              style: GoogleFonts.poppins(
                                fontSize: 8,
                                color: statusColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }, childCount: _slots.length),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 2.0,
                ),
              ),
            ),

          if (!_slotLoading && _slots.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  // An empty grid has two causes that must not look the same: the
                  // day is genuinely free of slots, or the load failed. The second
                  // offers a retry; "Try a different date" would send the player
                  // to re-run a request that never completed.
                  child: _loadError != null
                      ? _slotLoadError()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.event_busy_outlined,
                              size: 48,
                              color: AppColors.textSecondary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No slots available',
                              style: GoogleFonts.poppins(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Try selecting a different date',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The slot grid's error-with-retry state, used in place of the empty view when
  /// a load failed. Compact and non-scrolling because it sits inside the venue
  /// page's CustomScrollView; the full-screen [NetworkErrorView] covers the
  /// first-load case where the whole screen is the error.
  /// The tiny free-slot line under a date chip's number: "3 left", "Full", or an
  /// even gap while the count is still unknown, so chips do not jump when the
  /// counts arrive. Colour tracks the chip's selected state.
  Widget _dateChipAvailability(String dateKey, bool selected) {
    final free = _freeByDate[dateKey];
    if (free == null) return const SizedBox(height: 11);
    final full = free == 0;
    return Text(
      full ? 'Full' : '$free left',
      style: GoogleFonts.poppins(
        fontSize: 8,
        fontWeight: FontWeight.w600,
        color: selected
            ? Colors.white70
            : full
                ? AppColors.textSecondary.withValues(alpha: 0.6)
                : AppColors.accent,
      ),
    );
  }

  Widget _slotLoadError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 48, color: AppColors.disabled),
        const SizedBox(height: 12),
        Text(
          'Could not load slots',
          style: GoogleFonts.poppins(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _loadError ?? 'Please try again.',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 12,
            height: 1.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _load(),
          icon: const Icon(Icons.refresh, size: 18, color: AppColors.accent),
          label: Text(
            'Retry',
            style: GoogleFonts.poppins(
              color: AppColors.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            side: const BorderSide(color: AppColors.accent),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ],
    );
  }

  Widget _gradientPlaceholder(String sportType) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF0A1F13),
            _sportColor(sportType).withValues(alpha: 0.6),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          _sportIcon(sportType),
          color: Colors.white.withValues(alpha: 0.08),
          size: 160,
        ),
      ),
    );
  }

  // Reviews summary (venue detail)
  void _openAllReviews() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VenueReviewsScreen(
          venueId: widget.venueId,
          venueName: _venue?['name']?.toString(),
        ),
      ),
    );
  }

  Widget _reviewsSummary() {
    final r = _reviews;
    final avg = r.avgStars;
    final preview = r.reviews.take(3).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.reviews_outlined,
                    color: AppColors.accent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Player Reviews',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const Spacer(),
                if (r.total > 0)
                  Flexible(
                    child: Text(
                      '${r.total} ${r.total == 1 ? 'review' : 'reviews'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),

            if (r.total == 0) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.rate_review_outlined,
                    size: 18,
                    color: AppColors.textSecondary.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No reviews yet — play here and be the first to rate it.',
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 16),
              // Average + histogram
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    children: [
                      Text(
                        avg == null ? '—' : avg.toStringAsFixed(1),
                        style: GoogleFonts.poppins(
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                          height: 1,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      StarsDisplay(rating: avg ?? 0, size: 15),
                      const SizedBox(height: 4),
                      Text(
                        'out of 5',
                        style: GoogleFonts.poppins(
                          fontSize: 10.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: StarsHistogram(counts: r.starCounts)),
                ],
              ),

              // AI sentiment split — only once the model has scored something.
              if (!r.sentiment.isEmpty) ...[
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      size: 14,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'AI Sentiment',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SentimentSummaryBar(distribution: r.sentiment),
              ],

              if (preview.isNotEmpty) ...[
                const Divider(color: AppColors.border, height: 28),
                ...preview.map((rev) => ReviewCard(review: rev)),
              ] else
                const SizedBox(height: 16),

              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openAllReviews,
                  icon: const Icon(
                    Icons.forum_outlined,
                    size: 16,
                    color: AppColors.accent,
                  ),
                  label: Text(
                    'View all ${r.total} ${r.total == 1 ? 'review' : 'reviews'}',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.accent),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final slotPrice = _selectedSlot != null
        ? asNum(_selectedSlot!['price'])
        : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'TOTAL AMOUNT',
                      style: GoogleFonts.poppins(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      _selectedSlot != null
                          ? 'PKR ${slotPrice.toStringAsFixed(0)}'
                          : 'Select a slot',
                      style: GoogleFonts.poppins(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: _selectedSlot != null
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _selectedSlot == null ? null : _goToConfirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      disabledBackgroundColor: AppColors.disabled,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: _selectedSlot != null ? 4 : 0,
                      shadowColor: AppColors.accent.withValues(alpha: 0.4),
                    ),
                    child: Text(
                      'Book Now',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _goToConfirm() async {
    if (_selectedSlot == null || _venue == null) return;
    // Hold the refresh while checkout is on top — nothing there reacts to a
    // repaint, and a snackbar would land over the confirm screen.
    _refreshTimer?.cancel();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConfirmBookingScreen(
          venue: _venue!,
          slot: _selectedSlot!,
          selectedDate: _selectedDate,
        ),
      ),
    );
    if (!mounted) return;
    _startAutoRefresh();
    _load();
  }

  Widget _infoRow(IconData icon, String text) => Row(
    children: [
      Icon(icon, color: AppColors.textSecondary, size: 16),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: GoogleFonts.poppins(
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );

  Widget _legend(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 4),
      Text(
        label,
        style: GoogleFonts.poppins(
          fontSize: 11,
          color: AppColors.textSecondary,
        ),
      ),
    ],
  );

  // SRS colour code: Green free · Amber booked · Red blocked · Blue held.
  Color _slotStatusColor(String status) => switch (status) {
    'available' => const Color(0xFF22C55E),
    'booked' => const Color(0xFFF59E0B),
    'blocked' => const Color(0xFFEF4444),
    'locked' => const Color(0xFF3B82F6),
    _ => AppColors.disabled,
  };

  String _slotStatusLabel(String status) => switch (status) {
    'booked' => 'BOOKED',
    'blocked' => 'BLOCKED',
    'locked' => 'HELD',
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
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }

  String _weekday(DateTime d) {
    const days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return days[d.weekday - 1];
  }
}
