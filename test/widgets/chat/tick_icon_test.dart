// TickIcon: the four delivery states of one of my own messages.
//
// The states are not decoration. "Sending" is the only one that means the message is
// not yet on the server, and a message stuck there is the user's cue to check their
// connection rather than to wonder whether anyone read it; read is the only one drawn
// in a colour of its own, because it is the one fact the sender is looking for. Each
// state is pinned to its icon, its size and its colour so a reordered switch cannot
// quietly promote an unsent message to delivered.
//
// The muted colour is supplied by the caller because the ticks sit on two different
// bubble colours. Read ignores it: the blue is the signal, and a bubble that dimmed it
// to fit its own palette would lose the distinction.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/chat_message.dart';
import 'package:sportlynk/widgets/chat/tick_icon.dart';

import '../widget_harness.dart';

Icon _icon(WidgetTester tester) => tester.widget<Icon>(find.byType(Icon));

void main() {
  Future<void> pumpTick(WidgetTester tester, TickState state, {Color? muted}) =>
      pumpApp(
        tester,
        Scaffold(
          body: Center(
            child: muted == null ? TickIcon(state) : TickIcon(state, mutedColor: muted),
          ),
        ),
      );

  testWidgets('a message still in flight shows a clock, not a tick', (tester) async {
    await pumpTick(tester, TickState.sending);
    expect(_icon(tester).icon, Icons.access_time);
    expect(_icon(tester).size, 13);
    expect(_icon(tester).color, AppColors.textSecondary);
  });

  testWidgets('sent is one tick and delivered is two', (tester) async {
    await pumpTick(tester, TickState.sent);
    expect(_icon(tester).icon, Icons.done);
    expect(_icon(tester).size, 16);

    await pumpTick(tester, TickState.delivered);
    expect(_icon(tester).icon, Icons.done_all);
    expect(_icon(tester).color, AppColors.textSecondary);
  });

  // The one state with a colour of its own, and the only one the sender is watching
  // for.
  testWidgets('read is the blue double tick', (tester) async {
    await pumpTick(tester, TickState.read);
    expect(_icon(tester).icon, Icons.done_all);
    expect(_icon(tester).color, const Color(0xFF34B7F1));
  });

  testWidgets('the caller can mute every state except read', (tester) async {
    for (final state in [TickState.sending, TickState.sent, TickState.delivered]) {
      await pumpTick(tester, state, muted: AppColors.white);
      expect(_icon(tester).color, AppColors.white, reason: '$state follows the bubble');
    }

    await pumpTick(tester, TickState.read, muted: AppColors.white);
    expect(_icon(tester).color, const Color(0xFF34B7F1),
        reason: 'the read signal is not the bubble\'s to restyle');
  });
}
