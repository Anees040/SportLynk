import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/match.dart';
import '../../providers/auth_provider.dart';
import '../../services/match_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';

/// Compose a challenge (FR5.8 – FR5.12).
///
/// Everything a captain needs to decide *and* to commit, on one screen: how even
/// the tie is, how the two sides compare, the generated preview, and which of
/// their own confirmed bookings the match will be played on.
///
/// The booking picker is not a convenience — it is the rule. FR5.11 says a match
/// hangs off a confirmed booking, so there is no "propose a time" path here. If
/// the captain has no confirmed future slot, the screen says so and sends them to
/// book one rather than accepting a challenge the pitch cannot host.
class MatchChallengeScreen extends StatefulWidget {
  final String myTeamId;
  final MatchSide myTeam;
  final MatchSide opponent;

  const MatchChallengeScreen({
    super.key,
    required this.myTeamId,
    required this.myTeam,
    required this.opponent,
  });

  @override
  State<MatchChallengeScreen> createState() => _MatchChallengeScreenState();
}

class _MatchChallengeScreenState extends State<MatchChallengeScreen> {
  final _service = MatchService();

  String get _token => context.read<AuthProvider>().token ?? '';

  bool _loading = true;
  bool _sending = false;
  String? _loadError;

  MatchPreview? _preview;
  List<LinkableBooking> _bookings = const [];
  String? _bookingId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    // Both reads are independent, so they go together — the screen is useless
    // without either one and serialising them would just double the wait.
    final results = await Future.wait([
      _service.previewRaw(
        _token,
        challengerTeam: widget.myTeamId,
        opponentTeam: widget.opponent.id,
      ),
      _service.linkableBookings(_token, widget.myTeamId),
    ]);
    if (!mounted) return;

    final raw = results[0] as Map<String, dynamic>;
    final bookings = results[1] as List<LinkableBooking>;

