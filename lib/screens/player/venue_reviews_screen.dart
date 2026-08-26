import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/review.dart';
import '../../providers/auth_provider.dart';
import '../../services/review_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/match_widgets.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/trust_widgets.dart';

/// The full, paginated reviews list for one venue. Reached from the "View all" on
/// the venue detail's Reviews summary.
///
/// The header aggregates (average, histogram, sentiment split) are **venue-wide** —
/// the backend computes them over every visible review, not just the loaded page —
/// so they stay correct as more pages load beneath them. Reviews accumulate as the
/// list is scrolled; the aggregates are read once from the first page and left alone.
class VenueReviewsScreen extends StatefulWidget {
  final String venueId;
  final String? venueName;

  const VenueReviewsScreen({super.key, required this.venueId, this.venueName});

  @override
  State<VenueReviewsScreen> createState() => _VenueReviewsScreenState();
}

class _VenueReviewsScreenState extends State<VenueReviewsScreen> {
  final ReviewService _service = ReviewService();
  final ScrollController _scroll = ScrollController();

  static const int _limit = 20;

  VenueReviews _agg = VenueReviews.empty; // header aggregates (page 1)
  final List<Review> _reviews = [];
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;

  bool get _hasMore => _page * _limit < _agg.total;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String? get _token => Provider.of<AuthProvider>(context, listen: false).token;

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final res = await _service.venueReviews(token, widget.venueId, page: 1, limit: _limit);
    if (!mounted) return;
    setState(() {
      _agg = res;
      _reviews
        ..clear()
        ..addAll(res.reviews);
      _page = 1;
      _loading = false;
    });
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final token = _token;
    if (token == null) return;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    final res = await _service.venueReviews(token, widget.venueId, page: next, limit: _limit);
    if (!mounted) return;
    setState(() {
      _reviews.addAll(res.reviews);
      _page = next;
      _loadingMore = false;
    });
  }

  Future<void> _flag(Review r) async {
    final reason = await showReviewFlagSheet(context);
    if (reason == null || !mounted) return;
    final token = _token;
    if (token == null) return;
    final res = await _service.flagReview(token, r.id, reason: reason.isEmpty ? null : reason);
    if (!mounted) return;
    if (res['success'] == true) {
      SnackbarUtil.showSuccess(context, 'Reported to moderators. Thanks for flagging.');
    } else {
      SnackbarUtil.showError(context, res['message']?.toString() ?? 'Could not report this review.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          widget.venueName == null ? 'Reviews' : '${widget.venueName} · Reviews',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : RefreshIndicator(
              color: AppColors.accent,
              onRefresh: _load,
              child: _reviews.isEmpty && _agg.total == 0
                  ? const MatchEmptyState(
                      icon: Icons.reviews_outlined,
                      text: 'No reviews yet.\nBe the first to rate this venue after you play.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                      padding: const EdgeInsets.all(16),
                      itemCount: _reviews.length + 2, // header + footer
                      itemBuilder: (context, i) {
                        if (i == 0) return _summaryHeader();
                        if (i == _reviews.length + 1) return _footer();
                        return ReviewCard(review: _reviews[i - 1], onFlag: () => _flag(_reviews[i - 1]));
                      },
                    ),
            ),
    );
  }

  Widget _summaryHeader() {
    final avg = _agg.avgStars ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                children: [
                  Text(
                    _agg.avgStars == null ? '—' : avg.toStringAsFixed(1),
                    style: GoogleFonts.poppins(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      height: 1,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  StarsDisplay(rating: avg, size: 15),
                  const SizedBox(height: 4),
                  Text(
                    '${_agg.total} ${_agg.total == 1 ? 'review' : 'reviews'}',
                    style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
                  ),
                ],
              ),
              const SizedBox(width: 18),
              Expanded(child: StarsHistogram(counts: _agg.starCounts)),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 14),
          Text(
            'Sentiment of written reviews',
            style: GoogleFonts.poppins(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          SentimentSummaryBar(distribution: _agg.sentiment),
        ],
      ),
    );
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    if (!_hasMore && _reviews.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            'That\'s all ${_agg.total} reviews.',
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}

/// A shared "report this review" sheet used wherever a review can be flagged (venue
/// reviews, owner's venue reviews). Returns the chosen reason, `''` for "report with
/// no reason given", or `null` if the user dismissed it without reporting.
Future<String?> showReviewFlagSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _FlagSheet(),
  );
}

class _FlagSheet extends StatefulWidget {
  const _FlagSheet();

  @override
  State<_FlagSheet> createState() => _FlagSheetState();
}

class _FlagSheetState extends State<_FlagSheet> {
  final TextEditingController _reason = TextEditingController();

  static const List<String> _presets = [
    'Offensive or abusive language',
    'Spam or fake review',
    'Off-topic / irrelevant',
    'Personal or private information',
  ];
  String? _selected;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        decoration: const BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
              'Report this review',
              style: GoogleFonts.poppins(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'A moderator will take a look. Pick a reason (optional).',
              style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presets.map((p) {
                final on = _selected == p;
                return GestureDetector(
                  onTap: () => setState(() => _selected = on ? null : p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: on ? AppColors.accentLight : AppColors.inputFill,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: on ? AppColors.accent : AppColors.border),
                    ),
                    child: Text(
                      p,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: on ? AppColors.accent : AppColors.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            SportTextField(
              hint: 'Add any detail (optional)…',
              prefixIcon: Icons.edit_note_outlined,
              controller: _reason,
              maxLines: 3,
            ),
            const SizedBox(height: 18),
            CustomButton(
              text: 'Report Review',
              icon: Icons.flag_rounded,
              onPressed: () {
                final typed = _reason.text.trim();
                final reason = typed.isNotEmpty ? typed : (_selected ?? '');
                Navigator.of(context).pop(reason);
              },
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.poppins(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
