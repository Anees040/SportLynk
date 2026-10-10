import 'num_util.dart';

/// A TIME value as 'HH:MM:SS', so two of them compare as strings. Mirrors
/// `timeStr` in backend/src/utils/slotGroup.js and the copy in venue_detail.
String bookingTimeKey(dynamic raw) {
  final s = raw == null ? '' : raw.toString().trim();
  final m = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(s);
  if (m == null) return s;
  return '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}:${m.group(3) ?? '00'}';
}

/// Fold the bookings that were made together into one row each.
///
/// A multi-slot booking is N rows sharing a `booking_group_id` — each with its own
/// escrow, refund window and QR code — because that is what leaves the money paths
/// untouched. The player asked for one block of play, though, so a list shows one
/// card. Extracted from the Bookings tab so the Home dashboard collapses groups the
/// exact same way and the two can never disagree about what one booking is.
///
/// Grouped by id AND status, deliberately. Once one hour of a run is cancelled the
/// remaining hours are a different thing from the cancelled one, and a single card
/// would have to invent a combined status. Splitting by status means every card has
/// a status that is simply true.
///
/// Rows carrying no group id — every booking before migration 035, and every
/// single-slot booking after it — pass through untouched. A collapsed row carries
/// the first member plus `_groupCount`, `_groupContiguous`, `_groupEnd`,
/// `_groupStarts` and `_groupIds`, and a summed `total_amount`.
List<Map<String, dynamic>> collapseBookingGroups(List<Map<String, dynamic>> rows) {
  final order = <String>[];
  final buckets = <String, List<Map<String, dynamic>>>{};

  for (final b in rows) {
    final gid = b['booking_group_id']?.toString();
    final key = (gid == null || gid.isEmpty)
        ? 'single:${b['id']}'
        : 'group:$gid:${b['status']}';
    final bucket = buckets[key];
    if (bucket == null) {
      buckets[key] = [b];
      order.add(key);
    } else {
      bucket.add(b);
    }
  }

  final out = <Map<String, dynamic>>[];
  for (final key in order) {
    final members = buckets[key]!;
    if (members.length == 1) {
      out.add(members.first);
      continue;
    }
    members.sort((a, b) {
      final byDate = (a['slot_date'] ?? '').toString()
          .compareTo((b['slot_date'] ?? '').toString());
      return byDate != 0
          ? byDate
          : bookingTimeKey(a['start_time']).compareTo(bookingTimeKey(b['start_time']));
    });

    // Whether what is left of the run is still back to back. It may not be: one hour
    // out of the middle can be cancelled on its own, and printing "18:00 – 21:00 ·
    // 2 slots" for 18:00 and 20:00 would claim an hour the player no longer has.
    var contiguous = true;
    for (var i = 1; i < members.length; i += 1) {
      final prevEnd = bookingTimeKey(members[i - 1]['end_time']);
      final nextStart = bookingTimeKey(members[i]['start_time']);
      final sameDay = (members[i - 1]['slot_date'] ?? '').toString()
          == (members[i]['slot_date'] ?? '').toString();
      final seam = !sameDay && prevEnd == '24:00:00' && nextStart == '00:00:00';
      if (!(sameDay && prevEnd == nextStart) && !seam) {
        contiguous = false;
        break;
      }
    }

    out.add({
      // The first member carries the card: its id is what a tap opens, and its
      // `booking_group_id` is what lets the detail screen show the whole run.
      ...members.first,
      'total_amount': members.fold<double>(0, (s, m) => s + asNum(m['total_amount'])),
      '_groupCount': members.length,
      '_groupContiguous': contiguous,
      '_groupEnd': members.last['end_time'],
      '_groupStarts': members.map((m) => m['start_time']).toList(),
      '_groupIds': members.map((m) => m['id'].toString()).toList(),
    });
  }
  return out;
}
