import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'camera_capture_screen.dart';
import 'chat_media_screen.dart';
import 'image_caption_screen.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/chat_channel.dart';
import '../../models/chat_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_controller.dart';
import '../../services/chat_service.dart';
import '../../services/chat_audio_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/chat/chat_background.dart';
import '../../widgets/chat/chat_composer.dart';
import '../../widgets/chat/date_separator.dart';
import '../../widgets/chat/image_album_bubble.dart';
import '../../widgets/chat/image_viewer.dart';
import '../../widgets/chat/mention_picker.dart';
import '../../widgets/chat/message_bubble.dart';
import '../../widgets/chat/pinned_banner.dart';
import '../../widgets/chat/quick_reply_bar.dart';
import '../../widgets/chat/reply_banner.dart';
import '../../widgets/chat/system_message_pill.dart';
import '../../widgets/chat/typing_indicator.dart';
import '../player/match_center_screen.dart';
import '../player/team_roster_screen.dart';

/// One chat thread, whatever it is about — WhatsApp in feel: day separators,
/// sender-labelled bubbles, single/double/blue ticks, live typing, reactions and
/// delete. The heavy lifting is in [ChatController]; this screen is composition,
/// gestures, and the handful of things that genuinely differ per channel type.
///
/// Why one screen for three channel types
/// [ChatController] was already generic over `channelId` — it never knew what a
/// team was. Only three things vary: how the room is resolved when the
/// caller holds the thing instead of the room, what the header says, and where
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

  /// The thing the room is about — a team id, a booking id or a match id — used
  /// to resolve [channelId] when it was not supplied.
  final String? refId;

  final String title;
  final String? imageUrl;

  /// The line under the title: the server-computed context ("Confirmed · Sat 5
  /// Sept, 6:00 pm"). Live typing still wins over it, and presence fills in when
  /// there is no context to show.
  final String? contextLine;

  /// Team rooms only, and only so the header can reach the roster and the match
  /// centre — both of which need the team's name as well as its id.
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
  ///
  /// [teamId]/[teamName] are what the header's jump to the match centre needs. A
  /// team room's own id is the team; a coordination room's ref_id is the match,
  /// so the viewer's team is read from the server-computed context instead — the
  /// inbox is the one entry point that has no team in hand otherwise, and without
  /// this a captain who opened the room from their chat list could not reach the
  /// match to submit a result or raise a dispute.
  ChatThreadScreen.fromChannel(ChatChannel c, {Key? key})
      : this(
          type: c.type,
          title: c.title,
          channelId: c.id,
          refId: c.refId,
          imageUrl: c.imageUrl,
          contextLine: c.context?.subtitle,
          teamId: c.type == ChatChannelType.team
              ? c.refId
              : c.type == ChatChannelType.captain
                  ? c.context?.myTeamId
                  : null,
          teamName: c.type == ChatChannelType.team
              ? c.title
              : c.type == ChatChannelType.captain
                  ? c.context?.myTeamName
                  : null,
          muted: c.muted,
          key: key,
        );

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> with WidgetsBindingObserver {
  static const _palette = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉'];

  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _picker = ImagePicker();

  ChatController? _controller;
  late String _token;
  late String _myId;
  String? _channelId;
  String? _fatalError;
  int _lastCount = 0;

  /// The message the composer is currently replying to, or null when the next
  /// send is an ordinary one. Cleared after the send lands and by the reply
  /// banner's cancel.
  ChatMessage? _replyTo;

  /// Whether the scroll-to-bottom button is showing. True once the user has
  /// scrolled up far enough that the newest message is out of view.
  bool _showJump = false;

  /// A message briefly tinted after a quote was tapped to jump to it, so the eye
  /// lands on the right line. Cleared by a timer.
  String? _highlightId;

  /// The ids currently selected by the WhatsApp-style long-press selection. Empty
  /// means normal mode; non-empty swaps the app bar for the contextual action bar
  /// and makes a tap on any bubble toggle its selection.
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  /// Where to float the quick-reaction pill: the top of the one selected row, in
  /// the coordinate space of the timeline stack, with the side the bubble sits
  /// on. Null when nothing is selected, when more than one is, or when the row is
  /// scrolled out of the viewport — WhatsApp shows reactions against a message
  /// you can see, and against exactly one.
  double? _reactionTop;
  bool _reactionRight = false;

  /// Measures the selected row after layout and places the pill just above it.
  /// Runs post-frame because the row's box is only correct once the contextual
  /// app bar has been inserted and the list has settled under it.
  void _placeReactionPill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      double? top;
      var right = false;
      if (_selected.length == 1) {
        final id = _selected.first;
        final rowCtx = _rowKeys[id]?.currentContext;
        final stackBox =
            _listStackKey.currentContext?.findRenderObject() as RenderBox?;
        final rowBox = rowCtx?.findRenderObject() as RenderBox?;
        if (rowBox != null && stackBox != null && rowBox.hasSize) {
          final y = rowBox.localToGlobal(Offset.zero, ancestor: stackBox).dy;
          // Only when the row is actually on screen; otherwise the pill would
          // float over an unrelated part of the thread.
          if (y > -rowBox.size.height && y < stackBox.size.height) {
            top = (y - _reactionPillHeight - 6)
                .clamp(4.0, math.max(4.0, stackBox.size.height - _reactionPillHeight - 4));
            right = _controller?.messageById(id)?.senderId == _myId;
          }
        }
      }
      if (top != _reactionTop || right != _reactionRight) {
        setState(() {
          _reactionTop = top;
          _reactionRight = right;
        });
      }
    });
  }

  static const double _reactionPillHeight = 48;

  /// The timeline stack, used as the coordinate space the reaction pill is
  /// positioned in.
  final GlobalKey _listStackKey = GlobalKey();

  /// A stable key per rendered row, keyed by message id, so a tapped quote can
  /// scroll its parent into view. Every id in an album run maps to the run's key.
  final Map<String, GlobalKey> _rowKeys = {};

  /// The user ids the composer has mentioned, mapped to the exact `@handle` token
  /// inserted for each. On send, a mention counts only while its handle still
  /// appears in the text — deleting the visible `@Ali` drops the ping.
  final Map<String, String> _mentioned = {};

  /// The mention candidates matching the `@token` currently under the caret, or
  /// empty when no mention is being typed. Drives [MentionPicker].
  List<ChatMember> _mentionMatches = const [];

  /// The id of the message the "unread messages" divider sits above, resolved once
  /// from the read watermark captured when the room opened. Null when there is
  /// nothing unread to mark. [_unreadResolved] pins it so a live send does not
  /// chase the divider down the thread as messages arrive.
  String? _unreadAnchorId;
  bool _unreadResolved = false;

  // FR8.10 reply suggestions
  // Only ever offered for the message somebody else just sent, and the endpoint
  // refuses to suggest a reply to the viewer's own message anyway — so `_qrFor` is the
  // inbound message id the current set answers, and it is how a set is replaced
  // exactly once per incoming message instead of on every controller tick.
  QuickReplySet? _qr;
  bool _qrLoading = false;
  String? _qrFor;
  String? _qrDismissedFor;

  late bool _muted;

  /// The chosen chat-background preset (Issue 5). Defaults to the doodle until
  /// the stored preference loads a frame or two later.
  ChatBgPreset _bg = ChatBgPreset.doodle;

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
    _input.addListener(_onInputChanged);
    _loadBackground();
    _bootstrap();
  }

  Future<void> _loadBackground() async {
    final p = await ChatBgPreset.load();
    if (mounted && p != _bg) setState(() => _bg = p);
  }

  Future<void> _pickBackground() async {
    final p = await showChatBackgroundPicker(context, _bg);
    if (p != null && mounted) setState(() => _bg = p);
  }

  /// Resolve the room, then open the controller.
  ///
  /// A missing room is not an error, and the message says so per type: a booking
  /// room exists only once the booking is confirmed, and a coordination room only
  /// once the challenge is accepted, so "not open yet" is the truth in both cases.
  /// The server answers 404 rather than 403 for a room the viewer is not in, which is
  /// why every branch here reads the same way — a stranger cannot tell a room they
  /// are not in from a room that does not exist. Each message therefore says who the
  /// room is for rather than anything about the viewer, which keeps it true in all
  /// three cases: not created yet, created before this feature shipped, or created
  /// and not this viewer's.
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
          case ChatChannelType.direct:
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
  /// still ask for suggestions from the overflow menu — they are not offered
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
    _resolveUnreadAnchor();
    if (_suggestsAutomatically) _maybeSuggest();
  }

  /// Fix the unread divider to the first message from someone else that arrived
  /// after my read watermark, computed exactly once when the first page has
  /// loaded. Pinning it here (rather than in the row builder) keeps the divider
  /// still while I read and send — it only moves when the room is reopened.
  void _resolveUnreadAnchor() {
    final c = _controller;
    if (_unreadResolved || c == null || c.loading) return;
    _unreadResolved = true;
    final boundary = c.unreadBoundary;
    if (boundary == null) return;
    for (final m in c.messages) {
      if (m.isSystem || m.senderId == _myId) continue;
      if (m.createdAt.isAfter(boundary)) {
        _unreadAnchorId = m.id;
        break;
      }
    }
  }

  // FR8.10: three replies, one tap
  //
  // Advisory by construction. A tap fills the composer and stops there; the send
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

  /// A chip fills the composer and puts the caret at the end. It does not send.
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

  // Mute now lives on the chats list, reached by long-pressing the row (Issue 1),
  // where the interval (8 hours / 1 day / always) is chosen. This screen only
  // reflects the muted state, via the indicator beside the title.

  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.pixels <= 120; // reversed list: 0 == newest
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  /// The scroll-to-bottom control, shown only once the newest message is out of
  /// view. Sized past the 48px tap-target floor and labelled for screen readers.
  Widget _jumpButton() {
    return Material(
      color: AppColors.cardBg,
      elevation: 3,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _jumpToBottom,
        child: Semantics(
          button: true,
          label: 'Scroll to latest messages',
          child: const SizedBox(
            width: 48,
            height: 48,
            child: Icon(Icons.keyboard_arrow_down, color: AppColors.primary, size: 28),
          ),
        ),
      ),
    );
  }

  Future<void> _unpinFromBanner(ChatMessage m) async {
    final r = await _controller?.togglePin(m, pinned: false);
    if (mounted && r != null && r['success'] != true) {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not unpin the message.');
    }
  }

  // Reply
  //
  // A reply carries the parent's id (so the server denormalises the quote) and an
  // optimistic [ReplyPreview] built from the parent in hand (so the quote shows
  // before the server echoes it back). The banner above the composer mirrors that
  // quote while typing; the send clears it.

  /// Begin replying to [m]. System pills and deleted messages are not quotable —
  /// a quote of "this message was deleted" has no head to show and no anchor to
  /// jump to.
  void _startReply(ChatMessage m) {
    if (m.isSystem || m.isDeleted) return;
    setState(() => _replyTo = m);
    _inputFocus.requestFocus();
  }

  void _cancelReply() => setState(() => _replyTo = null);

  /// Jump to the message a tapped quote points at — WhatsApp's behaviour: the
  /// original is brought on screen and briefly pulsed wherever it is. It may be
  /// loaded but unbuilt (a lazy list only builds visible rows) or not loaded at
  /// all (far up the history), so this first pages older history in until the id
  /// is loaded, then nudges the scroll toward it until its row mounts, then
  /// centres and highlights it. Only a genuinely absent target falls back to a
  /// message rather than a dead tap.
  Future<void> _scrollToMessage(String messageId) async {
    final c = _controller;
    if (c == null) return;

    // 1. Page in older history until the target is loaded (or there is no more).
    var guard = 0;
    while (!c.hasMessage(messageId) && c.hasMore && guard < 25) {
      await c.loadMore();
      guard++;
      if (!mounted) return;
    }

    // 2. Bring it on screen. Its row may not be built yet, so nudge toward older
    //    messages (a reversed list grows its offset into the past) until the key
    //    resolves, then centre it.
    for (var attempt = 0; attempt < 30; attempt++) {
      if (!mounted) return;
      final ctx = _rowKeys[messageId]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.3,
        );
        if (!mounted) return;
        setState(() => _highlightId = messageId);
        Future.delayed(const Duration(milliseconds: 1400), () {
          if (mounted && _highlightId == messageId) {
            setState(() => _highlightId = null);
          }
        });
        return;
      }
      if (!_scroll.hasClients) break;
      final pos = _scroll.position;
      final next =
          (pos.pixels + pos.viewportDimension * 0.8).clamp(0.0, pos.maxScrollExtent);
      if (next <= pos.pixels) break; // already as far as the list goes
      await _scroll.animateTo(next,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (!mounted) return;
    }

    if (!mounted) return;
    SnackbarUtil.showInfo(context, 'The original message is no longer available.');
  }

  /// The reply context to attach to the next send, consumed once: it clears the
  /// reply banner and returns the (id, preview) to thread through the send.
  (String?, ReplyPreview?) _consumeReply() {
    final target = _replyTo;
    if (target == null) return (null, null);
    final preview = ReplyPreview.of(target);
    setState(() => _replyTo = null);
    return (target.id, preview);
  }

  void _onScroll() {
    // Reversed list: approaching maxScrollExtent nears the oldest loaded message,
    // so page in more history.
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _controller?.loadMore();
    }
    // Reversed list: pixels near 0 is the newest message. Show the jump button
    // once the newest is comfortably out of view.
    final show = _scroll.position.pixels > 400;
    if (show != _showJump) setState(() => _showJump = show);
  }

  // @mentions
  //
  // Detection is local to the composer text: the token under the caret is matched
  // against the room's members, and the picker offers the matches. Picking one
  // inserts a single `@handle` token and records the member's id; the id is sent
  // only while that handle still stands in the text, so backspacing the mention
  // unpings the person exactly as one would expect.

  /// The `@token` the caret is currently inside, as (start, query), or null when
  /// the caret is not in a mention. A mention starts at an `@` that is at the
  /// start of the text or follows whitespace, and runs while the characters are
  /// word characters — so a mid-word `@` (an email) never opens the picker.
  (int, String)? _activeMention() {
    if (!_input.selection.isValid || !_input.selection.isCollapsed) return null;
    final caret = _input.selection.baseOffset;
    final text = _input.text;
    if (caret < 0 || caret > text.length) return null;
    var at = -1;
    for (var i = caret - 1; i >= 0; i--) {
      final ch = text[i];
      if (ch == '@') {
        at = i;
        break;
      }
      if (!RegExp(r'\w').hasMatch(ch)) return null; // whitespace/punct ends it
    }
    if (at < 0) return null;
    if (at > 0 && RegExp(r'\w').hasMatch(text[at - 1])) return null; // mid-word @
    return (at, text.substring(at + 1, caret));
  }

  void _onInputChanged() {
    final c = _controller;
    if (c == null) return;
    final active = _activeMention();
    if (active == null) {
      if (_mentionMatches.isNotEmpty) setState(() => _mentionMatches = const []);
      return;
    }
    final q = active.$2.toLowerCase();
    final matches = c.mentionCandidates
        .where((m) => q.isEmpty || m.name.toLowerCase().contains(q))
        .take(6)
        .toList();
    setState(() => _mentionMatches = matches);
  }

  /// A one-token handle from a display name: the first word, stripped to word
  /// characters, so it renders and highlights as a single `@handle`.
  String _handleFor(ChatMember m) {
    final first = m.name.trim().split(RegExp(r'\s+')).first;
    final cleaned = first.replaceAll(RegExp(r'\W'), '');
    return cleaned.isEmpty ? 'member' : cleaned;
  }

  /// Replace the active `@token` with the picked member's `@handle` and record the
  /// mention, leaving the caret after a trailing space so typing continues cleanly.
  void _pickMention(ChatMember m) {
    final active = _activeMention();
    if (active == null) return;
    final start = active.$1;
    final caret = _input.selection.baseOffset;
    final handle = _handleFor(m);
    final text = _input.text;
    final replacement = '@$handle ';
    final next = text.replaceRange(start, caret, replacement);
    _mentioned[m.userId] = '@$handle';
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    setState(() => _mentionMatches = const []);
  }

  /// The ids to send as mentions: those whose handle token still stands in the
  /// text, as a whole token (so `@Ali` does not match inside `@Alina`).
  List<String> _mentionsInText() {
    final text = _input.text;
    final out = <String>[];
    _mentioned.forEach((userId, handle) {
      final re = RegExp('${RegExp.escape(handle)}(?!\\w)');
      if (re.hasMatch(text)) out.add(userId);
    });
    return out;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controller?.markReadNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Stop any voice note playing from this room so it does not carry into the
    // screen behind it; the shared player outlives the thread.
    ChatAudioService.instance.stop();
    _scroll.dispose();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _inputFocus.dispose();
    _controller?.removeListener(_onControllerChange);
    _controller?.dispose();
    super.dispose();
  }

  // Sending an image
  //
  // The attachment sheet is the mobile path: a camera tile and the device's
  // recent photos in one draggable grid. Web has no photo_manager gallery, so it
  // falls back to the platform's own multi-image chooser. One photo goes through
  // the caption screen; several are sent as a batch, each streaming in with its
  // own instant preview and spinner.
  Future<void> _pickImage() async {
    final List<XFile> files;
    if (kIsWeb) {
      // The browser cannot host a live camera the uploader can read, so web keeps
      // the multi-image picker.
      files = await _picker.pickMultiImage();
    } else {
      // The camera icon opens the live camera; the gallery (multi-select) is
      // reachable from inside it. Both return the same list shape.
      files = await Navigator.push<List<XFile>>(
            context,
            MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
          ) ??
          const [];
    }
    if (files.isEmpty || !mounted) return;
    if (files.length == 1) {
      await _sendOneWithCaption(files.first);
    } else {
      await _sendBatch(files);
    }
  }

  /// The natural pixel size of a picked file, used to give the bubble the right
  /// aspect ratio before the image loads. A nicety, not required.
  Future<(int?, int?)> _imageDims(XFile file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      return (w, h);
    } catch (_) {
      return (null, null);
    }
  }

  /// A single photo: preview + optional caption, then send.
  Future<void> _sendOneWithCaption(XFile picked) async {
    final (w, h) = await _imageDims(picked);
    if (!mounted) return;
    // A null result means the user backed out; an empty string means "send with
    // no caption".
    final caption = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageCaptionScreen(
          localPath: picked.path,
          recipientName: widget.title,
        ),
      ),
    );
    if (caption == null || !mounted) return;
    final (replyToId, replyPreview) = _consumeReply();
    await _controller?.sendImageLocal(
      localPath: picked.path,
      mediaMime: picked.mimeType ?? 'image/jpeg',
      mediaW: w,
      mediaH: h,
      caption: caption.isEmpty ? null : caption,
      replyToId: replyToId,
      replyPreview: replyPreview,
    );
    _jumpToBottom();
  }

  /// Several photos at once: no caption step (matching a quick multi-send), each
  /// dispatched in order so they arrive as a run.
  Future<void> _sendBatch(List<XFile> files) async {
    // A reply anchors one message; on a multi-photo send it rides the first photo.
    var (replyToId, replyPreview) = _consumeReply();
    for (final f in files) {
      final (w, h) = await _imageDims(f);
      if (!mounted) return;
      await _controller?.sendImageLocal(
        localPath: f.path,
        mediaMime: f.mimeType ?? 'image/jpeg',
        mediaW: w,
        mediaH: h,
        replyToId: replyToId,
        replyPreview: replyPreview,
      );
      replyToId = null;
      replyPreview = null;
    }
    _jumpToBottom();
  }

  // WhatsApp-style selection: a long press selects a message (highlighting it and
  // turning the app bar into a contextual action bar), and while selecting a tap
  // on any bubble adds or removes it. The old bottom-sheet action menu is gone.
  void _enterSelection(ChatMessage m) {
    if (m.isSystem || m.isDeleted) return;
    HapticFeedback.selectionClick();
    setState(() => _selected.add(m.id));
    _placeReactionPill();
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
    _placeReactionPill();
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() {
      _selected.clear();
      _reactionTop = null;
    });
  }

  List<ChatMessage> get _selectedMessages {
    final c = _controller;
    if (c == null) return const [];
    return _selected.map(c.messageById).whereType<ChatMessage>().toList();
  }

  /// The contextual action bar shown while messages are selected: a count, the
  /// actions that apply, and — when exactly one is selected — a reaction strip.
  PreferredSizeWidget _selectionAppBar() {
    final c = _controller;
    final msgs = _selectedMessages;
    final count = msgs.length;
    final single = count == 1 ? msgs.first : null;
    // Delete is always offered: "Delete for me" needs no permission, and the
    // sheet decides whether "Delete for everyone" is among the choices.
    final canDeleteAny = msgs.any((m) => !m.isSystem);
    final canForward = msgs.any((m) =>
        !m.isDeleted && !m.pending && !m.failed && m.kind != MessageKind.system);
    return AppBar(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Clear selection',
        onPressed: _clearSelection,
      ),
      title: Text('$count'),
      actions: [
        if (single != null &&
            single.kind == MessageKind.text &&
            (single.body ?? '').isNotEmpty)
          IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: 'Copy',
              onPressed: () => _copySelected(single)),
        if (single != null && !single.isDeleted && !single.pending && !single.failed)
          IconButton(
              icon: const Icon(Icons.reply_outlined),
              tooltip: 'Reply',
              onPressed: () {
                _startReply(single);
                _clearSelection();
              }),
        if (canForward)
          IconButton(
              icon: const Icon(Icons.forward_outlined),
              tooltip: 'Forward',
              onPressed: _forwardSelected),
        if (single != null && c != null && c.canPin(single))
          IconButton(
              icon: Icon(c.isPinned(single.id) ? Icons.push_pin : Icons.push_pin_outlined),
              tooltip: c.isPinned(single.id) ? 'Unpin' : 'Pin',
              onPressed: () => _pinSelected(single)),
        if (canDeleteAny)
          IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _deleteSelected),
      ],
    );
  }

  /// The floating quick-reaction pill, placed just above the selected bubble the
  /// way WhatsApp does rather than pinned under the header: a reaction is an
  /// action on one message, so it belongs beside that message, not at the top of
  /// a screen it may be nowhere near. Rounded, raised and on a light surface so
  /// the emoji read; "+" opens the full picker.
  Widget _reactionPill(ChatMessage m) {
    final c = _controller;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(_reactionPillHeight / 2),
      color: AppColors.white,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      child: Container(
        height: _reactionPillHeight,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._palette.map((e) {
              final mine = m.myReaction(_myId) == e;
              return InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  c?.toggleReaction(m.id, e);
                  _clearSelection();
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: mine ? AppColors.accentLight : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: Text(e, style: const TextStyle(fontSize: 21)),
                ),
              );
            }),
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _openEmojiPicker(m),
              child: Container(
                margin: const EdgeInsets.only(left: 2),
                padding: const EdgeInsets.all(5),
                decoration: const BoxDecoration(
                  color: AppColors.inputFill,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add,
                    color: AppColors.textSecondary, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copySelected(ChatMessage m) {
    Clipboard.setData(ClipboardData(text: m.body ?? ''));
    _clearSelection();
    SnackbarUtil.showSuccess(context, 'Copied');
  }

  Future<void> _pinSelected(ChatMessage m) async {
    final c = _controller;
    if (c == null) return;
    final want = !c.isPinned(m.id);
    _clearSelection();
    final r = await c.togglePin(m, pinned: want);
    if (mounted && r['success'] != true) {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not update the pin.');
    }
  }

  /// WhatsApp's delete sheet: "Delete for everyone" where the caller is allowed
  /// it, "Delete for me" always, and Cancel. The two are genuinely different
  /// operations — one tombstones the row for the room, the other hides it for
  /// this reader only (migration 033) — so they are offered as separate choices
  /// rather than one ambiguous "Delete".
  Future<void> _deleteSelected() async {
    final c = _controller;
    if (c == null) return;
    final msgs = _selectedMessages.where((m) => !m.isSystem).toList();
    if (msgs.isEmpty) return;
    // Delete-for-everyone needs the right on every selected message; a mixed
    // selection offers only the hide, rather than silently skipping some.
    final canEveryone = msgs.every(c.canDelete);
    final n = msgs.length;

    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                n == 1 ? 'Delete message?' : 'Delete $n messages?',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary),
              ),
            ),
            if (canEveryone)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined,
                    color: AppColors.error),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: AppColors.error)),
                subtitle: const Text('Removed from this chat for all members'),
                onTap: () => Navigator.pop(sheetCtx, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined,
                  color: AppColors.textPrimary),
              title: const Text('Delete for me'),
              subtitle: const Text('Hidden from your chat only'),
              onTap: () => Navigator.pop(sheetCtx, 'me'),
            ),
            ListTile(
              leading: const Icon(Icons.close, color: AppColors.textSecondary),
              title: const Text('Cancel',
                  style: TextStyle(color: AppColors.textSecondary)),
              onTap: () => Navigator.pop(sheetCtx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    _clearSelection();
    for (final m in msgs) {
      final r = choice == 'everyone'
          ? await c.deleteMessage(m.id)
          : await c.hideMessage(m.id);
      if (!mounted) return;
      if (r['success'] != true) {
        SnackbarUtil.showError(
            context, r['message']?.toString() ?? 'Could not delete.');
        break;
      }
    }
  }

  void _openEmojiPicker(ChatMessage m) {
    const emojis = [
      '👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉',
      '👏', '💯', '✅', '❌', '⚽', '🏏', '🏆', '😍',
      '😎', '🤔', '😅', '😭', '🙌', '👌', '💪', '😡',
      '🥳', '😴', '🤝', '👀', '💔', '😤', '🤷', '⏰',
    ];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: GridView.count(
          crossAxisCount: 8,
          shrinkWrap: true,
          padding: const EdgeInsets.all(14),
          children: emojis
              .map((e) => GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _controller?.toggleReaction(m.id, e);
                      _clearSelection();
                    },
                    child: Center(child: Text(e, style: const TextStyle(fontSize: 26))),
                  ))
              .toList(),
        ),
      ),
    );
  }

  /// Forward the selected messages to another chat: pick a room from the inbox,
  /// then re-send each one's content there. Polls and tombstones are skipped.
  Future<void> _forwardSelected() async {
    final msgs = _selectedMessages
        .where((m) =>
            !m.isDeleted &&
            !m.pending &&
            !m.failed &&
            m.kind != MessageKind.system &&
            m.kind != MessageKind.poll)
        .toList();
    if (msgs.isEmpty) return;
    final page = await ChatService().chats(_token, limit: 50);
    if (!mounted) return;
    final target = await showModalBottomSheet<ChatChannel>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ForwardPicker(
          channels: page.items.where((c) => c.id != _channelId).toList()),
    );
    if (target == null || !mounted) return;
    _clearSelection();
    var sent = 0;
    for (final m in msgs) {
      if (await _forwardOne(m, target.id)) sent++;
    }
    if (!mounted) return;
    SnackbarUtil.showSuccess(
        context, sent <= 1 ? 'Forwarded' : 'Forwarded $sent messages');
  }

  Future<bool> _forwardOne(ChatMessage m, String channelId) async {
    final svc = ChatService();
    final cid = 'fwd-${DateTime.now().microsecondsSinceEpoch}-${m.id.hashCode}';
    Map<String, dynamic> r;
    if (m.kind == MessageKind.image && m.mediaUrl != null) {
      r = await svc.sendImage(_token, channelId,
          mediaUrl: m.mediaUrl!,
          mediaMime: m.mediaMime,
          mediaW: m.mediaW.toInt(),
          mediaH: m.mediaH.toInt(),
          caption: m.body,
          clientId: cid);
    } else if (m.kind == MessageKind.audio && m.mediaUrl != null) {
      r = await svc.sendAudio(_token, channelId,
          mediaUrl: m.mediaUrl!,
          mediaMime: m.mediaMime,
          durationMs: m.durationMs.toInt(),
          waveform: m.waveform,
          clientId: cid);
    } else if ((m.body ?? '').isNotEmpty) {
      r = await svc.sendText(_token, channelId, body: m.body!, clientId: cid);
    } else {
      return false;
    }
    return r['success'] == true;
  }

  void _openImage(String? url) {
    if (url == null) return;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => ImageViewer(urls: [url]),
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

  void _openMedia() {
    final channelId = _channelId;
    if (channelId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatMediaScreen(
          token: _token,
          channelId: channelId,
          title: widget.title,
        ),
      ),
    );
  }

  Future<void> _createPoll() async {
    final c = _controller;
    if (c == null) return;
    final draft = await showModalBottomSheet<_PollDraft>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const _PollComposer(),
    );
    if (draft == null || !mounted) return;
    final r = await c.createPoll(
      question: draft.question,
      options: draft.options,
      allowMultiple: draft.allowMultiple,
    );
    if (!mounted) return;
    if (r['success'] == true) {
      _jumpToBottom();
    } else {
      SnackbarUtil.showError(
          context, r['message']?.toString() ?? 'Could not create the poll.');
    }
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

    return PopScope(
      // While messages are selected, back clears the selection instead of leaving
      // the room — the same escape the contextual bar's close button gives.
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _clearSelection();
      },
      child: Scaffold(
      backgroundColor: _bg.ground,
      appBar: _selecting ? _selectionAppBar() : _appBar(c),
      body: Column(
        children: [
          _connectionBar(c),
          ListenableBuilder(
            listenable: c,
            builder: (_, _) => PinnedBanner(
              pinned: c.pinned,
              onTap: (m) => _scrollToMessage(m.id),
              onUnpin: c.amAdmin ? _unpinFromBanner : null,
            ),
          ),
          Expanded(
            child: ChatBackground(
              preset: _bg,
              child: Stack(
              key: _listStackKey,
              children: [
                ListenableBuilder(
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
                      // The rows are builder closures, so ListView.builder
                      // constructs only the visible ones: a typing or presence
                      // tick no longer rebuilds the whole history, and the
                      // RepaintBoundary keeps each row's repaint to itself.
                      itemBuilder: (_, i) =>
                          RepaintBoundary(child: rows[rows.length - 1 - i]()),
                    );
                  },
                ),
                if (_showJump)
                  Positioned(right: 12, bottom: 12, child: _jumpButton()),
                // The quick-reaction pill, floated over the timeline just above
                // the one selected bubble.
                if (_reactionTop != null && _selected.length == 1)
                  Builder(builder: (_) {
                    final m = c.messageById(_selected.first);
                    if (m == null || m.isDeleted) return const SizedBox.shrink();
                    return Positioned(
                      top: _reactionTop,
                      left: _reactionRight ? null : 8,
                      right: _reactionRight ? 8 : null,
                      child: _reactionPill(m),
                    );
                  }),
              ],
              ),
            ),
          ),
          if (_qrLoading || _qr != null)
            QuickReplyBar(
              set: _qr,
              loading: _qrLoading,
              onPick: _pickSuggestion,
              onDismiss: _dismissSuggestions,
            ),
          if (_mentionMatches.isNotEmpty)
            MentionPicker(candidates: _mentionMatches, onPick: _pickMention),
          if (_replyTo != null)
            ReplyBanner(target: _replyTo!, onCancel: _cancelReply),
          ChatComposer(
            controller: _input,
            focusNode: _inputFocus,
            onSend: (t) {
              final mentions = _mentionsInText();
              final (replyToId, replyPreview) = _consumeReply();
              c.sendText(t,
                  replyToId: replyToId, replyPreview: replyPreview, mentions: mentions);
              _mentioned.clear();
              // My own message is now the last word, so the chips that answered
              // theirs are stale — clear them rather than leave three sentences
              // hanging over a conversation that has moved on.
              _qr = null;
              _qrFor = null;
              _mentionMatches = const [];
              _jumpToBottom();
            },
            onPickImage: _pickImage,
            onSendAudio: (path, durationMs, mime, waveform) {
              final (replyToId, replyPreview) = _consumeReply();
              c.sendAudioLocal(
                localPath: path,
                mediaMime: mime,
                durationMs: durationMs,
                waveform: waveform,
                replyToId: replyToId,
                replyPreview: replyPreview,
              );
              _jumpToBottom();
            },
            onTyping: c.sendTyping,
          ),
        ],
      ),
      ),
    );
  }

  /// The header, which is the only part of this screen that knows what the
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white)),
                        ),
                        if (_muted) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.notifications_off,
                              size: 15, color: Colors.white70),
                        ],
                      ],
                    ),
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
              case 'background':
                _pickBackground();
              case 'suggest':
                _suggestNow();
              case 'media':
                _openMedia();
              case 'poll':
                _createPoll();
            }
          },
          itemBuilder: (_) => [
            if (isTeam)
              const PopupMenuItem(value: 'info', child: Text('Group info')),
            const PopupMenuItem(value: 'media', child: Text('Shared media')),
            if (widget.type != ChatChannelType.unknown)
              const PopupMenuItem(value: 'poll', child: Text('New poll')),
            if (_suggestsAtAll && !_suggestsAutomatically)
              const PopupMenuItem(value: 'suggest', child: Text('Suggest replies')),
            const PopupMenuItem(
                value: 'background', child: Text('Chat background')),
          ],
        ),
      ],
    );
  }

  IconData get _typeIcon => switch (widget.type) {
        ChatChannelType.booking => Icons.stadium_outlined,
        ChatChannelType.captain => Icons.sports_kabaddi,
        ChatChannelType.team => Icons.groups,
        ChatChannelType.direct => Icons.person_outline,
        ChatChannelType.unknown => Icons.chat_bubble_outline,
      };

  Widget _connectionBar(ChatController c) {
    return ListenableBuilder(
      listenable: c,
      builder: (_, _) {
        if (!c.reconnecting) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: AppColors.warning.withValues(alpha: 0.15),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: const Text('Connecting…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.warningText)),
        );
      },
    );
  }

  /// An empty room is never a blank screen, and the sentence says what this
  /// particular room is for — a booking room and a coordination room are opened by
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
                ChatChannelType.direct =>
                  'You are now connected.\nSay hello and set up a game.',
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
  ///
  /// Consecutive photos from one sender collapse into a single album grid (see
  /// [_albumRun]); everything else — text, a lone photo, a captioned photo, a
  /// photo still sending — stays its own bubble.
  /// The message list as a flat list of row builders — closures, not built
  /// widgets — so `ListView.builder` constructs only the rows currently on
  /// screen rather than the whole history on every controller notification. The
  /// lightweight grouping decisions (day breaks, sender runs, album runs) are
  /// still computed here; only the widget construction is deferred.
  List<Widget Function()> _buildRows(ChatController c) {
    final msgs = c.messages;
    final rows = <Widget Function()>[];
    var i = 0;
    while (i < msgs.length) {
      final m = msgs[i];
      final prev = i > 0 ? msgs[i - 1] : null;
      if (prev == null || !_sameDay(prev.createdAt, m.createdAt)) {
        rows.add(() => DateSeparator(m.createdAt));
      }
      // The unread divider sits above the first message that arrived after my
      // watermark, once, at the anchor pinned when the room opened.
      if (m.id == _unreadAnchorId) rows.add(() => const _UnreadDivider());
      if (m.isSystem) {
        rows.add(() => SystemMessagePill(m));
        i++;
        continue;
      }
      final isMine = m.senderId == _myId;
      final showSender = !isMine &&
          (prev == null ||
              prev.isSystem ||
              prev.senderId != m.senderId ||
              !_sameDay(prev.createdAt, m.createdAt));

      // A run of two or more grouped photos becomes one album grid. Every id in
      // the run maps to the run's key so a quote of any one of them can scroll to
      // the album.
      final run = _albumRun(msgs, i);
      if (run > 1) {
        final group = msgs.sublist(i, i + run);
        rows.add(() => _rowWrap(
              group.first.id,
              _keyFor(group.first.id),
              ImageAlbumBubble(
                images: group,
                isMine: isMine,
                showSender: showSender,
                tickState: c.tickFor(group.last),
                onOpen: (idx) => _openAlbum(group, idx),
                onLongPress: _enterSelection,
              ),
              replyTarget: group.first,
            ));
        i += run;
        continue;
      }

      rows.add(() => _rowWrap(
            m.id,
            _keyFor(m.id),
            MessageBubble(
              message: m,
              isMine: isMine,
              showSender: showSender,
              tickState: c.tickFor(m),
              onLongPress: () => _enterSelection(m),
              onReactionTap: (e) => c.toggleReaction(m.id, e),
              onImageTap: () => _openImage(m.mediaUrl),
              onRetry: () => c.retry(m),
              onCancel:
                  (m.pending && m.isImage) ? () => c.cancelPending(m) : null,
              onQuoteTap: m.isReply
                  ? () => _scrollToMessage(m.replyToId ?? m.replyPreview!.id)
                  : null,
              uploadProgress: c.uploadProgressFor(m),
              myUserId: _myId,
              onPollVote: (i) => c.votePoll(m, i),
              failureReason: c.sendErrorFor(m),
            ),
            replyTarget: (m.isDeleted || m.pending || m.failed) ? null : m,
          ));
      i++;
    }
    if (c.typingText != null) rows.add(() => const TypingIndicator());
    return rows;
  }

  /// A stable key per message id, reused across rebuilds so a scroll target keeps
  /// its element identity.
  GlobalKey _keyFor(String id) => _rowKeys.putIfAbsent(id, () => GlobalKey());

  /// Wrap a row with its scroll key, the brief tint applied after a quote jumps to
  /// it, and — where the message is quotable — a swipe-to-reply gesture. The tint
  /// is a background behind the bubble, so it reads as "this one" without touching
  /// the bubble's own colour.
  ///
  /// Swipe uses a [Dismissible] whose `confirmDismiss` always returns false: the
  /// row springs back rather than leaving, giving the drag animation and the reveal
  /// icon while the release simply opens a reply — the standard chat idiom.
  Widget _rowWrap(String id, GlobalKey key, Widget child, {ChatMessage? replyTarget}) {
    final highlighted = _highlightId == id;
    final selected = _selected.contains(id);
    // Full width is load-bearing, not decoration. A swipeable row is wrapped in a
    // Dismissible, whose background makes it lay the row out inside a Stack that
    // passes loose width constraints; without a width the row shrink-wraps to the
    // bubble and the bubble's own end/start alignment has no room to act, so a
    // sent message drifts to the left and reads as centred. An unswiped row (a
    // pending or failed message, replyTarget == null) is already full width from
    // the list, which is why only confirmed messages mis-aligned.
    final tinted = AnimatedContainer(
      key: key,
      width: double.infinity,
      duration: const Duration(milliseconds: 300),
      color: selected
          ? AppColors.chatSelection
          : (highlighted ? AppColors.accentLight : Colors.transparent),
      child: child,
    );
    // While selecting, a tap toggles this row and the bubble's own gestures are
    // swallowed, so an image tap or a quote tap cannot fire mid-selection.
    if (_selecting) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleSelect(id),
        onLongPress: () => _toggleSelect(id),
        child: AbsorbPointer(child: tinted),
      );
    }
    if (replyTarget == null) return tinted;
    return Dismissible(
      key: ValueKey('swipe:$id'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.25},
      confirmDismiss: (_) async {
        _startReply(replyTarget);
        return false;
      },
      background: const Padding(
        padding: EdgeInsets.only(left: 24),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Icon(Icons.reply, color: AppColors.primary),
        ),
      ),
      child: tinted,
    );
  }

  /// How many messages starting at [start] form one photo album: same sender,
  /// each a plain sent photo (no caption, not pending, not failed, not deleted,
  /// so its own state is never hidden), within five minutes of the one before,
  /// and on the same day. Returns 1 when the message at [start] does not group.
  int _albumRun(List<ChatMessage> msgs, int start) {
    bool eligible(ChatMessage m) =>
        m.isImage && !m.isDeleted && !m.pending && !m.failed && !m.hasCaption;
    final first = msgs[start];
    if (!eligible(first)) return 1;
    var n = 1;
    for (var j = start + 1; j < msgs.length; j++) {
      final m = msgs[j];
      final prev = msgs[j - 1];
      if (!eligible(m) ||
          m.senderId != first.senderId ||
          !_sameDay(prev.createdAt, m.createdAt) ||
          m.createdAt.difference(prev.createdAt).inMinutes.abs() > 5) {
        break;
      }
      n++;
    }
    return n;
  }

  void _openAlbum(List<ChatMessage> group, int index) {
    final urls = group.map((m) => m.mediaUrl).whereType<String>().toList();
    if (urls.isEmpty) return;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) =>
          ImageViewer(urls: urls, initialIndex: index.clamp(0, urls.length - 1)),
    ));
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// The "Unread messages" line drawn once above the first message that arrived
/// after the reader's watermark — the WhatsApp marker that tells them where they
/// left off, so a long backlog does not have to be re-read from the top.
class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 4),
      color: AppColors.accentLight,
      alignment: Alignment.center,
      child: const Text(
        'Unread messages',
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.primary),
      ),
    );
  }
}

