import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../constants/colors.dart';

/// The step between picking a photo and sending it: see the picture full-size and
/// add an optional caption, the minimal WhatsApp flow. Deliberately no crop or
/// edit tools — the goal is a familiar, one-tap send, not an editor.
///
/// Pops with the caption (which may be empty) when the user sends, or null when
/// they back out — so the caller can tell "send with no caption" from "cancel".
class ImageCaptionScreen extends StatefulWidget {
  /// The picked file's path: a device path on mobile, a blob URL on web.
  final String localPath;

  const ImageCaptionScreen({required this.localPath, super.key});

  @override
  State<ImageCaptionScreen> createState() => _ImageCaptionScreenState();
}

class _ImageCaptionScreenState extends State<ImageCaptionScreen> {
  final _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Widget _preview() {
    return kIsWeb
        ? Image.network(widget.localPath, fit: BoxFit.contain)
        : Image.file(File(widget.localPath), fit: BoxFit.contain);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Discard photo',
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: _preview(),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(
                left: 8,
                right: 8,
                top: 8,
                bottom: MediaQuery.viewInsetsOf(context).bottom + 8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: AppColors.cardBg,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _caption,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 1024,
                        autofocus: false,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(fontSize: 15, color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          hintText: 'Add a caption…',
                          hintStyle: TextStyle(color: AppColors.textSecondary),
                          border: InputBorder.none,
                          counterText: '',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: AppColors.accent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.pop(context, _caption.text.trim()),
                      child: const Padding(
                        padding: EdgeInsets.all(14),
                        child: Icon(Icons.send_rounded, color: Colors.white, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
