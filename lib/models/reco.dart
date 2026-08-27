library;

import 'team.dart' show asNum;

/// Wire models for the S.5 Wave B recommenders — the player-for-team rail (FR2.8)
/// and the re-ranked opponent list (FR5.3 – FR5.5).
///
/// THE ONE RULE THIS FILE EXISTS TO ENFORCE
/// ----------------------------------------
/// A percentage is shown ONLY when the ranking service actually produced it.
/// Every payload from the backend carries a `ranking` block saying which path ran
/// — the weighted scorer, or the SQL fallback — and both paths ship the SAME field
/// names, with the score fields simply null on the fallback. So the screens never
/// need a second shape, and they can never print a number the server did not
/// compute. `ranking.available == false` means "no percentages exist", not "show
/// zero percent".
///
/// A component that is null is NOT zero either. It means the input for that block
/// did not exist for this candidate (a teamless player has no team rating, a
/// player with no bookings has no home area), and the server scored it neutrally
/// rather than punishing a cold start. [ScoreComponent.known] is what separates
/// the two, and the breakdown row says so out loud.
///
/// Numbers go through [asNum] because Postgres hands DECIMALs back as strings.

int _int(dynamic v, [int fallback = 0]) => asNum(v, fallback).round();
int? _intOrNull(dynamic v) => v == null ? null : asNum(v, 0).round();
double? _dbl(dynamic v) => v == null ? null : asNum(v, 0).toDouble();
bool _bool(dynamic v) => v == true;

String? _str(dynamic v) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? null : s;
}

