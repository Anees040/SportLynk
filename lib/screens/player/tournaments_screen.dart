import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/tournament.dart';
import '../../providers/auth_provider.dart';
import '../../services/tournament_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/tournament_widgets.dart';
import 'tournament_detail_screen.dart';

/// Browse tournaments, and see the ones I am already in (SRS FE-2, FE-8).
///
/// Two tabs, because they answer two different questions. **Browse** is a shop window
/// filtered the way the SRS asks — sport, city, start date — and everything in it is
/// something a captain could still enter. **My cups** is a status board: what my squads
/// are in, what I am running, and what needs me next.
///
/// The filters are all server-side query parameters rather than a client-side `where`
/// over a downloaded list. That matters beyond tidiness: capacity, the countdown and
/// `registrationOpen` are computed per row by the backend against `now()`, so filtering
/// locally on a cached list would eventually offer a spot that closed an hour ago.
class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({super.key});

  @override
  State<TournamentsScreen> createState() => _TournamentsScreenState();
}

class _TournamentsScreenState extends State<TournamentsScreen>
    with SingleTickerProviderStateMixin {
  final _service = TournamentService();
  final _searchCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();

  late final TabController _tabs = TabController(length: 2, vsync: this);

  List<Tournament> _rows = const [];
  MyTournaments _mine = MyTournaments.empty;
  bool _loading = true;
  bool _mineLoading = true;
  String? _error;

  // Filters (SRS FE-2). `_sport == 'All'` sends nothing at all rather than the word
  // "All", because the server treats an absent parameter as "no filter".
  String _sport = 'All';
  String? _startFrom;
  bool _openOnly = true;

  static const _sports = ['All', 'Football', 'Cricket', 'Futsal', 'Basketball'];

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    _loadMine();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final rows = await _service.browse(
        _token,
        sport: _sport == 'All' ? null : _sport,
        city: _cityCtrl.text,
        q: _searchCtrl.text,
        startFrom: _startFrom,
        openOnly: _openOnly,
        limit: 50,
      );
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// A failed load is said out loud rather than rendered as an empty list, because
  /// "you are not in a tournament yet" and "we could not reach the server" look
  /// identical once the list is empty, and only one of them is true.
  Future<void> _loadMine({bool silent = false}) async {
    if (!silent) setState(() => _mineLoading = true);
    try {
      final mine = await _service.mine(_token, limit: 30);
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _mineLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _mineLoading = false);
      SnackbarUtil.showError(context, 'Could not load your tournaments: $e');
    }
  }

  /// Open one tournament. `autoRegister` opens the register sheet on arrival, so the
  /// Enter button on a card is one tap to the decision instead of two.
  Future<void> _open(Tournament t, {bool autoRegister = false}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TournamentDetailScreen(
          tournamentId: t.id,
          autoRegister: autoRegister,
        ),
      ),
    );
    if (!mounted) return;
    // Coming back from the detail screen, anything could have changed — an entry, a
    // withdrawal, a draw. Both lists are refreshed quietly rather than assuming.
    await Future.wait([_load(silent: true), _loadMine(silent: true)]);
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Starting on or after',
    );
    if (picked == null || !mounted) return;
    setState(() => _startFrom = picked.toIso8601String().substring(0, 10));
    _load();
  }

  // Build

  @override
  Widget build(BuildContext context) {
    final todo = _mine.organiserTodo;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'Tournaments',
          style: GoogleFonts.poppins(
            color: AppColors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: AppColors.white),
        elevation: 0,
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.accent,
          indicatorWeight: 3,
          labelColor: AppColors.white,
          unselectedLabelColor: AppColors.white.withValues(alpha: 0.66),
          labelStyle: GoogleFonts.poppins(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: GoogleFonts.poppins(fontSize: 12.5),
          tabs: [
            const Tab(text: 'Browse'),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('My cups'),
                  // The badge counts only things that need the organiser to act —
                  // entries awaiting approval, a draw that is due, results not in.
                  if (todo > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        '$todo',
                        style: GoogleFonts.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppColors.white,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_browseTab(), _mineTab()],
      ),
    );
  }

  // Browse

  Widget _browseTab() {
    return Column(
      children: [
        _filterBar(),
        Expanded(
          child: _loading
              ? const CustomLoader()
              : _error != null
                  ? TournamentEmpty(
                      icon: Icons.cloud_off,
                      title: 'Could not load tournaments',
                      message: _error!,
                      action: TextButton(
                        onPressed: _load,
                        child: Text(
                          'Try again',
                          style: GoogleFonts.poppins(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    )
                  : _rows.isEmpty
                      ? _noResults()
                      : RefreshIndicator(
                          onRefresh: () => _load(silent: true),
                          color: AppColors.accent,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding:
                                const EdgeInsets.fromLTRB(14, 12, 14, 24),
                            itemCount: _rows.length,
                            itemBuilder: (_, i) => _browseCard(_rows[i]),
                          ),
                        ),
        ),
      ],
    );
  }

  /// A card, plus the one action it is worth having on a list row.
  ///
  /// `canEnter` is derived from server fields only — an open registration, a spot left,
  /// and no entry of my own already. It decides whether to *offer* the button, never
  /// whether the entry is allowed; that answer comes from the register call.
  Widget _browseCard(Tournament t) {
    final entry = t.myEntry;
    final canEnter = t.registrationOpen && !t.isFull && entry == null;
    return Column(
      children: [
        TournamentCard(t, myEntry: entry, onTap: () => _open(t)),
        if (canEnter)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t.requiresApproval
                        ? 'The organiser approves each entry'
                        : 'Spot is yours as soon as you enter',
                    style: GoogleFonts.poppins(
                      fontSize: 10,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _open(t, autoRegister: true),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.how_to_reg, size: 15),
                  label: Text(
                    'Enter',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _noResults() {
    final filtered = _sport != 'All' ||
        _startFrom != null ||
        _cityCtrl.text.trim().isNotEmpty ||
        _searchCtrl.text.trim().isNotEmpty ||
        !_openOnly;
    return TournamentEmpty(
      icon: Icons.emoji_events_outlined,
      title: filtered ? 'Nothing matches that' : 'No tournaments yet',
      message: filtered
          ? 'Try a different sport or city, or clear the filters to see everything '
              'that is open.'
          : 'Venue owners post tournaments here. When one opens, you will be able to '
              'enter a squad and see the bracket as it is drawn.',
      action: filtered
          ? TextButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off, size: 15),
              label: Text(
                'Clear filters',
                style: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            )
          : null,
    );
  }

  void _clearFilters() {
    _searchCtrl.clear();
    _cityCtrl.clear();
    setState(() {
      _sport = 'All';
      _startFrom = null;
      _openOnly = true;
    });
    _load();
  }

  // Filters (SRS FE-2)

  Widget _filterBar() {
    return Container(
      color: AppColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _field(
                  controller: _searchCtrl,
                  hint: 'Search by name or venue',
                  icon: Icons.search,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 116,
                child: _field(
                  controller: _cityCtrl,
                  hint: 'City',
                  icon: Icons.location_on_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                ..._sports.map((s) => _chip(
                      s,
                      selected: _sport == s,
                      onTap: () {
                        setState(() => _sport = s);
                        _load();
                      },
                    )),
                Container(
                  width: 1,
                  height: 22,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: AppColors.border,
                ),
                _chip(
                  _startFrom == null ? 'Any date' : 'From $_startFrom',
                  selected: _startFrom != null,
                  icon: Icons.calendar_today,
                  onTap: _pickStartDate,
                  onClear: _startFrom == null
                      ? null
                      : () {
                          setState(() => _startFrom = null);
                          _load();
                        },
                ),
                _chip(
                  _openOnly ? 'Open only' : 'All statuses',
                  selected: _openOnly,
                  icon: _openOnly ? Icons.lock_open : Icons.all_inclusive,
                  onTap: () {
                    setState(() => _openOnly = !_openOnly);
                    _load();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _load(),
      style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.inputFill,
        prefixIcon: Icon(icon, size: 16, color: AppColors.textSecondary),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 34, minHeight: 34),
        contentPadding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        hintText: hint,
        hintStyle:
            GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 14),
                color: AppColors.textSecondary,
                onPressed: () {
                  controller.clear();
                  _load();
                },
              ),
      ),
    );
  }

  Widget _chip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
    VoidCallback? onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.background,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 12,
                  color: selected ? AppColors.white : AppColors.textSecondary,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? AppColors.white : AppColors.textSecondary,
                ),
              ),
              if (onClear != null) ...[
                const SizedBox(width: 5),
                GestureDetector(
                  onTap: onClear,
                  child: const Icon(Icons.close, size: 12, color: AppColors.white),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // My cups

  /// The two roles in one list, organiser first.
  ///
  /// An owner who is also a captain sees both sections; most people see one. The
  /// organiser section is first because it is the only one where somebody is waiting on
  /// *this* user — an unapproved entry holds a captain's money frozen until it is
  /// answered.
  Widget _mineTab() {
    if (_mineLoading) return const CustomLoader();
    if (_mine.isEmpty) {
      return TournamentEmpty(
        icon: Icons.emoji_events_outlined,
        title: 'You are not in a tournament yet',
        message: 'Enter one from the Browse tab and it will show up here, with your '
            'seed, your next match and how the prize money is split.',
        action: TextButton.icon(
          onPressed: () => _tabs.animateTo(0),
          icon: const Icon(Icons.search, size: 15),
          label: Text(
            'Browse tournaments',
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: TextButton.styleFrom(foregroundColor: AppColors.accent),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadMine(silent: true),
      color: AppColors.accent,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          if (_mine.organising.isNotEmpty) ...[
            _sectionHeader(
              'Running',
              '${_mine.organising.length}',
              Icons.admin_panel_settings_outlined,
            ),
            const SizedBox(height: 10),
            ..._mine.organising.map(
              (t) => TournamentCard(t, onTap: () => _open(t)),
            ),
          ],
          if (_mine.playing.isNotEmpty) ...[
            if (_mine.organising.isNotEmpty) const SizedBox(height: 8),
            _sectionHeader(
              'My squads are in',
              '${_mine.playing.length}',
              Icons.groups_outlined,
            ),
            const SizedBox(height: 10),
            ..._mine.playing.map(
              (t) => TournamentCard(t, myEntry: t.myEntry, onTap: () => _open(t)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, String count, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.primary),
        const SizedBox(width: 7),
        Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.inputFill,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            count,
            style: GoogleFonts.poppins(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
