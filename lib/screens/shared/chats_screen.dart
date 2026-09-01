import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/chat_channel.dart';
import '../../providers/auth_provider.dart';
import '../../services/chat_service.dart';
import '../../services/realtime_service.dart';
import 'chat_thread_screen.dart';

/// The inbox — every room this person is in, newest first, in three sections.
///
/// Why SECTIONS and not one flat list
/// A booking room, a match coordination room and a team room are read for
/// different reasons: one is a transaction in progress, one is a fixture tonight,
/// one is a group of friends. Sorting them together by recency buries the booking
/// a player is waiting on under team banter. The server still returns one recency-
/// ordered page — the grouping is presentational, and paging works on the page,
/// not on a section.
///
/// Scout is not here. The assistant has its own screen and its own entry point;
/// the server excludes `type = 'assistant'` from this list, so there is nothing to
/// filter out on this side.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  static const _sections = [
    ChatChannelType.booking,
    ChatChannelType.captain,
    ChatChannelType.team,
  ];

  final _scroll = ScrollController();
  final _chat = ChatService();

  late String _token;
  late String _myId;

  final List<ChatChannel> _items = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;

  StreamSubscription<Map<String, dynamic>>? _msgSub;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _token = auth.token ?? '';
    _myId = auth.currentUser?.id ?? '';
    _scroll.addListener(_onScroll);
    // The socket is what makes this list live. It is a singleton and joining is
    // idempotent, so calling it here costs nothing when a thread already has it
    // open — and it is the difference between an inbox and a snapshot when this
    // is the only chat screen on the stack.
    RealtimeService().ensureConnected(_token);
    _msgSub = RealtimeService().messages.listen(_onLiveMessage);
    _load();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// One page from the top. There is deliberately no error line on this screen:
  /// `ChatService.chats` answers an empty page for both "you have no rooms" and
  /// "the request did not land" (ApiClient never throws), and a screen that cannot
  /// tell those apart must not claim either. So the empty state states the two
  /// facts it does know — how rooms get created, and that pulling down retries —
  /// and never says "no chats" as though that were confirmed.
  Future<void> _load() async {
    final page = await _chat.chats(_token, limit: 30);
    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _cursor == null) return;
    setState(() => _loadingMore = true);
    // The cursor goes back verbatim: it is the server's own `sortAt`, keyed on the
    // expression the ORDER BY uses. One built here would skip or repeat a row
    // whenever a message lands mid-scroll.
    final page = await _chat.chats(_token, limit: 30, cursor: _cursor);
    if (!mounted) return;
    setState(() {
      final seen = _items.map((c) => c.id).toSet();
      _items.addAll(page.items.where((c) => !seen.contains(c.id)));
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _loadingMore = false;
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  /// A message arrived somewhere. The socket already fans out to every member's
  /// own room, so this fires for every room this person is in — not just the one
  /// they have open — which is exactly what an inbox needs.
  ///
  /// The row is patched in place rather than re-fetched: a refresh per inbound
  /// message would be a request per message in a busy team chat, and it would
  /// scroll the list out from under a thumb. A message for a room that is not on
  /// this page (a brand-new booking room, or one further down than the loaded pages)
  /// is the one case that does need a reload.
  void _onLiveMessage(Map<String, dynamic> m) {
    final channelId = '${m['channel_id'] ?? m['channelId'] ?? ''}';
    if (channelId.isEmpty) return;
    final i = _items.indexWhere((c) => c.id == channelId);
    if (i < 0) {
      _load();
      return;
    }
    final senderId = m['sender_id'] == null ? null : '${m['sender_id']}';
    final deleted = m['deleted_at'] != null;
    final kind = '${m['kind'] ?? 'text'}';
    final preview = switch (kind) {
      'image' => 'Photo',
      'audio' => 'Voice message',
      _ => '${m['body'] ?? ''}',
    };
    final at = DateTime.tryParse('${m['created_at'] ?? ''}')?.toLocal();
    final mine = senderId != null && senderId == _myId;
    setState(() {
      _items[i] = _items[i].copyWith(
        lastMessageAt: at,
        lastMessagePreview: deleted ? 'This message was deleted' : preview,
        lastMessageSenderId: senderId,
        lastMessageSenderName: m['sender_name'] == null ? null : '${m['sender_name']}',
        // My own message never counts as unread to me, and a delete is an edit of
        // a message that was already counted — neither moves the badge.
        unread: (mine || deleted) ? _items[i].unread : _items[i].unread + 1,
      );
    });
  }

  Future<void> _open(ChatChannel c) async {
    // Optimistically clear the badge: opening the thread is what moves
    // `last_read_at` server-side, and the refresh on return confirms it.
    final i = _items.indexOf(c);
    if (i >= 0 && c.unread > 0) {
      setState(() => _items[i] = c.copyWith(unread: 0));
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatThreadScreen.fromChannel(c)),
    );
    if (mounted) await _load();
  }

  /// The page, flattened once per build: a section heading followed by its rows,
  /// and a section with nothing in it is not rendered at all (an empty "Matches"
  /// heading is furniture, not information).
  ///
  /// Sorting happens here rather than in the model list, because a live message
  /// patches a row's `lastMessageAt` in place and the row must then rise inside
  /// its own section. `sortAt` is the server's tiebreaker for a room that has
  /// never had a message — the same COALESCE the ORDER BY uses.
  List<Object> get _flat {
    final out = <Object>[];
    for (final t in _sections) {
      final rows = _items.where((c) => c.type == t).toList()
        ..sort((a, b) {
          final x = a.lastMessageAt ?? a.sortAt;
          final y = b.lastMessageAt ?? b.sortAt;
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return y.compareTo(x);
        });
      if (rows.isEmpty) continue;
      out.add(_SectionHead(t.sectionLabel, rows.fold(0, (n, c) => n + c.unread)));
      out.addAll(rows);
    }
    // Anything the server sends whose type this build of the app does not know
    // still gets a row. Dropping it silently would hide a real conversation
    // behind an app update.
    final rest = _items.where((c) => !_sections.contains(c.type)).toList();
    if (rest.isNotEmpty) {
      out.add(_SectionHead(ChatChannelType.unknown.sectionLabel, 0));
      out.addAll(rest);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final flat = _flat;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.cardBg,
        surfaceTintColor: AppColors.cardBg,
        elevation: 0.5,
        title: const Text(
          'Chats',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
            : flat.isEmpty
                ? _empty()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: flat.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= flat.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.accent),
                            ),
                          ),
                        );
                      }
                      final row = flat[i];
                      if (row is _SectionHead) return _sectionHeader(row);
                      return _ChatRow(
                        channel: row as ChatChannel,
                        myUserId: _myId,
                        onTap: () => _open(row),
                      );
                    },
                  ),
      ),
    );
  }

  Widget _sectionHeader(_SectionHead h) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Row(
          children: [
            Text(
              h.label.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: AppColors.textSecondary,
              ),
            ),
            if (h.unread > 0) ...[
              const SizedBox(width: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${h.unread}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.success,
                  ),
                ),
              ),
            ],
          ],
        ),
      );

  /// Scrollable on purpose — a non-scrolling child would make the
  /// RefreshIndicator unusable exactly when the user most needs to retry.
  Widget _empty() => ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(28, 96, 28, 28),
        children: const [
          Icon(Icons.forum_outlined, size: 46, color: AppColors.disabled),
          SizedBox(height: 14),
          Text(
            'No conversations here yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'A chat opens by itself when a booking is confirmed, when a challenge '
            'is accepted, or when you join a team. Pull down to check again.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.textSecondary),
          ),
        ],
      );
}

