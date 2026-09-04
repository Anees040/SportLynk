import '../constants/api_constants.dart';
import 'api_service.dart';

/// AI pricing + demand forecast (FR4.17 / FR4.18).
///
/// Everything in this file exists to keep one promise to the owner: the number on
/// the card is a suggestion they can read the reasoning for, and nothing changes
/// what a player pays until they press Apply. So the models below carry the
/// *provenance* of every figure — which service produced it ([PriceSuggestion.source]),
/// how sure it is ([PriceSuggestion.confidence]), what moved it ([topFactors]), and
/// how the model that produced it scored ([ModelMetrics]) — instead of a
/// bare rupee value the screen would have to dress up in invented confidence.
///
/// **`null` from a read means the request failed. An empty/unavailable payload means
/// the answer is genuinely not there.** Those are different sentences on screen:
/// "couldn't reach the server" invites a retry, "forecast unavailable" does not.

/// One "why" chip. Produced server-side by a per-request counterfactual: the model
/// is re-scored with this one piece of context moved to a neutral value, and
/// [impact] is how much P(booked) fell as a result.
///
/// [impact] is nullable on purpose. When the ML service is down the backend still
/// sends one chip from its heuristic ("Peak hour"), and that chip has no measured
/// impact — it is a rule, not a measurement. Rendering `0.00` there would present a
/// rule as a measurement of zero effect, which is a lie in the other direction, so
/// the screen shows the label alone.
class PriceFactor {
  final String key;
  final String label;
  final String direction; // 'up' | 'down'
  final double? impact;

  const PriceFactor({
    required this.key,
    required this.label,
    required this.direction,
    this.impact,
  });

  bool get isUp => direction != 'down';

  /// True when this chip came with a measured effect, i.e. from the model path.
  bool get isMeasured => impact != null;

  /// e.g. `+12 pts` — percentage POINTS of booking probability, not a percentage of
  /// anything, which is why it is never rendered with a `%`.
  String? get impactLabel {
    final i = impact;
    if (i == null) return null;
    final pts = (i * 100).round();
    if (pts <= 0) return null;
    return '${isUp ? '+' : '−'}$pts pts';
  }

  factory PriceFactor.fromJson(Map<String, dynamic> j) => PriceFactor(
        key: (j['key'] ?? 'factor').toString(),
        label: (j['label'] ?? '').toString(),
        direction: j['direction'] == 'down' ? 'down' : 'up',
        impact: _toDouble(j['impact']),
      );
}

/// The served model's own test-set scores, read from the artifact at request time.
///
/// This is the honest version of the "quiet flex" caption. The spec suggested
/// hardcoding `AUC 0.84`; the model that ships scores 0.7628, so the
/// caption reads whatever the loaded artifact measured. A demo number that does not
/// match `pricing_metrics.json` is the kind of thing an FYP panel asks about once.
class ModelMetrics {
  final double? rocAuc;
  final double? prAuc;
  final double? brier;
  final double? brierSkill;
  final double? rocAucCeiling;
  final int? testRows;
  final String? trainedAt;
  final String? datasetSource;

  const ModelMetrics({
    this.rocAuc,
    this.prAuc,
    this.brier,
    this.brierSkill,
    this.rocAucCeiling,
    this.testRows,
    this.trainedAt,
    this.datasetSource,
  });

  /// How much of the achievable signal this model captured. The ceiling is measured
  /// on the generator's own latent probabilities, so `0.7628 / 0.7770` is a far more
  /// meaningful sentence than a raw AUC: it says 98% of what is knowable was learnt.
  double? get attainmentPct {
    final auc = rocAuc, ceiling = rocAucCeiling;
    if (auc == null || ceiling == null || ceiling <= 0) return null;
    return (auc / ceiling * 100).clamp(0, 100).toDouble();
  }

  factory ModelMetrics.fromJson(Map<String, dynamic> j) => ModelMetrics(
        rocAuc: _toDouble(j['rocAuc']),
        prAuc: _toDouble(j['prAuc']),
        brier: _toDouble(j['brier']),
        brierSkill: _toDouble(j['brierSkill']),
        rocAucCeiling: _toDouble(j['rocAucCeiling']),
        testRows: _toInt(j['testRows']),
        trainedAt: j['trainedAt']?.toString(),
        datasetSource: j['datasetSource']?.toString(),
      );
}

