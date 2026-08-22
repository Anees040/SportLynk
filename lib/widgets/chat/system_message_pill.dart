import 'package:flutter/material.dart';
import '../../constants/colors.dart';
import '../../models/chat_message.dart';

/// The little centered notice for events the system posts into the timeline —
/// "Ali joined", "Sara is now captain", "Bilal left". Rendered from a message
/// whose kind is `system`; the human sentence is its body.
class SystemMessagePill extends StatelessWidget {
  final ChatMessage message;
  const SystemMessagePill(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final text = (message.body ?? '').trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.accentLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.35,
            fontWeight: FontWeight.w500,
            color: Color(0xFF166534),
          ),
        ),
      ),
    );
  }
}
