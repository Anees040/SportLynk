import 'api_service.dart';
import '../constants/api_constants.dart';
import '../models/review.dart';

/// The reviews / Trust 2.0 / moderation data gateway (S.4 Wave D).
///
/// Same split as `MatchService`: **reads** unwrap the envelope and return a typed
/// model (or its `.empty` sentinel, never a throw), so a screen can bind straight
/// to the result; **mutations** return the raw `{success, message, data}` map so the
/// caller can drive `SnackbarUtil` and — for a submitted review — reach into
/// `data.sentiment` to animate the chip. Every method takes the auth `token` first,
/// because all of these routes sit behind `authMiddleware`.
class ReviewService {
  final ApiClient _api = ApiClient();

  // ── Writes (raw envelope) ──────────────────────────────────────────────────

  /// Submit one review. `reviewType` is `'venue'` or `'opponent'`; for an opponent
  /// review the backend DERIVES the reviewed captain from the booking, so we never
  /// send a target id. `text` is omitted entirely when blank (a stars-only review
  /// is valid and simply won't carry a sentiment verdict).
  ///
  /// Returns the raw envelope. On 201 `data.sentiment` holds the live verdict; the
  /// caller reads it via [ReviewSentiment.fromJson]. A 409 (`already reviewed`) and a
  /// 400 (wrong booking state) both come back as `success:false` with a message.
  Future<Map<String, dynamic>> submitReview(
    String token, {
    required String bookingId,
    required String reviewType,
    required int stars,
    String? text,
  }) {
    final body = <String, dynamic>{
      'bookingId': bookingId,
      'reviewType': reviewType,
      'stars': stars,
    };
    final t = text?.trim();
    if (t != null && t.isNotEmpty) body['text'] = t;
    return _api.post(ApiConstants.reviews, body, token: token);
  }

  /// Report a review for a moderator to look at. `reason` is optional (max 500 on
  /// the server). Raw envelope; 409 if the caller already reported this review.
  Future<Map<String, dynamic>> flagReview(
    String token,
    String reviewId, {
    String? reason,
  }) {
    final body = <String, dynamic>{};
    final r = reason?.trim();
    if (r != null && r.isNotEmpty) body['reason'] = r;
    return _api.post(ApiConstants.flagReview(reviewId), body, token: token);
  }

  /// Act on a queued review (admin). `action` ∈ `hide` | `restore` | `dismiss`.
  /// Raw envelope so the queue screen can toast the returned message.
  Future<Map<String, dynamic>> moderate(
    String token,
    String reviewId,
    String action,
  ) {
    return _api.patch(
      ApiConstants.adminModerateReview(reviewId),
      {'action': action},
      token: token,
    );
  }

  // ── Reads (typed) ──────────────────────────────────────────────────────────

  /// One page of a venue's reviews plus the venue-wide aggregates. Returns
  /// [VenueReviews.empty] on any failure so the UI shows an empty state, not a crash.
  Future<VenueReviews> venueReviews(
    String token,
    String venueId, {
    int page = 1,
    int limit = 20,
  }) async {
    final r = await _api.get(
      ApiConstants.venueReviews(venueId),
      token: token,
      queryParams: {'page': '$page', 'limit': '$limit'},
    );
    if (r['success'] != true || r['data'] is! Map) return VenueReviews.empty;
    return VenueReviews.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// A user's received reviews plus their stored trust breakdown (M25). Returns
  /// [UserReviews.empty] on failure.
  Future<UserReviews> userReviews(
    String token,
    String userId, {
    int page = 1,
    int limit = 20,
  }) async {
    final r = await _api.get(
      ApiConstants.userReviews(userId),
      token: token,
      queryParams: {'page': '$page', 'limit': '$limit'},
    );
    if (r['success'] != true || r['data'] is! Map) return UserReviews.empty;
    return UserReviews.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// The moderation queue (admin). Returns an empty list on failure — the screen
  /// tells hide/restore/dismiss apart from "nothing to moderate" via a flag it
  /// tracks itself, so a bare `[]` here is safe.
  Future<List<FlaggedReview>> moderationQueue(String token) async {
    final r = await _api.get(ApiConstants.adminFlaggedReviews, token: token);
    if (r['success'] != true || r['data'] is! List) return const [];
    return (r['data'] as List)
        .whereType<Map>()
        .map((x) => FlaggedReview.fromJson(Map<String, dynamic>.from(x)))
        .toList();
  }
}
