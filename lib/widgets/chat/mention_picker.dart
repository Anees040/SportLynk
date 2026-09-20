import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';

/// The member list that rises above the composer while an `@` mention is being
/// typed. The screen owns the detection of the active `@token` and the filtering;
/// this widget only draws the candidates and reports the tapped one.
///
/// It caps its own height so a large team never pushes the composer off screen —
/// the list scrolls within the cap instead.
class MentionPicker extends StatelessWidget {
  final List<ChatMember> candidates;
  final void Function(ChatMember member) onPick;

  const MentionPicker({required this.candidates, required this.onPick, super.key});

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: const BoxDecoration(
        color: AppColors.cardBg,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: candidates.length,
        separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.border),
        itemBuilder: (_, i) {
          final m = candidates[i];
          final avatar = m.avatarUrl;
          final hasAvatar = avatar != null && avatar.isNotEmpty;
          return ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.accentLight,
              backgroundImage: hasAvatar ? CachedNetworkImageProvider(avatar) : null,
              child: hasAvatar
                  ? null
                  : Text(
                      m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: AppColors.primary, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
            ),
            title: Text(
              m.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
            ),
            onTap: () => onPick(m),
          );
        },
      ),
    );
  }
}
