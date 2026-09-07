// ChatService: the REST half of the chat — history, sending, read marks, reactions,
// the inbox and the three ways a channel is addressed.
//
// The rule this file exists to hold is that **null and zero are normal answers**.
// [ChatService.channelForBooking] answers null for a pending booking, for one made
// before rooms existed, and for a non-member (the server answers 404 rather than 403
// so a stranger cannot probe it) — all three render as an absent Message button and
// none of them is an error. [ChatService.unreadCount] answers zero rather than
// throwing, because a badge that cannot load must not put a dialog over the home
// screen.
//
// The second rule is that a send carries the `clientId` the controller generated.
// That is what reconciles the optimistic bubble with the persisted row, so it is
// asserted on both send paths rather than trusted.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_channel.dart';
import 'package:sportlynk/services/chat_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late ChatService service;

  setUp(() {
    api = FakeApi();
    service = ChatService();
  });

  tearDown(resetApiClient);

  group('history', () {
    test('the team room is addressed by team id', () async {
      api.ok({'channelId': 'c1'});
      await api.run(() => service.channelForTeam('JWT', 't1'));
      expect(api.endpoint(), '/chat/team/t1');
      expect(api.token(), 'JWT');
    });

    test('a page defaults to forty messages and no cursor', () async {
      api.ok([]);
      await api.run(() => service.messages('JWT', 'c1'));
      expect(api.endpoint(), '/chat/c1/messages?limit=40');
    });

    test('an older page passes the cursor back verbatim', () async {
      api.ok([]);
      await api.run(() => service.messages('JWT', 'c1', before: '2026-03-14T10:00:00Z', limit: 20));
      expect(api.query(), {'limit': '20', 'before': '2026-03-14T10:00:00Z'});
    });

    test('messages come back typed', () async {
      api.ok([
        {'id': 'm1', 'kind': 'text', 'body': 'kickoff at 6', 'senderId': 'u1'},
        {'id': 'm2', 'kind': 'image', 'mediaUrl': 'https://cdn/x.png', 'senderId': 'u2'},
      ]);
      final msgs = await api.run(() => service.messages('JWT', 'c1'));
      expect(msgs.map((m) => m.id), ['m1', 'm2']);
      expect(msgs.first.body, 'kickoff at 6');
    });

    test('a failure is an empty history, not a throw', () async {
      api.offline();
      expect(await api.run(() => service.messages('JWT', 'c1')), isEmpty);
    });

    test('a non-map entry is skipped', () async {
      api.ok([
        {'id': 'm1', 'kind': 'text', 'body': 'hi'},
        null,
      ]);
      expect((await api.run(() => service.messages('JWT', 'c1'))).length, 1);
    });
  });

  group('sending', () {
    test('a text message carries its kind, body and clientId', () async {
      api.ok(null, status: 201);
      await api.run(() => service.sendText('JWT', 'c1', body: 'on my way', clientId: 'tmp-1'));
      expect(api.endpoint(), '/chat/c1/messages');
      expect(api.method(), 'POST');
      expect(api.body(), {'kind': 'text', 'body': 'on my way', 'clientId': 'tmp-1'});
    });

    test('an image sends only the dimensions that are known', () async {
      api.ok(null, status: 201);
      await api.run(() => service.sendImage(
            'JWT',
            'c1',
            mediaUrl: 'https://cdn/x.png',
            clientId: 'tmp-2',
          ));
      expect(api.body(), {
        'kind': 'image',
        'mediaUrl': 'https://cdn/x.png',
        'clientId': 'tmp-2',
      });
    });

    test('an image with a caption sends it as the body', () async {
      api.ok(null, status: 201);
      await api.run(() => service.sendImage(
            'JWT',
            'c1',
            mediaUrl: 'https://cdn/x.png',
            mediaMime: 'image/png',
            mediaW: 800,
            mediaH: 600,
            caption: 'the pitch',
            clientId: 'tmp-3',
          ));
      expect(api.body(), {
        'kind': 'image',
        'mediaUrl': 'https://cdn/x.png',
        'mediaMime': 'image/png',
        'mediaW': 800,
        'mediaH': 600,
        'body': 'the pitch',
        'clientId': 'tmp-3',
      });
    });

    test('an empty caption is dropped rather than sent as a blank body', () async {
      api.ok(null, status: 201);
      await api.run(() => service.sendImage(
            'JWT',
            'c1',
            mediaUrl: 'https://cdn/x.png',
            caption: '',
            clientId: 'tmp-4',
          ));
      expect(api.body().containsKey('body'), isFalse);
    });

    test('the persisted row is returned so the optimistic copy can be reconciled', () async {
      api.ok({'id': 'm9', 'clientId': 'tmp-1', 'kind': 'text', 'body': 'on my way'}, status: 201);
      final r = await api.run(
        () => service.sendText('JWT', 'c1', body: 'on my way', clientId: 'tmp-1'),
      );
      expect((r['data'] as Map)['clientId'], 'tmp-1');
      expect((r['data'] as Map)['id'], 'm9');
    });

    test('a rejected send returns the message rather than throwing', () async {
      api.fail('You are not a member of this channel.', status: 403);
      final r = await api.run(
        () => service.sendText('JWT', 'c1', body: 'hi', clientId: 'tmp-1'),
      );
      expect(r['success'], isFalse);
      expect(r['message'], 'You are not a member of this channel.');
    });
  });

  group('read marks, members, reactions and deletes', () {
    test('marking read with no time sends an empty body, letting the server use now', () async {
      api.ok(null);
      await api.run(() => service.markRead('JWT', 'c1'));
      expect(api.endpoint(), '/chat/c1/read');
      expect(api.body(), isEmpty);
    });

    test('an explicit watermark is sent as UTC ISO 8601', () async {
      api.ok(null);
      await api.run(
        () => service.markRead('JWT', 'c1', at: DateTime.utc(2026, 3, 14, 18, 30)),
      );
      expect(api.body(), {'at': '2026-03-14T18:30:00.000Z'});
    });

    test('a local time is converted before it is sent', () async {
      api.ok(null);
      final local = DateTime(2026, 3, 14, 18, 30);
      await api.run(() => service.markRead('JWT', 'c1', at: local));
      expect(api.body()['at'], local.toUtc().toIso8601String());
      expect('${api.body()['at']}', endsWith('Z'));
    });

    test('members come back typed, and a failure is an empty roster', () async {
      api.ok([
        {'userId': 'u1', 'name': 'Ayaan', 'role': 'admin'},
      ]);
      final members = await api.run(() => service.members('JWT', 'c1'));
      expect(api.endpoint(), '/chat/c1/members');
      expect(members.single.name, 'Ayaan');

      final failing = FakeApi()..fail('nope', status: 500);
      expect(await failing.run(() => service.members('JWT', 'c1')), isEmpty);
    });

    test('a reaction posts the emoji to the message', () async {
      api.ok(null);
      await api.run(() => service.react('JWT', 'c1', 'm1', '👍'));
      expect(api.endpoint(), '/chat/c1/messages/m1/reactions');
      expect(api.body(), {'emoji': '👍'});
    });

    test('a delete is addressed at the message itself', () async {
      api.ok(null);
      await api.run(() => service.deleteMessage('JWT', 'c1', 'm1'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/chat/c1/messages/m1');
    });
  });

  group('the inbox', () {
    test('a page defaults to thirty rows with no filter', () async {
      api.ok({'items': []});
      await api.run(() => service.chats('JWT'));
      expect(api.endpoint(), '/chat?limit=30');
    });

    test('a cursor is passed back exactly as it was returned', () async {
      api.ok({'items': []});
      await api.run(() => service.chats('JWT', cursor: '2026-03-14T10:00:00Z~m9'));
      expect(api.query()['cursor'], '2026-03-14T10:00:00Z~m9');
    });

    test('a type filter travels as its wire name', () async {
      api.ok({'items': []});
      await api.run(() => service.chats('JWT', type: ChatChannelType.booking));
      expect(api.query()['type'], 'booking');
    });

    test('the unknown type is not sent as a filter', () async {
      api.ok({'items': []});
      await api.run(() => service.chats('JWT', type: ChatChannelType.unknown));
      expect(api.query().containsKey('type'), isFalse);
    });

    test('rows and the next cursor are parsed together', () async {
      api.ok({
        'items': [
          {'id': 'c1', 'type': 'team', 'title': 'Alpha'},
          {'id': 'c2', 'type': 'booking', 'title': 'Rai Arena'},
        ],
        'nextCursor': 'cur-2',
      });
      final page = await api.run(() => service.chats('JWT'));
      expect(page.items.map((c) => c.id), ['c1', 'c2']);
      expect(page.nextCursor, 'cur-2');
      expect(page.hasMore, isTrue);
    });

    test('a failure is an empty page rather than a throw', () async {
      api.offline();
      final page = await api.run(() => service.chats('JWT'));
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('a data block of the wrong type is an empty page', () async {
      api.ok([]);
      expect((await api.run(() => service.chats('JWT'))).items, isEmpty);
    });
  });

  group('the unread badge', () {
    test('totals and the per-type split are parsed', () async {
      api.ok({
        'total': '7',
        'rooms': '3',
        'byType': {'team': '4', 'booking': '3'},
      });
      final unread = await api.run(() => service.unreadCount('JWT'));
      expect(api.endpoint(), '/chat/unread-count');
      expect(unread.total, 7);
      expect(unread.rooms, 3);
      expect(unread.of(ChatChannelType.team), 4);
      expect(unread.of(ChatChannelType.captain), 0);
    });

    test('a failure is a zero badge, never an error the home screen has to show', () async {
      api.fail('Something went wrong on the server.', status: 500);
      final unread = await api.run(() => service.unreadCount('JWT'));
      expect(unread.total, 0);
      expect(unread.rooms, 0);
    });

    test('an unreachable server is a zero badge too', () async {
      api.offline();
      expect((await api.run(() => service.unreadCount('JWT'))).total, 0);
    });
  });

  group('the booking and match rooms', () {
    test('a booking room yields its channel id', () async {
      api.ok({'channelId': 'c9'});
      expect(await api.run(() => service.channelForBooking('JWT', 'b1')), 'c9');
      expect(api.endpoint(), '/chat/booking/b1');
    });

    test('a pending booking has no room yet, which is null and not an error', () async {
      api.fail('That was not found on the server.', status: 404);
      expect(await api.run(() => service.channelForBooking('JWT', 'b1')), isNull);
    });

    test('a non-member sees the same null a 404 gives, so nothing can be probed', () async {
      api.fail('That was not found on the server.', status: 404);
      expect(await api.run(() => service.channelForBooking('JWT', 'b-someone-elses')), isNull);
    });

    test('a data block without a channel id is null', () async {
      api.ok({'booking': 'b1'});
      expect(await api.run(() => service.channelForBooking('JWT', 'b1')), isNull);
    });

    test('a match room is read from the match route', () async {
      api.ok({'channelId': 'c7'});
      expect(await api.run(() => service.channelForMatch('JWT', 'm1')), 'c7');
      expect(api.endpoint(), '/chat/match/m1');
    });

    test('an unaccepted challenge has no room, which is null', () async {
      api.ok({'channelId': null});
      expect(await api.run(() => service.channelForMatch('JWT', 'm1')), isNull);
    });

    test('a numeric channel id is stringified rather than cast', () async {
      api.ok({'channelId': 42});
      expect(await api.run(() => service.channelForMatch('JWT', 'm1')), '42');
    });
  });

  group('quick replies and mute', () {
    test('replying to a message sends its id and nothing else', () async {
      api.ok({'suggestions': []});
      await api.run(() => service.quickReplies('JWT', 'c1', messageId: 'm4'));
      expect(api.endpoint(), '/chat/c1/quick-replies');
      expect(api.method(), 'POST');
      expect(api.body(), {'messageId': 'm4'});
    });

    test('raw text is the fallback when there is no message to point at', () async {
      api.ok({'suggestions': []});
      await api.run(() => service.quickReplies('JWT', 'c1', text: 'is the pitch free at 6'));
      expect(api.body(), {'text': 'is the pitch free at 6'});
    });

    test('neither argument sends an empty body, which the server refuses', () async {
      api.fail('A messageId or text is required.', status: 400);
      final set = await api.run(() => service.quickReplies('JWT', 'c1'));
      expect(api.body(), isEmpty);
      expect(set.isEmpty, isTrue);
    });

    test('the suggestions and their provenance are parsed', () async {
      api.ok({
        'suggestions': [
          {'text': 'Yes, 6 works', 'intent': 'confirm'},
          {'text': 'Can we make it 7?'},
        ],
        'intent': 'schedule',
        'confidence': '0.82',
        'source': 'model',
        'modelVersion': 'quick-reply-v1',
      });
      final set = await api.run(() => service.quickReplies('JWT', 'c1', messageId: 'm4'));
      expect(set.suggestions.map((s) => s.text), ['Yes, 6 works', 'Can we make it 7?']);
      expect(set.fromModel, isTrue);
      expect(set.confidence, 0.82);
      expect(set.advisory, isTrue);
    });

    test('a failure is an empty advisory set, so the composer is simply left alone', () async {
      api.offline();
      final set = await api.run(() => service.quickReplies('JWT', 'c1', messageId: 'm4'));
      expect(set.isEmpty, isTrue);
      expect(set.fromModel, isFalse);
    });

    test('muting sends the flag, and the hours only when given', () async {
      api.ok(null);
      await api.run(() => service.mute('JWT', 'c1'));
      expect(api.endpoint(), '/chat/c1/mute');
      expect(api.body(), {'muted': true});
    });

    test('a duration rides along with the mute', () async {
      api.ok(null);
      await api.run(() => service.mute('JWT', 'c1', hours: 8));
      expect(api.body(), {'muted': true, 'hours': 8});
    });

    test('unmuting sends the flag as false', () async {
      api.ok(null);
      await api.run(() => service.mute('JWT', 'c1', muted: false));
      expect(api.body(), {'muted': false});
    });
  });
}
