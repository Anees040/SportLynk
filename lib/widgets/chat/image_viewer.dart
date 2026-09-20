import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Full-screen pinch-to-zoom viewer for one or several chat photos. A lone photo
/// is a single page; several open on the tapped photo and swipe between them, with
/// a "3 of 5" counter so the run's size is never a surprise.
///
/// Shared by the chat thread (a tapped bubble or album) and the shared-media
/// gallery, so the zoom, the swipe and the counter behave identically wherever a
/// chat photo is opened.
class ImageViewer extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  const ImageViewer({required this.urls, this.initialIndex = 0, super.key});

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final PageController _pager = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.urls.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: many
            ? Text('${_index + 1} of ${widget.urls.length}',
                style: const TextStyle(fontSize: 15, color: Colors.white))
            : null,
      ),
      body: PageView.builder(
        controller: _pager,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => Center(
          child: InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: CachedNetworkImage(
              imageUrl: widget.urls[i],
              fit: BoxFit.contain,
              placeholder: (_, _) => const CircularProgressIndicator(color: Colors.white),
              errorWidget: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
            ),
          ),
        ),
      ),
    );
  }
}
