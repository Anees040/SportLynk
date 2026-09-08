// Chats: the inbox, and the only screen in the app that renders one recency-ordered
// server page as three separate sections.
//
// Five contracts are pinned here.
//
// The first is the sectioning itself (lib/screens/shared/chats_screen.dart:184). The
// server returns one flat page ordered by activity; the grouping into Bookings,
// Matches and Teams is presentational, the order of the headings comes from the
// screen's own `_sections` list rather than from the response, a section with no rows
// is not drawn at all, and a channel whose `type` this build does not recognise still
// gets a row under "Other" instead of being dropped. Each of those is independently
// breakable, so each has its own case, and the fixtures deliberately arrive in an
// order the headings do not follow.
//
// The second is that this screen has no error state, on purpose, and the header at
// :78 says why: `ChatService.chats` answers `const ChatInboxPage()` for a rejected
// token, a 500 and a dropped connection alike (lib/services/chat_service.dart:105,
// because `ApiClient` never throws), so the screen cannot tell "no rooms" from "the
// request did not land" and refuses to claim either. The empty copy states only the
// two facts it does know. Three cases below pin that a failure and a genuinely empty
// page are indistinguishable here — which is the honest handling of the limitation
// the rest of this suite records as a defect, and it is the reason this screen is
// listed as correct while Find Venues and Teams are not.
//
// The third is `previewLine` (lib/models/chat_channel.dart:144). The sender prefix is
// added for a team or a match room and withheld for a booking room, which has exactly
// two people in it; "You" replaces the reader's own name; only the first word of
// somebody else's name is used; and a room with no messages falls back to its context
// subtitle. The row then suppresses that same context line when it would be printed
// twice (:390).
//
// The fourth is the live-message path, which is NOT exercised: `_onLiveMessage` (:131)
// is driven by `RealtimeService().messages`, a broadcast stream with no public sink,
// so a test cannot deliver an event to it. The patch-in-place logic, the 'Photo' and
// 'Voice message' previews, the deleted-message line and the "reload when the room is
// not on this page" branch are all unverified here and need either an injectable
// realtime seam or an integration test.
//
// The fifth is the socket. `initState` calls `RealtimeService().ensureConnected(_token)`
// (:66), and socket.io registers a twenty-second connect timeout synchronously, which
// `flutter_test` reports as a pending timer before any tear-down can cancel it. Every
// pump below therefore passes `FakeAuth(token: null)`: the screen reads `auth.token ??
// ''` at :60, and `ensureConnected` returns on an empty token
// (lib/services/realtime_service.dart:90) before it builds a socket. Nothing else on
// the screen depends on the token — `FakeApi` matches on path, and `_myId` still
// resolves because the fixture always carries a user — so the list, the sections, the
// paging and the navigation are all fully exercised without one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/screens/shared/chat_thread_screen.dart';
import 'package:sportlynk/screens/shared/chats_screen.dart';

import '../screen_harness.dart';

/// The second sentence of the empty state. Held as a constant because it is one
/// [Text] split across two source lines, and a finder built by hand tends to drop
/// the join.
const String kEmptyChats =
    'A chat opens by itself when a booking is confirmed, when a challenge '
    'is accepted, or when you join a team. Pull down to check again.';

/// One row of `GET /chat`, in the camelCase that endpoint emits.
///
/// `unread` and `messageCount` are typed [Object] so a case can hand them the
/// strings Postgres returns for a BIGINT.
Map<String, dynamic> chan({
  String id = 'c-1',
  String type = 'booking',
  String title = 'Green Turf',
  String? imageUrl,
  String? lastMessageAt,
  String? lastMessagePreview = 'See you at seven',
  String? lastMessageSenderId,
  String? lastMessageSenderName,
  Object unread = 0,
  Object messageCount = 4,
  bool muted = false,
  String role = 'member',
  String? sortAt,
  Map<String, dynamic>? context,
}) =>
    <String, dynamic>{
      'id': id,
      'type': type,
      'refId': 'r-$id',
      'title': title,
      'imageUrl': imageUrl,
      'lastMessageAt': lastMessageAt,
      'lastMessagePreview': lastMessagePreview,
      'lastMessageSenderId': lastMessageSenderId,
      'lastMessageSenderName': lastMessageSenderName,
      'messageCount': messageCount,
      'unread': unread,
      'muted': muted,
      'role': role,
      'sortAt': sortAt,
      'context': context,
    };

