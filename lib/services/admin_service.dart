import '../constants/api_constants.dart';
import '../models/admin.dart';
import 'api_service.dart';

/// One page of a cursor-paginated admin list.
///
/// `nextCursor` is passed back to the server verbatim. The dispute cursor is a
/// `"<severityElo>~<createdAt>~<id>"` triple — the queue is ordered by what is at
/// stake and only then by age, so a cursor built from a timestamp alone would page
/// wrong and silently skip rows at a page boundary. Nothing on this side parses
/// one or builds one; that is the whole reason it is opaque.
class AdminPage<T> {
  final List<T> items;
  final bool hasMore;
  final String? nextCursor;

  const AdminPage({
    required this.items,
    this.hasMore = false,
    this.nextCursor,
  });

  bool get isEmpty => items.isEmpty;
}

/// REST for the admin surface: the dispute queue and its case files, the user
/// list with suspend/reinstate, and the platform settings.
///
/// Every DECISION here is the server's. This class carries no policy: it does not
/// compute severity, does not decide which ruling actions are legal, does not hold
/// a copy of the settings catalogue, and does not derive whether a user is
/// suspended. An admin screen that disagrees with the backend about what is
/// allowed offers a button that fails on submit, which is worse than no button.
///
/// Reads return a safe empty value on failure. Writes return the raw envelope —
/// `{success, message, data}` — because an admin action that fails must show the
/// server's own message (a 409 `sport_has_bookings`, a refused self-suspension, a
/// ruling blocked by `elo_applied`), and swallowing it into `null` would leave the
/// admin guessing.
class AdminService {
  final ApiClient _api = ApiClient();

  // Disputes (FR10.6, FR10.7)

  /// `status` is one of `open` · `resolved` · `dismissed` · `all`; anything else
  /// is normalised to `open` server-side.
  Future<AdminPage<DisputeRow>> disputes(
    String token, {
    String status = 'open',
    String? cursor,
    int limit = 25,
  }) async {
    final params = <String, String>{'status': status, 'limit': '$limit'};
    if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;
    final r = await _api.get(ApiConstants.adminDisputes,
        token: token, queryParams: params);
    if (r['success'] != true || r['data'] is! Map) {
      return const AdminPage<DisputeRow>(items: []);
    }
    final d = Map<String, dynamic>.from(r['data'] as Map);
    final items = (d['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => DisputeRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    final next = d['nextCursor']?.toString();
    return AdminPage<DisputeRow>(
      items: items,
      // The queue reports `count` and a cursor; "more" is the cursor's presence,
      // which is the only thing that can continue the page.
      hasMore: next != null && next.isNotEmpty,
      nextCursor: next,
    );
  }

  /// The case file: both submissions, both rosters, the booking evidence, the
  /// captain-channel archive and what the server says may be done about it.
  Future<DisputeCase?> disputeCase(String token, String id) async {
    final r = await _api.get(ApiConstants.adminDispute(id), token: token);
    if (r['success'] != true || r['data'] is! Map) return null;
    return DisputeCase.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// `action` is one of `rule_challenger` · `rule_opponent` · `rule_draw` ·
  /// `rule_custom` · `dismiss`. The two scores are sent only for `rule_custom`
  /// (and for a `rule_draw` that needs a scoreline the submissions do not supply)
  /// — the server adopts a team's own submission for the two `rule_*` team forms,
  /// so sending scores there would be the client deciding the result.
  ///
  /// Returns the raw envelope: `message` is the server's receipt, which names the
  /// scoreline, whether Elo was applied or corrected, and whether a bracket
  /// advanced. The screen shows that sentence rather than composing its own.
  Future<Map<String, dynamic>> ruleDispute(
    String token,
    String id, {
    required String action,
    int? scoreChallenger,
    int? scoreOpponent,
    String? note,
  }) =>
      _api.patch(
        ApiConstants.adminDispute(id),
        {
          'action': action,
          'scoreChallenger': ?scoreChallenger,
          'scoreOpponent': ?scoreOpponent,
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        },
        token: token,
      );

  // Users, suspension (FR10.8)

  /// `status` is `all` · `active` · `suspended`; `role` filters to one role.
  Future<AdminPage<AdminUserRow>> users(
    String token, {
    String? q,
    String? role,
    String status = 'all',
    String? cursor,
    int limit = 25,
  }) async {
    final params = <String, String>{'status': status, 'limit': '$limit'};
    if (q != null && q.trim().isNotEmpty) params['q'] = q.trim();
    if (role != null && role.isNotEmpty) params['role'] = role;
    if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;
    final r = await _api.get(ApiConstants.adminUsers,
        token: token, queryParams: params);
    if (r['success'] != true || r['data'] is! Map) {
      return const AdminPage<AdminUserRow>(items: []);
    }
    final d = Map<String, dynamic>.from(r['data'] as Map);
    return AdminPage<AdminUserRow>(
      items: (d['items'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => AdminUserRow.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      hasMore: d['hasMore'] == true,
      nextCursor: d['nextCursor']?.toString(),
    );
  }

  /// Suspend. `reason` is required by the server and is shown to the user in the
  /// notification they receive, so it is written for them, not for the audit log.
  ///
  /// One transaction on the far side: the flag, the cascade (bookings refunded,
  /// challenges withdrawn, tournaments unregistered, an owner's venues closed),
  /// the user's notification and the audit row. The response's `data.cascade` is
  /// the receipt for all of it.
  Future<Map<String, dynamic>> suspend(
    String token,
    String userId, {
    required String reason,
  }) =>
      _api.patch(
        ApiConstants.adminSuspendUser(userId),
        {'reason': reason.trim()},
        token: token,
      );

  /// Lift a suspension. Venues come back; cancelled bookings do not — they were
  /// refunded and their slots may already belong to someone else.
  Future<Map<String, dynamic>> reinstate(
    String token,
    String userId, {
    String? note,
  }) =>
      _api.patch(
        ApiConstants.adminReinstateUser(userId),
        {if (note != null && note.trim().isNotEmpty) 'note': note.trim()},
        token: token,
      );

  // Global settings (FR10.9–10.11)

  /// The catalogue: sections, fields, bounds, units, effective values. Rendered
  /// as sent — see [SettingsField].
  Future<SettingsCatalog> settings(String token) async {
    final r = await _api.get(ApiConstants.adminSettings, token: token);
    if (r['success'] != true || r['data'] is! Map) return SettingsCatalog.empty;
    return SettingsCatalog.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// Save a partial map of `key -> value`, exactly the keys that changed.
  ///
  /// The server validates against the same clamps the accessor applies, so a
  /// value out of range comes back as a 400 with the range named rather than
  /// being silently clamped — and disabling a sport with future confirmed
  /// bookings comes back as a 409 `sport_has_bookings` with the counts. Both are
  /// in `message`, which is why the envelope is returned whole.
  Future<Map<String, dynamic>> saveSettings(
    String token,
    Map<String, dynamic> changed, {
    String? note,
  }) =>
      _api.put(
        ApiConstants.adminSettings,
        {
          'settings': changed,
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        },
        token: token,
      );

  /// Drop the override rows for these keys, back to the documented defaults.
  Future<Map<String, dynamic>> resetSettings(String token, List<String> keys) =>
      _api.post(ApiConstants.adminSettingsReset, {'keys': keys}, token: token);
}
