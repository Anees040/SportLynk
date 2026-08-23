import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../models/match.dart';
import '../services/match_service.dart';
import '../utils/snackbar_util.dart';
import 'match_widgets.dart';

/// The two sheets that change a match's outcome: submitting a result (ER2.1) and
/// flagging one (FR5.17).
///
/// They live outside the Match Center because both are opened from more than one
/// place — the upcoming list, a history row, and (for the result) a match detail —
/// and because each carries a warning that must read identically everywhere. A
/// submission is one-shot and a dispute is on a clock; wording either of them
/// differently on two screens would be the same as wording it wrongly on one.
///
/// Each sheet performs its own call and resolves `true` only on a confirmed
/// success, so callers do nothing but `if (ok == true) reload()`.

// ═══════════════════════════════════════════════════════════════
//  Submit a result (ER2.1)
// ═══════════════════════════════════════════════════════════════

Future<bool?> showMatchResultSheet(
  BuildContext context, {
  required MatchModel match,
  required String token,
}) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ResultSheet(match: match, token: token),
    );

class _ResultSheet extends StatefulWidget {
  final MatchModel match;
  final String token;
  const _ResultSheet({required this.match, required this.token});

  @override
  State<_ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<_ResultSheet> {
  final _service = MatchService();

  /// Held challenger-first, in the match's own orientation, because that is what
  /// the API stores and what makes the two captains' submissions comparable. The
  /// rows below are re-ordered for the viewer; the numbers are not.
  int _challenger = 0;
  int _opponent = 0;
  bool _sending = false;

  static const _max = 99;

  MatchSide get _me => widget.match.myTeam;
  MatchSide get _them => widget.match.theirTeam;

  int get _myScore => widget.match.iAmChallenger ? _challenger : _opponent;
  int get _theirScore => widget.match.iAmChallenger ? _opponent : _challenger;

  void _bump(bool mine, int by) {
    setState(() {
      final challengerIsMine = widget.match.iAmChallenger;
      final touchChallenger = mine == challengerIsMine;
      if (touchChallenger) {
        _challenger = (_challenger + by).clamp(0, _max);
      } else {
        _opponent = (_opponent + by).clamp(0, _max);
      }
    });
  }

  /// Sent as a confirmation of what the scores already say. The server derives the
  /// winner itself and rejects a submission whose stated winner disagrees, so this
  /// is a cross-check, not the source of truth.
  String? get _winnerTeam {
    if (_challenger == _opponent) return null;
    return _challenger > _opponent
        ? widget.match.challenger.id
        : widget.match.opponent.id;
  }

  String get _verdict {
    if (_challenger == _opponent) return 'Draw';
    return '${_myScore > _theirScore ? _me.name : _them.name} wins';
  }

  Future<void> _submit() async {
    if (_sending) return;
    setState(() => _sending = true);

    final r = await _service.submitResult(
      widget.token,
      widget.match.id,
      scoreChallenger: _challenger,
      scoreOpponent: _opponent,
      winnerTeam: _winnerTeam,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    if (r['success'] == true) {
      final data = r['data'];
      // The backend tells us whether this submission completed the pair and, if
      // so, whether the two agreed. Relaying its own words is the difference
      // between a captain knowing a dispute was opened and being surprised later.
      final status = data is Map ? '${data['status'] ?? ''}' : '';
      Navigator.pop(context, true);
      if (status == MatchStatus.disputed) {
        SnackbarUtil.showError(context,
            'Your result does not match your opponent\'s. The match is now disputed and an admin will review it.');
      } else if (status == MatchStatus.awaitingOwner) {
        SnackbarUtil.showSuccess(
            context, 'Both captains agree. The venue owner will verify the result.');
      } else {
        SnackbarUtil.showSuccess(
            context, 'Result submitted. Waiting for the other captain.');
      }
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not submit the result.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.disabled,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Submit final score',
                style: GoogleFonts.poppins(
                  fontSize: 16.5,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: Text(
                  '${_me.name} vs ${_them.name}',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _stepper(_me, _myScore, mine: true),
              const Divider(height: 1, color: AppColors.divider),
              _stepper(_them, _theirScore, mine: false),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.inputFill,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _verdict,
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lock_clock, size: 16, color: AppColors.warning),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'You can submit once. If the other captain reports a different score the match is frozen as disputed and no ratings move until an admin resolves it.',
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          height: 1.45,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                          side: const BorderSide(color: AppColors.border),
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed:
                            _sending ? null : () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          disabledBackgroundColor: AppColors.disabled,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _sending ? null : _submit,
                        child: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Text(
                                'Submit $_myScore – $_theirScore',
                                style:
                                    GoogleFonts.poppins(fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepper(MatchSide side, int value, {required bool mine}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            TeamCrest(logoUrl: side.logoUrl, radius: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    side.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    mine ? 'Your team' : 'Opponent',
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            _stepButton(Icons.remove, value > 0 ? () => _bump(mine, -1) : null),
            SizedBox(
              width: 44,
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            _stepButton(Icons.add, value < _max ? () => _bump(mine, 1) : null),
          ],
        ),
      );

  Widget _stepButton(IconData icon, VoidCallback? onTap) => Material(
        color: onTap == null ? AppColors.inputFill : AppColors.accentLight,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(
              icon,
              size: 19,
              color: onTap == null ? AppColors.disabled : AppColors.primary,
            ),
          ),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════
//  Flag a result (FR5.17)
// ═══════════════════════════════════════════════════════════════

Future<bool?> showMatchDisputeSheet(
  BuildContext context, {
  required MatchModel match,
  required String token,
  required int windowHours,
}) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DisputeSheet(
        match: match,
        token: token,
        windowHours: windowHours,
      ),
    );

class _DisputeSheet extends StatefulWidget {
  final MatchModel match;
  final String token;
  final int windowHours;
  const _DisputeSheet({
    required this.match,
    required this.token,
    required this.windowHours,
  });

  @override
  State<_DisputeSheet> createState() => _DisputeSheetState();
}

class _DisputeSheetState extends State<_DisputeSheet> {
  final _service = MatchService();
  final _ctrl = TextEditingController();
  bool _sending = false;

  /// The backend enforces a minimum too. Mirroring it here means the captain finds
  /// out while they are still typing rather than after a round trip.
  static const _minChars = 10;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _ctrl.text.trim();
    if (reason.length < _minChars) return;
    if (_sending) return;

    setState(() => _sending = true);
    final r = await _service.dispute(widget.token, widget.match.id, reason);
    if (!mounted) return;
    setState(() => _sending = false);

    if (r['success'] == true) {
      Navigator.pop(context, true);
      SnackbarUtil.showSuccess(context,
          'Flagged for review. Ratings from this match stay frozen until an admin decides.');
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not file the dispute.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final enough = _ctrl.text.trim().length >= _minChars;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom + 16),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.disabled,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.gavel, size: 19, color: AppColors.error),
                  const SizedBox(width: 8),
                  Text(
                    'Flag this result',
                    style: GoogleFonts.poppins(
                      fontSize: 16.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'A result can be flagged within ${widget.windowHours} hours of being verified. Say what was wrong — an admin reads this and nothing else.',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _ctrl,
                autofocus: true,
                maxLines: 4,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'e.g. The final score was 2–1, not 3–1. Second goal was disallowed.',
                  hintStyle: GoogleFonts.poppins(
                      fontSize: 12.5, color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.inputFill,
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                enough
                    ? 'Ready to send'
                    : 'At least $_minChars characters so it can be acted on',
                style: GoogleFonts.poppins(
                  fontSize: 10.5,
                  color: enough ? AppColors.success : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.ac_unit, size: 16, color: AppColors.error),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Disputing repeatedly gets a team\'s rating frozen platform-wide. Use this when the result is genuinely wrong.',
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          height: 1.45,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        side: const BorderSide(color: AppColors.border),
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _sending ? null : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.error,
                        disabledBackgroundColor: AppColors.disabled,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: (!enough || _sending) ? null : _submit,
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text('Flag',
                              style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
