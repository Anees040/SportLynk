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
import '../../utils/deposit_policy.dart';

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

  /// The slots the player has selected, first to last.
  ///
  /// A list rather than a single slot because consecutive hours can be booked
  /// together. It is kept chronologically sorted and always contiguous — every
  /// path that adds or removes an entry preserves both, so no code downstream has
  /// to re-check it. Empty means nothing is selected; one entry is the ordinary
  /// single booking.
  final List<Map<String, dynamic>> _selected = [];

  /// The server's price for the current run: total, discount percent and saving.
  ///
  /// Only fetched for two slots or more, and only ever displayed — never computed
  /// here. The discount ladder belongs to the owner and lives on the server, so a
  /// second copy in Dart would be a price the booking contradicts. Null while a
  /// request is in flight or when the run is a single slot.
  Map<String, dynamic>? _groupQuote;
  bool _quoteLoading = false;

  /// Guards against an out-of-order quote reply overwriting a newer one: a reply
  /// is applied only if its token is still the latest request.
  int _quoteToken = 0;

  /// Slots already reported as taken by the 30-second refresh.
  ///
  /// Without this, a slot lost once is announced again on every refresh, because
  /// each refresh re-walks the selection and finds it missing again. Each slot is
  /// reported at most once; the set is cleared whenever the player changes the
  /// selection themselves, so a slot genuinely taken twice is still told twice.
  final Set<String> _reportedLost = {};

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

  /// The slots selected, as ids, in the order they will be booked in.
  List<String> get _selectedIds =>
      _selected.map((s) => s['id'].toString()).toList(growable: false);

  bool _isSelected(Map<String, dynamic> slot) =>
      _selected.any((s) => s['id'] == slot['id']);

  /// A TIME value as 'HH:MM:SS', so two of them can be compared as strings.
  /// Mirrors `timeStr` in backend/src/utils/slotGroup.js.
  String _timeKey(dynamic raw) {
    final s = raw == null ? '' : raw.toString().trim();
    final m = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(s);
    if (m == null) return s;
    return '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}:${m.group(3) ?? '00'}';
  }

  /// The most slots one checkout may cover. Mirrors `MAX_SELECTION_SLOTS` in
  /// backend/src/utils/slotGroup.js; the server refuses anything larger, so this
  /// only exists to stop the player reaching that refusal.
  ///
  /// This bounds the SELECTION, not one booking. A selection may be several
  /// disjoint runs, and each run becomes its own booking with its own QR — see
  /// [_runsInSelection].
  static const int _maxSelectionSlots = 4;

  /// Hands back every hold the selection is holding. Used wherever the selection
  /// is abandoned wholesale — a date change, leaving the screen, or Clear.
  void _releaseAllHolds() {
    for (final id in _selectedIds) {
      _releaseLock(id);
    }
  }

  void _clearSelection({bool releaseHolds = true}) {
    if (releaseHolds) _releaseAllHolds();
    _selected.clear();
    _reportedLost.clear();
    _groupQuote = null;
    _quoteLoading = false;
    _quoteToken += 1;
  }

  /// Drops one slot and hands its hold back. Unlike the old `_truncateFrom` this
  /// removes only the tapped slot: the selection no longer has to stay contiguous,
  /// so there is no "everything after it" to take with it.
  void _deselect(String slotId) {
    final at = _selected.indexWhere((s) => s['id'].toString() == slotId);
    if (at < 0) return;
    _releaseLock(slotId);
    _selected.removeAt(at);
    _reportedLost.remove(slotId);
  }

  /// Chronological within the selected date, so runs are always read in playing
  /// order regardless of the order the slots were tapped in.
  void _sortSelection() {
    _selected.sort((a, b) {
      final byDate = _slotDateKey(a).compareTo(_slotDateKey(b));
      return byDate != 0
          ? byDate
          : _timeKey(a['start_time']).compareTo(_timeKey(b['start_time']));
    });
  }

  /// A slot's `slot_date` as `YYYY-MM-DD`, whatever shape it arrived in.
  ///
  /// The API sends a DATE column as an ISO timestamp (`2026-10-10T00:00:00.000Z`),
  /// so two slots on the same day compare equal as raw strings only while the
  /// time component matches — which is true today but is not something the
  /// adjacency rule should depend on. Truncating to the date is the property the
  /// rule actually needs.
  String _slotDateKey(Map<String, dynamic> slot) {
    final raw = (slot['slot_date'] ?? '').toString().trim();
    if (raw.length >= 10 && raw[4] == '-' && raw[7] == '-') {
      return raw.substring(0, 10);
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return '${parsed.year.toString().padLeft(4, '0')}-'
        '${parsed.month.toString().padLeft(2, '0')}-'
        '${parsed.day.toString().padLeft(2, '0')}';
  }

  /// Does [next] begin exactly where [prev] ends?
  ///
  /// The one statement of the adjacency rule on the client, mirroring
  /// `areAdjacent` in backend/src/utils/slotGroup.js. The midnight seam is
  /// included: a venue open past midnight sells a 23:00 hour ending at the
  /// `24:00:00` end-of-day marker and a 00:00 hour beginning at `00:00:00`, and
  /// those two are back to back even though the strings differ and the rows carry
  /// different dates. Without this, 11 PM and 12 AM could never be booked together
  /// — selecting one silently deselected the other.
  bool _areAdjacent(Map<String, dynamic> prev, Map<String, dynamic> next) {
    final prevEnd = _timeKey(prev['end_time']);
    final nextStart = _timeKey(next['start_time']);
    final prevDate = _slotDateKey(prev);
    final nextDate = _slotDateKey(next);
    if (prevDate == nextDate) return prevEnd == nextStart;
    // Different dates. The only legal join is the seam: a day ending at the
    // 24:00:00 marker followed by the next day beginning at 00:00:00.
    if (prevEnd != '24:00:00' || nextStart != '00:00:00') return false;
    final a = DateTime.tryParse(prevDate);
    final b = DateTime.tryParse(nextDate);
    if (a == null || b == null) return false;
    return b.difference(a).inDays == 1;
  }

  /// The selection split into maximal contiguous runs, in playing order.
  ///
  /// Each run is what one booking can cover, because a booking is a single
  /// unbroken session: its escrow, its deposit, its refund window and its QR all
  /// describe one arrival. Two runs therefore mean two bookings and two QR codes —
  /// 09:00-11:00 and 18:00-20:00 is two trips to the ground, and four unrelated
  /// singles are four. Mirrors `partitionRuns` in backend/src/utils/slotGroup.js.
  List<List<Map<String, dynamic>>> get _runsInSelection {
    if (_selected.isEmpty) return const [];
    final sorted = List<Map<String, dynamic>>.of(_selected)..sort((a, b) {
        final byDate = _slotDateKey(a).compareTo(_slotDateKey(b));
        return byDate != 0
            ? byDate
            : _timeKey(a['start_time']).compareTo(_timeKey(b['start_time']));
      });
    final runs = <List<Map<String, dynamic>>>[];
    var current = <Map<String, dynamic>>[];
    for (final slot in sorted) {
      if (current.isEmpty) {
        current.add(slot);
      } else if (_areAdjacent(current.last, slot)) {
        current.add(slot);
      } else {
        runs.add(current);
        current = [slot];
      }
    }
    if (current.isNotEmpty) runs.add(current);
    return runs;
  }

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
    // Leaving checkout hands the slots straight back instead of making the next
    // player wait out the 5-minute expiry.
    _releaseAllHolds();
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
        final prevSelectedIds = _selectedIds;
        // Slots this refresh found genuinely taken, that the player has not already
        // been told about. Announcing them outside the setState below.
        var newlyTaken = const <String>[];
        setState(() {
          _venue = data['data'];
          _loading = false;
          if (!stillSelected) return; // cache updated; the shown date moved on
          _slots = slots;
          _loadError = null;
          _slotLoading = false;
          if (prevSelectedIds.isNotEmpty) {
            // Keep a live selection across an auto-refresh of the same date, and
            // re-point it at the fresh rows so a repriced slot shows its new price.
            //
            // Every still-selectable slot is kept, not only the run up to the first
            // loss. The selection no longer has to be contiguous, so a slot dropped
            // out of the middle is a perfectly bookable arrangement — truncating at
            // the first loss used to discard good slots the player had chosen, which
            // is one half of the "slots deselect themselves" report.
            //
            // A slot missing from the grid has usually STARTED, not been taken: the
            // server filters to start_time > now, so it simply is not offered any
            // more. It is dropped silently. Only a slot that is still listed but no
            // longer selectable — booked or held by somebody else — is reported.
            final kept = <Map<String, dynamic>>[];
            final stale = <String>[];
            final taken = <String>[];
            for (final id in prevSelectedIds) {
              final found = slots.where((s) => s['id'].toString() == id).toList();
              if (found.isNotEmpty && _isSelectable(found.first)) {
                kept.add(found.first);
              } else if (found.isNotEmpty) {
                stale.add(id);
                taken.add(id);
              } else {
                stale.add(id);
              }
            }
            // Only a loss the player has not already been told about is announced,
            // so a slot taken once does not produce a snackbar every thirty seconds
            // for as long as the screen is open.
            newlyTaken = taken.where(_reportedLost.add).toList();
            for (final id in stale) {
              _releaseLock(id);
            }
            _selected
              ..clear()
              ..addAll(kept);
            _sortSelection();
          }
        });
        if (newlyTaken.isNotEmpty) {
          _snack(_selected.isEmpty
              ? 'That slot was just taken by another player. Pick another one.'
              : 'Part of your selection was just taken. The rest is still held.');
        }
        // Prices may have moved with the refresh, so the quote is re-read rather
        // than left showing a total derived from slots that have since changed.
        _refreshQuote();
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
  /// 14-chip rail.
  ///
  /// Like a rail tap this keeps the selection, because the grid shows one date at a
  /// time and the midnight seam spans two of them: a venue open 18:00-02:00 sells
  /// 23:00 on one date and 00:00 on the next, and those two hours are back to back.
  /// Clearing on every date change made that pair impossible to book together —
  /// exactly the 11 PM + 12 AM case at a late-night ground.
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
    setState(() {
      _selectedDate = picked;
      _sortSelection();
    });
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

  /// Whether this slot was freed by a near-kickoff cancellation recently enough to
  /// still carry the "just freed" tag (item 8 re-listing). Only an available slot
  /// qualifies, and only within 24h of the stamp, so an old `relisted_at` left on a
  /// slot that has since been booked and freed again never shows a stale tag.
  bool _isRelisted(Map<String, dynamic> slot) {
    final raw = slot['relisted_at'];
    if (raw == null) return false;
    final at = DateTime.tryParse(raw.toString());
    if (at == null) return false;
    if (!_isSelectable(slot)) return false;
    return DateTime.now().difference(at.toLocal()) < const Duration(hours: 24);
  }

  /// Tap behaviour: tap a free slot to add it to the selection, tap a selected
  /// slot to remove just that one.
  ///
  /// The selection may be any arrangement up to [_maxSelectionSlots]: 09:00 and
  /// 10:00 followed by 18:00 is a legitimate choice. Contiguity is enforced per
  /// run when the selection is booked, where each unbroken run becomes its own
  /// booking and its own QR — so tapping a non-adjacent hour no longer has to undo
  /// anything, and the grid never deselects a slot the player did not tap.
  Future<void> _onSlotTap(
    Map<String, dynamic> slot,
    bool isCurrentlySelected,
  ) async {
    final slotId = slot['id'].toString();

    if (isCurrentlySelected) {
      setState(() => _deselect(slotId));
      _refreshQuote();
      return;
    }

    if (_selected.length >= _maxSelectionSlots) {
      _snack('You can book at most $_maxSelectionSlots slots at a time. '
          'Remove one to pick another.');
      return;
    }

    // Optimistic selection: the tap registers instantly and Book Now lights up at
    // once, the way a real booking app feels. The 5-minute checkout hold is taken
    // in the background rather than awaited — the hold is only a courtesy so two
    // players don't fill the same form, and the booking itself re-checks every
    // slot under a row lock, so a selection that loses a hold still fails safely
    // at confirm time rather than letting the player pay twice.
    setState(() {
      _selected.add(slot);
      _sortSelection();
    });
    _acquireHoldInBackground(slotId);
    _refreshQuote();
  }

  /// Takes the checkout hold without blocking the tap. A slot is dropped from the
  /// selection only when the server says it is *definitively* taken by someone else
  /// (409); a transient failure (network, 5xx) leaves the selection untouched. The
  /// hold is only a courtesy so two players do not fill the same form, and
  /// createBooking re-checks every slot under a row lock, so a blip must never
  /// silently deselect what the player just tapped — which is what made rapid
  /// tapping drop slots.
  Future<void> _acquireHoldInBackground(String slotId) async {
    final r = await _lockSlot(slotId);
    if (!mounted || r.ok || !r.taken) return;
    if (_selected.any((s) => s['id'].toString() == slotId)) {
      setState(() => _deselect(slotId));
      _snack(r.message ?? 'That slot was just taken by another player.');
      _refreshQuote();
      _load();
    }
  }

  /// Prices the current run on the server, or clears the quote when there is
  /// nothing multi-slot to price.
  ///
  /// The quote is advisory: it takes no locks, and the booking re-reads every slot
  /// before any money moves. What it buys is that the discount the player is shown
  /// is the owner's real ladder applied by the same code the booking will use.
  Future<void> _refreshQuote() async {
    final token = _token;
    final ids = _selectedIds;
    final venueId = widget.venueId;
    _quoteToken += 1;
    final token_ = _quoteToken;

    if (ids.length < 2 || token == null) {
      if (_groupQuote != null || _quoteLoading) {
        setState(() {
          _groupQuote = null;
          _quoteLoading = false;
        });
      }
      return;
    }

    setState(() => _quoteLoading = true);
    try {
      final resp = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/bookings/group/quote'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'venueId': venueId, 'slotIds': ids}),
      );
      final data = jsonDecode(resp.body);
      // A reply for a selection the player has since changed is discarded rather
      // than painted over the current one.
      if (!mounted || token_ != _quoteToken) return;
      setState(() {
        _quoteLoading = false;
        _groupQuote = data['success'] == true
            ? Map<String, dynamic>.from(data['data'] as Map)
            : null;
      });
    } catch (_) {
      if (!mounted || token_ != _quoteToken) return;
      // The bottom bar falls back to the sum of the slots' own prices, which is
      // the undiscounted truth rather than an invented discount.
      setState(() {
        _quoteLoading = false;
        _groupQuote = null;
      });
    }
  }

  /// Holds the slot for 5 minutes. `ok` is true on success; otherwise `taken` is
  /// true only for a 409 (another player definitively holds or just booked it) and
  /// false for a transient failure (network, 5xx), which the caller tolerates.
  Future<({bool ok, bool taken, String? message})> _lockSlot(String slotId) async {
    try {
      final resp = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/slots/$slotId/lock'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      final data = jsonDecode(resp.body);
      if (data['success'] == true) return (ok: true, taken: false, message: null);
      return (
        ok: false,
        taken: resp.statusCode == 409,
        message: (data['message'] ?? 'Could not hold this slot').toString(),
      );
    } catch (_) {
      return (ok: false, taken: false, message: 'Network error. Please try again.');
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
          //
          // The rating and photo-count badges used to sit ON the image, at top:90
          // inside the same Stack as a gradient that covers the lower 70% and a
          // venue name pinned to the bottom. On a 412-wide phone the three collided:
          // the name block ran up into the badge row and the page dots sat under the
          // gradient's densest band. They are moved BELOW the media container
          // instead, which fixes the overlap without changing what either one means
          // — and leaves the photo band itself uncluttered, which is the point of
          // having a gallery.
          SliverAppBar(
            expandedHeight: 320,
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
                      itemBuilder: (_, i) => Semantics(
                        // Each page announces where it is in the set, so the carousel
                        // is not a silent swipe for a screen reader.
                        label: 'Photo ${i + 1} of ${images.length}',
                        image: true,
                        child: Image.network(
                          images[i],
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, e, st) =>
                              _gradientPlaceholder(sportType),
                        ),
                      ),
                    )
                  else
                    _gradientPlaceholder(sportType),
                  // Gradient overlay at bottom
                  //
                  // Only the lower band is darkened now that the badges have moved
                  // off the image. The old stop at 0.3 threw a near-opaque black over
                  // 70% of every photo to make two small pills legible; with the
                  // photography carrying the page, the gradient's only remaining job
                  // is keeping the venue name readable over a bright pitch.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.55, 1.0],
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.82),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Page indicator dots
                  if (images.length > 1)
                    Positioned(
                      bottom: 76,
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
                  // Venue name at bottom of hero. The rating and photo-count badges
                  // that used to share this band are rendered below the image by
                  // _galleryMetaRow.
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

          // The rating and photo count, directly under the media container rather
          // than floating on top of it. See the gallery comment above for why.
          SliverToBoxAdapter(child: _galleryMetaRow(images.length)),

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
                    _infoRow(
                      Icons.shield_outlined,
                      'Upfront deposit: ${formatPercent(venueDepositPercent(_venue!))}% '
                      '(late cancellation or no-show)',
                    ),
                    const SizedBox(height: 8),
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

          // About-this-venue content (amenities, reviews) sits BELOW the booking
          // flow now, so the slot grid is the first thing under the summary. Those
          // two slivers are added after the grid, lower in this list.

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
                            // Switching dates keeps the selection. Holds are
                            // per-slot, not per-date, so the ones already taken
                            // remain valid; and a late-night venue's 23:00 and
                            // 00:00 hours sit on consecutive dates, so clearing
                            // here would make that back-to-back pair unbookable.
                            setState(() {
                              _selectedDate = date;
                              _sortSelection();
                            });
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
                  // The tap rule, stated once. A player who does not read it loses
                  // nothing: a single tap still books one slot exactly as before.
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.touch_app_outlined,
                          size: 12, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Select up to 4 slots — back-to-back hours book together, '
                          'hours with a gap become separate bookings',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // The owner's multi-slot ladder, composed by the server
                  // (discountService.describeTiers) so the app and Scout cannot
                  // describe the same ladder differently. Absent when the venue has
                  // no ladder, which renders as nothing at all.
                  if (_discountSummary != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.accentLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.local_offer_outlined,
                              size: 14, color: AppColors.accent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _discountSummary!,
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((_, i) {
                  final slot = _slots[i];
                  // Server-derived: folds a live checkout hold into 'locked'.
                  final status =
                      (slot['effective_status'] ??
                              slot['status'] ??
                              'available')
                          .toString();
                  return _slotCell(slot, status);
                }, childCount: _slots.length),
                // Three across, not two. Two columns at 84px made every cell a wide
                // slab with the time floating in the middle of it, which read as a
                // card rather than a time picker and pushed the grid two screens
                // down. Three at 76px keeps a full 48px minimum tap height once the
                // row padding is taken out, and fits a day's evening in one glance.
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  mainAxisExtent: 76,
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

          // About-this-venue content, now BELOW the booking flow so the slot grid
          // is the first thing under the summary. Amenities collapse to save
          // vertical space; reviews are a compact snippet linking to the full list.
          SliverToBoxAdapter(child: _amenitiesCard()),
          SliverToBoxAdapter(child: _reviewsSummary()),
          // Clears the floating booking bar at the end of the scroll.
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
        ],
      ),
    );
  }

  /// The rating and the photo position, on their own row under the gallery.
  ///
  /// Both used to be pills stacked on the hero image, where a gradient overlay and
  /// the venue name competed with them for the same 280 pixels. Moving them here
  /// costs a 44-pixel strip of the page and buys a photo that is not covered, a
  /// count that cannot collide with the title, and a rating that sits next to the
  /// price rather than on top of the venue a player is deciding about.
  ///
  /// The row always renders, even with one photo and no reviews, so the layout does
  /// not shift between venues — an unrated ground shows "New" where a rated one
  /// shows its score, which is a fact about the venue rather than an empty slot.
  Widget _galleryMetaRow(int imageCount) {
    final rating = asNum(_venue!['rating']);
    final reviews = asNum(_venue!['total_reviews']).toInt();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          const Icon(Icons.star_rounded, color: Colors.amber, size: 18),
          const SizedBox(width: 5),
          Text(
            reviews == 0 ? 'New' : rating.toStringAsFixed(1),
            style: GoogleFonts.poppins(
              fontSize: 13.5,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          if (reviews > 0) ...[
            const SizedBox(width: 3),
            Text(
              '($reviews ${reviews == 1 ? 'review' : 'reviews'})',
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          const Spacer(),
          if (imageCount > 1) ...[
            const Icon(Icons.photo_library_outlined,
                size: 15, color: AppColors.textSecondary),
            const SizedBox(width: 5),
            Text(
              '${_galleryPage + 1} of $imageCount',
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One slot cell, in one of four visible states that differ by SHAPE and not
  /// only by colour, so the grid is legible to a player who cannot separate the
  /// SRS green/amber/red/blue by hue:
  ///
  ///   - available  — white fill, hairline border, centred time over its price;
  ///   - selected   — the dark-green gradient with a check mark, so a chosen slot
  ///                  reads at a glance and survives a colour-blind test;
  ///   - held       — blue tint; a hold this player owns stays tappable and says
  ///                  "YOURS", one held by someone else is struck through;
  ///   - booked /   — flat grey fill, the time struck through and the state spelled
  ///     blocked      out in words, with no price (there is nothing to buy).
  ///
  /// The time is centred rather than left-aligned (the old 3-across cell left it
  /// hard against the edge), and the price sits on its own line beneath it rather
  /// than sharing a slot with the state label.
  /// The slot id currently under the finger, so a cell can react on touch-down
  /// rather than only on release. A grid whose cells give no tactile response
  /// reads as inert, and the player taps twice.
  String? _pressedSlotId;

  Widget _slotCell(Map<String, dynamic> slot, String status) {
    final selectable = _isSelectable(slot);
    final selected = _isSelected(slot);
    final mineHold = slot['locked_by_me'] == true;
    final time12 = _to12Hour(slot['start_time']);
    final slotPrice = asNum(slot['price']);
    final statusColor = _slotStatusColor(status);
    final relisted = _isRelisted(slot);
    final slotId = slot['id'].toString();
    final pressed = _pressedSlotId == slotId && (selectable || selected);

    // Selection is the one state the player must never have to look for, so it is
    // a solid dark-green fill with white text — the same fill the primary action
    // buttons use. The previous gradient over a transparent fill read as "slightly
    // tinted" next to a white cell, which is why a selected slot was hard to tell
    // from an unselected one at a glance.
    final Color fill;
    final Color borderColor;
    final double borderWidth;
    if (selected) {
      fill = AppColors.primary;
      borderColor = AppColors.primary;
      borderWidth = 2;
    } else if (selectable) {
      // A faint green tint rather than pure white marks the tappable cells as a
      // group, so "what can I press" is answerable without reading the legend.
      fill = AppColors.accentLight.withValues(alpha: 0.45);
      borderColor = AppColors.accent.withValues(alpha: 0.35);
      borderWidth = 1.2;
    } else {
      fill = statusColor.withValues(alpha: 0.08);
      borderColor = statusColor.withValues(alpha: 0.35);
      borderWidth = 1;
    }

    // The second line: a price when there is something to buy, the state in words
    // otherwise. "YOURS" for the player's own hold, which is still bookable.
    final Widget secondLine = selectable
        ? Text(
            'PKR ${slotPrice.toStringAsFixed(0)}',
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : AppColors.primary,
            ),
          )
        : Text(
            mineHold ? 'YOURS' : _slotStatusLabel(status),
            style: GoogleFonts.poppins(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: statusColor,
            ),
          );

    return Semantics(
      button: selectable || selected,
      label: selectable || selected
          ? '$time12, PKR ${slotPrice.toStringAsFixed(0)}${selected ? ', selected' : ''}'
          : '$time12, ${mineHold ? 'held by you' : _slotStatusLabel(status).toLowerCase()}',
      child: GestureDetector(
        onTapDown: (selectable || selected)
            ? (_) => setState(() => _pressedSlotId = slotId)
            : null,
        onTapCancel: () => setState(() => _pressedSlotId = null),
        onTap: (selectable || selected)
            ? () {
                setState(() => _pressedSlotId = null);
                _onSlotTap(slot, selected);
              }
            : null,
        child: AnimatedScale(
          scale: pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 90),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: borderWidth),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
            clipBehavior: Clip.none,
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (selected) ...[
                          const Icon(Icons.check_circle,
                              size: 12, color: Colors.white),
                          const SizedBox(width: 3),
                        ],
                        Flexible(
                          child: Text(
                            time12,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              color: selected
                                  ? Colors.white
                                  : selectable
                                      ? AppColors.textPrimary
                                      : statusColor,
                              decoration: (!selectable && !mineHold)
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    secondLine,
                  ],
                ),
              ),
              // Item 8: a slot freed by a near-kickoff cancellation wears a small
              // accent tag so a browsing player spots it before it is gone again.
              if (relisted && !selected)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'NEW',
                      style: GoogleFonts.poppins(
                        fontSize: 7,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          ),
        ),
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

  /// Amenities as a collapsible card so the list does not push the rest of the page
  /// down; it starts collapsed with the count in the header. Renders nothing when
  /// the venue lists no amenities.
  Widget _amenitiesCard() {
    final entries = _amenities.entries.toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
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
        child: Theme(
          // ExpansionTile draws divider lines above and below when open; clearing
          // them keeps the tile reading as one card.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
            childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFE0E7FF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.checklist_rounded,
                  color: Color(0xFF6366F1), size: 20),
            ),
            title: Text(
              'Amenities & Facilities',
              style: GoogleFonts.poppins(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            subtitle: Text(
              '${entries.length} listed',
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                color: AppColors.textSecondary,
              ),
            ),
            children: entries.map((e) {
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
                        displayKey.isEmpty
                            ? key
                            : displayKey[0].toUpperCase() +
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
                            ? (val ? AppColors.accent : AppColors.error)
                            : AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  /// A compact reviews snippet: the average with its star, one top review, and a
  /// link to the full paginated screen. The histogram and the AI-sentiment split
  /// moved to that screen, so this card stays short beneath the booking flow.
  Widget _reviewsSummary() {
    final r = _reviews;
    final avg = r.avgStars;
    final top = r.reviews.isNotEmpty ? r.reviews.first : null;

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
            // Header: title on the left, the average score on the right.
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.reviews_outlined,
                      color: AppColors.accent, size: 20),
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
                if (r.total > 0) ...[
                  const Icon(Icons.star_rounded, size: 18, color: Colors.amber),
                  const SizedBox(width: 2),
                  Text(
                    avg == null ? '—' : avg.toStringAsFixed(1),
                    style: GoogleFonts.poppins(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    ' (${r.total})',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),

            if (r.total == 0) ...[
              const SizedBox(height: 14),
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
              if (top != null) ...[
                const Divider(color: AppColors.border, height: 24),
                ReviewCard(review: top),
              ] else
                const SizedBox(height: 14),
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

  /// The venue's discount ladder as the server phrased it, or null when it has
  /// none. Read off the venue payload rather than fetched separately.
  String? get _discountSummary {
    final raw = _venue == null ? null : _venue!['discount_summary'];
    final s = raw?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// What the run costs at the slots' own prices, with no discount applied.
  double get _listTotal =>
      _selected.fold<double>(0, (sum, s) => sum + asNum(s['price']));

  /// What the player will pay: the server's quote when there is one, the list
  /// total otherwise. Never a discount computed here — the ladder belongs to the
  /// server, and a local copy would be a number the booking contradicts.
  double get _payableTotal {
    final q = _groupQuote;
    if (q != null && q['total'] != null) return asNum(q['total']);
    return _listTotal;
  }

  double get _quotedSaving => _groupQuote == null ? 0 : asNum(_groupQuote!['saved']);

  /// The discount percentage to name, or 0 when naming one would be untrue.
  ///
  /// A selection of several runs is quoted per run against the owner's ladder, so
  /// two runs can carry different percentages. Printing one of them over a total
  /// that mixes both would misstate the saving, so only a single-run selection
  /// names a percentage; a multi-run one states the amount saved instead.
  double get _quotedPercent {
    final q = _groupQuote;
    if (q == null) return 0;
    final runs = q['runs'];
    if (runs is! List || runs.length != 1) return 0;
    final only = runs.first;
    return only is Map ? asNum(only['discountPercent']) : 0;
  }

  Widget _bottomBar() {
    final count = _selected.length;
    final hasSelection = count > 0;
    final runs = _runsInSelection;
    final runCount = runs.length;
    // What the selection amounts to, in terms of what the player will actually
    // receive. One run is one booking and one QR; several runs are several of each,
    // because they are separate visits to the ground. The bar says so before the
    // player taps, rather than the success screen revealing two QR codes.
    final String? detail;
    if (!hasSelection) {
      detail = null;
    } else if (runCount == 1) {
      final only = runs.first;
      final span = '${_to12Hour(only.first['start_time'])} – '
          '${_to12Hour(only.last['end_time'])}';
      detail = count > 1 ? '$span  ·  $count slots' : span;
    } else {
      detail = '$count slots  ·  $runCount separate bookings';
    }

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The saving line, above the total and only when the server actually
            // quoted one. A Clear affordance rides with it, because a run of slots
            // is more work to undo one tap at a time.
            if (count > 1) ...[
              Row(
                children: [
                  if (_quotedPercent > 0) ...[
                    const Icon(Icons.local_offer_outlined,
                        size: 13, color: AppColors.accent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${_quotedPercent.toStringAsFixed(0)}% off — you save '
                        'PKR ${_quotedSaving.toStringAsFixed(0)}',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                  ] else
                    Expanded(
                      child: Text(
                        _quoteLoading
                            ? 'Checking your total…'
                            : (runCount > 1
                                ? '$runCount bookings will be created'
                                : '$count slots selected'),
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  TextButton(
                    onPressed: () {
                      setState(_clearSelection);
                      _refreshQuote();
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      'Clear',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
            ],
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
                      hasSelection
                          ? 'PKR ${_payableTotal.toStringAsFixed(0)}'
                          : 'Select a slot',
                      style: GoogleFonts.poppins(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: hasSelection
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    if (detail != null)
                      Text(
                        detail,
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: !hasSelection ? null : _goToConfirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      disabledBackgroundColor: AppColors.disabled,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: hasSelection ? 4 : 0,
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
    if (_selected.isEmpty || _venue == null) return;
    // Hold the refresh while checkout is on top — nothing there reacts to a
    // repaint, and a snackbar would land over the confirm screen.
    _refreshTimer?.cancel();
    final booked = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConfirmBookingScreen(
          venue: _venue!,
          // `slot` stays the first of the run so the single-slot path is untouched;
          // `slots` carries the whole run and is what makes it a group.
          slot: _selected.first,
          slots: List<Map<String, dynamic>>.of(_selected),
          selectedDate: _selectedDate,
        ),
      ),
    );
    if (!mounted) return;
    if (booked == true) {
      // The booking completed. Those slots are now ours and booked, so drop the
      // selection without the reclaim path's "taken by another player" notice —
      // which would otherwise fire over the success screen when the refresh below
      // re-reads the grid and finds our own just-booked slot gone. Holds are already
      // released server-side at booking, so this does not call release again.
      setState(() => _clearSelection(releaseHolds: false));
    }
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