/// A price suggestion for one venue-date-hour.
class PriceSuggestion {
  /// `model` | `heuristic` | `unavailable` — set by the backend, never inferred here.
  final String source;
  final int basePrice;
  final int suggestedPrice;
  final double deltaPct;

  /// Derived server-side as `identification × boundary penalty × model attainment`,
  /// clamped to [0.05, 0.95]. Never a constant, which is what the old static card had.
  final double? confidence;

  /// P(this slot gets booked) at [suggestedPrice] — the "expected occupancy" of the
  /// brief. A probability in 0..1, so the card multiplies by 100 for display.
  final double? demand;
  final String? demandLevel; // 'high' | 'medium' | 'low' | null
  final String? reason;
  final String? modelVersion;

  /// True when the raw suggestion hit the Node-side business guardrail (0.70–1.50×)
  /// and was pulled back. Worth surfacing: it means the model wanted to go further.
  final bool clamped;

  /// True when the sweep's best price sat on the training-time policy cap. Because
  /// the generator's peak elasticity is < 1, expected revenue rises monotonically to
  /// the cap on peak slots, so this fires often and legitimately — and the confidence
  /// already carries a penalty for it.
  final bool atPolicyCap;
  final double? policyMaxRatio;

  final List<PriceFactor> topFactors;
  final ModelMetrics? modelMetrics;

  final String? venueId;
  final String? slotDate;
  final String? startTime;
  final int? hour;
  final bool cached;

  const PriceSuggestion({
    required this.source,
    required this.basePrice,
    required this.suggestedPrice,
    required this.deltaPct,
    this.confidence,
    this.demand,
    this.demandLevel,
    this.reason,
    this.modelVersion,
    this.clamped = false,
    this.atPolicyCap = false,
    this.policyMaxRatio,
    this.topFactors = const [],
    this.modelMetrics,
    this.venueId,
    this.slotDate,
    this.startTime,
    this.hour,
    this.cached = false,
  });

  /// True when a trained model produced this. The card shows the confidence bar,
  /// the measured chips and the metrics caption only in this case — a heuristic
  /// dressed as a model is the single most dishonest thing this feature could do.
  bool get isModel => source == 'model';
  bool get isHeuristic => source == 'heuristic';

  /// Nothing to apply when the suggestion equals the current price.
  bool get isActionable => suggestedPrice > 0 && suggestedPrice != basePrice;

  /// `+12%` / `−4%` / `no change`.
  String get deltaLabel {
    final r = deltaPct.round();
    if (r == 0) return 'no change';
    return '${r > 0 ? '+' : '−'}${r.abs()}%';
  }

  /// `84%`, or null when the source has no honest confidence to report.
  String? get confidenceLabel {
    final c = confidence;
    if (c == null) return null;
    return '${(c * 100).round()}%';
  }

