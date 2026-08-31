import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../constants/api_constants.dart';
import '../models/report.dart';
import 'api_service.dart';

/// A downloaded CSV. `ok == false` carries a sentence for the user rather than an
/// exception — the same contract as every other service in the app.
class CsvFile {
  final bool ok;
  final String message;
  final Uint8List? bytes;
  final String filename;

  const CsvFile({
    required this.ok,
    this.message = '',
    this.bytes,
    this.filename = '',
  });

  int get sizeBytes => bytes?.length ?? 0;

  /// "12.4 KB" — shown next to the Share button so the owner knows something real
  /// arrived before they hand it to WhatsApp.
  String get sizeLabel {
    final n = sizeBytes;
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// The financial export (FR4.16), in the two shapes the screen needs.
///
/// WHY THE CSV DOES NOT GO THROUGH [ApiClient].
/// `ApiClient` sends `Accept: application/json` and decodes every response into
/// the `{success, ...}` envelope — it is built to never throw and to always return
/// a Map. The CSV route answers `text/csv; charset=utf-8` with a
/// `Content-Disposition: attachment` header and a UTF-8 BOM as its first three
/// bytes; running that through a JSON decoder would produce "the server sent
/// something we could not read" for a response that is perfectly correct. So the
/// download is a plain `http.get` that keeps `bodyBytes` intact, and the BOM
/// survives — which is the whole reason Excel on Windows opens the file with Urdu
/// venue names and em dashes readable instead of as mojibake.
///
/// The PREVIEW does go through [ApiClient]: `?format=json` is an ordinary
/// enveloped read, and it is the same server-side walk that the CSV streams, so
/// the totals on the phone cannot disagree with the totals in the file.
class ReportService {
  final ApiClient _api = ApiClient();

  /// `scope` picks the route: the owner's own venues, or the whole platform.
  static String _path(bool platform) =>
      platform ? ApiConstants.adminPlatformReport : ApiConstants.ownerFinancialReport;

  /// `from`/`to` are REQUIRED `YYYY-MM-DD` and the span is capped at 366 days
  /// server-side. Returns null on failure, with the server's message in
  /// [lastMessage] — a report screen has to be able to say WHY it is empty.
  String lastMessage = '';

  Future<ReportPreview?> preview(
    String token, {
    required String from,
    required String to,
    String? venueId,
    bool platform = false,
  }) async {
    final params = <String, String>{'from': from, 'to': to, 'format': 'json'};
    if (venueId != null && venueId.isNotEmpty) params['venueId'] = venueId;
    final r = await _api.get(_path(platform), token: token, queryParams: params);
    if (r['success'] != true || r['data'] is! Map) {
      lastMessage = '${r['message'] ?? 'Could not load the report.'}';
      return null;
    }
    lastMessage = '';
    return ReportPreview.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// Download the CSV itself.
  ///
  /// A non-2xx answer is JSON (`{success:false,message}`) because the failure
  /// happened BEFORE the first byte of the file went out; once streaming starts
  /// the status code is spent, and a mid-stream failure instead appends a final
  /// `ERROR,…` row to the file. So a 200 whose last line starts with `ERROR,` is a
  /// truncated export, and saying so is better than handing over a file that is
  /// quietly missing yesterday's bookings.
  Future<CsvFile> downloadCsv(
    String token, {
    required String from,
    required String to,
    String? venueId,
    bool platform = false,
  }) async {
    final params = <String, String>{'from': from, 'to': to, 'format': 'csv'};
    if (venueId != null && venueId.isNotEmpty) params['venueId'] = venueId;
    final uri = Uri.parse('${ApiConstants.baseUrl}${_path(platform)}')
        .replace(queryParameters: params);

    try {
      final res = await http.get(uri, headers: {
        'Accept': 'text/csv',
        'Authorization': 'Bearer $token',
      }).timeout(const Duration(seconds: 60));

      if (res.statusCode < 200 || res.statusCode >= 300) {
        return CsvFile(ok: false, message: _messageFrom(res));
      }

      final name = _filenameFrom(res.headers['content-disposition'])
          ?? '${platform ? 'sportlynk-platform' : 'sportlynk-financial'}-$from-to-$to.csv';

      final bytes = res.bodyBytes;
      final truncated = _endsWithErrorRow(bytes);
      return CsvFile(
        ok: true,
        bytes: bytes,
        filename: name,
        message: truncated
            ? 'The export failed part-way through — the last row of the file says so. Try a shorter range.'
            : '',
      );
    } on Exception catch (e) {
      return CsvFile(ok: false, message: _networkMessage(e));
    }
  }

  /// Hand the file to the OS share sheet.
  ///
  /// `XFile.fromData` rather than writing to a directory ourselves: share_plus's
  /// platform channel already spools an empty-path XFile into the app's temp
  /// directory before handing it over, so this needs no `path_provider` import and
  /// no storage permission. `fileNameOverrides` is what makes the attachment
  /// arrive as `sportlynk-financial-….csv` instead of a UUID.
  Future<bool> share(CsvFile file, {String? subject}) async {
    final bytes = file.bytes;
    if (!file.ok || bytes == null || bytes.isEmpty) return false;
    final result = await Share.shareXFiles(
      [XFile.fromData(bytes, mimeType: 'text/csv', name: file.filename)],
      fileNameOverrides: [file.filename],
      subject: subject ?? 'SportLynk financial export',
    );
    // `unavailable` means the sheet was shown but Android could not report which
    // app was picked -- that is a success, not a failure. Only `dismissed` is a no.
    return result.status != ShareResultStatus.dismissed;
  }

  /// `attachment; filename="sportlynk-financial-2026-01-01-to-2026-08-31.csv"`.
  /// The server already made this header-safe; this only unwraps it.
  static String? _filenameFrom(String? disposition) {
    if (disposition == null) return null;
    final m = RegExp('filename="([^"]+)"').firstMatch(disposition);
    final name = m?.group(1)?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  /// A failure before the first byte is a normal JSON envelope.
  static String _messageFrom(http.Response res) {
    final body = res.body.trim();
    final m = RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(body);
    final msg = m?.group(1);
    if (msg != null && msg.isNotEmpty) return msg;
    if (res.statusCode == 401 || res.statusCode == 403) {
      return 'You are not signed in as the owner of this venue.';
    }
    return 'The export failed (HTTP ${res.statusCode}).';
  }

  /// Only the tail is decoded: the file can be megabytes, and the marker is the
  /// last row.
  static bool _endsWithErrorRow(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final start = bytes.length > 240 ? bytes.length - 240 : 0;
    final tail = String.fromCharCodes(bytes.sublist(start));
    final lines = tail.trimRight().split('\n');
    return lines.isNotEmpty && lines.last.startsWith('ERROR,');
  }

  static String _networkMessage(Object e) {
    final s = '$e';
    if (s.contains('TimeoutException')) {
      return 'The export took too long. Try a shorter date range.';
    }
    if (s.contains('Failed host lookup') || s.contains('SocketException')) {
      return 'No connection to the server.';
    }
    return 'Could not download the export.';
  }
}
