import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/chat_message.dart';
import 'package:sportlynk/providers/chat_controller.dart';
import 'package:sportlynk/screens/shared/message_info_screen.dart';

ChatMessage _msg() => ChatMessage.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'sender_id': 'me',
      'kind': 'text',
      'body': 'See you at 6',
      'created_at': '2026-10-12T09:00:00Z',
    });

Future<void> _pump(WidgetTester t, List<MessageReceipt> receipts) => t.pumpWidget(
      MaterialApp(
        home: MessageInfoScreen(
          listenable: ValueNotifier(0),
          receiptsOf: () => receipts,
          message: _msg(),
        ),
      ),
    );

void main() {
  testWidgets('groups recipients into read, delivered and pending', (t) async {
    await _pump(t, [
      MessageReceipt(
          userId: 'a', name: 'Ali', status: ReceiptStatus.read, at: DateTime.utc(2026, 10, 12, 9, 5)),
      MessageReceipt(
          userId: 'b', name: 'Bina', status: ReceiptStatus.delivered, at: DateTime.utc(2026, 10, 12, 9, 2)),
      const MessageReceipt(userId: 'c', name: 'Cara', status: ReceiptStatus.sent),
    ]);

    expect(find.text('See you at 6'), findsOneWidget); // the message preview
    expect(find.text('Read by'), findsOneWidget);
    expect(find.text('Delivered to'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Ali'), findsOneWidget);
    expect(find.text('Bina'), findsOneWidget);
    expect(find.text('Cara'), findsOneWidget);
    // A recipient the message has not reached says so instead of showing a time.
    expect(find.text('Not delivered yet'), findsOneWidget);
  });

  testWidgets('an empty receipt set says there are no recipients yet', (t) async {
    await _pump(t, const []);
    expect(find.text('No recipients yet.'), findsOneWidget);
    expect(find.text('Read by'), findsNothing);
  });
}
