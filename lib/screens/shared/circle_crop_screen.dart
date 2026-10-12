import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../constants/colors.dart';

/// A full-screen circular crop step shown right after an image is picked, for every
/// avatar and team-logo upload (WhatsApp-style framing).
///
/// The picked image sits inside an [InteractiveViewer] the user can drag and
/// pinch-zoom; a circular guide is painted on top so they can centre the framing.
/// Done captures the framed SQUARE through a [RepaintBoundary], writes it to a temp
/// PNG and returns that as an [XFile] — every avatar is shown through a
/// `CircleAvatar` that clips to a circle, so a square source reads as circular
/// everywhere while staying useful if a surface ever shows it un-clipped.
///
/// The circular guide is a SIBLING of the boundary, not a child, so the dark mask is
/// drawn over the preview but never baked into the exported image. No native cropper
/// and no new dependency: `dart:ui` + `RepaintBoundary` do the whole job.
Future<XFile?> cropToCircle(BuildContext context, XFile source) {
  return Navigator.of(context).push<XFile>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CircleCropScreen(source: source),
    ),
  );
}

class CircleCropScreen extends StatefulWidget {
  final XFile source;
  const CircleCropScreen({super.key, required this.source});

  @override
  State<CircleCropScreen> createState() => _CircleCropScreenState();
}

class _CircleCropScreenState extends State<CircleCropScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  final TransformationController _controller = TransformationController();

  // Bytes rather than Image.file: a path-less XFile (web, or an in-memory pick) has
  // no file to read, and Image.memory works the same on every platform.
  Uint8List? _bytes;
  bool _loadFailed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadBytes();
  }

  Future<void> _loadBytes() async {
    try {
      final b = await widget.source.readAsBytes();
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    if (_busy || _bytes == null) return;
    setState(() => _busy = true);
    try {
      final boundary =
          _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('encode failed');
      // Write to a real temp file so the existing path-based upload flows work
      // unchanged (`CloudinaryFile.fromFile` reads a path, not bytes).
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sl_crop_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      if (mounted) Navigator.of(context).pop(XFile(file.path, mimeType: 'image/png'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not process the image. Try another.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _bytes != null && !_busy;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Adjust photo'),
        actions: [
          TextButton(
            onPressed: ready ? _done : null,
            child: Text('Done',
                style: TextStyle(
                  color: ready ? AppColors.accent : Colors.white38,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                )),
          ),
        ],
      ),
      body: _loadFailed
          ? const Center(
              child: Text('Could not open that image.',
                  style: TextStyle(color: Colors.white70)))
          : _bytes == null
              ? const Center(child: CircularProgressIndicator())
              : _cropper(),
    );
  }

  Widget _cropper() {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: LayoutBuilder(builder: (context, c) {
              final side = c.biggest.shortestSide.clamp(220.0, 420.0);
              return SizedBox(
                width: side,
                height: side,
                child: Stack(children: [
                  // Only this subtree is captured — the mask below is a sibling, so the
                  // exported PNG is the framed square image and nothing else.
                  RepaintBoundary(
                    key: _boundaryKey,
                    child: ClipRect(
                      child: InteractiveViewer(
                        transformationController: _controller,
                        minScale: 1.0,
                        maxScale: 6.0,
                        child: Image.memory(_bytes!, width: side, height: side, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: _CircleMaskPainter())),
                  ),
                ]),
              );
            }),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Text('Drag to reposition · pinch to zoom',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13)),
        ),
      ],
    );
  }
}

/// A dark overlay with a clear circle punched out, plus a thin ring — the framing
/// guide. Painted on top of (and outside) the capture boundary, so it never enters
/// the exported image.
class _CircleMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = size.shortestSide / 2;
    final hole = Path()..addOval(Rect.fromCircle(center: rect.center, radius: r));
    final mask = Path.combine(PathOperation.difference, Path()..addRect(rect), hole);
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawCircle(
      rect.center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(covariant _CircleMaskPainter oldDelegate) => false;
}
