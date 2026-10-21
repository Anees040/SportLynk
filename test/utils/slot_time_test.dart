import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/utils/slot_time.dart';

void main() {
  Map<String, dynamic> slot({String start = '18:00:00', String end = '19:00:00'}) => {
    'slot_date': '2026-10-20',
    'start_time': start,
    'end_time': end,
  };

  test('slot times use venue time even on a device outside Pakistan', () {
    expect(slotEndTime(slot()), DateTime.utc(2026, 10, 20, 14));
    expect(isSlotPast(slot(), now: DateTime.utc(2026, 10, 20, 13, 59)), isFalse);
    expect(isSlotPast(slot(), now: DateTime.utc(2026, 10, 20, 14)), isTrue);
  });

  test('a slot ending after midnight belongs to the following day', () {
    final overnight = slot(start: '23:00:00', end: '01:00:00');
    expect(slotEndTime(overnight), DateTime.utc(2026, 10, 20, 20));
    expect(isSlotPast(overnight, now: DateTime.utc(2026, 10, 20, 19)), isFalse);
    expect(isSlotPast(overnight, now: DateTime.utc(2026, 10, 20, 20)), isTrue);
  });

  test('24:00 and second precision are handled without losing time', () {
    expect(slotEndTime(slot(start: '23:00', end: '24:00:00')),
      DateTime.utc(2026, 10, 20, 19));
    expect(isSlotPast(slot(end: '19:00:30'),
      now: DateTime.utc(2026, 10, 20, 14, 0, 29)), isFalse);
  });

  test('missing or invalid timing does not invent a past status', () {
    expect(isSlotPast({}), isFalse);
    expect(slotEndTime(slot(end: 'bad')), isNull);
    expect(slotEndTime(slot(end: '24:01:00')), isNull);
    expect(slotEndTime(slot(end: '19:99:00')), isNull);
  });
}
