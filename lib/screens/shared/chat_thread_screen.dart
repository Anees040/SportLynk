import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/chat_channel.dart';
import '../../models/chat_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_controller.dart';
import '../../services/chat_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/chat/chat_composer.dart';
import '../../widgets/chat/date_separator.dart';
import '../../widgets/chat/message_bubble.dart';
import '../../widgets/chat/quick_reply_bar.dart';
import '../../widgets/chat/system_message_pill.dart';
import '../../widgets/chat/typing_indicator.dart';
import '../player/match_center_screen.dart';
import '../player/team_roster_screen.dart';

/// One chat thread, whatever it is about — WhatsApp in feel: day separators,
/// sender-labelled bubbles, single/double/blue ticks, live typing, reactions and
/// delete. The heavy lifting is in [ChatController]; this screen is composition,
/// gestures, and the handful of things that genuinely differ per channel type.
///
/// WHY ONE SCREEN FOR THREE CHANNEL TYPES
/// [ChatController] was already generic over `channelId` — it never knew what a
/// team was. Only three things actually vary: how the room is resolved when the
/// caller holds the THING instead of the room, what the header says, and where
/// the header can jump to. A screen per type would have forked the bubbles, the
/// ticks and the reaction palette three ways in order to change a title.
///
/// Prefer the named constructors: they encode which arguments each type needs, so
/// a booking thread cannot be opened with a team id by accident.
class ChatThreadScreen extends StatefulWidget {
  /// Which kind of room this is. Drives the header, the empty state, whether
  /// reply suggestions are offered, and — when [channelId] is null — the endpoint
  /// that resolves it.
  final ChatChannelType type;

  /// The room, when the caller already knows it. Every inbox row does.
  final String? channelId;

  /// The thing the room is ABOUT — a team id, a booking id or a match id — used
  /// to resolve [channelId] when it was not supplied.
  final String? refId;

  final String title;
  final String? imageUrl;

  /// The line under the title: the server-computed context ("Confirmed · Sat 5
  /// Sept, 6:00 pm"). Live typing still wins over it, and presence fills in when
  /// there is no context to show.
  final String? contextLine;

  /// Team rooms only, and only so the header can reach the roster and the match
  /// centre — both of which need the team's NAME as well as its id.
  final String? teamId;
  final String? teamName;

  /// Whether this room is currently muted, when the caller already knows (an
  /// inbox row does). It only seeds the menu label — the server owns the fact.
  final bool muted;

  const ChatThreadScreen({
    required this.type,
    required this.title,
    this.channelId,
    this.refId,
    this.imageUrl,
    this.contextLine,
    this.teamId,
    this.teamName,
    this.muted = false,
    super.key,
  }) : assert(channelId != null || refId != null,
            'a thread needs either its channelId or the ref it is about');

  /// The team group chat. [channelId] is optional — it is resolved from the team
  /// when absent, which is what the existing call sites rely on.
  const ChatThreadScreen.team({
    required String teamId,
    required String teamName,
    String? channelId,
    String? logoUrl,
    Key? key,
  }) : this(
          type: ChatChannelType.team,
          title: teamName,
          channelId: channelId,
          refId: teamId,
          imageUrl: logoUrl,
          teamId: teamId,
          teamName: teamName,
          key: key,
        );

  /// The booking room: the player and the venue owner. Opened from either side's
  /// booking screen, where a booking id is what the caller holds.
  const ChatThreadScreen.booking({
    required String bookingId,
    required String title,
    String? channelId,
    String? imageUrl,
    String? contextLine,
    Key? key,
  }) : this(
          type: ChatChannelType.booking,
          title: title,
          channelId: channelId,
          refId: bookingId,
          imageUrl: imageUrl,
          contextLine: contextLine,
          key: key,
        );

  /// The coordination room for a match: both captains and both vice-captains.
  /// [teamId]/[teamName] are optional — pass them when the caller came from a
  /// team context and the header gains a jump to the match centre.
  const ChatThreadScreen.forMatch({
    required String matchId,
    required String title,
    String? channelId,
    String? contextLine,
    String? teamId,
    String? teamName,
    Key? key,
  }) : this(
          type: ChatChannelType.captain,
          title: title,
          channelId: channelId,
          refId: matchId,
          contextLine: contextLine,
          teamId: teamId,
          teamName: teamName,
          key: key,
        );

