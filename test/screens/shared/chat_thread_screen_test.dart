// Chat Thread resolves a room only when the caller did not already have its id,
// then loads members and history through ChatController. The tests cover the room
// empty/not-found branches, a real inbound bubble, and the ordinary text send path.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_channel.dart';
import 'package:sportlynk/screens/shared/chat_thread_screen.dart';
import 'package:sportlynk/services/realtime_service.dart';

import '../screen_harness.dart';

const String kMembers = '/chat/c-1/members';
const String kMessages = '/chat/c-1/messages';
const String kRead = '/chat/c-1/read';
const String kQuickReplies = '/chat/c-1/quick-replies';
const String kBookingRoom = '/chat/booking/bk-1';

List<Map<String, dynamic>> members() => [
  {
    'user_id': 'u-1',
    'role': 'member',
    'name': 'Bilal Ahmed',
    'last_read_at': null,
    'last_delivered_at': null,
  },
  {
    'user_id': 'u-2',
    'role': 'member',
    'name': 'Ali Raza',
    'last_read_at': null,
    'last_delivered_at': null,
  },
];

List<Map<String, dynamic>> history({bool inbound = true}) => inbound
    ? [
        {
          'id': 'msg-1',
          'channel_id': 'c-1',
          'sender_id': 'u-2',
          'sender_name': 'Ali Raza',
          'kind': 'text',
          'body': 'Are we still on for six?',
          'created_at': '2026-09-13T10:00:00Z',
          'reactions': <Map<String, dynamic>>[],
        },
      ]
    : <Map<String, dynamic>>[];

