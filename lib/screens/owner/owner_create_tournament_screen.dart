import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/api_constants.dart';
import '../../constants/colors.dart';
import '../../models/assistant.dart' show formatPkr;
import '../../models/tournament.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/tournament_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/tournament_widgets.dart';

/// Post a tournament at one of my venues, with the economics shown before I commit
/// (SRS FE-1).
///
/// The point of this screen is the panel at the bottom. A venue owner setting an entry
/// fee is making a bet with fixed costs and a variable pool: eight teams at PKR 2,000
/// is a 16,000 pool, but a seven-match knockout eats seven hours of inventory that might
/// have sold for 14,000. Guess the fee wrong and the tournament earns less than simply
/// selling the slots — which would make the whole feature pointless.
///
/// So every edit re-quotes `POST /tournaments/preview`, which reads the venue's real
/// slot prices, and the panel says in rupees what this configuration pays versus what
/// those same hours would fetch sold one by one. The recommended fee is one tap away.
/// Nothing here is computed on the phone.
class OwnerCreateTournamentScreen extends StatefulWidget {
  /// Pre-selects a venue when the screen is opened from that venue's own page.
  final String? venueId;

  const OwnerCreateTournamentScreen({super.key, this.venueId});

  @override
  State<OwnerCreateTournamentScreen> createState() =>
      _OwnerCreateTournamentScreenState();
}

