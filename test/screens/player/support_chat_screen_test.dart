// The support chat surface, tested where it differs from the Scout tab it reuses.
//
// SupportChatScreen is not a second assistant — it drives the same
// AssistantController as the Scout tab, so the transcript rendering, the idempotent
// turns and the retry-on-failure are the controller's and the shared widgets'
// contracts, tested where they live and not re-asserted here.
//
// What is worth pinning is the handful of choices that make this a *support* surface
// rather than that tab: it opens clean (started with loadHistory:false, so it fetches
// capabilities and the classifier probe but never the thread list or a transcript),
// it seeds four server-executed topic chips that answer even with the intent model
// down, it names the offline state plainly, and it never leaves a signed-out player
// without the human route.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/support_chat_screen.dart';

import '../screen_harness.dart';

void main() {
  late FakeApi api;

  // The two calls a clean open makes. Stubbed on every test that reaches the loaded
  // state, so the surface is exercised against real answers rather than 404s.
  void stubOpen({bool nluReady = true}) {
    api.ok('/assistant/capabilities', {'capabilities': <Object>[]});
    api.ok('/assistant/health', {
      'nlu': {'ready': nluReady},
    });
  }

  // A minimal successful turn: a policy answer with no cards, enough for the reply to
  // render as a bubble.
  void stubTurn() {
    api.ok('/assistant/message', {
      'threadId': 't-1',
      'messageId': 'm-1',
      'reply': {
        'text': 'Cancellations more than 24 hours ahead are refunded in full.',
        'source': 'policy',
      },
      'state': {'fsm': 'idle'},
    });
  }

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('when it opens signed in', () {
    testWidgets('it lands on the support empty state, not a spinner',
        (tester) async {
      stubOpen();
      await pumpScreen(tester, const SupportChatScreen());
      await settleData(tester);

      expect(find.text('How can we help?'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('it opens clean — no thread list, no transcript fetched',
        (tester) async {
      // A support chat must not drop the player into their last half-finished booking
      // conversation, so it starts with loadHistory:false. Capabilities and the
      // classifier probe are the only calls; the thread list and any /messages page
      // are never read.
      stubOpen();
      await pumpScreen(tester, const SupportChatScreen());
      await settleData(tester);

      expect(api.countTo('/assistant/capabilities'), 1);
      expect(api.countTo('/assistant/health'), 1);
      expect(api.countTo('/assistant/threads'), 0);
      expect(api.to('/messages'), isEmpty);
    });

    testWidgets('it offers the four support topics as openers', (tester) async {
      // These are the surface's reason to exist: server-executed actions that answer
      // without the intent model, so a player can self-serve even when it is down.
      stubOpen();
      await pumpScreen(tester, const SupportChatScreen());
      await settleData(tester);

      expect(find.text('Cancellations & refunds'), findsOneWidget);
      expect(find.text('Topping up my wallet'), findsOneWidget);
      expect(find.text('Check my bookings'), findsOneWidget);
      expect(find.text('What can Scout help with?'), findsOneWidget);
    });

    testWidgets('it says plainly that Scout is not a person', (tester) async {
      // The human route is the mail icon; this surface must not let a player believe
      // opening it reached a person.
      stubOpen();
      await pumpScreen(tester, const SupportChatScreen());
      await settleData(tester);

      expect(find.textContaining('not a person'), findsWidgets);
    });
  });

  group('a support topic', () {
    testWidgets('posts its action to /assistant/message, not typed text',
        (tester) async {
      // A chip carries an action the server runs directly, so model #4 never sees it.
      // That is what makes the topic work with the classifier offline, and why the
      // POST must carry the action rather than the label as free text.
      stubOpen();
      stubTurn();
      await pumpScreen(tester, const SupportChatScreen());
      await settleData(tester);

      await tester.tap(find.text('Cancellations & refunds'));
      await settleData(tester);

      final posts = api.to('/assistant/message');
      expect(posts, hasLength(1));
      expect(posts.single.body, contains('"action"'));
      expect(posts.single.body, contains('refund_policy'));
    });

    testWidgets('renders the answer it gets back', (tester) async {
      stubOpen();
      stubTurn();
      await pumpScreen(tester, const SupportChatScreen());
      await settleData(tester);

      await tester.tap(find.text('Cancellations & refunds'));
      await settleData(tester);

      expect(find.textContaining('refunded in full'), findsOneWidget);
    });
  });

  group('when the classifier is offline', () {
    testWidgets('it names the outage and keeps the topics reachable',
        (tester) async {
      // The degradation is otherwise invisible: with the model down every typed
      // sentence gets the capability menu, which looks identical to an assistant that
      // simply cannot help. Naming it is the difference between degraded and broken.
      stubOpen(nluReady: false);
      await pumpScreen(tester, const SupportChatScreen());
      await settleData(tester);

      expect(
        find.textContaining('its language model is offline'),
        findsOneWidget,
      );
      // A chip needs no model to run, so the topics stay on screen through the outage.
      expect(find.text('Cancellations & refunds'), findsOneWidget);
    });
  });

  group('without a session', () {
    testWidgets('it guards rather than throwing, and still offers a human',
        (tester) async {
      // Reachable from a signed-out state, where a token read would throw before first
      // paint. The guard has to stand in for the controller and still name the email
      // route, since a signed-out player is the one most likely to be locked out.
      await pumpScreen(
        tester,
        const SupportChatScreen(),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(find.text('Sign in to use support chat'), findsOneWidget);
      expect(find.text('Email support'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('it makes no request with no token', (tester) async {
      // No controller is created without a token, so the two open calls must not fire.
      await pumpScreen(
        tester,
        const SupportChatScreen(),
        auth: FakeAuth(token: null),
      );
      await settleData(tester);

      expect(api.requests, isEmpty);
    });
  });
}
