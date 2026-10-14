import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_message.dart';
import 'package:sportlynk/screens/shared/poll_votes_screen.dart';

ChatPoll _poll(List<Map<String, dynamic>> votes) => ChatPoll.fromJson({
      'id': 'p',
      'question': 'Match day?',
      'options': ['Sat', 'Sun'],
      'votes': votes,
    });

List<Map<String, dynamic>> _many(int n, int option, String prefix) => [
      for (var i = 0; i < n; i++)
        {'optionIndex': option, 'userId': '$prefix$i', 'userName': '$prefix $i'},
    ];

Future<void> _pump(WidgetTester t, ChatPoll poll, {String myUserId = 'a0'}) =>
    t.pumpWidget(MaterialApp(home: PollVotesScreen(poll: poll, myUserId: myUserId)));

void main() {
  testWidgets('lists the question, the options and each voter', (t) async {
    await _pump(t, _poll([
      {'optionIndex': 0, 'userId': 'a0', 'userName': 'Alpha', 'votedAt': '2026-10-12T09:00:00Z'},
      {'optionIndex': 1, 'userId': 'b0', 'userName': 'Beta'},
    ]));
    expect(find.text('Match day?'), findsOneWidget);
    expect(find.text('Sat'), findsOneWidget);
    expect(find.text('Sun'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    // My own vote is marked, and a cast time renders when the server sent one.
    expect(find.text('Alpha (You)'), findsOneWidget);
    expect(find.textContaining('Oct'), findsWidgets);
  });

  testWidgets('a heavily-voted option collapses with a See-more that expands',
      (t) async {
    // A tall surface so the collapsed list and its "See more" are on-screen to
    // tap, rather than below the default 600px test viewport.
    t.view.physicalSize = const Size(800, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await _pump(t, _poll(_many(12, 0, 'P')), myUserId: 'none');
    // 12 voters, collapsed to 8 → 4 hidden until expanded.
    expect(find.text('See 4 more'), findsOneWidget);
    expect(find.text('P 11'), findsNothing);
    await t.tap(find.text('See 4 more'));
    await t.pumpAndSettle();
    expect(find.text('P 11'), findsOneWidget);
    expect(find.text('See 4 more'), findsNothing);
  });

  testWidgets('an option with no votes says so', (t) async {
    await _pump(t, _poll([
      {'optionIndex': 0, 'userId': 'a0', 'userName': 'Alpha'},
    ]));
    // Option 2 (Sun) drew nobody.
    expect(find.text('No votes'), findsOneWidget);
  });
}