  /// Straight from an inbox row, which already carries everything.
  ChatThreadScreen.fromChannel(ChatChannel c, {Key? key})
      : this(
          type: c.type,
          title: c.title,
          channelId: c.id,
          refId: c.refId,
          imageUrl: c.imageUrl,
          contextLine: c.context?.subtitle,
          teamId: c.type == ChatChannelType.team ? c.refId : null,
          teamName: c.type == ChatChannelType.team ? c.title : null,
          muted: c.muted,
          key: key,
        );

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> with WidgetsBindingObserver {
  static const _palette = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉'];

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();

  ChatController? _controller;
  late String _token;
  late String _myId;
  String? _channelId;
  String? _fatalError;
  int _lastCount = 0;

  // ── FR8.10 reply suggestions ───────────────────────────────
  // Only ever offered for the message somebody ELSE just sent, and the endpoint
  // refuses to suggest a reply to your own message anyway — so `_qrFor` is the
  // inbound message id the current set answers, and it is how a set is replaced
  // exactly once per incoming message instead of on every controller tick.
  QuickReplySet? _qr;
  bool _qrLoading = false;
  String? _qrFor;
  String? _qrDismissedFor;

  late bool _muted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final auth = context.read<AuthProvider>();
    _token = auth.token ?? '';
    _myId = auth.currentUser?.id ?? '';
    _channelId = widget.channelId;
    _muted = widget.muted;
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  /// Resolve the room, then open the controller.
  ///
  /// A MISSING ROOM IS NOT AN ERROR, and the message says so per type: a booking
  /// room exists only once the booking is confirmed, and a coordination room only
  /// once the challenge is accepted, so "not open yet" is the truth in both cases.
  /// The server answers 404 rather than 403 for a room that is not yours, which is
  /// why every branch here reads the same way — a stranger cannot tell a room they
  /// are not in from a room that does not exist. Each message therefore says who the
  /// room is FOR rather than anything about the viewer, which keeps it true in all
  /// three cases: not created yet, created before this feature shipped, or created
  /// and not yours.
  Future<void> _bootstrap() async {
    if (_channelId == null || _channelId!.isEmpty) {
      final ref = widget.refId;
      if (ref != null && ref.isNotEmpty) {
        switch (widget.type) {
          case ChatChannelType.team:
            final r = await ChatService().channelForTeam(_token, ref);
            if (r['success'] == true && r['data'] is Map) {
              _channelId = '${(r['data'] as Map)['channelId']}';
            }
          case ChatChannelType.booking:
            _channelId = await ChatService().channelForBooking(_token, ref);
          case ChatChannelType.captain:
            _channelId = await ChatService().channelForMatch(_token, ref);
          case ChatChannelType.unknown:
            break;
        }
      }
    }
    if (!mounted) return;
    if (_channelId == null || _channelId!.isEmpty || _channelId == 'null') {
      setState(() => _fatalError = switch (widget.type) {
            ChatChannelType.booking =>
              'No chat room for this booking. One opens for you and the venue when '
                  'a booking is confirmed.',
            ChatChannelType.captain =>
              "No coordination room for this match. One opens for the two teams' "
                  'captains and vice-captains when a challenge is accepted.',
            _ => 'This chat could not be opened.',
          });
      return;
    }
    final c = ChatController(token: _token, channelId: _channelId!, myUserId: _myId)
      ..addListener(_onControllerChange);
    setState(() => _controller = c);
  }

  /// True where a canned reply is a help rather than a nuisance: a booking room
  /// has exactly two people and the same six questions all day. Group rooms can
  /// still ask for suggestions from the overflow menu — they are just not offered
  /// unprompted, because a suggestion per inbound message in a busy team chat is
  /// a round trip nobody asked for.
  bool get _suggestsAutomatically => widget.type == ChatChannelType.booking;

  bool get _suggestsAtAll => widget.type != ChatChannelType.unknown;

  void _onControllerChange() {
    final count = _controller?.messages.length ?? 0;
    // Auto-stick to the newest message when the user is already at the bottom.
    if (count != _lastCount) {
      final grew = count > _lastCount;
      _lastCount = count;
      if (grew && _isNearBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
      }
    }
    if (_suggestsAutomatically) _maybeSuggest();
  }

  // ── FR8.10: three replies, one tap ─────────────────────────
  //
  // ADVISORY BY CONSTRUCTION. A tap fills the composer and stops there; the send
  // is the ordinary send, with the same validation, flood limit and idempotency
  // key. Nothing on this screen can put a sentence in somebody's mouth.

  /// The newest message from somebody else, or null when the last word was mine.
  /// System pills are skipped — a "booking confirmed" pill is not a question, and
  /// the endpoint would refuse it anyway.
  ChatMessage? get _lastInbound {
    final msgs = _controller?.messages ?? const <ChatMessage>[];
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      if (m.isSystem) continue;
      if (m.senderId == _myId) return null;
      if (m.kind != MessageKind.text || (m.body ?? '').trim().isEmpty) return null;
      return m;
    }
    return null;
  }

