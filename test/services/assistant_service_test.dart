// AssistantService: the two input modes of Scout's single endpoint, and the
// idempotency key that keeps a booking turn from being executed twice.
//
// One endpoint, two shapes. `POST /assistant/message` is the only turn route, and
// the body says which kind of turn it is: `text` runs the intent classifier, while
// `action` (plus `args`) is a chip press the server executes without classifying.
// The screen has no branch for "button or sentence", so a service that dropped the
// `action` key would silently reroute every chip through a model that has no label
// for half of them.
//
// `client_id` is required rather than optional because a booking turn moves money. On
// a flaky connection the app cannot tell "the request never arrived" from "the reply
// never came back", and retrying the second case would book twice; the server
// recognises a repeated `client_id` and returns the original turn. The key is
// therefore the CALLER's to hold across retries, which is why `newClientId` is a
// separate static and is asserted here as stable per call rather than per send.
//
// A failed turn still has to draw a bubble. `ScoutTurn.fromEnvelope` substitutes
// `ScoutReply.offline` — carrying a "Try again" chip — when the reply block is
// missing, so the transport-failure cases below assert a renderable reply rather than
// a null one.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/services/assistant_service.dart';

import 'http_seam.dart';

void main() {
  late FakeApi api;
  late AssistantService service;

  setUp(() {
    api = FakeApi();
    service = AssistantService();
  });

  tearDown(resetApiClient);

  group('the idempotency key', () {
    test('two keys generated in a row differ', () {
      final a = AssistantService.newClientId();
      final b = AssistantService.newClientId();
      expect(a, isNotEmpty);
      expect(a, isNot(b));
    });

    // The key is base-36 throughout: a millisecond stamp followed by 32 bits of
    // randomness, so it stays URL- and log-safe with no separator to escape.
    test('a key is base-36 text with nothing needing escaping', () {
      expect(AssistantService.newClientId(), matches(RegExp(r'^[0-9a-z]+$')));
    });

    test('the service never invents a key of its own for a send', () async {
      api.ok(const {});
      await api.run(() => service.send('JWT', text: 'hi', clientId: 'held-by-caller'));
      expect(api.body()['client_id'], 'held-by-caller');
    });
  });

  group('sending a typed message', () {
    test('a typed turn sends the trimmed text and the key', () async {
      api.ok({
        'threadId': 'th1',
        'reply': {'text': 'Arena One has 18:00 free.', 'source': 'live'},
      });
      final turn = await api.run(
        () => service.send('JWT', text: '  courts near me  ', clientId: 'c1'),
      );
      expect(api.method(), 'POST');
      expect(api.endpoint(), '/assistant/message');
      expect(api.body(), {'text': 'courts near me', 'client_id': 'c1'});
      expect(turn.ok, isTrue);
      expect(turn.threadId, 'th1');
      expect(turn.reply.text, 'Arena One has 18:00 free.');
      expect(turn.reply.source, ScoutSource.live);
    });

    // A whitespace-only message would otherwise reach the classifier as an empty
    // string, which the route rejects with a message no user caused.
    test('a blank message is not sent as a text key', () async {
      api.ok(const {});
      await api.run(() => service.send('JWT', text: '   ', clientId: 'c1'));
      expect(api.body(), {'client_id': 'c1'});
    });

    test('the thread id travels as session_id, the name the route reads', () async {
      api.ok(const {});
      await api.run(() => service.send('JWT', text: 'hi', threadId: 'th1', clientId: 'c1'));
      expect(api.body()['session_id'], 'th1');
      expect(api.body().containsKey('threadId'), isFalse);
    });

    test('an empty thread id is omitted so the server opens a new thread', () async {
      api.ok(const {});
      await api.run(() => service.send('JWT', text: 'hi', threadId: '', clientId: 'c1'));
      expect(api.body().containsKey('session_id'), isFalse);
    });
  });

  group('sending a chip press', () {
    // A chip carries an executable action, so the server skips the classifier
    // entirely; that is what keeps capabilities outside the trained label set
    // reachable.
    test('a chip sends its action and args, with no text at all', () async {
      api.ok(const {});
      await api.run(() => service.send(
            'JWT',
            action: 'book_slot',
            args: {'venueId': 'v1', 'slotId': 's3'},
            threadId: 'th1',
            clientId: 'c1',
          ));
      expect(api.body(), {
        'action': 'book_slot',
        'args': {'venueId': 'v1', 'slotId': 's3'},
        'session_id': 'th1',
        'client_id': 'c1',
      });
    });

    test('an empty args map is omitted rather than sent as an empty object', () async {
      api.ok(const {});
      await api.run(
        () => service.send('JWT', action: 'show_help', args: const {}, clientId: 'c1'),
      );
      expect(api.body(), {'action': 'show_help', 'client_id': 'c1'});
    });
  });

  group('the turn a reply comes back as', () {
    test('the dialog state, the classifier verdict and the timing all survive', () async {
      api.ok({
        'threadId': 'th1',
        'threadCreated': true,
        'messageId': 'msg9',
        'reply': {
          'text': 'Which slot?',
          'source': 'live',
          'chips': [
            {'label': '18:00', 'action': 'pick_slot', 'args': {'slotId': 's3'}},
          ],
          'cards': [
            {'type': 'slot_picker', 'data': {'venueId': 'v1'}},
          ],
        },
        'state': {
          'fsm': 'awaiting_choice',
          'pending': 'slotId',
          'intent': 'book_venue',
          'slots': {'venueId': 'v1'},
        },
        'nlu': {'intent': 'book_venue', 'confidence': 0.94, 'via': 'model'},
        'totalMs': '412',
      });
      final turn = await api.run(() => service.send('JWT', text: 'book', clientId: 'c1'));
      expect(turn.threadCreated, isTrue);
      expect(turn.messageId, 'msg9');
      expect(turn.fsm, ScoutFsm.awaitingChoice);
      expect(turn.fsm.isWaiting, isTrue);
      expect(turn.pending, 'slotId');
      expect(turn.intent, 'book_venue');
      expect(turn.slots, {'venueId': 'v1'});
      expect(turn.nlu!.confidence, 0.94);
      expect(turn.totalMs, 412);
      expect(turn.reply.chips.single.action, 'pick_slot');
      expect(turn.reply.cardOfType('slot_picker'), isNotNull);
    });

    // An unrecognised source is reported as unknown rather than guessed at, because
    // the pill answers "did the model do this or is it hard-coded?" per message.
    test('a source this app version does not know is unknown, not defaulted', () async {
      api.ok({
        'reply': {'text': 'x', 'source': 'something_new'},
      });
      final turn = await api.run(() => service.send('JWT', text: 'x', clientId: 'c1'));
      expect(turn.reply.source, ScoutSource.unknown);
    });

    // A dropped connection must still draw a bubble with a way forward, so the reply
    // falls back to the offline form and keeps the server message as its text.
    test('a transport failure still yields a renderable reply with a retry chip', () async {
      api.offline();
      final turn = await api.run(() => service.send('JWT', text: 'x', clientId: 'c1'));
      expect(turn.ok, isFalse);
      expect(turn.reply.text, isNotEmpty);
      expect(turn.reply.chips.single.action, 'retry_last');
      expect(turn.reply.source, ScoutSource.unknown);
    });

    test('a rejected turn keeps the server sentence as the bubble text', () async {
      api.fail('Scout is busy. Try again in a moment.', status: 429);
      final turn = await api.run(() => service.send('JWT', text: 'x', clientId: 'c1'));
      expect(turn.ok, isFalse);
      expect(turn.message, 'Scout is busy. Try again in a moment.');
      expect(turn.reply.text, 'Scout is busy. Try again in a moment.');
    });

    test('an idle state is the default when the server sends none', () async {
      api.ok({
        'reply': {'text': 'x'},
      });
      final turn = await api.run(() => service.send('JWT', text: 'x', clientId: 'c1'));
      expect(turn.fsm, ScoutFsm.idle);
      expect(turn.fsm.isWaiting, isFalse);
      expect(turn.slots, isEmpty);
      expect(turn.nlu, isNull);
    });
  });

  group('threads', () {
    test('the drawer read asks for a page size and no archived rows', () async {
      api.ok({'threads': const []});
      await api.run(() => service.threads('JWT'));
      expect(api.endpoint(), '/assistant/threads?limit=30');
      expect(api.query(), {'limit': '30'});
    });

    test('archived rows are asked for explicitly', () async {
      api.ok({'threads': const []});
      await api.run(() => service.threads('JWT', includeArchived: true, limit: 10));
      expect(api.query(), {'archived': '1', 'limit': '10'});
    });

    // The row is snake_case here, unlike the camelCase reads elsewhere in the app;
    // both spellings are accepted by the model and both are asserted.
    test('a row is read under either casing, and archived is derived', () async {
      api.ok({
        'threads': [
          {
            'id': 'th1',
            'title': '  Friday game  ',
            'archived_at': '2026-03-14T18:30:00.000Z',
            'assistant_persona': 'Scout',
            'last_message_preview': 'Booked.',
            'message_count': '12',
          },
          {'id': 'th2', 'preview': 'Hello', 'messageCount': 3},
        ],
      });
      final threads = await api.run(() => service.threads('JWT'));
      expect(threads.first.title, 'Friday game');
      expect(threads.first.archived, isTrue);
      expect(threads.first.messageCount, 12);
      expect(threads.first.preview, 'Booked.');
      expect(threads.last.archived, isFalse);
      expect(threads.last.messageCount, 3);
    });

    test('an untitled thread reads as New chat rather than as blank', () async {
      api.ok({
        'threads': [
          {'id': 'th1', 'title': '   '},
        ],
      });
      expect((await api.run(() => service.threads('JWT'))).single.title, 'New chat');
    });

    // A row with no id cannot be opened, so it is dropped rather than drawn as a
    // tappable line that leads nowhere.
    test('a row with no id is dropped from the drawer', () async {
      api.ok({
        'threads': [
          {'title': 'Ghost'},
          {'id': 'th1'},
        ],
      });
      expect((await api.run(() => service.threads('JWT'))).map((t) => t.id), ['th1']);
    });

    test('a failure and a wrong-typed block are both an empty drawer', () async {
      api.fail('Unauthorised.', status: 401);
      expect(await api.run(() => service.threads('JWT')), isEmpty);

      final wrong = FakeApi()..ok({'threads': 'not a list'});
      expect(await wrong.run(() => service.threads('JWT')), isEmpty);
    });

    test('a new chat is a POST, with the title trimmed or omitted', () async {
      api.ok(const {});
      await api.run(() async {
        await service.createThread('JWT', title: '  Friday game  ');
        await service.createThread('JWT', title: '   ');
        await service.createThread('JWT');
      });
      expect(api.method(0), 'POST');
      expect(api.endpoint(0), '/assistant/threads');
      expect(api.body(0), {'title': 'Friday game'});
      expect(api.body(1), isEmpty);
      expect(api.body(2), isEmpty);
    });

    // The thread cap's 409 sentence is the instruction the user has to follow, so the
    // envelope is returned whole rather than reduced to false.
    test('hitting the thread cap returns the sentence that says what to do', () async {
      api.fail('You have too many chats. Archive one to start another.', status: 409);
      final r = await api.run(() => service.createThread('JWT'));
      expect(r['success'], isFalse);
      expect(r['message'], 'You have too many chats. Archive one to start another.');
      expect(r['statusCode'], 409);
    });

    test('a rename and an archive are both a PATCH on the thread', () async {
      api.ok(const {});
      await api.run(() async {
        await service.updateThread('JWT', 'th1', title: 'Friday game');
        await service.updateThread('JWT', 'th1', archived: true);
        await service.updateThread('JWT', 'th1', title: 'Both', archived: false);
      });
      expect(api.method(0), 'PATCH');
      expect(api.endpoint(0), '/assistant/threads/th1');
      expect(api.body(0), {'title': 'Friday game'});
      expect(api.body(1), {'archived': true});
      expect(api.body(2), {'title': 'Both', 'archived': false});
    });

    test('an update with neither key sends an empty body', () async {
      api.ok(const {});
      await api.run(() => service.updateThread('JWT', 'th1'));
      expect(api.body(), isEmpty);
    });

    test('a delete is addressed at the thread', () async {
      api.ok(const {});
      await api.run(() => service.deleteThread('JWT', 'th1'));
      expect(api.method(), 'DELETE');
      expect(api.endpoint(), '/assistant/threads/th1');
    });
  });

  group('history', () {
    test('the first page asks for a size and carries no cursor', () async {
      api.ok(const {'messages': []});
      await api.run(() => service.history('JWT', 'th1'));
      expect(api.endpoint(), '/assistant/threads/th1/messages?limit=40');
      expect(api.query(), {'limit': '40'});
    });

    // The cursor is an opaque message id, not a timestamp: two messages in one turn
    // share a `created_at` to the microsecond, so paging by time drops or repeats one.
    test('a cursor is sent as before, verbatim', () async {
      api.ok(const {'messages': []});
      await api.run(() => service.history('JWT', 'th1', before: 'msg9', limit: 20));
      expect(api.query(), {'limit': '20', 'before': 'msg9'});
    });

    test('an empty cursor is dropped', () async {
      api.ok(const {'messages': []});
      await api.run(() => service.history('JWT', 'th1', before: ''));
      expect(api.query().containsKey('before'), isFalse);
    });

    // The thread's title and dialog state ride with the page, so a chat reopened
    // mid-booking restores its confirm prompt instead of looking idle.
    test('the page restores the title and the dialog state', () async {
      api.ok({
        'messages': [
          {'id': 'm1', 'is_assistant': false, 'text': 'book friday'},
          {
            'id': 'm2',
            'is_assistant': true,
            'reply': {'text': 'Confirm?', 'source': 'live'},
          },
        ],
        'hasMore': true,
        'cursor': 'm1',
        'thread': {'title': 'Friday game'},
        'state': {'fsm': 'awaiting_confirm'},
      });
      final page = await api.run(() => service.history('JWT', 'th1'));
      expect(page.messages.length, 2);
      expect(page.hasMore, isTrue);
      expect(page.cursor, 'm1');
      expect(page.title, 'Friday game');
      expect(page.fsm, ScoutFsm.awaitingConfirm);
    });

    test('a failure is the empty page', () async {
      api.offline();
      final page = await api.run(() => service.history('JWT', 'th1'));
      expect(page.messages, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.cursor, isNull);
      expect(page.fsm, ScoutFsm.idle);
    });
  });

  group('feedback and capabilities', () {
    test('a vote is normalised to 1 or -1, whatever number is passed', () async {
      api.ok(const {});
      await api.run(() async {
        await service.vote('JWT', 'msg9', 1);
        await service.vote('JWT', 'msg9', -5);
        await service.vote('JWT', 'msg9', 0);
      });
      expect(api.endpoint(0), '/assistant/messages/msg9/feedback');
      expect(api.body(0), {'vote': 1});
      expect(api.body(1), {'vote': -1});
      expect(api.body(2), {'vote': 1});
    });

    test('a reason is trimmed, and a blank one is not sent', () async {
      api.ok(const {});
      await api.run(() async {
        await service.vote('JWT', 'msg9', -1, reason: '  wrong venue  ');
        await service.vote('JWT', 'msg9', -1, reason: '   ');
      });
      expect(api.body(0), {'vote': -1, 'reason': 'wrong venue'});
      expect(api.body(1), {'vote': -1});
    });

    test('a vote reports the envelope as a boolean, false when it failed', () async {
      api.ok(const {});
      expect(await api.run(() => service.vote('JWT', 'msg9', 1)), isTrue);

      final failing = FakeApi()..fail('Not your message.', status: 403);
      expect(await failing.run(() => service.vote('JWT', 'msg9', 1)), isFalse);
    });

    // The help sheet is built from the backend's own table so it can never advertise
    // an ability the server does not have.
    test('capabilities come from the server table, grouped as sent', () async {
      api.ok({
        'capabilities': [
          {'action': 'book_venue', 'label': 'Book a venue', 'group': 'Booking'},
          {'action': 'my_bookings', 'label': 'My bookings', 'group': 'Booking'},
          {'action': 'my_elo', 'label': 'My ELO', 'group': 'Teams'},
        ],
      });
      final caps = await api.run(() => service.capabilities('JWT'));
      expect(api.endpoint(), '/assistant/capabilities');
      expect(caps.length, 3);
      final grouped = ScoutCapability.grouped(caps);
      expect(grouped.map((g) => g.group), ['Booking', 'Teams']);
      expect(grouped.first.items.length, 2);
    });

    // A row without an executable action or a readable label cannot become a button,
    // so it is dropped rather than drawn as a dead one.
    test('a capability missing its action or its label is dropped', () async {
      api.ok({
        'capabilities': [
          {'label': 'No action'},
          {'action': 'no_label'},
          {'action': 'book_venue', 'label': 'Book a venue'},
        ],
      });
      final caps = await api.run(() => service.capabilities('JWT'));
      expect(caps.map((c) => c.action), ['book_venue']);
    });

    test('a failure is an empty capability list', () async {
      api.offline();
      expect(await api.run(() => service.capabilities('JWT')), isEmpty);
    });

    test('every assistant call carries the bearer token', () async {
      api.ok(const {});
      await api.run(() async {
        await service.send('JWT', text: 'hi', clientId: 'c1');
        await service.threads('JWT');
        await service.createThread('JWT');
        await service.history('JWT', 'th1');
        await service.updateThread('JWT', 'th1', archived: true);
        await service.deleteThread('JWT', 'th1');
        await service.vote('JWT', 'msg9', 1);
        await service.capabilities('JWT');
      });
      for (var i = 0; i < 8; i++) {
        expect(api.token(i), 'JWT', reason: 'request $i');
      }
    });
  });
}
