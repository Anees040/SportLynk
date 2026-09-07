// Chat message model tests.
//
// Three things here decide whether a bubble renders or the list throws: the
// `kind` fallback (an unknown kind must degrade to text, never crash a channel),
// the image aspect ratio (an unconstrained ratio blows the bubble out of the
// viewport), and the reaction fold (chips must not reshuffle between rebuilds).
// Media dimensions arrive from pg, so they may be strings.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_message.dart';

ChatMessage msg(Map<String, dynamic> j) => ChatMessage.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'created_at': '2026-03-01T10:00:00.000Z',
      ...j,
    });

void main() {
  group('MessageKind parsing', () {
    test('every wire value maps to its kind', () {
      expect(msg({'kind': 'text'}).kind, MessageKind.text);
      expect(msg({'kind': 'image'}).kind, MessageKind.image);
      expect(msg({'kind': 'audio'}).kind, MessageKind.audio);
      expect(msg({'kind': 'system'}).kind, MessageKind.system);
    });

    test('an unknown or absent kind degrades to text', () {
      expect(msg({'kind': 'video'}).kind, MessageKind.text);
      expect(msg({'kind': null}).kind, MessageKind.text);
      expect(msg({}).kind, MessageKind.text);
      expect(msg({'kind': 'IMAGE'}).kind, MessageKind.text,
          reason: 'the match is exact; the column is lower case');
    });
  });

  group('bubble state flags', () {
    test('kind flags are mutually exclusive', () {
      final image = msg({'kind': 'image'});
      expect(image.isImage, isTrue);
      expect(image.isSystem, isFalse);
      final system = msg({'kind': 'system'});
      expect(system.isSystem, isTrue);
      expect(system.isImage, isFalse);
    });

    test('isDeleted is driven by the tombstone timestamp', () {
      expect(msg({}).isDeleted, isFalse);
      expect(msg({'deleted_at': '2026-03-01T11:00:00.000Z'}).isDeleted, isTrue);
    });

    test('hasCaption ignores whitespace-only bodies', () {
      expect(msg({'body': 'hello'}).hasCaption, isTrue);
      expect(msg({'body': ''}).hasCaption, isFalse);
      expect(msg({'body': '   '}).hasCaption, isFalse);
      expect(msg({'body': null}).hasCaption, isFalse);
      expect(msg({}).hasCaption, isFalse);
    });
  });

  group('aspectRatio', () {
    test('uses the natural ratio when both dimensions are known', () {
      expect(msg({'media_w': 1600, 'media_h': 900}).aspectRatio,
          closeTo(1.7778, 0.0001));
      expect(msg({'media_w': 1080, 'media_h': 1920}).aspectRatio,
          closeTo(0.5625, 0.0001));
    });

    test('parses pg string dimensions', () {
      expect(msg({'media_w': '1080', 'media_h': '1920'}).aspectRatio,
          closeTo(0.5625, 0.0001));
    });

    test('clamps a freak-wide and a freak-tall photo', () {
      expect(msg({'media_w': 4000, 'media_h': 500}).aspectRatio, 1.9);
      expect(msg({'media_w': 500, 'media_h': 4000}).aspectRatio, 0.5);
    });

    test('falls back to a gentle portrait when dimensions are unusable', () {
      expect(msg({}).aspectRatio, 0.75);
      expect(msg({'media_w': 0, 'media_h': 0}).aspectRatio, 0.75);
      expect(msg({'media_w': 1080, 'media_h': 0}).aspectRatio, 0.75);
      expect(msg({'media_w': -10, 'media_h': 100}).aspectRatio, 0.75);
      expect(msg({'media_w': 'unknown', 'media_h': 'unknown'}).aspectRatio, 0.75);
    });
  });

  group('reactions', () {
    List<Map<String, dynamic>> rx(List<List<String>> pairs) =>
        pairs.map((p) => {'emoji': p[0], 'userId': p[1]}).toList();

    test('counts fold by emoji and keep first-seen order', () {
      final m = msg({
        'reactions': rx([
          ['thumb', 'u1'],
          ['fire', 'u2'],
          ['thumb', 'u3'],
        ])
      });
      expect(m.reactionCounts, {'thumb': 2, 'fire': 1});
      expect(m.reactionCounts.keys.toList(), ['thumb', 'fire']);
    });

    test('an absent or non-list reactions field yields no reactions', () {
      expect(msg({}).reactions, isEmpty);
      expect(msg({'reactions': null}).reactions, isEmpty);
      expect(msg({}).reactionCounts, isEmpty);
    });

    test('non-map entries in the list are skipped rather than throwing', () {
      final m = msg({
        'reactions': [
          {'emoji': 'thumb', 'userId': 'u1'},
          'garbage',
          42,
        ]
      });
      expect(m.reactions.length, 1);
      expect(m.reactions.first.emoji, 'thumb');
    });

    test('reactedBy and myReaction identify the caller only', () {
      final m = msg({
        'reactions': rx([
          ['thumb', 'u1'],
          ['fire', 'u2'],
        ])
      });
      expect(m.reactedBy('u1'), isTrue);
      expect(m.reactedBy('u9'), isFalse);
      expect(m.myReaction('u2'), 'fire');
      expect(m.myReaction('u9'), isNull);
    });

    test('MessageReaction accepts either casing of the user key', () {
      expect(MessageReaction.fromJson({'emoji': 'thumb', 'userId': 'u1'}).userId, 'u1');
      expect(MessageReaction.fromJson({'emoji': 'thumb', 'user_id': 'u1'}).userId, 'u1');
    });
  });

  group('fromJson and copyWith', () {
    test('identifiers are stringified so an int id does not throw', () {
      final m = ChatMessage.fromJson({
        'id': 12,
        'channel_id': 34,
        'sender_id': 56,
        'created_at': '2026-03-01T10:00:00.000Z',
      });
      expect(m.id, '12');
      expect(m.channelId, '34');
      expect(m.senderId, '56');
    });

    test('an unparseable created_at falls back to the epoch, not null', () {
      final m = ChatMessage.fromJson({'id': 'm1', 'channel_id': 'c1'});
      expect(m.createdAt.millisecondsSinceEpoch, 0);
    });

    test('systemMeta is kept only when it is a map', () {
      expect(msg({'system_meta': {'actor': 'u1'}}).systemMeta, {'actor': 'u1'});
      expect(msg({'system_meta': 'joined'}).systemMeta, isNull);
      expect(msg({}).systemMeta, isNull);
    });

    test('an optimistic message starts settled and flips through copyWith', () {
      final m = msg({});
      expect(m.pending, isFalse);
      expect(m.failed, isFalse);
      final sending = m.copyWith(pending: true);
      expect(sending.pending, isTrue);
      expect(sending.id, m.id);
      expect(sending.createdAt, m.createdAt);
      expect(sending.copyWith(pending: false, failed: true).failed, isTrue);
    });

    test('copyWith cannot clear deletedAt once it is set', () {
      final deleted = msg({'deleted_at': '2026-03-01T11:00:00.000Z'});
      expect(deleted.copyWith(deletedAt: null).isDeleted, isTrue,
          reason: 'a null argument means "unchanged"; deletion is one-way here');
    });
  });

  group('ChatMember', () {
    test('defaults keep a partial row renderable', () {
      final m = ChatMember.fromJson({'user_id': 'u1'});
      expect(m.userId, 'u1');
      expect(m.role, 'member');
      expect(m.name, 'Player');
      expect(m.isAdmin, isFalse);
      expect(m.lastSeenAt, isNull);
    });

    test('an admin is recognised by the chat role, not the team role', () {
      expect(ChatMember.fromJson({'user_id': 'u1', 'role': 'admin'}).isAdmin, isTrue);
      expect(ChatMember.fromJson({'user_id': 'u1', 'role': 'captain'}).isAdmin, isFalse);
    });

    test('missing watermarks read as the epoch so nothing is marked read', () {
      final m = ChatMember.fromJson({'user_id': 'u1'});
      expect(m.lastReadAt.millisecondsSinceEpoch, 0);
      expect(m.lastDeliveredAt.millisecondsSinceEpoch, 0);
    });
  });
}
