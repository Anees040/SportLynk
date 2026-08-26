import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/review.dart';
import '../../providers/auth_provider.dart';
import '../../services/review_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';
import '../../widgets/trust_widgets.dart';
import '../player/venue_reviews_screen.dart' show showReviewFlagSheet;

/// The owner's window onto one venue's reviews. Read-only by design: an owner can
/// *report* a review they believe breaks the rules (it goes to the same admin queue
/// as a player's report), but cannot hide or edit it themselves — moderation stays
/// with admins so an owner can't quietly bury honest criticism.
class OwnerVenueReviewsScreen extends StatefulWidget {
  final String venueId;
  final String? venueName;

  const OwnerVenueReviewsScreen({super.key, required this.venueId, this.venueName});

  @override
  State<OwnerVenueReviewsScreen> createState() => _OwnerVenueReviewsScreenState();
}

class _OwnerVenueReviewsScreenState extends State<OwnerVenueReviewsScreen> {
  final ReviewService _service = ReviewService();
  final ScrollController _scroll = ScrollController();

  static const int _limit = 20;

  VenueReviews _agg = VenueReviews.empty;
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
      SnackbarUtil.showSuccess(context, 'Reported to moderators for review.');
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
          widget.venueName == null ? 'Venue Reviews' : '${widget.venueName} · Reviews',
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
                      text: 'No reviews yet.\nReviews appear here once players rate this venue.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                      padding: const EdgeInsets.all(16),
                      itemCount: _reviews.length + 2,
                      itemBuilder: (context, i) {
                        if (i == 0) return _header();
                        if (i == _reviews.length + 1) return _footer();
                        return ReviewCard(review: _reviews[i - 1], onFlag: () => _flag(_reviews[i - 1]));
                      },
                    ),
            ),
    );
  }

  Widget _header() {
    final avg = _agg.avgStars ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
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
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'You can report a review for moderation, but only admins can hide it — '
                  'so honest feedback stays visible.',
                  style: GoogleFonts.poppins(
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
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
