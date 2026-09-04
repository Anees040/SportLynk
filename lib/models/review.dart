library;

import '../utils/num_util.dart';

/// Wire models for the reviews / Trust 2.0 / moderation stack.
///
/// These mirror `routes/reviews.js` and `routes/admin.js` one field at a time.
/// Those endpoints answer in **camelCase** (unlike the older snake_case reads), so
/// every key below is camelCase — the one casing trap that turns a populated screen
/// blank if the wrong endpoint's convention is mirrored.
///
/// Numbers come through [num_util]: Postgres hands back `DECIMAL`/`NUMERIC` as
/// Strings, so `avgStars` arrives as `"4.25"` and every trust component as a
/// stringified fraction. The rule the backend is careful about, and so is this model:
/// **a null component is "no data yet", never a zero.** A user with no disputes on
/// record has `disputes == null`, which the UI must say out loud rather than
/// drawing an empty bar that reads as "0% dispute-free".

String? _str(dynamic v) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? null : s;
}

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

bool _bool(dynamic v) => v == true;

/// The model's verdict on one review's text, as returned inside `POST /api/reviews`.
///
/// [source] is the honesty marker: `'model'` (the trained classifier scored it),
/// `'unavailable'` (ml-service was down — the review still saved, sentiment fills in
/// later via the backfill job), or `null` (there was no text to score). The chip
/// renders all three states differently, so the distinction is kept, not flattened.
class ReviewSentiment {
  final String? label; // 'positive' | 'neutral' | 'negative' | null
  final double? score; // signed magnitude in [-1, 1]; null when not scored
  final bool flagged; // model escalated it for a moderator's eye
  final String? source; // 'model' | 'unavailable' | null

  const ReviewSentiment({this.label, this.score, this.flagged = false, this.source});

  factory ReviewSentiment.fromJson(Map<String, dynamic> j) => ReviewSentiment(
        label: _str(j['label']),
        score: asNumOrNull(j['score']),
        flagged: _bool(j['flagged']),
        source: _str(j['source']),
      );

  /// The classifier ran. `false` for both "server was down" and "no text".
  bool get scoredByModel => source == 'model' && label != null;

  /// The review saved but the model was unreachable — the "added shortly" state.
  bool get pending => source == 'unavailable';

  /// A confidence percentage for display: `Positive (92%)`. The label already
  /// carries the polarity, so the magnitude is what the number communicates.
  int? get percent => score == null ? null : (score!.abs() * 100).round().clamp(0, 100);

  static const ReviewSentiment empty = ReviewSentiment();
}

/// One review as it appears in a list — a venue's reviews, or the reviews a user
/// has received. [reviewType] is only present on the user (received) feed, where a
/// row can be a `venue` or an `opponent` review; on a venue feed it is null.
class Review {
  final String id;
  final int stars;
  final String? text;
  final String? reviewerName;
  final String? reviewType; // 'venue' | 'opponent' | null
  final String? sentimentLabel; // null = not scored yet
  final DateTime? createdAt;

  const Review({
    required this.id,
    required this.stars,
    this.text,
    this.reviewerName,
    this.reviewType,
    this.sentimentLabel,
    this.createdAt,
  });

  factory Review.fromJson(Map<String, dynamic> j) => Review(
        id: '${j['id']}',
        stars: asInt(j['stars']),
        text: _str(j['text']),
        reviewerName: _str(j['reviewerName']),
        reviewType: _str(j['reviewType']),
        sentimentLabel: _str(j['sentimentLabel']),
        createdAt: _date(j['createdAt']),
      );

  bool get isOpponent => reviewType == 'opponent';

  /// `2h ago`, `3d ago`, `just now`. Written out rather than adding a date package
  /// for one label, matching `LinkableBooking.prettyDate` in match.dart.
  String get relativeTime {
    final t = createdAt;
    if (t == null) return '';
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
    return '${(diff.inDays / 365).floor()}y ago';
  }
}

/// The positive/neutral/negative counts over a venue's visible reviews. Unscored
/// (NULL-label) reviews are in none of the three — the total here can be less than
/// the review count, by design.
class SentimentDistribution {
  final int positive;
  final int neutral;
  final int negative;

  const SentimentDistribution({this.positive = 0, this.neutral = 0, this.negative = 0});

  factory SentimentDistribution.fromJson(Map<String, dynamic> j) => SentimentDistribution(
        positive: asInt(j['positive']),
        neutral: asInt(j['neutral']),
        negative: asInt(j['negative']),
      );

  int get total => positive + neutral + negative;
  bool get isEmpty => total == 0;

