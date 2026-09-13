// Financial reports preview the same server-side walk that produces the CSV. The
// tests therefore use the preview envelope and assert the visible totals rather than
// inventing a second calculation in Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_reports_screen.dart';

import '../screen_harness.dart';

const String kVenues = '/owner/venues';
const String kReport = '/owner/reports/financial';
const String kPlatformReport = '/admin/reports/platform';

Map<String, dynamic> report({int rows = 1}) => {
  'range': {'from': '2026-09-01', 'to': '2026-09-13', 'days': 13},
  'columns': [
    {'key': 'ref', 'label': 'Reference', 'money': false},
    {'key': 'gross', 'label': 'Gross', 'money': true},
    {'key': 'net', 'label': 'Net', 'money': true},
  ],
  'totals': {
    'rows': rows,
    'bookings': rows,
    'tournaments': 0,
    'gross': 3000,
    'net': rows == 0 ? 0 : 2500,
  },
  'rows': rows == 0
      ? const []
      : [
          {'kind': 'booking', 'ref': 'bk-1', 'gross': 3000, 'net': 2500},
        ],
  'truncated': false,
};

Future<void> settleReport(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<RouteLog> pumpReport(
  WidgetTester tester,
  FakeApi api, {
  bool platform = false,
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    OwnerReportsScreen(platform: platform),
    auth: FakeAuth(
      role: platform ? 'admin' : 'owner',
      id: 'o-1',
      name: 'Owner',
      token: 'owner-token',
    ),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi()..install();
    api.ok(kVenues, [
      {'id': 'v-1', 'name': 'Green Turf Arena'},
    ]);
    api.ok(kReport, report());
    api.ok(kPlatformReport, report());
  });

  group('the preview', () {
    testWidgets('shows a spinner while the financial preview is in flight', (
      tester,
    ) async {
      api.ok(kReport, report(), delay: const Duration(milliseconds: 300));
      await pumpReport(tester, api);
      expectLoading(tester);

      await settleReport(tester);
      expect(find.text('Financial report'), findsOneWidget);
      expect(find.text('PKR 2,500'), findsOneWidget);
    });

    testWidgets('renders totals and a preview row', (tester) async {
      await pumpReport(tester, api);
      await settleReport(tester);

      expect(find.text('Financial report'), findsOneWidget);
      expect(find.text('PKR 2,500'), findsOneWidget);
      expect(find.text('bk-1'), findsOneWidget);
      expect(find.text('Export 1 row'), findsOneWidget);
    });

    testWidgets('an empty range explains that there is nothing to export', (
      tester,
    ) async {
      api.ok(kReport, report(rows: 0));
      await pumpReport(tester, api);
      await settleReport(tester);

      expect(
        find.text('No bookings or tournament payouts in this range.'),
        findsOneWidget,
      );
      expect(find.text('Export 0 row'), findsNothing);
    });

    testWidgets('a failed preview surfaces the service message', (
      tester,
    ) async {
      api.fail(kReport, 'Report service unavailable.');
      await pumpReport(tester, api);
      await settleReport(tester);

      expect(find.text('Report service unavailable.'), findsOneWidget);
    });

    testWidgets('the platform variant uses its own endpoint and title', (
      tester,
    ) async {
      await pumpReport(tester, api, platform: true);
      await settleReport(tester);

      expect(find.text('Platform report'), findsOneWidget);
      expect(api.countTo(kPlatformReport), 1);
      expect(
        api.countTo(kVenues),
        0,
        reason: 'platform reports do not load the owner venue picker',
      );
    });
  });

  group('reach and scale', () {
    testWidgets('the refresh action runs the preview again', (tester) async {
      await pumpReport(tester, api);
      await settleReport(tester);
      expect(api.countTo(kReport), 1);

      await tester.tap(find.byTooltip('Refresh'));
      await settleReport(tester);

      expect(api.countTo(kReport), 2);
    });

    testWidgets('a doubled text scale keeps the totals readable', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpReport(tester, api, textScale: 2.0);
      await settleReport(tester);

      expect(find.text('PKR 2,500'), findsOneWidget);
    });
  });
}