  void _maybeSuggest() {
    final m = _lastInbound;
    if (m == null) {
      // The conversation moved on — my own reply landed, or the thread is empty.
      if (_qr != null || _qrFor != null) {
        setState(() {
          _qr = null;
          _qrFor = null;
        });
      }
      return;
    }
    if (m.id == _qrFor || m.id == _qrDismissedFor || _qrLoading) return;
    _fetchSuggestions(m);
  }

  Future<void> _fetchSuggestions(ChatMessage m) async {
    final channelId = _channelId;
    if (channelId == null) return;
    setState(() {
      _qrLoading = true;
      _qrFor = m.id;
      _qr = null;
    });
    final set = await ChatService().quickReplies(_token, channelId, messageId: m.id);
    if (!mounted) return;
    setState(() {
      _qrLoading = false;
      // A late answer for a message that is no longer the newest is dropped, not
      // shown: chips that answer the message before last are worse than none.
      _qr = (_qrFor == m.id && !set.isEmpty) ? set : _qr;
    });
  }

  /// The overflow-menu path, for the rooms that do not offer suggestions on their
  /// own. Same endpoint, same advisory contract.
  Future<void> _suggestNow() async {
    final m = _lastInbound;
    if (m == null) {
      SnackbarUtil.showInfo(context, 'Nothing to reply to yet.');
      return;
    }
    _qrDismissedFor = null;
    await _fetchSuggestions(m);
  }

  /// A chip fills the composer and puts the caret at the end. It does NOT send.
  void _pickSuggestion(QuickReply q) {
    _input.text = q.text;
    _input.selection = TextSelection.collapsed(offset: q.text.length);
    setState(() {
      _qrDismissedFor = _qrFor;
      _qr = null;
    });
  }

  void _dismissSuggestions() => setState(() {
        _qrDismissedFor = _qrFor;
        _qr = null;
      });

  // ── Mute ───────────────────────────────────────────────────
  //
  // `muted_until` is a TIMESTAMP on the server, not a boolean, so "mute for 8
  // hours" un-mutes itself. The room keeps showing its own unread count in the
  // inbox either way — muting only takes it out of the header badge.
  Future<void> _toggleMute() async {
    final channelId = _channelId;
    if (channelId == null) return;
    final want = !_muted;
    final r = await ChatService()
        .mute(_token, channelId, muted: want, hours: want ? 8 : null);
    if (!mounted) return;
    if (r['success'] != true) {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not change notifications.');
      return;
    }
    final data = r['data'];
    setState(() => _muted = (data is Map && data['muted'] == true) || (data is! Map && want));
    SnackbarUtil.showSuccess(
        context, _muted ? 'Muted for 8 hours' : 'Notifications on');
  }

  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.pixels <= 120; // reversed list: 0 == newest
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  void _onScroll() {
    // Reversed list: approaching maxScrollExtent means we're reaching the oldest
    // loaded message — page in more history.
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _controller?.loadMore();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controller?.markReadNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _input.dispose();
    _controller?.removeListener(_onControllerChange);
    _controller?.dispose();
    super.dispose();
  }

