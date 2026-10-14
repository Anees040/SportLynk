// Manage Admins: the super admin's screen for the admin tier. It reads two endpoints
// on mount — the admin list (`/admin/admins`) and the permission catalog
// (`/admin/permissions`) — and renders the four mandated states. A failed read of
// either half is an error with a retry, never an empty list presented as "no admins",
// because the super admin always exists.
//
// Mounted with a super-admin session; the screen itself carries no NotificationBell,
// so a non-null token is harmless here.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_manage_admins_screen.dart';

import '../screen_harness.dart';

const String kAdmins = '/admin/admins';
const String kPerms = '/admin/permissions';

Map<String, dynamic> superAdmin() => {
      'id': 's1',
      'name': 'Site Owner',
      'email': 'owner@site.com',
      'isSuperAdmin': true,
      'permissions': <String>[],
      'active': true,
      'createdAt': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> subAdmin({
  String id = 'u1',
  String name = 'Helper One',
  List<String> permissions = const ['user_management'],
  bool active = true,
}) =>
    {
      'id': id,
      'name': name,
      'email': 'helper@site.com',
      'isSuperAdmin': false,
      'permissions': permissions,
      'active': active,
      'createdAt': '2026-02-01T00:00:00Z',
    };

List<Map<String, dynamic>> catalog() => [
      {'key': 'user_management', 'label': 'User management', 'description': 'Suspend and reinstate.'},
      {'key': 'match_disputes', 'label': 'Match disputes', 'description': 'Rule disputes.'},
    ];

Future<void> pumpManage(WidgetTester tester) => pumpScreen(
      tester,
      const AdminManageAdminsScreen(),
      auth: FakeAuth(role: 'admin', id: 's1', name: 'Owner', isSuperAdmin: true),
    );

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kAdmins, {'admins': [superAdmin(), subAdmin()]});
    api.ok(kPerms, {'permissions': catalog()});
  });

  testWidgets('a spinner stands while the admins load', (tester) async {
    api.ok(kAdmins, {'admins': [superAdmin()]}, delay: const Duration(milliseconds: 300));
    await pumpManage(tester);
    expectLoading(tester);
    await settleData(tester, step: const Duration(milliseconds: 400));
    expect(find.text('SUPER ADMIN'), findsOneWidget);
  });

  testWidgets('the loaded screen shows the super admin and a sub-admin with its chips',
      (tester) async {
    await pumpManage(tester);
    await settleData(tester);

    expect(find.text('Site Owner'), findsOneWidget);
    expect(find.text('SUPER ADMIN'), findsOneWidget);
    expect(find.text('ALL PERMISSIONS'), findsOneWidget);
    expect(find.text('Helper One'), findsOneWidget);
    // The sub-admin's granted key is rendered as its catalog label, not the raw key.
    expect(find.text('User management'), findsOneWidget);
    // The add action is offered.
    expect(find.text('Add sub-admin'), findsOneWidget);
  });

  testWidgets('with no sub-admins the sub-admin section says so', (tester) async {
    api.ok(kAdmins, {'admins': [superAdmin()]});
    await pumpManage(tester);
    await settleData(tester);

    expect(find.text('No sub-admins yet'), findsOneWidget);
    // The super admin is still shown, and adding one is still offered.
    expect(find.text('SUPER ADMIN'), findsOneWidget);
    expect(find.text('Add sub-admin'), findsOneWidget);
  });

  testWidgets('a removed sub-admin is flagged and its permissions read empty',
      (tester) async {
    api.ok(kAdmins, {
      'admins': [superAdmin(), subAdmin(permissions: const [], active: false)],
    });
    await pumpManage(tester);
    await settleData(tester);

    expect(find.text('REMOVED'), findsOneWidget);
    expect(find.text('Access removed'), findsOneWidget);
  });

  testWidgets('a failed admin list shows an error with a retry, not an empty screen',
      (tester) async {
    api.fail(kAdmins, 'boom');
    await pumpManage(tester);
    await settleData(tester);

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Add sub-admin'), findsNothing); // the FAB is hidden on error
  });

  testWidgets('a failed permission catalog is also an error (the form would be empty)',
      (tester) async {
    api.fail(kPerms, 'boom');
    await pumpManage(tester);
    await settleData(tester);

    expect(find.text('Retry'), findsOneWidget);
  });
}
