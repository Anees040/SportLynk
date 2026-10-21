import '../constants/api_constants.dart';
import '../models/public_profile.dart';
import 'api_service.dart';

/// Reads another user's public-facing profile (module 8c).
///
/// Maps the API envelope into a profile or a readable failure, so server errors
/// are not mistaken for connection failures. Visibility is the server's decision: a private
/// profile still returns 200 with only its header, and the model carries the flag.
class PublicProfileResult {
  final PublicProfile? profile;
  final String? error;

  const PublicProfileResult({this.profile, this.error});
}

class UserService {
  final ApiClient _api = ApiClient();

  Future<PublicProfileResult> publicProfile(String token, String userId, {String? ownerBookingId}) async {
    final path = ownerBookingId == null
        ? ApiConstants.userPublicProfile(userId)
        : ApiConstants.ownerBookingPlayerProfile(ownerBookingId);
    var r = await _api.get(path, token: token);
    // Older deployments have the shared public-profile route but not the newer
    // booking lookup. Only fall back when that route is absent, never when an
    // existing booking route denies access or says the booking was not found.
    if (ownerBookingId != null &&
        userId.trim().isNotEmpty &&
        r['statusCode'] == 404 &&
        r['message'] == 'Route not found') {
      r = await _api.get(ApiConstants.userPublicProfile(userId), token: token);
    }
    if (r['success'] != true) {
      final message = r['message'];
      return PublicProfileResult(error: message == 'Route not found'
          ? 'Player profiles are unavailable on the server. Please try again later.'
          : message is String && message.isNotEmpty
              ? message
              : 'The server could not load this profile. Please try again.');
    }
    try {
      if (r['data'] is Map) {
        return PublicProfileResult(
          profile: PublicProfile.fromJson(Map<String, dynamic>.from(r['data'] as Map)),
        );
      }
    } catch (_) {
      // A malformed response is a server problem, not a lost connection.
    }
    return const PublicProfileResult(
      error: 'The server returned an invalid player profile. Please try again.',
    );
  }
}
