// admin_settings_screen.dart — D5 / FR10.9–10.11.
//
// The catalogue is the server's. Every section, every field, its type, its unit,
// its bounds, its step, its description, its default and whether it is currently
// overridden all arrive from `GET /api/admin/settings`. There is deliberately no
// Dart copy of any of it: a second list of settings is a second source of truth,
// and the moment one of them gains a key the other one is a lie. Add a field to
// `backend/src/utils/settingsCatalog.js` and it appears here with no Flutter change.
//
// So this screen only knows how to render five TYPES — `int`, `number`, `bool`,
// `text`, `sports` — and how to send a patch back. It does not know what
// `elo.k_factor` means, and it must not.
//
// What it does CHECK, and only because the server checks the same thing and an
// instant answer beats a round trip: the numeric bounds it was handed, and the two
// cross-field rules whose violation the accessor would otherwise paper over —
// commission + deposit must not exceed 100 % of a slot, and the tournament pool
// shares must total exactly 100. Everything else is the server's refusal to make,
// including the 409 that names the sport whose future bookings block a switch-off.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';

class AdminSettingsScreen extends StatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen> {
  final _svc = AdminService();
  final Map<String, TextEditingController> _controllers = {};

  SettingsCatalog _catalog = SettingsCatalog.empty;
  final Map<String, dynamic> _draft = {};
  final Map<String, String> _fieldErrors = {};
  bool _loading = true;
  bool _saving = false;

