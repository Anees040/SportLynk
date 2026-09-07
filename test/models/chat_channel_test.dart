// Chat inbox model tests.
//
// The inbox row carries two pieces of real client-side logic: the type fallback
// (an unrecognised channel type must file under "Other", never crash the list)
// and `previewLine`, which decides whether a sender prefix appears. Everything
// else is tolerance — the server computes `context` and the client renders it
// verbatim, so the tests assert that a partial row still reads.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_channel.dart';

ChatChannel channel(Map<String, dynamic> j) =>
    ChatChannel.fromJson({'id': 'c1', ...j});

void main() {
  group('ChatChannelType', () {
    test('parses the three real types', () {
      expect(ChatChannelType.parse('booking'), ChatChannelType.booking);
      expect(ChatChannelType.parse('captain'), ChatChannelType.captain);
      expect(ChatChannelType.parse('team'), ChatChannelType.team);
    });

    test('anything else files under unknown rather than throwing', () {
      expect(ChatChannelType.parse('assistant'), ChatChannelType.unknown);
      expect(ChatChannelType.parse('tournament'), ChatChannelType.unknown);
      expect(ChatChannelType.parse(null), ChatChannelType.unknown);
      expect(ChatChannelType.parse(''), ChatChannelType.unknown);
      expect(ChatChannelType.parse('BOOKING'), ChatChannelType.unknown);
    });

    test('the wire value round-trips back through parse', () {
      for (final t in ChatChannelType.values) {
        if (t == ChatChannelType.unknown) continue;
        expect(ChatChannelType.parse(t.wire), t);
      }
    });

    test('every type has a section heading, including unknown', () {
      expect(ChatChannelType.booking.sectionLabel, 'Bookings');
      expect(ChatChannelType.captain.sectionLabel, 'Matches');
      expect(ChatChannelType.team.sectionLabel, 'Teams');
      expect(ChatChannelType.unknown.sectionLabel, 'Other');
    });
  });

  group('previewLine', () {
    test('an empty room falls back to the context subtitle', () {
      final c = channel({
        'type': 'booking',
        'context': {'kind': 'booking', 'subtitle': 'Confirmed - Sat 6:00 pm'},
      });
      expect(c.previewLine('me'), 'Confirmed - Sat 6:00 pm');
    });

    test('a whitespace-only preview counts as empty', () {
      final c = channel({
        'type': 'booking',
        'lastMessagePreview': '   ',
        'context': {'kind': 'booking', 'subtitle': 'Confirmed'},
      });
      expect(c.previewLine('me'), 'Confirmed');
    });

    test('with neither a message nor a context it says so', () {
      expect(channel({'type': 'team'}).previewLine('me'), 'No messages yet');
    });

    test('a two-person booking room is never prefixed', () {
      final c = channel({
        'type': 'booking',
        'lastMessagePreview': 'ok',
        'lastMessageSenderId': 'u2',
        'lastMessageSenderName': 'Ali Raza',
      });
      expect(c.previewLine('me'), 'ok');
    });

    test('a group room prefixes the first name of another sender', () {
      for (final type in ['team', 'captain']) {
        final c = channel({
          'type': type,
          'lastMessagePreview': 'ok',
          'lastMessageSenderId': 'u2',
          'lastMessageSenderName': 'Ali Raza',
        });
        expect(c.previewLine('me'), 'Ali: ok', reason: 'type $type is a group');
      }
    });

    test('my own message reads as You', () {
      final c = channel({
        'type': 'team',
        'lastMessagePreview': 'on my way',
        'lastMessageSenderId': 'me',
        'lastMessageSenderName': 'Anees Khan',
      });
      expect(c.previewLine('me'), 'You: on my way');
    });

    test('a group sender with no name reads as Someone', () {
      final c = channel({
        'type': 'team',
        'lastMessagePreview': 'ok',
        'lastMessageSenderId': 'u2',
      });
      expect(c.previewLine('me'), 'Someone: ok');
    });

    test('a system pill has no sender and is not prefixed', () {
      final c = channel({
        'type': 'team',
        'lastMessagePreview': 'Ali joined the team',
      });
      expect(c.previewLine('me'), 'Ali joined the team');
    });
  });

  group('ChatChannel.fromJson', () {
    test('defaults keep a partial row renderable', () {
      final c = channel({});
      expect(c.id, 'c1');
      expect(c.type, ChatChannelType.unknown);
      expect(c.title, 'Chat');
      expect(c.role, 'member');
      expect(c.isAdmin, isFalse);
      expect(c.messageCount, 0);
      expect(c.unread, 0);
      expect(c.isUnread, isFalse);
      expect(c.muted, isFalse);
      expect(c.context, isNull);
      expect(c.subtitle, isNull);
    });

    test('string-typed counts from pg are parsed', () {
      final c = channel({'messageCount': '42', 'unread': '3'});
      expect(c.messageCount, 42);
      expect(c.unread, 3);
      expect(c.isUnread, isTrue);
    });

    test('muted requires a literal true', () {
      expect(channel({'muted': true}).muted, isTrue);
      expect(channel({'muted': 'true'}).muted, isFalse);
      expect(channel({'muted': 1}).muted, isFalse);
    });

    test('context is parsed only when it is a map', () {
      expect(channel({'context': 'booking'}).context, isNull);
      expect(channel({'context': {'kind': 'team', 'sport': 'football'}}).context?.sport,
          'football');
    });

    test('the subtitle getter reads through to the context', () {
      final c = channel({'context': {'kind': 'team', 'subtitle': '8 members'}});
      expect(c.subtitle, '8 members');
    });
  });

  group('ChatChannelContext.fromJson', () {
    test('memberCount stays null when absent, so "0 members" is not invented', () {
      expect(ChatChannelContext.fromJson({'kind': 'team'}).memberCount, isNull);
      expect(ChatChannelContext.fromJson({'kind': 'team', 'memberCount': '8'}).memberCount, 8);
      expect(ChatChannelContext.fromJson({'kind': 'team', 'memberCount': 0}).memberCount, 0);
    });

    test('isTournament requires a literal true', () {
      expect(ChatChannelContext.fromJson({'kind': 'captain'}).isTournament, isFalse);
      expect(
        ChatChannelContext.fromJson({'kind': 'captain', 'isTournament': true}).isTournament,
        isTrue,
      );
      expect(
        ChatChannelContext.fromJson({'kind': 'captain', 'isTournament': 'yes'}).isTournament,
        isFalse,
      );
    });

    test('only the fields that apply to a type are populated', () {
      final booking = ChatChannelContext.fromJson({
        'kind': 'booking',
        'status': 'confirmed',
        'venueName': 'Astro Turf',
        'slotLabel': 'Sat 6:00 pm',
      });
      expect(booking.venueName, 'Astro Turf');
      expect(booking.slotLabel, 'Sat 6:00 pm');
      expect(booking.opponentName, isNull);
      expect(booking.sport, isNull);
    });
  });

  group('ChatChannel.copyWith mute semantics', () {
    ChatChannel muted() => channel({
          'muted': true,
          'mutedUntil': '2026-03-01T10:00:00.000Z',
        });

    test('un-muting clears the timestamp instead of keeping the old one', () {
      final c = muted().copyWith(muted: false, mutedUntil: null);
      expect(c.muted, isFalse);
      expect(c.mutedUntil, isNull);
    });

    test('an unrelated change keeps the mute window intact', () {
      final c = muted().copyWith(unread: 5);
      expect(c.muted, isTrue);
      expect(c.mutedUntil, isNotNull);
      expect(c.unread, 5);
    });

    test('re-muting with a new window replaces it', () {
      final c = muted().copyWith(muted: true, mutedUntil: DateTime.utc(2026, 4, 1));
      expect(c.mutedUntil, DateTime.utc(2026, 4, 1));
    });

    test('fields not exposed by copyWith are carried over', () {
      final c = channel({'type': 'team', 'title': 'Falcons', 'messageCount': 9})
          .copyWith(unread: 1);
      expect(c.type, ChatChannelType.team);
      expect(c.title, 'Falcons');
      expect(c.messageCount, 9);
    });
  });

  group('ChatInboxPage', () {
    test('hasMore is driven by the cursor, not by the item count', () {
      expect(ChatInboxPage.fromJson({'items': []}).hasMore, isFalse);
      expect(ChatInboxPage.fromJson({'items': [], 'nextCursor': 'x'}).hasMore, isTrue);
    });

    test('the cursor is passed through as a string, untouched', () {
      expect(
        ChatInboxPage.fromJson({'nextCursor': '2026-03-01T10:00:00.000Z'}).nextCursor,
        '2026-03-01T10:00:00.000Z',
      );
      expect(ChatInboxPage.fromJson({'nextCursor': 1234}).nextCursor, '1234');
      expect(ChatInboxPage.fromJson({}).nextCursor, isNull);
    });

    test('rows are parsed and non-map entries are skipped', () {
      final p = ChatInboxPage.fromJson({
        'items': [
          {'id': 'c1', 'type': 'team'},
          'garbage',
          null,
          {'id': 'c2', 'type': 'booking'},
        ]
      });
      expect(p.items.length, 2);
      expect(p.items.first.type, ChatChannelType.team);
      expect(p.items.last.type, ChatChannelType.booking);
    });

    test('an absent items list yields an empty page, not null', () {
      expect(ChatInboxPage.fromJson({}).items, isEmpty);
    });
  });

  group('ChatUnread', () {
    test('totals are parsed from pg strings', () {
      final u = ChatUnread.fromJson({'total': '7', 'rooms': '3'});
      expect(u.total, 7);
      expect(u.rooms, 3);
    });

    test('byType keeps only recognised channel types', () {
      final u = ChatUnread.fromJson({
        'total': 7,
        'byType': {'team': 4, 'booking': '3', 'assistant': 9, 'nonsense': 1},
      });
      expect(u.of(ChatChannelType.team), 4);
      expect(u.of(ChatChannelType.booking), 3);
      expect(u.byType.containsKey(ChatChannelType.unknown), isFalse,
          reason: 'unrecognised keys would all collapse onto one bucket');
      expect(u.byType.length, 2);
    });

    test('of() reads zero for a type with nothing unread', () {
      expect(ChatUnread.fromJson({}).of(ChatChannelType.team), 0);
      expect(const ChatUnread().of(ChatChannelType.booking), 0);
    });

    test('a non-map byType is ignored rather than throwing', () {
      expect(ChatUnread.fromJson({'byType': 'team'}).byType, isEmpty);
    });
  });

  group('QuickReplySet', () {
    test('an unconfigured response is empty, advisory and not from the model', () {
      final q = QuickReplySet.fromJson({});
      expect(q.isEmpty, isTrue);
      expect(q.source, 'unavailable');
      expect(q.fromModel, isFalse);
      expect(q.advisory, isTrue);
      expect(q.audience, 'player');
      expect(q.confidence, 0);
      expect(q.intent, isNull);
      expect(q.modelVersion, isNull);
    });

    test('fromModel gates the sparkle badge to a real classifier answer', () {
      expect(QuickReplySet.fromJson({'source': 'model'}).fromModel, isTrue);
      expect(QuickReplySet.fromJson({'source': 'lexicon'}).fromModel, isFalse);
      expect(QuickReplySet.fromJson({'source': 'unavailable'}).fromModel, isFalse);
    });

    test('advisory defaults to true and only a literal false turns it off', () {
      expect(QuickReplySet.fromJson({'advisory': false}).advisory, isFalse);
      expect(QuickReplySet.fromJson({'advisory': true}).advisory, isTrue);
      expect(QuickReplySet.fromJson({'advisory': null}).advisory, isTrue,
          reason: 'a chip must never be treated as auto-sending by default');
    });

    test('suggestions are parsed and non-map entries skipped', () {
      final q = QuickReplySet.fromJson({
        'suggestions': [
          {'text': 'On my way', 'intent': 'eta'},
          'garbage',
          {'text': 'Confirmed'},
        ],
        'source': 'model',
        'confidence': '0.82',
        'modelVersion': 'intent-v2',
      });
      expect(q.suggestions.length, 2);
      expect(q.suggestions.first.text, 'On my way');
      expect(q.suggestions.first.intent, 'eta');
      expect(q.suggestions.last.intent, isNull);
      expect(q.confidence, closeTo(0.82, 0.0001));
      expect(q.modelVersion, 'intent-v2');
      expect(q.isEmpty, isFalse);
    });

    test('a chip with no text reads as empty rather than the word null', () {
      expect(QuickReply.fromJson({}).text, '');
    });
  });
}
