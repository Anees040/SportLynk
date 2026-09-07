// ReportService: the two shapes of the financial export, and the reason only one of
// them goes through [ApiClient].
//
// The preview is an ordinary enveloped read — `?format=json` walks the same rows the
// CSV streams, so the totals on the phone cannot disagree with the totals in the file.
// The download is not: that route answers `text/csv; charset=utf-8` with a
// `Content-Disposition` filename and a UTF-8 BOM as its first three bytes, and running
// it through a JSON decoder would report "the server sent something we could not read"
// for a response that is perfectly correct. So `downloadCsv` is a plain `http.get` that
// keeps `bodyBytes` intact, and the tests below assert the BOM survives byte for byte —
// that BOM is the only reason Excel on Windows opens the file with Urdu venue names
// readable instead of as mojibake.
//
// The failure contract has two halves, split by when the failure happened. Before the
// first byte goes out the route can still answer JSON, so a non-2xx carries the
// server's sentence and `_messageFrom` digs it out with a regex rather than a decoder —
// the body may not be JSON at all. Once streaming has started the status code is spent,
// so a mid-stream failure appends a final `ERROR,…` row instead: a 200 whose last line
// starts with `ERROR,` is a TRUNCATED export, and saying so is better than handing an
// owner a file that is quietly missing yesterday's bookings.
//
// `lastMessage` is process state on the service instance, which is why it is asserted
// as cleared by a subsequent success: a screen that showed a stale refusal beside fresh
// figures would be worse than one that showed nothing.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/services/report_service.dart';

import 'http_seam.dart';

/// A CSV exactly as the route sends one: BOM, header row, one data row.
List<int> _csv([String tail = 'BK-1001,Arena One,2026-03-14,2500.00,250.00,2250.00']) =>
    <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('ref,venue,date,gross,commission,net\n$tail\n')];

const _csvHeaders = {
  'content-type': 'text/csv; charset=utf-8',
  'content-disposition':
      'attachment; filename="sportlynk-financial-2026-03-01-to-2026-03-31.csv"',
};

