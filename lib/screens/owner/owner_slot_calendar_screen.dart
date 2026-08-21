import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';

class OwnerSlotCalendarScreen extends StatefulWidget {
  const OwnerSlotCalendarScreen({super.key});
  @override
  State<OwnerSlotCalendarScreen> createState() => _OwnerSlotCalendarScreenState();
}

class _OwnerSlotCalendarScreenState extends State<OwnerSlotCalendarScreen> {
  DateTime _selectedDate = DateTime.now();
  List<Map<String, dynamic>> _slots = [];
  List<Map<String, dynamic>> _venues = [];
  String? _selectedVenueId;
  bool _loading = false;
  static String get _base => ApiConstants.baseUrl;

  @override
  void initState() {
    super.initState();
    _loadVenues();
  }

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
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        setState(() {
          _slots = data['success'] == true ? List<Map<String, dynamic>>.from(data['data']) : [];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _generateSlots() async {
    if (_selectedVenueId == null) return;
    if (mounted) setState(() => _loading = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token!;
      final resp = await http.post(
        Uri.parse('$_base/owner/slots/generate'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'venueId': _selectedVenueId}),
      );
      final data = jsonDecode(resp.body);
      if (mounted) {
        _snack(data['message'] ?? 'Action completed', data['success'] == true ? AppColors.accent : AppColors.error);
        _loadSlots();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      _snack('Network error', AppColors.error);
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
          IconButton(
            tooltip: 'Generate Slots for 7 Days',
            icon: const Icon(Icons.auto_awesome, color: Colors.white),
            onPressed: _generateSlots,
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
        // ── CALENDAR WIDGET ──────────────────────────────
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

        // ── SELECTED DATE HEADER ────────────────────────
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

        // ── SLOTS LIST ──────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
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
                  : ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                      itemCount: _slots.length,
                      itemBuilder: (_, i) => _slotRow(_slots[i]),
                    ),
        ),
      ]),
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
    final isPast = _isSlotPast(slot);

    final Color statusColor;
    final String statusLabel;

    // SRS colour code: Green free · Amber booked · Red blocked · Blue held.
    if (isPast && !isBooked) {
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
                color: (isPast && !isBooked) ? AppColors.textSecondary : AppColors.textPrimary,
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

  bool _isSlotPast(Map<String, dynamic> slot) {
    try {
      final date = DateTime.parse(slot['slot_date'].toString());
      final timeParts = (slot['end_time'] as String).split(':');
      final slotEnd = DateTime(date.year, date.month, date.day, int.parse(timeParts[0]), int.parse(timeParts[1]));
      return slotEnd.isBefore(DateTime.now());
    } catch (_) {
      return false;
    }
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
