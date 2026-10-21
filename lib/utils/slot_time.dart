DateTime? slotEndTime(Map<String, dynamic> slot) {
  final dateText = (slot['slot_date'] ?? slot['date'])?.toString();
  if (dateText == null || dateText.length < 10) return null;
  final date = DateTime.tryParse(dateText.substring(0, 10));
  final end = _timeOffset(slot['end_time']);
  if (date == null || end == null) return null;
  final start = _timeOffset(slot['start_time']);
  final overnight = start != null && end < start;
  return DateTime.utc(date.year, date.month, date.day)
      .add(end)
      .add(Duration(days: overnight ? 1 : 0))
      .subtract(const Duration(hours: 5));
}

bool isSlotPast(Map<String, dynamic> slot, {DateTime? now}) {
  final end = slotEndTime(slot);
  return end != null && !end.isAfter((now ?? DateTime.now()).toUtc());
}

Duration? _timeOffset(dynamic raw) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$')
      .firstMatch(raw?.toString() ?? '');
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  final second = int.parse(match.group(3) ?? '0');
  if (hour > 24 || minute > 59 || second > 59 ||
      (hour == 24 && (minute != 0 || second != 0))) {
    return null;
  }
  return Duration(hours: hour, minutes: minute, seconds: second);
}
