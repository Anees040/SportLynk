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
import '../../widgets/match_widgets.dart' show TeamCrest;
import '../../widgets/tournament_widgets.dart';

/// One tournament, for everybody (SRS FE-3, FE-5, FE-6, FE-7, FE-8).
///
/// The same five tabs serve a passer-by, an entered captain and the organiser. What
/// changes is the actions: the server sends `viewer` and, for the organiser only, an
/// `organiser` block, and this screen offers exactly the buttons those blocks permit.
/// It never decides permission itself — `canRegister`, `canWithdraw` and `canGenerate`
/// are the server's answers, re-checked inside a locked transaction when the button is
/// pressed, so the worst a stale screen can do is offer an action that then refuses
/// politely.
///
/// Every refusal is printed verbatim. In this module a failure is usually a RULE and
/// not a fault — "the last spot went while you were deciding", "you are PKR 1,200
/// short", "round 2 needs 4 hours and the venue has 3" — and paraphrasing those into
/// "Something went wrong" would leave a captain tapping a button that will never work.
class TournamentDetailScreen extends StatefulWidget {
  final String tournamentId;

  /// Set when the caller already knows the user wants to enter — the browse list's
  /// Enter button — so the register sheet opens on arrival instead of making them
  /// hunt for the same button again.
  final bool autoRegister;

  const TournamentDetailScreen({
    super.key,
    required this.tournamentId,
    this.autoRegister = false,
  });

  @override
  State<TournamentDetailScreen> createState() => _TournamentDetailScreenState();
}