  double _frac(int n) => total == 0 ? 0 : n / total;
  double get positiveFraction => _frac(positive);
  double get neutralFraction => _frac(neutral);
  double get negativeFraction => _frac(negative);

  static const SentimentDistribution empty = SentimentDistribution();
}

/// `GET /api/venues/:id/reviews` — one page of reviews plus the venue-wide
/// aggregates (which are computed over all visible reviews, not just this page).
class VenueReviews {
  final String venueId;
  final int page;
  final int limit;
  final int total;
  final double? avgStars; // null when the venue has no reviews at all
  final SentimentDistribution sentiment;

  /// Per-star counts, high→low: `starCounts[0]` is the number of 5★ reviews,
  /// `starCounts[4]` the number of 1★. Venue-wide (matches [total]/[avgStars]),
  /// so the histogram never misdescribes a busy venue from one loaded page.
  final List<int> starCounts;
  final List<Review> reviews;

  const VenueReviews({
    required this.venueId,
    required this.page,
    required this.limit,
    required this.total,
    required this.avgStars,
    required this.sentiment,
    required this.starCounts,
    required this.reviews,
  });

  factory VenueReviews.fromJson(Map<String, dynamic> j) => VenueReviews(
        venueId: '${j['venueId'] ?? ''}',
        page: asInt(j['page'], fallback: 1),
        limit: asInt(j['limit'], fallback: 20),
        total: asInt(j['total']),
        avgStars: asNumOrNull(j['avgStars']),
        sentiment: j['sentimentDistribution'] is Map
            ? SentimentDistribution.fromJson(
                Map<String, dynamic>.from(j['sentimentDistribution'] as Map))
            : SentimentDistribution.empty,
        starCounts: _starCounts(j['starCounts']),
        reviews: (j['reviews'] as List? ?? const [])
            .whereType<Map>()
            .map((x) => Review.fromJson(Map<String, dynamic>.from(x)))
            .toList(),
      );

  /// The tallest bar, so the histogram can scale its fills. 1 when empty (avoids
  /// a divide-by-zero and simply draws five empty tracks).
  int get maxStarCount =>
      starCounts.fold<int>(1, (m, c) => c > m ? c : m);

  /// True when there are more pages to fetch (drives the infinite list).
  bool get hasMore => page * limit < total;

  static const VenueReviews empty = VenueReviews(
    venueId: '',
    page: 1,
    limit: 20,
    total: 0,
    avgStars: null,
    sentiment: SentimentDistribution.empty,
    starCounts: [0, 0, 0, 0, 0],
    reviews: [],
  );
}

/// Parse the `{"5":n,"4":n,…}` star-count map into a fixed [5★,4★,3★,2★,1★] list.
/// Tolerates the field being absent (older backend) → all zeros.
List<int> _starCounts(dynamic raw) {
  if (raw is! Map) return const [0, 0, 0, 0, 0];
  return [
    asInt(raw['5']),
    asInt(raw['4']),
    asInt(raw['3']),
    asInt(raw['2']),
    asInt(raw['1']),
  ];
}

/// The stored Trust Score 2.0 breakdown (ER2.5): the headline 0–100 [score] plus
/// the four weighted components, each a fraction in `[0, 1]` or **null** when the
/// user has no signal of that kind yet.
///
/// Weights are fixed by the backend (`utils/trustScore.WEIGHTS`) and repeated here
/// only so a tile can show "contributes N pts", never to recompute the score — the
/// server owns the arithmetic.
class TrustBreakdown {
  final int? score; // 0..100, or null for a profile with no player_profiles row
  final double? rating; // avg star rating, normalised 0..1
  final double? attendance; // check-in rate 0..1
  final double? disputes; // dispute-free rate 0..1
  final double? sentiment; // avg review sentiment, normalised 0..1

  const TrustBreakdown({
    this.score,
    this.rating,
    this.attendance,
    this.disputes,
    this.sentiment,
  });

  factory TrustBreakdown.fromJson(Map<String, dynamic> j) => TrustBreakdown(
        score: j['score'] == null ? null : asInt(j['score']),
        rating: asNumOrNull(j['rating']),
        attendance: asNumOrNull(j['attendance']),
        disputes: asNumOrNull(j['disputes']),
        sentiment: asNumOrNull(j['sentiment']),
      );

  // The published weights (sum = 100). Display-only.
  static const int wRating = 35;
  static const int wAttendance = 30;
  static const int wDisputes = 20;
  static const int wSentiment = 15;

  static const TrustBreakdown empty = TrustBreakdown();
}

/// `GET /api/users/:id/reviews` — reviews a user has received plus their trust
/// ledger. Feeds the M25 Trust Profile screen.
class UserReviews {
  final String userId;
  final int page;
  final int limit;
  final int total;
  final double? avgStars;
  final TrustBreakdown trust;
  final List<Review> reviews;

