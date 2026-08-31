// owner_reports_screen.dart — S.7 Wave D · D5 / FR4.16. The financial export.
//
// ONE SCREEN, TWO SCOPES. `platform: false` is the owner's own venues
// (`GET /api/owner/reports/financial`); `platform: true` is every venue on the
// platform with commission broken out per owner (`GET /api/admin/reports/platform`).
// The two answers have the same shape — the server runs the SAME generator over a
// different WHERE — so a second screen would be a second place for the column list
// to drift.
//
// THE TABLE'S COLUMNS ARE THE SERVER'S, IN THE SERVER'S ORDER. `columns` arrives
// with the preview and says which cells are money; nothing here knows that a
// financial row has nineteen fields. Adding a column to `reportService.COLUMNS`
// changes this screen with no Flutter release, and the phone can never show a
// header the file does not have.
//
// THE PREVIEW AND THE FILE ARE THE SAME WALK. `?format=json` is not a summary
// endpoint — it is the CSV's own row loop collected into a list and capped at the
// server's `JSON_ROW_CAP`. So the totals here are the totals in the file, for the
// WHOLE range, while `rows` may be one page. `truncated` says that out loud rather
// than letting the owner assume the table is the export.
//
// WHY DOWNLOAD IS A SEPARATE ACTION FROM PREVIEW. The CSV is `text/csv` with a
// BOM and an attachment header; it does not go through `ApiClient` at all (see
// `ReportService`). Previewing first means the owner has seen the totals before
// they hand a file to their accountant — and a 0-row range is caught before a
// download that would contain only a header.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/api_constants.dart';
import '../../constants/colors.dart';
import '../../models/report.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/report_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/match_widgets.dart';

class OwnerReportsScreen extends StatefulWidget {
  /// `true` renders the admin's platform-wide report. The route decides this; the
  /// screen never guesses it from the signed-in role, because an admin who also
  /// owns venues is a real case and both reports are legitimately theirs.
  final bool platform;

  const OwnerReportsScreen({super.key, this.platform = false});

  @override
  State<OwnerReportsScreen> createState() => _OwnerReportsScreenState();
}

class _OwnerReportsScreenState extends State<OwnerReportsScreen> {
  final _svc = ReportService();
  final _api = ApiClient();

  /// Mirrors `reportService.RANGE_MAX_DAYS`. It bounds the PICKER so the common
  /// mistake is impossible; the server refuses anything longer regardless, and its
  /// refusal is shown verbatim if one ever gets through.
  static const int _maxDays = 366;

  late DateTime _from;
  late DateTime _to;
  String _presetLabel = 'This month';

  List<Map<String, dynamic>> _venues = const [];
  String? _venueId;

  ReportPreview? _preview;
  bool _loading = false;
  bool _downloading = false;
  String _error = '';
  CsvFile? _file;

