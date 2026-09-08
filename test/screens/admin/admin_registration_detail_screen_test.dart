// Admin registration detail: the case file for one owner application, with an
// approve/reject action bar shown only while the application is pending. The screen
// takes the registration as a constructor map and renders it directly — there is no
// load and no loading state — and it talks to the API through a raw `http.patch`
// rather than a service, so the two write paths are asserted on the intercepted
// request itself.
//
// Two behaviours are pinned as defects rather than fixed (see the findings list):
// the reject dialog silently refuses a reason under five characters with no message,
// and the whole screen bypasses the service layer for a bare `http.patch`.
//
// The approve and reject success paths call `Navigator.pop`. Popping the root route
// of a `MaterialApp` is not a state the screen is built for, so those two tests mount
// the screen over a host route (`_Host`): the pop becomes an ordinary one and the
// host reappearing proves the screen was dismissed. `SnackbarUtil` is not used here —
// `_showResult` posts to the app-level `ScaffoldMessenger` above the Navigator, so its
// snackbar survives the pop and stays findable.
//
// Document URLs and `ground_photos` are left absent in the fixture on purpose: a
// present http URL renders an `Image.network`, which cannot load under a widget test,
// so `_docThumbnail` is exercised on its "Not uploaded" branch instead.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_registration_detail_screen.dart';

import '../screen_harness.dart';

/// The two per-registration write paths, matched by suffix against the recorded
/// request (whose path carries the `/api` prefix the base URL adds).
const String kApprove = '/admin/registrations/reg-1/approve';
const String kReject = '/admin/registrations/reg-1/reject';

/// One registration, in the shape the screen reads its fields from. Document URLs and
/// photos are omitted so no `Image.network` is built.
Map<String, dynamic> reg({
  String id = 'reg-1',
  String status = 'pending',
  String ownerName = 'Bilal Traders',
  String groundName = 'Green Turf Arena',
  String city = 'Lahore',
  dynamic price = 2500,
  String? rejectionReason,
}) =>
    {
      'id': id,
      'verification_status': status,
      'owner_name': ownerName,
      'owner_phone': '+923001234567',
      'owner_email': 'bilal@example.com',
      'cnic_number': '35201-1234567-1',
      'ground_name': groundName,
      'city': city,
      'full_address': 'Main Boulevard, Gulberg',
      'sport_types': const ['Football', 'Cricket'],
      'ground_type': 'Outdoor',
      'price_per_hour': price,
      'operating_hours_from': '06:00',
      'operating_hours_to': '23:00',
      'rejection_reason': ?rejectionReason,
      'created_at': '2026-09-01T09:00:00Z',
    };

final FakeAuth _admin =
    FakeAuth(role: 'admin', id: 'admin-1', name: 'Ops', token: 'admin-token');

/// Mounts the screen as the root route. Correct for every path that does not pop.
Future<RouteLog> pumpReg(
  WidgetTester tester,
  FakeApi api,
  Map<String, dynamic> registration, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    AdminRegistrationDetailScreen(registration: registration),
    auth: _admin,
    textScale: textScale,
  );
}

/// Mounts the screen over a host route, so its success-path `Navigator.pop` is an
/// ordinary pop back to the host rather than a removal of the root.
Future<RouteLog> pumpRegHosted(
  WidgetTester tester,
  FakeApi api,
  Map<String, dynamic> registration,
) async {
  final log = await pumpScreen(
    tester,
    _Host(child: AdminRegistrationDetailScreen(registration: registration)),
    auth: _admin,
  );
  // Run the post-frame push and settle the transition; this screen has no loading
  // spinner, so a full settle is safe.
  await tester.pumpAndSettle();
  return log;
}

/// The single reason field inside the reject dialog.
Finder dialogField() =>
    find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