/// The per-type subtitle block the server resolves for each row.
Map<String, dynamic> ctx(String kind, String subtitle) => <String, dynamic>{
      'kind': kind,
      'subtitle': subtitle,
    };

/// The envelope `data` of one inbox page.
Map<String, dynamic> page(List<Map<String, dynamic>> items, {String? cursor}) =>
    <String, dynamic>{'items': items, 'nextCursor': cursor};

/// [count] booking rows with distinct ids and titles, enough of them to make the
/// list scroll past its paging threshold.
List<Map<String, dynamic>> rows(int count, {Object unread = 0}) =>
    List<Map<String, dynamic>>.generate(
      count,
      (i) => chan(id: 'c-$i', title: 'Room $i', unread: unread),
    );

/// An ISO timestamp [ago] before now, which is what the row's stamp is computed
/// against. Local rather than UTC: `_stamp` compares calendar days in local time,
/// and a UTC fixture five hours from midnight lands on the wrong day.
String at(Duration ago) =>
    DateTime.now().subtract(ago).toIso8601String();

/// Pumps the inbox without a token, for the reason in the header.
Future<RouteLog> pumpInbox(WidgetTester tester, {double textScale = 1.0}) =>
    pumpScreen(
      tester,
      const ChatsScreen(),
      auth: FakeAuth(token: null),
      textScale: textScale,
    );

/// Scrolls the list to its end, which is where `_onScroll` asks for the next page.
Future<void> scrollToEnd(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -4000));
  await tester.pump();
  await settleData(tester);
}

