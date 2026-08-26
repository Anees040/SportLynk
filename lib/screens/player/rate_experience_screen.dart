import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/review.dart';
import '../../providers/auth_provider.dart';
import '../../services/review_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/trust_widgets.dart';

/// M24 — Rate Experience. One combined screen for both kinds of review, reached
/// from two places:
///   • the booking detail (a checked-in player rates the **venue**), and
///   • the match centre (a captain rates the opposing team's **sportsmanship**).
///
/// It renders only the sections the entry point enables. The one shared comment box
/// attaches to the *primary* review — the venue when present, otherwise the opponent
/// — because that is the review whose text the sentiment model scores, and its
/// verdict is the demo's payoff: submit, and the [SentimentChip] animates in reading
/// "😊 Positive (92%)".
///
/// The write path is deliberately forgiving: each review is a separate POST, a 409
/// ("already reviewed") on one doesn't sink the other, and a stars-only review (no
/// text) is valid — it simply carries no sentiment. Nothing here re-checks who may
/// review whom; the backend owns that (checked-in booking, completed match, captain
/// role) and answers 400/403 which we surface verbatim.
class RateExperienceScreen extends StatefulWidget {
  final String bookingId;
  final String? venueName;
  final String? opponentTeamName;
  final bool canReviewVenue;
  final bool canReviewOpponent;
  final String? dateLabel;

  const RateExperienceScreen({
    super.key,
    required this.bookingId,
    this.venueName,
    this.opponentTeamName,
    this.canReviewVenue = true,
    this.canReviewOpponent = false,
    this.dateLabel,
  });

  @override
  State<RateExperienceScreen> createState() => _RateExperienceScreenState();
}

class _RateExperienceScreenState extends State<RateExperienceScreen> {
  final ReviewService _service = ReviewService();
  final TextEditingController _comment = TextEditingController();

  int _venueStars = 0;
  int _oppStars = 0;
  bool _submitting = false;

  // Set once the submit completes with at least one saved review — the screen then
  // switches from the form to the confirmation, showing the model's verdict.
  bool _done = false;
  ReviewSentiment? _sentiment;

  bool get _showVenue => widget.canReviewVenue;
  bool get _showOpponent => widget.canReviewOpponent;

  /// The venue leads when both are offered — it is the review with the comment.
  bool get _primaryIsVenue => _showVenue;

  bool get _canSubmit =>
      (_showVenue && _venueStars > 0) || (_showOpponent && _oppStars > 0);

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = Provider.of<AuthProvider>(context, listen: false).token;
    if (token == null) {
      SnackbarUtil.showError(context, 'Please log in again.');
      return;
    }
    if (!_canSubmit) return;

    final comment = _comment.text.trim();
    final commentOrNull = comment.isEmpty ? null : comment;

    // Build the submission list primary-first. Only the primary carries the text,
    // so only the primary produces a sentiment verdict — which is what we animate in.
    final jobs = <({String type, int stars, String? text})>[];
    if (_showVenue && _venueStars > 0) {
      jobs.add((type: 'venue', stars: _venueStars, text: _primaryIsVenue ? commentOrNull : null));
    }
    if (_showOpponent && _oppStars > 0) {
      jobs.add((type: 'opponent', stars: _oppStars, text: _primaryIsVenue ? null : commentOrNull));
    }

    setState(() => _submitting = true);

    ReviewSentiment? primarySentiment;
    final errors = <String>[];
    var saved = 0;

