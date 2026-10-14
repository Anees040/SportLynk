import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';

/// The per-option voter list for a poll, opened full-screen (with a back button)
/// from a poll bubble's "View votes". Each option is a section; under it every
/// voter is a row — avatar, or a lettered placeholder when they have no photo,
/// then the name and the time they voted — in the order the votes were cast. An
/// option with many voters collapses to the first [_collapsedCount] with a "See
/// more" toggle, so a lopsided poll does not bury the smaller options off-screen.
class PollVotesScreen extends StatefulWidget {
  final ChatPoll poll;
  final String myUserId;

  const PollVotesScreen({required this.poll, required this.myUserId, super.key});

  @override
  State<PollVotesScreen> createState() => _PollVotesScreenState();
}

class _PollVotesScreenState extends State<PollVotesScreen> {
  static const _collapsedCount = 8;
  final Set<int> _expanded = <int>{};

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Votes'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(poll.question,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(poll.totalVoters == 1 ? '1 vote' : '${poll.totalVoters} votes',
              style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          const SizedBox(height: 16),
          for (var i = 0; i < poll.options.length; i++) _optionSection(i),
        ],
      ),
    );
  }

  Widget _optionSection(int i) {
    final poll = widget.poll;
    final voters = poll.votersFor(i);
    final expanded = _expanded.contains(i);
    final shown = expanded ? voters : voters.take(_collapsedCount).toList();
    final hidden = voters.length - shown.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(poll.options[i],
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
                const SizedBox(width: 10),
                Text(voters.length == 1 ? '1 vote' : '${voters.length} votes',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary)),
              ],
            ),
          ),
          if (voters.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Text('No votes', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            )
          else ...[
            const Divider(height: 1, color: AppColors.border),
            for (final v in shown) _voterRow(v),
            if (hidden > 0)
              InkWell(
                onTap: () => setState(() => _expanded.add(i)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Text('See $hidden more',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _voterRow(PollVote v) {
    final isMe = v.userId == widget.myUserId;
    final url = (v.avatarUrl ?? '').trim();
    final avatar = url.isEmpty ? null : CachedNetworkImageProvider(url);
    final name = isMe ? '${v.userName} (You)' : v.userName;
    final when = v.votedAt == null ? null : DateFormat('d MMM, h:mm a').format(v.votedAt!);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: AppColors.accentLight,
            foregroundImage: avatar,
            child: avatar == null
                ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                if (when != null) ...[
                  const SizedBox(height: 2),
                  Text(when, style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
