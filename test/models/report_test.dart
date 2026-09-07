// Financial export model tests (FR4.16).
//
// Two properties matter more than the rest. The columns and their order come
// from the server, so the preview must render whatever list arrives rather than
// a hard-coded one — a second source of truth for the shape of a financial
// document is the last place to keep one. And `money` must format a cell exactly
// as `utils/csv.js` writes it, so a number read on the phone matches the file
// byte for byte; `pkr` is the separate, separator-bearing form used only for the
// summary figures.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/report.dart';

void main() {
  group('money', () {
    test('is two-place with no thousands separator, matching the CSV', () {
      expect(money(1200), '1200.00');
      expect(money(1200.5), '1200.50');
      expect(money(0), '0.00');
      expect(money(1234567.891), '1234567.89');
    });

    test('keeps a negative sign, since a refund column carries one', () {
      expect(money(-500), '-500.00');
    });
  });

  group('pkr', () {
    test('groups thousands in threes', () {
      expect(pkr(0), 'PKR 0');
      expect(pkr(999), 'PKR 999');
      expect(pkr(1000), 'PKR 1,000');
      expect(pkr(1200), 'PKR 1,200');
      expect(pkr(12000), 'PKR 12,000');
      expect(pkr(123456), 'PKR 123,456');
      expect(pkr(1000000), 'PKR 1,000,000');
    });

    test('drops a .00 tail but keeps real paisa', () {
      expect(pkr(1200), 'PKR 1,200');
      expect(pkr(1200.5), 'PKR 1,200.50');
      expect(pkr(1200.05), 'PKR 1,200.05');
      expect(pkr(0.5), 'PKR 0.50');
    });

    test('puts the sign before the currency, not inside the number', () {
      expect(pkr(-1200), '-PKR 1,200');
      expect(pkr(-0.5), '-PKR 0.50');
    });

    test('rounds to two places before grouping', () {
      expect(pkr(999.999), 'PKR 1,000');
    });
  });

  group('ReportColumn', () {
    test('the label falls back to the key so no header is ever blank', () {
      expect(ReportColumn.fromJson({'key': 'gross'}).label, 'gross');
      expect(ReportColumn.fromJson({'key': 'gross', 'label': ''}).label, 'gross');
      expect(ReportColumn.fromJson({'key': 'gross', 'label': 'Gross'}).label, 'Gross');
    });

    test('money requires a literal true, since it decides formatting', () {
      expect(ReportColumn.fromJson({'key': 'gross', 'money': true}).money, isTrue);
      expect(ReportColumn.fromJson({'key': 'gross', 'money': 'true'}).money, isFalse);
      expect(ReportColumn.fromJson({'key': 'ref'}).money, isFalse);
    });
  });

  group('ReportRow', () {
    const gross = ReportColumn(key: 'gross', label: 'Gross', money: true);
    const ref = ReportColumn(key: 'ref', label: 'Reference');

    test('a money cell is formatted the same way as a total', () {
      const row = ReportRow({'gross': '2500'});
      expect(row.cell(gross), '2500.00');
      expect(row.cell(gross), money(2500));
    });

    test('a money cell parses a pg decimal string', () {
      expect(const ReportRow({'gross': '2500.00'}).cell(gross), '2500.00');
      expect(const ReportRow({'gross': 2500.5}).cell(gross), '2500.50');
    });

    test('an empty cell renders empty rather than the word null or a zero', () {
      const row = ReportRow({'ref': 'BK-1'});
      expect(row.cell(gross), '');
      expect(const ReportRow({'gross': null}).cell(gross), '');
      expect(row.cell(ref), 'BK-1');
    });

    test('a non-money cell is passed through verbatim', () {
      expect(const ReportRow({'ref': 'BK-1'}).cell(ref), 'BK-1');
      expect(const ReportRow({'ref': 42}).cell(ref), '42');
    });

    test('kind and ref are the only two facts lifted out of the map', () {
      const t = ReportRow({'kind': 'tournament', 'ref': 'TR-9'});
      expect(t.kind, 'tournament');
      expect(t.isTournament, isTrue);
      expect(t.ref, 'TR-9');

      const b = ReportRow({'kind': 'booking', 'ref': 'BK-1'});
      expect(b.isTournament, isFalse);
    });

    test('a row with neither reads as empty strings, not null', () {
      const row = ReportRow({});
      expect(row.kind, '');
      expect(row.ref, '');
      expect(row.isTournament, isFalse);
    });
  });

  group('ReportTotals', () {
    test('counts are read as ints, including from pg strings', () {
      const t = ReportTotals({'rows': '12', 'bookings': 10, 'tournaments': '2'});
      expect(t.rows, 12);
      expect(t.bookings, 10);
      expect(t.tournaments, 2);
    });

    test('an absent count is zero, which is the honest reading of no rows', () {
      const t = ReportTotals({});
      expect(t.rows, 0);
      expect(t.bookings, 0);
      expect(t.tournaments, 0);
    });

    test('every money field is keyed the same way a row cell is', () {
      const t = ReportTotals({
        'gross': '5000.00',
        'commission': 500,
        'net': '4500.00',
        'refunded': '250.5',
        'depositForfeited': '100',
        'depositHeld': 0,
      });
      expect(t.gross, 5000.0);
      expect(t.commission, 500.0);
      expect(t.net, 4500.0);
      expect(t.refunded, 250.5);
      expect(t.depositForfeited, 100.0);
      expect(t.depositHeld, 0.0);
    });

    test('amount reads a column the named getters do not cover', () {
      expect(const ReportTotals({'platformFee': '75.25'}).amount('platformFee'), 75.25);
      expect(const ReportTotals({}).amount('platformFee'), 0.0);
    });

    test('an unparseable amount reads as zero rather than throwing', () {
      expect(const ReportTotals({'gross': 'n/a'}).gross, 0.0);
    });
  });

  group('OwnerSubtotal', () {
    test('a row with no owner on record is named rather than left blank', () {
      expect(OwnerSubtotal.fromJson({}).name, '(no owner on record)');
      expect(OwnerSubtotal.fromJson({'name': '   '}).name, '(no owner on record)');
      expect(OwnerSubtotal.fromJson({'name': 'Ali Raza'}).name, 'Ali Raza');
    });

    test('ownerId stays null so a missing owner cannot be grouped as one', () {
      expect(OwnerSubtotal.fromJson({}).ownerId, isNull);
      expect(OwnerSubtotal.fromJson({'ownerId': ''}).ownerId, isNull);
      expect(OwnerSubtotal.fromJson({'ownerId': 'o1'}).ownerId, 'o1');
    });

    test('the subtotal reads its amounts from the same object as its name', () {
      final s = OwnerSubtotal.fromJson({
        'ownerId': 'o1',
        'name': 'Ali Raza',
        'rows': '3',
        'gross': '9000.00',
        'commission': '900.00',
      });
      expect(s.totals.rows, 3);
      expect(s.totals.gross, 9000.0);
      expect(s.totals.commission, 900.0,
          reason: 'commission per owner is the FR4.16 figure and is read here');
    });
  });

  group('ReportPreview', () {
    test('the range is read out of its nested object', () {
      final p = ReportPreview.fromJson({
        'range': {'from': '2026-08-01', 'to': '2026-08-31', 'days': 31},
      });
      expect(p.from, '2026-08-01');
      expect(p.to, '2026-08-31');
      expect(p.days, 31);
    });

    test('a missing or non-map range leaves the dates empty', () {
      final p = ReportPreview.fromJson({});
      expect(p.from, '');
      expect(p.to, '');
      expect(p.days, 0);
      expect(ReportPreview.fromJson({'range': 'august'}).from, '');
    });

    test('columns keep the order the server sent them in', () {
      final p = ReportPreview.fromJson({
        'columns': [
          {'key': 'ref', 'label': 'Reference'},
          {'key': 'gross', 'label': 'Gross', 'money': true},
          {'key': 'net', 'label': 'Net', 'money': true},
        ],
      });
      expect(p.columns.map((c) => c.key).toList(), ['ref', 'gross', 'net']);
      expect(p.columns.first.money, isFalse);
      expect(p.columns.last.money, isTrue);
    });

    test('rows are parsed and non-map entries skipped', () {
      final p = ReportPreview.fromJson({
        'rows': [
          {'kind': 'booking', 'ref': 'BK-1'},
          'garbage',
          {'kind': 'tournament', 'ref': 'TR-9'},
        ],
      });
      expect(p.rows.length, 2);
      expect(p.rows.last.isTournament, isTrue);
    });

    test('truncated requires a literal true, because it changes what is claimed', () {
      expect(ReportPreview.fromJson({'truncated': true}).truncated, isTrue);
      expect(ReportPreview.fromJson({'truncated': 'true'}).truncated, isFalse);
      expect(ReportPreview.fromJson({}).truncated, isFalse);
    });

    test('a truncated page still carries whole-range totals', () {
      final p = ReportPreview.fromJson({
        'truncated': true,
        'rows': [
          {'ref': 'BK-1'},
        ],
        'totals': {'rows': 5000, 'gross': '900000.00'},
      });
      expect(p.rows.length, 1);
      expect(p.totals.rows, 5000,
          reason: 'the totals are for the range, never for the page');
      expect(p.totals.gross, 900000.0);
    });

    test('isEmpty follows the total row count, not the page', () {
      expect(ReportPreview.fromJson({}).isEmpty, isTrue);
      expect(
        ReportPreview.fromJson({
          'totals': {'rows': 0},
          'rows': const [],
        }).isEmpty,
        isTrue,
      );
      expect(ReportPreview.fromJson({'totals': {'rows': 1}}).isEmpty, isFalse);
    });

    test('byOwner is empty on an owner-scoped report', () {
      expect(ReportPreview.fromJson({}).byOwner, isEmpty);
      final p = ReportPreview.fromJson({
        'byOwner': [
          {'ownerId': 'o1', 'name': 'Ali', 'commission': '900'},
          {'name': 'Sana', 'commission': '450'},
        ],
      });
      expect(p.byOwner.length, 2);
      expect(p.byOwner.first.totals.commission, 900.0);
    });

    test('the pre-read default claims nothing at all', () {
      const p = ReportPreview.empty;
      expect(p.from, '');
      expect(p.columns, isEmpty);
      expect(p.rows, isEmpty);
      expect(p.byOwner, isEmpty);
      expect(p.truncated, isFalse);
      expect(p.isEmpty, isTrue);
    });
  });
}