List<String> _strList(dynamic v) => (v as List? ?? const [])
    .map((e) => '$e'.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// One weighted block of a match score, as the "Why this match?" row draws it.
///
/// [value] is the block's own 0..1 result and [weight] is its share of the total,
/// both straight from the server's published spec. Nothing here is re-weighted or
/// re-derived client-side: if the two disagreed, the bar would explain a score the
/// user is not looking at.
class ScoreComponent {
  final String key;

  /// 0..1, or null when the input did not exist for this candidate.
  final double? value;

  /// 0..1 — this block's share of the total, from `ranking.weights`.
  final double weight;

  const ScoreComponent({required this.key, required this.value, required this.weight});

  /// False when the server had nothing to measure. Drawn as "unknown", never 0%.
  bool get known => value != null;

  int get percent => ((value ?? 0).clamp(0, 1) * 100).round();
  int get weightPercent => (weight.clamp(0, 1) * 100).round();

  /// How much of the final score this block actually contributed. Null when the
  /// block is unknown, because the neutral value the server substituted is its
  /// policy, not this candidate's evidence.
  double? get contribution => value == null ? null : value! * weight;

  /// Wording that holds for BOTH recommenders. `elo` is a rating-proximity block
  /// in each of them — the opponent's own rating, or the rating of the teams a
  /// player already plays for — so "Level match" is true either way, and neither
  /// screen has to relabel it.
  String get label => switch (key) {
        'fit' => 'Sport fit',
        'elo' => 'Level match',
        'activity' => 'Recent activity',
        'zone' => 'Same area',
        'trust' => 'Trust standing',
        _ => key,
      };

  /// What the block measured, in one line under the bar.
  String get explain => switch (key) {
        'fit' => 'Plays the sport this team plays',
        'elo' => 'How close the ratings are',
        'activity' => 'How often they have been playing lately',
        'zone' => 'Books at the same part of town',
        'trust' => 'Reliability score of the roster',
        _ => '',
      };

  /// Why there is no bar. Deliberately does not name a substituted number: the
  /// honest statement is that nothing was measured, and that it was not held
  /// against them.
  String get unknownNote => switch (key) {
        'fit' => 'No sports listed on their profile — not counted against them',
        'elo' => 'No rated team yet — not counted against them',
        'activity' => 'Nothing to count yet — not counted against them',
        'zone' => 'No usual venue yet — not counted against them',
        'trust' => 'No trust score yet — not counted against them',
        _ => 'Not known — not counted against them',
      };
}

/// Which engine produced an ordering, and on what terms.
///
/// Shipped by both `GET /matches/opponents` and `GET /teams/:id/suggested-players`
/// so a screen that shows a ranking can say what ranked it. `source` is the
/// server's word: `ranked` for the weighted scorer, anything else for a fallback.
class RankingInfo {
  final String source;

  /// True when the scorer ran. The ONLY gate on showing a percentage.
  final bool available;

  final String? specVersion;
  final String? specFingerprint;

  /// Component key → its share of the total. Empty on the fallback path.
  final Map<String, double> weights;

  /// The order the server scores the components in — used verbatim so the
  /// breakdown reads in the same order the spec publishes.
  final List<String> componentOrder;

  /// How many candidates were weighed. Null when the endpoint does not send it.
  final int? considered;

  final int activityWindowDays;

  /// A sentence to show INSTEAD of percentages when the scorer did not run.
  /// Written by the server so the two endpoints' degradations read differently
  /// (one loses its order, the other loses its numbers).
  final String? fallbackNote;

  const RankingInfo({
    required this.source,
    required this.available,
    this.specVersion,
    this.specFingerprint,
    this.weights = const {},
    this.componentOrder = const [],
    this.considered,
    this.activityWindowDays = 30,
    this.fallbackNote,
  });

  /// What a screen assumes before its first successful read: no scorer, no
  /// numbers, and no claim about why.
  static const RankingInfo none = RankingInfo(source: 'unavailable', available: false);

  factory RankingInfo.fromJson(Map<String, dynamic> j) => RankingInfo(
        source: '${j['source'] ?? 'unavailable'}',
        available: _bool(j['available']),
        specVersion: _str(j['specVersion']),
        specFingerprint: _str(j['specFingerprint']),
        weights: weightsFrom(j['weights']),
        componentOrder: _strList(j['componentOrder']),
        considered: _intOrNull(j['considered']),
        activityWindowDays: _int(j['activityWindowDays'], 30),
        fallbackNote: _str(j['fallbackNote']),
      );

  static Map<String, double> weightsFrom(dynamic v) {
    if (v is! Map) return const {};
    final out = <String, double>{};
    v.forEach((k, val) {
      final d = _dbl(val);
      if (d != null) out['$k'] = d;
    });
    return out;
  }

  /// The per-candidate `components` map. Values stay NULLABLE — a missing block
  /// and a block that scored zero are different facts.
  static Map<String, double?>? componentsFrom(dynamic v) {
    if (v is! Map) return null;
    final out = <String, double?>{};
    v.forEach((k, val) => out['$k'] = _dbl(val));
    return out.isEmpty ? null : out;
  }

  /// The breakdown rows for one candidate, in the spec's published order.
  /// Returns empty when there is nothing to explain, which is what makes the
  /// "Why this match?" row disappear on the fallback path rather than open onto
  /// a set of blank bars.
  List<ScoreComponent> breakdown(Map<String, double?>? components) {
    if (components == null || components.isEmpty) return const [];
    final order = componentOrder.isNotEmpty ? componentOrder : components.keys.toList();
    return [
      for (final k in order)
        if (components.containsKey(k))
          ScoreComponent(key: k, value: components[k], weight: weights[k] ?? 0),
    ];
  }

  /// The short attribution line. Says "SportLynk ranking" and not "AI": this is a
  /// published weighted formula, not a trained model, and badging it as AI would
  /// be the one claim the wave cannot support.
  String get label => available ? 'SportLynk ranking' : 'Basic ordering';

  /// The spec's fingerprint, short enough for a footer. Present so a demo can
  /// show that the weights on screen are the weights the service published.
  String? get specTag {
    final v = specVersion;
    if (v == null) return null;
    final f = specFingerprint;
    return f == null ? v : '$v · ${f.length > 8 ? f.substring(0, 8) : f}';
  }
}

/// One row of the roster screen's "Suggested players" rail (FR2.8).
class PlayerSuggestion {
  final String userId;
  final String name;
  final String? avatarUrl;

  /// Their stated sports. Empty is an unfilled profile, not a refusal — the
  /// server keeps those candidates and scores the sport block neutrally.
  final List<String> sports;

  final int bookingsLast30d;

  /// Whether the zone block had a venue to work with. Lets the card say "no
  /// usual venue yet" instead of implying the player is somewhere else.
  final bool hasHomeArea;

  final int? trustScore;
  final String? trustBand;
  final String? trustLabel;

  /// Null on the fallback path — the rail then shows no number at all.
  final int? matchPct;
  final double? score;

  final Map<String, double?>? components;

  /// `team_elo` or `trust_proxy` — which input the level block used. Shown
  /// because the same bar means two different things depending on it.
  final String? eloSource;

  final List<String> reasons;

  const PlayerSuggestion({
    required this.userId,
    required this.name,
    this.avatarUrl,
    this.sports = const [],
    this.bookingsLast30d = 0,
    this.hasHomeArea = false,
    this.trustScore,
    this.trustBand,
    this.trustLabel,
    this.matchPct,
    this.score,
    this.components,
    this.eloSource,
    this.reasons = const [],
  });

  factory PlayerSuggestion.fromJson(Map<String, dynamic> j) => PlayerSuggestion(
        userId: '${j['userId'] ?? ''}',
        name: '${j['name'] ?? 'Player'}',
        avatarUrl: _str(j['avatarUrl']),
        sports: _strList(j['sports']),
        bookingsLast30d: _int(j['bookingsLast30d']),
        hasHomeArea: _bool(j['hasHomeArea']),
        trustScore: _intOrNull(j['trustScore']),
        trustBand: _str(j['trustBand']),
        trustLabel: _str(j['trustLabel']),
        matchPct: _intOrNull(j['matchPct']),
        score: _dbl(j['score']),
        components: RankingInfo.componentsFrom(j['components']),
        eloSource: _str(j['eloSource']),
        reasons: _strList(j['reasons']),
      );

  String get initial => name.isEmpty ? '?' : name.trimLeft()[0].toUpperCase();

  String get sportsLabel => sports.isEmpty ? 'No sports listed' : sports.join(' · ');

  String get activityLabel => bookingsLast30d == 0
      ? 'No recent bookings'
      : '$bookingsLast30d booking${bookingsLast30d == 1 ? '' : 's'} · 30d';

  /// What the level block was measured from, for the breakdown footer.
  String? get eloSourceNote => switch (eloSource) {
        'team_elo' => 'Level taken from the rating of the team they play for',
        'trust_proxy' => 'No team yet — their trust score stood in for a rating',
        _ => null,
      };
}

/// `GET /api/teams/:id/suggested-players` — the rail plus who it was built for.
class SuggestedPlayers {
  final String? teamId;
  final String? sport;

  /// The team's own city field.
  final String? city;

  /// The city of the venue its members book most — the value the "same city"
  /// pool was actually built from, which is not always [city].
  final String? homeCity;

  final RankingInfo ranking;
  final List<PlayerSuggestion> suggestions;

  const SuggestedPlayers({
    this.teamId,
    this.sport,
    this.city,
    this.homeCity,
    this.ranking = RankingInfo.none,
    this.suggestions = const [],
  });

  static const SuggestedPlayers empty = SuggestedPlayers();

  factory SuggestedPlayers.fromJson(Map<String, dynamic> j) {
    final t = j['team'];
    final team = t is Map ? Map<String, dynamic>.from(t) : const <String, dynamic>{};
    final r = j['ranking'];
    return SuggestedPlayers(
      teamId: _str(team['id']),
      sport: _str(team['sport']),
      city: _str(team['city']),
      homeCity: _str(team['homeCity']),
      ranking: r is Map
          ? RankingInfo.fromJson(Map<String, dynamic>.from(r))
          : RankingInfo.none,
      suggestions: (j['suggestions'] as List? ?? const [])
          .whereType<Map>()
          .map((x) => PlayerSuggestion.fromJson(Map<String, dynamic>.from(x)))
          .toList(),
    );
  }

  bool get isEmpty => suggestions.isEmpty;
}
