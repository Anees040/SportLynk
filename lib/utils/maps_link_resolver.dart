/// Resolution of a shortened Google Maps link into coordinates.
///
/// [parseLatLng] in maps_link.dart is pure and offline by design, so it cannot read
/// a shortened link (`maps.app.goo.gl`, `goo.gl/maps`): the text carries no
/// coordinates until the redirect is followed. This adds that one network hop, kept
/// out of maps_link.dart so the parser stays dependency-free and unit-testable
/// without a network.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'maps_link.dart';

const List<String> _shortHosts = ['maps.app.goo.gl', 'goo.gl', 'g.co'];

/// Whether [input] looks like a shortened Google Maps link worth resolving over the
/// network. A link the parser can already read directly is not one, and neither is
/// bare text — only the known short hosts, with a path, qualify.
bool isShortMapsLink(String input) {
  final s = input.trim().toLowerCase();
  if (s.isEmpty) return false;
  final uri = Uri.tryParse(s.startsWith('http') ? s : 'https://$s');
  if (uri == null) return false;
  return _shortHosts.contains(uri.host) && uri.pathSegments.isNotEmpty;
}

/// Coordinates for [input], following a shortened link's redirect when the text
/// itself carries none.
///
/// Returns null when nothing can be read — including on web, where a cross-origin
/// redirect to Google cannot be inspected (CORS), so the owner is asked to paste
/// coordinates instead. Best-effort and never throws. [client] is injectable so the
/// hop can be exercised in a test without a real network.
Future<LatLng?> resolveMapsLink(String input, {http.Client? client}) async {
  final direct = parseLatLng(input);
  if (direct != null) return direct;
  if (!isShortMapsLink(input)) return null;

  final owned = client == null;
  final c = client ?? http.Client();
  try {
    var url = input.trim();
    if (!url.startsWith('http')) url = 'https://$url';
    // Follow up to a few redirects by hand — reading the Location header rather than
    // letting http follow them — so the expanded URL, which carries the coordinates
    // in its path or query, can be parsed at each hop.
    for (var hop = 0; hop < 5; hop += 1) {
      final request = http.Request('GET', Uri.parse(url))
        ..followRedirects = false;
      final response = await c.send(request).timeout(const Duration(seconds: 8));
      await response.stream.drain<void>();
      final location = response.headers['location'];
      if (location == null || location.isEmpty) {
        return parseLatLng(url);
      }
      final atHop = parseLatLng(location);
      if (atHop != null) return atHop;
      url = Uri.parse(url).resolve(location).toString();
    }
    return parseLatLng(url);
  } catch (_) {
    return null;
  } finally {
    if (owned) c.close();
  }
}

/// Whether [s] looks like a typed place/address worth geocoding — has letters and is
/// not a URL (coordinates and Maps links are handled by the parser/resolver above, so
/// geocoding them would waste a round trip).
bool looksLikeAddress(String s) {
  final t = s.trim();
  if (t.length < 4) return false;
  if (t.startsWith('http') || t.contains('://') || t.contains('goo.gl')) return false;
  return RegExp(r'[A-Za-z]').hasMatch(t);
}

/// Coordinates for a typed address, via OpenStreetMap's Nominatim — the free,
/// keyless geocoder. Restricted to Pakistan so a bare "DHA phase 5" resolves in
/// country rather than to a namesake abroad, and matched against the same global
/// range the parser enforces.
///
/// Best-effort and never throws: an empty result, a non-200, a rate-limit or no
/// network all return null, and the owner falls back to pasting coordinates or a
/// Maps link. Nominatim asks callers to send a descriptive User-Agent and keep to a
/// low request rate; the field is debounced, so one lookup fires per settle.
Future<LatLng?> geocodeAddress(String input, {http.Client? client}) async {
  final q = input.trim();
  if (!looksLikeAddress(q)) return null;

  final owned = client == null;
  final c = client ?? http.Client();
  try {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': q,
      'format': 'jsonv2',
      'limit': '1',
      'countrycodes': 'pk',
    });
    final resp = await c.get(uri, headers: {
      'User-Agent': 'SportLynk/1.0 (venue onboarding)',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(resp.body);
    if (decoded is! List || decoded.isEmpty) return null;
    final first = decoded.first;
    if (first is! Map) return null;
    final lat = double.tryParse('${first['lat']}');
    final lng = double.tryParse('${first['lon']}');
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return LatLng(lat, lng);
  } catch (_) {
    return null;
  } finally {
    if (owned) c.close();
  }
}

/// Resolve any location text an owner might enter, in cheapest-first order:
/// a parseable pair or Maps URL (offline), then a shortened Maps link (one redirect),
/// then a typed address (Nominatim geocode). Null when nothing resolves.
Future<LatLng?> resolveLocationText(String input, {http.Client? client}) async {
  final viaLink = await resolveMapsLink(input, client: client);
  if (viaLink != null) return viaLink;
  return geocodeAddress(input, client: client);
}
