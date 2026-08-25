import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../constants/api_constants.dart';
import '../constants/colors.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../services/pricing_service.dart';

/// The Apply half of FR4.17 — the owner's explicit act.
///
/// The whole point of this sheet is that it stands between a suggestion and a real
/// price. Nothing in Wave D writes a price without an owner passing through here:
/// they pick a day, they pick the slots, they see the exact rupee change on each
/// one, and only then does the PATCH go out.
///
/// It is deliberately picky about what it OFFERS to reprice. A booked slot's price
/// is what a player already agreed to pay and must never move; a held slot is
/// mid-checkout; a past slot is history. Those are shown, greyed, with the reason —
/// rather than hidden — because an owner who selected "all" and got 6 of 9 needs to
/// know which three and why, and the answer should already be on screen when the
/// result lands. The server independently enforces every one of these rules inside
/// the transaction; this sheet is the courtesy, not the guard.
Future<bool?> showApplyPriceSheet(
  BuildContext context, {
  required String venueId,
  required PriceSuggestion suggestion,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ApplyPriceSheet(venueId: venueId, suggestion: suggestion),
  );
}

class _ApplyPriceSheet extends StatefulWidget {
  final String venueId;
  final PriceSuggestion suggestion;

  const _ApplyPriceSheet({required this.venueId, required this.suggestion});

  @override
  State<_ApplyPriceSheet> createState() => _ApplyPriceSheetState();
}

class _SlotRow {
  final String id;
  final String startTime;
  final String status; // effective_status: available | booked | blocked | locked
  final double price;
  final bool isPast;

  const _SlotRow({
    required this.id,
    required this.startTime,
    required this.status,
    required this.price,
    required this.isPast,
  });

  bool get selectable => status == 'available' && !isPast;

  String get hourLabel {
    final h = int.tryParse(startTime.split(':').first) ?? 0;
    return '${h.toString().padLeft(2, '0')}:00';
  }

  String get blockedReason => isPast
      ? 'already passed'
      : switch (status) {
          'booked' => 'booked — price is locked in',
          'locked' => 'held by a player right now',
          'blocked' => 'blocked',
          _ => 'not available',
        };
}

class _ApplyPriceSheetState extends State<_ApplyPriceSheet> {
  final ApiClient _api = ApiClient();
  final PricingService _pricing = PricingService();

  late DateTime _day;
  List<_SlotRow> _slots = const [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Opens on the day the suggestion was computed for, not on "today" — the
    // suggestion is for a specific date and hour, and landing the owner anywhere
    // else invites them to apply a Saturday-peak price to a Tuesday morning.
    _day = DateTime.tryParse(widget.suggestion.slotDate ?? '') ?? DateTime.now();
    _load();
  }

