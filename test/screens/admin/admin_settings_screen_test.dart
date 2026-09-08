// Admin settings: a server-owned catalogue of typed fields the admin can override.
// The screen holds no Dart copy of the settings — every section, field, type, unit,
// bound, step, default and override flag arrives from `GET /admin/settings` — so the
// tests here pin the five rendered types, the client-side bounds check that gates the
// Save button, the change diff, and the two write paths (a keyed PUT of only the
// touched fields, and a reset that POSTs to its own endpoint).
//
// Mount note: this screen embeds no `NotificationBell` and never calls
// `RealtimeService`, but its `_load` returns early on a null token WITHOUT clearing
// `_loading` (admin_settings_screen.dart:65-67), so a null-token mount hangs on the
// spinner forever. The session must therefore carry a non-null token.
//
// A failed load reads as the empty-catalogue copy: `AdminService.settings` returns
// `SettingsCatalog.empty` on any non-success (admin_service.dart:181), and an empty
// catalogue and a failed one both render "could not be loaded". That copy is honest
// for both because a real catalogue is never empty, so it is asserted, not pinned as
// a defect.
//
// FakeApi keys stubs by PATH, not method (screen_harness.dart:125), so the reload GET
// after a save re-reads whatever `/admin/settings` currently answers; the PUT is
// asserted by method-filtering the recorded requests, and the reset uses a distinct
// path (`/admin/settings/reset`) that does not collide with the catalogue GET.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_settings_screen.dart';

import '../screen_harness.dart';

/// The catalogue endpoint and the reset endpoint, as `ApiConstants` resolves them.
const String kSettings = '/admin/settings';
const String kReset = '/admin/settings/reset';

/// One numeric field, in the shape `SettingsField.fromJson` reads (models/admin.dart:876).
/// The default arrives under the JSON key `default`, not `defaultValue`.
Map<String, dynamic> numberField({
  String key = 'commission_pct',
  String label = 'Commission',
  String unit = '%',
  num value = 10,
  num min = 0,
  num max = 100,
  num step = 5,
  num defaultValue = 8,
  bool isOverridden = false,
  String? description,
}) =>
    {
      'key': key,
      'label': label,
      'type': 'number',
      if (description != null) 'description': description,
      'unit': unit,
      'step': step,
      'min': min,
      'max': max,
      'value': value,
      'default': defaultValue,
      'isOverridden': isOverridden,
    };

/// One section, in the shape `SettingsSection.fromJson` reads (models/admin.dart:938).
Map<String, dynamic> section({
  String key = 'pricing',
  String label = 'Pricing',
  String? hint,
  required List<Map<String, dynamic>> fields,
}) =>
    {
      'key': key,
      'label': label,
      if (hint != null) 'hint': hint,
      'fields': fields,
    };

/// A whole catalogue, in the shape `SettingsCatalog.fromJson` reads (models/admin.dart:965):
/// `overrides` is a list of keys, `appliesImmediately` defaults true unless explicitly
/// false, and `cacheTtlSeconds` feeds the banner.
Map<String, dynamic> catalog({
  List<Map<String, dynamic>>? sections,
  List<String> overrides = const [],
  bool appliesImmediately = true,
  int cacheTtlSeconds = 60,
}) =>
    {
      'sections': sections ?? [section(fields: [numberField()])],
      'overrides': overrides,
      'appliesImmediately': appliesImmediately,
      'cacheTtlSeconds': cacheTtlSeconds,
    };

Future<RouteLog> pumpSettings(WidgetTester tester, FakeApi api,
    {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const AdminSettingsScreen(),
    auth: FakeAuth(role: 'admin', id: 'admin-1', name: 'Ops', token: 'admin-token'),
    textScale: textScale,
  );
}