void main() {
  late FakeApi api;
  late ReportService service;

  setUp(() {
    api = FakeApi();
    service = ReportService();
  });

  tearDown(resetApiClient);

  group('the preview', () {
    test('an owner reads their own venues and asks for JSON', () async {
      api.ok(const {});
      await api.run(() => service.preview('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(api.endpoint().split('?').first, '/owner/reports/financial');
      expect(api.query(), {'from': '2026-03-01', 'to': '2026-03-31', 'format': 'json'});
      expect(api.method(), 'GET');
    });

    // One generator, two scopes. The route is the only thing that changes, so a screen
    // cannot accidentally show an owner the whole platform.
    test('the platform scope is a different route, not a parameter', () async {
      api.ok(const {});
      await api.run(() => service.preview('JWT',
          from: '2026-03-01', to: '2026-03-31', platform: true));
      expect(api.endpoint().split('?').first, '/admin/reports/platform');
      expect(api.query().keys, isNot(contains('platform')));
    });

    test('a venue filter is sent when given and dropped when blank', () async {
      api.ok(const {});
      await api.run(() async {
        await service.preview('JWT', from: '2026-03-01', to: '2026-03-31', venueId: 'v1');
        await service.preview('JWT', from: '2026-03-01', to: '2026-03-31', venueId: '');
      });
      expect(api.query(0)['venueId'], 'v1');
      expect(api.query(1).keys, isNot(contains('venueId')));
    });

    test('the payload is parsed into columns, totals and rows', () async {
      api.ok({
        'range': {'from': '2026-03-01', 'to': '2026-03-31', 'days': '31'},
        'columns': [
          {'key': 'ref', 'label': 'Reference'},
          {'key': 'gross', 'label': 'Gross', 'money': true},
        ],
        'totals': {'rows': '2', 'bookings': '1', 'tournaments': '1', 'gross': '4000.00', 'commission': '400.00', 'net': '3600.00'},
        'rows': [
          {'kind': 'booking', 'ref': 'BK-1001', 'gross': '2500.00'},
          {'kind': 'tournament', 'ref': 'TR-9', 'gross': '1500.00'},
        ],
      });
      final p = await api.run(
          () => service.preview('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(p!.from, '2026-03-01');
      expect(p.days, 31);
      expect(p.columns.map((c) => c.label), ['Reference', 'Gross']);
      expect(p.columns.last.money, isTrue);
      expect(p.totals.gross, 4000.0);
      expect(p.totals.net, 3600.0);
      expect(p.rows.length, 2);
      expect(p.rows.last.isTournament, isTrue);
      expect(p.isEmpty, isFalse);
    });

    // The row list is capped server-side but the totals are for the whole range. A
    // screen that read `rows.length` as the count would understate the month.
    test('a truncated page says so while the totals stay whole', () async {
      api.ok({
        'totals': {'rows': '5000', 'gross': '900000.00'},
        'rows': [
          {'ref': 'BK-1'},
        ],
        'truncated': true,
      });
      final p = await api.run(
          () => service.preview('JWT', from: '2026-01-01', to: '2026-12-31'));
      expect(p!.truncated, isTrue);
      expect(p.rows.length, 1);
      expect(p.totals.rows, 5000);
    });

    test('per-owner subtotals reach the platform report', () async {
      api.ok({
        'totals': {'rows': '3'},
        'byOwner': [
          {'ownerId': 'o1', 'name': 'Arena Group', 'commission': '400.00'},
          {'commission': '50.00'},
        ],
      });
      final p = await api.run(() => service.preview('JWT',
          from: '2026-03-01', to: '2026-03-31', platform: true));
      expect(p!.byOwner.first.name, 'Arena Group');
      expect(p.byOwner.first.totals.commission, 400.0);
      expect(p.byOwner.last.name, '(no owner on record)');
    });

    test('an empty range is a preview that reports itself empty', () async {
      api.ok({'totals': {'rows': '0'}, 'rows': const []});
      final p = await api.run(
          () => service.preview('JWT', from: '2026-03-01', to: '2026-03-02'));
      expect(p!.isEmpty, isTrue);
    });
  });

  group('a refused preview', () {
    // A report screen has to be able to say why it is empty, and the typed preview
    // cannot carry a reason, so the sentence is parked on the service.
    test('the span cap is reported in lastMessage', () async {
      api.fail('A report may cover at most 366 days.', status: 400);
      final p = await api.run(
          () => service.preview('JWT', from: '2025-01-01', to: '2026-12-31'));
      expect(p, isNull);
      expect(service.lastMessage, 'A report may cover at most 366 days.');
    });

    // [ApiClient] substitutes a sentence for every non-2xx, so the service's own
    // fallback is reachable only through the one case it does not touch: a success
    // envelope whose `data` is not the object this read expects.
    test('a successful envelope with no report in it still says something', () async {
      api.ok(null);
      final p = await api.run(
          () => service.preview('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(p, isNull);
      expect(service.lastMessage, 'Could not load the report.');
    });

    test('a server error arrives as the client-side sentence for a 500', () async {
      api.json(const {'success': false}, status: 500);
      await api.run(() => service.preview('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(service.lastMessage, 'Something went wrong on the server.');
    });

    // A stale refusal beside fresh figures is worse than no message at all.
    test('a later success clears the message', () async {
      api
        ..fail('A report may cover at most 366 days.', status: 400)
        ..ok({'totals': {'rows': '1'}});
      await api.run(() async {
        await service.preview('JWT', from: '2025-01-01', to: '2026-12-31');
        expect(service.lastMessage, isNotEmpty);
        await service.preview('JWT', from: '2026-03-01', to: '2026-03-31');
      });
      expect(service.lastMessage, isEmpty);
    });

    test('a transport failure is a sentence, not a throw', () async {
      api.offline();
      final p = await api.run(
          () => service.preview('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(p, isNull);
      expect(service.lastMessage, isNotEmpty);
    });
  });

  group('the CSV download', () {
    test('the download asks for CSV on the same route as the preview', () async {
      api.rawBytes(_csv(), headers: _csvHeaders);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.ok, isTrue);
      expect(api.endpoint().split('?').first, '/owner/reports/financial');
      expect(api.query()['format'], 'csv');
      expect(api.header('Accept'), 'text/csv');
      expect(api.token(), 'JWT');
    });

    // The BOM is the contract: without those three bytes Excel on Windows opens the
    // file in the system codepage and every non-ASCII venue name arrives as mojibake.
    test('the BOM reaches the caller byte for byte', () async {
      api.rawBytes(_csv(), headers: _csvHeaders);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.bytes!.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(f.sizeBytes, _csv().length);
    });

    // The server already made the filename header-safe; the service only unwraps it,
    // and the name is what makes the attachment arrive as a report rather than a UUID.
    test('the filename comes from the disposition header', () async {
      api.rawBytes(_csv(), headers: _csvHeaders);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.filename, 'sportlynk-financial-2026-03-01-to-2026-03-31.csv');
    });

    test('a missing disposition header falls back to a named range', () async {
      api.rawBytes(_csv(), headers: const {'content-type': 'text/csv'});
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.filename, 'sportlynk-financial-2026-03-01-to-2026-03-31.csv');
    });

    test('the platform export is named for its own scope', () async {
      api.rawBytes(_csv(), headers: const {'content-type': 'text/csv'});
      final f = await api.run(() => service.downloadCsv('JWT',
          from: '2026-03-01', to: '2026-03-31', platform: true));
      expect(f.filename, 'sportlynk-platform-2026-03-01-to-2026-03-31.csv');
      expect(api.endpoint().split('?').first, '/admin/reports/platform');
    });

    test('a quoted filename that is empty is treated as absent', () async {
      api.rawBytes(_csv(), headers: const {
        'content-disposition': 'attachment; filename=""',
      });
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.filename, 'sportlynk-financial-2026-03-01-to-2026-03-31.csv');
    });

    test('the size label is human-readable at each magnitude', () async {
      api.rawBytes(List<int>.filled(2560, 0x41), headers: const {});
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.sizeLabel, '2.5 KB');
      expect(const CsvFile(ok: true).sizeLabel, '0 B');
    });
  });

  group('a failed download', () {
    // Before the first byte the route can still answer JSON, so the server's own
    // sentence is what an owner reads. The regex is deliberate: the body may not be
    // JSON at all, and a decoder would throw where this simply finds nothing.
    test("a refusal carries the server's sentence", () async {
      api.raw('{"success":false,"message":"A report may cover at most 366 days."}',
          status: 400);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2025-01-01', to: '2026-12-31'));
      expect(f.ok, isFalse);
      expect(f.message, 'A report may cover at most 366 days.');
      expect(f.bytes, isNull);
    });

    test('a signed-out download says which credential is wrong', () async {
      api.raw('', status: 403);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.ok, isFalse);
      expect(f.message, 'You are not signed in as the owner of this venue.');
    });

    // A proxy or a crash can answer HTML. The status code is then the only fact
    // available, and reporting it is more useful than reporting nothing.
    test('a non-JSON error page falls back to the status code', () async {
      api.raw('<html><body>Bad Gateway</body></html>', status: 502);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.message, 'The export failed (HTTP 502).');
    });

    test('an empty message field is not mistaken for a sentence', () async {
      api.raw('{"success":false,"message":""}', status: 400);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.message, 'The export failed (HTTP 400).');
    });

    test('a dead server is named as a connection problem', () async {
      api.offline('SocketException: Connection refused');
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.ok, isFalse);
      expect(f.message, 'No connection to the server.');
    });

    test('an unrecognised transport failure still says something', () async {
      api.offline('Connection closed before full header was received');
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.message, 'Could not download the export.');
    });
  });

  // The 60-second budget is the service's own, not [ApiClient]'s: a month of bookings
  // is a slow query and a stalled export has to end in a sentence rather than a
  // spinner. `pump` advances the test clock, so nothing here waits a real minute.
  group('a download that never answers', () {
    testWidgets('the export gives up on its own budget', (tester) async {
      api.hang();
      late CsvFile f;
      await api.run(() async {
        final pending =
            service.downloadCsv('JWT', from: '2026-01-01', to: '2026-12-31');
        await tester.pump(const Duration(seconds: 61));
        f = await pending;
      });
      expect(f.ok, isFalse);
      expect(f.message, 'The export took too long. Try a shorter date range.');
      expect(f.bytes, isNull);
    });
  });

  // A mid-stream failure cannot change the status code, so the route appends a final
  // `ERROR,` row instead. The rows before it are real, which is why the bytes are
  // still handed over: a partial file plus a warning beats no file and no reason.
  group('a truncated export', () {
    test('a trailing error row is reported while the rows still arrive', () async {
      api.rawBytes(_csv('ERROR,export failed after 12 rows'), headers: _csvHeaders);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.ok, isTrue);
      expect(f.bytes, isNotNull);
      expect(
        f.message,
        'The export failed part-way through — the last row of the file says so. '
        'Try a shorter range.',
      );
    });

    // Only the last 240 bytes are decoded, because the file can be megabytes and the
    // marker is always the final row. A long export must still be caught.
    test('the marker is found at the end of a long file', () async {
      final rows = List<String>.generate(
          400, (i) => 'BK-${1000 + i},Arena One,2026-03-14,2500.00,250.00,2250.00');
      final body = <int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('ref,venue,date,gross,commission,net\n'
            '${rows.join('\n')}\n'
            'ERROR,export failed after 400 rows\n'),
      ];
      api.rawBytes(body, headers: _csvHeaders);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.sizeBytes, body.length);
      expect(f.message, contains('failed part-way through'));
    });

    // A venue legitimately named "ERROR, Ltd" mid-file is not a truncation. The
    // marker is only the marker in the last row.
    test('an error row anywhere but the last is not a truncation', () async {
      final body = <int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('ref,venue,date,gross,commission,net\n'
            'ERROR,not the last row,2026-03-14,0.00,0.00,0.00\n'
            'BK-1002,Arena Two,2026-03-15,2500.00,250.00,2250.00\n'),
      ];
      api.rawBytes(body, headers: _csvHeaders);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.ok, isTrue);
      expect(f.message, isEmpty);
    });

    test('an empty body is not read as a truncation', () async {
      api.rawBytes(const <int>[], headers: _csvHeaders);
      final f = await api.run(
          () => service.downloadCsv('JWT', from: '2026-03-01', to: '2026-03-31'));
      expect(f.ok, isTrue);
      expect(f.sizeBytes, 0);
      expect(f.message, isEmpty);
    });
  });

  // `share` reaches a platform channel, which a unit test cannot answer. What it can
  // pin is the guard in front of it: nothing is handed to the share sheet unless
  // there are bytes to hand over, so a refused download never opens an empty sheet.
  group('sharing', () {
    test('a refused download is never shared', () async {
      expect(await service.share(const CsvFile(ok: false, message: 'nope')), isFalse);
    });

    test('a download with no bytes is never shared', () async {
      expect(await service.share(const CsvFile(ok: true, filename: 'a.csv')), isFalse);
    });

    test('an empty file is never shared', () async {
      final empty = CsvFile(ok: true, bytes: Uint8List(0), filename: 'a.csv');
      expect(await service.share(empty), isFalse);
    });
  });
}
