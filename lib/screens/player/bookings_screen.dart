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

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _hydrateThenLoad();
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

  /// Draw the last good rows before the network is consulted.
  ///
  /// The fetch still runs either way: a cache hit changes what the user waits in
  /// front of, not whether the list is refreshed. This is the whole behavioural
  /// change — the tab opens populated, offline or on a cold start, instead of
  /// showing a spinner and then claiming the account has no bookings.
  Future<void> _hydrateThenLoad() async {
    final cached = await OfflineCache.read(OfflineCache.myBookings);
    if (cached != null && mounted) {
      final rows = cached.asRows();
      if (rows.isNotEmpty) {
        setState(() {
          _applyRows(rows);
          _cachedAt = cached.at;
          _loading = false;
        });
      }
    }
    await _load();
  }

  /// Partition the server's rows across the two tabs.
  ///
  /// Plain field assignment with no setState of its own, so the same partition
  /// serves both sources — the cache on hydrate and the response on load — and the
  /// two can never drift into disagreeing about what counts as upcoming.
  void _applyRows(List<Map<String, dynamic>> all) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _upcoming = all.where((b) {
      final d = DateTime.tryParse(b['slot_date'] ?? '')?.toLocal();
      return d != null && !d.isBefore(today)
        && ['confirmed','pending'].contains(b['status']);
    }).toList();
    _past = all.where((b) {
      final d = DateTime.tryParse(b['slot_date'] ?? '')?.toLocal();
      return d == null || d.isBefore(today)
        || ['cancelled','rejected','no_show','checked_in','completed','refunded'].contains(b['status']);
    }).toList();
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

  Future<void> _cancel(String bookingId) async {
    // Refused up front rather than queued. A cancellation moves money through
    // escrow and its refund split depends on how far the slot is away at the
    // moment it lands, so holding one until the network returns would compute a
    // different refund than the dialog just promised.
    if (!await OfflineActionNotice.guard(context, 'Cancelling a booking')) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Cancel Booking?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
      content: Text('You will receive a full refund to your wallet.',
        style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: Text('Keep', style: GoogleFonts.poppins(color: AppColors.textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, true),
          child: Text('Cancel Booking',
            style: GoogleFonts.poppins(color: AppColors.error, fontWeight: FontWeight.w600))),
      ],
    ));
    if (ok != true) return;
    if (!mounted) return;
    final res = await ApiClient().patch('/bookings/$bookingId/cancel', const {});
    if (!mounted) return;
    if (res['success'] == true) {
      SnackbarUtil.showSuccess(context, 'Booking cancelled. Refund added to wallet.');
      _load();
    } else {
      // Previously an empty catch: a cancellation that failed told the user
      // nothing at all, and the booking simply stayed where it was.
      SnackbarUtil.showError(
          context, res['message'] as String? ?? 'Could not cancel the booking.');
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
            Expanded(child: _infoItem(Icons.access_time_outlined,
              '${_safeTime(b['start_time'])} – ${_safeTime(b['end_time'])}')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _infoItem(Icons.location_on_outlined, b['city'] ?? '')),
            const SizedBox(width: 8),
            Expanded(child: _infoItem(Icons.currency_rupee,
              'PKR ${asNum(b['total_amount']).toStringAsFixed(0)}')),
          ]),
          if (upcoming && status == 'confirmed') ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => _cancel(b['id']),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(vertical: 10)),
                child: Text('Cancel', style: GoogleFonts.poppins(
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
