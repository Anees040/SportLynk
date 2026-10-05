import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/chat_channel.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../services/chat_service.dart';
import '../../services/offline_cache.dart';
import '../../services/realtime_service.dart';
import '../../services/team_service.dart';
import '../../widgets/offline_banner.dart';
import 'chat_thread_screen.dart';

/// The inbox — every room this person is in, newest first, grouped in sections.
///
/// Why SECTIONS and not one flat list
/// A booking room, a match coordination room, a team room and a direct message are
/// read for different reasons: one is a transaction in progress, one is a fixture
/// tonight, one is a group of friends, one is a player who accepted a request to
/// play. Sorting them together by recency buries the booking a player is waiting on
/// under team banter. The server still returns one recency-ordered page — the
/// grouping is presentational, and paging works on the page, not on a section.
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
    ChatChannelType.direct,
  ];

  final _scroll = ScrollController();
  final _chat = ChatService();
  final _team = TeamService();

  late String _token;
  late String _myId;

  final List<ChatChannel> _items = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;

  /// Set while the rows on screen were restored from disk.
  DateTime? _cachedAt;

  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<Map<String, dynamic>>? _receiptSub;

  /// The room whose thread is open on top of this list, or null.
  ///
  /// This screen stays mounted underneath the thread and keeps receiving the
  /// socket's messages, so without this it counted every line the user was
  /// reading at that moment as unread and the badge came back the instant they
  /// returned.
  String? _openChannelId;

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
    // My own read marks arrive here too (the server sends a receipt to the
    // reader's own devices as well as to the room), and they are what clears a
    // badge without waiting for a refetch to agree.
    _receiptSub = RealtimeService().receipts.listen(_onReceipt);
    // Concurrent, not chained — see [_hydrateFromCache].
    _load();
    _hydrateFromCache();
  }

  /// Draw the last known inbox if it arrives before the network does.
  ///
  /// This is the piece that makes the chat feature behave offline the way the
  /// threads already do: `ChatController` caches a page of messages per room, so
  /// with the room list cached too, a phone with no connection can open the inbox,
  /// pick a conversation and read it. Without this the list was empty and the
  /// cached messages were unreachable.
  ///
  /// The `_items.isEmpty` guard keeps a slow disk read from replacing rooms the
  /// response already delivered.
  Future<void> _hydrateFromCache() async {
    final cached = await OfflineCache.read(OfflineCache.chatInbox);
    if (!mounted || cached == null || _items.isNotEmpty) return;
    final rows = cached.asRows();
    if (rows.isEmpty) return;
    setState(() {
      _items.addAll(rows.map(ChatChannel.fromJson));
      _cachedAt = cached.at;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _receiptSub?.cancel();
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
    // A failed fetch leaves whatever is on screen alone. Clearing the list on
    // failure is what used to turn a dropped connection into an inbox that looked
    // like an account with no conversations — and it also threw away the only
    // route to the message caches the threads keep.
    if (!page.ok) {
      setState(() => _loading = false);
      context.read<ConnectivityProvider>().markUnreachable();
      return;
    }
    setState(() {
      _items
        ..clear()
        ..addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _cachedAt = null;
      _loading = false;
    });
    context.read<ConnectivityProvider>().markReachable();
    await OfflineCache.write(
        OfflineCache.chatInbox, page.items.map((c) => c.toJson()).toList());
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
    // A message landing in the room the user is reading right now is not unread.
    // The thread marks it read a moment later and the server's receipt confirms
    // it, but counting it first and uncounting it after is a badge that blinks.
    final reading = channelId == _openChannelId;
    setState(() {
      _items[i] = _items[i].copyWith(
        lastMessageAt: at,
        lastMessagePreview: deleted ? 'This message was deleted' : preview,
        lastMessageSenderId: senderId,
        lastMessageSenderName: m['sender_name'] == null ? null : '${m['sender_name']}',
        // My own message never counts as unread to me, and a delete is an edit of
        // a message that was already counted — neither moves the badge.
        unread: (mine || deleted || reading) ? _items[i].unread : _items[i].unread + 1,
      );
    });
  }

  /// One of my read watermarks moved: drop that room's badge.
  ///
  /// The server emits a receipt to the reader's own user room precisely so this
  /// screen can learn it. Before that, a read performed inside the thread was
  /// invisible here and the only correction was the refetch on return — which
  /// races the read it is trying to observe, because the read-mark is sent
  /// without waiting for an answer. The result was a room the user had just
  /// finished reading still wearing its count.
  ///
  /// Receipts from other people are ignored: their ticks are the thread's
  /// business, and an inbox row says nothing about them.
  void _onReceipt(Map<String, dynamic> data) {
    if ('${data['userId']}' != _myId) return;
    if (data['readAt'] == null) return; // delivered-only: nothing was read
    final channelId = '${data['channelId'] ?? ''}';
    if (channelId.isEmpty) return;
    final i = _items.indexWhere((c) => c.id == channelId);
    if (i < 0 || _items[i].unread == 0) return;
    setState(() => _items[i] = _items[i].copyWith(unread: 0));
  }

  Future<void> _open(ChatChannel c) async {
    // Optimistically clear the badge: opening the thread is what moves
    // `last_read_at` server-side, the live receipt confirms it, and the refresh
    // on return is the backstop for a socket that was down throughout.
    final i = _items.indexOf(c);
    if (i >= 0 && c.unread > 0) {
      setState(() => _items[i] = c.copyWith(unread: 0));
    }
    _openChannelId = c.id;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatThreadScreen.fromChannel(c)),
    );
    _openChannelId = null;
    if (!mounted) return;
    // Confirm the read from here before re-reading the counts. The thread's own
    // read-marks are fire-and-forget (a socket emit, or an un-awaited POST when
    // the socket is down), so a refresh issued the instant the thread closes can
    // observe the room as still unread and put the badge straight back. This POST
    // is idempotent — the watermark only moves forwards — and it costs one
    // request per visit to make the clear deterministic rather than likely.
    await _chat.markRead(_token, c.id);
    if (mounted) await _load();
  }

  /// The WhatsApp-style long-press sheet: the actions that belong to a whole room
  /// rather than to a message. Mute lives here, not in the thread's overflow menu,
  /// so a room can be silenced without opening it.
  void _showActions(ChatChannel c) {
    final isTeam = c.type == ChatChannelType.team;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.divider),
            if (c.unread > 0)
              _actionTile(
                icon: Icons.mark_chat_read_outlined,
                label: 'Mark as read',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _markRead(c);
                },
              ),
            _actionTile(
              icon: c.muted
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              label: c.muted ? 'Unmute' : 'Mute notifications',
              onTap: () {
                Navigator.pop(sheetContext);
                if (c.muted) {
                  _setMuted(c, muted: false);
                } else {
                  _pickMuteInterval(c);
                }
              },
            ),
            if (isTeam)
              _actionTile(
                icon: Icons.logout,
                label: 'Leave team',
                danger: true,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmLeave(c);
                },
              ),
            _actionTile(
              icon: Icons.delete_outline,
              label: 'Delete chat',
              danger: true,
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDelete(c);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? AppColors.error : AppColors.textPrimary;
    return ListTile(
      leading: Icon(icon, color: color, size: 22),
      title: Text(
        label,
        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: color),
      ),
      onTap: onTap,
    );
  }

  Future<void> _markRead(ChatChannel c) async {
    final i = _items.indexWhere((x) => x.id == c.id);
    if (i >= 0) setState(() => _items[i] = _items[i].copyWith(unread: 0));
    await _chat.markRead(_token, c.id);
  }

  /// Offer the three WhatsApp mute windows. "Always" is a year, the server's cap,
  /// so it reads as permanent without a separate never-expires code path.
  void _pickMuteInterval(ChatChannel c) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Mute for',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: AppColors.divider),
            _actionTile(
              icon: Icons.schedule,
              label: '8 hours',
              onTap: () {
                Navigator.pop(sheetContext);
                _setMuted(c, muted: true, hours: 8);
              },
            ),
            _actionTile(
              icon: Icons.today_outlined,
              label: '1 day',
              onTap: () {
                Navigator.pop(sheetContext);
                _setMuted(c, muted: true, hours: 24);
              },
            ),
            _actionTile(
              icon: Icons.all_inclusive,
              label: 'Always',
              onTap: () {
                Navigator.pop(sheetContext);
                _setMuted(c, muted: true, hours: 24 * 365);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Future<void> _setMuted(ChatChannel c, {required bool muted, int? hours}) async {
    final r = await _chat.mute(_token, c.id, muted: muted, hours: hours);
    if (!mounted) return;
    if (r['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update mute. Try again when connected.')),
      );
      return;
    }
    // Read the muted state back from the server rather than assuming it — the
    // server owns the "muted" definition (and clears mutedUntil on unmute).
    final data = r['data'] is Map ? Map<String, dynamic>.from(r['data'] as Map) : const {};
    final nowMuted = data['muted'] == true ? true : (data['muted'] == false ? false : muted);
    final until = data['mutedUntil'] == null
        ? null
        : DateTime.tryParse('${data['mutedUntil']}')?.toLocal();
    final i = _items.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      setState(() => _items[i] = _items[i].copyWith(
            muted: nowMuted,
            mutedUntil: until,
          ));
    }
  }

  Future<void> _confirmLeave(ChatChannel c) async {
    final teamId = c.refId;
    if (teamId == null || teamId.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.cardBg,
        title: const Text('Leave team?'),
        content: Text(
          'You will stop receiving messages from ${c.title} and be removed from '
          'its roster. You can be added again by a captain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _team.leave(_token, teamId);
    if (!mounted) return;
    if (r['success'] == true) {
      setState(() => _items.removeWhere((x) => x.id == c.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You left ${c.title}.')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${r['message'] ?? 'Could not leave the team.'}')),
      );
    }
  }

  /// Clear a conversation from this inbox. WhatsApp's "Delete chat": the room drops
  /// off the list and returns on the next message; it is not a leave, so the copy
  /// says so plainly rather than implying the team was left.
  Future<void> _confirmDelete(ChatChannel c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.cardBg,
        title: const Text('Delete chat?'),
        content: Text(
          'This clears ${c.title} from your chats. You stay in the conversation, '
          'and it returns here when a new message arrives.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = await _chat.hideChannel(_token, c.id);
    if (!mounted) return;
    if (r['success'] == true) {
      setState(() => _items.removeWhere((x) => x.id == c.id));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete the chat. Try again when connected.')),
      );
    }
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
      body: Column(children: [
        OfflineBanner(cachedAt: _cachedAt),
        Expanded(
          child: RefreshIndicator(
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
                            onLongPress: () => _showActions(row),
                          );
                        },
                      ),
          ),
        ),
      ]),
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
  final VoidCallback onLongPress;

  const _ChatRow({
    required this.channel,
    required this.myUserId,
    required this.onTap,
    required this.onLongPress,
  });

  IconData get _fallbackIcon => switch (channel.type) {
        ChatChannelType.booking => Icons.stadium_outlined,
        ChatChannelType.captain => Icons.sports_kabaddi,
        ChatChannelType.team => Icons.groups,
        ChatChannelType.direct => Icons.person_outline,
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
      onLongPress: onLongPress,
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
