import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../widgets/stable_refresh_indicator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../utils/reconnect_refresh.dart';
import '../../utils/slot_time.dart';
import '../../widgets/assistant/scout_bits.dart';
import '../../widgets/network_error_view.dart';
import 'owner_venue_management_screen.dart';

class OwnerSlotCalendarScreen extends StatefulWidget {
  const OwnerSlotCalendarScreen({super.key});
  @override
  State<OwnerSlotCalendarScreen> createState() => _OwnerSlotCalendarScreenState();
}

class _OwnerSlotCalendarScreenState extends State<OwnerSlotCalendarScreen>
    with ReconnectRefresh<OwnerSlotCalendarScreen> {
  DateTime _selectedDate = DateTime.now();
  List<Map<String, dynamic>> _slots = [];
  List<Map<String, dynamic>> _venues = [];
  String? _selectedVenueId;
  bool _loading = false;
  Timer? _clockTimer;
  bool _generating = false;
  bool _generated = false;
  Timer? _generationFeedbackTimer;

  /// The failure sentence for a slot load that could not reach the server.
  ///
  /// Kept distinct from an empty result because the two call for opposite actions:
  /// a date with genuinely no slots invites the owner to generate them, while a
  /// failed load must not — generating over slots that already exist but could not
  /// be read would double-book the grid. "No slots for this date" is now shown only
  /// when the server actually answered with none.
  String? _error;
  static String get _base => ApiConstants.baseUrl;

  @override
  void initState() {
    super.initState();
    _loadVenues();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _generationFeedbackTimer?.cancel();
    super.dispose();
  }

  // The calendar re-reads venues and slots once the socket returns, so a screen
  // opened offline recovers without a manual pull.
  @override
  void onReconnect() => _loadVenues();

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _loadVenues() async {
    if (mounted) setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.get(
        Uri.parse('$_base/owner/venues'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          _venues = List<Map<String, dynamic>>.from(data['data']);
          if (_venues.isNotEmpty) {
            _selectedVenueId = _venues.first['id'].toString();
          }
        }
      }
    } catch (_) {}
    _loadSlots();
  }

  Future<void> _loadSlots() async {
    if (mounted) setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      String url = '$_base/owner/slots?date=${_dateStr(_selectedDate)}';
      if (_selectedVenueId != null) url += '&venueId=$_selectedVenueId';

      final resp = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (data['success'] == true) {
        final raw = data['data'];
        setState(() {
          _slots = raw is List
              ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
              : <Map<String, dynamic>>[];
          _error = null;
          _loading = false;
        });
        context.read<ConnectivityProvider>().markReachable();
      } else {
        // The server answered and refused. Its message is shown rather than an
        // empty grid, so the owner does not read a failure as "regenerate these".
        setState(() {
          _slots = [];
          _loading = false;
          _error = data['message'] as String? ?? 'Could not load the schedule.';
        });
      }
    } catch (_) {
      // Nothing came back. The empty grid would read as "no slots"; the error view
      // reads as what it is, with a retry.
      if (!mounted) return;
      context.read<ConnectivityProvider>().markUnreachable();
      setState(() {
        _slots = [];
        _loading = false;
        _error = 'Could not reach the server. Check your connection and try again.';
      });
    }
  }

  Future<void> _generateSlots() async {
    if (_selectedVenueId == null || _loading || _generating) return;
    _generationFeedbackTimer?.cancel();
    setState(() {
      _generating = true;
      _generated = false;
    });
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(
        Uri.parse('$_base/owner/slots/generate'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'venueId': _selectedVenueId}),
      ).timeout(const Duration(seconds: 30));
      final data = jsonDecode(resp.body);
      if (!mounted) return;
      final success = data['success'] == true;
      setState(() => _generated = success);
      _snack(data['message'] ?? (success ? 'Schedule updated' : 'Could not generate slots'),
          success ? AppColors.accent : AppColors.error);
      if (success) {
        await _loadSlots();
        if (!mounted) return;
        _generationFeedbackTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _generated = false);
        });
      }
    } catch (_) {
      if (mounted) _snack('Could not generate slots. Please try again.', AppColors.error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _toggleBlock(Map<String, dynamic> slot) async {
    final isBlocked = slot['status'] == 'blocked';
    final action = isBlocked ? 'unblock' : 'block';
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.patch(
        Uri.parse('$_base/owner/slots/${slot['id']}/$action'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        if (data['success'] == true) {
          _snack(isBlocked ? 'Slot unblocked' : 'Slot blocked', AppColors.accent);
          _loadSlots();
        } else {
          _snack(data['message'] ?? 'Failed', AppColors.error);
        }
      }
    } catch (_) {
      _snack('Network error', AppColors.error);
    }
  }

  void _snack(String msg, Color c) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg, style: GoogleFonts.poppins(color: Colors.white)),
          backgroundColor: c,
          behavior: SnackBarBehavior.floating,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Schedule', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        automaticallyImplyLeading: false,
        elevation: 0,
        actions: [
          if (_selectedVenueId != null)
            IconButton(
              tooltip: 'Upfront deposit settings',
              icon: const Icon(Icons.shield_outlined, color: Colors.white),
              onPressed: () async {
                final venue = _venues.firstWhere((row) => row['id'].toString() == _selectedVenueId);
                await Navigator.push(context, MaterialPageRoute(
                  builder: (_) => OwnerVenueManagementScreen(venue: venue),
                ));
                if (mounted) _loadVenues();
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _generationButton()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'calendar_fab',
        backgroundColor: AppColors.accent,
        onPressed: _showAddSlotSheet,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: Column(children: [
        if (_venues.isNotEmpty)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.stadium_outlined, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: _venues.length == 1
                      ? Text(_venues[0]['name'] ?? 'Your Venue',
                          style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary))
                      : DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedVenueId,
                            icon: const Icon(Icons.keyboard_arrow_down, color: AppColors.textSecondary),
                            style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedVenueId = val);
                                _loadSlots();
                              }
                            },
                            items: _venues.map((v) {
                              return DropdownMenuItem<String>(
                                value: v['id'].toString(),
                                child: Text(v['name'] ?? 'Unknown Venue'),
                              );
                            }).toList(),
                          ),
                        ),
                ),
              ],
            ),
          ),
        // Calendar widget
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(children: [
            // Month header
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(
                _monthYear(_selectedDate),
                style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              Row(children: [
                _navBtn(Icons.chevron_left, () {
                  setState(() => _selectedDate = DateTime(_selectedDate.year, _selectedDate.month - 1, 1));
                  _loadSlots();
                }),
                const SizedBox(width: 4),
                _navBtn(Icons.chevron_right, () {
                  setState(() => _selectedDate = DateTime(_selectedDate.year, _selectedDate.month + 1, 1));
                  _loadSlots();
                }),
              ]),
            ]),
            const SizedBox(height: 12),
            // Day headers
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'].map((d) => SizedBox(
                    width: 36,
                    child: Center(
                      child: Text(
                        d,
                        style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                      ),
                    ),
                  )).toList(),
            ),
            const SizedBox(height: 8),
            _buildCalendarGrid(),
          ]),
        ),
        const Divider(height: 1, color: AppColors.border),

        // Selected date HEADER
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(
              _fullDate(_selectedDate),
              style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
              child: Text(
                'SELECTED',
                style: GoogleFonts.poppins(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ]),
        ),

        // SLOTS list
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
              : _error != null
                  ? NetworkErrorView(message: _error!, onRetry: _loadSlots)
                  : _slots.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.event_note_outlined, size: 48, color: AppColors.disabled),
                        const SizedBox(height: 12),
                        Text(
                          'No slots for this date',
                          style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 14),
                        ),
                      ]),
                    )
                  : ScrollConfiguration(
                      behavior: stableScrollBehavior(context),
                      child: ListView.builder(
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                      itemCount: _slots.length,
                      itemBuilder: (_, i) => _slotRow(_slots[i]),
                      ),
                    ),
        ),
      ]),
    );
  }

  Widget _generationButton() {
    final enabled = _selectedVenueId != null && !_loading && !_generating;
    final label = _generating ? 'Building...' : _generated ? 'Ready' : 'Auto-fill';
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Tooltip(
      message: 'Generate Slots for 7 Days',
      child: Semantics(
        label: _generating
            ? 'Generating slots for 7 days'
            : _generated ? 'Schedule updated' : 'Auto-fill slots for 7 days',
        liveRegion: true,
        child: TextButton(
          onPressed: enabled ? _generateSlots : null,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white70,
            backgroundColor: Colors.white.withValues(alpha: _generating ? 0.22 : 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(48, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: Duration(milliseconds: reduceMotion ? 0 : 200),
                child: _generated && !_generating
                    ? const Icon(Icons.check_circle_outline, key: ValueKey('ready'), size: 24)
                    : ScoutAvatar(
                        key: const ValueKey('scout'),
                        size: 24,
                        thinking: _generating && !reduceMotion,
                      ),
              ),
              const SizedBox(width: 8),
              Text(label, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCalendarGrid() {
    final firstDay = DateTime(_selectedDate.year, _selectedDate.month, 1);
    final lastDay = DateTime(_selectedDate.year, _selectedDate.month + 1, 0);
    final startOffset = firstDay.weekday - 1;
    final totalCells = startOffset + lastDay.day;
    final rows = (totalCells / 7).ceil();

    return Column(
      children: List.generate(rows, (row) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(7, (col) {
                final dayIdx = row * 7 + col - startOffset + 1;
                if (dayIdx < 1 || dayIdx > lastDay.day) {
                  return const SizedBox(width: 36, height: 36);
                }
                final date = DateTime(_selectedDate.year, _selectedDate.month, dayIdx);
                final isSelected = _dateStr(date) == _dateStr(_selectedDate);
                final isToday = _dateStr(date) == _dateStr(DateTime.now());
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedDate = date);
                    _loadSlots();
                  },
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.accent : Colors.transparent,
                      shape: BoxShape.circle,
                      border: isToday && !isSelected ? Border.all(color: AppColors.accent, width: 1.5) : null,
                    ),
                    child: Center(
                      child: Text(
                        '$dayIdx',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          color: isSelected ? Colors.white : isToday ? AppColors.accent : AppColors.textPrimary,
                          fontWeight: isSelected || isToday ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          )),
    );
  }

  Widget _slotRow(Map<String, dynamic> slot) {
    // `effective_status` is derived server-side: a slot with a live checkout
    // hold on it reads as 'locked' even though its stored status is 'available'.
    final status = (slot['effective_status'] ?? slot['status'] ?? 'available').toString();
    final isAvailable = status == 'available';
    final isBooked = status == 'booked';
    final isBlocked = status == 'blocked';
    final isHeld = status == 'locked';
    final isPast = isSlotPast(slot);

    final Color statusColor;
    final String statusLabel;

    // SRS colour code: Green free · Amber booked · Red blocked · Blue held.
    if (isPast) {
      statusColor = AppColors.disabled;
      statusLabel = 'PAST';
    } else if (isAvailable) {
      statusColor = AppColors.accent;
      statusLabel = 'AVAILABLE';
    } else if (isBooked) {
      statusColor = AppColors.warning;
      statusLabel = 'BOOKED';
    } else if (isBlocked) {
      statusColor = AppColors.error;
      statusLabel = 'BLOCKED';
    } else if (isHeld) {
      statusColor = const Color(0xFF3B82F6);
      statusLabel = 'HELD';
    } else {
      statusColor = AppColors.textSecondary;
      statusLabel = status.toUpperCase();
    }

    final startT = (slot['start_time'] as String? ?? '00:00:00');
    final endT = (slot['end_time'] as String? ?? '00:00:00');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              isHeld ? 'PLAYER IN CHECKOUT' : 'TIME SLOT',
              style: GoogleFonts.poppins(
                fontSize: 9,
                color: isHeld ? statusColor : AppColors.textSecondary,
                fontWeight: isHeld ? FontWeight.w600 : FontWeight.normal,
                letterSpacing: 0.5),
            ),
            const SizedBox(height: 2),
            Text(
              '${startT.length >= 5 ? startT.substring(0, 5) : startT} – ${endT.length >= 5 ? endT.substring(0, 5) : endT}',
              style: GoogleFonts.poppins(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: isPast ? AppColors.textSecondary : AppColors.textPrimary,
              ),
            ),
          ]),
        ),
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              statusLabel,
              style: GoogleFonts.poppins(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
          if (isPast && isBooked) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('WAS BOOKED',
                style: GoogleFonts.poppins(
                  color: AppColors.warning, fontSize: 9, fontWeight: FontWeight.bold)),
            ),
          ],
          // Block/unblock for available or blocked, non-past. A held slot has a
          // player mid-checkout on it, so it is deliberately not blockable until
          // the hold expires or they finish.
          if ((isAvailable || isBlocked) && !isPast) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _toggleBlock(slot),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isBlocked ? AppColors.accentLight : const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isBlocked ? Icons.lock_open_outlined : Icons.lock_outline,
                  size: 16,
                  color: isBlocked ? AppColors.accent : AppColors.error,
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  void _showAddSlotSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Slot Info — ${_fullDate(_selectedDate)}',
            style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.inputFill, borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              Row(children: [
                const Icon(Icons.info_outline, color: AppColors.accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Slots are auto-generated for your venue. Use the Slot Calendar to block/unblock individual slots.',
                    style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text('Got It', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _navBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: AppColors.inputFill, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 20, color: AppColors.textPrimary),
        ),
      );

  String _monthYear(DateTime d) {
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[d.month - 1]} ${d.year}';
  }

  String _fullDate(DateTime d) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
  }
}
