// AuthService: the request bodies the three registration and reset routes send, and
// the token that outlives the session.
//
// Two things are worth pinning here. The first is that optional fields are omitted
// rather than sent as null: `email` and `avatarUrl` are nullable columns, and a
// literal null in the JSON is not the same request as an absent key once the server
// starts validating shapes. The second is [AuthService.getMe], the one method that
// parses rather than forwards — it must answer null for a failed request instead of
// throwing, because its caller is the startup path that decides whether to show the
// login screen.
//
// The token helpers go through `SharedPreferences`, whose plugin has no
// implementation on the test VM; `setMockInitialValues` installs the in-memory one
// the package ships for exactly this purpose.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportlynk/services/auth_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late AuthService service;

  setUp(() {
    api = FakeApi();
    service = AuthService();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(resetApiClient);

  group('registerPlayer', () {
    test('sends the four required fields to the player route', () async {
      api.ok(null);
      await api.run(() => service.registerPlayer(
            name: 'Ayaan',
            phone: '+923001234567',
            password: 'secret123',
            firebaseUid: 'uid-1',
          ));
      expect(api.endpoint(), '/auth/register/player');
      expect(api.method(), 'POST');
      expect(api.body(), {
        'name': 'Ayaan',
        'phone': '+923001234567',
        'password': 'secret123',
        'firebaseUid': 'uid-1',
      });
    });

    test('omits an absent email rather than sending null', () async {
      api.ok(null);
      await api.run(() => service.registerPlayer(
            name: 'Ayaan',
            phone: '+923001234567',
            password: 'secret123',
            firebaseUid: 'uid-1',
          ));
      expect(api.body().containsKey('email'), isFalse);
      expect(api.body().containsKey('avatarUrl'), isFalse);
    });

    test('omits a blank email, which an untouched text field produces', () async {
      api.ok(null);
      await api.run(() => service.registerPlayer(
            name: 'Ayaan',
            phone: '+923001234567',
            password: 'secret123',
            firebaseUid: 'uid-1',
            email: '',
          ));
      expect(api.body().containsKey('email'), isFalse);
    });

    test('carries an email and an avatar when both are given', () async {
      api.ok(null);
      await api.run(() => service.registerPlayer(
            name: 'Ayaan',
            phone: '+923001234567',
            password: 'secret123',
            firebaseUid: 'uid-1',
            email: 'ayaan@example.com',
            avatarUrl: 'https://cdn/a.png',
          ));
      expect(api.body()['email'], 'ayaan@example.com');
      expect(api.body()['avatarUrl'], 'https://cdn/a.png');
    });

    test('returns the failure envelope untouched for the form to display', () async {
      api.fail('Phone already registered', status: 409);
      final r = await api.run(() => service.registerPlayer(
            name: 'Ayaan',
            phone: '+923001234567',
            password: 'secret123',
            firebaseUid: 'uid-1',
          ));
      expect(r['success'], isFalse);
      expect(r['message'], 'Phone already registered');
      expect(r['statusCode'], 409);
    });
  });

  group('the other credential routes', () {
    test('registerOwner forwards the whole draft to the owner route', () async {
      api.ok(null);
      await api.run(() => service.registerOwner({
            'name': 'Rai Sports',
            'phone': '+923009999999',
            'password': 'secret123',
            'firebaseUid': 'uid-2',
            'cnic': '35202-1234567-1',
          }));
      expect(api.endpoint(), '/auth/register/owner');
      expect(api.body()['cnic'], '35202-1234567-1');
    });

    test('login sends one identifier field, not a phone and an email', () async {
      api.ok(null);
      await api.run(() => service.login(identifier: 'ayaan@example.com', password: 'x'));
      expect(api.endpoint(), '/auth/login');
      expect(api.body(), {'identifier': 'ayaan@example.com', 'password': 'x'});
    });

    test('forgotPasswordSendOtp sends only the phone', () async {
      api.ok(null);
      await api.run(() => service.forgotPasswordSendOtp('+923001234567'));
      expect(api.endpoint(), '/auth/forgot-password/send-otp');
      expect(api.body(), {'phone': '+923001234567'});
    });

    test('forgotPasswordReset proves the OTP with the Firebase uid', () async {
      api.ok(null);
      await api.run(() => service.forgotPasswordReset(
            phone: '+923001234567',
            newPassword: 'newsecret',
            firebaseUid: 'uid-3',
          ));
      expect(api.endpoint(), '/auth/forgot-password/reset');
      expect(api.body(), {
        'phone': '+923001234567',
        'newPassword': 'newsecret',
        'firebaseUid': 'uid-3',
      });
    });
  });

  group('the stored token', () {
    test('a saved token is readable again', () async {
      await service.saveToken('JWT-1');
      expect(await service.getToken(), 'JWT-1');
    });

    test('nothing saved reads as null, which the startup path treats as logged out', () async {
      expect(await service.getToken(), isNull);
    });

    test('clearing removes it rather than storing an empty string', () async {
      await service.saveToken('JWT-1');
      await service.clearToken();
      expect(await service.getToken(), isNull);
    });

    test('saving again replaces the previous token', () async {
      await service.saveToken('JWT-1');
      await service.saveToken('JWT-2');
      expect(await service.getToken(), 'JWT-2');
    });
  });

  group('getMe', () {
    test('parses the user out of the nested data block', () async {
      api.ok({
        'user': {
          'id': 'u1',
          'name': 'Ayaan',
          'phone': '+923001234567',
          'role': 'player',
        },
      });
      final user = await api.run(() => service.getMe('JWT'));
      expect(api.endpoint(), '/auth/me');
      expect(api.token(), 'JWT');
      expect(user!.id, 'u1');
      expect(user.name, 'Ayaan');
      expect(user.role, 'player');
    });

    test('answers null on a failure instead of throwing at the startup path', () async {
      api.fail('Your session has expired. Please log in again.', status: 401);
      expect(await api.run(() => service.getMe('STALE')), isNull);
    });

    test('answers null when the server is unreachable', () async {
      api.offline();
      expect(await api.run(() => service.getMe('JWT')), isNull);
    });

    test('answers null when the envelope carries no data block', () async {
      api.json({'success': true});
      expect(await api.run(() => service.getMe('JWT')), isNull);
    });
  });
}
