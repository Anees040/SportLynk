import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// The room the photo is going to, shown as a chip beside the send button so
  /// the sender can see where it lands. Optional — omitted from callers that have
  /// no name to show.
  final String? recipientName;

  const ImageCaptionScreen({required this.localPath, this.recipientName, super.key});

  @override
  State<ImageCaptionScreen> createState() => _ImageCaptionScreenState();
}

class _ImageCaptionScreenState extends State<ImageCaptionScreen> {
  final _caption = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _caption.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget _preview() {
    return kIsWeb
        ? Image.network(widget.localPath, fit: BoxFit.contain)
        : Image.file(File(widget.localPath), fit: BoxFit.contain);
  }

  void _send() => Navigator.pop(context, _caption.text.trim());

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    // Light status-bar icons so they read over the photo and the top scrim.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        // resizeToAvoidBottomInset is handled manually so the image does not jump
        // when the keyboard opens — only the caption bar rises with it.
        resizeToAvoidBottomInset: false,
        body: Stack(
        children: [
          // The photo fills the frame and can be pinch-zoomed.
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(child: _preview()),
            ),
          ),

          // Top scrim + close, floating over the image rather than an opaque bar.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: 'Discard photo',
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Caption bar, docked to the bottom and rising with the keyboard.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, bottomInset + 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Icon(Icons.photo_size_select_actual_outlined,
                                  color: Colors.white70, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _caption,
                                  focusNode: _focus,
                                  minLines: 1,
                                  maxLines: 4,
                                  maxLength: 1024,
                                  textCapitalization: TextCapitalization.sentences,
                                  keyboardType: TextInputType.multiline,
                                  cursorColor: AppColors.accent,
                                  style: const TextStyle(
                                      fontSize: 15, color: Colors.white),
                                  decoration: const InputDecoration(
                                    hintText: 'Add a caption…',
                                    hintStyle: TextStyle(color: Colors.white60),
                                    border: InputBorder.none,
                                    counterText: '',
                                    isDense: true,
                                    contentPadding:
                                        EdgeInsets.symmetric(vertical: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if ((widget.recipientName ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  widget.recipientName!,
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.white),
                                ),
                              ),
                            ),
                          Material(
                            color: AppColors.accent,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _send,
                              child: const Padding(
                                padding: EdgeInsets.all(15),
                                child: Icon(Icons.send_rounded,
                                    color: Colors.white, size: 22),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }
}