  String? get _token => Provider.of<AuthProvider>(context, listen: false).token;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = now;
    if (!widget.platform) _loadVenues();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  // ── Loading ───────────────────────────────────────────────────────────────
  Future<void> _loadVenues() async {
    final token = _token;
    if (token == null) return;
    final r = await _api.get(ApiConstants.ownerVenues, token: token);
    if (!mounted) return;
    final rows = r['data'];
    setState(() {
      _venues = rows is List
          ? rows.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
          : const [];
    });
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  int get _days => _to.difference(_from).inDays + 1;

  /// Re-read the preview. A new range invalidates any downloaded file: handing over
  /// a CSV for January while the screen shows February's totals is exactly the kind
  /// of quiet mismatch a financial export must not be capable of.
  Future<void> _run() async {
    final token = _token;
    if (token == null) return;
    setState(() {
      _loading = true;
      _error = '';
      _file = null;
    });
    final p = await _svc.preview(
      token,
      from: _iso(_from),
      to: _iso(_to),
      venueId: widget.platform ? null : _venueId,
      platform: widget.platform,
    );
    if (!mounted) return;
    setState(() {
      _preview = p;
      _error = p == null ? _svc.lastMessage : '';
      _loading = false;
    });
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _from, end: _to),
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: 'Export range',
      saveText: 'Use range',
    );
    if (picked == null || !mounted) return;
    final span = picked.end.difference(picked.start).inDays + 1;
    if (span > _maxDays) {
      SnackbarUtil.showError(
        context,
        'That is $span days; the maximum is $_maxDays. Export it in parts.',
      );
      return;
    }
    setState(() {
      _from = picked.start;
      _to = picked.end;
      _presetLabel = 'Custom';
    });
    await _run();
  }

  void _applyPreset(String label, DateTime from, DateTime to) {
    setState(() {
      _presetLabel = label;
      _from = from;
      _to = to;
    });
    _run();
  }

  // ── Download / share ──────────────────────────────────────────────────────
  /// Download, then offer the share sheet. An empty range is refused here rather
  /// than downloaded: a CSV containing nothing but a header row and a TOTAL of zero
  /// looks like a broken export, and saying "there is nothing in this range" is the
  /// truthful version.
  Future<void> _download({required bool thenShare}) async {
    final token = _token;
    if (token == null || _downloading) return;
    final p = _preview;
    if (p != null && p.isEmpty) {
      SnackbarUtil.showInfo(context, 'Nothing to export in that range.');
      return;
    }
    setState(() => _downloading = true);
    final file = await _svc.downloadCsv(
      token,
      from: _iso(_from),
      to: _iso(_to),
      venueId: widget.platform ? null : _venueId,
      platform: widget.platform,
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _file = file.ok ? file : null;
    });

    if (!file.ok) {
      SnackbarUtil.showError(context, file.message);
      return;
    }
    // A 200 can still carry a truncated file — the generator appends an `ERROR,` row
    // when it fails after the first byte, because the status code is already spent.
    if (file.message.isNotEmpty) {
      SnackbarUtil.showError(context, file.message);
    } else {
      SnackbarUtil.showSuccess(context, '${file.filename} · ${file.sizeLabel}');
    }

    if (!thenShare) return;
    final shared = await _svc.share(
      file,
      subject: widget.platform
          ? 'SportLynk platform report ${_iso(_from)} to ${_iso(_to)}'
          : 'SportLynk financial export ${_iso(_from)} to ${_iso(_to)}',
    );
    if (!mounted || shared) return;
    SnackbarUtil.showInfo(context, 'Not shared.');
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          widget.platform ? 'Platform report' : 'Financial report',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _run,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _run,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            _rangeCard(),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error.isNotEmpty)
              _errorCard()
            else if (p == null)
              const SizedBox.shrink()
            else if (p.isEmpty)
              _card(
                child: const MatchEmptyState(
                  text: 'No bookings or tournament payouts in this range.',
                  icon: Icons.receipt_long,
                ),
              )
            else ...[
              _totalsCard(p),
              const SizedBox(height: 12),
              if (widget.platform && p.byOwner.isNotEmpty) ...[
                _byOwnerCard(p),
                const SizedBox(height: 12),
              ],
              _rowsCard(p),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _loading || p == null || p.isEmpty ? null : _exportBar(p),
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      );

  Widget _errorCard() => _card(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error,
                style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.error, height: 1.35),
              ),
            ),
          ],
        ),
      );

  // ── The range ─────────────────────────────────────────────────────────────
  Widget _rangeCard() {
    final now = DateTime.now();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _loading ? null : _pickRange,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.date_range_rounded, size: 18, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_iso(_from)}  →  ${_iso(_to)}',
                          style: GoogleFonts.poppins(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          '$_presetLabel · $_days day${_days == 1 ? '' : 's'} · both days included',
                          style: GoogleFonts.poppins(
                            fontSize: 10.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.edit_calendar_outlined, size: 16, color: AppColors.textSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _preset('This month', DateTime(now.year, now.month, 1), now),
              _preset(
                'Last month',
                DateTime(now.year, now.month - 1, 1),
                DateTime(now.year, now.month, 0),
              ),
              _preset('Last 30 days', now.subtract(const Duration(days: 29)), now),
              _preset('This year', DateTime(now.year, 1, 1), now),
            ],
          ),
          if (!widget.platform && _venues.isNotEmpty) ...[
            Divider(height: 20, color: AppColors.border),
            _venuePicker(),
          ],
        ],
      ),
    );
  }

  Widget _preset(String label, DateTime from, DateTime to) {
    final selected = _presetLabel == label;
    return InkWell(
      onTap: _loading ? null : () => _applyPreset(label, from, to),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.accent : AppColors.border),
        ),
        child: Text(
          label,
          style: GoogleFonts.poppins(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// All venues, or one. The server scopes by `venues.owner_id` either way, so this
  /// narrows a report the owner is already entitled to — it is a filter, not a
  /// permission.
  Widget _venuePicker() {
    return Row(
      children: [
        const Icon(Icons.storefront_outlined, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: _venueId,
              isExpanded: true,
              hint: Text(
                'All my venues',
                style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary),
              ),
              style: GoogleFonts.poppins(fontSize: 12.5, color: AppColors.textPrimary),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All my venues', style: GoogleFonts.poppins(fontSize: 12.5)),
                ),
                for (final v in _venues)
                  DropdownMenuItem<String?>(
                    value: '${v['id']}',
                    child: Text(
                      '${v['name'] ?? 'Venue'}',
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(fontSize: 12.5),
                    ),
                  ),
              ],
              onChanged: _loading
                  ? null
                  : (v) {
                      setState(() => _venueId = v);
                      _run();
                    },
            ),
          ),
        ),
      ],
    );
  }

  // ── Totals ────────────────────────────────────────────────────────────────
  /// Every money column the server declared, in the server's order and under the
  /// server's labels — one hero number plus a grid.
  ///
  /// The hero differs by scope because the question differs: an owner is asking what
  /// they earned (`net`), the platform is asking what it took (`commission`). Both
  /// numbers are in both reports; only the emphasis moves.
  ///
  /// `Price` and `Deposit At Risk` are the AGREEMENT — what the booking says — while
  /// everything after them is the ledger. They are labelled as such because a report
  /// where "price" and "received" differ by a cancellation is correct, and an owner
  /// comparing the two columns deserves to know which is which.
  Widget _totalsCard(ReportPreview p) {
    final heroKey = widget.platform ? 'commission' : 'net';
    final money = p.columns.where((c) => c.money).toList();
    final heroMatch = money.where((c) => c.key == heroKey);
    final hero = heroMatch.isEmpty ? null : heroMatch.first;
    final rest = money.where((c) => c.key != heroKey).toList();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hero?.label ?? (widget.platform ? 'Commission' : 'Net'),
            style: GoogleFonts.poppins(fontSize: 11.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            pkr(p.totals.amount(heroKey)),
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${p.totals.rows} row${p.totals.rows == 1 ? '' : 's'} · '
            '${p.totals.bookings} booking${p.totals.bookings == 1 ? '' : 's'} · '
            '${p.totals.tournaments} tournament payout${p.totals.tournaments == 1 ? '' : 's'}',
            style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
          ),
          Divider(height: 18, color: AppColors.border),
          for (int i = 0; i < rest.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _totalTile(rest[i], p)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: i + 1 < rest.length
                        ? _totalTile(rest[i + 1], p)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          Text(
            'Money is summed from the wallet ledger, not recalculated from prices, so '
            'this reconciles with your wallet. Price and Deposit At Risk are what was '
            'agreed at booking.',
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              color: AppColors.textSecondary,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalTile(ReportColumn c, ReportPreview p) {
    final agreed = c.key == 'price' || c.key == 'depositAtRisk';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          c.label,
          style: GoogleFonts.poppins(
            fontSize: 10.5,
            color: AppColors.textSecondary,
            fontStyle: agreed ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        Text(
          pkr(p.totals.amount(c.key)),
          style: GoogleFonts.poppins(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: agreed ? AppColors.textSecondary : AppColors.textPrimary,
          ),
        ),
      ],
    );
  }

  /// FR4.16's "commission earned per owner". This is where it lives, because
  /// commission is a ledger row on the owner's wallet rather than a column of a
  /// booking — so it can only be reported by bucketing the ledger, which the server
  /// does. `(no owner on record)` is a real bucket for a venue whose owner account
  /// was deleted: without it the subtotals would not add up to the TOTAL row, and
  /// subtotals that do not reconcile make the whole report unusable.
  Widget _byOwnerCard(ReportPreview p) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Commission by owner',
            style: GoogleFonts.poppins(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            'Highest first. These add up to the TOTAL row in the file.',
            style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < p.byOwner.length; i++) ...[
            if (i > 0) Divider(height: 14, color: AppColors.border),
            _ownerRow(p.byOwner[i]),
          ],
        ],
      ),
    );
  }

  Widget _ownerRow(OwnerSubtotal o) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  o.name,
                  style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  '${o.totals.rows} row${o.totals.rows == 1 ? '' : 's'} · '
                  'gross ${pkr(o.totals.gross)}',
                  style: GoogleFonts.poppins(fontSize: 10.5, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Text(
            pkr(o.totals.commission),
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.accent,
            ),
          ),
        ],
      );

  // ── The rows ──────────────────────────────────────────────────────────────
  /// The file's own shape, scrolled sideways — this is a PREVIEW of the CSV, so it
  /// shows the same columns in the same order rather than a phone-friendly summary
  /// that would make the owner guess what they are about to download.
  ///
  /// Rendered rows are capped well below the server's own 500: nineteen cells times
  /// five hundred rows is ten thousand widgets, and the answer to "I need all of
  /// them" is the CSV, which is one tap away.
  static const int _tableCap = 40;

  Widget _rowsCard(ReportPreview p) {
    final cols = p.columns;
    final shown = p.rows.length > _tableCap ? p.rows.sublist(0, _tableCap) : p.rows;
    return _card(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rows',
            style: GoogleFonts.poppins(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            _rowsSubtitle(p, shown.length),
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              color: p.truncated || shown.length < p.rows.length
                  ? AppColors.warning
                  : AppColors.textSecondary,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 34,
              dataRowMinHeight: 30,
              dataRowMaxHeight: 40,
              columnSpacing: 18,
              horizontalMargin: 0,
              dividerThickness: 0.6,
              columns: [
                for (final c in cols)
                  DataColumn(
                    numeric: c.money,
                    label: Text(
                      c.label,
                      style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
              rows: [
                for (final r in shown)
                  DataRow(
                    cells: [
                      for (final c in cols) DataCell(_cell(r, c)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Says exactly what is on screen versus what is in the file. `truncated` is the
  /// server's own flag — the preview is capped at `JSON_ROW_CAP` while the totals
  /// above are for the whole range, and a preview that quietly disagreed with the
  /// download would be worse than no preview.
  String _rowsSubtitle(ReportPreview p, int shownCount) {
    if (p.truncated) {
      return 'Showing $shownCount of ${p.totals.rows}. The totals above cover the whole '
          'range; download the CSV for every row.';
    }
    if (shownCount < p.rows.length) {
      return 'Showing $shownCount of ${p.rows.length}. Download the CSV for the rest.';
    }
    return 'All ${p.rows.length} row${p.rows.length == 1 ? '' : 's'} in this range. '
        'A tournament payout leaves the booking columns empty.';
  }

  /// A tournament payout is tinted so the two kinds of row are distinguishable at a
  /// glance — the flat one-table layout is deliberate (a CSV with two header blocks
  /// cannot be opened as a table by anything), so the colour does the separating.
  Widget _cell(ReportRow r, ReportColumn c) {
    final text = r.cell(c);
    final isRef = c.key == 'ref';
    return SizedBox(
      width: isRef ? 74 : null,
      child: Text(
        isRef && text.length > 8 ? text.substring(0, 8) : text,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.poppins(
          fontSize: 10.5,
          fontWeight: c.money ? FontWeight.w500 : FontWeight.w400,
          color: r.isTournament ? AppColors.accent : AppColors.textPrimary,
        ),
      ),
    );
  }

  // ── Export bar ────────────────────────────────────────────────────────────
  Widget _exportBar(ReportPreview p) {
    final file = _file;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Export ${p.totals.rows} row${p.totals.rows == 1 ? '' : 's'}',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    file == null
                        ? 'CSV, opens in Excel and Google Sheets'
                        : '${file.filename} · ${file.sizeLabel}',
                    style: GoogleFonts.poppins(
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Download',
              onPressed: _downloading ? null : () => _download(thenShare: false),
              icon: _downloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded, color: AppColors.textPrimary),
            ),
            const SizedBox(width: 2),
            ElevatedButton.icon(
              onPressed: _downloading ? null : () => _download(thenShare: true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.ios_share_rounded, size: 16),
              label: Text(
                'Share',
                style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
