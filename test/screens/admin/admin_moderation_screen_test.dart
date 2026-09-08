// Admin moderation: the queue of reviews that need an eye — a human reported one,
// the sentiment model auto-flagged one, or an admin already hid one. The card names
// which source it is, because the action differs; the three verbs (hide, restore,
// dismiss) map straight to `PATCH /admin/reviews/:id`, and after any action the
// screen reloads from the server, the authority on what remains. The tests pin the
// four states, the source-aware card copy, the filter tallies, and the two write
// outcomes (a reloaded success, a surfaced failure that does not reload).
//
// Mount note: this screen embeds no `NotificationBell` and never calls
// `RealtimeService`, so a plain authenticated session is correct. `_load` returns
// early on a null token but clears `_loading` first (admin_moderation_screen.dart:53),
// so a null-token mount would show the empty state rather than hang; the non-null
// token is what lets a populated queue load.
//
// Read failures do not surface here. `ReviewService.moderationQueue` returns an empty
// list on any non-success (review_service.dart), and `_load` has no catch, so a failed
// queue read is indistinguishable from a genuinely clear queue — a defect (there is no
// error-with-retry state) pinned by a test below rather than fixed.
//
// FakeApi keys stubs by PATH, not method (screen_harness.dart), but the moderate PATCH
// (`/admin/reviews/r-1`) and the queue GET (`/admin/reviews/flagged`) are distinct
// paths that do not collide, so the write is counted directly.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_moderation_screen.dart';

import '../screen_harness.dart';

/// The queue endpoint, as `ApiConstants.adminFlaggedReviews` resolves it, and the
/// per-review moderation path built from a review id.
const String kFlagged = '/admin/reviews/flagged';
const String kModerate = '/admin/reviews/r-1';

/// One flagged review, in the shape `FlaggedReview.fromJson` reads (models/review.dart).
/// With no `flags` and a zero `openFlagCount` the getters read this as an auto-flag,
/// not a human report; pass `flags` to make it a reported review.
Map<String, dynamic> flagged({
  String id = 'r-1',
  int stars = 1,
  String? text = 'Terrible pitch, a waste of money.',
  String reviewerName = 'Usman Ali',
  String reviewType = 'venue',
  String? reviewedUserName,
  String? venueName = 'Green Turf Arena',
  String sentimentLabel = 'negative',
  num? sentimentScore = -0.82,
  bool flagged = true,
  bool hidden = false,
  int openFlagCount = 0,
  List<Map<String, dynamic>> flags = const [],
  String? createdAt = '2026-09-01T10:00:00Z',
}) =>
    {
      'id': id,
      'stars': stars,
      'text': ?text,
      'reviewerName': reviewerName,
      'reviewType': reviewType,
      'reviewedUserName': ?reviewedUserName,
      'venueName': ?venueName,
      'sentimentLabel': sentimentLabel,
      'sentimentScore': ?sentimentScore,
      'flagged': flagged,
      'hidden': hidden,
      'openFlagCount': openFlagCount,
      'flags': flags,
      'createdAt': ?createdAt,
    };

/// One human report row inside a review's `flags` list.
Map<String, dynamic> report({String reason = 'Abusive language', String? by = 'Sana'}) =>
    {
      'reason': reason,
      'flaggedByName': ?by,
      'createdAt': '2026-09-01T11:00:00Z',
    };

