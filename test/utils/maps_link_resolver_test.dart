import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sportlynk/utils/maps_link_resolver.dart';

void main() {
  group('isShortMapsLink', () {
    test('recognises the Google short hosts, with or without a scheme', () {
      expect(isShortMapsLink('https://maps.app.goo.gl/abc123'), isTrue);
      expect(isShortMapsLink('https://goo.gl/maps/xyz'), isTrue);
      expect(isShortMapsLink('maps.app.goo.gl/abc123'), isTrue);
    });

    test('rejects a full URL, a bare pair, plain text and a bare host', () {
      expect(isShortMapsLink('https://www.google.com/maps/@24.86,67.00,17z'),
          isFalse);
      expect(isShortMapsLink('24.8607, 67.0011'), isFalse);
      expect(isShortMapsLink('Green Turf Arena'), isFalse);
      expect(isShortMapsLink('https://maps.app.goo.gl'), isFalse); // no path
    });
  });

  group('resolveMapsLink', () {
    test('returns the point directly when the text already carries one', () async {
      // A bare pair is read without a network hop, so no client is needed.
      final c = await resolveMapsLink('24.8607, 67.0011');
      expect(c, isNotNull);
      expect(c!.lat, closeTo(24.8607, 1e-9));
    });

    test('follows a short link\'s redirect to the expanded URL', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'maps.app.goo.gl');
        return http.Response('', 302, headers: {
          'location':
              'https://www.google.com/maps/place/Arena/@24.8607,67.0011,17z',
        });
      });
      final c = await resolveMapsLink('https://maps.app.goo.gl/abc123',
          client: client);
      expect(c, isNotNull);
      expect(c!.lat, closeTo(24.8607, 1e-9));
      expect(c.lng, closeTo(67.0011, 1e-9));
    });

    test('returns null when the redirect carries no coordinates', () async {
      final client = MockClient((req) async =>
          http.Response('', 302, headers: {'location': 'https://example.com/nope'}));
      final c =
          await resolveMapsLink('https://goo.gl/maps/none', client: client);
      expect(c, isNull);
    });

    test('returns null and does not throw on a transport error', () async {
      final client =
          MockClient((req) async => throw http.ClientException('boom'));
      final c =
          await resolveMapsLink('https://maps.app.goo.gl/abc', client: client);
      expect(c, isNull);
    });
  });

  group('looksLikeAddress', () {
    test('accepts a typed place with letters', () {
      expect(looksLikeAddress('Green Turf Arena, Lahore'), isTrue);
      expect(looksLikeAddress('DHA Phase 5'), isTrue);
    });

    test('rejects coordinates, URLs and too-short text', () {
      expect(looksLikeAddress('24.8607, 67.0011'), isFalse); // no letters
      expect(looksLikeAddress('https://maps.app.goo.gl/x'), isFalse); // URL
      expect(looksLikeAddress('ab'), isFalse); // too short
      expect(looksLikeAddress(''), isFalse);
    });
  });

  group('geocodeAddress', () {
    test('resolves a typed address through Nominatim', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'nominatim.openstreetmap.org');
        expect(req.url.queryParameters['countrycodes'], 'pk');
        expect(req.url.queryParameters['q'], 'Green Turf Arena, Lahore');
        return http.Response(
          '[{"lat":"31.5204","lon":"74.3587","display_name":"Lahore"}]',
          200,
        );
      });
      final c = await geocodeAddress('Green Turf Arena, Lahore', client: client);
      expect(c, isNotNull);
      expect(c!.lat, closeTo(31.5204, 1e-9));
      expect(c.lng, closeTo(74.3587, 1e-9));
    });

    test('does not call the network for a URL or bare coordinates', () async {
      final client = MockClient((req) async => throw StateError('should not be called'));
      expect(await geocodeAddress('https://maps.app.goo.gl/x', client: client), isNull);
      expect(await geocodeAddress('24.86, 67.00', client: client), isNull);
    });

    test('returns null on an empty result', () async {
      final client = MockClient((req) async => http.Response('[]', 200));
      expect(await geocodeAddress('Nowhere at all xyz', client: client), isNull);
    });

    test('returns null on a non-200', () async {
      final client = MockClient((req) async => http.Response('rate limited', 429));
      expect(await geocodeAddress('Somewhere real', client: client), isNull);
    });
  });

  group('resolveLocationText', () {
    test('a bare pair resolves without any network call', () async {
      final client = MockClient((req) async => throw StateError('no network needed'));
      final c = await resolveLocationText('24.8607, 67.0011', client: client);
      expect(c!.lat, closeTo(24.8607, 1e-9));
    });

    test('falls back to geocoding a typed address', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'nominatim.openstreetmap.org');
        return http.Response('[{"lat":"33.6844","lon":"73.0479"}]', 200);
      });
      final c = await resolveLocationText('Blue Area, Islamabad', client: client);
      expect(c, isNotNull);
      expect(c!.lat, closeTo(33.6844, 1e-9));
    });
  });
}
