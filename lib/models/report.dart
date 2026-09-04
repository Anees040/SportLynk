/// report.dart — FR4.16. The financial export, as the preview screen
/// reads it (`?format=json` on the same two routes that stream the CSV).
///
/// The COLUMNS come from the server, and so does their order.
/// `reportService.COLUMNS` is the single definition of what a row contains, which
/// columns are money, and which appear only in the platform scope. The preview
/// renders whatever that list says, in that order, so the table on the phone and
/// the file in Excel can never disagree — and adding a column is a server change
/// with no app release. A hard-coded Dart column list would be a second source of
/// truth for the shape of a financial document, which is the last place to keep
/// one.
///
/// A row is A MAP, deliberately. Every cell is addressed by the column key the
/// server sent, so a row model with nineteen named fields cannot fall out of step
/// with the header. Only the two facts the UI genuinely branches on — is this a
/// booking or a tournament payout, and what is its reference — are lifted out.
library;

double _num(dynamic v, [double d = 0]) =>
    v is num ? v.toDouble() : double.tryParse('$v') ?? d;
int _int(dynamic v, [int d = 0]) =>
    v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? d);
String? _str(dynamic v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(dynamic v) => (v as List? ?? const [])
    .whereType<Map>()
    .map((m) => Map<String, dynamic>.from(m))
    .toList();

/// One column of the export. `money` decides alignment and formatting on the
/// phone and is the same flag that decides which cells are summed into total.
class ReportColumn {
  final String key;
  final String label;
  final bool money;

  const ReportColumn({required this.key, required this.label, this.money = false});

  factory ReportColumn.fromJson(Map<String, dynamic> j) => ReportColumn(
        key: '${j['key'] ?? ''}',
        label: _str(j['label']) ?? '${j['key'] ?? ''}',
        money: j['money'] == true,
      );
}

/// One row, addressed by column key.
class ReportRow {
  final Map<String, dynamic> cells;

  const ReportRow(this.cells);

  /// `booking` or `tournament`. A tournament payout leaves the booking-only cells
  /// empty, which is why the table needs to know.
  String get kind => '${cells['kind'] ?? ''}';
  bool get isTournament => kind == 'tournament';

  String get ref => '${cells['ref'] ?? ''}';

  /// The display value for one column. Money is formatted here rather than in the
  /// widget so a total and a cell can never be formatted two different ways.
  String cell(ReportColumn c) {
    final v = cells[c.key];
    if (v == null) return '';
    if (c.money) return money(_num(v));
    return '$v';
  }
}

/// Two-place, no thousands separator — the same shape `utils/csv.js` writes, so a
/// number read on the phone matches the number in the file byte for byte.
String money(double v) => v.toStringAsFixed(2);

/// PKR with thousands separators, for the big summary numbers only.
String pkr(double v) {
  final neg = v < 0;
  final parts = v.abs().toStringAsFixed(2).split('.');
  final digits = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  final body = parts[1] == '00' ? '$buf' : '$buf.${parts[1]}';
  return '${neg ? '-' : ''}PKR $body';
}

/// The total row, and each per-owner subtotal in the platform scope. Keyed the
/// same way a row is, plus the three counts.
class ReportTotals {
  final Map<String, dynamic> values;

  const ReportTotals(this.values);

  int get rows => _int(values['rows']);
  int get bookings => _int(values['bookings']);
  int get tournaments => _int(values['tournaments']);

  double amount(String key) => _num(values[key]);

  double get gross => amount('gross');
  double get commission => amount('commission');
  double get net => amount('net');
  double get refunded => amount('refunded');
  double get depositForfeited => amount('depositForfeited');
  double get depositHeld => amount('depositHeld');
}

/// A per-owner subtotal from the platform report. This is where "commission earned
/// per owner" (FR4.16) lives, because commission is a ledger row on the
/// owner's wallet rather than a column of the booking.
class OwnerSubtotal {
  final String? ownerId;
  final String name;
  final ReportTotals totals;

  const OwnerSubtotal({required this.name, required this.totals, this.ownerId});

  factory OwnerSubtotal.fromJson(Map<String, dynamic> j) => OwnerSubtotal(
        ownerId: _str(j['ownerId']),
        name: _str(j['name']) ?? '(no owner on record)',
        totals: ReportTotals(j),
      );
}

/// `GET …/reports/financial?format=json` — the same walk the CSV streams, capped
/// at the server's `JSON_ROW_CAP`. `truncated` says so out loud: the totals are
/// always for the whole range, only `rows` is a page, and the screen must not
/// imply otherwise.
class ReportPreview {
  final String from;
  final String to;
  final int days;
  final List<ReportColumn> columns;
  final ReportTotals totals;
  final List<ReportRow> rows;
  final bool truncated;
  final List<OwnerSubtotal> byOwner;

  const ReportPreview({
    required this.from,
    required this.to,
    required this.totals,
    this.days = 0,
    this.columns = const [],
    this.rows = const [],
    this.truncated = false,
    this.byOwner = const [],
  });

  static const empty = ReportPreview(
    from: '',
    to: '',
    totals: ReportTotals({}),
  );

  factory ReportPreview.fromJson(Map<String, dynamic> j) {
    final r = _map(j['range']);
    return ReportPreview(
      from: _str(r['from']) ?? '',
      to: _str(r['to']) ?? '',
      days: _int(r['days']),
      columns: _rows(j['columns']).map(ReportColumn.fromJson).toList(),
      totals: ReportTotals(_map(j['totals'])),
      rows: _rows(j['rows']).map(ReportRow.new).toList(),
      truncated: j['truncated'] == true,
      byOwner: _rows(j['byOwner']).map(OwnerSubtotal.fromJson).toList(),
    );
  }

  bool get isEmpty => totals.rows == 0;
}