Future<RouteLog> pumpModeration(WidgetTester tester, FakeApi api,
    {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const AdminModerationScreen(),
    auth: FakeAuth(role: 'admin', id: 'admin-1', name: 'Ops', token: 'admin-token'),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // The queue is a bare list under `data`, not a paged envelope.
    api.ok(kFlagged, [flagged()]);
  });

  group('the queue as it loads', () {
    testWidgets('a spinner stands while the queue is in flight', (tester) async {
      api.ok(kFlagged, [flagged()], delay: const Duration(milliseconds: 300));
      await pumpModeration(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Review of Green Turf Arena'), findsOneWidget);
    });

    testWidgets('an auto-flagged venue review names its source and subject',
        (tester) async {
      await pumpModeration(tester, api);
      await settleData(tester);

      // A venue review reads "Review of <venue>"; the reviewer, their text and the
      // model's own escalation note all render.
      expect(find.text('Review of Green Turf Arena'), findsOneWidget);
      expect(find.text('Usman Ali'), findsOneWidget);
      expect(find.text('Terrible pitch, a waste of money.'), findsOneWidget);
      // No human report, so the card shows the model-escalation copy, not a count.
      expect(find.textContaining('Auto-flagged by the sentiment model'),
          findsOneWidget);
      // The tallies count this one review as auto, not reported or hidden.
      expect(find.text('All (1)'), findsOneWidget);
      expect(find.text('Auto-flagged (1)'), findsOneWidget);
      expect(find.text('Reported (0)'), findsOneWidget);
      expect(find.text('Hidden (0)'), findsOneWidget);
    });

    testWidgets('a reported opponent review names the reporter and reason',
        (tester) async {
      // An opponent (conduct) review reads "Conduct review of <player>"; a human
      // report gives it a count and a reason line rather than the model note.
      api.ok(kFlagged, [
        flagged(
          reviewType: 'opponent',
          reviewedUserName: 'Kaleem Raza',
          venueName: null,
          flags: [report()],
        )
      ]);
      await pumpModeration(tester, api);
      await settleData(tester);

      expect(find.text('Conduct review of Kaleem Raza'), findsOneWidget);
      expect(find.text('1 report'), findsOneWidget);
      expect(find.textContaining('Abusive language'), findsOneWidget);
      expect(find.text('Reported (1)'), findsOneWidget);
    });

    testWidgets('an empty queue says the queue is clear', (tester) async {
      api.ok(kFlagged, const <dynamic>[]);
      await pumpModeration(tester, api);
      await settleData(tester);

      expect(find.textContaining('Queue is clear.'), findsOneWidget);
    });

    testWidgets('a failed load reads as a clear queue, not an error',
        (tester) async {
      // Defect, pinned rather than fixed: `ReviewService.moderationQueue` swallows a
      // failure into an empty list, so a 500 is indistinguishable from a clear queue.
      // There is no error-with-retry state on this screen.
      api.fail(kFlagged, 'boom');
      await pumpModeration(tester, api);
      await settleData(tester);

      expect(find.textContaining('Queue is clear.'), findsOneWidget);
    });
  });

  group('the source filters', () {
    testWidgets('the auto filter with no auto-flags shows the in-filter empty copy',
        (tester) async {
      // A single reported review: switching to Auto-flagged leaves the filter empty,
      // and the copy distinguishes an empty filter from a clear queue.
      api.ok(kFlagged, [flagged(flags: [report()])]);
      await pumpModeration(tester, api);
      await settleData(tester);

      await tapVisible(tester, find.text('Auto-flagged (0)'));
      await tester.pump();

      expect(find.text('Nothing in this filter.'), findsOneWidget);
    });
  });

  group('a hidden review', () {
    testWidgets('offers only Restore and wears the hidden marker', (tester) async {
      api.ok(kFlagged, [flagged(hidden: true)]);
      await pumpModeration(tester, api);
      await settleData(tester);

      expect(find.text('HIDDEN'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Restore'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Hide'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Dismiss'), findsNothing);
    });
  });

  group('moderating a review', () {
    testWidgets('Hide sends the action, then reloads the emptied queue',
        (tester) async {
      api.on(
        kModerate,
        FakeResponse(200, jsonEncode({'success': true, 'message': 'Review hidden.'})),
      );
      await pumpModeration(tester, api);
      await settleData(tester);

      // The review leaves the queue once hidden, so the reload reads clear.
      api.ok(kFlagged, const <dynamic>[]);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Hide'));
      await tester.pumpAndSettle();

      expect(api.countTo(kModerate), 1, reason: 'exactly one moderate PATCH');
      final body = jsonDecode(api.to(kModerate).single.body!) as Map;
      expect(body['action'], 'hide');
      expect(find.text('Review hidden.'), findsOneWidget);
      expect(find.textContaining('Queue is clear.'), findsOneWidget,
          reason: 'the reload shows the emptied queue');

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('a failed action surfaces the reason and leaves the card',
        (tester) async {
      api.fail(kModerate, 'Could not reach the model service.');
      await pumpModeration(tester, api);
      await settleData(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Dismiss'));
      await tester.pumpAndSettle();

      expect(api.countTo(kModerate), 1);
      expect(find.text('Could not reach the model service.'), findsOneWidget);
      // A failure does not reload, so the review is still on screen.
      expect(find.text('Review of Green Turf Arena'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('reach and scale', () {
    testWidgets('the refresh control names itself', (tester) async {
      await pumpModeration(tester, api);
      await settleData(tester);

      expect(find.byTooltip('Refresh'), findsOneWidget);
    });

    testWidgets('a doubled text scale keeps a card present', (tester) async {
      // The test font's square-em glyphs are far wider than the app's Poppins, so a
      // dense card overflows at this scale in the harness alone; the contract is that
      // the content is still built.
      ignoreOverflow();
      await pumpModeration(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Review of Green Turf Arena'), findsOneWidget);
    });
  });
}
