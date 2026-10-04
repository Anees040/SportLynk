import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../services/pricing_service.dart';
import '../../widgets/pricing_widgets.dart';
import 'owner_venue_reviews_screen.dart';

class OwnerVenueManagementScreen extends StatefulWidget {
  final Map<String, dynamic> venue;

  const OwnerVenueManagementScreen({super.key, required this.venue});

  @override
  State<OwnerVenueManagementScreen> createState() => _OwnerVenueManagementScreenState();
}

class _OwnerVenueManagementScreenState extends State<OwnerVenueManagementScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _descCtrl;
  late TextEditingController _priceCtrl;
  bool _isSaving = false;

  // Operating hours and slot length.
  //
  // Both are sent only when the owner actually changes them, because saving either
  // one re-cuts the venue's future grid: unsold slots outside the new window are
  // retired and the new window is filled. An owner editing only the description
  // must not trigger that.
  TimeOfDay _open = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _close = const TimeOfDay(hour: 23, minute: 0);
  int _slotMinutes = 60;
  bool _hoursDirty = false;
  bool _durationDirty = false;

  /// The lengths the server accepts (`slotGrid.ALLOWED_DURATIONS`). Restated here
  /// rather than fetched: it is a fixed list, and the server rejects anything else
  /// with a message this screen shows.
  static const _slotLengths = [30, 60, 90, 120];

  /// The multi-slot discount ladder, as the owner edits it.
  ///
  /// Each entry is `{minSlots, percent}`. Loaded from the server and sent back as
  /// a whole set: the ladder is one thing to the player, so editing it a rule at a
  /// time would leave the two halves of a two-rule change live at different
  /// moments.
  List<Map<String, int>> _tiers = [];
  bool _tiersLoading = true;
  String? _tiersError;
  bool _savingTiers = false;

  /// Mirrors the CHECK clauses migration 035 writes. The server validates the same
  /// bounds and its message is what the owner is shown on a refusal; these only
  /// stop the form offering a value that would be refused.
  static const int _minTierSlots = 2;
  static const int _maxTierSlots = 12;
  static const int _maxTierPercent = 50;

  // 72-hour demand forecast (FR4.18)
  // Read-only and independent of the form: the owner is looking at it precisely to
  // decide what to type into the price field, so a failure here must leave the form
  // fully usable.
  final _pricing = PricingService();
  DemandForecast? _forecast;
  bool _forecastLoading = true;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: widget.venue['description']?.toString() ?? '');
    _priceCtrl = TextEditingController(text: _parseNum(widget.venue['price_per_hour']).toStringAsFixed(0));
    _open = _parseTime(widget.venue['operating_hours_from']) ?? _open;
    _close = _parseTime(widget.venue['operating_hours_to']) ?? _close;
    final d = int.tryParse(widget.venue['slot_duration_minutes']?.toString() ?? '');
    if (d != null && _slotLengths.contains(d)) _slotMinutes = d;
    _loadForecast();
    _loadTiers();
  }

  Future<void> _loadTiers() async {
    final id = widget.venue['id']?.toString();
    if (id == null || id.isEmpty) {
      setState(() => _tiersLoading = false);
      return;
    }
    setState(() {
      _tiersLoading = true;
      _tiersError = null;
    });
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final resp = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/owner/venues/$id/discounts'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = jsonDecode(resp.body);
      if (!mounted) return;
      setState(() {
        _tiersLoading = false;
        if (data['success'] == true) {
          _tiers = ((data['data']['tiers'] ?? []) as List)
              .map((t) => {
                    'minSlots': (_parseNum(t['min_slots'])).round(),
                    'percent': (_parseNum(t['percent'])).round(),
                  })
              .toList();
        } else {
          // Surfaced with a retry rather than shown as an empty ladder: "no
          // discounts" and "could not read the discounts" are different facts and
          // an owner acts differently on each.
          _tiersError = (data['message'] ?? 'Could not load discounts.').toString();
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _tiersLoading = false;
        _tiersError = 'Could not reach the server.';
      });
    }
  }

  Future<void> _saveTiers() async {
    final id = widget.venue['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() => _savingTiers = true);
    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final resp = await http.put(
        Uri.parse('${ApiConstants.baseUrl}/owner/venues/$id/discounts'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'tiers': _tiers
              .map((t) => {'min_slots': t['minSlots'], 'percent': t['percent']})
              .toList(),
        }),
      );
      final data = jsonDecode(resp.body);
      if (!mounted) return;
      setState(() => _savingTiers = false);
      if (data['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(data['message']?.toString() ?? 'Discounts saved'),
          backgroundColor: AppColors.accent,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(data['message']?.toString() ?? 'Could not save discounts'),
          backgroundColor: AppColors.error,
        ));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _savingTiers = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error occurred'),
        backgroundColor: AppColors.error,
      ));
    }
  }

  /// The next sensible threshold to offer: one more than the deepest rule already
  /// in the ladder, so a second Add never proposes a duplicate the server refuses.
  int get _nextTierThreshold {
    final used = _tiers.map((t) => t['minSlots'] ?? 0).toList();
    for (var n = _minTierSlots; n <= _maxTierSlots; n += 1) {
      if (!used.contains(n)) return n;
    }
    return _maxTierSlots;
  }

  /// A TIME column as 'HH:MM:SS', or null when the venue has never had hours set.
  ///
  /// 24:00:00 is a value the column can hold and TimeOfDay cannot. It is shown as
  /// 00:00, which the server reads as the same window: a closing time below the
  /// opening time rolls past midnight, and 18:00-00:00 covers exactly the hours
  /// 18:00-24:00 does.
  TimeOfDay? _parseTime(dynamic raw) {
    if (raw == null) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw.toString());
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    return TimeOfDay(hour: h >= 24 ? 0 : h, minute: int.parse(m.group(2)!));
  }

  String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// True when the close time is at or before the open time, which the server reads
  /// as a window that runs past midnight. Stated in the UI so an owner who meant
  /// 02:00 the next morning can see that is how it was understood.
  bool get _runsPastMidnight {
    final openM = _open.hour * 60 + _open.minute;
    final closeM = _close.hour * 60 + _close.minute;
    return closeM < openM || (closeM == 0 && openM > 0);
  }

  Future<void> _pickTime({required bool isOpen}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isOpen ? _open : _close,
    );
    if (picked == null) return;
    setState(() {
      if (isOpen) {
        _open = picked;
      } else {
        _close = picked;
      }
      _hoursDirty = true;
    });
  }

  Future<void> _loadForecast() async {
    final id = widget.venue['id']?.toString();
    if (id == null || id.isEmpty) {
      setState(() => _forecastLoading = false);
      return;
    }
    setState(() => _forecastLoading = true);
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    final f = await _pricing.forecast(token ?? '', id, hours: 72);
    if (!mounted) return;
    setState(() {
      _forecast = f;
      _forecastLoading = false;
    });
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  double _parseNum(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;

    // Changing the window retires unsold slots outside it. That is not something to
    // do on a mis-tap, so it is confirmed first and the consequence is named —
    // including the one thing that does NOT happen, since an owner's first fear is
    // that narrowing their hours cancels bookings they have already taken.
    if (_hoursDirty || _durationDirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Update hours?', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
          content: Text(
            'Slots for the next 14 days will be rebuilt as '
            '${_hhmm(_open)}–${_hhmm(_close)} in $_slotMinutes-minute slots.\n\n'
            'Unsold slots outside the new hours are removed. Slots that are already '
            'booked, blocked or held for a tournament are kept exactly as they are.',
            style: GoogleFonts.poppins(fontSize: 13),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Update')),
          ],
        ),
      );
      if (ok != true) return;
    }

    if (!mounted) return;
    setState(() => _isSaving = true);

    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      final body = <String, dynamic>{
        'description': _descCtrl.text.trim(),
        'price_per_hour': double.parse(_priceCtrl.text.trim()),
      };
      if (_hoursDirty) {
        body['operating_hours_from'] = _hhmm(_open);
        body['operating_hours_to'] = _hhmm(_close);
      }
      if (_durationDirty) body['slot_duration_minutes'] = _slotMinutes;

      final req = await http.patch(
        Uri.parse('${ApiConstants.baseUrl}/owner/venues/${widget.venue['id']}'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      final data = jsonDecode(req.body);
      if (mounted) {
        if (data['success'] == true) {
          // The server's own sentence, not a generic one: after a reshape it carries
          // the window, the slot length and how many slots were opened, closed and
          // kept. A hardcoded "updated successfully" would hide all of it.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['message']?.toString() ?? 'Venue updated successfully'),
              backgroundColor: AppColors.accent,
              duration: const Duration(seconds: 6),
            ),
          );
          Navigator.pop(context, true); // true indicates a refresh is needed
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(data['message'] ?? 'Failed to update'), backgroundColor: AppColors.error),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Network error occurred'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildField(String label, TextEditingController ctrl, {bool isNumber = false, int maxLines = 1, String? suffixText}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        TextFormField(
          controller: ctrl,
          keyboardType: isNumber ? TextInputType.number : TextInputType.text,
          maxLines: maxLines,
          style: GoogleFonts.poppins(fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.inputFill,
            suffixText: suffixText,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          validator: (v) => v == null || v.isEmpty ? 'Required' : null,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// One tappable time tile. Minimum height 56 so the target clears 48 logical
  /// pixels with its padding, and the label sits above the value so a large system
  /// text scale grows the tile downwards instead of clipping it.
  Widget _timeTile({required String label, required TimeOfDay value, required VoidCallback onTap}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.inputFill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
              Text(_hhmm(value),
                style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }

  /// Operating hours and slot length.
  ///
  /// No slot count is computed here on purpose. The grid arithmetic lives on the
  /// server (utils/slotGrid.js) and a second copy in Dart would be one more place
  /// for the two to disagree about what a venue sells. The save response states the
  /// window, the slot length and the real counts.
  Widget _buildHoursSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Operating Hours',
          style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Row(children: [
          _timeTile(label: 'Opens', value: _open, onTap: () => _pickTime(isOpen: true)),
          const SizedBox(width: 12),
          _timeTile(label: 'Closes', value: _close, onTap: () => _pickTime(isOpen: false)),
        ]),
        if (_runsPastMidnight)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.nightlight_outlined, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Closes the next morning. Slots after midnight appear on the following day.',
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 16),
        Text('Slot Length',
          style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _slotLengths.map((m) {
            final selected = m == _slotMinutes;
            return ChoiceChip(
              label: Text('$m min',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? Colors.white : AppColors.textPrimary,
                )),
              selected: selected,
              selectedColor: AppColors.accent,
              backgroundColor: AppColors.inputFill,
              showCheckmark: false,
              onSelected: (_) => setState(() {
                _slotMinutes = m;
                _durationDirty = true;
              }),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Text(
          'The price above is per hour. A $_slotMinutes-minute slot is priced pro rata.',
          style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// The multi-slot discount ladder.
  ///
  /// Saved by its own button rather than by Save Changes: the ladder has its own
  /// endpoint, its own validation and its own refusals, and folding it into the
  /// venue save would mean one failed rule rejecting a description edit too.
  Widget _buildDiscountSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Multi-Slot Discounts',
          style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Text(
          'Reward players who book back-to-back slots. The discount applies to '
          'each slot in the booking.',
          style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),

        if (_tiersLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
            )),
          )
        else if (_tiersError != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, size: 16, color: AppColors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_tiersError!,
                  style: GoogleFonts.poppins(fontSize: 11, color: AppColors.error)),
              ),
              TextButton(
                onPressed: _loadTiers,
                child: Text('Retry', style: GoogleFonts.poppins(fontSize: 12)),
              ),
            ]),
          )
        else ...[
          if (_tiers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('No discounts yet — players pay the full price for every slot.',
                style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
            ),
          for (var i = 0; i < _tiers.length; i += 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: _tierDropdown<int>(
                    label: 'Slots',
                    value: _tiers[i]['minSlots'] ?? _minTierSlots,
                    items: [
                      for (var n = _minTierSlots; n <= _maxTierSlots; n += 1) n,
                    ],
                    render: (n) => '$n+',
                    onChanged: (n) => setState(() => _tiers[i]['minSlots'] = n),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _tierDropdown<int>(
                    label: 'Discount',
                    value: _tiers[i]['percent'] ?? 5,
                    items: [
                      for (var p = 5; p <= _maxTierPercent; p += 5) p,
                    ],
                    render: (p) => '$p%',
                    onChanged: (p) => setState(() => _tiers[i]['percent'] = p),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove this rule',
                  icon: const Icon(Icons.delete_outline, color: AppColors.textSecondary),
                  onPressed: () => setState(() => _tiers.removeAt(i)),
                ),
              ]),
            ),
          Row(children: [
            if (_tiers.length < _maxTierSlots - _minTierSlots + 1)
              TextButton.icon(
                onPressed: () => setState(() =>
                    _tiers.add({'minSlots': _nextTierThreshold, 'percent': 10})),
                icon: const Icon(Icons.add, size: 18, color: AppColors.accent),
                label: Text('Add a rule',
                  style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.accent)),
              ),
            const Spacer(),
            TextButton(
              onPressed: _savingTiers ? null : _saveTiers,
              child: _savingTiers
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent))
                  : Text('Save discounts',
                      style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.accent)),
            ),
          ]),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  /// A labelled dropdown sized to clear a 48-pixel tap target.
  Widget _tierDropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) render,
    required ValueChanged<T> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.inputFill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: items.contains(value) ? value : items.first,
              isExpanded: true,
              style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textPrimary),
              items: items
                  .map((i) => DropdownMenuItem<T>(value: i, child: Text(render(i))))
                  .toList(),
              onChanged: (v) { if (v != null) onChanged(v); },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Manage ${widget.venue['name']}', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Reviews',
            icon: const Icon(Icons.reviews_outlined, color: Colors.white),
            onPressed: () {
              final id = widget.venue['id']?.toString();
              if (id == null || id.isEmpty) return;
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => OwnerVenueReviewsScreen(
                  venueId: id,
                  venueName: widget.venue['name']?.toString(),
                ),
              ));
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildField('Venue Description & Amenities', _descCtrl, maxLines: 4),
              _buildField('Price Per Hour', _priceCtrl, isNumber: true, suffixText: 'PKR'),

              // Above the forecast: the hours decide which slots exist at all, and
              // the forecast is advice about what to charge for them.
              _buildHoursSection(),

              // Directly after the hours, because the slot length decides what "2+
              // slots" is worth: at 30-minute slots a 2-slot discount is an hour.
              _buildDiscountSection(),

              // Sits directly under the price field on purpose: this is the evidence
              // for the number the owner is about to type. Above the escrow note,
              // which is policy they cannot change.
              DemandForecastSection(
                forecast: _forecast,
                loading: _forecastLoading,
                onRetry: _loadForecast,
              ),
              const SizedBox(height: 16),

              // Deposit policy is platform-wide and computed server-side — read only.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.lock_outline, color: AppColors.accent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Escrow policy (set by SportLynk): the full slot price is held when a '
                      'player books and released to you at QR check-in. On a late '
                      'cancellation or no-show you keep the 20% deposit.',
                      style: GoogleFonts.poppins(fontSize: 11, color: AppColors.primary),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveChanges,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: _isSaving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text('Save Changes', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
