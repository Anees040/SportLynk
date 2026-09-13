// Scout, the in-app assistant, on its own screen. The screen builds an
// `AssistantController` on mount (it needs `AuthProvider.token`, which `FakeAuth`
// supplies) and calls `start()`, which reads the user's thread list and, if an open
// thread exists, its most recent transcript. A single boot spinner covers that; the
// screen then resolves to one of two shapes — the seed "Ask Scout" screen when the
// account has no open chat, or the transcript when it does.
//
// One behaviour is worth pinning because it is deliberate rather than accidental:
// `AssistantService.threads` and `.history` both swallow a failed read (they return
// an empty list / an empty page rather than throwing), so a thread-list that 500s
// does not strand the user on an error — it opens a usable, empty chat. The test
// below asserts that degrade rather than a non-existent error state.
//
// Animation and timer note: the only forever-animating parts of this screen — the
// `ScoutTyping` bubble and the "thinking" avatar, each holding a repeating controller
// and, for typing, two escalation timers — appear only while `controller.busy` is
// true, i.e. mid-turn. No test here sends a turn, so none reaches that state and none
// needs to unmount. `pumpAndSettle` is still avoided: the boot spinner is a
// `CircularProgressIndicator` and would hang it until the reads resolve, so every test
// drives the boot with explicit pumps (`settleData`).
//
// Mount note: the fake keys on the path, so `/assistant/threads` answers the list GET
// regardless of its `limit` query, `/assistant/threads/th-1/messages` the history GET,
// and `/assistant/capabilities` the fire-and-forget help-sheet fetch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/assistant_screen.dart';

import '../screen_harness.dart';

/// The thread list, one thread's transcript, and the capability list, path-keyed.
const String kThreads = '/assistant/threads';
const String kHistory = '/assistant/threads/th-1/messages';
const String kCapabilities = '/assistant/capabilities';

/// One row of `GET /assistant/threads`, in the snake_case that endpoint emits. No
/// `archived_at`, so `ScoutThread.archived` is false and `start()` treats it as an
/// open chat to reopen.
Map<String, dynamic> threadRow({String id = 'th-1', String title = 'Booking help'}) =>
    {
      'id': id,
      'title': title,
      'last_message_at': DateTime.now().toIso8601String(),
      'created_at': DateTime.now().toIso8601String(),
      'message_count': 2,
    };

/// The `data` block the thread-list GET returns; `threads` is the only key read.
Map<String, dynamic> threadsData({List<Map<String, dynamic>> threads = const []}) =>
    {'threads': threads};

/// The `data` block `ScoutHistoryPage.fromJson` reads: the thread's title and FSM
/// travel with the first page, then a short user/Scout exchange. The Scout row carries
/// a `payload` so it rebuilds a real `ScoutReply` (a `live` source draws its pill).
Map<String, dynamic> historyData({String title = 'Booking help'}) => {
      'thread': {'title': title},
      'state': {'fsm': 'idle'},
      'messages': [
        {
          'id': 'msg-1',
          'role': 'user',
          'text': 'What can you do?',
          'createdAt': DateTime.now().toIso8601String(),
        },
        {
          'id': 'msg-2',
          'role': 'scout',
          'text': 'I can book grounds and check your wallet.',
          'createdAt': DateTime.now().toIso8601String(),
          'payload': {
            'text': 'I can book grounds and check your wallet.',
            'source': 'live',
            'chips': const [],
            'cards': const [],
          },
        },
      ],
      'hasMore': false,
      'cursor': null,
    };

/// The capability list is fetched unawaited on boot and only feeds the help sheet; an
/// empty list keeps that fetch quiet so it never repaints during a boot assertion.
Map<String, dynamic> capabilitiesData() => {'capabilities': const []};

Future<RouteLog> pumpAssistant(WidgetTester tester, {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    const AssistantScreen(),
    auth: FakeAuth(
        role: 'player', id: 'u-1', name: 'Bilal Ahmed', token: 'test-token'),
    textScale: textScale,
  );
}

/// `start()` chains up to two reads — the thread list, then the transcript of the
/// open thread it finds. One `settleData` drains the first; a second drains the one
/// it schedules. The empty-account path only makes the first read, but the extra
/// pumps are harmless.
Future<void> settleBoot(WidgetTester tester) async {
  await settleData(tester);
  await settleData(tester);
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // Default: an account with no open chat, so the screen resolves to the seed
    // screen. Individual tests override the thread list to load a transcript.
    api.ok(kThreads, threadsData());
    api.ok(kCapabilities, capabilitiesData());
  });

  group('the assistant as it boots', () {
    testWidgets('a spinner stands while the boot read is in flight',
        (tester) async {
      api.ok(kThreads, threadsData(), delay: const Duration(milliseconds: 300));
      await pumpAssistant(tester);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      await settleData(tester);
      expect(find.text('Ask Scout'), findsOneWidget); // the seed heading
    });

    testWidgets('an empty account opens to the seed screen', (tester) async {
      await pumpAssistant(tester);
      await settleBoot(tester);

      expect(find.text('Scout'), findsOneWidget); // app-bar title, no thread yet
      expect(find.text('Ask Scout'), findsOneWidget); // the seed heading
      expect(find.text('Find a ground'), findsOneWidget); // a seed chip
      expect(find.byType(TextField), findsOneWidget); // the composer
      expect(find.bySemanticsLabel('Send'), findsOneWidget); // the send button
    });

    testWidgets('a failed thread list still opens a usable chat', (tester) async {
      // The service swallows the failure and returns an empty list, so boot lands on
      // the seed screen rather than an error state — the deliberate degrade.
      api.fail(kThreads, 'boom');
      await pumpAssistant(tester);
      await settleBoot(tester);

      expect(find.text('Ask Scout'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  group('a prior conversation', () {
    testWidgets('loads its transcript and titles the bar', (tester) async {
      api.ok(kThreads, threadsData(threads: [threadRow()]));
      api.ok(kHistory, historyData());
      await pumpAssistant(tester);
      await settleBoot(tester);

      expect(find.text('Booking help'), findsOneWidget); // title from the thread
      expect(find.text('What can you do?'), findsOneWidget); // the user bubble
      expect(find.text('I can book grounds and check your wallet.'),
          findsOneWidget); // Scout's reply
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the seed heading present',
        (tester) async {
      ignoreOverflow();
      await pumpAssistant(tester, textScale: 2.0);
      await settleBoot(tester);

      expect(find.text('Ask Scout'), findsOneWidget);
    });
  });
}
