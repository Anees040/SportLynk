import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/connectivity_provider.dart';
import '../../services/api_service.dart';
import '../../services/offline_cache.dart';
import '../../utils/num_util.dart';
import '../../utils/reconnect_refresh.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/offline_banner.dart';

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});
  @override
  State<BookingsScreen> createState() => BookingsScreenState();
}

class BookingsScreenState extends State<BookingsScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin, WidgetsBindingObserver, ReconnectRefresh<BookingsScreen> {
  late TabController _tab;
  List<Map<String, dynamic>> _upcoming = [], _past = [];
  bool _loading = true;
  DateTime? _lastLoadTime;

  /// When the rows on screen were fetched, when they came from the cache rather
  /// than from this session's network call. Drives the banner's "saved 10 min ago"
  /// so a cached booking is never mistaken for a current one.
  DateTime? _cachedAt;

  /// The failure sentence for a load that had nothing cached to fall back on.
  ///
  /// Only this case earns a full error view. With a cache present the rows stay on
  /// screen under the offline strip, which is the whole point of the change: a
  /// first-ever load with no connection has nothing to show, every later one does.
  String? _error;

  /// Set once a fetch has returned real rows.
  ///
  /// Guards the cache hydration against a race it would otherwise lose silently:
  /// the two run concurrently, and a slow disk read landing after a fast response
  /// would replace this session's bookings with saved ones and re-label them
  /// stale.
  bool _networkAnswered = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    // Both started together, deliberately NOT chained. Reading the cache is disk
    // I/O, and awaiting it before the request would delay every online load by
    // however long shared_preferences takes to answer — paying an offline cost on
    // a connection that is fine. Whichever resolves first paints; [_hydrateFromCache]
    // stands down if the network already answered.
    _load();
    _hydrateFromCache();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tab.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshIfStale();
  }

  // Reconnecting after a drop is the same trigger as resuming: pull anything the
  // list missed while offline, throttled by the same staleness guard so a resume
  // and a reconnect firing together do not double-load.
  @override
  void onReconnect() => _refreshIfStale();

  /// Called by parent (PlayerHomeScreen) when Bookings tab becomes active
  void refreshIfNeeded() => _refreshIfStale();

  /// Reload unconditionally, ignoring the 5-second staleness guard.
  ///
  /// Used when something outside this screen is known to have changed the rows —
  /// a booking made or cancelled through the assistant. `refreshIfNeeded` would be
  /// free to skip that, and a booking the user just paid for missing from the list
  /// is not a cache miss, it is the app calling them a liar.
  Future<void> reloadNow() => _load();

  void _refreshIfStale() {
    final now = DateTime.now();
    if (_lastLoadTime == null || now.difference(_lastLoadTime!).inSeconds > 5) {
      _load();
    }
  }

  /// Draw the last good rows if they arrive before the network does.
  ///
  /// The whole behavioural change is here — the tab opens populated, offline or on
  /// a cold start, instead of showing a spinner and then claiming the account has
  /// no bookings. It runs alongside the fetch rather than before it, so a cache
  /// that resolves second is discarded rather than overwriting fresher rows.
  Future<void> _hydrateFromCache() async {
    final cached = await OfflineCache.read(OfflineCache.myBookings);
    if (!mounted || cached == null || _networkAnswered) return;
    final rows = cached.asRows();
    if (rows.isEmpty) return;
    setState(() {
      _applyRows(rows);
      _cachedAt = cached.at;
      _loading = false;
    });
  }

  /// Partition the server's rows across the two tabs.
  ///
  /// Plain field assignment with no setState of its own, so the same partition
  /// serves both sources — the cache on hydrate and the response on load — and the
  /// two can never drift into disagreeing about what counts as upcoming.
  void _applyRows(List<Map<String, dynamic>> all) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _upcoming = _collapseGroups(all.where((b) {
      final d = DateTime.tryParse(b['slot_date'] ?? '')?.toLocal();
      return d != null && !d.isBefore(today)
        && ['confirmed','pending'].contains(b['status']);
    }).toList());
    _past = _collapseGroups(all.where((b) {
      final d = DateTime.tryParse(b['slot_date'] ?? '')?.toLocal();
      return d == null || d.isBefore(today)
        || ['cancelled','rejected','no_show','checked_in','completed','refunded'].contains(b['status']);
    }).toList());
  }

  /// A TIME value as 'HH:MM:SS', so two of them can be compared as strings.
  String _timeKey(dynamic raw) {
    final s = raw == null ? '' : raw.toString().trim();
    final m = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(s);
    if (m == null) return s;
    return '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}:${m.group(3) ?? '00'}';
  }

  /// Fold the bookings that were made together into one row each.
  ///
  /// A multi-slot booking is N rows sharing a `booking_group_id` — each with its
  /// own escrow, refund window and QR code — because that is what leaves the money
  /// paths untouched. The player asked for two hours of play, though, so the list
  /// shows one card.
  ///
  /// Grouped by id AND status, deliberately. Once one hour of a run is cancelled
  /// the remaining hours are a different thing from the cancelled one, and a single
  /// card would have to invent a combined status to describe them. Splitting by
  /// status instead means every card has a status that is simply true.
  ///
  /// Rows carrying no group id — every booking made before migration 035, and every
  /// single-slot booking after it — pass through untouched.
  List<Map<String, dynamic>> _collapseGroups(List<Map<String, dynamic>> rows) {
    final order = <String>[];
    final buckets = <String, List<Map<String, dynamic>>>{};

    for (final b in rows) {
      final gid = b['booking_group_id']?.toString();
      final key = (gid == null || gid.isEmpty)
          ? 'single:${b['id']}'
          : 'group:$gid:${b['status']}';
      final bucket = buckets[key];
      if (bucket == null) {
        buckets[key] = [b];
        order.add(key);
      } else {
        bucket.add(b);
      }
    }

    final out = <Map<String, dynamic>>[];
    for (final key in order) {
      final members = buckets[key]!;
      if (members.length == 1) {
        out.add(members.first);
        continue;
      }
      members.sort((a, b) {
        final byDate = (a['slot_date'] ?? '').toString()
            .compareTo((b['slot_date'] ?? '').toString());
        return byDate != 0
            ? byDate
            : _timeKey(a['start_time']).compareTo(_timeKey(b['start_time']));
      });

      // Whether what is left of the run is still back to back. It may not be: one
      // hour out of the middle can be cancelled on its own, and printing
      // "18:00 – 21:00 · 2 slots" for 18:00 and 20:00 would claim an hour the
      // player no longer has.
      var contiguous = true;
      for (var i = 1; i < members.length; i += 1) {
        final prevEnd = _timeKey(members[i - 1]['end_time']);
        final nextStart = _timeKey(members[i]['start_time']);
        final sameDay = (members[i - 1]['slot_date'] ?? '').toString()
            == (members[i]['slot_date'] ?? '').toString();
        final seam = !sameDay && prevEnd == '24:00:00' && nextStart == '00:00:00';
        if (!(sameDay && prevEnd == nextStart) && !seam) {
          contiguous = false;
          break;
        }
      }

      out.add({
        // The first member carries the card: its id is what a tap opens, and its
        // `booking_group_id` is what lets the detail screen show the whole run.
        ...members.first,
        'total_amount': members.fold<double>(0, (s, m) => s + asNum(m['total_amount'])),
        '_groupCount': members.length,
        '_groupContiguous': contiguous,
        '_groupEnd': members.last['end_time'],
        '_groupStarts': members.map((m) => m['start_time']).toList(),
        '_groupIds': members.map((m) => m['id'].toString()).toList(),
      });
    }
    return out;
  }

  Future<void> _load() async {
    // The spinner is only for a screen with nothing to show. With cached rows
    // already drawn, a refresh happens underneath them — replacing a populated
    // list with a spinner on every resume is the flicker this avoids.
    final hadRows = _upcoming.isNotEmpty || _past.isNotEmpty;
    if (!hadRows && mounted) setState(() => _loading = true);
    _lastLoadTime = DateTime.now();

    final res = await ApiClient().get(ApiConstants.myBookings);
    if (!mounted) return;

    if (res['success'] == true) {
      final raw = res['data'];
      final rows = raw is List
          ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
          : <Map<String, dynamic>>[];
      _networkAnswered = true;
      setState(() {
        _applyRows(rows);
        _cachedAt = null;   // on screen is now this session's data, not a saved copy
        _error = null;
        _loading = false;
      });
      context.read<ConnectivityProvider>().markReachable();
      await OfflineCache.write(OfflineCache.myBookings, rows);
      return;
    }

    // `statusCode == 0` is ApiClient's transport failure — no answer reached us, so
    // this is the offline case and the rows on screen stay where they are. Any real
    // status means the server replied, which is a fault worth a sentence rather
    // than a connection the user might go and re-check.
    if (res['statusCode'] == 0) {
      context.read<ConnectivityProvider>().markUnreachable();
    }
    setState(() {
      _loading = false;
      // An error view only when there is genuinely nothing to look at. Otherwise
      // the cached list stays and the offline strip carries the explanation.
      _error = hadRows
          ? null
          : (res['message'] as String? ?? 'Could not load your bookings.');
    });
  }

  Future<void> _cancel(List<String> bookingIds) async {
    // Refused up front rather than queued. A cancellation moves money through
    // escrow and its refund split depends on how far the slot is away at the
    // moment it lands, so holding one until the network returns would compute a
    // different refund than the dialog just promised.
    if (!await OfflineActionNotice.guard(context, 'Cancelling a booking')) return;
    if (!mounted) return;
    if (bookingIds.isEmpty) return;
    final many = bookingIds.length > 1;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(many ? 'Cancel ${bookingIds.length} slots?' : 'Cancel Booking?',
        style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      // Previously this promised "a full refund" unconditionally, which is only
      // true at least 24 hours before the slot: inside that window the policy
      // keeps 20% for the venue. The amount is stated by the server once the
      // cancellation has actually been performed.
      content: Text(
        many
            ? 'All ${bookingIds.length} slots will be cancelled. Each one is '
              'refunded by its own cancellation window — at least 24 hours before '
              'the slot is a full refund; inside that window the venue keeps the '
              '20% deposit.'
            : 'At least 24 hours before the slot this is a full refund. Inside '
              'that window the venue keeps the 20% deposit.',
        style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text('Keep', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),
          child: Text(many ? 'Cancel all' : 'Cancel Booking',
            style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600))),
      ],
    ));
    if (ok != true) return;
    if (!mounted) return;

    // One request per booking, because that is what the server offers and each
    // slot's refund is genuinely its own calculation. A failure part-way is
    // reported with the count that did go through rather than hidden behind the
    // last error — a player whose two of three slots were cancelled needs to know
    // which state they are in.
    var cancelled = 0;
    var refunded = 0.0;
    String? failure;
    for (final id in bookingIds) {
      final res = await ApiClient().patch('/bookings/$id/cancel', const {});
      if (res['success'] == true) {
        cancelled += 1;
        final data = res['data'];
        if (data is Map && data['refund'] != null) refunded += asNum(data['refund']);
      } else {
        failure = res['message'] as String? ?? 'Could not cancel the booking.';
        break;
      }
    }
    if (!mounted) return;

    if (failure == null) {
      SnackbarUtil.showSuccess(
        context,
        many
            ? '$cancelled slots cancelled. PKR ${refunded.toStringAsFixed(0)} refunded to your wallet.'
            : 'Booking cancelled. PKR ${refunded.toStringAsFixed(0)} refunded to your wallet.',
      );
    } else if (cancelled > 0) {
      SnackbarUtil.showError(
        context,
        '$cancelled of ${bookingIds.length} slots cancelled. $failure',
      );
    } else {
      // Previously an empty catch: a cancellation that failed told the user
      // nothing at all, and the booking simply stayed where it was.
      SnackbarUtil.showError(context, failure);
    }
    // Refetch only when something actually changed. A cancel that was wholly
    // refused (nothing cancelled) leaves the list exactly as it is, and a refetch
    // there would read as the action having worked.
    if (cancelled > 0) _load();
  }

  /// Cancel a whole multi-slot group in one atomic request.
  ///
  /// The group was booked as one action and is cancelled as one: the server
  /// cancels every still-cancellable slot in a single transaction and refunds each
  /// by its own window, so the player is never left with a half-cancelled booking
  /// to finish slot by slot — the exact complaint the per-slot loop produced. A
  /// single booking still goes through [_cancel].
  Future<void> _cancelGroup(String? groupId, int count) async {
    if (!await OfflineActionNotice.guard(context, 'Cancelling a booking')) return;
    if (!mounted || groupId == null || groupId.isEmpty) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Cancel all $count slots?',
        style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      content: Text(
        'All $count slots in this booking will be cancelled together. Each one is '
        'refunded by its own window — at least 24 hours before the slot is a full '
        'refund; inside that window the venue keeps that slot\'s 20% deposit.',
        style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text('Keep', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),
          child: Text('Cancel all',
            style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600))),
      ],
    ));
    if (ok != true || !mounted) return;
    final res = await ApiClient().patch('/bookings/group/$groupId/cancel', const {});
    if (!mounted) return;
    if (res['success'] == true) {
      final data = res['data'];
      final refunded = data is Map ? asNum(data['refund']) : 0.0;
      SnackbarUtil.showSuccess(context,
        '$count slots cancelled. PKR ${refunded.toStringAsFixed(0)} refunded to your wallet.');
      _load();
    } else {
      SnackbarUtil.showError(context, res['message'] as String? ?? 'Could not cancel the booking.');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('My Bookings', style: GoogleFonts.poppins(
          color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        bottom: TabBar(controller: _tab,
          indicatorColor: AppColors.accent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
          tabs: const [Tab(text: 'Upcoming'), Tab(text: 'Past')]),
      ),
      body: Column(children: [
        // Directly under the app bar, so the explanation sits with the content it
        // applies to rather than floating over it.
        OfflineBanner(cachedAt: _cachedAt),
        Expanded(
          child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
            : _error != null
              ? NetworkErrorView(
                  message: _error!,
                  onRetry: _load,
                  title: 'Could not load bookings',
                )
              : TabBarView(controller: _tab, children: [
                  _buildList(_upcoming, upcoming: true),
                  _buildList(_past, upcoming: false),
                ]),
        ),
      ]),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> items, {required bool upcoming}) {
    // Reached only after a load that actually succeeded and returned nothing, or a
    // cache that held nothing: a failed request now resolves to [_error] and the
    // error view above. Before that split this same empty state was shown for a
    // failure too, which told the user they owned no bookings when the request had
    // simply not completed.
    if (items.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.event_busy, size: 64, color: AppColors.disabled),
        const SizedBox(height: 12),
        Text(upcoming ? 'No upcoming bookings' : 'No past bookings',
          style: GoogleFonts.poppins(fontSize: 15, color: AppColors.textSecondary)),
        if (upcoming) ...[
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => Navigator.pushNamed(context, '/find-venues'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
            child: Text('Find Venues', style: GoogleFonts.poppins(color: Colors.white))),
        ],
      ]));
    }
    return RefreshIndicator(color: AppColors.accent, onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (_, i) => _bookingCard(items[i], upcoming: upcoming),
      ));
  }

  String _fmtSlotDate(String isoStr) {
    final d = DateTime.tryParse(isoStr);
    if (d == null) return isoStr;
    return DateFormat('dd MMM, yyyy').format(d.toLocal());
  }

  String _safeTime(dynamic t) {
    if (t == null) return '—';
    final s = t.toString();
    if (s.length >= 5) return s.substring(0, 5);
    return s;
  }

  Widget _bookingCard(Map<String, dynamic> b, {required bool upcoming}) {
    final status = b['status'] as String;
    final statusColor = _statusColor(status);
    // Present only on a card standing for several bookings made together.
    final groupCount = (b['_groupCount'] as int?) ?? 1;
    final isGroup = groupCount > 1;
    final ids = isGroup
        ? List<String>.from(b['_groupIds'] as List)
        : <String>[b['id'].toString()];

    // A run that is still back to back reads as one stretch of time. One that has
    // been broken up — a middle hour cancelled on its own — lists its start times
    // instead, because a range would claim an hour the player no longer holds.
    final String timeText;
    if (!isGroup) {
      timeText = '${_safeTime(b['start_time'])} – ${_safeTime(b['end_time'])}';
    } else if (b['_groupContiguous'] == true) {
      timeText = '${_safeTime(b['start_time'])} – ${_safeTime(b['_groupEnd'])}';
    } else {
      timeText = (b['_groupStarts'] as List).map(_safeTime).join(', ');
    }

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/booking-detail',
          arguments: {'bookingId': b['id']}),
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03),
          blurRadius: 6, offset: const Offset(0,2))]),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(b['venue_name'] ?? 'Venue',
              style: GoogleFonts.poppins(color: Colors.white,
                fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (isGroup) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6)),
                child: Text('$groupCount SLOTS', style: GoogleFonts.poppins(
                  color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold))),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: statusColor.withValues(alpha: 0.5))),
              child: Text(status.toUpperCase(), style: GoogleFonts.poppins(
                color: statusColor, fontSize: 9, fontWeight: FontWeight.bold))),
          ]),
        ),
        // Body
        Padding(padding: const EdgeInsets.all(14), child: Column(children: [
          Row(children: [
            Expanded(child: _infoItem(Icons.calendar_today_outlined,
              _fmtSlotDate(b['slot_date'] ?? ''))),
            const SizedBox(width: 8),
            Expanded(child: _infoItem(Icons.access_time_outlined, timeText)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _infoItem(Icons.location_on_outlined, b['city'] ?? '')),
            const SizedBox(width: 8),
            Expanded(child: _infoItem(Icons.currency_rupee,
              'PKR ${asNum(b['total_amount']).toStringAsFixed(0)}')),
          ]),
          // Said once, because it is the one thing about a grouped card a player
          // would not otherwise expect: the slots are separate bookings underneath,
          // but they check in as one — a single QR opens and settles the whole run.
          if (isGroup) ...[
            const SizedBox(height: 8),
            _infoItem(Icons.qr_code_2_outlined,
              'One QR — checks in all $groupCount slots'),
          ],
          if (upcoming && status == 'confirmed') ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(
                // A group cancels atomically, in one request, so the player never
                // has to clear slot after slot; a single booking keeps the plain
                // path. Both route through the same refund rules.
                onPressed: () {
                  final gid = b['booking_group_id']?.toString();
                  if (isGroup && gid != null && gid.isNotEmpty) {
                    _cancelGroup(gid, groupCount);
                  } else {
                    _cancel(ids);
                  }
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(vertical: 10)),
                child: Text(isGroup ? 'Cancel all $groupCount' : 'Cancel',
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w600, fontSize: 12)))),
            ]),
          ],
        ])),
      ]),
    ),
    );
  }

  Widget _infoItem(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 14, color: AppColors.textSecondary),
    const SizedBox(width: 4),
    Expanded(child: Text(text, style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
  ]);

  Color _statusColor(String s) => switch(s) {
    'confirmed' => AppColors.accent, 'pending' => AppColors.warning,
    'cancelled' => AppColors.error, 'checked_in' => AppColors.success,
    'rejected' => AppColors.error,
    'no_show' => AppColors.error, _ => AppColors.textSecondary,
  };
}
