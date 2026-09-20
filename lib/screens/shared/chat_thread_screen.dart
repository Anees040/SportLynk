import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'chat_media_screen.dart';
import 'image_caption_screen.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/chat_channel.dart';
import '../../models/chat_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_controller.dart';
import '../../services/chat_service.dart';
import '../../utils/snackbar_util.dart';
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
    _bootstrap();
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

  // Mute
  //
  // `muted_until` is a timestamp on the server, not a boolean, so "mute for 8
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

  /// Jump to the message a tapped quote points at. When it is loaded, its row is
  /// scrolled into view and briefly tinted; when it is not (far up the history, or
  /// never loaded), the reader is told rather than left with a dead tap.
  Future<void> _scrollToMessage(String messageId) async {
    final key = _rowKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx == null) {
      SnackbarUtil.showInfo(context, 'Scroll up to load the original message.');
      return;
    }
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.3,
    );
    if (!mounted) return;
    setState(() => _highlightId = messageId);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted && _highlightId == messageId) setState(() => _highlightId = null);
    });
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
    _scroll.dispose();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _inputFocus.dispose();
    _controller?.removeListener(_onControllerChange);
    _controller?.dispose();
    super.dispose();
  }

  // Sending an image
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
              subtitle: const Text('Select one or several'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    if (source == ImageSource.camera) {
      final picked =
          await _picker.pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 82);
      if (picked == null || !mounted) return;
      await _sendOneWithCaption(picked);
      return;
    }

    // Gallery: the in-app grid picker (recents thumbnails, multi-select). One
    // photo goes through the caption screen; several are sent as a batch, each
    // streaming in with its own instant preview and spinner.
    final assets = await AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        maxAssets: 10,
        requestType: RequestType.image,
        themeColor: AppColors.accent,
      ),
    );
    if (assets == null || assets.isEmpty || !mounted) return;

    final files = <XFile>[];
    for (final a in assets) {
      final f = await a.file;
      if (f != null) files.add(XFile(f.path, mimeType: a.mimeType));
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
      MaterialPageRoute(builder: (_) => ImageCaptionScreen(localPath: picked.path)),
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

  // Long-press actions
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
            if (!m.isDeleted && !m.pending && !m.failed)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  _startReply(m);
                },
              ),
            if (c.canPin(m))
              ListTile(
                leading: Icon(c.isPinned(m.id) ? Icons.push_pin : Icons.push_pin_outlined,
                    color: AppColors.primary),
                title: Text(c.isPinned(m.id) ? 'Unpin' : 'Pin'),
                onTap: () async {
                  Navigator.pop(context);
                  final want = !c.isPinned(m.id);
                  final r = await c.togglePin(m, pinned: want);
                  if (mounted && r['success'] != true) {
                    SnackbarUtil.showError(
                        context, r['message']?.toString() ?? 'Could not update the pin.');
                  }
                },
              ),
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
          ListenableBuilder(
            listenable: c,
            builder: (_, _) => PinnedBanner(
              pinned: c.pinned,
              onTap: (m) => _scrollToMessage(m.id),
              onUnpin: c.amAdmin ? _unpinFromBanner : null,
            ),
          ),
          Expanded(
            child: Stack(
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
                      itemBuilder: (_, i) => rows[rows.length - 1 - i],
                    );
                  },
                ),
                if (_showJump)
                  Positioned(right: 12, bottom: 12, child: _jumpButton()),
              ],
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
            onSendAudio: (path, durationMs, mime) {
              final (replyToId, replyPreview) = _consumeReply();
              c.sendAudioLocal(
                localPath: path,
                mediaMime: mime,
                durationMs: durationMs,
                replyToId: replyToId,
                replyPreview: replyPreview,
              );
              _jumpToBottom();
            },
            onTyping: c.sendTyping,
          ),
        ],
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
              case 'media':
                _openMedia();
            }
          },
          itemBuilder: (_) => [
            if (isTeam)
              const PopupMenuItem(value: 'info', child: Text('Group info')),
            const PopupMenuItem(value: 'media', child: Text('Shared media')),
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
  List<Widget> _buildRows(ChatController c) {
    final msgs = c.messages;
    final rows = <Widget>[];
    var i = 0;
    while (i < msgs.length) {
      final m = msgs[i];
      final prev = i > 0 ? msgs[i - 1] : null;
      if (prev == null || !_sameDay(prev.createdAt, m.createdAt)) {
        rows.add(DateSeparator(m.createdAt));
      }
      // The unread divider sits above the first message that arrived after my
      // watermark, once, at the anchor pinned when the room opened.
      if (m.id == _unreadAnchorId) rows.add(const _UnreadDivider());
      if (m.isSystem) {
        rows.add(SystemMessagePill(m));
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
        final key = _keyFor(group.first.id);
        rows.add(_rowWrap(
          group.first.id,
          key,
          ImageAlbumBubble(
            images: group,
            isMine: isMine,
            showSender: showSender,
            tickState: c.tickFor(group.last),
            onOpen: (idx) => _openAlbum(group, idx),
            onLongPress: _showActions,
          ),
          replyTarget: group.first,
        ));
        i += run;
        continue;
      }

      rows.add(_rowWrap(
        m.id,
        _keyFor(m.id),
        MessageBubble(
          message: m,
          isMine: isMine,
          showSender: showSender,
          tickState: c.tickFor(m),
          onLongPress: () => _showActions(m),
          onReactionTap: (e) => c.toggleReaction(m.id, e),
          onImageTap: () => _openImage(m.mediaUrl),
          onRetry: () => c.retry(m),
          onCancel: (m.pending && m.isImage) ? () => c.cancelPending(m) : null,
          onQuoteTap: m.isReply ? () => _scrollToMessage(m.replyToId ?? m.replyPreview!.id) : null,
        ),
        replyTarget: (m.isDeleted || m.pending || m.failed) ? null : m,
      ));
      i++;
    }
    if (c.typingText != null) rows.add(const TypingIndicator());
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
    final tinted = AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 300),
      color: highlighted ? AppColors.accentLight : Colors.transparent,
      child: child,
    );
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
