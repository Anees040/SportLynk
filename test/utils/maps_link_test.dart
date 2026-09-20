import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/utils/maps_link.dart';

void main() {
  group('parseLatLng', () {
    test('reads a bare "lat, lng" pair (the long-press copy format)', () {
      final c = parseLatLng('24.8607, 67.0011');
      expect(c, isNotNull);
      expect(c!.lat, closeTo(24.8607, 1e-9));
      expect(c.lng, closeTo(67.0011, 1e-9));
    });

    test('reads a pair with no space after the comma', () {
      final c = parseLatLng('31.5204,74.3587');
      expect(c!.lat, closeTo(31.5204, 1e-9));
      expect(c.lng, closeTo(74.3587, 1e-9));
    });

    test('reads @lat,lng from a place URL', () {
      final c = parseLatLng(
          'https://www.google.com/maps/place/Arena/@24.8607,67.0011,17z/data=abc');
      expect(c!.lat, closeTo(24.8607, 1e-9));
      expect(c.lng, closeTo(67.0011, 1e-9));
    });

    test('prefers the !3d/!4d place pin over the @ viewport centre', () {
      final c = parseLatLng(
          'https://www.google.com/maps/place/X/@24.5000,67.5000,17z/data=!3d24.8607!4d67.0011');
      expect(c!.lat, closeTo(24.8607, 1e-9));
      expect(c.lng, closeTo(67.0011, 1e-9));
    });

    test('reads a q= query parameter', () {
      final c = parseLatLng('https://maps.google.com/?q=33.6844,73.0479');
      expect(c!.lat, closeTo(33.6844, 1e-9));
      expect(c.lng, closeTo(73.0479, 1e-9));
    });

    test('returns null for a short share link with no coordinates', () {
      expect(parseLatLng('https://maps.app.goo.gl/abc123'), isNull);
    });

    test('returns null for empty or non-coordinate text', () {
      expect(parseLatLng(''), isNull);
      expect(parseLatLng('   '), isNull);
      expect(parseLatLng('Green Turf Arena, Lahore'), isNull);
    });

    test('rejects an out-of-range coordinate', () {
      expect(parseLatLng('91.0, 200.0'), isNull);
    });
  });

  group('isWithinPakistan', () {
    test('accepts Karachi, Lahore and Islamabad', () {
      expect(isWithinPakistan(const LatLng(24.8607, 67.0011)), isTrue);
      expect(isWithinPakistan(const LatLng(31.5204, 74.3587)), isTrue);
      expect(isWithinPakistan(const LatLng(33.6844, 73.0479)), isTrue);
    });

    test('rejects a coordinate outside the country', () {
      expect(isWithinPakistan(const LatLng(51.5074, -0.1278)), isFalse); // London
      // Latitude and longitude swapped — the box catches this common paste error
      // because a latitude of 67 is far north of any Pakistani venue.
      expect(isWithinPakistan(const LatLng(67.0011, 24.8607)), isFalse);
    });
  });
}
