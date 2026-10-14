import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/providers/chat_controller.dart';

void main() {
  group('chatCacheKey', () {
    test('is scoped to the user, so a shared device never leaks a channel cache',
        () {
      final a = chatCacheKey('user-a', 'chan-1');
      final b = chatCacheKey('user-b', 'chan-1');
      expect(a, isNot(b), reason: 'two accounts must not share one channel cache');
      expect(a, contains('user-a'));
      expect(a, contains('chan-1'));
    });

    test('still differs by channel for a single user', () {
      expect(chatCacheKey('u', 'c1'), isNot(chatCacheKey('u', 'c2')));
    });
  });
}