  String? get _token => Provider.of<AuthProvider>(context, listen: false).token;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    setState(() => _loading = true);
    final cat = await _svc.settings(token);
    if (!mounted) return;
    setState(() {
      _catalog = cat;
      _draft.clear();
      _fieldErrors.clear();
      // Controllers are rebuilt from the server's values: a reload after a save
      // must not leave a stale string in a box the admin is looking at.
      for (final s in cat.sections) {
        for (final f in s.fields) {
          if (f.isNumeric || f.type == 'text') {
            _controllers.putIfAbsent(f.key, () => TextEditingController()).text =
                _asText(f, f.value);
          }
        }
      }
      _loading = false;
    });
  }

  /// A field's value as the editor should show it: the draft if the admin has
  /// touched it, otherwise the saved value.
  dynamic _effective(SettingsField f) =>
      _draft.containsKey(f.key) ? _draft[f.key] : f.value;

  String _asText(SettingsField f, dynamic v) {
    if (v == null) return '';
    if (v is num) {
      return v == v.roundToDouble() && f.type == 'int'
          ? v.toStringAsFixed(0)
          : '$v';
    }
    return '$v';
  }

  void _set(SettingsField f, dynamic value) {
    setState(() {
      final saved = f.value;
      // A draft that matches the saved value is not a change: dropping it keeps the
      // "N changes" count and the confirm diff honest.
      if (_sameValue(value, saved)) {
        _draft.remove(f.key);
      } else {
        _draft[f.key] = value;
      }
      _fieldErrors.remove(f.key);
      _revalidate();
    });
  }

  bool _sameValue(dynamic a, dynamic b) {
    if (a is num && b is num) return (a - b).abs() < 1e-9;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if ((a[k] == true) != (b[k] == true)) return false;
      }
      return true;
    }
    return a == b;
  }

  /// The bounds the server returned, plus the two cross-field rules. Runs on every
  /// edit so the Save button can be honest about whether the patch would be taken.
  void _revalidate() {
    _fieldErrors.clear();
    for (final key in _draft.keys) {
      final f = _catalog.field(key);
      if (f == null) continue;
      final v = _draft[key];
      if (f.isNumeric) {
        if (v is! num) {
          _fieldErrors[key] = 'Must be a number.';
        } else if (f.type == 'int' && v != v.roundToDouble()) {
          _fieldErrors[key] = 'Must be a whole number.';
        } else if (f.min != null && v < f.min!) {
          _fieldErrors[key] = 'At least ${f.min}${f.unit ?? ''}.';
        } else if (f.max != null && v > f.max!) {
          _fieldErrors[key] = 'At most ${f.max}${f.unit ?? ''}.';
        }
      } else if (f.type == 'text') {
        final s = '${v ?? ''}'.trim();
        if (s.isEmpty) _fieldErrors[key] = 'Cannot be empty.';
        if (f.maxLen != null && s.length > f.maxLen!) {
          _fieldErrors[key] = 'Keep it to ${f.maxLen} characters.';
        }
      } else if (f.isSports) {
        final map = v is Map ? v : const {};
        if (!map.values.any((x) => x == true)) {
          _fieldErrors[key] = 'At least one sport has to stay switched on.';
        }
      }
    }
    _crossFieldRules();
  }

  /// Two rules the accessor would otherwise absorb silently — which is why they are
  /// refused at the edge instead. Both are evaluated on the state after the save,
  /// exactly as `settingsCatalog.validate()` does, so half a pair still counts.
  void _crossFieldRules() {
    num? live(String key) {
      final f = _catalog.field(key);
      if (f == null) return null;
      final v = _effective(f);
      return v is num ? v : null;
    }

    final comm = live('commission_pct');
    final dep = live('deposit_pct');
    if (comm != null && dep != null && comm + dep > 100) {
      _fieldErrors['commission_pct'] =
          'Commission ($comm%) plus the deposit ($dep%) is ${comm + dep}% of the '
          'slot price — together they cannot exceed 100%.';
    }

    final w = live('tournament.winner_percent');
    final r = live('tournament.runnerup_percent');
    if (w != null && r != null && w + r != 100) {
      _fieldErrors['tournament.winner_percent'] =
          'Winner $w% + runner-up $r% must total 100% (currently ${w + r}%).';
    }

    final minTeams = live('tournament.min_teams');
    final maxKo = live('tournament.max_knockout_teams');
    if (minTeams != null && maxKo != null && minTeams > maxKo) {
      _fieldErrors['tournament.min_teams'] =
          'The minimum ($minTeams) cannot be above the largest knockout bracket ($maxKo).';
    }
  }

  List<SettingsChange> get _changes {
    final out = <SettingsChange>[];
    for (final key in _draft.keys) {
      final f = _catalog.field(key);
      if (f == null) continue;
      out.add(SettingsChange(key: key, label: f.label, from: f.value, to: _draft[key]));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final changes = _changes;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Settings', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        actions: [
          if (_catalog.overrides.isNotEmpty)
            IconButton(
              tooltip: 'Reset every override',
              onPressed: _saving ? null : _resetAll,
              icon: const Icon(Icons.restart_alt),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _saving ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _catalog.sections.isEmpty
              ? const Center(
                  child: MatchEmptyState(
                    text: 'The settings catalogue could not be loaded.',
                    icon: Icons.tune,
                  ),
                )
              : RefreshIndicator(
                  color: AppColors.accent,
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                    children: [
                      _banner(),
                      const SizedBox(height: 12),
                      for (final s in _catalog.sections) ...[
                        _section(s),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
      bottomNavigationBar: changes.isEmpty ? null : _saveBar(changes),
    );
  }

  /// FR10.11 in one sentence, with the number the server gave rather than a claim:
  /// a change lands on the next operation because the accessor's cache is dropped in
  /// the same request that writes the row.
  Widget _banner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _catalog.appliesImmediately
                  ? 'Changes apply to the next booking, match and tournament — no '
                      'restart. Other servers pick them up within '
                      '${_catalog.cacheTtlSeconds}s.'
                  : 'Changes need a restart to take effect.',
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textPrimary),
            ),
          ),
          if (_catalog.overrides.isNotEmpty)
            Text(
              '${_catalog.overrides.length} overridden',
              style: GoogleFonts.poppins(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
        ],
      ),
    );
  }

  Widget _section(SettingsSection s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.label,
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          if ((s.hint ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              s.hint!,
              style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 10),
          for (int i = 0; i < s.fields.length; i++) ...[
            if (i > 0) Divider(height: 18, color: AppColors.border),
            _field(s.fields[i]),
          ],
        ],
      ),
    );
  }

  // One field, whatever it is
  Widget _field(SettingsField f) {
    final err = _fieldErrors[f.key];
    final dirty = _draft.containsKey(f.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.label,
                    style: GoogleFonts.poppins(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if ((f.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      f.description!,
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _stateChip(f, dirty),
          ],
        ),
        const SizedBox(height: 8),
        _editor(f),
        if (err != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded, size: 13, color: Colors.red),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  err,
                  style: GoogleFonts.poppins(fontSize: 11, color: Colors.red),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// "default" · "overridden" · "edited", plus the per-key reset.
  ///
  /// `isOverridden` is the server's comparison of the stored value against the
  /// documented default — it is not recomputed here, because the server compares
  /// values and the seed migration wrote a row for every key, so "has a row" and
  /// "is overridden" are different facts.
  Widget _stateChip(SettingsField f, bool dirty) {
    if (dirty) {
      return Row(
        children: [
          _pill('edited', AppColors.accent),
          const SizedBox(width: 4),
          _iconBtn(
            Icons.undo_rounded,
            'Undo this change',
            () => setState(() {
              _draft.remove(f.key);
              _controllers[f.key]?.text = _asText(f, f.value);
              _revalidate();
            }),
          ),
        ],
      );
    }
    if (!f.isOverridden) return _pill('default', AppColors.textSecondary);
    return Row(
      children: [
        _pill('overridden', Colors.orange),
        const SizedBox(width: 4),
        _iconBtn(
          Icons.restart_alt_rounded,
          'Back to default (${f.defaultLabel})',
          () => _reset([f.key], '${f.label} is back to its default.'),
        ),
      ],
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          text,
          style: GoogleFonts.poppins(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      );

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: _saving ? null : onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icon, size: 15, color: AppColors.textSecondary),
          ),
        ),
      );

  // The five editors
  /// An unrecognised `type` falls through to a read-only value rather than a
  /// guessed editor: a new server type must be added here deliberately, and until
  /// it is, the admin sees the truth instead of a box that submits the wrong shape.
  Widget _editor(SettingsField f) {
    if (f.isBool) return _boolEditor(f);
    if (f.isSports) return _sportsEditor(f);
    if (f.isNumeric) return _numberEditor(f);
    if (f.type == 'text') return _textEditor(f);
    return Text(
      f.valueLabel,
      style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary),
    );
  }

  Widget _boolEditor(SettingsField f) {
    final on = _effective(f) == true;
    return Row(
      children: [
        Switch(
          value: on,
          activeThumbColor: AppColors.accent,
          onChanged: _saving ? null : (v) => _set(f, v),
        ),
        const SizedBox(width: 6),
        Text(
          on ? 'On' : 'Off',
          style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  /// A number, with the server's `step` on either side of it.
  ///
  /// The steppers exist because most of these are percentages and hour counts that
  /// move by a known increment, and because they clamp to the server's own `min`
  /// and `max` — so the common edit cannot produce a value the server would refuse.
  /// Typing is still allowed, and typing out of range is caught by `_revalidate`
  /// with the server's numbers rather than silently corrected.
  Widget _numberEditor(SettingsField f) {
    final ctl = _controllers.putIfAbsent(f.key, () => TextEditingController());
    final isInt = f.type == 'int';
    final step = f.step ?? (isInt ? 1 : 0.5);
    return Row(
      children: [
        _stepBtn(Icons.remove_rounded, () => _nudge(f, -step)),
        const SizedBox(width: 6),
        SizedBox(
          width: 96,
          child: TextField(
            controller: ctl,
            enabled: !_saving,
            keyboardType: isInt
                ? TextInputType.number
                : const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                isInt ? RegExp(r'[0-9-]') : RegExp(r'[0-9.\-]'),
              ),
            ],
            style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
            decoration: _boxDecoration(f.unit),
            onChanged: (raw) {
              final t = raw.trim();
              if (t.isEmpty) {
                _set(f, null);
                return;
              }
              final n = isInt ? int.tryParse(t) : num.tryParse(t);
              _set(f, n ?? t);
            },
          ),
        ),
        const SizedBox(width: 6),
        _stepBtn(Icons.add_rounded, () => _nudge(f, step)),
        const SizedBox(width: 10),
        if (f.min != null || f.max != null)
          Expanded(
            child: Text(
              _rangeLabel(f),
              style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  /// Move a numeric field by one step, clamped to the server's bounds. A field
  /// that has been typed into something unparseable steps from the saved value,
  /// which is the only number here that is known to be legal.
  void _nudge(SettingsField f, num delta) {
    if (_saving) return;
    final cur = _effective(f);
    final base = cur is num ? cur : (f.value is num ? f.value as num : 0);
    num next = base + delta;
    if (f.min != null && next < f.min!) next = f.min!;
    if (f.max != null && next > f.max!) next = f.max!;
    if (f.type == 'int') next = next.round();
    // Two decimals: a percentage nudged by 0.5 twenty times must not drift into
    // 12.499999999999998 and then fail the server's own bounds check.
    if (next is double) next = num.parse(next.toStringAsFixed(2));
    _controllers[f.key]?.text = _asText(f, next);
    _set(f, next);
  }

  Widget _stepBtn(IconData icon, VoidCallback onTap) => InkWell(
        onTap: _saving ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Icon(icon, size: 16, color: AppColors.textPrimary),
        ),
      );

  InputDecoration _boxDecoration(String? unit) => InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        suffixText: unit,
        suffixStyle: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.accent),
        ),
      );

  String _rangeLabel(SettingsField f) {
    final u = f.unit ?? '';
    if (f.min != null && f.max != null) return 'allowed ${_n(f.min!)}–${_n(f.max!)}$u';
    if (f.min != null) return 'min ${_n(f.min!)}$u';
    return 'max ${_n(f.max!)}$u';
  }

  String _n(num v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

  Widget _textEditor(SettingsField f) {
    final ctl = _controllers.putIfAbsent(f.key, () => TextEditingController());
    return TextField(
      controller: ctl,
      enabled: !_saving,
      maxLength: f.maxLen,
      maxLines: (f.maxLen ?? 0) > 120 ? 3 : 1,
      style: GoogleFonts.poppins(fontSize: 12.5),
      decoration: _boxDecoration(null).copyWith(counterText: ''),
      onChanged: (raw) => _set(f, raw),
    );
  }

  /// The enabled-sports map. Chips rather than a list of switches because the set is
  /// small and the whole point is to see at a glance which sports the platform is
  /// currently taking bookings for.
  ///
  /// Switching one off is the dangerous direction — the server refuses with a 409
  /// and a count when that sport has future confirmed bookings — so the chip stays
  /// tappable and the refusal is shown; guessing here would need a booking count the
  /// screen does not have.
  Widget _sportsEditor(SettingsField f) {
    final cur = _effective(f);
    final map = <String, bool>{
      if (cur is Map)
        for (final e in cur.entries) '${e.key}': e.value == true,
    };
    if (map.isEmpty) {
      return Text(
        'No sports configured.',
        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
      );
    }
    final names = map.keys.toList()..sort();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final name in names)
          FilterChip(
            label: Text(
              name,
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: map[name] == true ? Colors.white : AppColors.textSecondary,
              ),
            ),
            selected: map[name] == true,
            showCheckmark: false,
            backgroundColor: AppColors.background,
            selectedColor: AppColors.accent,
            side: BorderSide(color: AppColors.border),
            onSelected: _saving
                ? null
                : (on) => _set(f, {...map, name: on}),
          ),
      ],
    );
  }

  // Save
  /// The bar only exists while there is a diff, and it refuses to open the confirm
  /// dialog while any field is invalid: the errors are already on screen next to the
  /// fields that caused them, so a disabled button with a count is more useful than
  /// a dialog that the server would reject.
  Widget _saveBar(List<SettingsChange> changes) {
    final invalid = _fieldErrors.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    changes.length == 1 ? '1 change' : '${changes.length} changes',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    invalid == 0
                        ? 'Applies to the next booking, match and payout.'
                        : invalid == 1
                            ? '1 value needs fixing first.'
                            : '$invalid values need fixing first.',
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: invalid == 0 ? AppColors.textSecondary : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _saving ? null : () => setState(_discard),
              child: Text(
                'Discard',
                style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: _saving || invalid > 0 ? null : () => _confirmSave(changes),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      'Save',
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _discard() {
    for (final key in _draft.keys.toList()) {
      final f = _catalog.field(key);
      if (f != null) _controllers[key]?.text = _asText(f, f.value);
    }
    _draft.clear();
    _fieldErrors.clear();
  }

  /// The save-diff confirmation: every change as `label: from → to`, plus the
  /// optional audit note.
  ///
  /// The note is optional here because the server treats it as optional, but it is
  /// asked for on the same screen as the diff because it is the only free-text
  /// record of why a rate changed, and `admin_audit` keeps it next to the before and
  /// after jsonb forever.
  Future<void> _confirmSave(List<SettingsChange> changes) async {
    final noteCtl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Apply these changes?',
          style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final ch in changes) ...[
                _diffLine(ch),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 2),
              Text(
                'These apply to the next operation — no restart, and anything already '
                'confirmed keeps the rate it was booked at.',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtl,
                maxLength: 500,
                maxLines: 2,
                style: GoogleFonts.poppins(fontSize: 12.5),
                decoration: _boxDecoration(null).copyWith(
                  counterText: '',
                  hintText: 'Why (optional — kept in the audit log)',
                  hintStyle: GoogleFonts.poppins(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            child: Text('Apply', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _save(noteCtl.text.trim());
  }

  Widget _diffLine(SettingsChange ch) {
    final f = _catalog.field(ch.key);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: Text(
            ch.label,
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        Expanded(
          flex: 5,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  f?.display(ch.from) ?? '${ch.from}',
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                    decoration: TextDecoration.lineThrough,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_right_alt_rounded, size: 14),
              ),
              Flexible(
                child: Text(
                  f?.display(ch.to) ?? '${ch.to}',
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Send the patch. Only the keys in `_draft` go — a full-catalogue PUT would
  /// rewrite every row as an override the moment anyone opened this screen.
  ///
  /// Three answers matter and each is shown as the server worded it: a 400 carrying
  /// an `errors` array (pinned back onto the fields that caused it, so the admin sees
  /// WHERE not just what), the 409 that names the sport whose future bookings block a
  /// switch-off, and the honest success that says nothing changed.
  Future<void> _save(String note) async {
    final token = _token;
    if (token == null) return;
    final patch = Map<String, dynamic>.from(_draft);
    if (patch.isEmpty) return;

    setState(() => _saving = true);
    final res = await _svc.saveSettings(token, patch, note: note.isEmpty ? null : note);
    if (!mounted) return;
    setState(() => _saving = false);

    final message = (res['message'] ?? '').toString().trim();

    if (res['success'] != true) {
      final errors = res['errors'];
      if (errors is List && errors.isNotEmpty) {
        setState(() {
          for (final e in errors) {
            if (e is Map) {
              final k = '${e['key'] ?? ''}';
              final m = '${e['message'] ?? ''}';
              if (k.isNotEmpty && m.isNotEmpty) _fieldErrors[k] = m;
            }
          }
        });
      }
      SnackbarUtil.showError(
        context,
        message.isEmpty ? 'Those settings were not saved.' : message,
      );
      // The 409 is long — a sport with paid future bookings names each one and its
      // count — so it also gets a dialog it cannot scroll off the bottom of.
      if (res['code'] == 'sport_has_bookings') await _explain('Cannot switch that off', message);
      return;
    }

    // Success, including the "nothing changed" success: re-read so the override
    // chips, the effective values and the text boxes all come from the server.
    await _load();
    if (!mounted) return;
    SnackbarUtil.showSuccess(context, message.isEmpty ? 'Saved.' : message);
  }

  Future<void> _explain(String title, String body) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            title,
            style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: Text(
            body,
            style: GoogleFonts.poppins(fontSize: 12.5, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('OK', style: GoogleFonts.poppins()),
            ),
          ],
        ),
      );

  // Reset
  /// Reset deletes the override row, so the key follows `DEFAULTS` from then on
  /// rather than being frozen at today's number — which is why this is a separate
  /// endpoint and not a save of the default value.
  Future<void> _reset(List<String> keys, String okMessage) async {
    final token = _token;
    if (token == null || keys.isEmpty) return;
    setState(() => _saving = true);
    final res = await _svc.resetSettings(token, keys);
    if (!mounted) return;
    setState(() => _saving = false);
    final message = (res['message'] ?? '').toString().trim();
    if (res['success'] != true) {
      SnackbarUtil.showError(context, message.isEmpty ? 'That reset did not go through.' : message);
      return;
    }
    await _load();
    if (!mounted) return;
    SnackbarUtil.showSuccess(context, message.isEmpty ? okMessage : message);
  }

  Future<void> _resetAll() async {
    final keys = _catalog.overrides;
    if (keys.isEmpty) return;
    final labels = keys.map((k) => _catalog.field(k)?.label ?? k).toList();
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Reset ${keys.length} override${keys.length == 1 ? '' : 's'}?',
          style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              labels.join(', '),
              style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              'Each goes back to its documented default and follows it from then on. '
              'Bookings already confirmed keep the rate they were taken at.',
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: AppColors.textSecondary,
                height: 1.3,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: Text('Reset', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _reset(keys, 'Back to defaults.');
  }
}