/// The "forward to" sheet: the caller's other chats, one of which is returned to
/// forward the selected messages into. Shown by [_forwardSelected].
class _ForwardPicker extends StatelessWidget {
  final List<ChatChannel> channels;
  const _ForwardPicker({required this.channels});

  IconData _iconFor(ChatChannelType t) => switch (t) {
        ChatChannelType.team => Icons.groups,
        ChatChannelType.captain => Icons.shield_outlined,
        ChatChannelType.booking => Icons.event_outlined,
        _ => Icons.chat_bubble_outline,
      };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Forward to',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          if (channels.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Text('No other chats to forward to.',
                  style: TextStyle(color: AppColors.textSecondary)),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: channels.length,
                itemBuilder: (_, i) {
                  final ch = channels[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.accentLight,
                      child: Icon(_iconFor(ch.type),
                          color: AppColors.primary, size: 20),
                    ),
                    title: Text(ch.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, ch),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// The result of the poll composer: a question, its options, and whether more
/// than one answer may be chosen.
class _PollDraft {
  final String question;
  final List<String> options;
  final bool allowMultiple;
  const _PollDraft(this.question, this.options, this.allowMultiple);
}

/// The "new poll" sheet: a question, two to twelve options, and a multiple-answer
/// toggle. Pops a [_PollDraft] on create, or null when dismissed.
class _PollComposer extends StatefulWidget {
  const _PollComposer();

  @override
  State<_PollComposer> createState() => _PollComposerState();
}

class _PollComposerState extends State<_PollComposer> {
  final _question = TextEditingController();
  final _options = <TextEditingController>[TextEditingController(), TextEditingController()];
  bool _allowMultiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _question.text.trim().isNotEmpty &&
      _options.where((o) => o.text.trim().isNotEmpty).length >= 2;

  void _submit() {
    final opts = _options
        .map((o) => o.text.trim())
        .where((o) => o.isNotEmpty)
        .toList();
    Navigator.pop(context, _PollDraft(_question.text.trim(), opts, _allowMultiple));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('New poll',
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 12),
            TextField(
              controller: _question,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 300,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Question',
                hintText: 'Ask the group…',
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            const Text('Options',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            const SizedBox(height: 6),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _options[i],
                        textCapitalization: TextCapitalization.sentences,
                        maxLength: 100,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Option ${i + 1}',
                          counterText: '',
                          isDense: true,
                        ),
                      ),
                    ),
                    if (_options.length > 2)
                      IconButton(
                        icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                        tooltip: 'Remove option',
                        onPressed: () => setState(() => _options.removeAt(i).dispose()),
                      ),
                  ],
                ),
              ),
            if (_options.length < 12)
              TextButton.icon(
                onPressed: () => setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Add option'),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowMultiple,
              onChanged: (v) => setState(() => _allowMultiple = v),
              title: const Text('Allow multiple answers', style: TextStyle(fontSize: 14)),
              activeThumbColor: AppColors.accent,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _valid ? _submit : null,
                child: const Text('Create poll'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