Future<RouteLog> pumpThread(
  WidgetTester tester,
  FakeApi api, {
  String? channelId = 'c-1',
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    ChatThreadScreen.booking(
      bookingId: 'bk-1',
      title: 'Green Turf Arena',
      channelId: channelId,
      contextLine: '2026-09-20 - 6:00 PM',
    ),
    // ChatController deliberately receives an empty token in the offline harness;
    // this makes RealtimeService.ensureConnected a no-op while REST remains covered.
    auth: FakeAuth(token: null),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi()..install();
    api.ok(kMembers, members());
    api.ok(kMessages, history());
    api.ok(kRead, <String, dynamic>{});
    api.ok(kQuickReplies, {
      'suggestions': [
        {'text': 'Yes, see you then.'},
      ],
      'source': 'lexicon',
      'advisory': true,
    });
  });

  group('the room as it opens', () {
    testWidgets('shows a spinner while history is loading', (tester) async {
      api.ok(kMessages, history(), delay: const Duration(milliseconds: 300));
      await pumpThread(tester, api);

      expectLoading(tester);
      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Are we still on for six?'), findsOneWidget);
    });

    testWidgets('an empty booking room explains what it is for', (
      tester,
    ) async {
      api.ok(kMessages, history(inbound: false));
      await pumpThread(tester, api);
      await settleData(tester);

      expect(
        find.textContaining('Chat with the venue about this booking'),
        findsOneWidget,
      );
      expect(find.text('Green Turf Arena'), findsOneWidget);
    });

    testWidgets('an inbound message shows its sender and context', (
      tester,
    ) async {
      await pumpThread(tester, api);
      await settleData(tester);

      expect(find.text('Are we still on for six?'), findsOneWidget);
      expect(find.text('Ali Raza'), findsOneWidget);
      expect(find.text('2026-09-20 - 6:00 PM'), findsOneWidget);
      // Booking rooms request advisory replies for the latest inbound message.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Yes, see you then.'), findsOneWidget);
    });

    testWidgets(
      'a missing booking room renders its type-specific explanation',
      (tester) async {
        api.offline(kBookingRoom);
        final log = await pumpThread(tester, api, channelId: null);
        await settleData(tester);

        expect(
          find.textContaining('No chat room for this booking'),
          findsOneWidget,
        );
        expect(log.pushed, isEmpty);
      },
    );
  });

  testWidgets('sending text posts the channel message body', (tester) async {
    await pumpThread(tester, api);
    await settleData(tester);

    // The socket is never created under flutter test, so the controller opens in
    // its offline state and a send would be held for the reconnect flush rather
    // than posted. Drive a connect edge so the send takes the live path a
    // signed-in client normally has — the socket connects at login, before a
    // chat is ever opened — which is the path this test exists to cover.
    RealtimeService().emitConnectionForTest(true);
    await settleData(tester);

    await tester.enterText(find.byType(TextField), 'On my way');
    // Typing swaps the hold-to-record mic for the send button; a frame has to
    // run for that rebuild before the send icon is in the tree to tap.
    await tester.pump();
    await tapVisible(tester, find.byIcon(Icons.send_rounded));
    await settleData(tester);

    final sent = api.to(kMessages).where((r) => r.method == 'POST').toList();
    expect(sent, hasLength(1));
    final body = jsonDecode(sent.single.body!) as Map<String, dynamic>;
    expect(body['kind'], 'text');
    expect(body['body'], 'On my way');
    expect(body['clientId'], isNotEmpty);
    expect(find.text('On my way'), findsOneWidget);
  });

  // The offline compose path: a send made while the socket is down is held as a
  // pending bubble and posted on the reconnect flush, reusing its clientId so the
  // server dedupes rather than doubling it. This is the half of the outbound queue
  // that the plain send above deliberately steps past by connecting first.
  testWidgets('a send composed offline is flushed on reconnect', (tester) async {
    await pumpThread(tester, api);
    await settleData(tester);

    // No connect edge: the controller is offline, so the send is queued.
    await tester.enterText(find.byType(TextField), 'On my way');
    await tester.pump();
    await tapVisible(tester, find.byIcon(Icons.send_rounded));
    await settleData(tester);

    expect(find.text('On my way'), findsOneWidget,
        reason: 'the offline send shows immediately as a pending bubble');
    expect(
      api.to(kMessages).where((r) => r.method == 'POST'),
      isEmpty,
      reason: 'nothing is posted while offline',
    );

    // Reconnect drains the outbox in order.
    RealtimeService().emitConnectionForTest(true);
    await settleData(tester);

    final sent = api.to(kMessages).where((r) => r.method == 'POST').toList();
    expect(sent, hasLength(1));
    final body = jsonDecode(sent.single.body!) as Map<String, dynamic>;
    expect(body['body'], 'On my way');
    expect(body['clientId'], isNotEmpty);
  });

  testWidgets('a doubled text scale keeps the room title and message present', (
    tester,
  ) async {
    ignoreOverflow();
    await pumpThread(tester, api, textScale: 2.0);
    await settleData(tester);

    expect(find.text('Green Turf Arena'), findsOneWidget);
    expect(find.text('Are we still on for six?'), findsOneWidget);
  });

  // The coordination room reaches its match from the inbox
  //
  // A captain channel's ref_id is the match, not a team, so the header's jump to
  // the match centre needs the viewer's own team resolved from the server-computed
  // context. `fromChannel` is the inbox path — the one entry point that has no team
  // in hand — so without the context field the jump would never appear there and a
  // captain could not reach the result/dispute controls the room exists to support.
  group('the coordination room header, opened from the inbox', () {
    ChatChannel captainChannel({String? myTeamId, String? myTeamName}) => ChatChannel(
          id: 'c-1',
          type: ChatChannelType.captain,
          refId: 'match-1',
          title: 'Falcons vs Titans',
          role: 'admin',
          context: ChatChannelContext(
            kind: 'captain',
            status: 'accepted',
            title: 'Falcons vs Titans',
            subtitle: 'Accepted',
            opponentName: 'Titans',
            myTeamId: myTeamId,
            myTeamName: myTeamName,
          ),
        );

    testWidgets('offers the match-centre jump when the viewer’s team is known', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        ChatThreadScreen.fromChannel(captainChannel(myTeamId: 'team-A', myTeamName: 'Falcons')),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(find.byTooltip('Match centre'), findsOneWidget);
    });

    testWidgets('hides the jump when the viewer’s team is unknown', (tester) async {
      await pumpScreen(
        tester,
        ChatThreadScreen.fromChannel(captainChannel()),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(find.byTooltip('Match centre'), findsNothing);
    });
  });

  // Message alignment — the regression that opened this batch.
  //
  // A sent message is wrapped in a Dismissible for swipe-to-reply, and the
  // Dismissible lays its child out in a Stack that passes loose width; without a
  // width the row shrank to the bubble, the bubble's own end-alignment had no
  // room to act, and a sent message drifted left and read as centred. A pending
  // message skips the Dismissible, which is why it looked right while sending and
  // jumped on confirmation. Mine must sit in the right half of the row, theirs in
  // the left — WhatsApp's layout.
  testWidgets('a sent message aligns right and a received one aligns left',
      (tester) async {
    api.ok(kMessages, [
      {
        'id': 'm-them',
        'channel_id': 'c-1',
        'sender_id': 'u-2',
        'sender_name': 'Ali Raza',
        'kind': 'text',
        'body': 'Six works',
        'created_at': '2026-09-13T10:00:00Z',
        'reactions': <Map<String, dynamic>>[],
      },
      {
        'id': 'm-mine',
        'channel_id': 'c-1',
        'sender_id': 'u-1',
        'sender_name': 'Bilal Ahmed',
        'kind': 'text',
        'body': 'See you',
        'created_at': '2026-09-13T10:01:00Z',
        'reactions': <Map<String, dynamic>>[],
      },
    ]);
    await pumpThread(tester, api);
    await settleData(tester);

    final width = tester.getSize(find.byType(Scaffold).first).width;
    final mine = tester.getCenter(find.text('See you')).dx;
    final theirs = tester.getCenter(find.text('Six works')).dx;
    expect(mine, greaterThan(width / 2),
        reason: 'a sent message hugs the right');
    expect(theirs, lessThan(width / 2),
        reason: 'a received message hugs the left');
  });

  // In-place selection (Issue 1h) — long-press turns the app bar into a
  // contextual action bar; its close button returns to the normal header.
  group('message selection', () {
    testWidgets('a long press opens the contextual action bar', (tester) async {
      await pumpThread(tester, api);
      await settleData(tester);

      await tester.longPress(find.text('Are we still on for six?'));
      await tester.pump();

      expect(find.text('1'), findsOneWidget, reason: 'the selected count');
      expect(find.byIcon(Icons.forward_outlined), findsOneWidget);
      expect(find.text('Green Turf Arena'), findsNothing,
          reason: 'the normal header is replaced while selecting');
    });

    testWidgets('closing the action bar restores the header', (tester) async {
      await pumpThread(tester, api);
      await settleData(tester);

      await tester.longPress(find.text('Are we still on for six?'));
      await tester.pump();
      await tester.tap(find.descendant(
          of: find.byType(AppBar), matching: find.byIcon(Icons.close)));
      await tester.pump();

      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.byIcon(Icons.forward_outlined), findsNothing);
    });
  });
}