class _OwnerCreateTournamentScreenState
    extends State<OwnerCreateTournamentScreen> {
  final _service = TournamentService();
  final _api = ApiClient();

  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _feeCtrl = TextEditingController();

  List<Map<String, dynamic>> _venues = const [];
  String? _venueId;
  bool _loadingVenues = true;

  String _sport = 'Football';
  String _format = TournamentFormat.knockout;
  int _maxTeams = 8;
  int _minTeams = 4;
  int _slotMinutes = 60;
  int _prizePercent = 60;
  int _winnerPercent = 70;
  int _venueDiscountPercent = 0;
  bool _requiresApproval = false;
  DateTime? _deadline;
  DateTime? _startDate;

  TournamentPreview? _preview;
  bool _quoting = false;
  String? _quoteError;
  Timer? _debounce;
  bool _creating = false;

  static const _sports = ['Football', 'Futsal', 'Cricket', 'Basketball'];

  /// Round-robin is capped at 6 because `n(n−1)/2` fixtures is 15 hours of venue at
  /// six teams and 28 at eight — the server enforces this, and offering 8 here would
  /// only produce a refusal.
  int get _maxTeamsCeiling =>
      _format == TournamentFormat.roundRobin ? 6 : 16;

  List<int> get _teamChoices => _format == TournamentFormat.knockout
      ? const [4, 8, 16]
      : const [4, 5, 6];

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    _venueId = widget.venueId;
    _deadline = DateTime.now().add(const Duration(days: 7));
    _loadVenues();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _feeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadVenues() async {
    try {
      final r = await _api.get(ApiConstants.ownerVenues, token: _token);
      if (!mounted) return;
      final rows = r['data'];
      final list = rows is List
          ? rows.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
          : <Map<String, dynamic>>[];
      setState(() {
        _venues = list;
        _venueId ??= list.isEmpty ? null : '${list.first['id']}';
        _loadingVenues = false;
        final v = list.firstWhere(
          (x) => '${x['id']}' == _venueId,
          orElse: () => const {},
        );
        if (v['sport'] != null) _sport = '${v['sport']}';
      });
      _quote();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingVenues = false);
      SnackbarUtil.showError(context, 'Could not load your venues: $e');
    }
  }

  // ── The quote ──────────────────────────────────────────────

  /// Re-quote after a short pause.
  ///
  /// Debounced because the preview is a real round trip that hits the venue's slot
  /// table and, when ml-service is up, the demand model — firing it on every keystroke
  /// of the fee field would be a request per digit.
  void _scheduleQuote() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 550), _quote);
  }

  Future<void> _quote() async {
    final venueId = _venueId;
    if (venueId == null || venueId.isEmpty) return;
    setState(() {
      _quoting = true;
      _quoteError = null;
    });
    try {
      final p = await _service.preview(
        _token,
        venueId: venueId,
        name: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
        format: _format,
        maxTeams: _maxTeams,
        minTeams: _minTeams,
        entryFee: double.tryParse(_feeCtrl.text.trim()),
        prizePercent: _prizePercent,
        winnerPercent: _winnerPercent,
        runnerupPercent: 100 - _winnerPercent,
        venueDiscountPercent: _venueDiscountPercent,
        slotMinutes: _slotMinutes,
        registrationDeadline: _deadline?.toUtc().toIso8601String(),
        startDate: _startDate?.toIso8601String().substring(0, 10),
      );
      if (!mounted) return;
      setState(() {
        _preview = p;
        _quoting = false;
        _quoteError = p == null ? 'Could not price this configuration.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _quoting = false;
        _quoteError = '$e';
      });
    }
  }

  /// Take the server's recommended fee.
  ///
  /// Computed as `(venue cost + target margin) / min teams`, so it is the smallest fee
  /// that still clears the inventory cost at the *worst* turnout rather than the best —
  /// which is the number an owner actually needs.
  void _useRecommendedFee() {
    final rec = _preview?.recommended;
    if (rec == null || rec.entryFee <= 0) return;
    _feeCtrl.text = rec.entryFee.toStringAsFixed(0);
    _quote();
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _deadline ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 180)),
      helpText: 'Registration closes on',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 20, minute: 0),
      helpText: 'Registration closes at',
    );
    if (!mounted) return;
    setState(() {
      _deadline = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? 20,
        time?.minute ?? 0,
      );
    });
    _quote();
  }

  Future<void> _pickStartDate() async {
    final base = _deadline ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _startDate ?? base.add(const Duration(days: 1)),
      firstDate: base,
      lastDate: base.add(const Duration(days: 365)),
      helpText: 'First match on or after',
    );
    if (date == null || !mounted) return;
    setState(() => _startDate = date);
    _quote();
  }

  // ── Create ─────────────────────────────────────────────────

  String? _localBlocker() {
    if (_venueId == null || _venueId!.isEmpty) return 'Pick one of your venues';
    if (_nameCtrl.text.trim().length < 3) return 'Give the tournament a name';
    final fee = double.tryParse(_feeCtrl.text.trim());
    if (fee == null || fee <= 0) return 'Set an entry fee';
    if (_deadline == null) return 'Set a registration deadline';
    if (!_deadline!.isAfter(DateTime.now())) {
      return 'The deadline has to be in the future';
    }
    return null;
  }

  Future<void> _create() async {
    final local = _localBlocker();
    if (local != null) {
      SnackbarUtil.showInfo(context, local);
      return;
    }
    final p = _preview;
    if (p != null && p.blocker != null) {
      SnackbarUtil.showError(context, p.blocker!);
      return;
    }
    final confirmed = await _confirmCreate();
    if (!confirmed || !mounted) return;

    setState(() => _creating = true);
    final r = await _service.create(
      _token,
      venueId: _venueId!,
      name: _nameCtrl.text.trim(),
      entryFee: double.parse(_feeCtrl.text.trim()),
      maxTeams: _maxTeams,
      registrationDeadline: _deadline!.toUtc().toIso8601String(),
      description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      sport: _sport,
      format: _format,
      minTeams: _minTeams,
      prizePercent: _prizePercent,
      winnerPercent: _winnerPercent,
      runnerupPercent: 100 - _winnerPercent,
      venueDiscountPercent: _venueDiscountPercent,
      slotMinutes: _slotMinutes,
      requiresApproval: _requiresApproval,
      startDate: _startDate?.toIso8601String().substring(0, 10),
    );
    if (!mounted) return;
    setState(() => _creating = false);
    final message = '${r['message'] ?? ''}';
    if (r['success'] == true) {
      SnackbarUtil.showSuccess(
        context,
        message.isEmpty ? 'Tournament posted.' : message,
      );
      Navigator.pop(context, true);
    } else {
      SnackbarUtil.showError(
        context,
        message.isEmpty ? 'Could not post the tournament.' : message,
      );
    }
  }

  /// The last look before the tournament exists.
  ///
  /// It quotes the figures back rather than saying "are you sure", because the thing
  /// worth checking is not the intent but the arithmetic — an owner who mis-set the fee
  /// finds out here rather than at the draw.
  Future<bool> _confirmCreate() async {
    final p = _preview;
    final e = p?.atCapacity;
    final lines = <String>[
      '${_maxTeams == _minTeams ? '$_maxTeams' : '$_minTeams–$_maxTeams'} teams · '
          '${TournamentFormat.label(_format)} · $_sport',
      'Entry fee ${formatPkr(double.tryParse(_feeCtrl.text.trim()) ?? 0)} per team',
      if (e != null)
        'At a full field you earn ${formatPkr(e.ownerEarning)}, of which '
            '${formatPkr(e.venueCost)} covers the venue hours',
      if (e != null && e.prize > 0)
        'Prize pool ${formatPkr(e.prize)} — champion ${formatPkr(e.winnerShare)}, '
            'runner-up ${formatPkr(e.runnerupShare)}',
      if (p != null && p.capacity.hoursNeeded > 0)
        '${p.capacity.hoursNeeded} venue hours get reserved for fixtures and cannot be '
            'sold separately',
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Post this tournament?',
          style: GoogleFonts.poppins(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines
              .map((l) => Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 4, right: 7),
                          child: Icon(Icons.check, size: 12,
                              color: AppColors.accent),
                        ),
                        Expanded(
                          child: Text(
                            l,
                            style: GoogleFonts.poppins(
                              fontSize: 11.5,
                              height: 1.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Keep editing',
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              'Post it',
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ── Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'New tournament',
          style: GoogleFonts.poppins(
            color: AppColors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: AppColors.white),
        elevation: 0,
      ),
      body: _loadingVenues
          ? const CustomLoader()
          : _venues.isEmpty
              ? TournamentEmpty(
                  icon: Icons.stadium_outlined,
                  title: 'You need a venue first',
                  message: 'Tournaments run on your own slots, so add a venue and open '
                      'some hours before posting one.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                  children: [
                    _card('Where', [_venuePicker(), _sportPicker()]),
                    const SizedBox(height: 12),
                    _card('What', [
                      _text(_nameCtrl, 'Tournament name',
                          hint: 'Ramadan Futsal Cup 2026', onChanged: _scheduleQuote),
                      const SizedBox(height: 10),
                      _text(_descCtrl, 'Description (optional)',
                          hint: 'Rules, kit, anything captains should know',
                          lines: 3),
                    ]),
                    const SizedBox(height: 12),
                    _card('Format', [
                      _formatPicker(),
                      const SizedBox(height: 12),
                      _teamsPicker(),
                      const SizedBox(height: 12),
                      _slotPicker(),
                    ]),
                    const SizedBox(height: 12),
                    _card('Money', [
                      _feeField(),
                      const SizedBox(height: 12),
                      _percentSlider(
                        'Prize pool',
                        _prizePercent,
                        'of the surplus after the venue hours are paid for',
                        (v) => setState(() => _prizePercent = v),
                      ),
                      _percentSlider(
                        'Champion',
                        _winnerPercent,
                        'of the prize pool — runner-up takes '
                            '${100 - _winnerPercent}%',
                        (v) => setState(() => _winnerPercent = v),
                        min: 50,
                      ),
                      _percentSlider(
                        'Your discount on your own slots',
                        _venueDiscountPercent,
                        'lowers the entry fee teams have to pay',
                        (v) => setState(() => _venueDiscountPercent = v),
                        max: 50,
                      ),
                    ]),
                    const SizedBox(height: 12),
                    _card('When', [_deadlineRow(), _startRow(), _approvalRow()]),
                    const SizedBox(height: 12),
                    _economicsPanel(),
                    const SizedBox(height: 16),
                    _createButton(),
                  ],
                ),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 11),
          ...children,
        ],
      ),
    );
  }

  Widget _createButton() {
    final blocker = _localBlocker() ?? _preview?.blocker;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: blocker != null || _creating ? null : _create,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.white,
              disabledBackgroundColor: AppColors.disabled,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: _creating
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppColors.white),
                    ),
                  )
                : const Icon(Icons.emoji_events, size: 17),
            label: Text(
              _creating ? 'Posting…' : 'Post tournament',
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (blocker != null) ...[
          const SizedBox(height: 8),
          Text(
            blocker,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              color: AppColors.error,
            ),
          ),
        ],
      ],
    );
  }

  // ── Fields ─────────────────────────────────────────────────

  Widget _venuePicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String>(
        initialValue: _venueId,
        isExpanded: true,
        decoration: _decoration('Venue'),
        style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary),
        items: _venues
            .map((v) => DropdownMenuItem(
                  value: '${v['id']}',
                  child: Text(
                    '${v['name']}${v['city'] == null ? '' : ' · ${v['city']}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
            .toList(),
        onChanged: (v) {
          if (v == null) return;
          final row = _venues.firstWhere(
            (x) => '${x['id']}' == v,
            orElse: () => const {},
          );
          setState(() {
            _venueId = v;
            if (row['sport'] != null) _sport = '${row['sport']}';
          });
          _quote();
        },
      ),
    );
  }

  Widget _sportPicker() {
    final options = {..._sports, _sport}.toList();
    return DropdownButtonFormField<String>(
      initialValue: _sport,
      isExpanded: true,
      decoration: _decoration('Sport'),
      style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary),
      items: options
          .map((s) => DropdownMenuItem(value: s, child: Text(s)))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _sport = v);
      },
    );
  }

  Widget _formatPicker() {
    return Row(
      children: [
        _seg('Knockout', TournamentFormat.knockout),
        const SizedBox(width: 8),
        _seg('Round-robin', TournamentFormat.roundRobin),
      ],
    );
  }

  Widget _seg(String label, String value) {
    final selected = _format == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _format = value;
            if (_maxTeams > _maxTeamsCeiling) _maxTeams = _maxTeamsCeiling;
            if (!_teamChoices.contains(_maxTeams)) {
              _maxTeams = _teamChoices.last;
            }
            if (_minTeams > _maxTeams) _minTeams = _maxTeams;
          });
          _quote();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.inputFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? AppColors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _teamsPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Teams',
          style: GoogleFonts.poppins(
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _maxTeams,
                decoration: _decoration('Maximum'),
                style: GoogleFonts.poppins(
                    fontSize: 12.5, color: AppColors.textPrimary),
                items: _teamChoices
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _maxTeams = v;
                    if (_minTeams > v) _minTeams = v;
                  });
                  _quote();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _minTeams,
                decoration: _decoration('Minimum'),
                style: GoogleFonts.poppins(
                    fontSize: 12.5, color: AppColors.textPrimary),
                items: [2, 3, 4, 5, 6, 8]
                    .where((n) => n <= _maxTeams)
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _minTeams = v);
                  _quote();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _format == TournamentFormat.knockout
              ? 'A knockout bracket has to be a power of two, so anything short of the '
                  'maximum gives the top seeds a bye. Below the minimum the tournament '
                  'is cancelled and every fee refunded.'
              : 'Round-robin plays ${_maxTeams * (_maxTeams - 1) ~/ 2} matches at '
                  '$_maxTeams teams — every one of them takes an hour of your venue, '
                  'which is why it is capped at 6.',
          style: GoogleFonts.poppins(
            fontSize: 10,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  InputDecoration _decoration(String label) => InputDecoration(
        labelText: label,
        labelStyle:
            GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
        isDense: true,
        filled: true,
        fillColor: AppColors.inputFill,
        contentPadding:
            const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );

  Widget _slotPicker() {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Each match takes',
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        ...[60, 90, 120].map((m) {
          final selected = _slotMinutes == m;
          return Padding(
            padding: const EdgeInsets.only(left: 7),
            child: GestureDetector(
              onTap: () {
                setState(() => _slotMinutes = m);
                _quote();
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? AppColors.accent : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${m}m',
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color:
                        selected ? AppColors.white : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _text(
    TextEditingController ctrl,
    String label, {
    String? hint,
    int lines = 1,
    VoidCallback? onChanged,
  }) {
    return TextField(
      controller: ctrl,
      maxLines: lines,
      onChanged: onChanged == null ? null : (_) => onChanged(),
      style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary),
      decoration: _decoration(label).copyWith(
        hintText: hint,
        hintStyle:
            GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _feeField() {
    final rec = _preview?.recommended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _feeCtrl,
          keyboardType: TextInputType.number,
          onChanged: (_) => _scheduleQuote(),
          style: GoogleFonts.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
          decoration: _decoration('Entry fee per team (PKR)').copyWith(
            prefixText: 'PKR  ',
            prefixStyle: GoogleFonts.poppins(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        if (rec != null && rec.entryFee > 0) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _useRecommendedFee,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.accentLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome,
                      size: 14, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Suggested: ${formatPkr(rec.entryFee)} per team',
                          style: GoogleFonts.poppins(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          rec.achievable
                              ? 'Covers ${formatPkr(rec.venueCost)} of venue hours plus '
                                  'a ${rec.targetMarginPercent}% margin even if only '
                                  '${rec.minTeams} teams turn up'
                              : 'Even at this fee ${rec.minTeams} teams would not cover '
                                  '${formatPkr(rec.venueCost)} of venue hours — raise it '
                                  'or shorten the tournament',
                          style: GoogleFonts.poppins(
                            fontSize: 9.5,
                            height: 1.4,
                            color: rec.achievable
                                ? AppColors.textSecondary
                                : AppColors.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Use',
                    style: GoogleFonts.poppins(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _percentSlider(
    String label,
    int value,
    String note,
    ValueChanged<int> onChanged, {
    int min = 0,
    int max = 100,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                '$value%',
                style: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.border,
              thumbColor: AppColors.accent,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: (max - min) ~/ 5,
              onChanged: (v) => onChanged(v.round()),
              onChangeEnd: (_) => _quote(),
            ),
          ),
          Text(
            note,
            style: GoogleFonts.poppins(
              fontSize: 9.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _deadlineRow() => _pickRow(
        icon: Icons.timer_outlined,
        label: 'Registration closes',
        value: _deadline == null
            ? 'Pick a date and time'
            : _prettyDateTime(_deadline!),
        note: 'The bracket is drawn automatically at this moment, on whoever has '
            'entered by then.',
        onTap: _pickDeadline,
      );

  Widget _startRow() => _pickRow(
        icon: Icons.event_outlined,
        label: 'First match on or after',
        value: _startDate == null
            ? 'As soon as possible after the deadline'
            : _prettyDate(_startDate!),
        note: 'Leave this alone and fixtures take the earliest suitable hours.',
        onTap: _pickStartDate,
        onClear: _startDate == null
            ? null
            : () {
                setState(() => _startDate = null);
                _quote();
              },
      );

  Widget _pickRow({
    required IconData icon,
    required String label,
    required String value,
    required String note,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: GoogleFonts.poppins(
                          fontSize: 10.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Text(
                        value,
                        style: GoogleFonts.poppins(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onClear != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 15),
                    color: AppColors.textSecondary,
                    onPressed: onClear,
                  )
                else
                  const Icon(Icons.edit_calendar_outlined,
                      size: 15, color: AppColors.textSecondary),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              note,
              style: GoogleFonts.poppins(
                fontSize: 9.5,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _approvalRow() {
    return SwitchListTile.adaptive(
      value: _requiresApproval,
      onChanged: (v) => setState(() => _requiresApproval = v),
      dense: true,
      contentPadding: EdgeInsets.zero,
      activeThumbColor: AppColors.accent,
      title: Text(
        'I approve each entry',
        style: GoogleFonts.poppins(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        _requiresApproval
            ? 'Fees are held until you accept. Anything still unanswered at the '
                'deadline is refunded automatically.'
            : 'Teams take a spot the moment they pay, first come first served.',
        style: GoogleFonts.poppins(
          fontSize: 9.5,
          height: 1.4,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  String _prettyDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  String _prettyDateTime(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '${_prettyDate(d)}, $h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  // ── The economics panel (the reason this screen exists) ─────

  Widget _economicsPanel() {
    final p = _preview;
    if (_quoting && p == null) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 30),
        alignment: Alignment.center,
        child: const CustomLoader(size: 34),
      );
    }
    if (p == null) {
      return TournamentWarning(
        _quoteError ??
            'Fill in the venue and the entry fee to see what this tournament earns.',
        icon: Icons.calculate_outlined,
        color: _quoteError == null ? AppColors.accent : AppColors.error,
      );
    }
    final full = p.atCapacity;
    final low = p.atMinimum;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.query_stats, size: 16, color: AppColors.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'What this pays you',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (_quoting)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Priced against this venue’s real slot prices, not an estimate.',
            style: GoogleFonts.poppins(
              fontSize: 10,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          PrizeBreakdownCard(full, showOwnerView: true),
          const SizedBox(height: 10),
          OwnerUpliftNote(full),
          const SizedBox(height: 12),
          _turnoutRow(full, low, p),
          if (p.capacity.hoursNeeded > 0) ...[
            const SizedBox(height: 12),
            _hoursRow(p),
          ],
          if (p.scheduling.source.isNotEmpty) ...[
            const SizedBox(height: 12),
            SchedulingNote(p.scheduling),
          ],
          if (p.cappedByHours) ...[
            const SizedBox(height: 10),
            TournamentWarning(
              'There are enough open hours for ${p.minimum.teams} teams but not for a '
              'full field of ${p.capacity.teams}. '
              '${p.capacity.shortfall?.line ?? 'Open more slots'} — the tournament can '
              'still run, it just cannot fill.',
            ),
          ],
          if (p.blocker != null) ...[
            const SizedBox(height: 10),
            TournamentWarning(p.blocker!, color: AppColors.error),
          ],
        ],
      ),
    );
  }

  /// Best case and worst case side by side.
  ///
  /// An owner who only sees the full-field number is reading the optimistic half of the
  /// bet. The minimum-field column is the one that decides whether the fee is safe,
  /// because it is what happens if only the minimum turn up — and it is exactly the
  /// figure the recommended fee is solved against.
  Widget _turnoutRow(Economics full, Economics low, TournamentPreview p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'If turnout is…',
          style: GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _turnoutBox('${p.minimum.teams} teams', 'the minimum', low),
            ),
            const SizedBox(width: 8),
            Expanded(
              child:
                  _turnoutBox('${p.capacity.teams} teams', 'a full field', full),
            ),
          ],
        ),
      ],
    );
  }

  Widget _turnoutBox(String title, String note, Economics e) {
    final underwater = e.isUnderwater;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: underwater
            ? AppColors.error.withValues(alpha: 0.07)
            : AppColors.inputFill,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: underwater
              ? AppColors.error.withValues(alpha: 0.4)
              : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            note,
            style: GoogleFonts.poppins(
              fontSize: 9,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            formatPkr(e.ownerEarning),
            style: GoogleFonts.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: underwater ? AppColors.error : AppColors.success,
            ),
          ),
          Text(
            underwater
                ? 'pool does not cover the hours — no prize, you keep it all'
                : 'to you, prize ${formatPkr(e.prize)}',
            style: GoogleFonts.poppins(
              fontSize: 9,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Which hours this would consume, and which windows the scheduler picked them from.
  ///
  /// The per-round `pickLabel` is the visible half of the demand model's decision: early
  /// rounds land in off-peak hours the venue struggles to sell, and the final takes a
  /// peak window for the crowd. Since the venue cost is the sum of those slots' own
  /// prices, that placement is what makes the entry fee affordable.
  Widget _hoursRow(TournamentPreview p) {
    final plan = p.capacity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.schedule, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '${plan.fixtures} matches over ${plan.hoursNeeded} of your hours '
                '(${p.candidateHours} open in the window)',
                style: GoogleFonts.poppins(
                  fontSize: 10.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (plan.rounds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: plan.rounds
                .map((r) => Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.inputFill,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${r.label}: ${r.count}×'
                        '${r.pickLabel.isEmpty ? '' : ' ${r.pickLabel}'}'
                        '${r.date == null ? '' : ' · ${r.date}'}',
                        style: GoogleFonts.poppins(
                          fontSize: 9.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ))
                .toList(),
          ),
        ],
      ],
    );
  }
}