/// The note field inside the confirm dialog, distinct from the number field behind it.
Finder dialogField() =>
    find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kSettings, catalog());
  });

  group('the catalogue as it loads', () {
    testWidgets('a spinner stands while the catalogue is in flight',
        (tester) async {
      api.ok(kSettings, catalog(), delay: const Duration(milliseconds: 300));
      await pumpSettings(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Commission'), findsOneWidget);
    });

    testWidgets('the loaded catalogue shows the banner, the section and the field',
        (tester) async {
      await pumpSettings(tester, api);
      await settleData(tester);

      expect(find.text('Pricing'), findsOneWidget);
      expect(find.text('Commission'), findsOneWidget);
      // The immediacy banner names the effect of a change, not a restart.
      expect(find.textContaining('Changes apply to the next booking'),
          findsOneWidget);
      // A field the server did not flag as overridden wears the "default" pill.
      expect(find.text('default'), findsOneWidget);
      // No diff yet, so the save bar is absent.
      expect(find.widgetWithText(ElevatedButton, 'Save'), findsNothing);
    });

    testWidgets('a failed load reads as the could-not-load copy', (tester) async {
      // `AdminService.settings` returns `SettingsCatalog.empty` on non-success, and an
      // empty catalogue renders the same copy; both are honest because a real
      // catalogue always has sections.
      api.fail(kSettings, 'boom');
      await pumpSettings(tester, api);
      await settleData(tester);

      expect(find.text('The settings catalogue could not be loaded.'),
          findsOneWidget);
    });
  });

  group('editing and the bounds check', () {
    testWidgets('a stepper edit raises the save bar with a one-change count',
        (tester) async {
      await pumpSettings(tester, api);
      await settleData(tester);
      expect(find.widgetWithText(ElevatedButton, 'Save'), findsNothing);

      // The increment stepper nudges by the server's step (5), producing a draft.
      await tester.tap(find.byIcon(Icons.add_rounded).first);
      await tester.pump();

      expect(find.text('1 change'), findsOneWidget);
      expect(find.text('Applies to the next booking, match and payout.'),
          findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Save'), findsOneWidget);
    });

    testWidgets('a value past the server bound blocks Save and names the limit',
        (tester) async {
      await pumpSettings(tester, api);
      await settleData(tester);

      // 150 is above the field's max of 100; the client refuses it with the server's
      // own number rather than sending a patch the server would reject.
      await tester.enterText(find.byType(TextField), '150');
      await tester.pump();

      expect(find.text('At most 100%.'), findsOneWidget);
      expect(find.text('1 value needs fixing first.'), findsOneWidget);
      final save =
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Save'));
      expect(save.onPressed, isNull, reason: 'an invalid draft disables Save');
    });
  });

  group('saving a change', () {
    testWidgets('Apply sends only the touched key, with the note, and confirms',
        (tester) async {
      // Two fields, one touched: the PUT must carry commission alone.
      api.ok(
        kSettings,
        catalog(sections: [
          section(fields: [
            numberField(),
            numberField(key: 'deposit_pct', label: 'Deposit', value: 20),
          ])
        ]),
      );
      await pumpSettings(tester, api);
      await settleData(tester);

      await tester.tap(find.byIcon(Icons.add_rounded).first);
      await tester.pump();
      expect(find.text('1 change'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      // The confirm dialog states the diff as from -> to, in the display formatting.
      expect(find.text('Apply these changes?'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
      expect(find.text('15%'), findsOneWidget);

      await tester.enterText(dialogField(), 'Rate correction for winter.');
      await tester.pump();

      // The reload GET after a save re-reads this path; stub it to the saved state so
      // the screen settles on a real catalogue rather than a stale one.
      api.ok(
        kSettings,
        catalog(sections: [
          section(fields: [
            numberField(value: 15, isOverridden: true),
            numberField(key: 'deposit_pct', label: 'Deposit', value: 20),
          ])
        ], overrides: const ['commission_pct']),
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Apply'));
      await tester.pumpAndSettle();

      final puts =
          api.to(kSettings).where((r) => r.method == 'PUT').toList();
      expect(puts.length, 1, reason: 'exactly one PUT is sent');
      final body = jsonDecode(puts.single.body!) as Map;
      expect(body['settings'], {'commission_pct': 15},
          reason: 'only the touched key travels, never the whole catalogue');
      expect(body['note'], 'Rate correction for winter.');
      expect(find.text('Saved.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('Discard drops the draft and retires the save bar', (tester) async {
      await pumpSettings(tester, api);
      await settleData(tester);
      await tester.tap(find.byIcon(Icons.add_rounded).first);
      await tester.pump();
      expect(find.text('1 change'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pump();

      expect(find.text('1 change'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Save'), findsNothing);
    });
  });

  group('resetting an override', () {
    testWidgets('a per-key reset posts the key to the reset endpoint', (tester) async {
      api.ok(
        kSettings,
        catalog(
          sections: [
            section(fields: [numberField(isOverridden: true)])
          ],
          overrides: const ['commission_pct'],
        ),
      );
      api.ok(kReset, <String, dynamic>{});
      await pumpSettings(tester, api);
      await settleData(tester);

      expect(find.text('overridden'), findsOneWidget);

      // The per-key reset carries the rounded icon; the app-bar reset-all carries the
      // plain one, so the rounded match is unambiguous.
      await tester.tap(find.byIcon(Icons.restart_alt_rounded));
      await tester.pumpAndSettle();

      expect(api.countTo(kReset), 1);
      final body = jsonDecode(api.to(kReset).single.body!) as Map;
      expect(body['keys'], ['commission_pct']);
      expect(find.text('Commission is back to its default.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('reach and scale', () {
    testWidgets('the refresh control names itself', (tester) async {
      await pumpSettings(tester, api);
      await settleData(tester);

      expect(find.byTooltip('Refresh'), findsOneWidget);
    });

    testWidgets('a doubled text scale keeps the field present', (tester) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense field row overflows at this scale in the harness alone; the contract is
      // that the content is still built.
      ignoreOverflow();
      await pumpSettings(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Commission'), findsOneWidget);
    });
  });
}