  const UserReviews({
    required this.userId,
    required this.page,
    required this.limit,
    required this.total,
    required this.avgStars,
    required this.trust,
    required this.reviews,
  });

  factory UserReviews.fromJson(Map<String, dynamic> j) => UserReviews(
        userId: '${j['userId'] ?? ''}',
        page: asInt(j['page'], fallback: 1),
        limit: asInt(j['limit'], fallback: 20),
        total: asInt(j['total']),
        avgStars: asNumOrNull(j['avgStars']),
        trust: j['trust'] is Map
            ? TrustBreakdown.fromJson(Map<String, dynamic>.from(j['trust'] as Map))
            : TrustBreakdown.empty,
        reviews: (j['reviews'] as List? ?? const [])
            .whereType<Map>()
            .map((x) => Review.fromJson(Map<String, dynamic>.from(x)))
            .toList(),
      );

  bool get hasMore => page * limit < total;

  static const UserReviews empty = UserReviews(
    userId: '',
    page: 1,
    limit: 20,
    total: 0,
    avgStars: null,
    trust: TrustBreakdown.empty,
    reviews: [],
  );
}

/// One manual report on a review, as surfaced in the admin queue. An
/// auto-escalation by the sentiment model produces no row of this kind — the
/// review is simply `flagged=true` with an empty [FlaggedReview.flags] list.
class ReviewFlag {
  final String? reason;
  final String? flaggedByName;
  final DateTime? createdAt;

  const ReviewFlag({this.reason, this.flaggedByName, this.createdAt});

  factory ReviewFlag.fromJson(Map<String, dynamic> j) => ReviewFlag(
        reason: _str(j['reason']),
        flaggedByName: _str(j['flaggedByName']),
        createdAt: _date(j['createdAt']),
      );
}

/// A row in the moderation queue (`GET /api/admin/reviews/flagged`). Carries enough
/// context — who is reviewed, which venue, the sentiment verdict, every manual
/// report — for an admin to act without opening a second screen.
class FlaggedReview {
  final String id;
  final int stars;
  final String? text;
  final String? reviewerName;
  final String? reviewType;
  final String? reviewedUserId;
  final String? reviewedUserName;
  final String? venueId;
  final String? venueName;
  final String? sentimentLabel;
  final double? sentimentScore;
  final bool flagged;
  final bool hidden;
  final int openFlagCount;
  final List<ReviewFlag> flags;
  final DateTime? createdAt;

  const FlaggedReview({
    required this.id,
    required this.stars,
    this.text,
    this.reviewerName,
    this.reviewType,
    this.reviewedUserId,
    this.reviewedUserName,
    this.venueId,
    this.venueName,
    this.sentimentLabel,
    this.sentimentScore,
    this.flagged = false,
    this.hidden = false,
    this.openFlagCount = 0,
    this.flags = const [],
    this.createdAt,
  });

  factory FlaggedReview.fromJson(Map<String, dynamic> j) => FlaggedReview(
        id: '${j['id']}',
        stars: asInt(j['stars']),
        text: _str(j['text']),
        reviewerName: _str(j['reviewerName']),
        reviewType: _str(j['reviewType']),
        reviewedUserId: _str(j['reviewedUserId']),
        reviewedUserName: _str(j['reviewedUserName']),
        venueId: _str(j['venueId']),
        venueName: _str(j['venueName']),
        sentimentLabel: _str(j['sentimentLabel']),
        sentimentScore: asNumOrNull(j['sentimentScore']),
        flagged: _bool(j['flagged']),
        hidden: _bool(j['hidden']),
        openFlagCount: asInt(j['openFlagCount']),
        flags: (j['flags'] as List? ?? const [])
            .whereType<Map>()
            .map((x) => ReviewFlag.fromJson(Map<String, dynamic>.from(x)))
            .toList(),
        createdAt: _date(j['createdAt']),
      );

  /// Reported by a human vs. escalated by the model. When there are no manual
  /// reports but the review is flagged, the sentiment model raised it — the queue
  /// labels that case "Auto-flagged by sentiment model".
  bool get hasManualReports => flags.isNotEmpty || openFlagCount > 0;
  bool get isAutoFlagged => flagged && !hidden && !hasManualReports;

  /// Whether this row is an opponent (captain conduct) review vs. a venue review.
  bool get isOpponent => reviewType == 'opponent';

  /// Who/what the review is about, for the queue's context line.
  String get subjectLabel {
    if (isOpponent) return reviewedUserName ?? 'a player';
    return venueName ?? 'a venue';
  }
}
