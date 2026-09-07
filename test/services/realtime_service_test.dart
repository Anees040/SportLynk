// RealtimeService: the parts of the socket that hold when there is no socket.
//
// A live Socket.IO connection cannot be opened from a unit test — there is no server
// and no event loop willing to wait for one — so what is pinned here is the contract
// every chat, team and notification screen leans on while disconnected. Those screens
// call `joinChannel`, `markRead` and `sendTyping` from `initState` and from stream
// callbacks, on a phone that may have lost signal a second earlier. Each of those
// calls goes through `_socket?.emit`, and the null-aware operator is the whole
// safety net: if any of them threw when the socket were absent, a lost connection
// would take the screen down with it rather than degrading to "no live updates".
//
// The broadcast streams matter for the same reason. A screen subscribes on open and
// cancels on close while the socket stays up for the rest of the app, so each stream
// has to accept a second listener after the first has gone. A single-subscription
// controller would throw on the second chat screen a user opened.
//
// [ApiConstants.socketUrl] is asserted here rather than beside the REST constants
// because it is the socket's own target and the one that has been wrong before:
// engine.io mounts at the server root, so the socket connects to the bare origin
// while every REST call goes under `/api`. Deriving it from [ApiConstants.baseUrl]
// is what keeps the two from drifting apart, and "chat will not connect but REST
// works" is what it looks like when they do.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/api_constants.dart';
import 'package:sportlynk/services/realtime_service.dart';

void main() {
  late RealtimeService rt;

  setUp(() => rt = RealtimeService());

  group('the connect target', () {
    test('the socket origin drops the REST prefix', () {
      expect(ApiConstants.baseUrl.endsWith('/api'), isTrue);
      expect(ApiConstants.socketUrl, ApiConstants.baseUrl.replaceFirst(RegExp(r'/api$'), ''));
      expect(ApiConstants.socketUrl.endsWith('/api'), isFalse);
      expect(ApiConstants.socketUrl, isNotEmpty);
    });
  });

  group('one socket for the whole app', () {
    // Every screen constructs its own `RealtimeService()`; they have to be the same
    // connection, or the second chat screen opens a second socket.
    test('the service is the same instance wherever it is constructed', () {
      expect(RealtimeService(), same(rt));
      expect(RealtimeService(), same(RealtimeService()));
    });

    test('nothing is connected before a token is supplied', () {
      expect(rt.isConnected, isFalse);
    });

    // An empty token is the signed-out state, and the handshake would be rejected
    // anyway. It is refused here so a logged-out app never opens a socket at all.
    test('an empty token opens nothing', () {
      rt.ensureConnected('');
      expect(rt.isConnected, isFalse);
    });
  });

  // These are called from `initState` and from stream callbacks on a phone that may
  // have lost signal a moment earlier. A throw here would take the screen down.
  group('sending while disconnected', () {
    test('joining and leaving a channel are no-ops without a socket', () {
      expect(() => rt.joinChannel('c1'), returnsNormally);
      expect(() => rt.leaveChannel('c1'), returnsNormally);
      expect(rt.isConnected, isFalse);
    });

    test('a typing signal is dropped rather than raised', () {
      expect(() => rt.sendTyping('c1', true), returnsNormally);
      expect(() => rt.sendTyping('c1', false), returnsNormally);
    });

    test('a read watermark is dropped rather than raised', () {
      expect(() => rt.markRead('c1'), returnsNormally);
    });

    // Logout runs this whether or not a socket was ever opened.
    test('disconnecting a service that never connected is safe', () {
      expect(rt.disconnect, returnsNormally);
      expect(rt.isConnected, isFalse);
    });
  });

  // A screen subscribes on open and cancels on close; the socket outlives both. Each
  // stream therefore has to take a second listener after the first has gone.
  group('the event streams', () {
    test('every stream accepts a listener, a cancel, and another listener', () async {
      final streams = <String, Stream<Object?>>{
        'messages': rt.messages,
        'receipts': rt.receipts,
        'typing': rt.typing,
        'presence': rt.presence,
        'teamUpdates': rt.teamUpdates,
        'teamRequests': rt.teamRequests,
        'matchUpdates': rt.matchUpdates,
        'notifications': rt.notifications,
        'connection': rt.connection,
      };
      for (final entry in streams.entries) {
        expect(entry.value.isBroadcast, isTrue, reason: entry.key);
        final first = entry.value.listen((_) {});
        await first.cancel();
        final second = entry.value.listen((_) {});
        await second.cancel();
      }
    });

    test('two screens can hold the same stream at once', () async {
      final a = rt.messages.listen((_) {});
      final b = rt.messages.listen((_) {});
      await a.cancel();
      await b.cancel();
    });
  });
}