/// The PATCHes recorded against [path], method-filtered off any other traffic.
Iterable<RecordedRequest> patches(FakeApi api, String path) =>
    api.to(path).where((r) => r.method == 'PATCH');

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('rendering the case file', () {
    testWidgets('a pending application shows its sections and the action bar',
        (tester) async {
      await pumpReg(tester, api, reg());
      await tester.pump();

      expect(find.text('Registration Review'), findsOneWidget);
      expect(find.text('Pending Review'), findsOneWidget);
      expect(find.text('Owner Information'), findsOneWidget);
      expect(find.text('Bilal Traders'), findsOneWidget);
      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('Lahore'), findsOneWidget);
      expect(find.text('PKR 2500'), findsOneWidget);
      // The action bar is present only while pending.
      expect(find.widgetWithText(ElevatedButton, 'Approve & Create Venue'),
          findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Reject'), findsOneWidget);
    });

    testWidgets('an absent document reads as not uploaded, never a broken image',
        (tester) async {
      await pumpReg(tester, api, reg());
      await tester.pump();

      // CNIC front, CNIC back and the selfie are all absent, so each thumbnail shows
      // its placeholder rather than attempting a network image.
      expect(find.text('Not uploaded'), findsNWidgets(3));
    });

    testWidgets('an approved application drops the action bar', (tester) async {
      await pumpReg(tester, api, reg(status: 'approved'));
      await tester.pump();

      expect(find.textContaining('Venue is live'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Approve & Create Venue'),
          findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNothing);
    });

    testWidgets('a rejected application shows its reason and drops the action bar',
        (tester) async {
      await pumpReg(
        tester,
        api,
        reg(status: 'rejected', rejectionReason: 'CNIC photos are blurry.'),
      );
      await tester.pump();

      expect(find.text('Rejected'), findsOneWidget);
      expect(find.text('Reason: CNIC photos are blurry.'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Approve & Create Venue'),
          findsNothing);
    });
  });

  group('approving', () {
    testWidgets('a successful approve patches, confirms and dismisses the screen',
        (tester) async {
      api.on(
        kApprove,
        FakeResponse(200, jsonEncode({'success': true, 'data': {'venueId': 'v-1'}})),
      );
      await pumpRegHosted(tester, api, reg());

      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Approve & Create Venue'));
      await tester.pumpAndSettle();

      expect(patches(api, kApprove).length, 1, reason: 'exactly one approve PATCH');
      expect(find.text('Owner approved! Venue created successfully.'),
          findsOneWidget);
      expect(find.text('host'), findsOneWidget,
          reason: 'the screen popped back to the host route');

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('a refused approve surfaces the server reason and stays put',
        (tester) async {
      api.on(
        kApprove,
        FakeResponse(
            200,
            jsonEncode(
                {'success': false, 'message': 'This CNIC is already registered.'})),
      );
      await pumpReg(tester, api, reg());
      await tester.pump();

      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Approve & Create Venue'));
      await tester.pumpAndSettle();

      expect(patches(api, kApprove).length, 1);
      expect(find.text('This CNIC is already registered.'), findsOneWidget);
      // No pop on failure, so the action bar is still there to try again.
      expect(find.widgetWithText(ElevatedButton, 'Approve & Create Venue'),
          findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('rejecting', () {
    testWidgets('a reason under five characters is silently refused, costing nothing',
        (tester) async {
      // Defect, pinned rather than fixed: the dialog's Reject button returns without a
      // message when the reason is too short (admin_registration_detail_screen.dart:109),
      // so the admin gets no feedback at all.
      await pumpReg(tester, api, reg());
      await tester.pump();

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Reject'));
      await tester.pumpAndSettle();
      expect(find.text('Reject Registration'), findsOneWidget);

      await tester.enterText(dialogField(), 'no');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Reject'));
      await tester.pumpAndSettle();

      // The dialog is still open and nothing was sent.
      expect(find.text('Reject Registration'), findsOneWidget);
      expect(patches(api, kReject).length, 0);
    });

    testWidgets('a reasoned reject patches the reason, confirms and dismisses',
        (tester) async {
      api.on(kReject, FakeResponse(200, jsonEncode({'success': true})));
      await pumpRegHosted(tester, api, reg());

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Reject'));
      await tester.pumpAndSettle();

      await tester.enterText(
          dialogField(), 'CNIC photos are blurry, please resubmit.');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Reject'));
      await tester.pumpAndSettle();

      expect(patches(api, kReject).length, 1);
      final body = jsonDecode(patches(api, kReject).single.body!) as Map;
      expect(body['reason'], 'CNIC photos are blurry, please resubmit.');
      expect(find.text('Registration rejected.'), findsOneWidget);
      expect(find.text('host'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('scale', () {
    testWidgets('a doubled text scale keeps the owner name present', (tester) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense row overflows at this scale in the harness alone; the contract is that
      // the content is still built.
      ignoreOverflow();
      await pumpReg(tester, api, reg(), textScale: 2.0);
      await tester.pump();

      expect(find.text('Bilal Traders'), findsOneWidget);
    });
  });
}

/// A base route beneath the screen under test. The approve and reject paths end in
/// `Navigator.pop`, and popping the root route of a `MaterialApp` is not a state the
/// screen is built for; a host route makes that pop an ordinary one and lets a test
/// confirm the screen was dismissed by the host reappearing.
class _Host extends StatefulWidget {
  const _Host({required this.child});

  final Widget child;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => widget.child));
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('host')));
}
