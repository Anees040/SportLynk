import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/stable_refresh_indicator.dart';

enum AdminOverviewData {
  players(
    'Total Players',
    '/admin/users',
    'user_management',
    'All registered player accounts.',
    Icons.people_outline,
  ),
  venues(
    'Active Venues',
    '/admin/venues/active',
    'owner_approvals',
    'Venues currently active on SportLynk.',
    Icons.stadium_outlined,
  ),
  bookings(
    'Active Bookings',
    '/admin/bookings/active',
    'booking_disputes',
    'Pending, confirmed and checked-in bookings.',
    Icons.calendar_today_outlined,
  );

  const AdminOverviewData(
    this.title,
    this.endpoint,
    this.permission,
    this.description,
    this.icon,
  );
  final String title;
  final String endpoint;
  final String permission;
  final String description;
  final IconData icon;
}

/// Read-only records behind a dashboard count, fetched only when opened.
class AdminOverviewDataScreen extends StatefulWidget {
  const AdminOverviewDataScreen({super.key, required this.data});
  final AdminOverviewData data;

  @override
  State<AdminOverviewDataScreen> createState() =>
      _AdminOverviewDataScreenState();
}

class _AdminOverviewDataScreenState extends State<AdminOverviewDataScreen> {
  final _items = <Map<String, dynamic>>[];
  bool _loading = false;
  String? _error;
  String? _cursor;
  bool _retryMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_loading) return;
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null ||
        (!user.isSuperAdmin &&
            !user.permissions.contains(widget.data.permission))) {
      setState(
        () => _error = 'You do not have permission to view these records.',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await ApiClient().get(
      widget.data.endpoint,
      token: auth.token,
      queryParams: {
        'limit': '25',
        if (widget.data == AdminOverviewData.players) ...{
          'role': 'player',
          'status': 'all',
        },
        if (more && _cursor != null) 'cursor': _cursor!,
      },
    );
    if (!mounted) return;
    final data = result['data'];
    setState(() {
      _loading = false;
      if (result['success'] != true || data is! Map || data['items'] is! List) {
        _retryMore = more;
        _error =
            result['message']?.toString() ?? 'Could not load these records.';
        return;
      }
      if (!more) _items.clear();
      final known = _items.map((item) => item['id']).toSet();
      _items.addAll(
        (data['items'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where((item) => known.add(item['id'])),
      );
      _cursor = data['nextCursor']?.toString();
      if (_cursor?.isEmpty ?? false) _cursor = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: FittedBox(fit: BoxFit.scaleDown, child: Text(widget.data.title)),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: _loading ? null : () => _load(),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _items.isEmpty
              ? NetworkErrorView(message: _error!, onRetry: () => _load())
              : StableRefreshIndicator(
                  onRefresh: () => _load(),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: _items.length + 2,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            widget.data.description,
                            style: GoogleFonts.poppins(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        );
                      }
                      if (index <= _items.length) {
                        return _record(_items[index - 1]);
                      }
                      return Column(
                        children: [
                          if (_items.isEmpty) ...[
                            const SizedBox(height: 48),
                            Icon(
                              widget.data.icon,
                              size: 48,
                              color: AppColors.disabled,
                            ),
                            const SizedBox(height: 12),
                            const Text('No records to show.'),
                          ],
                          if (_error != null) ...[
                            Text(_error!, textAlign: TextAlign.center),
                            TextButton(
                              onPressed: () => _load(more: _retryMore),
                              child: const Text('Retry'),
                            ),
                          ] else if (_loading)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(),
                            )
                          else if (_cursor != null)
                            OutlinedButton(
                              onPressed: () => _load(more: true),
                              child: const Text('Load more'),
                            ),
                        ],
                      );
                    },
                  ),
                ),
        ),
      ),
    ),
  );

  Widget _record(Map<String, dynamic> row) {
    String title;
    final lines = <String>[];
    switch (widget.data) {
      case AdminOverviewData.players:
        title = row['name']?.toString() ?? 'Player';
        lines.addAll([
          if (row['email'] != null) row['email'].toString(),
          if (row['phone'] != null) row['phone'].toString(),
          row['suspended'] == true ? 'Suspended account' : 'Active account',
        ]);
      case AdminOverviewData.venues:
        title = row['name']?.toString() ?? 'Venue';
        lines.addAll([
          'Owner: ${row['owner_name'] ?? 'Unknown'}',
          [
            row['city'],
            row['address'],
          ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
          if (row['sport_type'] != null) row['sport_type'].toString(),
        ]);
      case AdminOverviewData.bookings:
        title = row['venue_name']?.toString() ?? 'Booking';
        final date = DateTime.tryParse(row['slot_date']?.toString() ?? '');
        String time(dynamic value) {
          final text = value?.toString() ?? '';
          return text.length >= 5 ? text.substring(0, 5) : text;
        }
        final amount = num.tryParse('${row['total_amount']}');
        lines.addAll([
          'Player: ${row['player_name'] ?? 'Unknown'}',
          if (date != null) DateFormat('d MMM yyyy').format(date),
          '${time(row['start_time'])} – ${time(row['end_time'])}',
          'Status: ${row['status']?.toString().replaceAll('_', ' ') ?? 'Unknown'}',
          if (amount != null) 'PKR ${NumberFormat('#,##0.##').format(amount)}',
        ]);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (final line in lines.where((line) => line.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