  // ── Sending an image ───────────────────────────────────────
  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: AppColors.primary),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppColors.primary),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked =
        await _picker.pickImage(source: source, maxWidth: 1600, imageQuality: 82);
    if (picked == null || !mounted) return;

    int? w, h;
    try {
      final bytes = await picked.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      w = frame.image.width;
      h = frame.image.height;
      frame.image.dispose();
    } catch (_) {/* dimensions are a nicety, not required */}

    if (!mounted) return;
    SnackbarUtil.showSuccess(context, 'Sending photo…');
    final url = await CloudinaryService().uploadImage(picked.path, folder: 'chat');
    if (!mounted) return;
    if (url == null) {
      SnackbarUtil.showError(context, 'Could not upload the photo. Try again.');
      return;
    }
    await _controller?.sendImage(
      mediaUrl: url,
      mediaMime: picked.mimeType ?? 'image/jpeg',
      mediaW: w,
      mediaH: h,
    );
    _jumpToBottom();
  }

  // ── Long-press actions ─────────────────────────────────────
  void _showActions(ChatMessage m) {
    final c = _controller;
    if (c == null) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: _palette.map((e) {
                  final mine = m.myReaction(_myId) == e;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      c.toggleReaction(m.id, e);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: mine ? AppColors.accentLight : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 24)),
                    ),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            if (m.kind == MessageKind.text && (m.body ?? '').isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: m.body ?? ''));
                  Navigator.pop(context);
                  SnackbarUtil.showSuccess(context, 'Copied');
                },
              ),
            if (c.canDelete(m))
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AppColors.error),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: AppColors.error)),
                onTap: () async {
                  Navigator.pop(context);
                  final r = await c.deleteMessage(m.id);
                  if (mounted && r['success'] != true) {
                    SnackbarUtil.showError(
                        context, r['message']?.toString() ?? 'Could not delete.');
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openImage(String? url) {
    if (url == null) return;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => _ImageViewer(url: url),
    ));
  }

  /// The roster, and only for a team room — it is the one type whose "group info"
  /// is a screen this app has. Returning 'left' means the user left the team, in
  /// which case the thread they left is popped with it.
  Future<void> _openGroupInfo() async {
    final teamId = widget.teamId;
    if (teamId == null) return;
    final res = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            TeamRosterScreen(teamId: teamId, teamName: widget.teamName ?? widget.title),
      ),
    );
    if (res == 'left' && mounted) Navigator.pop(context);
  }

  void _openMatchCentre() {
    final teamId = widget.teamId;
    if (teamId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MatchCenterScreen(
          teamId: teamId,
          teamName: widget.teamName ?? widget.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(_fatalError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, height: 1.4)),
          ),
        ),
      );
    }
    final c = _controller;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5F4),
      appBar: _appBar(c),
      body: Column(
        children: [
          _connectionBar(c),
          Expanded(
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) {
                if (c.loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (c.messages.isEmpty) return _emptyState();
                final rows = _buildRows(c);
                return ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => rows[rows.length - 1 - i],
                );
              },
            ),
          ),
          if (_qrLoading || _qr != null)
            QuickReplyBar(
              set: _qr,
              loading: _qrLoading,
              onPick: _pickSuggestion,
              onDismiss: _dismissSuggestions,
            ),
          ChatComposer(
            controller: _input,
            onSend: (t) {
              c.sendText(t);
              // My own message is now the last word, so the chips that answered
              // theirs are stale — clear them rather than leave three sentences
              // hanging over a conversation that has moved on.
              _qr = null;
              _qrFor = null;
              _jumpToBottom();
            },
            onPickImage: _pickImage,
            onTyping: c.sendTyping,
          ),
        ],
      ),
    );
  }

  /// The header, which is the only part of this screen that really knows what the
  /// room is about.
  ///
  /// The subtitle has a precedence and each step earns its place: live typing
  /// beats everything (it is the only thing that is happening right now), the
  /// server-computed context comes next ("Confirmed · Sat 5 Sept, 6:00 pm" is a
  /// reason to be here), and presence is the fallback — which is all a team room
  /// ever had.
  PreferredSizeWidget _appBar(ChatController c) {
    final img = widget.imageUrl;
    final hasImg = img != null && img.isNotEmpty;
    final isTeam = widget.type == ChatChannelType.team;

    return AppBar(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      titleSpacing: 0,
      title: InkWell(
        onTap: isTeam ? _openGroupInfo : null,
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white24,
              backgroundImage: hasImg ? CachedNetworkImageProvider(img) : null,
              child: hasImg
                  ? null
                  : Icon(_typeIcon, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ListenableBuilder(
                listenable: c,
                builder: (_, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                    Text(c.typingText ?? widget.contextLine ?? c.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (isTeam)
          IconButton(
            tooltip: 'Matches',
            icon: const Icon(Icons.sports_kabaddi),
            onPressed: _openMatchCentre,
          ),
        if (widget.type == ChatChannelType.captain && widget.teamId != null)
          IconButton(
            tooltip: 'Match centre',
            icon: const Icon(Icons.scoreboard_outlined),
            onPressed: _openMatchCentre,
          ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) {
            switch (v) {
              case 'info':
                _openGroupInfo();
              case 'mute':
                _toggleMute();
              case 'suggest':
                _suggestNow();
            }
          },
          itemBuilder: (_) => [
            if (isTeam)
              const PopupMenuItem(value: 'info', child: Text('Group info')),
            if (_suggestsAtAll && !_suggestsAutomatically)
              const PopupMenuItem(value: 'suggest', child: Text('Suggest replies')),
            PopupMenuItem(
              value: 'mute',
              child: Text(_muted ? 'Unmute notifications' : 'Mute for 8 hours'),
            ),
          ],
        ),
      ],
    );
  }

  IconData get _typeIcon => switch (widget.type) {
        ChatChannelType.booking => Icons.stadium_outlined,
        ChatChannelType.captain => Icons.sports_kabaddi,
        ChatChannelType.team => Icons.groups,
        ChatChannelType.unknown => Icons.chat_bubble_outline,
      };

  Widget _connectionBar(ChatController c) {
    return ListenableBuilder(
      listenable: c,
      builder: (_, _) {
        if (c.connected) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: AppColors.warning.withValues(alpha: 0.15),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: const Text('Connecting…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Color(0xFF92600A))),
        );
      },
    );
  }

  /// An empty room is never a blank screen, and the sentence says what this
  /// particular room is FOR — a booking room and a coordination room are opened by
  /// the system, so the first person in will not otherwise know why they are here.
  Widget _emptyState() => ListView(
        children: [
          const SizedBox(height: 80),
          Icon(_typeIcon, size: 56, color: AppColors.textSecondary),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              switch (widget.type) {
                ChatChannelType.booking =>
                  'Chat with the venue about this booking.\nAsk about timings, parking or the gate.',
                ChatChannelType.captain =>
                  'Coordinate this match with the other captain.\nKit colours, arrival time, who brings the ball.',
                ChatChannelType.team => 'This is the start of your team chat.\nSay hello 👋',
                ChatChannelType.unknown => 'No messages yet.',
              },
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 14, height: 1.4),
            ),
          ),
        ],
      );

  /// Flatten the ascending timeline into widgets, inserting a day separator
  /// whenever the date changes and a typing bubble at the very bottom.
  List<Widget> _buildRows(ChatController c) {
    final msgs = c.messages;
    final rows = <Widget>[];
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      final prev = i > 0 ? msgs[i - 1] : null;
      if (prev == null || !_sameDay(prev.createdAt, m.createdAt)) {
        rows.add(DateSeparator(m.createdAt));
      }
      if (m.isSystem) {
        rows.add(SystemMessagePill(m));
        continue;
      }
      final isMine = m.senderId == _myId;
      final showSender = !isMine &&
          (prev == null ||
              prev.isSystem ||
              prev.senderId != m.senderId ||
              !_sameDay(prev.createdAt, m.createdAt));
      rows.add(MessageBubble(
        message: m,
        isMine: isMine,
        showSender: showSender,
        tickState: c.tickFor(m),
        onLongPress: () => _showActions(m),
        onReactionTap: (e) => c.toggleReaction(m.id, e),
        onImageTap: () => _openImage(m.mediaUrl),
        onRetry: () => c.retry(m),
      ));
    }
    if (c.typingText != null) rows.add(const TypingIndicator());
    return rows;
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Full-screen pinch-to-zoom image view for a chat photo.
class _ImageViewer extends StatelessWidget {
  final String url;
  const _ImageViewer({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 4,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            placeholder: (_, _) =>
                const CircularProgressIndicator(color: Colors.white),
            errorWidget: (_, _, _) =>
                const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
          ),
        ),
      ),
    );
  }
}
