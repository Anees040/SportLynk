import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';
import '../../providers/chat_controller.dart';

/// WhatsApp's "Message info": for one of my own messages, who it has reached and
/// when — a "Read by" list, a "Delivered to" list, and anyone it is still only
/// "Pending" for. The data comes from [ChatController.receiptsFor], the same live
/// watermarks that drive the bubble's ticks, so this screen stays in step with
/// them — it rebuilds on every receipt through the controller's notifications.
class MessageInfoScreen extends StatelessWidget {
  /// What to rebuild on — the chat controller, so the lists update live as
  /// receipts arrive.
  final Listenable listenable;

  /// The current per-recipient receipts for [message], read on each rebuild
  /// (typically `() => controller.receiptsFor(message)`). Passed as a callback
  /// rather than the controller itself so the screen can be tested on its own.
  final List<MessageReceipt> Function() receiptsOf;
  final ChatMessage message;

  const MessageInfoScreen({
    required this.listenable,
    required this.receiptsOf,
    required this.message,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Message info'),
      ),
      body: ListenableBuilder(
        listenable: listenable,
        builder: (context, _) {
          final receipts = receiptsOf();
          final read = receipts.where((r) => r.status == ReceiptStatus.read).toList();
          final delivered = receipts.where((r) => r.status == ReceiptStatus.delivered).toList();
          final pending = receipts.where((r) => r.status == ReceiptStatus.sent).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _preview(),
              const SizedBox(height: 10),
              if (receipts.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 28),
                  child: Text('No recipients yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ),
              _section('Read by', Icons.done_all, AppColors.readTick, read),
              _section('Delivered to', Icons.done_all, AppColors.textSecondary, delivered),
              _section('Pending', Icons.done, AppColors.textSecondary, pending),
            ],
          );
        },
      ),
    );
  }

  Widget _preview() {
    final body = (message.body ?? '').trim();
    final text = body.isEmpty ? 'Attachment' : body;
    final sent = DateFormat('d MMM, h:mm a').format(message.createdAt.toLocal());
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.chatBubbleMine,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Text('Sent $sent',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _section(String title, IconData icon, Color accent, List<MessageReceipt> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
          child: Row(
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent)),
              const SizedBox(width: 6),
              Text('${rows.length}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: AppColors.border),
                _row(rows[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(MessageReceipt r) {
    final url = (r.avatarUrl ?? '').trim();
    final avatar = url.isEmpty ? null : CachedNetworkImageProvider(url);
    final when = r.at == null ? null : DateFormat('d MMM, h:mm a').format(r.at!.toLocal());
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: AppColors.accentLight,
        foregroundImage: avatar,
        child: avatar == null
            ? Text(r.name.isNotEmpty ? r.name[0].toUpperCase() : '?',
                style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold))
            : null,
      ),
      title: Text(r.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      subtitle: Text(when ?? 'Not delivered yet',
          style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
    );
  }
}
