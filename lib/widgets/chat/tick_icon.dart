import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../models/chat_message.dart';

/// The delivery ticks drawn on my own messages. Read is WhatsApp's blue
/// double-tick; every earlier state is a muted grey the caller supplies so it
/// sits correctly on whatever bubble colour it lands on.
class TickIcon extends StatelessWidget {
  final TickState state;
  final Color mutedColor;
  const TickIcon(this.state, {this.mutedColor = AppColors.textSecondary, super.key});

  static const Color _readBlue = Color(0xFF34B7F1); // WhatsApp read-tick blue

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case TickState.sending:
        return Icon(Icons.access_time, size: 13, color: mutedColor);
      case TickState.sent:
        return Icon(Icons.done, size: 16, color: mutedColor);
      case TickState.delivered:
        return Icon(Icons.done_all, size: 16, color: mutedColor);
      case TickState.read:
        return const Icon(Icons.done_all, size: 16, color: _readBlue);
    }
  }
}