/// The section heading finder. Headings are upper-cased in the widget, so a case
/// asserting on 'Bookings' would never match.
Finder heading(String label) => find.text(label.toUpperCase());

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('on the first frame', () {
    testWidgets('it asks for one page of thirty, with no cursor', (tester) async {
      api.ok('/chat', page([chan()]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(api.countTo('/chat'), 1);
      expect(api.to('/chat').single.param('limit'), '30');
      expect(api.to('/chat').single.param('cursor'), isNull,
          reason: 'the first page is the top of the list, not a continuation');
    });

    testWidgets('it shows a spinner while the page is in flight', (tester) async {
      api.ok('/chat', page([chan()]),
          delay: const Duration(milliseconds: 300));

      await pumpInbox(tester);

      expectLoading(tester);
      expect(find.text('Green Turf'), findsNothing);

      // The fixture's delay and `ApiClient`'s ten-second timeout are both live
      // timers while the request is in flight, and flutter_test reports either as
      // a pending timer, so the request is let finish before the case ends.
      await settleData(tester, step: const Duration(milliseconds: 400));
    });

    testWidgets('the title is already there behind the spinner', (tester) async {
      api.ok('/chat', page([chan()]),
          delay: const Duration(milliseconds: 300));

      await pumpInbox(tester);

      expect(find.text('Chats'), findsOneWidget);
      await settleData(tester, step: const Duration(milliseconds: 400));
    });

    testWidgets('no socket is opened without a token', (tester) async {
      // The guard this whole file depends on. If `ensureConnected` ever stops
      // returning early on an empty token, socket.io's connect timeout becomes a
      // pending timer and every case here fails on the notice rather than on its
      // subject — so the absence of that failure is itself the assertion.
      api.ok('/chat', page([chan()]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('Green Turf'), findsOneWidget);
    });
  });

  group('when there is nothing to show', () {
    testWidgets('it names how rooms get created and how to retry',
        (tester) async {
      api.ok('/chat', page(const []));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('No conversations here yet'), findsOneWidget);
      expect(find.text(kEmptyChats), findsOneWidget);
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
    });

    testWidgets('the empty state is a list under a refresh indicator',
        (tester) async {
      // The two widgets a retry needs are both present. That they are not enough
      // is pinned in the 'pull to refresh' group below: the list does not accept
      // the gesture at this height.
      api.ok('/chat', page(const []));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    // Pinned as it behaves, and as the screen's own header at
    // lib/screens/shared/chats_screen.dart:78 intends: the three cases below are
    // three different failures and one genuinely empty account, and this screen
    // cannot distinguish them, so it says nothing it cannot support.
    testWidgets('a server error reads exactly like an empty account',
        (tester) async {
      api.fail('/chat', 'Internal error', status: 500);

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('No conversations here yet'), findsOneWidget);
      expect(find.text('Internal error'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a dropped connection reads the same way', (tester) async {
      api.offline('/chat');

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text(kEmptyChats), findsOneWidget);
    });

    testWidgets('a rejected token reads the same way', (tester) async {
      api.fail('/chat', 'Unauthorized', status: 401);

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('No conversations here yet'), findsOneWidget);
    });
  });

  group('the sections', () {
    testWidgets('they are drawn in the screen order, not the response order',
        (tester) async {
      // Fixtures arrive team, booking, captain. The headings must still come out
      // Bookings, Matches, Teams — the order is `_sections`, and a page whose rows
      // happen to be grouped differently must not reorder the screen.
      api.ok(
        '/chat',
        page([
          chan(id: 'c-t', type: 'team', title: 'Lahore Lions'),
          chan(id: 'c-b', type: 'booking', title: 'Green Turf'),
          chan(id: 'c-c', type: 'captain', title: 'Karachi Kings'),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      final bookings = tester.getTopLeft(heading('Bookings')).dy;
      final matches = tester.getTopLeft(heading('Matches')).dy;
      final teams = tester.getTopLeft(heading('Teams')).dy;
      expect(bookings, lessThan(matches));
      expect(matches, lessThan(teams));
    });

    testWidgets('a row sits under its own heading', (tester) async {
      api.ok(
        '/chat',
        page([
          chan(id: 'c-t', type: 'team', title: 'Lahore Lions'),
          chan(id: 'c-b', type: 'booking', title: 'Green Turf'),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(tester.getTopLeft(heading('Bookings')).dy,
          lessThan(tester.getTopLeft(find.text('Green Turf')).dy));
      expect(tester.getTopLeft(find.text('Green Turf')).dy,
          lessThan(tester.getTopLeft(heading('Teams')).dy));
    });

    testWidgets('an empty section is not drawn at all', (tester) async {
      // An empty "Matches" heading is furniture, not information.
      api.ok('/chat', page([chan(type: 'booking')]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(heading('Bookings'), findsOneWidget);
      expect(heading('Matches'), findsNothing);
      expect(heading('Teams'), findsNothing);
    });

    testWidgets('an unrecognised type still gets a row, under Other',
        (tester) async {
      // Dropping it silently would hide a real conversation behind an app update.
      api.ok(
        '/chat',
        page([chan(id: 'c-x', type: 'coach', title: 'Coaching room')]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(heading('Other'), findsOneWidget);
      expect(find.text('Coaching room'), findsOneWidget);
    });

    testWidgets('Other comes after the three known sections', (tester) async {
      api.ok(
        '/chat',
        page([
          chan(id: 'c-x', type: 'coach', title: 'Coaching room'),
          chan(id: 'c-b', type: 'booking', title: 'Green Turf'),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(tester.getTopLeft(heading('Bookings')).dy,
          lessThan(tester.getTopLeft(heading('Other')).dy));
    });

    testWidgets('a heading carries its own unread total', (tester) async {
      api.ok(
        '/chat',
        page([
          chan(id: 'c-1', type: 'booking', unread: 2),
          chan(id: 'c-2', type: 'booking', unread: 3),
          chan(id: 'c-3', type: 'team', unread: 1),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      // 5 is the Bookings heading, which is a total no single row shows.
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('a heading with nothing unread carries no badge',
        (tester) async {
      api.ok('/chat', page([chan(unread: 0)]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('0'), findsNothing);
    });

    testWidgets('the Other heading never shows a total', (tester) async {
      // Pinned as it behaves: `_flat` (:203) passes a literal 0 for the unknown
      // section, so an unread message in a room this build cannot classify is
      // counted on the row and nowhere else.
      api.ok(
        '/chat',
        page([chan(id: 'c-x', type: 'coach', title: 'Coaching room', unread: 4)]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('4'), findsOneWidget,
          reason: 'the row badge, and no heading total beside it');
    });
  });

  group('ordering inside a section', () {
    testWidgets('the newest message comes first', (tester) async {
      api.ok(
        '/chat',
        page([
          chan(id: 'c-old', title: 'Older room', lastMessageAt: at(const Duration(hours: 5))),
          chan(id: 'c-new', title: 'Newer room', lastMessageAt: at(const Duration(minutes: 5))),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(tester.getTopLeft(find.text('Newer room')).dy,
          lessThan(tester.getTopLeft(find.text('Older room')).dy));
    });

    testWidgets('a room with no messages sorts on sortAt', (tester) async {
      // `sortAt` is the server's COALESCE tiebreaker, so a freshly created room
      // still lands in the right place rather than at the bottom.
      api.ok(
        '/chat',
        page([
          chan(
            id: 'c-msg',
            title: 'Has messages',
            lastMessageAt: at(const Duration(hours: 5)),
          ),
          chan(
            id: 'c-fresh',
            title: 'Brand new',
            lastMessagePreview: null,
            sortAt: at(const Duration(minutes: 2)),
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(tester.getTopLeft(find.text('Brand new')).dy,
          lessThan(tester.getTopLeft(find.text('Has messages')).dy));
    });

    testWidgets('a room with neither timestamp sinks to the bottom',
        (tester) async {
      api.ok(
        '/chat',
        page([
          chan(id: 'c-none', title: 'No timestamps', lastMessagePreview: null),
          chan(
            id: 'c-msg',
            title: 'Has messages',
            lastMessageAt: at(const Duration(days: 3)),
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(tester.getTopLeft(find.text('Has messages')).dy,
          lessThan(tester.getTopLeft(find.text('No timestamps')).dy));
    });
  });

  group('a row', () {
    testWidgets('a booking preview carries no sender prefix', (tester) async {
      // A booking room has exactly two people in it, so "Ali: ok" tells the reader
      // nothing the title does not already say.
      api.ok(
        '/chat',
        page([
          chan(
            type: 'booking',
            lastMessagePreview: 'On my way',
            lastMessageSenderId: 'u-9',
            lastMessageSenderName: 'Ali Raza',
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('On my way'), findsOneWidget);
      expect(find.text('Ali: On my way'), findsNothing);
    });

    testWidgets('a team preview names the sender by first name',
        (tester) async {
      api.ok(
        '/chat',
        page([
          chan(
            type: 'team',
            title: 'Lahore Lions',
            lastMessagePreview: 'Practice at six',
            lastMessageSenderId: 'u-9',
            lastMessageSenderName: 'Ali Raza',
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('Ali: Practice at six'), findsOneWidget);
    });

    testWidgets('my own message reads as You', (tester) async {
      // 'u-1' is the fixture identity, which is what `_myId` resolves to.
      api.ok(
        '/chat',
        page([
          chan(
            type: 'team',
            title: 'Lahore Lions',
            lastMessagePreview: 'On it',
            lastMessageSenderId: 'u-1',
            lastMessageSenderName: 'Bilal Ahmed',
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('You: On it'), findsOneWidget);
    });

    testWidgets('a nameless sender reads as Someone', (tester) async {
      api.ok(
        '/chat',
        page([
          chan(
            type: 'captain',
            title: 'Karachi Kings',
            lastMessagePreview: 'Confirmed',
            lastMessageSenderId: 'u-9',
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('Someone: Confirmed'), findsOneWidget);
    });

    testWidgets('a room with no messages falls back to its context line',
        (tester) async {
      api.ok(
        '/chat',
        page([
          chan(
            lastMessagePreview: null,
            context: ctx('booking', 'Confirmed · Sat 5 Sept, 6:00 pm'),
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      // Once, not twice: the row suppresses the context line when it is already
      // the preview.
      expect(find.text('Confirmed · Sat 5 Sept, 6:00 pm'), findsOneWidget);
    });

    testWidgets('a room with no messages and no context says so',
        (tester) async {
      api.ok('/chat', page([chan(lastMessagePreview: null)]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('No messages yet'), findsOneWidget);
    });

    testWidgets('the context line is a third line when it differs from the preview',
        (tester) async {
      api.ok(
        '/chat',
        page([
          chan(
            lastMessagePreview: 'See you at seven',
            context: ctx('booking', 'Confirmed · Sat 5 Sept, 6:00 pm'),
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('See you at seven'), findsOneWidget);
      expect(find.text('Confirmed · Sat 5 Sept, 6:00 pm'), findsOneWidget);
    });

    testWidgets('an unread row carries a badge and a heavier title',
        (tester) async {
      api.ok('/chat', page([chan(unread: 3)]));

      await pumpInbox(tester);
      await settleData(tester);

      // Twice: the row badge, and the Bookings heading whose total is this one
      // room's count.
      expect(find.text('3'), findsNWidgets(2));
      expect(
        tester.widget<Text>(find.text('Green Turf')).style?.fontWeight,
        FontWeight.w800,
      );
    });

    testWidgets('a read row has no badge and a lighter title', (tester) async {
      api.ok('/chat', page([chan(unread: 0)]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(
        tester.widget<Text>(find.text('Green Turf')).style?.fontWeight,
        FontWeight.w600,
      );
    });

    testWidgets('the badge caps at ninety-nine plus', (tester) async {
      api.ok('/chat', page([chan(unread: 214)]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('99+'), findsOneWidget);
      // Pinned as it behaves: `_sectionHeader` (:263) prints the total unformatted,
      // so the heading reads 214 beside a row that reads 99+. The cap is the row's
      // alone.
      expect(find.text('214'), findsOneWidget);
    });

    testWidgets('an unread count arriving as a string still counts',
        (tester) async {
      // Postgres returns BIGINT as JSON text; `asNum` is what keeps a badge of
      // "7" from being a zero.
      api.ok('/chat', page([chan(unread: '7')]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text('7'), findsNWidgets(2),
          reason: 'the row badge and the section total, both from the same string');
    });

    testWidgets('a muted room shows the crossed-out bell', (tester) async {
      api.ok('/chat', page([chan(muted: true)]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    });

    testWidgets('an unmuted room does not', (tester) async {
      api.ok('/chat', page([chan(muted: false)]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
    });

    testWidgets('each type has its own fallback icon', (tester) async {
      api.ok(
        '/chat',
        page([
          chan(id: 'c-b', type: 'booking', title: 'Green Turf'),
          chan(id: 'c-c', type: 'captain', title: 'Karachi Kings'),
          chan(id: 'c-t', type: 'team', title: 'Lahore Lions'),
          chan(id: 'c-x', type: 'coach', title: 'Coaching room'),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.byIcon(Icons.stadium_outlined), findsOneWidget);
      expect(find.byIcon(Icons.sports_kabaddi), findsOneWidget);
      expect(find.byIcon(Icons.groups), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    });

    testWidgets('a title too long for the row ellipsises', (tester) async {
      api.ok(
        '/chat',
        page([
          chan(
            title: 'Green Turf Sports Complex, Gulberg III, Lahore — Ground Two',
          ),
        ]),
      );

      await pumpInbox(tester);
      await settleData(tester);

      final title = tester.widget<Text>(find.textContaining('Green Turf Sports'));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('a timestamp today is a clock time', (tester) async {
      api.ok('/chat',
          page([chan(lastMessageAt: DateTime.now().toIso8601String())]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.textContaining(RegExp(r'^\d{1,2}:\d{2} (AM|PM)$')),
          findsOneWidget);
    });

    testWidgets('a timestamp inside the week is a weekday', (tester) async {
      api.ok('/chat', page([chan(lastMessageAt: at(const Duration(days: 3)))]));

      await pumpInbox(tester);
      await settleData(tester);

      // Three days back is never today or yesterday, so it renders as EEE.
      expect(
        find.byWidgetPredicate((w) =>
            w is Text &&
            const <String>{'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'}
                .contains(w.data)),
        findsOneWidget,
      );
    });

    testWidgets('a room with no timestamp shows no stamp at all',
        (tester) async {
      api.ok('/chat', page([chan(lastMessagePreview: null)]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(find.text(''), findsOneWidget,
          reason: '_stamp answers an empty string rather than a placeholder');
    });
  });

  group('opening a room', () {
    testWidgets('the badge clears before the thread is on screen',
        (tester) async {
      // Optimistic: opening the thread is what moves `last_read_at` server-side,
      // and the reload on return is what confirms it.
      api.ok('/chat', page([chan(unread: 3)]));

      await pumpInbox(tester);
      await settleData(tester);
      expect(find.text('3'), findsNWidgets(2));

      await tester.tap(find.text('Green Turf'));
      await tester.pump();

      // Both go: the heading total is recomputed from the rows on every build.
      expect(find.text('3'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('it pushes the thread for that channel', (tester) async {
      api.ok('/chat', page([chan(title: 'Green Turf')]));

      await pumpInbox(tester);
      await settleData(tester);

      await tester.tap(find.text('Green Turf'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatThreadScreen), findsOneWidget);
    });

    testWidgets('the list reloads on the way back', (tester) async {
      api.ok('/chat', page([chan(title: 'Green Turf')]));

      await pumpInbox(tester);
      await settleData(tester);
      expect(api.countTo('/chat'), 1);

      await tester.tap(find.text('Green Turf'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(api.countTo('/chat'), 2,
          reason: 'the badge the tap cleared is confirmed, or restored, by a reload');
    });

    testWidgets('a read row is opened without a needless rebuild',
        (tester) async {
      api.ok('/chat', page([chan(unread: 0, title: 'Green Turf')]));

      await pumpInbox(tester);
      await settleData(tester);

      await tester.tap(find.text('Green Turf'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatThreadScreen), findsOneWidget);
    });
  });

  group('paging', () {
    testWidgets('a page with a cursor asks for the next one at the end',
        (tester) async {
      api.ok('/chat', page(rows(20), cursor: '2026-09-06T10:00:00.000Z'));

      await pumpInbox(tester);
      await settleData(tester);
      expect(api.countTo('/chat'), 1);

      await scrollToEnd(tester);

      expect(api.countTo('/chat'), 2);
    });

    testWidgets('the cursor goes back exactly as it arrived', (tester) async {
      // One built here would be keyed on a different expression from the server's
      // ORDER BY and would skip or repeat a row at the seam.
      api.ok('/chat', page(rows(20), cursor: '2026-09-06T10:00:00.000Z'));

      await pumpInbox(tester);
      await settleData(tester);
      await scrollToEnd(tester);

      expect(api.to('/chat')[1].param('cursor'), '2026-09-06T10:00:00.000Z');
      expect(api.to('/chat')[1].param('limit'), '30');
    });

    testWidgets('a page without a cursor is the end of the list',
        (tester) async {
      api.ok('/chat', page(rows(20)));

      await pumpInbox(tester);
      await settleData(tester);
      await scrollToEnd(tester);

      expect(api.countTo('/chat'), 1,
          reason: 'nextCursor null means there is nothing left to ask for');
    });

    testWidgets('a repeated row is not added twice', (tester) async {
      // The fixture answers the same page for both requests, which is the seam
      // this de-duplication exists for.
      api.ok('/chat', page(rows(20), cursor: 'cur-1'));

      await pumpInbox(tester);
      await settleData(tester);
      final before = tester.widgetList(find.textContaining('Room ')).length;

      await scrollToEnd(tester);

      expect(tester.widgetList(find.textContaining('Room ')).length, before,
          reason: 'de-duplication is by channel id, not by position');
    });

    testWidgets('a trailing spinner shows while the next page is in flight',
        (tester) async {
      api.ok(
        '/chat',
        page(rows(20), cursor: 'cur-1'),
        delay: const Duration(milliseconds: 400),
      );

      await pumpInbox(tester);
      await settleData(tester, step: const Duration(milliseconds: 500));

      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await settleData(tester, step: const Duration(milliseconds: 500));
    });
  });

  group('pull to refresh', () {
    testWidgets('it asks for the first page again', (tester) async {
      // Twenty rows, not one: `ClampingScrollPhysics` refuses a user offset while
      // the content fits the viewport, so a short list cannot be dragged far
      // enough to arm the indicator. See the case below for the consequence.
      api.ok('/chat', page(rows(20)));

      await pumpInbox(tester);
      await settleData(tester);
      expect(api.countTo('/chat'), 1);

      await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleData(tester);
      await tester.pumpAndSettle();

      expect(api.countTo('/chat'), 2);
      expect(api.to('/chat')[1].param('cursor'), isNull,
          reason: 'a refresh replaces the page rather than continuing it');
    });

    testWidgets('it does not work from the empty state, which is the one place '
        'the screen tells the user to use it', (tester) async {
      // Pinned as it behaves, not as it should. Neither the empty list
      // (lib/screens/shared/chats_screen.dart:305) nor the loaded one (:170) sets
      // `physics`, so both inherit `ClampingScrollPhysics`, whose
      // `shouldAcceptUserOffset` returns false while `pixels == 0` and the content
      // is no taller than the viewport. The empty state is exactly that case, so
      // the gesture never reaches the indicator — and this screen has no error
      // state, which makes the pull its only retry. The copy at :312 says "Pull
      // down to check again". Fix: `physics: const AlwaysScrollableScrollPhysics()`
      // on both lists.
      api.ok('/chat', page(const []));

      await pumpInbox(tester);
      await settleData(tester);

      await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleData(tester);
      await tester.pumpAndSettle();

      expect(api.countTo('/chat'), 1);
    });
  });

  group('reach and scale', () {
    testWidgets('a row is comfortably above the tap-target floor',
        (tester) async {
      api.ok('/chat', page([chan()]));

      await pumpInbox(tester);
      await settleData(tester);

      expectTapTarget(tester, find.byType(InkWell));
    });

    testWidgets('a doubled text scale keeps every row legible', (tester) async {
      // The overflow assertion is deliberately not made: the test font's glyphs
      // are square ems, roughly twice the width of the Poppins the app asks for,
      // so an overflow here would be the harness's and not the screen's.
      ignoreOverflow();
      api.ok(
        '/chat',
        page([
          chan(id: 'c-b', type: 'booking', title: 'Green Turf', unread: 2),
          chan(id: 'c-t', type: 'team', title: 'Lahore Lions'),
        ]),
      );

      await pumpInbox(tester, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Green Turf'), findsOneWidget);
      expect(find.text('Lahore Lions'), findsOneWidget);
      expect(heading('Bookings'), findsOneWidget);
      expect(find.text('2'), findsNWidgets(2));
    });

    testWidgets('the section heading uses the theme colours, not literals',
        (tester) async {
      api.ok('/chat', page([chan()]));

      await pumpInbox(tester);
      await settleData(tester);

      expect(
        tester.widget<Text>(heading('Bookings')).style?.color,
        AppColors.textSecondary,
      );
    });
  });
}
