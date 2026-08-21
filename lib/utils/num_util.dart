/// Numeric parsing for values that came out of PostgreSQL.
///
/// pg returns every `DECIMAL`/`NUMERIC` column as a **String**, not a number, so
/// `json['balance'] as double` throws and `json['price'].toStringAsFixed(0)`
/// crashes with "NoSuchMethodError: Class 'String' has no instance method
/// 'toStringAsFixed'". That is the crash class this file exists to end — the
/// backend has the same guard in `src/utils/escrow.js` (`asNum`).
///
/// Before this, ten screens and models each carried their own private
/// `_parseDouble` / `_toDouble` copy, in two subtly different flavours (some
/// returned `double`, some `double?`). Both flavours are kept here so every call
/// site can move over without changing its own null-handling.
library;

/// Parse anything into a non-null double. Unparseable input yields [fallback].
///
/// Handles `num`, numeric `String` (including pg's `"1200.00"` and values with
/// stray spaces, commas or a `PKR` prefix), `bool`, and `null`.
double asNum(dynamic value, {double fallback = 0}) {
  return asNumOrNull(value) ?? fallback;
}

/// Parse anything into a double, or `null` when the value is absent or garbage.
///
/// Use this where "no value" and "zero" must stay distinguishable — an unrated
/// venue (`rating == null`) should render "New", not "0.0 stars".
double? asNumOrNull(dynamic value) {
  if (value == null) return null;
  if (value is double) return value.isFinite ? value : null;
  if (value is int) return value.toDouble();
  if (value is num) {
    final d = value.toDouble();
    return d.isFinite ? d : null;
  }
  if (value is bool) return value ? 1 : 0;

  // Strip anything that is not part of a number: currency prefixes, thousands
  // separators and whitespace all show up in values echoed back from the API.
  final cleaned = value.toString().replaceAll(RegExp(r'[^0-9eE+\-.]'), '');
  if (cleaned.isEmpty) return null;
  final parsed = double.tryParse(cleaned);
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
}

/// Parse into a non-null int, rounding a decimal input. Falls back to [fallback].
///
/// Needed because pg hands back `"3"` for an INT column inside a JOIN just as
/// readily as it does for a DECIMAL one.
int asInt(dynamic value, {int fallback = 0}) {
  final d = asNumOrNull(value);
  return d == null ? fallback : d.round();
}
