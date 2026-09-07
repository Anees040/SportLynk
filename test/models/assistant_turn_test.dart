// Scout conversation-state tests: the turn envelope, the bubbles, the thread list.
//
// The card models are covered in assistant_model_test.dart; this file covers what
// carries them. Two properties are load-bearing. A failed turn must still produce
// a renderable reply, because the backend rolls its transaction back and answers
// with a menu — a toast instead would leave the conversation looking as though
// nothing had happened. And a chip press must never be credited to the
// classifier: `confidence` and `modelVersion` are absent on that path, so
// `confidencePct` has to stay null rather than read as a confident zero.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';

void main() {
  group('ScoutNlu', () {
    test('confidencePct scales a 0..1 score to whole percent', () {
      expect(ScoutNlu.fromJson({'confidence': 0.8108}).confidencePct, 81);
      expect(ScoutNlu.fromJson({'confidence': '0.45'}).confidencePct, 45);
      expect(ScoutNlu.fromJson({'confidence': 1}).confidencePct, 100);
    });

    test('a value already in percent is not scaled twice', () {
      expect(ScoutNlu.fromJson({'confidence': 87}).confidencePct, 87);
    });

    test('no model scored the turn means null, never zero', () {
      expect(ScoutNlu.fromJson({}).confidencePct, isNull);
      expect(ScoutNlu.fromJson({'via': 'chip'}).confidence, isNull);
      expect(ScoutNlu.fromJson({'confidence': 0}).confidencePct, 0,
          reason: 'a measured zero is still a measurement');
    });

    test('abstained requires a literal true', () {
      expect(ScoutNlu.fromJson({'abstained': true}).abstained, isTrue);
      expect(ScoutNlu.fromJson({'abstained': 'true'}).abstained, isFalse);
      expect(ScoutNlu.fromJson({}).abstained, isFalse);
    });

    test('the abstain reason and the door taken are both carried', () {
      final n = ScoutNlu.fromJson({
        'intent': 'out_of_scope',
        'abstained': true,
        'reason': 'low_confidence',
        'via': 'model',
        'modelVersion': 'intent-v2-20260828-2315',
        'ms': '21',
      });
      expect(n.reason, 'low_confidence');
      expect(n.via, 'model');
      expect(n.modelVersion, 'intent-v2-20260828-2315');
      expect(n.ms, 21);
    });
  });

  group('ScoutReply', () {
    test('an unrecognised source still delivers the message', () {
      final r = ScoutReply.fromJson({'text': 'Here you go', 'source': 'llm'});
      expect(r.text, 'Here you go');
      expect(r.source, ScoutSource.unknown);
    });

    test('the offline reply arrives with a way forward', () {
      final r = ScoutReply.offline('No connection.');
      expect(r.text, 'No connection.');
      expect(r.chips.single.action, 'retry_last');
      expect(r.source, ScoutSource.unknown);
      expect(r.cards, isEmpty);
    });

    test('actionOk stays null unless the server sent a boolean', () {
      expect(ScoutReply.fromJson({'actionOk': true}).actionOk, isTrue);
      expect(ScoutReply.fromJson({'actionOk': false}).actionOk, isFalse);
      expect(ScoutReply.fromJson({'actionOk': 'true'}).actionOk, isNull);
      expect(ScoutReply.fromJson({}).actionOk, isNull);
    });

    test('cardOfType finds the first card of a type and null otherwise', () {
      final r = ScoutReply.fromJson({
        'cards': [
          {'type': 'venue', 'data': {'name': 'A'}},
          {'type': 'venue', 'data': {'name': 'B'}},
        ],
      });
      expect(r.cardOfType('venue')!.data.str('name'), 'A');
      expect(r.cardOfType('confirm'), isNull);
    });

    test('targetScreen is what lets a "take me there" button exist', () {
      expect(
        ScoutReply.fromJson({'meta': {'screen': 'bookings'}}).targetScreen,
        'bookings',
      );
      expect(ScoutReply.fromJson({}).targetScreen, isNull);
      expect(ScoutReply.fromJson({'meta': 'bookings'}).meta, isEmpty);
    });

    test('toJson round-trips a stored bubble, omitting what was absent', () {
      final r = ScoutReply.fromJson({
        'text': 'Two grounds free',
        'source': 'live',
        'chips': [
          {'label': 'Book', 'action': 'pick_slot', 'args': {'slotId': 's1'}},
        ],
        'cards': [
          {'type': 'venue', 'data': {'name': 'F-11 Arena'}},
        ],
      });
      final j = r.toJson();
      expect(j['source'], 'live');
      expect(j.containsKey('action'), isFalse);
      expect(j.containsKey('meta'), isFalse);

      final back = ScoutReply.fromJson(j);
      expect(back.text, r.text);
      expect(back.source, ScoutSource.live);
      expect(back.chips.single.args!['slotId'], 's1');
      expect(back.cards.single.data.str('name'), 'F-11 Arena');
    });
  });

  group('ScoutTurn.fromEnvelope', () {
    test('a successful turn carries the reply, the ids and the new state', () {
      final t = ScoutTurn.fromEnvelope({
        'success': true,
        'data': {
          'threadId': 'th1',
          'threadCreated': true,
          'messageId': 'm2',
          'reply': {'text': 'Pick a time', 'source': 'live'},
          'state': {
            'fsm': 'awaiting_choice',
            'pending': 'book',
            'intent': 'book_venue',
            'slots': {'venueId': 'v1'},
          },
          'nlu': {'intent': 'book_venue', 'confidence': 0.91, 'via': 'model'},
          'totalMs': '412',
        },
      });
      expect(t.ok, isTrue);
      expect(t.threadId, 'th1');
      expect(t.threadCreated, isTrue);
      expect(t.messageId, 'm2');
      expect(t.reply.source, ScoutSource.live);
      expect(t.fsm, ScoutFsm.awaitingChoice);
      expect(t.pending, 'book');
      expect(t.slots['venueId'], 'v1');
      expect(t.nlu!.confidencePct, 91);
      expect(t.totalMs, 412);
    });

    test('ok requires a literal true, not a truthy body', () {
      expect(ScoutTurn.fromEnvelope({'success': true}).ok, isTrue);
      expect(ScoutTurn.fromEnvelope({'success': 'true'}).ok, isFalse);
      expect(ScoutTurn.fromEnvelope({}).ok, isFalse);
    });

    test('a failed turn with no reply still draws a bubble the user can act on', () {
      final t = ScoutTurn.fromEnvelope({
        'success': false,
        'message': 'That slot was taken while you were deciding.',
      });
      expect(t.ok, isFalse);
      expect(t.reply.text, 'That slot was taken while you were deciding.');
      expect(t.reply.chips.single.action, 'retry_last');
      expect(t.message, 'That slot was taken while you were deciding.');
    });

    test('a failure with neither reply nor message still says something', () {
      final t = ScoutTurn.fromEnvelope({'success': false});
      expect(t.reply.text, 'Scout could not finish that message.');
      expect(t.reply.chips, isNotEmpty);
    });

    test('a failed turn keeps the server reply when one was sent', () {
      final t = ScoutTurn.fromEnvelope({
        'success': false,
        'message': 'rolled back',
        'data': {
          'reply': {'text': 'That is taken. Try 7 pm?', 'source': 'menu'},
        },
      });
      expect(t.reply.text, 'That is taken. Try 7 pm?');
      expect(t.reply.source, ScoutSource.menu);
    });

    test('a missing data block leaves the state idle and the ids empty', () {
      final t = ScoutTurn.fromEnvelope({'success': true});
      expect(t.threadId, '');
      expect(t.fsm, ScoutFsm.idle);
      expect(t.pending, isNull);
      expect(t.slots, isEmpty);
      expect(t.nlu, isNull);
      expect(t.totalMs, isNull);
    });

    test('a non-map state or nlu block is ignored rather than fatal', () {
      final t = ScoutTurn.fromEnvelope({
        'success': true,
        'data': {'threadId': 'th1', 'state': 'idle', 'nlu': 'chip'},
      });
      expect(t.fsm, ScoutFsm.idle);
      expect(t.nlu, isNull);
    });
  });

  group('ScoutMessage', () {
    test('a typed message is drawn before the server has seen it', () {
      final m = ScoutMessage.user('grounds near F-11', clientId: 'c9');
      expect(m.id, 'local:c9');
      expect(m.isScout, isFalse);
      expect(m.delivery, ScoutDelivery.sending);
      expect(m.clientId, 'c9');
      expect(m.isLocal, isTrue);
      expect(m.canVote, isFalse, reason: 'the user does not rate their own words');
    });

    test('a local Scout bubble cannot be voted on until it has a server id', () {
      final local = ScoutMessage.scout(ScoutReply.offline('No connection.'));
      expect(local.isLocal, isTrue);
      expect(local.canVote, isFalse);

      final saved = ScoutMessage.scout(
        ScoutReply.fromJson({'text': 'Two free'}),
        id: 'm7',
      );
      expect(saved.isLocal, isFalse);
      expect(saved.canVote, isTrue);
      expect(saved.text, 'Two free');
    });

    test('the delivery receipt swaps the local id for the server one', () {
      final sent = ScoutMessage.user('hi', clientId: 'c1')
          .copyWith(id: 'm1', delivery: ScoutDelivery.sent);
      expect(sent.id, 'm1');
      expect(sent.isLocal, isFalse);
      expect(sent.delivery, ScoutDelivery.sent);
      expect(sent.text, 'hi', reason: 'the words the user typed are never rewritten');
      expect(sent.clientId, 'c1');
    });

    test('copyWith cannot clear a field, only replace it', () {
      final voted = ScoutMessage.scout(ScoutReply.fromJson({'text': 'x'}), id: 'm1')
          .copyWith(vote: 1);
      expect(voted.vote, 1);
      expect(voted.copyWith(vote: null).vote, 1,
          reason: 'a vote is withdrawn by passing 0, since null means unchanged');
      expect(voted.copyWith(vote: 0).vote, 0);
    });

    test('a stored Scout turn re-draws its cards rather than degrading to text', () {
      final m = ScoutMessage.fromHistory({
        'id': 'm4',
        'role': 'scout',
        'text': 'Two grounds free',
        'createdAt': '2026-09-05T13:00:00Z',
        'payload': {
          'text': 'Two grounds free',
          'source': 'live',
          'cards': [
            {'type': 'venue', 'data': {'name': 'F-11 Arena'}},
          ],
        },
      });
      expect(m.isScout, isTrue);
      expect(m.reply!.cards.single.data.str('name'), 'F-11 Arena');
      expect(m.reply!.source, ScoutSource.live);
      expect(m.createdAt.toUtc().hour, 13);
      expect(m.delivery, ScoutDelivery.sent,
          reason: 'a message read back from history has plainly arrived');
    });

    test('a user row carries no reply even if a payload was stored beside it', () {
      final m = ScoutMessage.fromHistory({
        'id': 'm3',
        'role': 'user',
        'text': 'grounds near F-11',
        'payload': {'text': 'ignored'},
      });
      expect(m.isScout, isFalse);
      expect(m.reply, isNull);
    });

    test('an unparseable date falls back to now rather than dropping the bubble', () {
      final before = DateTime.now();
      final m = ScoutMessage.fromHistory({'id': 'm1', 'role': 'scout', 'createdAt': 'soon'});
      expect(m.createdAt.isBefore(before.subtract(const Duration(seconds: 1))), isFalse);
      expect(m.text, '');
      expect(m.reply, isNull, reason: 'a scout row with no payload has nothing to re-draw');
    });

    test('a row with no id is carried but not votable', () {
      final m = ScoutMessage.fromHistory({'role': 'scout', 'text': 'x'});
      expect(m.id, '');
      expect(m.isLocal, isFalse);
      expect(m.canVote, isFalse);
    });
  });

  group('ScoutThread', () {
    test('an untitled thread reads as a new chat, never as a blank row', () {
      expect(ScoutThread.fromJson({'id': 't1'}).title, 'New chat');
      expect(ScoutThread.fromJson({'id': 't1', 'title': '   '}).title, 'New chat');
      expect(ScoutThread.fromJson({'id': 't1', 'title': '  Book F-11  '}).title, 'Book F-11');
    });

    test('archived is read from either spelling the two routes use', () {
      expect(ScoutThread.fromJson({'archived_at': '2026-09-01T10:00:00Z'}).archived, isTrue);
      expect(ScoutThread.fromJson({'archivedAt': '2026-09-01T10:00:00Z'}).archived, isTrue);
      expect(ScoutThread.fromJson({'archived_at': null}).archived, isFalse);
      expect(ScoutThread.fromJson({}).archived, isFalse);
    });

    test('the persona falls back to Scout so a row always has a name', () {
      expect(ScoutThread.fromJson({}).persona, 'Scout');
      expect(ScoutThread.fromJson({'assistant_persona': 'Coach'}).persona, 'Coach');
      expect(ScoutThread.fromJson({'persona': 'Coach'}).persona, 'Coach');
    });

    test('a thread with no messages sorts by its creation time', () {
      final t = ScoutThread.fromJson({
        'id': 't1',
        'created_at': '2026-09-01T10:00:00Z',
      });
      expect(t.lastMessageAt, isNotNull);
      expect(t.lastMessageAt!.toUtc(), DateTime.utc(2026, 9, 1, 10));
      expect(t.messageCount, 0);
      expect(t.preview, isNull);
    });

    test('the count arrives as a pg string and the preview under either key', () {
      expect(ScoutThread.fromJson({'message_count': '14'}).messageCount, 14);
      expect(ScoutThread.fromJson({'messageCount': 14}).messageCount, 14);
      expect(
        ScoutThread.fromJson({'last_message_preview': 'Two grounds free'}).preview,
        'Two grounds free',
      );
    });
  });

  group('ScoutHistoryPage', () {
    test('the first page restores the title and the dialog state', () {
      final p = ScoutHistoryPage.fromJson({
        'thread': {'title': 'Book F-11'},
        'state': {'fsm': 'awaiting_confirm'},
        'messages': [
          {'id': 'm1', 'role': 'user', 'text': 'book it'},
          {'id': 'm2', 'role': 'scout', 'text': 'Confirm?'},
        ],
        'hasMore': true,
        'cursor': 'm1',
      });
      expect(p.title, 'Book F-11');
      expect(p.fsm, ScoutFsm.awaitingConfirm);
      expect(p.fsm.isWaiting, isTrue,
          reason: 'a chat reopened mid-booking must still be waiting on the user');
      expect(p.messages.length, 2);
      expect(p.hasMore, isTrue);
      expect(p.cursor, 'm1');
    });

    test('hasMore requires a literal true, so no empty page is fetched', () {
      expect(ScoutHistoryPage.fromJson({'hasMore': 'true'}).hasMore, isFalse);
      expect(ScoutHistoryPage.fromJson({}).hasMore, isFalse);
      expect(ScoutHistoryPage.fromJson({}).cursor, isNull);
    });

    test('non-map rows are skipped and a missing block yields no messages', () {
      final p = ScoutHistoryPage.fromJson({
        'messages': [
          {'id': 'm1', 'role': 'user'},
          'garbage',
          null,
        ],
      });
      expect(p.messages.length, 1);
      expect(ScoutHistoryPage.fromJson({'messages': 'none'}).messages, isEmpty);
    });

    test('the pre-read default is an idle, empty, unpaged conversation', () {
      const p = ScoutHistoryPage.empty;
      expect(p.messages, isEmpty);
      expect(p.hasMore, isFalse);
      expect(p.cursor, isNull);
      expect(p.title, isNull);
      expect(p.fsm, ScoutFsm.idle);
    });
  });

  group('ScoutCapability', () {
    test('an ungrouped ability files under More rather than under nothing', () {
      final c = ScoutCapability.fromJson({'action': 'find_venue', 'label': 'Find a ground'});
      expect(c.group, 'More');
      expect(c.gloss, '');
    });

    test('an ability with no action or no label is dropped, never drawn dead', () {
      final all = ScoutCapability.listFrom([
        {'action': 'find_venue', 'label': 'Find a ground', 'group': 'Booking'},
        {'action': '', 'label': 'Nothing'},
        {'action': 'help', 'label': ''},
        'garbage',
        null,
      ]);
      expect(all.length, 1);
      expect(all.single.action, 'find_venue');
    });

    test('a non-list capabilities block yields nothing', () {
      expect(ScoutCapability.listFrom(null), isEmpty);
      expect(ScoutCapability.listFrom('find_venue'), isEmpty);
    });

    test('grouped keeps the backend declaration order, not alphabetical order', () {
      final groups = ScoutCapability.grouped(ScoutCapability.listFrom([
        {'action': 'find_venue', 'label': 'Find a ground', 'group': 'Booking'},
        {'action': 'my_teams', 'label': 'My teams', 'group': 'Teams'},
        {'action': 'my_bookings', 'label': 'My bookings', 'group': 'Booking'},
      ]));
      expect(groups.map((g) => g.group).toList(), ['Booking', 'Teams']);
      expect(groups.first.items.map((c) => c.action).toList(),
          ['find_venue', 'my_bookings']);
      expect(groups.last.items.single.action, 'my_teams');
    });

    test('grouping nothing yields no headings', () {
      expect(ScoutCapability.grouped(const []), isEmpty);
    });
  });
}