class _TournamentDetailScreenState extends State<TournamentDetailScreen>
    with SingleTickerProviderStateMixin {
  final _service = TournamentService();

  TournamentDetail _detail = TournamentDetail.empty;
  bool _loading = true;
  String? _error;

  /// Ids of in-flight actions. One membership test guards every button, so a second
  /// tap on Approve cannot fire a second refund while the first is still travelling.
  final _busy = <String>{};

  late final TabController _tabs = TabController(length: 5, vsync: this);

  String get _token => context.read<AuthProvider>().token ?? '';

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (widget.autoRegister && mounted) _register();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final raw = await _service.detailRaw(_token, widget.tournamentId);
    if (!mounted) return;
    final ok = raw['success'] == true && raw['data'] is Map;
    setState(() {
      _loading = false;
      _error = ok ? null : '${raw['message'] ?? 'Could not load this tournament'}';
      if (ok) {
        _detail = TournamentDetail.fromJson(
          Map<String, dynamic>.from(raw['data'] as Map),
        );
      }
    });
  }

  // ---- Actions -------------------------------------------------

  /// Runs one mutation, shows the server's own sentence either way, and reloads.
  ///
  /// Every action in this module goes through here so that no screen ever invents a
  /// success message: a register that was refused because the last spot went and a
  /// register that was refused because the wallet is short read differently, and both
  /// sentences come from the transaction that made the decision.
  Future<void> _run(
    String key,
    Future<Map<String, dynamic>> Function() call, {
    String? fallbackSuccess,
  }) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    final r = await call();
    if (!mounted) return;
    setState(() => _busy.remove(key));
    final ok = r['success'] == true;
    final message = '${r['message'] ?? (ok ? fallbackSuccess ?? 'Done' : 'That did not work')}';
    if (ok) {
      SnackbarUtil.showSuccess(context, message);
    } else {
      SnackbarUtil.showError(context, message);
    }
    await _load(silent: true);
  }

  Future<void> _register() async {
    final t = _detail.tournament;
    final viewer = _detail.viewer;
    if (t == null) return;
    if (viewer.eligibleTeams.isEmpty) {
      SnackbarUtil.showInfo(
        context,
        viewer.isCaptain
            ? 'None of your teams can enter this one - check the sport and whether '
                'they are already registered.'
            : 'Only a team captain can enter a tournament. Create a team first.',
      );
      return;
    }
    final teamId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RegisterSheet(
        tournament: t,
        viewer: viewer,
        economics: _detail.economics,
      ),
    );
    if (teamId == null || !mounted) return;
    await _run(
      'register',
      () => _service.register(_token, t.id, teamId: teamId),
      fallbackSuccess: 'Entered. Your entry fee is held until the draw.',
    );
  }

  Future<void> _withdraw() async {
    final t = _detail.tournament;
    final entry = _detail.viewer.myRegistration;
    if (t == null || entry == null) return;
    final ok = await _confirm(
      title: 'Withdraw ${entry.teamName}?',
      message: 'Your ${formatPkr(entry.paidAmount)} entry fee goes straight back to '
          'your wallet. Once the bracket is drawn the fee has already paid for venue '
          'hours and there is nothing left to refund.',
      confirmLabel: 'Withdraw',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _run(
      'withdraw',
      () => _service.withdraw(_token, t.id, teamId: entry.teamId),
      fallbackSuccess: 'Withdrawn and refunded.',
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          message,
          style: GoogleFonts.poppins(
            fontSize: 12.5,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.poppins(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: danger ? AppColors.error : AppColors.primary,
              foregroundColor: AppColors.white,
            ),
            child: Text(
              confirmLabel,
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return res == true;
  }

  // ---- Organiser actions (SRS FE-5, FE-6, FE-7) ----------------

  /// Draw the bracket now. The biggest money move in the module, so it is behind a
  /// confirmation that spells out what settles: every held entry fee is released, the
  /// venue hours are paid to the owner, and the prize is frozen.
  Future<void> _generate() async {
    final t = _detail.tournament;
    if (t == null) return;
    final e = _detail.economics;
    final ok = await _confirm(
      title: 'Draw the bracket?',
      message: 'Fixtures are seeded by ELO and placed on real slots at your venue, '
          'which are then blocked. The ${formatPkr(e.pool)} of held entry fees settles '
          'now: ${formatPkr(e.venueCost)} for the venue hours, ${formatPkr(e.prize)} '
          'frozen as prize money, ${formatPkr(e.margin)} to you as margin. '
          'Registration closes and this cannot be undone.',
      confirmLabel: 'Draw it',
    );
    if (!ok || !mounted) return;
    if (_busy.contains('generate')) return;
    setState(() => _busy.add('generate'));
    final r = await _service.generate(_token, t.id);
    if (!mounted) return;
    setState(() => _busy.remove('generate'));
    if (r['success'] != true) {
      SnackbarUtil.showError(context, '${r['message'] ?? 'The draw was refused'}');
      await _load(silent: true);
      return;
    }
    await _load(silent: true);
    if (!mounted) return;
    // Not a snackbar. The generate response carries the one thing this module claims
    // and has to be able to prove — `meta.scheduling.source`, whether the released
    // demand model actually placed the hours or the chronological fallback did — and a
    // toast that vanishes in three seconds is not where a provenance record belongs.
    final data = r['data'];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DrawResultSheet(
        message: '${r['message'] ?? 'Bracket drawn'}',
        data: data is Map ? Map<String, dynamic>.from(data) : const {},
      ),
    );
  }

  Future<void> _cancelTournament() async {
    final t = _detail.tournament;
    if (t == null) return;
    final reason = await _askText(
      title: 'Cancel ${t.name}?',
      message: 'Every held entry fee is refunded in full. Tell the captains why.',
      hint: 'Reason (optional)',
      confirmLabel: 'Cancel tournament',
      danger: true,
    );
    if (reason == null || !mounted) return;
    await _run(
      'cancel',
      () => _service.cancel(_token, t.id, reason: reason.isEmpty ? null : reason),
      fallbackSuccess: 'Cancelled and refunded.',
    );
  }

  /// Approve, reject or remove one entry (FE-5).
  ///
  /// A reject and a remove both refund the held fee in the same transaction, so the
  /// confirmation says so in rupees. This looks like editing a list; it moves money.
  Future<void> _decide(Registration r, String decision) async {
    final t = _detail.tournament;
    if (t == null) return;
    if (decision != 'approve') {
      final ok = await _confirm(
        title: decision == 'reject' ? 'Reject ${r.teamName}?' : 'Remove ${r.teamName}?',
        message: 'Their ${formatPkr(r.paidAmount)} entry fee is refunded immediately.',
        confirmLabel: decision == 'reject' ? 'Reject' : 'Remove',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    await _run(
      '$decision:${r.teamId}',
      () => _service.decide(_token, t.id, r.teamId, decision: decision),
      fallbackSuccess: 'Done.',
    );
  }

  /// Type the score straight onto a fixture (FE-7).
  ///
  /// The organiser's door into the same settle function a captain's submission reaches
  /// through the normal match flow: the same ELO application, the same bracket advance,
  /// idempotent either way.
  Future<void> _enterResult(Fixture f) async {
    final t = _detail.tournament;
    if (t == null) return;
    final score = await showDialog<List<int>>(
      context: context,
      builder: (_) => _ScoreDialog(f),
    );
    if (score == null || !mounted) return;
    await _run(
      'result:${f.id}',
      () => _service.enterResult(_token, t.id, f.id, scoreA: score[0], scoreB: score[1]),
      fallbackSuccess: 'Result recorded.',
    );
  }

  /// A team did not turn up.
  ///
  /// Deliberately not entered as a 3-0. A walkover means no game was played, so the
  /// fixture carries K=0 and nobody's rating moves; recording a scoreline instead
  /// would hand the other side free rating points for a match that never happened.
  Future<void> _walkover(Fixture f) async {
    final t = _detail.tournament;
    if (t == null || !f.isPlayable) return;
    final winner = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.cardBg,
        title: Text(
          'Who turned up?',
          style: GoogleFonts.poppins(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Text(
              'The other side forfeits. No rating changes hands for a game that was '
              'not played.',
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, f.teamA),
            child: Text(f.nameA, style: GoogleFonts.poppins(fontSize: 13.5)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, f.teamB),
            child: Text(f.nameB, style: GoogleFonts.poppins(fontSize: 13.5)),
          ),
        ],
      ),
    );
    if (winner == null || !mounted) return;
    await _run(
      'walkover:${f.id}',
      () => _service.walkover(_token, t.id, f.id, winnerTeamId: winner),
      fallbackSuccess: 'Walkover recorded.',
    );
  }

  /// A confirm dialog with one optional free-text field. Returns null on cancel and
  /// the (possibly empty) text on confirm, so "" and null mean different things.
  Future<String?> _askText({
    required String title,
    required String message,
    required String hint,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final ctrl = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: GoogleFonts.poppins(
                fontSize: 12.5,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLength: 200,
              style: GoogleFonts.poppins(fontSize: 13),
              decoration: InputDecoration(
                hintText: hint,
                counterText: '',
                filled: true,
                fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Keep it',
              style: GoogleFonts.poppins(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: danger ? AppColors.error : AppColors.primary,
              foregroundColor: AppColors.white,
            ),
            child: Text(
              confirmLabel,
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return res;
  }

  // ---- Build ---------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = _detail.tournament;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.white),
        title: Text(
          t?.name ?? 'Tournament',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.poppins(
            color: AppColors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        bottom: t == null
            ? null
            : TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: AppColors.accent,
                indicatorWeight: 3,
                labelColor: AppColors.white,
                unselectedLabelColor: AppColors.white.withValues(alpha: 0.66),
                labelStyle: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
                tabs: const [
                  Tab(text: 'Overview'),
                  Tab(text: 'Fixtures'),
                  Tab(text: 'Table'),
                  Tab(text: 'Teams'),
                  Tab(text: 'Money'),
                ],
              ),
      ),
      body: _loading
          ? const CustomLoader()
          : t == null
              ? TournamentEmpty(
                  icon: Icons.search_off,
                  title: 'Tournament not found',
                  message: _error ??
                      'It may have been cancelled, or the link is out of date.',
                )
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _tab(_overview(t)),
                    _tab(_fixtures(t)),
                    _tab(_table(t)),
                    _tab(_teams(t)),
                    _tab(_money(t)),
                  ],
                ),
      bottomNavigationBar: t == null || _loading ? null : _actionBar(t),
    );
  }

  /// Every tab is a pull-to-refresh list. Standings and fixtures change while a
  /// tournament is being played, and a captain watching from the touchline should be
  /// able to pull the newest state from whichever tab they are on.
  Widget _tab(List<Widget> children) => RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () => _load(silent: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: children,
        ),
      );

  // ---- Tabs ----------------------------------------------------

  List<Widget> _overview(Tournament t) {
    final v = _detail.viewer;
    final org = _detail.organiser;
    final next = _detail.nextFixtureFor(v.myTeamId);
    return [
      _HeaderCard(t),
      const SizedBox(height: 12),
      if (t.hasChampion) ...[ChampionBanner(t), const SizedBox(height: 12)],
      if (t.isCancelled) ...[
        TournamentWarning(
          t.cancelReason == null
              ? 'This tournament was cancelled and every entry fee was refunded.'
              : 'Cancelled: ${t.cancelReason}. Every entry fee was refunded.',
          color: AppColors.error,
          icon: Icons.block,
        ),
        const SizedBox(height: 12),
      ],
      if (v.myRegistration != null) ...[
        _MyEntryCard(
          registration: v.myRegistration!,
          nextFixture: next,
        ),
        const SizedBox(height: 12),
      ],
      if (org != null) ...[
        _OrganiserPanel(
          organiser: org,
          tournament: t,
          busy: _busy,
          onGenerate: org.canGenerate ? _generate : null,
          onCancel: org.canCancel ? _cancelTournament : null,
          onSeeTeams: () => _tabs.animateTo(3),
        ),
        const SizedBox(height: 12),
      ],
      _RulesCard(t),
      if (t.description != null && t.description!.isNotEmpty) ...[
        const SizedBox(height: 12),
        _SectionCard(
          title: 'About',
          child: Text(
            t.description!,
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _fixtures(Tournament t) {
    final b = _detail.bracket;
    final org = _detail.organiser;
    final mine = _detail.viewer.myTeamId;
    Widget? trailing(Fixture f) {
      if (org == null || !f.isPlayable || f.isSettled) return null;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TinyAction(
            label: 'Result',
            icon: Icons.edit_outlined,
            color: AppColors.primary,
            busy: _busy.contains('result:${f.id}'),
            onPressed: () => _enterResult(f),
          ),
          const SizedBox(width: 6),
          _TinyAction(
            label: 'No-show',
            icon: Icons.person_off_outlined,
            color: AppColors.warning,
            busy: _busy.contains('walkover:${f.id}'),
            onPressed: () => _walkover(f),
          ),
        ],
      );
    }

    if (!b.generated) {
      return [
        TournamentEmpty(
          icon: Icons.account_tree_outlined,
          title: 'The draw is not out yet',
          message: t.isOpen
              ? 'Fixtures are seeded by team ELO and drawn when registration closes'
                  '${t.countdown.startsWith('Closes') ? ' - ${t.countdown.toLowerCase()}' : ''}.'
              : 'Fixtures have not been generated for this tournament.',
        ),
      ];
    }
    if (b.isKnockout) {
      return [
        BracketView(b, highlightTeamId: mine, onFixtureTap: null),
        const SizedBox(height: 14),
        FixtureRoundList(
          b.roundsList,
          highlightTeamId: mine,
          trailingBuilder: org == null ? null : trailing,
        ),
      ];
    }
    return [
      FixtureRoundList(
        b.roundsList,
        highlightTeamId: mine,
        trailingBuilder: org == null ? null : trailing,
      ),
    ];
  }

  List<Widget> _table(Tournament t) => [
        StandingsTable(
          _detail.standings,
          highlightTeamId: _detail.viewer.myTeamId,
          knockout: t.format == TournamentFormat.knockout,
        ),
      ];

  List<Widget> _teams(Tournament t) {
    final org = _detail.organiser;
    // The organiser sees withdrawals and rejections; everybody else sees the field.
    // A captain does not need to know which squads were turned away, and publishing it
    // would be a small public humiliation the module has no reason to hand out.
    final rows = org == null ? _detail.field : _detail.teams;
    if (rows.isEmpty) {
      return [
        TournamentEmpty(
          icon: Icons.groups_outlined,
          title: 'No teams yet',
          message: t.isOpen
              ? 'Be the first in. ${t.maxTeams} spots, ${formatPkr(t.entryFee)} each.'
              : 'Nobody entered this one.',
        ),
      ];
    }
    return [
      Row(
        children: [
          Text(
            t.requiresApproval ? 'Entries' : 'Teams',
            style: GoogleFonts.poppins(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          Text(
            t.capacityLabel,
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      for (final r in rows)
        RegistrationTile(
          r,
          showCaptain: org != null,
          actions: org == null || r.isOut
              ? const []
              : [
                  if (r.isPending)
                    TournamentActionButton(
                      label: 'Approve',
                      icon: Icons.check,
                      color: AppColors.success,
                      filled: true,
                      busy: _busy.contains('approve:${r.teamId}'),
                      onPressed: () => _decide(r, 'approve'),
                    ),
                  if (r.isPending)
                    TournamentActionButton(
                      label: 'Reject',
                      icon: Icons.close,
                      color: AppColors.error,
                      busy: _busy.contains('reject:${r.teamId}'),
                      onPressed: () => _decide(r, 'reject'),
                    ),
                  if (!r.isPending && !_detail.bracket.generated)
                    TournamentActionButton(
                      label: 'Remove and refund',
                      icon: Icons.person_remove_outlined,
                      color: AppColors.error,
                      busy: _busy.contains('remove:${r.teamId}'),
                      onPressed: () => _decide(r, 'remove'),
                    ),
                ],
        ),
    ];
  }

  List<Widget> _money(Tournament t) {
    final isOrganiser = _detail.organiser != null;
    return [
      PrizeBreakdownCard(_detail.economics, showOwnerView: isOrganiser),
      if (isOrganiser) ...[
        const SizedBox(height: 12),
        OwnerUpliftNote(_detail.economics),
      ],
      const SizedBox(height: 12),
      _SectionCard(
        title: 'How the money moves',
        // The stage pill, because which of these five steps has already happened is
        // the first thing anyone reading the ledger wants to know. Whether the figures
        // above are settled or projected is the breakdown card's own heading.
        trailing: TournamentStatusPill(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bullet('Your entry fee leaves your spendable balance the moment you enter '
                'and sits frozen. Nobody has earned it yet.'),
            _bullet('Withdraw before the draw, or get rejected, and it comes straight '
                'back in full.'),
            _bullet('At the draw the fees settle: the venue hours are paid for first, '
                'then the prize pool is frozen, then the organiser takes what is left.'),
            _bullet('The champion and the runner-up are paid when the final is '
                'settled.'),
            _bullet('You never book or pay for a tournament slot. The entry fee is the '
                'only thing you pay.'),
          ],
        ),
      ),
    ];
  }

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 8),
              child: Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );

  // ---- The one action ------------------------------------------

  /// The bar at the bottom offers AT MOST ONE action, and only when the server said it
  /// is available. Registration and withdrawal are money; a screen that showed both,
  /// or showed Enter to somebody who is already in, would be inviting a tap that can
  /// only end in a refusal.
  Widget? _actionBar(Tournament t) {
    final v = _detail.viewer;
    final org = _detail.organiser;

    if (v.canWithdraw) {
      return _Bar(
        label: 'Withdraw and get ${formatPkr(v.myRegistration!.paidAmount)} back',
        icon: Icons.undo,
        color: AppColors.error,
        busy: _busy.contains('withdraw'),
        onPressed: _withdraw,
      );
    }
    if (v.canRegister) {
      final short = v.canAfford == false;
      return _Bar(
        label: short
            ? 'Top up to enter - ${formatPkr(t.entryFee)} needed'
            : 'Enter for ${formatPkr(t.entryFee)}',
        icon: short ? Icons.account_balance_wallet_outlined : Icons.how_to_reg,
        color: short ? AppColors.warning : AppColors.accent,
        busy: _busy.contains('register'),
        onPressed: short ? null : _register,
        note: short && v.walletBalance != null
            ? 'Wallet balance ${formatPkr(v.walletBalance!)}'
            : null,
      );
    }
    if (org != null && org.canGenerate) {
      return _Bar(
        label: 'Draw the bracket',
        icon: Icons.account_tree_outlined,
        color: AppColors.primary,
        busy: _busy.contains('generate'),
        onPressed: _generate,
        note: org.pendingApprovals > 0
            ? '${org.pendingApprovals} ${org.pendingApprovals == 1 ? 'entry' : 'entries'} '
                'still awaiting your approval - drawing now rejects and refunds them'
            : null,
      );
    }
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════
//  Private pieces of this screen
// ═══════════════════════════════════════════════════════════════

/// A titled white card. Used four times on this screen, so it is a class rather than
/// four copies of the same BoxDecoration.
class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: GoogleFonts.poppins(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );
}

/// The bottom bar's one button, with an optional line of context above it.
class _Bar extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool busy;
  final VoidCallback? onPressed;
  final String? note;

  const _Bar({
    required this.label,
    required this.icon,
    required this.color,
    required this.busy,
    this.onPressed,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Container(
      padding: EdgeInsets.fromLTRB(
        14,
        10,
        14,
        10 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (note != null) ...[
            Row(
              children: [
                Icon(Icons.info_outline, size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    note!,
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      height: 1.35,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed: enabled ? onPressed : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                disabledBackgroundColor: AppColors.disabled,
                foregroundColor: AppColors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(AppColors.white),
                      ),
                    )
                  : Icon(icon, size: 18),
              label: Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The header: where, when, what format, how full, how long left.
class _HeaderCard extends StatelessWidget {
  final Tournament tournament;
  const _HeaderCard(this.tournament);

  @override
  Widget build(BuildContext context) {
    final t = tournament;
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
          Row(
            children: [
              TournamentStatusPill(t),
              const SizedBox(width: 6),
              CountdownChip(t),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            t.venue.display,
            style: GoogleFonts.poppins(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: AppColors.white,
            ),
          ),
          if (t.venue.where.isNotEmpty)
            Text(
              t.venue.where,
              style: GoogleFonts.poppins(
                fontSize: 11.5,
                color: AppColors.white.withValues(alpha: 0.72),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              _fact(Icons.sports_soccer, t.sport.toUpperCase()),
              _fact(Icons.account_tree_outlined, t.formatLabel),
              if (t.startDate != null) _fact(Icons.event, t.startDate!),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  t.capacityLabel,
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.white.withValues(alpha: 0.86),
                  ),
                ),
              ),
              Text(
                'Entry ${formatPkr(t.entryFee)}',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: t.capacityFraction,
              minHeight: 6,
              backgroundColor: AppColors.white.withValues(alpha: 0.22),
              valueColor: const AlwaysStoppedAnimation(AppColors.accent),
            ),
          ),
          if (t.organiserName != null || t.ownerName != null) ...[
            const SizedBox(height: 11),
            Row(
              children: [
                Icon(
                  Icons.storefront_outlined,
                  size: 13,
                  color: AppColors.white.withValues(alpha: 0.72),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'Organised by ${t.organiserName ?? t.ownerName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: AppColors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _fact(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Row(
          children: [
            Icon(icon, size: 13, color: AppColors.accent),
            const SizedBox(width: 4),
            Text(
              text,
              style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.white.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      );
}

/// A compact icon+label action for the trailing edge of a fixture tile.
class _TinyAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool busy;
  final VoidCallback? onPressed;

  const _TinyAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.busy,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final tint = enabled ? color : AppColors.disabled;
    return Material(
      color: tint.withValues(alpha: 0.11),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Row(
            children: [
              if (busy)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(tint),
                  ),
                )
              else
                Icon(icon, size: 12, color: tint),
              const SizedBox(width: 4),
              Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: tint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rules, in the words a captain would use to ask about them.
///
/// Every line here is a policy the server actually enforces, and each one exists
/// because it is the sort of thing that causes an argument on a touchline if it was
/// never written down: what happens to a draw, who gets a bye, whether a walkover moves
/// ratings, and what a tournament match is worth compared to a friendly.
class _RulesCard extends StatelessWidget {
  final Tournament tournament;
  const _RulesCard(this.tournament);

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final knockout = t.format == TournamentFormat.knockout;
    return _SectionCard(
      title: 'Rules',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(
            Icons.account_tree_outlined,
            knockout
                ? 'Single-elimination knockout, up to ${t.maxTeams} teams. Seeded by '
                    'team ELO: the top seed meets the lowest.'
                : 'Round-robin, up to ${t.maxTeams} teams. Everybody plays everybody '
                    'once.',
          ),
          if (knockout)
            _row(
              Icons.balance,
              'A drawn tie is decided in favour of the higher seed. If the number of '
                  'entries is not a power of two, the top seeds get a bye into the next '
                  'round.',
            )
          else
            _row(Icons.balance, 'Win 3 points, draw 1, loss 0.'),
          _row(
            Icons.trending_up,
            'Tournament matches move ELO harder than friendlies, and the later the '
                'round the harder: K=40 early, 48 in a semi-final, 56 in the final. A '
                'bye or a walkover moves nothing, because no game was played.',
          ),
          _row(
            Icons.groups_outlined,
            'At least ${t.minTeams} teams have to enter. Below that the tournament is '
                'cancelled at the deadline and every fee is refunded in full.',
          ),
          _row(
            t.requiresApproval ? Icons.verified_outlined : Icons.bolt,
            t.requiresApproval
                ? 'The organiser approves each entry. Your fee is held until they do, '
                    'and refunded in full if they say no.'
                : 'Entry is automatic while there are spots left.',
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
}

/// My team's own entry: what it cost, whether it is confirmed, and who is next.
///
/// The fee is described as *held* until the organiser accepts, because that is what the
/// ledger actually did — it moved the money into the frozen column, not out of the
/// wallet. Calling it "paid" while it can still come back would be a small lie that
/// the refund would later contradict.
class _MyEntryCard extends StatelessWidget {
  final Registration registration;
  final Fixture? nextFixture;

  const _MyEntryCard({required this.registration, this.nextFixture});

  @override
  Widget build(BuildContext context) {
    final r = registration;
    final next = nextFixture;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Your entry',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              EntryStatusPill(r.status),
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              TeamCrest(logoUrl: r.logoUrl, radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.teamName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      [
                        'ELO ${r.elo}',
                        if (r.seed != null) r.seedLabel,
                        if (r.eliminatedRound != null)
                          'Out in round ${r.eliminatedRound}',
                      ].join('  ·  '),
                      style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatPkr(r.paidAmount),
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    r.isPending ? 'held' : 'entry fee',
                    style: GoogleFonts.poppins(
                      fontSize: 9.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (r.isPending) ...[
            const SizedBox(height: 10),
            Text(
              'The organiser has not accepted this entry yet. Your fee is held, not '
              'spent — if they say no, or you withdraw before the deadline, it comes '
              'straight back.',
              style: GoogleFonts.poppins(
                fontSize: 10.5,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          if (next != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.accentLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.sports, size: 14, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Next: ${next.nameA} vs ${next.nameB}',
                          style: GoogleFonts.poppins(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          [
                            if (next.label != null) next.label!,
                            next.when,
                          ].where((s) => s.isNotEmpty).join('  ·  '),
                          style: GoogleFonts.poppins(
                            fontSize: 10.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The organiser's control strip: what still needs a human, and the one big lever.
///
/// Every enabling condition here is a server flag (`canGenerate`, `canCancel`) rather
/// than a client-side re-derivation of the deadline. If the two ever disagree the
/// server wins, and the worst a stale screen can do is offer a button that comes back
/// with a polite refusal.
class _OrganiserPanel extends StatelessWidget {
  final OrganiserView organiser;
  final Tournament tournament;
  final Set<String> busy;
  final VoidCallback? onGenerate;
  final VoidCallback? onCancel;
  final VoidCallback onSeeTeams;

  const _OrganiserPanel({
    required this.organiser,
    required this.tournament,
    required this.busy,
    required this.onSeeTeams,
    this.onGenerate,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final o = organiser;
    final t = tournament;
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
              const Icon(Icons.admin_panel_settings_outlined,
                  size: 15, color: AppColors.primary),
              const SizedBox(width: 7),
              Text(
                'You are running this',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _stat('${t.teamsAccepted}', 'accepted'),
              if (o.pendingApprovals > 0)
                _stat('${o.pendingApprovals}', 'awaiting you',
                    color: AppColors.warning),
              if (t.hasBracket)
                _stat('${o.unsettledFixtures}', 'results to enter',
                    color: o.unsettledFixtures > 0
                        ? AppColors.warning
                        : AppColors.success),
              _stat('${t.minTeams}', 'minimum'),
            ],
          ),
          if (o.pendingApprovals > 0) ...[
            const SizedBox(height: 11),
            GestureDetector(
              onTap: onSeeTeams,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${o.pendingApprovals} '
                      '${o.pendingApprovals == 1 ? 'team is' : 'teams are'} waiting for '
                      'your decision. Their fees are held until you answer.',
                      style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 16, color: AppColors.accent),
                ],
              ),
            ),
          ],
          if (!t.hasBracket && o.deadlinePassed && !t.isCancelled) ...[
            const SizedBox(height: 11),
            TournamentWarning(
              t.teamsAccepted < t.minTeams
                  ? 'The deadline has passed with only ${t.teamsAccepted} of the '
                      '${t.minTeams} teams needed. This will be cancelled and every fee '
                      'refunded.'
                  : 'The deadline has passed. Draw the bracket to start play — the '
                      'nightly job will do it for you if you do not.',
              color: t.teamsAccepted < t.minTeams
                  ? AppColors.error
                  : AppColors.warning,
            ),
          ],
          if (onGenerate != null || onCancel != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (onGenerate != null)
                  TournamentActionButton(
                    label: 'Draw bracket',
                    icon: Icons.account_tree,
                    color: AppColors.accent,
                    filled: true,
                    busy: busy.contains('generate'),
                    onPressed: onGenerate,
                  ),
                if (onGenerate != null && onCancel != null)
                  const SizedBox(width: 8),
                if (onCancel != null)
                  TournamentActionButton(
                    label: 'Cancel & refund',
                    icon: Icons.block,
                    color: AppColors.error,
                    busy: busy.contains('cancel'),
                    onPressed: onCancel,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String value, String label, {Color? color}) {
    final tint = color ?? AppColors.textPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: (color ?? AppColors.primary).withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: tint,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 10,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Squad sizes used only to divide the entry fee into a per-player number.
///
/// This is a presentation default, not policy — the sheet lets the captain change it,
/// and the number it produces is labelled as *their* split rather than a charge. The
/// server never sees it. It exists because "PKR 4,000" and "about PKR 571 each" are the
/// same fact and only the second one is a decision a captain can actually make.
const Map<String, int> _defaultSquad = {
  'football': 7,
  'futsal': 6,
  'cricket': 11,
  'basketball': 5,
  'badminton': 2,
  'tennis': 2,
  'volleyball': 6,
  'hockey': 11,
  'table tennis': 2,
};

int _squadFor(String sport) => _defaultSquad[sport.toLowerCase()] ?? 7;

/// The register sheet: pick a squad, then see exactly what entering costs and what is
/// on the table before the fee is held (SRS FE-3).
///
/// Two numbers do the persuading, and both come from the server: the per-player split of
/// the fee, and the champion's share as the economics endpoint projected it. A captain
/// deciding between this and a couple of friendlies is comparing those two figures, so
/// they are shown together rather than a page apart.
class _RegisterSheet extends StatefulWidget {
  final Tournament tournament;
  final TournamentViewer viewer;
  final Economics economics;

  const _RegisterSheet({
    required this.tournament,
    required this.viewer,
    required this.economics,
  });

  @override
  State<_RegisterSheet> createState() => _RegisterSheetState();
}

class _RegisterSheetState extends State<_RegisterSheet> {
  String? _teamId;
  late int _squad = _squadFor(widget.tournament.sport);

  @override
  void initState() {
    super.initState();
    final teams = widget.viewer.eligibleTeams;
    if (teams.length == 1) _teamId = teams.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tournament;
    final v = widget.viewer;
    final e = widget.economics;
    final teams = v.eligibleTeams;
    final balance = v.walletBalance;
    final short = balance != null && balance < t.entryFee;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Enter ${t.name}',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${t.formatLabel}  ·  ${t.sport}  ·  ${t.venue.name}',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                teams.length == 1 ? 'Entering as' : 'Which squad?',
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              ...teams.map(_teamRow),
              const SizedBox(height: 16),
              _splitRow(t),
              const SizedBox(height: 14),
              _costCard(t, e, balance, short),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _teamId == null || short
                      ? null
                      : () => Navigator.pop(context, _teamId),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.white,
                    disabledBackgroundColor: AppColors.disabled,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.check_circle_outline, size: 17),
                  label: Text(
                    short
                        ? 'Top up your wallet first'
                        : 'Hold ${formatPkr(t.entryFee)} and enter',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t.requiresApproval
                    ? 'The fee is held now and only becomes the organiser’s once '
                        'they accept you. Refunded in full if they say no, or if you '
                        'withdraw before the deadline.'
                    : 'The fee is held now, not spent. Refunded in full if you withdraw '
                        'before the deadline or the tournament is cancelled.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 10,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _teamRow(EligibleTeam team) {
    final selected = _teamId == team.id;
    return GestureDetector(
      onTap: () => setState(() => _teamId = team.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentLight : AppColors.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            TeamCrest(logoUrl: team.logoUrl, radius: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    team.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    'ELO ${team.elo}',
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? AppColors.accent : AppColors.border,
            ),
          ],
        ),
      ),
    );
  }

  Widget _splitRow(Tournament t) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Split the fee between',
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        _stepper(
          Icons.remove,
          _squad > 1 ? () => setState(() => _squad -= 1) : null,
        ),
        SizedBox(
          width: 58,
          child: Text(
            '$_squad',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        _stepper(
          Icons.add,
          _squad < 30 ? () => setState(() => _squad += 1) : null,
        ),
      ],
    );
  }

  Widget _stepper(IconData icon, VoidCallback? onTap) {
    final enabled = onTap != null;
    return Material(
      color: enabled
          ? AppColors.accent.withValues(alpha: 0.12)
          : AppColors.inputFill,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 15,
            color: enabled ? AppColors.accent : AppColors.disabled,
          ),
        ),
      ),
    );
  }

  /// Cost on the left, upside on the right — the two halves of the decision.
  ///
  /// `winnerShare` is whatever the economics endpoint last projected, so before the
  /// draw it is explicitly a projection at N teams and after the draw it is the real
  /// figure. Neither is computed here.
  Widget _costCard(Tournament t, Economics e, double? balance, bool short) {
    final per = t.perPlayer(_squad);
    final win = e.winnerShare;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _fact(
                  'Your squad pays',
                  formatPkr(t.entryFee),
                  '≈ ${formatPkr(per)} each, $_squad ways',
                  AppColors.textPrimary,
                ),
              ),
              Container(width: 1, height: 46, color: AppColors.border),
              Expanded(
                child: _fact(
                  'Champion takes',
                  win > 0 ? formatPkr(win) : 'Set at the draw',
                  win > 0
                      ? (e.isProjection
                          ? 'projected at ${e.projectedFor ?? e.teams} teams'
                          : 'runner-up ${formatPkr(e.runnerupShare)}')
                      : 'once the field is known',
                  AppColors.accent,
                ),
              ),
            ],
          ),
          if (balance != null) ...[
            const SizedBox(height: 12),
            Container(height: 1, color: AppColors.border),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  short ? Icons.error_outline : Icons.account_balance_wallet_outlined,
                  size: 14,
                  color: short ? AppColors.error : AppColors.textSecondary,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    short
                        ? 'Wallet ${formatPkr(balance)} — you are '
                            '${formatPkr(t.entryFee - balance)} short'
                        : 'Wallet ${formatPkr(balance)}, leaving '
                            '${formatPkr(balance - t.entryFee)} after this',
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      fontWeight: short ? FontWeight.w600 : FontWeight.w400,
                      color: short ? AppColors.error : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (win > 0) ...[
            const SizedBox(height: 10),
            Text(
              'You never book or pay for a tournament slot. This one fee covers every '
              'match your squad plays.',
              style: GoogleFonts.poppins(
                fontSize: 10,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _fact(String label, String value, String note, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 9.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(
            note,
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
}

/// Two numbers, and the consequence of them spelled out before the button is live.
///
/// A knockout draw is not rejected here — it is legal and resolves in favour of the
/// higher seed — so the dialog says which team that advances rather than making the
/// organiser find out afterwards.
class _ScoreDialog extends StatefulWidget {
  final Fixture fixture;
  const _ScoreDialog(this.fixture);

  @override
  State<_ScoreDialog> createState() => _ScoreDialogState();
}

class _ScoreDialogState extends State<_ScoreDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  int? get _scoreA => int.tryParse(_a.text.trim());
  int? get _scoreB => int.tryParse(_b.text.trim());
  bool get _valid =>
      _scoreA != null && _scoreB != null && _scoreA! >= 0 && _scoreB! >= 0;

  @override
  Widget build(BuildContext context) {
    final f = widget.fixture;
    return AlertDialog(
      backgroundColor: AppColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        f.label == null ? 'Enter the result' : 'Result · ${f.label}',
        style: GoogleFonts.poppins(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _scoreRow(f.nameA, _a),
          const SizedBox(height: 10),
          _scoreRow(f.nameB, _b),
          const SizedBox(height: 12),
          Text(
            _drawNote(f),
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _valid
              ? () => Navigator.pop(context, [_scoreA!, _scoreB!])
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.white,
            disabledBackgroundColor: AppColors.disabled,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(
            'Save result',
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  String _drawNote(Fixture f) {
    if (!_valid || _scoreA != _scoreB) {
      return 'Saving this applies ELO to both teams and advances the winner. It cannot '
          'be edited afterwards.';
    }
    return 'A draw here is decided in favour of the higher seed, so '
        '${f.nameA} and ${f.nameB} will not replay — the better-seeded side advances.';
  }

  Widget _scoreRow(String name, TextEditingController ctrl) {
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 62,
          child: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            onChanged: (_) => setState(() {}),
            style: GoogleFonts.poppins(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppColors.inputFill,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide.none,
              ),
              hintText: '0',
              hintStyle: GoogleFonts.poppins(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the draw actually did, shown once, straight after it happened.
///
/// This is the only screen in the app that carries the scheduler's provenance stamp,
/// because `meta.scheduling` is only on the generate response — `GET /:id` does not
/// return it. So the honest place for "the demand model chose these hours" is here, next
/// to the hours it chose, rather than as a permanent badge on a public overview that
/// cannot prove it.
class _DrawResultSheet extends StatelessWidget {
  final String message;
  final Map<String, dynamic> data;

  const _DrawResultSheet({required this.message, required this.data});

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};

  double _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final bracket = _map(data['bracket']);
    final econ = _map(data['economics']);
    final meta = _map(data['meta']);
    final sched = _map(meta['scheduling']);
    final teams = data['teams'] is num ? (data['teams'] as num).toInt() : 0;
    final byes = bracket['byes'] is num ? (bracket['byes'] as num).toInt() : 0;
    final rejected = data['rejectedPending'] is num
        ? (data['rejectedPending'] as num).toInt()
        : 0;
    final prize = _num(econ['prize']);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.account_tree,
                      size: 18, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The draw is done',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                message,
                style: GoogleFonts.poppins(
                  fontSize: 11.5,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip('$teams teams', Icons.groups_outlined),
                  if (bracket['rounds'] != null)
                    _chip('${bracket['rounds']} rounds',
                        Icons.format_list_numbered),
                  if (bracket['fixtures'] != null)
                    _chip('${bracket['fixtures']} fixtures', Icons.sports),
                  if (byes > 0)
                    _chip('$byes ${byes == 1 ? 'bye' : 'byes'}',
                        Icons.fast_forward),
                  if (prize > 0)
                    _chip('${formatPkr(prize)} prize', Icons.emoji_events),
                ],
              ),
              if (econ.isNotEmpty) ...[
                const SizedBox(height: 14),
                PrizeBreakdownCard(
                  Economics.fromJson(econ),
                  showOwnerView: true,
                ),
              ],
              if (sched.isNotEmpty) ...[
                const SizedBox(height: 14),
                SchedulingNote(SchedulingMeta.fromJson(sched)),
              ],
              if (byes > 0) ...[
                const SizedBox(height: 12),
                TournamentWarning(
                  '$byes top ${byes == 1 ? 'seed' : 'seeds'} got a bye into round 2, '
                  'because $teams teams do not fill a power-of-two bracket. A bye moves '
                  'nobody’s rating.',
                  icon: Icons.fast_forward,
                  color: AppColors.accent,
                ),
              ],
              if (rejected > 0) ...[
                const SizedBox(height: 12),
                TournamentWarning(
                  '$rejected entry ${rejected == 1 ? 'was' : 'were'} still awaiting '
                  'approval at the draw and ${rejected == 1 ? 'was' : 'were'} refunded '
                  'in full.',
                  icon: Icons.reply,
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'See the bracket',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 12, color: AppColors.accent),
            const SizedBox(width: 5),
            Text(
              text,
              style: GoogleFonts.poppins(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      );
}
