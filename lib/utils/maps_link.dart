/// Extraction of a latitude/longitude pair from owner-supplied text — either a
/// Google Maps URL in any of the forms Maps produces, or a bare "lat, lng" pair
/// copied from a long-press on the map. Kept pure and dependency-free so it runs
/// identically on web and mobile and is unit tested without a network.
library;

/// A parsed coordinate pair. Immutable by construction.
class LatLng {
  final double lat;
  final double lng;
  const LatLng(this.lat, this.lng);

  /// Six decimal places is roughly 0.11 m at the equator — more than enough to
  /// pin a venue and stable for display.
  @override
  String toString() => '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
}

/// Pakistan's approximate bounding box, used to reject a coordinate that parsed
/// cleanly but plainly is not an in-country venue (a common paste mistake such as
/// leaving Maps centred on another country, or swapping latitude and longitude).
const double _pkMinLat = 23.5;
const double _pkMaxLat = 37.2;
const double _pkMinLng = 60.8;
const double _pkMaxLng = 77.9;

/// Coordinates read from [input], or null when none can be recognised.
///
/// Recognised forms, tried from most to least specific so a place pin is
/// preferred over the viewport centre:
///   - `...!3d24.8607!4d67.0011...`   the place-detail encoding (the actual pin)
///   - `.../@24.8607,67.0011,17z`     the URL Maps shows for a place (viewport)
///   - `...?q=24.8607,67.0011`        `q`, `query` or `ll` query parameters
///   - `24.8607, 67.0011`            a bare pair, the long-press copy format
LatLng? parseLatLng(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;

  // The place pin: !3dLAT!4dLNG. Most accurate, so it is tried first.
  final bang = RegExp(r'!3d(-?\d+\.?\d*)!4d(-?\d+\.?\d*)').firstMatch(s);
  final fromBang = _build(bang?.group(1), bang?.group(2));
  if (fromBang != null) return fromBang;

  // The viewport centre: @LAT,LNG.
  final at = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(s);
  final fromAt = _build(at?.group(1), at?.group(2));
  if (fromAt != null) return fromAt;

  // A q / query / ll parameter carrying the pair.
  final param =
      RegExp(r'[?&](?:q|query|ll)=(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(s);
  final fromParam = _build(param?.group(1), param?.group(2));
  if (fromParam != null) return fromParam;

  // A bare "lat, lng". Anchored to the whole string so a stray number inside a
  // URL is never mistaken for coordinates.
  final bare =
      RegExp(r'^(-?\d{1,2}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)$').firstMatch(s);
  return _build(bare?.group(1), bare?.group(2));
}

/// Builds a [LatLng] from two captured strings, rejecting anything that is not a
/// finite coordinate within the valid global range.
LatLng? _build(String? a, String? b) {
  if (a == null || b == null) return null;
  final lat = double.tryParse(a);
  final lng = double.tryParse(b);
  if (lat == null || lng == null) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return LatLng(lat, lng);
}

/// Whether [c] falls inside Pakistan's bounding box.
bool isWithinPakistan(LatLng c) =>
    c.lat >= _pkMinLat &&
    c.lat <= _pkMaxLat &&
    c.lng >= _pkMinLng &&
    c.lng <= _pkMaxLng;
