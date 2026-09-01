import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/assistant.dart' show formatPkr;
import '../../models/tournament.dart';
import '../../providers/auth_provider.dart';
import '../../services/tournament_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/custom_loader.dart';
import '../../widgets/tournament_widgets.dart';
import '../player/tournament_detail_screen.dart';
import 'owner_create_tournament_screen.dart';

/// The tournaments I am running (SRS FE-1, FE-5, FE-6, FE-7).
///
/// Deliberately a list and not a second management console. Every action an organiser
/// has — approve, reject, remove and refund, draw the bracket, enter a result, record a
/// walkover, cancel — already lives on the tournament detail screen, which shows those
/// controls to whoever the server says is the organiser. Rebuilding them here would mean
/// two copies of the same money-touching confirmations drifting apart.
///
/// What this screen adds is triage: which of my tournaments is waiting on *me*, and how
/// much each one has earned. The rest is one tap away.
class OwnerTournamentsScreen extends StatefulWidget {
  const OwnerTournamentsScreen({super.key});

  @override
  State<OwnerTournamentsScreen> createState() => _OwnerTournamentsScreenState();
}

class _OwnerTournamentsScreenState extends State<OwnerTournamentsScreen> {
  final _service = TournamentService();

  MyTournaments _mine = MyTournaments.empty;
  bool _loading = true;
  String? _error;

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final mine = await _service.mine(_token, limit: 50);
      if (!mounted) return;
      setState(() {
        _mine = mine;
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

  Future<void> _open(Tournament t) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TournamentDetailScreen(tournamentId: t.id),
      ),
    );
    if (!mounted) return;
    await _load(silent: true);
  }

  Future<void> _create() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const OwnerCreateTournamentScreen()),
    );
    if (!mounted) return;
    if (created == true) {
      SnackbarUtil.showSuccess(context, 'Tournament posted — captains can enter now.');
    }
    await _load(silent: true);
  }

  // Build

  @override
  Widget build(BuildContext context) {
    final rows = _mine.organising;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'My tournaments',
          style: GoogleFonts.poppins(
            color: AppColors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: AppColors.white),
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add, size: 19),
        label: Text(
          'New tournament',
          style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
      ),
      body: _loading
          ? const CustomLoader()
          : _error != null
              ? TournamentEmpty(
                  icon: Icons.cloud_off,
                  title: 'Could not load your tournaments',
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
              : rows.isEmpty
                  ? TournamentEmpty(
                      icon: Icons.emoji_events_outlined,
                      title: 'No tournaments yet',
                      message: 'A tournament fills hours you would struggle to sell one '
                          'booking at a time, and you keep the venue cost plus a margin '
                          'off the top. Post one and see the numbers before you commit.',
                      action: TextButton.icon(
                        onPressed: _create,
                        icon: const Icon(Icons.add, size: 15),
                        label: Text(
                          'Post your first one',
                          style: GoogleFonts.poppins(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.accent,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _load(silent: true),
                      color: AppColors.accent,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
                        children: [
                          _earningsStrip(rows),
                          const SizedBox(height: 14),
                          ...rows.map(_row),
                        ],
                      ),
                    ),
    );
  }

  /// A one-line answer to "is this worth running".
  ///
  /// Only settled tournaments are counted, because an in-progress one has money frozen
  /// rather than earned and adding it would overstate the total.
  Widget _earningsStrip(List<Tournament> rows) {
    final settled = rows.where((t) => t.isCompleted).toList();
    final earned = settled.fold<double>(0, (sum, t) => sum + t.ownerEarning);
    final hours = settled.fold<double>(0, (sum, t) => sum + t.venueCost);
    final live = rows.where((t) => t.isOpen || t.isActive).length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, Color(0xFF166534)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Earned from finished tournaments',
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              color: AppColors.white.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            formatPkr(earned),
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            settled.isEmpty
                ? '$live live · nothing has settled yet'
                : '${settled.length} settled · ${formatPkr(hours)} of that covered your '
                    'venue hours · $live live',
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              height: 1.4,
              color: AppColors.white.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }

  /// One tournament, plus the sentence saying what it wants from me.
  ///
  /// The card itself is the same `TournamentCard` captains see, so an owner is never
  /// looking at a different set of facts about their own tournament than the teams are.
  Widget _row(Tournament t) {
    final todo = _todo(t);
    return Column(
      children: [
        TournamentCard(t, onTap: () => _open(t)),
        if (todo != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: GestureDetector(
              onTap: () => _open(t),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: todo.color.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: todo.color.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(todo.icon, size: 14, color: todo.color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        todo.text,
                        style: GoogleFonts.poppins(
                          fontSize: 10.5,
                          height: 1.45,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 16, color: todo.color),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// What this tournament needs next, in priority order.
  ///
  /// Derived from the list payload's own counters, so nothing here is a guess about
  /// server state — and when there is nothing to do the strip is simply absent rather
  /// than saying "all good", which would be noise on every row.
  _Todo? _todo(Tournament t) {
    if (t.isCancelled) return null;
    if (t.teamsPending > 0) {
      return _Todo(
        '${t.teamsPending} ${t.teamsPending == 1 ? 'team is' : 'teams are'} waiting for '
            'your decision — their fees are held until you answer',
        Icons.how_to_reg,
        AppColors.warning,
      );
    }
    final secs = t.secondsToDeadline;
    if (!t.hasBracket && secs != null && secs <= 0) {
      return t.teamsAccepted < t.minTeams
          ? _Todo(
              'The deadline passed with ${t.teamsAccepted} of ${t.minTeams} teams — this '
                  'will be cancelled and every fee refunded',
              Icons.block,
              AppColors.error,
            )
          : _Todo(
              'The deadline has passed with ${t.teamsAccepted} teams — draw the bracket '
                  'to start play',
              Icons.account_tree,
              AppColors.accent,
            );
    }
    if (t.isActive) {
      return _Todo(
        'In progress — enter results as matches are played, or verify the scores '
            'captains submit',
        Icons.scoreboard_outlined,
        AppColors.accent,
      );
    }
    if (t.isCompleted && t.winnerName != null) {
      return _Todo(
        '${t.winnerName} won it. You earned ${formatPkr(t.ownerEarning)}',
        Icons.emoji_events,
        AppColors.success,
      );
    }
    return null;
  }
}

/// One line of "this needs you", with the colour that says how badly.
class _Todo {
  final String text;
  final IconData icon;
  final Color color;
  const _Todo(this.text, this.icon, this.color);
}
