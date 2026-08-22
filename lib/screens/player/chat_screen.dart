import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_controller.dart';
import '../../services/chat_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/chat/chat_composer.dart';
import '../../widgets/chat/date_separator.dart';
import '../../widgets/chat/message_bubble.dart';
import '../../widgets/chat/system_message_pill.dart';
import '../../widgets/chat/typing_indicator.dart';
import 'team_roster_screen.dart';

/// The team group chat — WhatsApp in feel: day separators, sender-labelled
/// bubbles, single/double/blue ticks, live typing, reactions, and delete. The
/// heavy lifting is in [ChatController]; this screen is composition and gestures.
class ChatScreen extends StatefulWidget {
  final String teamId;
  final String teamName;
  final String? channelId;
  final String? logoUrl;

  const ChatScreen({
    required this.teamId,
    required this.teamName,
    this.channelId,
    this.logoUrl,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final auth = context.read<AuthProvider>();
    _token = auth.token ?? '';
    _myId = auth.currentUser?.id ?? '';
    _channelId = widget.channelId;
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (_channelId == null || _channelId!.isEmpty) {
      final r = await ChatService().channelForTeam(_token, widget.teamId);
      if (r['success'] == true && r['data'] is Map) {
        _channelId = '${(r['data'] as Map)['channelId']}';
      }
    }
    if (!mounted) return;
    if (_channelId == null || _channelId!.isEmpty || _channelId == 'null') {
      setState(() => _fatalError = 'This chat could not be opened.');
      return;
    }
    final c = ChatController(token: _token, channelId: _channelId!, myUserId: _myId)
      ..addListener(_onControllerChange);
    setState(() => _controller = c);
  }

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

  Future<void> _openGroupInfo() async {
    final res = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => TeamRosterScreen(teamId: widget.teamId, teamName: widget.teamName),
      ),
    );
    if (res == 'left' && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.teamName)),
        body: Center(child: Text(_fatalError!)),
      );
    }
    final c = _controller;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.teamName)),
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
          ChatComposer(
            controller: _input,
            onSend: (t) {
              c.sendText(t);
              _jumpToBottom();
            },
            onPickImage: _pickImage,
            onTyping: c.sendTyping,
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar(ChatController c) {
    return AppBar(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      titleSpacing: 0,
      title: InkWell(
        onTap: _openGroupInfo,
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white24,
              backgroundImage: (widget.logoUrl != null && widget.logoUrl!.isNotEmpty)
                  ? CachedNetworkImageProvider(widget.logoUrl!)
                  : null,
              child: (widget.logoUrl == null || widget.logoUrl!.isEmpty)
                  ? const Icon(Icons.groups, size: 18, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ListenableBuilder(
                listenable: c,
                builder: (_, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.teamName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                    Text(c.subtitle,
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
        IconButton(
          tooltip: 'Group info',
          icon: const Icon(Icons.info_outline),
          onPressed: _openGroupInfo,
        ),
      ],
    );
  }

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

  Widget _emptyState() => ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.chat_bubble_outline, size: 56, color: AppColors.textSecondary),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'This is the start of your team chat.\nSay hello 👋',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.4),
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