    setState(() {
      _loading = false;
      if (raw['success'] == true && raw['data'] is Map) {
        _preview = MatchPreview.fromJson(Map<String, dynamic>.from(raw['data'] as Map));
      } else {
        // The backend refuses a pairing for real reasons — different sports, a
        // team gone private, a live match already open between the two. Showing
        // its sentence is the difference between "fix this" and "it's broken".
        _loadError = raw['message']?.toString() ?? 'This pairing is not available.';
      }
      _bookings = bookings;
      if (_bookings.length == 1) _bookingId = _bookings.first.id;
    });
  }

  Future<void> _send() async {
    final bookingId = _bookingId;
    if (bookingId == null) {
      SnackbarUtil.showError(context, 'Pick the booking this match will be played on.');
      return;
    }
    if (_sending) return;

    setState(() => _sending = true);
    final r = await _service.challenge(
      _token,
      challengerTeam: widget.myTeamId,
      opponentTeam: widget.opponent.id,
      bookingId: bookingId,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    if (r['success'] == true) {
      SnackbarUtil.showSuccess(
        context,
        'Challenge sent to ${widget.opponent.name}. They have 48 hours to reply.',
      );
      Navigator.pop(context, true);
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not send the challenge.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSend = !_loading && _loadError == null && _bookingId != null && !_sending;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'New Challenge',
          style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                _versusHeader(),
                if (_loadError != null)
                  _notice(_loadError!, AppColors.error, Icons.error_outline)
                else ...[
                  const SizedBox(height: 18),
                  Center(child: CompetitivenessGauge(score: _preview?.competitiveness)),
                  const SizedBox(height: 6),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        _gaugeCaption(),
                        textAlign: TextAlign.center,
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          height: 1.4,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _comparison(),
                  if ((_preview?.previewText ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: MatchPreviewBlock(
                        label: _preview!.previewLabel,
                        text: _preview!.previewText,
                      ),
                    ),
                  const SizedBox(height: 20),
                  _bookingPicker(),
                ],
              ],
            ),
      bottomNavigationBar: _loadError != null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(
                  _sending ? 'Sending…' : 'Send challenge',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  disabledBackgroundColor: AppColors.disabled,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: canSend ? _send : null,
              ),
            ),
    );
  }

  // ── Header ─────────────────────────────────────────────────

  Widget _versusHeader() {
    final me = _preview?.challenger ?? widget.myTeam;
    final them = _preview?.opponent ?? widget.opponent;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.primary, Color(0xFF14532D)],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _headerSide(me, 'YOU')),
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: Text(
              'VS',
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ),
          Expanded(child: _headerSide(them, 'OPPONENT')),
        ],
      ),
    );
  }

  Widget _headerSide(MatchSide s, String tag) => Column(
        children: [
          Text(
            tag,
            style: GoogleFonts.poppins(
              fontSize: 8.5,
              letterSpacing: 1.3,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          TeamCrest(
            logoUrl: s.logoUrl,
            radius: 30,
            background: Colors.white.withValues(alpha: 0.14),
          ),
          const SizedBox(height: 8),
          Text(
            s.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.ranked ? 'ELO ${s.elo}' : 'Unranked',
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: s.ranked ? AppColors.accent : Colors.white.withValues(alpha: 0.6),
            ),
          ),
          if (s.trustBand != null) ...[
            const SizedBox(height: 6),
            TrustBadgeChip(band: s.trustBand, label: s.trustLabel),
          ],
        ],
      );

  String _gaugeCaption() {
    final p = _preview;
    if (p == null) return '';
    if (p.competitiveness == null) {
      return 'A competitiveness score needs a verified match on both sides (FR2.6). Play one and this fills in.';
    }
    final gap = p.eloGap;
    return p.withinPreferredBand
        ? '$gap rating points apart — inside the ±400 range the ladder recommends.'
        : '$gap rating points apart — outside the recommended ±400 range, so expect a lopsided game.';
  }

  // ── Side-by-side stats ─────────────────────────────────────

  Widget _comparison() {
    final me = _preview?.challenger ?? widget.myTeam;
    final them = _preview?.opponent ?? widget.opponent;

    String pct(MatchSide s) =>
        s.played == 0 ? '—' : '${(s.winRate * 100).round()}%';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _row('Rating', me.ranked ? '${me.elo}' : 'Unranked',
              them.ranked ? '${them.elo}' : 'Unranked'),
          _row('Played', '${me.played}', '${them.played}'),
          _row('Won', '${me.wins}', '${them.wins}'),
          _row('Lost', '${me.losses}', '${them.losses}'),
          _row('Drawn', '${me.draws}', '${them.draws}'),
          _row('Win rate', pct(me), pct(them), last: true),
        ],
      ),
    );
  }

  Widget _row(String label, String mine, String theirs, {bool last = false}) => Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          border: last
              ? null
              : const Border(bottom: BorderSide(color: AppColors.divider, width: 0.7)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                mine,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                label.toUpperCase(),
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 9.5,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Expanded(
              child: Text(
                theirs,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );

  // ── Which booking (FR5.11) ─────────────────────────────────

  Widget _bookingPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'PLAYED ON',
            style: GoogleFonts.poppins(
              fontSize: 9.5,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            'A challenge is pinned to one of your confirmed bookings, so the pitch is guaranteed before anyone accepts.',
            style: GoogleFonts.poppins(
              fontSize: 11.5,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        if (_bookings.isEmpty)
          _notice(
            'You have no confirmed upcoming bookings left to link. Book a slot first — then the challenge can name a real time and place.',
            AppColors.warning,
            Icons.event_busy,
          )
        else
          ..._bookings.map(_bookingTile),
      ],
    );
  }

  Widget _bookingTile(LinkableBooking b) {
    final on = b.id == _bookingId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: on ? AppColors.accentLight : AppColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _bookingId = b.id),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: on ? AppColors.accent : AppColors.border,
                width: on ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20,
                  color: on ? AppColors.accent : AppColors.disabled,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.venueName ?? 'Venue',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 13.5,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${b.prettyDate}  ·  ${b.timeRange}',
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.primary,
                        ),
                      ),
                      if (b.venueCity != null && b.venueCity!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          b.venueCity!,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice(String text, Color color, IconData icon) => Container(
        margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  height: 1.45,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );
}
