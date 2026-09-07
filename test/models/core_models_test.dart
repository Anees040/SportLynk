// Venue, User and Booking model tests.
//
// These three are the oldest models in the tree and the only ones that still
// hard-cast their required fields (`json['id'] as String`). A cast is not a
// tolerance: a null or an integer where a string was expected throws a TypeError
// and takes out the whole list, not one row. The throwing cases are pinned below
// so the fragility is visible, and so a future fix has to update a test
// deliberately rather than silently changing behaviour.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/booking.dart';
import 'package:sportlynk/models/user.dart';
import 'package:sportlynk/models/venue.dart';

void main() {
  group('Venue.fromJson', () {
    test('reads a full row, coercing pg decimal strings', () {
      final v = Venue.fromJson({
        'id': 'v1',
        'name': 'Astro Turf Gulberg',
        'sport_type': 'football',
        'city': 'Lahore',
        'latitude': '31.5204',
        'longitude': '74.3587',
        'base_price': '2500.00',
        'current_price': '2750.50',
        'is_active': true,
      });
      expect(v.id, 'v1');
      expect(v.latitude, closeTo(31.5204, 0.0001));
      expect(v.longitude, closeTo(74.3587, 0.0001));
      expect(v.basePrice, 2500.0);
      expect(v.currentPrice, 2750.5);
      expect(v.isActive, isTrue);
    });

    test('an absent price stays null so the UI can say "unpriced"', () {
      final v = Venue.fromJson({'id': 'v1', 'name': 'Court 2'});
      expect(v.basePrice, isNull);
      expect(v.currentPrice, isNull);
      expect(v.latitude, isNull);
      expect(v.description, isNull);
      expect(v.imageUrl, isNull);
    });

    test('a zero price is a price, not an absence', () {
      final v = Venue.fromJson({'id': 'v1', 'name': 'Free Court', 'base_price': '0.00'});
      expect(v.basePrice, 0.0);
      expect(v.basePrice, isNotNull);
    });

    test('isActive defaults to true when the column is absent', () {
      expect(Venue.fromJson({'id': 'v1', 'name': 'X'}).isActive, isTrue);
      expect(Venue.fromJson({'id': 'v1', 'name': 'X', 'is_active': false}).isActive, isFalse);
    });

    test('toJson round-trips the fields the API accepts back', () {
      final v = Venue.fromJson({
        'id': 'v1',
        'name': 'Astro Turf',
        'city': 'Lahore',
        'base_price': '2500.00',
      });
      final j = v.toJson();
      expect(j['id'], 'v1');
      expect(j['name'], 'Astro Turf');
      expect(j['city'], 'Lahore');
      expect(j['base_price'], 2500.0);
      expect(Venue.fromJson(Map<String, dynamic>.from(j)).basePrice, 2500.0);
    });

    test('a missing id or name throws rather than degrading', () {
      expect(() => Venue.fromJson({'name': 'X'}), throwsA(isA<TypeError>()));
      expect(() => Venue.fromJson({'id': 'v1'}), throwsA(isA<TypeError>()));
      expect(() => Venue.fromJson({'id': 7, 'name': 'X'}), throwsA(isA<TypeError>()));
    });
  });

  group('User.fromJson', () {
    test('reads a full row and stringifies the id', () {
      final u = User.fromJson({
        'id': 41,
        'email': 'a@example.com',
        'role': 'player',
        'name': 'Anees',
        'phone': '+923001234567',
      });
      expect(u.id, '41');
      expect(u.email, 'a@example.com');
      expect(u.role, 'player');
      expect(u.name, 'Anees');
      expect(u.phone, '+923001234567');
      expect(u.avatarUrl, isNull);
    });

    test('the avatar arrives under either key depending on the route', () {
      expect(
        User.fromJson({'id': 'u1', 'role': 'player', 'name': 'A', 'avatarUrl': 'x.png'}).avatarUrl,
        'x.png',
      );
      expect(
        User.fromJson({'id': 'u1', 'role': 'player', 'name': 'A', 'avatar_url': 'y.png'}).avatarUrl,
        'y.png',
      );
    });

    test('a missing role or name throws rather than degrading', () {
      expect(() => User.fromJson({'id': 'u1', 'name': 'A'}), throwsA(isA<TypeError>()));
      expect(() => User.fromJson({'id': 'u1', 'role': 'player'}), throwsA(isA<TypeError>()));
    });

    test('copyWith overrides only what it is given', () {
      const u = User(id: 'u1', role: 'player', name: 'Anees', email: 'a@example.com');
      final renamed = u.copyWith(name: 'Anees Khan');
      expect(renamed.name, 'Anees Khan');
      expect(renamed.id, 'u1');
      expect(renamed.role, 'player');
      expect(renamed.email, 'a@example.com');
    });

    test('copyWith cannot clear a field, since null means unchanged', () {
      const u = User(id: 'u1', role: 'player', name: 'A', phone: '+92300');
      expect(u.copyWith(phone: null).phone, '+92300');
    });

    test('toJson emits the snake-case avatar key the API expects', () {
      const u = User(id: 'u1', role: 'player', name: 'A', avatarUrl: 'x.png');
      expect(u.toJson()['avatar_url'], 'x.png');
      expect(u.toJson().containsKey('avatarUrl'), isFalse);
    });
  });

  group('Booking.fromJson', () {
    test('reads a joined row with venue and slot columns', () {
      final b = Booking.fromJson({
        'id': 'b1',
        'venue_id': 'v1',
        'player_id': 'u1',
        'slot_id': 's1',
        'status': 'confirmed',
        'total_amount': '2500.00',
        'deposit_amount': '500.00',
        'venue_name': 'Astro Turf',
        'city': 'Lahore',
        'date': '2026-03-01',
        'start_time': '18:00:00',
        'end_time': '19:00:00',
      });
      expect(b.id, 'b1');
      expect(b.status, 'confirmed');
      expect(b.totalAmount, 2500.0);
      expect(b.depositAmount, 500.0);
      expect(b.venueName, 'Astro Turf');
      expect(b.slotDate, '2026-03-01');
      expect(b.startTime, '18:00:00');
    });

    test('the slot date is read from `date`, not `slot_date`', () {
      expect(Booking.fromJson({'id': 'b1', 'date': '2026-03-01'}).slotDate, '2026-03-01');
      expect(Booking.fromJson({'id': 'b1', 'slot_date': '2026-03-01'}).slotDate, isNull);
    });

    test('status defaults to pending when the column is absent', () {
      expect(Booking.fromJson({'id': 'b1'}).status, 'pending');
    });

    test('an absent amount stays null so a total of zero is distinguishable', () {
      final b = Booking.fromJson({'id': 'b1'});
      expect(b.totalAmount, isNull);
      expect(b.depositAmount, isNull);
      expect(Booking.fromJson({'id': 'b1', 'deposit_amount': '0.00'}).depositAmount, 0.0);
    });

    test('a missing id throws rather than degrading', () {
      expect(() => Booking.fromJson({'status': 'confirmed'}), throwsA(isA<TypeError>()));
      expect(() => Booking.fromJson({'id': 7}), throwsA(isA<TypeError>()));
    });
  });
}
