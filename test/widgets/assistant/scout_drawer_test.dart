// Scout's chat list, as the drawer of the chat screen.
//
// These cases moved here from `scout_sheets_test.dart` when the list stopped being a
// bottom sheet. The drive is different — a drawer is a widget inside a Scaffold rather
// than a route pushed by a function, so each test opens it through a ScaffoldState the
// way the app bar's button does — but what is asserted is the same, and deliberately so:
// the chat list is the app's only chat management, and the destructive half of it is
// what these tests spend their length on. Rename sends the new title and nothing else,
// archive sends the flag and nothing else, and delete asks first, because the sentence
// the confirmation carries ("any bookings you made in this chat are unaffected") is the
// only place the app says so.
//
// One case is new rather than ported. The sheet had no error state that could be
// reached: `AssistantService.threads` answered a failed request with an empty list, so a
// server that was down read as "no chats yet" and could not be retried. That is now a
// thrown `ScoutUnavailable` and a real error-with-retry, and it is tested here as
// behaviour rather than pinned as a defect.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/providers/assistant_controller.dart';
import 'package:sportlynk/widgets/assistant/scout_drawer.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../../services/http_seam.dart';
import '../widget_harness.dart';

/// One row of `GET /api/assistant/threads`.
Map<String, dynamic> thread({
  String id = 't1',
  String title = 'Refund question',
  String? preview = 'Where is my refund?',
  Duration ago = const Duration(hours: 3),
  int count = 6,
}) =>
    {
      'id': id,
      'title': title,
      'last_message_preview': preview,
      'last_message_at': DateTime.now().toUtc().subtract(ago).toIso8601String(),
      'message_count': count,
    };

