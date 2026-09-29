import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../widgets/chat/attachment_sheet.dart';

/// The in-chat live camera (Issue 2): a WhatsApp-style capture screen — live
/// preview, flash toggle, lens flip, a shutter, and a gallery shortcut that hands
/// off to the existing [showAttachmentSheet] for multi-select.
///
/// Resolves with the files to send: a single captured photo (`[shot]`), the
/// gallery's selection (one to many), or null when the user backs out. The caller
/// keeps its existing single-vs-many branching (one photo gets the caption step,
/// several are sent as a run).
///
/// Photo only. The chat backend has no video message kind, so a video mode here
/// would capture something that could never be sent — a placeholder this screen
/// deliberately does not offer.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _lensIndex = 0;
  FlashMode _flash = FlashMode.off;

  bool _initializing = true;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setUp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    // Free the camera when backgrounded, re-acquire on resume — a held-open
    // camera on another app's foreground is both a battery cost and a privacy
    // smell.
    if (state == AppLifecycleState.inactive) {
      c.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initController(_lensIndex);
    }
  }

  Future<void> _setUp() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _error = 'No camera found on this device.';
        });
        return;
      }
      // Prefer the back lens on first open.
      final back = _cameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back);
      await _initController(back >= 0 ? back : 0);
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = 'The camera could not be opened. Check the app\'s camera '
              'permission and try again.';
        });
      }
    }
  }

  Future<void> _initController(int index) async {
    if (_cameras.isEmpty) return;
    final old = _controller;
    _controller = null;
    await old?.dispose();

    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      await controller.setFlashMode(_flash);
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = 'The camera could not be started.';
        });
      }
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _lensIndex = index;
      _initializing = false;
      _error = null;
    });
  }

  Future<void> _flip() async {
    if (_cameras.length < 2) return;
    setState(() => _initializing = true);
    await _initController((_lensIndex + 1) % _cameras.length);
  }

  Future<void> _cycleFlash() async {
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    setState(() => _flash = next);
    try {
      await _controller?.setFlashMode(next);
    } catch (_) {}
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        _ => Icons.flash_on,
      };

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final shot = await c.takePicture();
      if (mounted) Navigator.pop(context, <XFile>[shot]);
    } catch (_) {
      if (mounted) {
        setState(() => _capturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not take the photo.')),
        );
      }
    }
  }

  Future<void> _openGallery() async {
    final files = await showAttachmentSheet(context, maxAssets: 10);
    if (!mounted) return;
    if (files != null && files.isNotEmpty) Navigator.pop(context, files);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _preview(),
          _topBar(),
          _bottomBar(),
        ],
      ),
    );
  }

  Widget _preview() {
    if (_error != null) return _errorView();
    final c = _controller;
    if (_initializing || c == null || !c.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }
    // Fill the screen with the preview, cropping to the viewport rather than
    // letterboxing — the WhatsApp full-bleed look.
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: c.value.previewSize?.height ?? 1,
        height: c.value.previewSize?.width ?? 1,
        child: CameraPreview(c),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                size: 56, color: Colors.white54),
            const SizedBox(height: 14),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.4)),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              onPressed: _openGallery,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose from gallery'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              tooltip: 'Close camera',
              onPressed: () => Navigator.pop(context),
            ),
            const Spacer(),
            if (_error == null)
              IconButton(
                icon: Icon(_flashIcon, color: Colors.white, size: 26),
                tooltip: 'Flash',
                onPressed: _cycleFlash,
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Gallery shortcut.
              _roundButton(
                icon: Icons.photo_library_outlined,
                label: 'Gallery',
                onTap: _openGallery,
              ),
              // Shutter.
              GestureDetector(
                onTap: _error == null ? _capture : null,
                child: Semantics(
                  button: true,
                  label: 'Take photo',
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: _capturing
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2.5),
                          )
                        : Container(
                            margin: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle, color: Colors.white),
                          ),
                  ),
                ),
              ),
              // Lens flip.
              _roundButton(
                icon: Icons.flip_camera_ios_outlined,
                label: 'Flip',
                onTap: _cameras.length > 1 ? _flip : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final disabled = onTap == null;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: disabled ? 0.06 : 0.18),
          ),
          child: Icon(icon,
              color: disabled ? Colors.white38 : Colors.white, size: 24),
        ),
      ),
    );
  }
}