    for (var i = 0; i < jobs.length; i++) {
      final j = jobs[i];
      final res = await _service.submitReview(
        token,
        bookingId: widget.bookingId,
        reviewType: j.type,
        stars: j.stars,
        text: j.text,
      );
      if (res['success'] == true) {
        saved++;
        final data = res['data'];
        if (i == 0 && data is Map && data['sentiment'] is Map) {
          primarySentiment =
              ReviewSentiment.fromJson(Map<String, dynamic>.from(data['sentiment'] as Map));
        }
      } else {
        errors.add(res['message']?.toString() ?? 'Could not submit your ${j.type} review.');
      }
    }

    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (saved > 0) {
        _done = true;
        _sentiment = primarySentiment;
      }
    });

    if (saved > 0 && errors.isEmpty) {
      SnackbarUtil.showSuccess(context, 'Thanks — your feedback is in.');
    } else if (saved > 0) {
      SnackbarUtil.showInfo(context, errors.first);
    } else {
      SnackbarUtil.showError(context, errors.isNotEmpty ? errors.first : 'Could not submit your review.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Rate Experience',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: 20),
            if (_done) _confirmation() else ..._form(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────
  Widget _header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.accentLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.stadium_rounded, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.venueName ?? 'Your booking',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (widget.opponentTeamName != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'vs ${widget.opponentTeamName}',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    if (widget.dateLabel != null)
                      Text(
                        widget.dateLabel!,
                        style: GoogleFonts.poppins(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Form ─────────────────────────────────────────────────────────────────
  List<Widget> _form() {
    return [
      if (_showVenue)
        _ratingSection(
          emoji: '🏟️',
          title: 'Rate the Venue',
          subtitle: 'Pitch quality, facilities, and the owner',
          value: _venueStars,
          onChanged: (v) => setState(() => _venueStars = v),
        ),
      if (_showVenue && _showOpponent) const SizedBox(height: 14),
      if (_showOpponent)
        _ratingSection(
          emoji: '🤝',
          title: 'Opponent Sportsmanship',
          subtitle: 'Fair play and conduct of ${widget.opponentTeamName ?? 'the opposing captain'}',
          badge: 'Captain only',
          value: _oppStars,
          onChanged: (v) => setState(() => _oppStars = v),
        ),
      const SizedBox(height: 16),
      SportTextField(
        label: 'Add a comment',
        hint: 'Share how it went…',
        prefixIcon: Icons.rate_review_outlined,
        controller: _comment,
        maxLines: 4,
        helperText: 'Optional. English or Roman-Urdu — our sentiment model reads both.',
      ),
      const SizedBox(height: 20),
      CustomButton(
        text: 'Submit Feedback',
        icon: Icons.send_rounded,
        isLoading: _submitting,
        onPressed: _canSubmit ? _submit : null,
      ),
      if (!_canSubmit) ...[
        const SizedBox(height: 10),
        Center(
          child: Text(
            'Tap the stars to rate before submitting.',
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      ],
    ];
  }

  Widget _ratingSection({
    required String emoji,
    required String title,
    required String subtitle,
    required int value,
    required ValueChanged<int> onChanged,
    String? badge,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    badge,
                    style: GoogleFonts.poppins(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: AppColors.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Center(
            child: Column(
              children: [
                StarRatingInput(value: value, onChanged: onChanged),
                const SizedBox(height: 8),
                Text(
                  _starWord(value),
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: value == 0 ? AppColors.textSecondary : AppColors.warning,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _starWord(int v) => switch (v) {
        1 => 'Poor',
        2 => 'Fair',
        3 => 'Good',
        4 => 'Great',
        5 => 'Excellent',
        _ => 'Tap to rate',
      };

  // ── Confirmation (the demo moment) ─────────────────────────────────────────
  Widget _confirmation() {
    final s = _sentiment;
    final hasVerdict = s != null && (s.scoredByModel || s.flagged || s.pending);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 16),
          child: Transform.scale(scale: 0.96 + 0.04 * t.clamp(0.0, 1.0), child: child),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.cardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded, color: AppColors.accent, size: 30),
                ),
                const SizedBox(height: 14),
                Text(
                  'Feedback submitted',
                  style: GoogleFonts.poppins(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasVerdict
                      ? 'Our sentiment model read your comment:'
                      : 'Thanks for helping keep SportLynk trustworthy.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary),
                ),
                if (hasVerdict) ...[
                  const SizedBox(height: 16),
                  SentimentChip.fromSentiment(s),
                  if (s.flagged) ...[
                    const SizedBox(height: 12),
                    Text(
                      'This comment was escalated for a moderator to review. '
                      'Your rating still counts.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        fontSize: 11.5,
                        height: 1.4,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          CustomButton(
            text: 'Done',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}