  String get _dateStr =>
      '${_day.year}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final r = await _api.get(
      ApiConstants.ownerSlots,
      token: token,
      queryParams: {'date': _dateStr, 'venueId': widget.venueId},
    );
    if (!mounted) return;

    if (r['success'] != true) {
      setState(() {
        _loading = false;
        _error = r['message']?.toString() ?? 'Could not load slots for this day.';
      });
      return;
    }

    final now = DateTime.now();
    final rows = (r['data'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final m = Map<String, dynamic>.from(raw);
          final start = (m['start_time'] ?? '00:00:00').toString();
          final hour = int.tryParse(start.split(':').first) ?? 0;
          final slotAt = DateTime(_day.year, _day.month, _day.day, hour);
          return _SlotRow(
            id: (m['id'] ?? '').toString(),
            startTime: start,
            // `effective_status` folds a live hold into its own status server-side;
            // falling back to raw `status` keeps this working if that column is ever
            // absent, at the cost of showing a held slot as available — which the
            // server would then skip and report.
            status: (m['effective_status'] ?? m['status'] ?? 'available').toString(),
            price: _num(m['price']),
            isPast: slotAt.isBefore(now),
          );
        })
        .where((s) => s.id.isNotEmpty)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    // Pre-select the hour the suggestion was actually computed for. Everything else
    // is an extrapolation the owner should opt into deliberately: the model priced
    // 20:00 on a Saturday, not the whole day.
    final target = widget.suggestion.hour;
    _selected.clear();
    if (target != null) {
      for (final s in rows) {
        if (s.selectable && s.hourLabel.startsWith(target.toString().padLeft(2, '0'))) {
          _selected.add(s.id);
        }
      }
    }

    setState(() {
      _slots = rows;
      _loading = false;
    });
  }

  Future<void> _shiftDay(int days) async {
    setState(() => _day = _day.add(Duration(days: days)));
    await _load();
  }

  Future<void> _submit() async {
    if (_selected.isEmpty || _submitting) return;
    setState(() => _submitting = true);

    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final r = await _pricing.applyPrice(
      token ?? '',
      widget.venueId,
      slotIds: _selected.toList(),
      price: widget.suggestion.suggestedPrice.toDouble(),
    );
    if (!mounted) return;

    final ok = r['success'] == true;
    final data = r['data'] is Map ? Map<String, dynamic>.from(r['data'] as Map) : const {};
    final skipped = (data['skipped'] as List? ?? const []);

    if (ok) {
      // The server's own message already says "applied to 6 of 8". Appending the
      // first skip reason turns that into something the owner can act on without
      // opening the sheet again.
      final detail = skipped.isEmpty
          ? ''
          : ' (${skipped.length} skipped — ${_skipWord(skipped)})';
      // Captured BEFORE the pop: after it, this sheet's context is defunct and
      // `ScaffoldMessenger.of(context)` would look up a dead element.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, true);
      messenger.showSnackBar(SnackBar(
        content: Text('${r['message'] ?? 'Price applied'}$detail',
            style: GoogleFonts.poppins(color: Colors.white, fontSize: 12.5)),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    setState(() {
      _submitting = false;
      _error = r['message']?.toString() ?? 'Could not apply the price.';
    });
  }

  /// Turns the server's skip reasons into one phrase, most common first, rather
  /// than a raw enum dump.
  String _skipWord(List<dynamic> skipped) {
    final counts = <String, int>{};
    for (final s in skipped) {
      if (s is Map) {
        final reason = (s['reason'] ?? 'skipped').toString();
        counts[reason] = (counts[reason] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return 'see the schedule';
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return switch (top) {
      'booked' => 'already booked',
      'locked' => 'held by a player',
      'past' => 'already passed',
      'unchanged' => 'already at this price',
      'not_found' => 'no longer exist',
      _ => top,
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    final selectable = _slots.where((x) => x.selectable).toList();
    final allSelected = selectable.isNotEmpty && _selected.length == selectable.length;

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      expand: false,
      builder: (context, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration:
                BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Apply PKR ${_fmtInt(s.suggestedPrice)}/hr',
                  style: GoogleFonts.poppins(
                      fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
              const SizedBox(height: 2),
              Text(
                'Choose the slots to reprice. Booked and held slots cannot change.',
                style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
              ),
            ]),
          ),
          _dayBar(allSelected, selectable),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent))
                : _slots.isEmpty
                    ? _empty()
                    : ListView.separated(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        itemCount: _slots.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (_, i) => _slotTile(_slots[i]),
                      ),
          ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: AppColors.error.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text(_error!,
                  style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.error)),
            ),
          _footer(),
        ]),
      ),
    );
  }

  Widget _dayBar(bool allSelected, List<_SlotRow> selectable) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded, size: 22),
            color: AppColors.textSecondary,
            // No repricing the past: the schedule only moves forward from today.
            onPressed: _loading || _isToday ? null : () => _shiftDay(-1),
          ),
          Expanded(
            child: Text(
              _dayLabel,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                  fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded, size: 22),
            color: AppColors.textSecondary,
            onPressed: _loading ? null : () => _shiftDay(1),
          ),
          TextButton(
            onPressed: selectable.isEmpty
                ? null
                : () => setState(() {
                      if (allSelected) {
                        _selected.clear();
                      } else {
                        _selected
                          ..clear()
                          ..addAll(selectable.map((x) => x.id));
                      }
                    }),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(allSelected ? 'Clear' : 'All',
                style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ]),
      );

  bool get _isToday {
    final n = DateTime.now();
    return _day.year == n.year && _day.month == n.month && _day.day == n.day;
  }

  String get _dayLabel {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final w = names[(_day.weekday - 1).clamp(0, 6)];
    return _isToday
        ? 'Today · $w ${_day.day} ${months[_day.month - 1]}'
        : '$w ${_day.day} ${months[_day.month - 1]}';
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No slots on this day.\nGenerate the schedule first, then come back.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
                fontSize: 12, color: AppColors.textSecondary, height: 1.5),
          ),
        ),
      );

  Widget _slotTile(_SlotRow s) {
    final selected = _selected.contains(s.id);
    final delta = widget.suggestion.suggestedPrice - s.price;
    final unchanged = delta.abs() < 0.5;

    return Opacity(
      opacity: s.selectable ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: !s.selectable
            ? null
            : () => setState(() => selected ? _selected.remove(s.id) : _selected.add(s.id)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentLight : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            SizedBox(
              width: 34,
              child: s.selectable
                  ? Icon(
                      selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                      size: 20,
                      color: selected ? AppColors.accent : AppColors.disabled,
                    )
                  : const Icon(Icons.lock_outline_rounded, size: 17, color: AppColors.disabled),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.hourLabel,
                    style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                if (!s.selectable)
                  Text(s.blockedReason,
                      style:
                          GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary)),
              ]),
            ),
            // The exact rupee change on THIS slot, not the card's headline delta.
            // Slots can sit at different prices after an earlier partial apply, so
            // one global "+30%" would be wrong on some rows.
            if (s.selectable)
              Text(
                unchanged
                    ? 'no change'
                    : 'PKR ${_fmtInt(s.price.round())} → ${_fmtInt(widget.suggestion.suggestedPrice)}',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: unchanged
                      ? AppColors.textSecondary
                      : (delta > 0 ? AppColors.success : AppColors.error),
                ),
              )
            else
              Text('PKR ${_fmtInt(s.price.round())}',
                  style:
                      GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }

  Widget _footer() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(children: [
            Expanded(
              child: Text(
                _selected.isEmpty
                    ? 'Nothing selected'
                    : '${_selected.length} slot${_selected.length == 1 ? '' : 's'} selected',
                style: GoogleFonts.poppins(
                    fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              onPressed: _selected.isEmpty || _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                disabledBackgroundColor: AppColors.disabled,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('Apply price',
                      style: GoogleFonts.poppins(
                          color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      );
}

double _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

String _fmtInt(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
