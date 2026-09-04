// Unit tests for lib/utils/num_util.dart.
//
// These cover the crash class the file exists to end: PostgreSQL returns every
// DECIMAL/NUMERIC column as a String, so a raw cast throws at runtime on a screen
// the user has already opened. The cases below are the shapes the API has actually
// been observed to send, not invented input.
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/utils/num_util.dart';

void main() {
  group('asNumOrNull', () {
    test('parses the string form pg uses for a DECIMAL column', () {
      expect(asNumOrNull('1200.00'), 1200.0);
      expect(asNumOrNull('0.00'), 0.0);
      expect(asNumOrNull('3'), 3.0);
    });

    test('tolerates a currency prefix, thousands separators and stray space', () {
      expect(asNumOrNull('PKR 1200'), 1200.0);
      expect(asNumOrNull('1,200.50'), 1200.5);
      expect(asNumOrNull('  850  '), 850.0);
      expect(asNumOrNull('Rs. 2,500.75'), 2500.75);
    });

    test('passes num input through without going near the string path', () {
      expect(asNumOrNull(12), 12.0);
      expect(asNumOrNull(12.5), 12.5);
      expect(asNumOrNull(-3), -3.0);
    });

    test('returns null for absent or unparseable input, never zero', () {
      expect(asNumOrNull(null), isNull);
      expect(asNumOrNull(''), isNull);
      expect(asNumOrNull('   '), isNull);
      expect(asNumOrNull('unrated'), isNull);
      expect(asNumOrNull('12-14'), isNull);
      expect(asNumOrNull(<String>[]), isNull);
    });

    test('rejects non-finite doubles, which no widget can lay out', () {
      expect(asNumOrNull(double.nan), isNull);
      expect(asNumOrNull(double.infinity), isNull);
      expect(asNumOrNull(double.negativeInfinity), isNull);
    });

    test('maps a bool to 1 or 0, the form a pg boolean aggregate arrives in', () {
      expect(asNumOrNull(true), 1.0);
      expect(asNumOrNull(false), 0.0);
    });
  });

  group('asNum', () {
    test('substitutes the fallback rather than propagating null', () {
      expect(asNum(null), 0.0);
      expect(asNum('garbage'), 0.0);
      expect(asNum(null, fallback: 1000), 1000.0);
      expect(asNum('', fallback: -1), -1.0);
    });

    test('a real value is returned even when a fallback was supplied', () {
      expect(asNum('1200.00', fallback: 1000), 1200.0);
      expect(asNum(0, fallback: 1000), 0.0);
    });
  });

  group('asInt', () {
    test('parses the string form of an int column', () {
      expect(asInt('3'), 3);
      expect(asInt(7), 7);
    });

    test('rounds a decimal instead of truncating it', () {
      expect(asInt('3.7'), 4);
      expect(asInt(2.5), 3);
      expect(asInt('-2.5'), -3);
    });

    test('falls back for absent or unparseable input', () {
      expect(asInt(null), 0);
      expect(asInt('none'), 0);
      expect(asInt(null, fallback: 1000), 1000);
    });
  });

  // The distinction the two flavours exist for: a venue with no reviews must render
  // "New" rather than "0.0 stars", so the caller needs null to survive parsing.
  test('asNumOrNull keeps absent distinguishable from zero, asNum does not', () {
    expect(asNumOrNull(null), isNull);
    expect(asNumOrNull('0'), 0.0);
    expect(asNum(null), asNum('0'));
  });
}
