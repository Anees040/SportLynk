// Chat Thread resolves a room only when the caller did not already have its id,
// then loads members and history through ChatController. The tests cover the room
// empty/not-found branches, a real inbound bubble, and the ordinary text send path.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/shared/chat_thread_screen.dart';

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

    await tester.enterText(find.byType(TextField), 'On my way');
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

  testWidgets('a doubled text scale keeps the room title and message present', (
    tester,
  ) async {
    ignoreOverflow();
    await pumpThread(tester, api, textScale: 2.0);
    await settleData(tester);

    expect(find.text('Green Turf Arena'), findsOneWidget);
    expect(find.text('Are we still on for six?'), findsOneWidget);
  });
}
