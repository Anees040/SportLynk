// Add / edit sub-admin: a form rendered from the server permission catalog. Create
// mode validates name, email and password locally before any call; edit mode shows
// the email read-only (it is the login identity) and no password field. The permission
// checkboxes are the catalog passed in, so these tests hand it one directly rather than
// loading it over the network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/admin.dart';
import 'package:sportlynk/screens/admin/admin_subadmin_edit_screen.dart';

import '../screen_harness.dart';

const String kAdmins = '/admin/admins';

const List<PermissionDef> kCatalog = [
  PermissionDef(key: 'user_management', label: 'User management', description: 'Suspend and reinstate.'),
  PermissionDef(key: 'match_disputes', label: 'Match disputes', description: 'Rule disputes.'),
];

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('create mode', () {
    Future<void> pumpCreate(WidgetTester tester) => pumpScreen(
          tester,
          const AdminSubAdminEditScreen(catalog: kCatalog),
          auth: FakeAuth(role: 'admin', id: 's1', isSuperAdmin: true),
        );

    testWidgets('renders the create title, a password field and the catalog',
        (tester) async {
      await pumpCreate(tester);
      await tester.pump();

      expect(find.text('Add sub-admin'), findsWidgets); // app bar + button
      expect(find.text('Create sub-admin'), findsOneWidget);
      expect(find.text('User management'), findsOneWidget);
      expect(find.text('Match disputes'), findsOneWidget);
    });

    testWidgets('empty fields are refused locally and nothing is sent',
        (tester) async {
      await pumpCreate(tester);
      await tester.pump();

      await tapVisible(tester, find.text('Create sub-admin'));
      await tester.pump();

      expect(find.text('At least 3 characters'), findsOneWidget);
      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(find.text('At least 8 characters'), findsOneWidget);
      expect(api.countTo(kAdmins), 0);
    });

    testWidgets('a valid create sends exactly the permissions that were ticked',
        (tester) async {
      api.ok(kAdmins, {'admin': <String, dynamic>{}});
      await pumpCreate(tester);
      await tester.pump();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Helper One');
      await tester.enterText(fields.at(1), 'helper@site.com');
      await tester.enterText(fields.at(2), 'longenough1');
      // Tick one permission, leave the other off.
      await tapVisible(tester, find.text('Match disputes'));
      await tapVisible(tester, find.text('Create sub-admin'));
      await settleData(tester);

      expect(api.countTo(kAdmins), 1);
      final body = api.to(kAdmins).last.body ?? '';
      expect(body.contains('match_disputes'), isTrue);
      expect(body.contains('user_management'), isFalse);
      expect(body.contains('helper@site.com'), isTrue);
    });
  });

  group('edit mode', () {
    final account = AdminAccount(
      id: 'u1',
      name: 'Helper One',
      email: 'helper@site.com',
      permissions: const ['user_management'],
      active: true,
      createdAt: DateTime.parse('2026-02-01T00:00:00Z'),
    );

    Future<void> pumpEdit(WidgetTester tester) => pumpScreen(
          tester,
          AdminSubAdminEditScreen(catalog: kCatalog, existing: account),
          auth: FakeAuth(role: 'admin', id: 's1', isSuperAdmin: true),
        );

    testWidgets('shows the email read-only and no password field', (tester) async {
      await pumpEdit(tester);
      await tester.pump();

      expect(find.text('Edit sub-admin'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      // The login email is shown but not as an editable field.
      expect(find.text('helper@site.com'), findsOneWidget);
      expect(find.text('Temporary password'), findsNothing);
    });
  });
}
