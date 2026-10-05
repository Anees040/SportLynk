import '../constants/api_constants.dart';
import '../models/public_profile.dart';
import 'api_service.dart';

/// Reads another user's public-facing profile (module 8c).
///
/// A thin wrapper over [ApiClient] that maps the `{success, data}` envelope into a
/// [PublicProfile] and never throws. [publicProfile] returns `null` when the call did
/// not land (a cold network, a 404, a server error), so the screen can tell "could not
/// load" apart from a real profile and show a retry rather than a blank — the same
/// convention [RequestService] follows. Visibility is the server's decision: a private
/// profile still returns 200 with only its header, and the model carries the flag.
class UserService {
  final ApiClient _api = ApiClient();

  Future<PublicProfile?> publicProfile(String token, String userId) async {
    final r = await _api.get(ApiConstants.userPublicProfile(userId), token: token);
    if (r['success'] != true || r['data'] is! Map) return null;
    return PublicProfile.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }
}