void main() {
  tearDown(resetApiClient);

  /// Opens the drawer the way the app bar does, and returns the controller so a test can
  /// assert on what a row did to it.
  Future<AssistantController> openDrawer(WidgetTester tester,
      {double textScale = 1.0}) async {
    final controller = AssistantController(token: 'tok-1');
    addTearDown(controller.dispose);
    final scaffold = GlobalKey<ScaffoldState>();
    await pumpApp(
      tester,
      Scaffold(
        key: scaffold,
        backgroundColor: ScoutTheme.light.canvas,
        drawer: ScoutDrawer(controller: controller),
        body: const SizedBox.shrink(),
      ),
      textScale: textScale,
    );
    scaffold.currentState!.openDrawer();
    await tester.pump();
    return controller;
  }

  /// A drawer slides in over a quarter of a second, and a tap before it has landed hits
  /// the barrier rather than the row: every interaction test waits for the transition,
  /// while the loading-state tests deliberately do not.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('the list of chats', () {
    testWidgets('a spinner stands in until the list arrives', (tester) async {
      final api = FakeApi()..ok({'threads': [thread()]});
      await api.run(() async {
        await openDrawer(tester);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Your chats'), findsOneWidget,
            reason: 'the heading and the new-chat button are drawn immediately');
        expect(find.text('New chat'), findsOneWidget);

        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Refund question'), findsOneWidget);
      });
    });

    // The limit matches the server's own per-user cap, so a user at the cap is not shown
    // the newest 30 of their 50 chats with the rest silently missing.
    testWidgets('the request carries the bearer and asks for every chat',
        (tester) async {
      final api = FakeApi()..ok({'threads': const []});
      await api.run(() async {
        await openDrawer(tester);
        await tester.pump();
        expect(api.endpoint(), '/assistant/threads?limit=50');
        expect(api.method(), 'GET');
        expect(api.token(), 'tok-1');
        expect(api.query(), {'limit': '50'},
            reason: 'archived chats are asked for separately or not at all');
      });
    });

    testWidgets('a chat is its title, its preview and how long ago it spoke',
        (tester) async {
      final api = FakeApi()..ok({'threads': [thread()]});
      await api.run(() async {
        await openDrawer(tester);
        await tester.pump();
        expect(find.text('Refund question'), findsOneWidget);
        expect(find.text('Where is my refund?  ·  3h'), findsOneWidget);
      });
    });

    testWidgets('a chat the server left untitled is still named', (tester) async {
      final api = FakeApi()
        ..ok({'threads': [thread(title: '   ', preview: null)]});
      await api.run(() async {
        await openDrawer(tester);
        await tester.pump();
        expect(find.text('New chat'), findsNWidgets(2),
            reason: 'the button, and the fallback title beside it');
      });
    });

    testWidgets('no chats yet is said in words', (tester) async {
      final api = FakeApi()..ok({'threads': const []});
      await api.run(() async {
        await openDrawer(tester);
        await tester.pump();
        expect(find.text('No chats yet. Whatever you ask first becomes one.'),
            findsOneWidget);
        expect(find.byType(ListTile), findsNothing);
      });
    });

    // An outage and an empty account are different facts and must not render the same.
    // Returning [] for a failed read is what made every server error read as "no chats
    // yet", with no way to ask again.
    testWidgets('a failed read says so, in the server\'s words, with a retry',
        (tester) async {
      final api = FakeApi()
        ..fail('Chats are unavailable right now.')
        ..ok({'threads': [thread()]});
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        expect(find.text('Chats are unavailable right now.'), findsOneWidget);
        expect(find.text('No chats yet. Whatever you ask first becomes one.'),
            findsNothing, reason: 'an outage must never read as an empty account');
        expect(find.text('Try again'), findsOneWidget);

        await tester.tap(find.text('Try again'));
        await settle(tester);
        expect(find.text('Refund question'), findsOneWidget,
            reason: 'the retry re-reads and the list appears');
        expect(api.sent.length, 2);
      });
    });
  });

  group('switching chats', () {
    testWidgets('a tap closes the drawer and opens the chat', (tester) async {
      final api = FakeApi()
        ..ok({'threads': [thread(), thread(id: 't2', title: 'Book Arena One')]})
        ..ok({'messages': const [], 'hasMore': false});
      await api.run(() async {
        final controller = await openDrawer(tester);
        await settle(tester);
        await tester.tap(find.text('Book Arena One'));
        await settle(tester);
        expect(find.text('Your chats'), findsNothing,
            reason: 'the drawer is closed before the chat is opened');
        expect(controller.threadId, 't2');
      });
    });

    // The same thing the row tap does, named explicitly in the menu because the request
    // asked for it there.
    testWidgets('Resume in the row menu opens the chat', (tester) async {
      final api = FakeApi()
        ..ok({'threads': [thread(id: 't2', title: 'Book Arena One')]})
        ..ok({'messages': const [], 'hasMore': false});
      await api.run(() async {
        final controller = await openDrawer(tester);
        await settle(tester);
        await tester.tap(find.byIcon(Icons.more_horiz_rounded));
        await settle(tester);
        await tester.tap(find.text('Resume'));
        await settle(tester);
        expect(controller.threadId, 't2');
      });
    });

    // Nothing is created server-side, so the only evidence is the drawer closing and the
    // transcript being cleared.
    testWidgets('a new chat consumes no thread slot', (tester) async {
      final api = FakeApi()..ok({'threads': [thread()]});
      await api.run(() async {
        final controller = await openDrawer(tester);
        await settle(tester);
        await tester.tap(find.text('New chat'));
        await settle(tester);
        expect(find.text('Your chats'), findsNothing);
        expect(controller.threadId, isNull);
        expect(api.sent.length, 1,
            reason: 'no thread is created until a message is sent');
      });
    });
  });

  group('managing a chat', () {
    /// Opens the row menu on the one thread the list holds.
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await settle(tester);
    }

    testWidgets('the menu offers resume, rename, archive and delete',
        (tester) async {
      final api = FakeApi()..ok({'threads': [thread()]});
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        await openMenu(tester);
        expect(find.text('Resume'), findsOneWidget);
        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('Archive'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
      });
    });

    /// Collects the framework errors a case expects, so an assertion the drawer trips
    /// can be asserted on rather than failing the case with no explanation.
    List<String> captureErrors() {
      final errors = <String>[];
      final prior = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.exceptionAsString());
      addTearDown(() => FlutterError.onError = prior);
      return errors;
    }

    /// Tears the tree down while the framework errors are still being intercepted. A
    /// dialog's dismissal leaves behind a ticker that would trip an animation assertion
    /// in whichever case runs next, so each rename case discards its own tree rather
    /// than the next one paying for it.
    Future<void> discardTree(WidgetTester tester) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('a rename sends the new title and reloads the list',
        (tester) async {
      final api = FakeApi()
        ..ok({'threads': [thread()]})
        ..ok({'thread': thread(title: 'Refunds')})
        ..ok({'threads': [thread(title: 'Refunds')]});
      final errors = captureErrors();
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        await openMenu(tester);
        await tester.tap(find.text('Rename'));
        await settle(tester);
        expect(find.text('Rename chat'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Refund question'), findsOneWidget,
            reason: 'the field opens on the current title, not empty');

        await tester.enterText(find.byType(TextField), 'Refunds');
        await tester.tap(find.text('Save'));
        await settle(tester);
        expect(errors, isEmpty,
            reason: 'the controller is disposed with the dialog state');
        expect(api.method(1), 'PATCH');
        expect(api.endpoint(1), '/assistant/threads/t1');
        expect(api.body(1), {'title': 'Refunds'},
            reason: 'a rename must not also send the archived flag');
        expect(api.sent.length, 3, reason: 'the list is re-read after the rename');
        await discardTree(tester);
      });
    });

    testWidgets('a rename to the title it already had sends nothing',
        (tester) async {
      final api = FakeApi()..ok({'threads': [thread()]});
      captureErrors();
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        await openMenu(tester);
        await tester.tap(find.text('Rename'));
        await settle(tester);
        await tester.tap(find.text('Save'));
        await settle(tester);
        expect(api.sent.length, 1);
        await discardTree(tester);
      });
    });

    testWidgets('a rename that is cancelled sends nothing', (tester) async {
      final api = FakeApi()..ok({'threads': [thread()]});
      final errors = captureErrors();
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        await openMenu(tester);
        await tester.tap(find.text('Rename'));
        await settle(tester);
        await tester.enterText(find.byType(TextField), 'Refunds');
        await tester.tap(find.text('Cancel'));
        await settle(tester);
        expect(errors, isEmpty);
        expect(api.sent.length, 1);
        expect(find.text('Refund question'), findsOneWidget,
            reason: 'the list is left exactly as it was');
        await discardTree(tester);
      });
    });

    // Archiving is how the per-user thread cap is escaped, so the flag has to be the
    // only thing in the body: a title sent alongside it would rename the chat as well.
    testWidgets('archiving sends the flag and nothing else', (tester) async {
      final api = FakeApi()
        ..ok({'threads': [thread()]})
        ..ok({'thread': thread()})
        ..ok({'threads': const []});
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        await openMenu(tester);
        await tester.tap(find.text('Archive'));
        await settle(tester);
        expect(api.method(1), 'PATCH');
        expect(api.endpoint(1), '/assistant/threads/t1');
        expect(api.body(1), {'archived': true});
        expect(find.text('No chats yet. Whatever you ask first becomes one.'),
            findsOneWidget,
            reason: 'the list is re-read, and the archived chat is gone from it');
      });
    });

    // The confirmation is not decoration: its sentence is the only place the app says
    // that deleting a chat does not touch the bookings made inside it.
    testWidgets('deleting asks first, and says what survives', (tester) async {
      final api = FakeApi()..ok({'threads': [thread()]});
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        await openMenu(tester);
        await tester.tap(find.text('Delete'));
        await settle(tester);
        expect(find.text('Delete this chat?'), findsOneWidget);
        expect(
            find.text('The messages go with it. Any bookings you made in this chat '
                'are unaffected — they live in your bookings, not in the conversation.'),
            findsOneWidget);

        await tester.tap(find.text('Keep'));
        await settle(tester);
        expect(api.sent.length, 1, reason: 'keeping sends nothing');
        expect(find.text('Refund question'), findsOneWidget);
      });
    });

    testWidgets('confirming the delete removes the chat', (tester) async {
      final api = FakeApi()
        ..ok({'threads': [thread()]})
        ..ok({'deleted': true})
        ..ok({'threads': const []});
      await api.run(() async {
        await openDrawer(tester);
        await settle(tester);
        await openMenu(tester);
        await tester.tap(find.text('Delete'));
        await settle(tester);
        await tester.tap(find.text('Delete').last);
        await settle(tester);
        expect(api.method(1), 'DELETE');
        expect(api.endpoint(1), '/assistant/threads/t1');
        expect(find.text('Refund question'), findsNothing);
      });
    });
  });

  // The drawer is the one surface in Scout whose rows carry three lines of text at a
  // doubled scale, and a clipped title is how a chat becomes unidentifiable.
  testWidgets('the rows hold at a doubled text scale', (tester) async {
    final api = FakeApi()..ok({'threads': [thread()]});
    await api.run(() async {
      await openDrawer(tester, textScale: 2.0);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Refund question'), findsOneWidget);
    });
  });
}