  /// `Model v1 · AUC 0.76 (98% of ceiling)` — the caption from the brief, built from
  /// the artifact rather than from a string literal. Null when there is nothing
  /// measured to show, in which case the card shows no caption at all.
  String? get modelCaption {
    if (!isModel) return null;
    final m = modelMetrics;
    final version = modelVersion;
    final parts = <String>[];
    if (version != null && version.isNotEmpty) parts.add('Model $version');
    final auc = m?.rocAuc;
    if (auc != null) parts.add('AUC ${auc.toStringAsFixed(2)}');
    final att = m?.attainmentPct;
    if (att != null) parts.add('${att.round()}% of ceiling');
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  factory PriceSuggestion.fromJson(Map<String, dynamic> j) => PriceSuggestion(
        source: (j['source'] ?? 'unavailable').toString(),
        basePrice: _toInt(j['basePrice']) ?? 0,
        suggestedPrice: _toInt(j['suggestedPrice']) ?? 0,
        deltaPct: _toDouble(j['deltaPct']) ?? 0,
        confidence: _toDouble(j['confidence']),
        demand: _toDouble(j['demand']),
        demandLevel: j['demandLevel']?.toString(),
        reason: j['reason']?.toString(),
        modelVersion: j['modelVersion']?.toString(),
        clamped: j['clamped'] == true,
        atPolicyCap: j['atPolicyCap'] == true,
        policyMaxRatio: _toDouble(j['policyMaxRatio']),
        topFactors: (j['topFactors'] as List? ?? const [])
            .whereType<Map>()
            .map((f) => PriceFactor.fromJson(Map<String, dynamic>.from(f)))
            .where((f) => f.label.isNotEmpty)
            .toList(),
        modelMetrics: j['modelMetrics'] is Map
            ? ModelMetrics.fromJson(Map<String, dynamic>.from(j['modelMetrics'] as Map))
            : null,
        venueId: j['venueId']?.toString(),
        slotDate: j['slotDate']?.toString(),
        startTime: j['startTime']?.toString(),
        hour: _toInt(j['hour']),
        cached: j['cached'] == true,
      );
}

/// One hour of the 72-hour forecast.
class DemandPoint {
  /// Full ISO-8601 with the `+05:00` offset already applied by the backend. The
  /// chart never converts a timezone: the server owns PKT, the client renders it.
  final String ts;
  final String slotDate;
  final int hour;
  final double bookProbability;
  final String? level; // 'high' | 'medium' | 'low'

  const DemandPoint({
    required this.ts,
    required this.slotDate,
    required this.hour,
    required this.bookProbability,
    this.level,
  });

  /// `19:00` — PKT, straight from the hour the server bucketed.
  String get hourLabel => '${hour.toString().padLeft(2, '0')}:00';

  static DemandPoint? tryParse(Map<String, dynamic> j) {
    final p = _toDouble(j['bookProbability']);
    final h = _toInt(j['hour']);
    final ts = j['ts']?.toString();
    // A point with no probability or no timestamp cannot be drawn honestly: a
    // zero-height bar at an unknown hour reads as "no demand", which is a claim the
    // model never made. Dropped instead.
    if (p == null || h == null || ts == null || ts.isEmpty) return null;
    return DemandPoint(
      ts: ts,
      slotDate: (j['slotDate'] ?? '').toString(),
      hour: h,
      bookProbability: p,
      level: j['level']?.toString(),
    );
  }
}

/// The demand thresholds the server used to bucket the bars, carried alongside them
/// so the chart legend and the chart cannot disagree. Anchored on the training set's
/// measured unconditional booking rate, not on taste.
class DemandLevels {
  final double high;
  final double low;
  final double baseRate;

  const DemandLevels({this.high = 0.448, this.low = 0.154, this.baseRate = 0.28});

  factory DemandLevels.fromJson(Map<String, dynamic> j) => DemandLevels(
        high: _toDouble(j['high']) ?? 0.448,
        low: _toDouble(j['low']) ?? 0.154,
        baseRate: _toDouble(j['baseRate']) ?? 0.28,
      );
}

/// The 72-hour forecast (FR4.18).
class DemandForecast {
  final String source;

  /// False means "no forecast", with [reason] carrying the server's own sentence.
  /// The chart draws nothing rather than flat zeros — see the note in [DemandPoint].
  final bool available;
  final List<DemandPoint> points;
  final DemandLevels levels;
  final ModelMetrics? modelMetrics;
  final String? reason;
  final String? modelVersion;
  final bool cached;

  const DemandForecast({
    required this.source,
    required this.available,
    this.points = const [],
    this.levels = const DemandLevels(),
    this.modelMetrics,
    this.reason,
    this.modelVersion,
    this.cached = false,
  });

  bool get isEmpty => points.isEmpty;

  /// Highest hour in the window — the one worth naming in a one-line summary.
  DemandPoint? get peak {
    if (points.isEmpty) return null;
    var best = points.first;
    for (final p in points) {
      if (p.bookProbability > best.bookProbability) best = p;
    }
    return best;
  }

  double get maxProbability =>
      points.isEmpty ? 0 : points.map((p) => p.bookProbability).reduce((a, b) => a > b ? a : b);