/// A heading is a different kind of row from a channel, so the flattened list is
/// typed `Object` and each entry answers for itself in the builder. A sentinel
/// index (`i == 0 ? header : items[i-1]`) breaks the moment a section is empty.
class _SectionHead {
  final String label;
  final int unread;
  const _SectionHead(this.label, this.unread);
}

/// One inbox row.
///
/// The unread state changes three things at once — the title weight, the preview
/// weight and the badge — because a single green dot is easy to miss on a list
/// read at arm's length, and the same three moving together is what makes an
/// unread row legible in a glance.
class _ChatRow extends StatelessWidget {
  final ChatChannel channel;
  final String myUserId;
  final VoidCallback onTap;

  const _ChatRow({
    required this.channel,
    required this.myUserId,
    required this.onTap,
  });

  IconData get _fallbackIcon => switch (channel.type) {
        ChatChannelType.booking => Icons.stadium_outlined,
        ChatChannelType.captain => Icons.sports_kabaddi,
        ChatChannelType.team => Icons.groups,
        ChatChannelType.unknown => Icons.chat_bubble_outline,
      };

  /// Time on the row, at the precision a reader wants: the clock for
  /// today, the weekday inside a week, the date beyond it. A year is added only
  /// once it is not this one — "12 Sept 2025" on every old row is noise.
  String _stamp(DateTime? at) {
    if (at == null) return '';
    final now = DateTime.now();
    final d = DateTime(at.year, at.month, at.day);
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(d).inDays;
    if (days == 0) return DateFormat('h:mm a').format(at);
    if (days == 1) return 'Yesterday';
    if (days < 7) return DateFormat('EEE').format(at);
    if (at.year == now.year) return DateFormat('d MMM').format(at);
    return DateFormat('d MMM yy').format(at);
  }

  @override
  Widget build(BuildContext context) {
    final unread = channel.unread;
    final isUnread = unread > 0;
    final img = channel.imageUrl;
    final hasImg = img != null && img.isNotEmpty;
    // The context subtitle is the row's third line and only earns the space when
    // it is not already the preview — `previewLine` falls back to exactly this
    // string for a room with no messages, and printing it twice reads as a bug.
    final ctx = channel.context?.subtitle;
    final preview = channel.previewLine(myUserId);
    final showCtx = ctx != null && ctx.isNotEmpty && ctx != preview;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: const BoxDecoration(
          color: AppColors.cardBg,
          border: Border(bottom: BorderSide(color: AppColors.divider, width: 0.6)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.accentLight,
              backgroundImage: hasImg ? CachedNetworkImageProvider(img) : null,
              child: hasImg
                  ? null
                  : Icon(_fallbackIcon, size: 22, color: AppColors.primary),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          channel.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: isUnread ? FontWeight.w800 : FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (channel.muted) ...[
                        const SizedBox(width: 5),
                        const Icon(Icons.notifications_off_outlined,
                            size: 14, color: AppColors.textSecondary),
                      ],
                      const SizedBox(width: 7),
                      Text(
                        _stamp(channel.lastMessageAt ?? channel.sortAt),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: isUnread ? FontWeight.w700 : FontWeight.w500,
                          color: isUnread ? AppColors.success : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.25,
                            fontWeight: isUnread ? FontWeight.w600 : FontWeight.w400,
                            color: isUnread
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                      if (isUnread) ...[
                        const SizedBox(width: 8),
                        Container(
                          constraints: const BoxConstraints(minWidth: 20),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: AppColors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (showCtx) ...[
                    const SizedBox(height: 3),
                    Text(
                      ctx,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
