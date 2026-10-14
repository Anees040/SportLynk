import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_message.dart';
import 'package:sportlynk/providers/chat_controller.dart';

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);
final _t = DateTime.utc(2026, 10, 12, 9, 0);
final _after = DateTime.utc(2026, 10, 12, 9, 5);

ChatMessage _mine({bool pending = false, bool failed = false, String sender = 'me'}) =>
    ChatMessage.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'sender_id': sender,
      'kind': 'text',
      'body': 'hi',
      'created_at': _t.toIso8601String(),
      'pending': pending,
      'failed': failed,
    });

ChatMember _member(String id, {String? historyFrom}) => ChatMember.fromJson({
      'user_id': id,
      'name': id.toUpperCase(),
      'history_from': ?historyFrom,
    });

void main() {
  group('computeMessageReceipts', () {
    test('classifies each recipient by its watermark against the sent time', () {
      final out = computeMessageReceipts(
        members: [_member('me'), _member('a'), _member('b'), _member('c')],
        myUserId: 'me',
        read: {'a': _after},
        delivered: {'a': _after, 'b': _after},
        epoch: _epoch,
        message: _mine(),
      );
      final byId = {for (final r in out) r.userId: r.status};
      expect(byId['me'], isNull, reason: 'the sender is never a recipient of their own message');
      expect(byId['a'], ReceiptStatus.read);
      expect(byId['b'], ReceiptStatus.delivered);
      expect(byId['c'], ReceiptStatus.sent);
    });

    test('a member who joined after the message is not counted for it', () {
      final out = computeMessageReceipts(
        members: [_member('a'), _member('late', historyFrom: '2026-10-12T10:00:00Z')],
        myUserId: 'me',
        read: const {},
        delivered: const {},
        epoch: _epoch,
        message: _mine(),
      );
      expect(out.map((r) => r.userId), ['a']);
    });

    test('info is a sender view: another person\'s message yields nothing', () {
      expect(
        computeMessageReceipts(
          members: [_member('a')],
          myUserId: 'me',
          read: const {},
          delivered: const {},
          epoch: _epoch,
          message: _mine(sender: 'someone-else'),
        ),
        isEmpty,
      );
    });

    test('a message not yet sent (pending or failed) yields nothing', () {
      expect(
        computeMessageReceipts(
          members: [_member('a')],
          myUserId: 'me',
          read: const {},
          delivered: const {},
          epoch: _epoch,
          message: _mine(pending: true),
        ),
        isEmpty,
      );
    });
  });
}
