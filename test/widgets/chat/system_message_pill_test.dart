// SystemMessagePill: the timeline notice for events nobody typed.
//
// The body is the whole widget — the server writes the human sentence ("Ali joined",
// "Sara is now captain") and this draws it centred. The case worth pinning is the empty
// one: a system row with no body is a server-side omission, and rendering it would put
// an empty green pill in the middle of the conversation with nothing to explain it. It
// collapses to nothing instead, so the timeline shows no gap at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_message.dart';
import 'package:sportlynk/widgets/chat/system_message_pill.dart';

import '../widget_harness.dart';

ChatMessage _system(String? body) => ChatMessage.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'kind': 'system',
      'body': body,
      'created_at': '2026-03-14T10:00:00Z',
    });

void main() {
  Future<void> pumpPill(WidgetTester tester, String? body) => pumpApp(
        tester,
        Scaffold(body: Center(child: SystemMessagePill(_system(body)))),
      );

  testWidgets('the sentence is drawn centred', (tester) async {
    await pumpPill(tester, 'Ali joined the team');
    expect(find.text('Ali joined the team'), findsOneWidget);
    expect(tester.widget<Text>(find.byType(Text)).textAlign, TextAlign.center);
  });

  testWidgets('surrounding whitespace is trimmed off', (tester) async {
    await pumpPill(tester, '  Sara is now captain\n');
    expect(find.text('Sara is now captain'), findsOneWidget);
  });

  // A row with nothing to say takes up no space in the timeline.
  testWidgets('a body-less row collapses instead of drawing an empty pill',
      (tester) async {
    await pumpPill(tester, null);
    expect(find.byType(Text), findsNothing);
    expect(tester.getSize(find.byType(SystemMessagePill)), Size.zero);

    await pumpPill(tester, '   ');
    expect(find.byType(Text), findsNothing);
  });
}
