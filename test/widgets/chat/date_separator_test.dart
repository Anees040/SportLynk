// DateSeparator: the day-grouping pill in the message timeline.
//
// The label is relative for the days a user still thinks of as recent and absolute
// after that, which is the convention every chat app follows: "Today" and "Yesterday"
// need no reading, a weekday name is enough to place something inside the current week,
// and past that only a date is unambiguous. The boundary at exactly seven days is
// pinned because a weekday name there would be the wrong answer twice over — last
// Saturday and this Saturday would carry the same label.
//
// The comparison is between calendar days, not instants: both sides are truncated to
// midnight before the difference is taken, so a message at 23:50 and one at 00:10 the
// next morning are one day apart rather than twenty minutes. That is what makes the
// dates below safe to build from the current clock.
//
// A date in the future falls through to the absolute form. There is no "Tomorrow"
// branch, because a message dated ahead of now means the sending device's clock is
// wrong, and printing the date it claims is more honest than a friendly label.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sportlynk/widgets/chat/date_separator.dart';

import '../widget_harness.dart';

void main() {
  /// Midday on the day [days] before today, so no assertion depends on the hour the
  /// suite happens to run at.
  DateTime daysAgo(int days) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, 12).subtract(Duration(days: days));
  }

  Future<void> pumpSeparator(WidgetTester tester, DateTime date,
          {double textScale = 1.0}) =>
      pumpApp(tester, Scaffold(body: DateSeparator(date)), textScale: textScale);

  testWidgets('today and yesterday are named rather than dated', (tester) async {
    await pumpSeparator(tester, daysAgo(0));
    expect(find.text('Today'), findsOneWidget);

    await pumpSeparator(tester, daysAgo(1));
    expect(find.text('Yesterday'), findsOneWidget);
  });

  // The hour is irrelevant: both sides are truncated to midnight first.
  testWidgets('a message late last night is still yesterday', (tester) async {
    final now = DateTime.now();
    final lateYesterday =
        DateTime(now.year, now.month, now.day, 23, 50).subtract(const Duration(days: 1));
    await pumpSeparator(tester, lateYesterday);
    expect(find.text('Yesterday'), findsOneWidget);
  });

  testWidgets('the rest of the week is the weekday name', (tester) async {
    for (final days in [2, 3, 4, 5, 6]) {
      final date = daysAgo(days);
      await pumpSeparator(tester, date);
      expect(find.text(DateFormat('EEEE').format(date)), findsOneWidget,
          reason: '$days days ago is inside the current week');
    }
  });

  // Seven days back is the same weekday as today, so the name would be ambiguous.
  testWidgets('a week back is dated, not named', (tester) async {
    final date = daysAgo(7);
    await pumpSeparator(tester, date);
    expect(find.text(DateFormat('d MMM yyyy').format(date)), findsOneWidget);
    expect(find.text(DateFormat('EEEE').format(date)), findsNothing);
  });

  testWidgets('anything older carries the full date', (tester) async {
    await pumpSeparator(tester, DateTime(2026, 3, 14, 9));
    expect(find.text('14 Mar 2026'), findsOneWidget);
  });

  // A device with a fast clock, not a friendly label.
  testWidgets('a future date is printed as the date it claims', (tester) async {
    final tomorrow = daysAgo(-1);
    await pumpSeparator(tester, tomorrow);
    expect(find.text(DateFormat('d MMM yyyy').format(tomorrow)), findsOneWidget);
  });

  testWidgets('the pill stays within the timeline at a doubled text scale',
      (tester) async {
    await pumpSeparator(tester, DateTime(2026, 3, 14), textScale: 2.0);
    expect(find.text('14 Mar 2026'), findsOneWidget);
    expectNoOverflow(tester);
  });
}
