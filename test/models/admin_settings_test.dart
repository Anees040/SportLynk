// Admin user-suspension and platform-settings model tests.
//
// A suspension unwinds bookings and refunds money, so the receipt is the subject
// here: the cascade must report what it deliberately did NOT touch as plainly as
// what it did, because "suspended" alone hides a committed match left standing on
// a booking and an owner's confirmed nights left for a human to decide.
//
// The settings half has one rule: there is no Dart copy of the catalogue. Label,
// type, bounds, step and unit all arrive from `utils/settingsCatalog.js`, so a
// field added on the server appears with no app release and the form can never
// offer a value the server would reject. Every assertion below reads the shape
// out of the payload rather than naming a known key.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/admin.dart';

void main() {
  group('AdminUserRow', () {
    test('the frozen balance is carried beside the spendable one', () {
      final u = AdminUserRow.fromJson({
        'id': 'u1',
        'name': 'Ali Raza',
        'role': 'player',
        'phone': '+923001234567',
        'counts': {'bookings': '14', 'venues': 0},
        'wallet': {'balance': '2500.00', 'frozen': '480.00'},
      });
      expect(u.bookings, 14);
      expect(u.venues, 0);
      expect(u.walletBalance, 2500.0);
      expect(u.walletFrozen, 480.0,
          reason: 'suspending an account with frozen funds refunds them');
    });

    test('a suspension carries who did it, when, and why', () {
      final u = AdminUserRow.fromJson({
        'id': 'u1',
        'suspended': true,
        'suspendedAt': '2026-09-01T10:00:00Z',
        'suspendedReason': 'repeated no-shows',
        'suspendedByName': 'Admin',
      });
      expect(u.suspended, isTrue);
      expect(u.suspendedReason, 'repeated no-shows');
      expect(u.suspendedByName, 'Admin');
      expect(u.suspendedAt!.isUtc, isTrue);
    });

    test('suspended requires a literal true, since it gates a destructive screen', () {
      expect(AdminUserRow.fromJson({'suspended': 'true'}).suspended, isFalse);
      expect(AdminUserRow.fromJson({'suspended': 1}).suspended, isFalse);
    });

    test('an active account carries no suspension fields at all', () {
      final u = AdminUserRow.fromJson({'id': 'u1'});
      expect(u.suspended, isFalse);
      expect(u.suspendedAt, isNull);
      expect(u.suspendedReason, isNull);
      expect(u.name, 'Unknown');
      expect(u.role, 'player');
      expect(u.walletBalance, 0);
    });
  });

  group('the cascade rows', () {
    test('a cancelled booking reports its refund and its penalty separately', () {
      final b = CascadeBooking.fromJson({
        'bookingId': 'b1',
        'venueName': 'F-11 Arena',
        'refunded': '2400.00',
        'penalty': '480.00',
        'late': true,
      });
      expect(b.refunded, 2400.0);
      expect(b.penalty, 480.0);
      expect(b.late, isTrue);
    });

    test('a skipped booking always names the reason it was left standing', () {
      final s = CascadeSkip.fromJson({
        'bookingId': 'b2',
        'venueName': 'G-9 Ground',
        'slotDate': '2026-09-10T00:00:00.000Z',
        'reason': 'a committed match sits on it',
      });
      expect(s.reason, 'a committed match sits on it');
      expect(s.slotDate, '2026-09-10');
    });

    test('a skip with no reason still says something rather than nothing', () {
      expect(CascadeSkip.fromJson({'bookingId': 'b2'}).reason,
          'could not be cancelled');
    });

    test('a tournament row carries its name and, when skipped, its reason', () {
      final t = CascadeTournament.fromJson({
        'tournamentId': 'tr1',
        'name': 'Ramadan Cup',
        'reason': 'already in the knockout stage',
      });
      expect(t.name, 'Ramadan Cup');
      expect(t.reason, 'already in the knockout stage');
      expect(CascadeTournament.fromJson({'tournamentId': 'tr2'}).reason, isNull);
    });

    test('a deactivated venue is just an id and a name', () {
      final v = CascadeVenue.fromJson({'id': 'v1', 'name': 'F-11 Arena'});
      expect(v.id, 'v1');
      expect(v.name, 'F-11 Arena');
      expect(CascadeVenue.fromJson({}).name, isNull);
    });
  });

  group('SuspensionCascade', () {
    test('what was left alone is reported as fully as what was unwound', () {
      final c = SuspensionCascade.fromJson({
        'challengesExpired': ['c1', 'c2'],
        'bookingsCancelled': [
          {'bookingId': 'b1', 'refunded': '2400.00'},
        ],
        'bookingsLeftAlone': [
          {'bookingId': 'b2', 'reason': 'a committed match sits on it'},
        ],
        'tournamentsWithdrawn': [
          {'tournamentId': 'tr1', 'name': 'Ramadan Cup'},
        ],
        'tournamentsLeftAlone': [
          {'tournamentId': 'tr2', 'reason': 'knockout stage'},
        ],
        'venuesDeactivated': [
          {'id': 'v1', 'name': 'F-11 Arena'},
        ],
        'requestsRejected': '3',
        'confirmedBookingsLeftAlone': '2',
        'refundedTotal': '2400.00',
      });
      expect(c.challengesExpired, ['c1', 'c2']);
      expect(c.bookingsCancelled.single.refunded, 2400.0);
      expect(c.bookingsLeftAlone.single.reason, contains('committed match'));
      expect(c.tournamentsWithdrawn.single.name, 'Ramadan Cup');
      expect(c.tournamentsLeftAlone.single.reason, 'knockout stage');
      expect(c.venuesDeactivated.single.name, 'F-11 Arena');
      expect(c.requestsRejected, 3);
      expect(c.confirmedBookingsLeftAlone, 2,
          reason: 'an owner\'s confirmed nights are counted, never cancelled');
      expect(c.refundedTotal, 2400.0);
      expect(c.isEmpty, isFalse);
    });

    test('a suspension that unwound nothing says so, so no empty receipt is drawn', () {
      expect(const SuspensionCascade().isEmpty, isTrue);
      expect(SuspensionCascade.fromJson({}).isEmpty, isTrue);
      expect(SuspensionCascade.fromJson({'refundedTotal': '0'}).isEmpty, isTrue,
          reason: 'a zero refund is not an action, only the absence of one');
    });

    test('a single skipped booking is enough to make the receipt worth showing', () {
      final c = SuspensionCascade.fromJson({
        'bookingsLeftAlone': [
          {'bookingId': 'b2', 'reason': 'a committed match sits on it'},
        ],
      });
      expect(c.isEmpty, isFalse);
    });

    test('non-map entries inside a cascade list are skipped rather than fatal', () {
      final c = SuspensionCascade.fromJson({
        'bookingsCancelled': [
          {'bookingId': 'b1'},
          'garbage',
          null,
        ],
      });
      expect(c.bookingsCancelled.length, 1);
    });

    test('a cascade block that is not a list throws, which is a known fragility', () {
      expect(
        () => SuspensionCascade.fromJson({'venuesDeactivated': 'none'}),
        throwsA(isA<TypeError>()),
        reason: 'the private _rows helper in admin.dart hard-casts to List, unlike '
            'the whereType guard it applies to the entries inside one',
      );
    });
  });

  group('SuspensionResult', () {
    test('a suspension carries the cascade receipt and the server wording', () {
      final r = SuspensionResult.fromJson({
        'userId': 'u1',
        'name': 'Ali Raza',
        'role': 'owner',
        'suspended': true,
        'reason': 'repeated no-shows',
        'cascade': {'refundedTotal': '2400.00', 'requestsRejected': 3},
      }, 'Account suspended. 1 booking refunded.');
      expect(r.suspended, isTrue);
      expect(r.cascade!.refundedTotal, 2400.0);
      expect(r.message, 'Account suspended. 1 booking refunded.');
      expect(r.venuesRestored, 0);
    });

    test('a reinstatement has no cascade, and brings back venues only', () {
      final r = SuspensionResult.fromJson({
        'userId': 'u1',
        'suspended': false,
        'venuesRestored': '2',
      }, 'Account reinstated.');
      expect(r.suspended, isFalse);
      expect(r.cascade, isNull,
          reason: 'a cancelled booking was refunded and its slot may be taken');
      expect(r.venuesRestored, 2);
    });

    test('a non-map cascade block is ignored rather than half-parsed', () {
      final r = SuspensionResult.fromJson({'userId': 'u1', 'cascade': 'none'}, '');
      expect(r.cascade, isNull);
      expect(r.message, '');
      expect(r.name, isNull);
    });
  });

  group('SettingsField', () {
    test('the type decides the control, and an unknown type is not guessed at', () {
      expect(SettingsField.fromJson({'key': 'k', 'type': 'int'}).isNumeric, isTrue);
      expect(SettingsField.fromJson({'key': 'k', 'type': 'number'}).isNumeric, isTrue);
      expect(SettingsField.fromJson({'key': 'k', 'type': 'bool'}).isBool, isTrue);
      expect(SettingsField.fromJson({'key': 'k', 'type': 'sports'}).isSports, isTrue);

      final unknown = SettingsField.fromJson({'key': 'k', 'type': 'duration'});
      expect(unknown.isNumeric, isFalse);
      expect(unknown.isBool, isFalse);
      expect(unknown.isSports, isFalse);
    });

    test('a field with no type is treated as text, the read-only default', () {
      expect(SettingsField.fromJson({'key': 'k'}).type, 'text');
    });

    test('the label falls back to the key so no row is unlabelled', () {
      expect(SettingsField.fromJson({'key': 'commission_pct'}).label, 'commission_pct');
      expect(SettingsField.fromJson({'key': 'k', 'label': '  Commission  '}).label,
          'Commission');
    });

    test('bounds are kept only when they arrive as numbers, never coerced', () {
      final f = SettingsField.fromJson({
        'key': 'k',
        'type': 'int',
        'min': 0,
        'max': 50,
        'step': 0.5,
        'unit': '%',
      });
      expect(f.min, 0);
      expect(f.max, 50);
      expect(f.step, 0.5);
      expect(f.unit, '%');

      final loose = SettingsField.fromJson({'key': 'k', 'min': '0', 'max': '50'});
      expect(loose.min, isNull,
          reason: 'a string bound would silently widen the range the form allows');
      expect(loose.max, isNull);
    });

    test('pairsWith names the field this one is bounded against', () {
      final f = SettingsField.fromJson({
        'key': 'commission_pct',
        'pairsWith': 'deposit_pct',
      });
      expect(f.pairsWith, 'deposit_pct');
      expect(SettingsField.fromJson({'key': 'k'}).pairsWith, isNull);
    });

    test('isOverridden and restartRequired both require a literal true', () {
      final f = SettingsField.fromJson({
        'key': 'k',
        'isOverridden': 'true',
        'restartRequired': 1,
      });
      expect(f.isOverridden, isFalse);
      expect(f.restartRequired, isFalse);
    });
  });

  group('SettingsField.display', () {
    test('a boolean reads as on or off, not as true or false', () {
      final f = SettingsField.fromJson({'key': 'k', 'type': 'bool', 'value': true});
      expect(f.valueLabel, 'on');
      expect(f.display(false), 'off');
    });

    test('a whole number drops its decimals and keeps its unit', () {
      final f = SettingsField.fromJson({'key': 'k', 'type': 'int', 'unit': '%'});
      expect(f.display(5), '5%');
      expect(f.display(5.0), '5%');
      expect(f.display(2.5), '2.50%');
    });

    test('a unitless number carries no suffix', () {
      final f = SettingsField.fromJson({'key': 'k', 'type': 'number'});
      expect(f.display(12), '12');
      expect(f.display(12.25), '12.25');
    });

    test('an absent value reads as a dash, so no default is implied', () {
      final f = SettingsField.fromJson({'key': 'k', 'type': 'int'});
      expect(f.valueLabel, '—');
      expect(f.defaultLabel, '—');
    });

    test('a sports map lists what is enabled, and names the empty case', () {
      final f = SettingsField.fromJson({
        'key': 'sports_enabled',
        'type': 'sports',
        'value': {'football': true, 'cricket': false, 'futsal': true},
        'default': {'football': false},
      });
      expect(f.sports, {'football': true, 'cricket': false, 'futsal': true});
      expect(f.valueLabel, 'football, futsal');
      expect(f.defaultLabel, 'none enabled');
    });

    test('the sports map is empty for any other field type', () {
      final f = SettingsField.fromJson({
        'key': 'k',
        'type': 'int',
        'value': {'football': true},
      });
      expect(f.sports, isEmpty);
      expect(f.isSports, isFalse);
    });

    test('a sports field whose value is not a map yields no toggles', () {
      final f = SettingsField.fromJson({
        'key': 'k',
        'type': 'sports',
        'value': 'football',
      });
      expect(f.sports, isEmpty);
      expect(f.valueLabel, 'football');
    });

    test('a sports entry needs a literal true to count as enabled', () {
      final f = SettingsField.fromJson({
        'key': 'k',
        'type': 'sports',
        'value': {'football': 'true', 'cricket': 1},
      });
      expect(f.sports, {'football': false, 'cricket': false});
      expect(f.valueLabel, 'none enabled');
    });

    test('a text value passes through as written', () {
      final f = SettingsField.fromJson({
        'key': 'support_phone',
        'type': 'text',
        'value': '+92 300 1234567',
        'maxLen': '40',
      });
      expect(f.valueLabel, '+92 300 1234567');
      expect(f.maxLen, 40);
    });
  });

  group('SettingsSection', () {
    test('fields keep the server order the form is built in', () {
      final s = SettingsSection.fromJson({
        'key': 'money',
        'label': 'Money',
        'hint': 'Commission and deposit cannot exceed 100 % together.',
        'fields': [
          {'key': 'commission_pct', 'type': 'int'},
          {'key': 'deposit_pct', 'type': 'int'},
        ],
      });
      expect(s.fields.map((f) => f.key).toList(), ['commission_pct', 'deposit_pct']);
      expect(s.hint, contains('100'));
    });

    test('a section label falls back to its key, and non-map fields are skipped', () {
      final s = SettingsSection.fromJson({
        'key': 'money',
        'fields': [
          {'key': 'commission_pct'},
          'garbage',
        ],
      });
      expect(s.label, 'money');
      expect(s.fields.length, 1);
      expect(s.hint, isNull);
    });
  });

  group('SettingsCatalog', () {
    SettingsCatalog catalog() => SettingsCatalog.fromJson({
          'sections': [
            {
              'key': 'money',
              'label': 'Money',
              'fields': [
                {'key': 'commission_pct', 'type': 'int', 'value': 12},
                {'key': 'deposit_pct', 'type': 'int', 'value': 20},
              ],
            },
            {
              'key': 'matchmaking',
              'label': 'Matchmaking',
              'fields': [
                {'key': 'elo_k_factor', 'type': 'int', 'value': 32},
              ],
            },
          ],
          'overrides': ['commission_pct'],
          'cacheTtlSeconds': '30',
        });

    test('sections and their fields keep the order the screen renders in', () {
      final c = catalog();
      expect(c.sections.map((s) => s.key).toList(), ['money', 'matchmaking']);
      expect(c.sections.first.fields.length, 2);
    });

    test('field searches every section, and returns null for an unknown key', () {
      final c = catalog();
      expect(c.field('elo_k_factor')!.value, 32);
      expect(c.field('commission_pct')!.valueLabel, '12');
      expect(c.field('nothing_like_this'), isNull,
          reason: 'a missing key is a server change, not a value to invent');
    });

    test('overrides is the server comparison of values, carried verbatim', () {
      expect(catalog().overrides, ['commission_pct']);
      expect(SettingsCatalog.fromJson({}).overrides, isEmpty);
    });

    test('appliesImmediately is true unless the server denies it', () {
      expect(SettingsCatalog.fromJson({}).appliesImmediately, isTrue);
      expect(
        SettingsCatalog.fromJson({'appliesImmediately': false}).appliesImmediately,
        isFalse,
      );
      expect(
        SettingsCatalog.fromJson({'appliesImmediately': 'no'}).appliesImmediately,
        isTrue,
        reason: 'only a literal false may claim a save does not take effect',
      );
    });

    test('the cache window defaults to 60 seconds', () {
      expect(SettingsCatalog.fromJson({}).cacheTtlSeconds, 60);
      expect(catalog().cacheTtlSeconds, 30);
    });

    test('the pre-read default is an empty form that finds nothing', () {
      const c = SettingsCatalog.empty;
      expect(c.sections, isEmpty);
      expect(c.overrides, isEmpty);
      expect(c.field('commission_pct'), isNull);
      expect(c.appliesImmediately, isTrue);
      expect(c.cacheTtlSeconds, 60);
    });
  });

  group('SettingsChange', () {
    test('a saved change names the key, the label and both values', () {
      final c = SettingsChange.fromJson({
        'key': 'commission_pct',
        'label': 'Commission',
        'from': 12,
        'to': 15,
      });
      expect(c.key, 'commission_pct');
      expect(c.label, 'Commission');
      expect(c.from, 12);
      expect(c.to, 15);
    });

    test('the label falls back to the key, and both values may be absent', () {
      final c = SettingsChange.fromJson({'key': 'commission_pct'});
      expect(c.label, 'commission_pct');
      expect(c.from, isNull);
      expect(c.to, isNull);
    });

    test('a change to false is carried, not mistaken for an absent value', () {
      final c = SettingsChange.fromJson({'key': 'k', 'from': true, 'to': false});
      expect(c.from, isTrue);
      expect(c.to, isFalse);
    });
  });
}
