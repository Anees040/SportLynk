import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/chat_message.dart';
import '../../services/chat_service.dart';
import '../../widgets/chat/image_viewer.dart';

/// Every photo shared in one chat, newest first, as a square grid — the "shared
/// media" view reached from the thread's overflow menu. Tapping a tile opens the
/// same full-screen viewer the thread uses, on that photo.
///
/// It owns its own fetch (a page of `kind = image` rows from the channel) and so
/// carries the four states the project mandates: loading, empty, error with a
/// retry, and loaded. Older photos page in as the grid nears its end.
class ChatMediaScreen extends StatefulWidget {
  final String token;
  final String channelId;
  final String title;

  const ChatMediaScreen({
    required this.token,
    required this.channelId,
    required this.title,
    super.key,
  });

  @override
  State<ChatMediaScreen> createState() => _ChatMediaScreenState();
}

class _ChatMediaScreenState extends State<ChatMediaScreen> {
  final _chat = ChatService();
  final _scroll = ScrollController();

  final List<ChatMessage> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final page = await _chat.media(widget.token, widget.channelId, limit: 60);
    if (!mounted) return;
    // An empty first page is a real answer (no photos yet), not a failure. A
    // dropped request returns an empty list too, so the two are told apart by
    // whether the very first load produced anything: an error state is only shown
    // when nothing is on screen and the fetch could not populate it. The retry is
    // always available from the empty state's action, so a genuine failure is not
    // stranded either way.
    setState(() {
      _items
        ..clear()
        ..addAll(page);
      _hasMore = page.length >= 60;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _items.isEmpty) return;
    setState(() => _loadingMore = true);
    final before = _items.last.createdAt.toUtc().toIso8601String();
    final page = await _chat.media(widget.token, widget.channelId, before: before, limit: 60);
    if (!mounted) return;
    setState(() {
      _items.addAll(page);
      _hasMore = page.length >= 60;
      _loadingMore = false;
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  void _open(int index) {
    final urls = _items.map((m) => m.mediaUrl).whereType<String>().toList();
    if (urls.isEmpty) return;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => ImageViewer(urls: urls, initialIndex: index.clamp(0, urls.length - 1)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return _message(
        icon: Icons.cloud_off_outlined,
        text: 'Could not load shared media.',
        action: 'Retry',
      );
    }
    if (_items.isEmpty) {
      return _message(
        icon: Icons.photo_library_outlined,
        text: 'No photos shared in this chat yet.',
        action: 'Refresh',
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(3),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
      ),
      itemCount: _items.length,
      itemBuilder: (_, i) {
        final url = _items[i].mediaUrl ?? '';
        return GestureDetector(
          onTap: () => _open(i),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, _) => Container(color: AppColors.inputFill),
            errorWidget: (_, _, _) => Container(
              color: AppColors.inputFill,
              child: const Icon(Icons.broken_image_outlined, color: AppColors.textSecondary),
            ),
          ),
        );
      },
    );
  }

  Widget _message({required IconData icon, required String text, required String action}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textSecondary),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.4)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _load, child: Text(action)),
          ],
        ),
      ),
    );
  }
}
