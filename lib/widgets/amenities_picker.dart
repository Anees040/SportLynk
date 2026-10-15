import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';

/// The amenities a ground offers, chosen from a preset checklist plus a free-text
/// "add your own" field (owner item 4).
///
/// The value is a map of amenity-key → true, which is exactly the shape
/// `venues.amenities` (JSONB) stores and the player's venue detail screen renders.
/// Only present amenities are kept — the column lists what a ground HAS, so an
/// unticked preset is simply absent rather than stored as `false`. Keys are
/// lowercased with underscores so they match the server's `normaliseAmenities`
/// (owner.js) and the keys `seed_venues.js` wrote by hand; the label shown to the
/// owner is title-cased for display only.
///
/// Both the add-venue wizard and the manage-venue screen embed this, so the two
/// paths cannot drift in which presets they offer or how they key a custom entry.
class AmenitiesPicker extends StatefulWidget {
  /// Amenities already on the venue, as the `amenities` map from the API
  /// (key → truthy). Only truthy entries are treated as selected.
  final Map<String, dynamic> initial;

  /// Fired on every change with the current selection as a `{key: true}` map,
  /// ready to send to the server unchanged.
  final ValueChanged<Map<String, bool>> onChanged;

  const AmenitiesPicker({
    super.key,
    this.initial = const {},
    required this.onChanged,
  });

  @override
  State<AmenitiesPicker> createState() => _AmenitiesPickerState();
}

class _AmenitiesPickerState extends State<AmenitiesPicker> {
  /// The presets, in display order. The key is what is stored; the label is what
  /// the owner reads. These six are the common ground facilities named in the
  /// requirement; anything else is added through the custom field.
  static const List<MapEntry<String, String>> _presets = [
    MapEntry('floodlights', 'Floodlights'),
    MapEntry('changing_rooms', 'Changing Rooms'),
    MapEntry('parking', 'Parking'),
    MapEntry('water', 'Water'),
    MapEntry('washrooms', 'Washrooms'),
    MapEntry('seating_stand', 'Seating Stand'),
  ];

  final _customCtrl = TextEditingController();

  /// Selected amenity keys. Seeded from [AmenitiesPicker.initial]'s truthy entries,
  /// so re-opening a venue shows what it already offers.
  final Set<String> _selected = {};

  /// Custom keys the owner added that are not among the presets, kept so they
  /// render their own chip alongside the presets.
  final Set<String> _custom = {};

  @override
  void initState() {
    super.initState();
    for (final e in widget.initial.entries) {
      if (e.value == true || e.value == 'true') {
        final key = _normalise(e.key);
        if (key.isEmpty) continue;
        _selected.add(key);
        if (!_presets.any((p) => p.key == key)) _custom.add(key);
      }
    }
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  /// The same normalisation the server applies, so a chip the owner ticks keys the
  /// same string the backend validates and the detail screen later renders.
  String _normalise(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');

  /// A key back to a readable label: a preset uses its own label, a custom key is
  /// un-underscored and title-cased.
  String _label(String key) {
    for (final p in _presets) {
      if (p.key == key) return p.value;
    }
    return key
        .split('_')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  void _emit() => widget.onChanged({for (final k in _selected) k: true});

  void _toggle(String key, bool on) {
    setState(() {
      if (on) {
        _selected.add(key);
      } else {
        _selected.remove(key);
      }
    });
    _emit();
  }

  void _addCustom() {
    final key = _normalise(_customCtrl.text);
    // Mirror the server's key rule so a value it would refuse is never offered.
    if (key.isEmpty || !RegExp(r'^[a-z][a-z0-9_-]{1,29}$').hasMatch(key)) return;
    if (_presets.any((p) => p.key == key) || _custom.contains(key)) {
      // Already offered — just select it and clear the field.
      setState(() {
        _selected.add(key);
        _customCtrl.clear();
      });
      _emit();
      return;
    }
    setState(() {
      _custom.add(key);
      _selected.add(key);
      _customCtrl.clear();
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      for (final p in _presets) _chip(p.key),
      for (final k in _custom) _chip(k),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Amenities & Facilities',
            style: GoogleFonts.poppins(
                fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Text('Tick what this ground offers, or add your own.',
            style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: chips),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customCtrl,
                textInputAction: TextInputAction.done,
                inputFormatters: [LengthLimitingTextInputFormatter(30)],
                style: GoogleFonts.poppins(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Add a custom amenity',
                  hintStyle: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.inputFill,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _addCustom(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 44,
              child: ElevatedButton(
                onPressed: _addCustom,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentLight,
                  foregroundColor: AppColors.accent,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('Add', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(String key) {
    final on = _selected.contains(key);
    return FilterChip(
      label: Text(
        _label(key),
        style: GoogleFonts.poppins(
          fontSize: 12.5,
          color: on ? AppColors.accent : AppColors.textSecondary,
          fontWeight: on ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      selected: on,
      onSelected: (v) => _toggle(key, v),
      selectedColor: AppColors.accentLight,
      checkmarkColor: AppColors.accent,
      backgroundColor: AppColors.inputFill,
      side: BorderSide(color: on ? AppColors.accent : AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}
