import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../constants/colors.dart';

/// The camera-first attachment sheet: a camera tile followed by the device's
/// recent photos, all in one grid that a drag pulls up to full height so the
/// whole gallery scrolls in — the WhatsApp attachment gesture. Multi-select is
/// numbered in tap order; the send button carries the count.
///
/// Resolves with the files to send — one capture from the camera, or one to
/// [maxAssets] chosen photos — or null when the sheet is dismissed with nothing
/// chosen. Photo access is mobile-only; the caller keeps web on image_picker.
Future<List<XFile>?> showAttachmentSheet(BuildContext context,
    {int maxAssets = 10}) {
  return showModalBottomSheet<List<XFile>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AttachmentSheet(maxAssets: maxAssets),
  );
}

class _AttachmentSheet extends StatefulWidget {
  final int maxAssets;
  const _AttachmentSheet({required this.maxAssets});

  @override
  State<_AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends State<_AttachmentSheet> {
  // A page of thumbnails, loaded as the grid nears its end so the whole gallery
  // does not decode up front.
  static const _pageSize = 60;

  final _selected = <AssetEntity>[];
  final _assets = <AssetEntity>[];
  AssetPathEntity? _album;
  bool _loading = true;
  bool _denied = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (!ps.hasAccess) {
      setState(() {
        _denied = true;
        _loading = false;
      });
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );
    if (!mounted) return;
    _album = albums.isNotEmpty ? albums.first : null;
    await _loadMore();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    final batch = await album.getAssetListPaged(page: _page, size: _pageSize);
    if (!mounted) return;
    setState(() {
      _assets.addAll(batch);
      _page++;
      _hasMore = batch.length == _pageSize;
      _loadingMore = false;
    });
  }

  void _toggle(AssetEntity a) {
    setState(() {
      if (_selected.contains(a)) {
        _selected.remove(a);
      } else if (_selected.length < widget.maxAssets) {
        _selected.add(a);
      }
    });
  }

  Future<void> _takePhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      imageQuality: 82,
    );
    if (!mounted) return;
    if (picked != null) Navigator.pop(context, [picked]);
  }

  Future<void> _send() async {
    final files = <XFile>[];
    for (final a in _selected) {
      final f = await a.file;
      if (f != null) files.add(XFile(f.path, mimeType: a.mimeType));
    }
    if (mounted) Navigator.pop(context, files);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              _grabber(),
              _header(),
              Expanded(child: _body(scrollController)),
              if (_selected.isNotEmpty) _sendBar(),
            ],
          ),
        );
      },
    );
  }

  Widget _grabber() => Container(
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.border,
          borderRadius: BorderRadius.circular(2),
        ),
      );

  Widget _header() => const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('Recent',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
        ),
      );

  Widget _body(ScrollController controller) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_denied) return _deniedView(controller);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) _loadMore();
        return false;
      },
      child: GridView.builder(
        controller: controller,
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: _assets.length + 1,
        itemBuilder: (context, i) =>
            i == 0 ? _cameraTile() : _photoTile(_assets[i - 1]),
      ),
    );
  }

  Widget _deniedView(ScrollController controller) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 20),
        const Icon(Icons.photo_library_outlined,
            size: 48, color: AppColors.textSecondary),
        const SizedBox(height: 12),
        const Text('Photo access is off',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
        const SizedBox(height: 6),
        const Text(
          'Allow photo access to pick from the gallery, or take a photo now.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13, color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => PhotoManager.openSetting(),
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Open settings'),
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: _takePhoto,
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('Take a photo'),
        ),
      ],
    );
  }

  Widget _cameraTile() {
    return GestureDetector(
      onTap: _takePhoto,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_camera, color: Colors.white, size: 26),
            SizedBox(height: 4),
            Text('Camera',
                style: TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _photoTile(AssetEntity a) {
    final index = _selected.indexOf(a);
    final selected = index >= 0;
    return GestureDetector(
      onTap: () => _toggle(a),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _Thumb(asset: a),
          ),
          if (selected)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.black.withValues(alpha: 0.25),
                border: Border.all(color: AppColors.accent, width: 2.5),
              ),
            ),
          Positioned(
            top: 6,
            right: 6,
            child: _selectionBadge(selected, index),
          ),
        ],
      ),
    );
  }

  Widget _selectionBadge(bool selected, int index) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.accent : Colors.black26,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: selected
          ? Center(
              child: Text('${index + 1}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)))
          : null,
    );
  }

  Widget _sendBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Text('${_selected.length} selected',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)),
            ),
            Material(
              color: AppColors.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _send,
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Icon(Icons.send_rounded, color: Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One grid thumbnail, decoded once on first build and cached, so scrolling the
/// gallery does not re-decode a tile each time it scrolls back into view.
class _Thumb extends StatefulWidget {
  final AssetEntity asset;
  const _Thumb({required this.asset});

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b =
        await widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(240));
    if (mounted) setState(() => _bytes = b);
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return Container(color: AppColors.inputFill);
    return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
  }
}