  int get highCount => points.where((p) => p.level == 'high').length;

  /// Distinct calendar days present, in wire order. The chart labels day boundaries
  /// rather than all 72 hours, which would be unreadable on a phone.
  List<String> get days {
    final seen = <String>[];
    for (final p in points) {
      if (p.slotDate.isNotEmpty && !seen.contains(p.slotDate)) seen.add(p.slotDate);
    }
    return seen;
  }

  factory DemandForecast.fromJson(Map<String, dynamic> j) => DemandForecast(
        source: (j['source'] ?? 'unavailable').toString(),
        available: j['available'] == true,
        points: (j['points'] as List? ?? const [])
            .whereType<Map>()
            .map((p) => DemandPoint.tryParse(Map<String, dynamic>.from(p)))
            .whereType<DemandPoint>()
            .toList(),
        levels: j['levels'] is Map
            ? DemandLevels.fromJson(Map<String, dynamic>.from(j['levels'] as Map))
            : const DemandLevels(),
        modelMetrics: j['modelMetrics'] is Map
            ? ModelMetrics.fromJson(Map<String, dynamic>.from(j['modelMetrics'] as Map))
            : null,
        reason: j['reason']?.toString(),
        modelVersion: j['modelVersion']?.toString(),
        cached: j['cached'] == true,
      );
}

/// Thin, never-throwing wrapper over the owner pricing API. Reads return typed
/// models (or `null` when the request itself failed); the Apply mutation returns the
/// raw `{success, message, data}` map so the screen can surface the backend's own
/// sentence — it is the only place that knows which slots were skipped and why.
class PricingService {
  final ApiClient _api = ApiClient();

  /// Suggestion for one slot. [date] is `YYYY-MM-DD` PKT; omitting it asks the
  /// server for today, and omitting [hour] lets the server pick the venue's own
  /// peak-adjacent hour — the client does not duplicate that arithmetic, because
  /// two implementations of "which hour do we mean" is two answers.
  Future<PriceSuggestion?> suggestion(
    String token,
    String venueId, {
    String? date,
    int? hour,
  }) async {
    final params = <String, String>{};
    if (date != null && date.isNotEmpty) params['date'] = date;
    if (hour != null && hour >= 0 && hour <= 23) params['hour'] = hour.toString();
    final r = await _api.get(
      ApiConstants.ownerVenuePricing(venueId),
      token: token,
      queryParams: params,
    );
    if (r['success'] != true) return null;
    final data = r['data'];
    if (data is! Map) return null;
    return PriceSuggestion.fromJson(Map<String, dynamic>.from(data));
  }

  /// 72-hour demand forecast (FR4.18). `null` = the call failed; a forecast with
  /// `available == false` = the model could not answer, and says why.
  Future<DemandForecast?> forecast(String token, String venueId, {int hours = 72}) async {
    final r = await _api.get(
      ApiConstants.ownerVenueForecast(venueId),
      token: token,
      queryParams: {'hours': hours.toString()},
    );
    if (r['success'] != true) return null;
    final data = r['data'];
    if (data is! Map) return null;
    return DemandForecast.fromJson(Map<String, dynamic>.from(data));
  }

  /// The Apply half of FR4.17 — the owner's explicit act, never automatic.
  ///
  /// Returned raw because the interesting part is the partial case: the server
  /// classifies each slot as updated or skipped (`booked`, `locked`, `past`,
  /// `unchanged`, `not_found`) and the screen must be able to say "applied to 6 of
  /// 8 — 2 are already booked" instead of a flat success.
  Future<Map<String, dynamic>> applyPrice(
    String token,
    String venueId, {
    required List<String> slotIds,
    required double price,
  }) =>
      _api.patch(
        ApiConstants.ownerVenueSlotPrice(venueId),
        {'slotIds': slotIds, 'price': price},
        token: token,
      );
}

// Coercion helpers
// JSON numbers arrive as int or double depending on whether Postgres/Python emitted
// a trailing `.0`, and `as double` on an int throws. Every numeric read goes through
// these, so one integral price does not blank the whole card.

double? _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round();
  return null;
}
