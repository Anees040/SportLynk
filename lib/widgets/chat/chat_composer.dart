import 'dart:async';
import 'package:flutter/material.dart';
import '../../constants/colors.dart';

/// The message input bar. Owns two subtleties that make chat feel right:
///   • the send button only appears once there's something to send;
///   • typing is announced on the first keystroke and auto-stopped after a short
///     lull, so the other side sees "typing…" appear and fade like WhatsApp —
///     without a socket event per character.
class ChatComposer extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String text) onSend;
  final VoidCallback onPickImage;
  final void Function(bool isTyping) onTyping;
  final bool enabled;

  const ChatComposer({
    required this.controller,
    required this.onSend,
    required this.onPickImage,
    required this.onTyping,
    this.enabled = true,
    super.key,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  Timer? _stopTimer;
  bool _typing = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _stopTimer?.cancel();
    super.dispose();
  }

  void _onChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);

    if (has) {
      if (!_typing) {
        _typing = true;
        widget.onTyping(true);
      }
      _stopTimer?.cancel();
      _stopTimer = Timer(const Duration(milliseconds: 1800), _stopTyping);
    } else {
      _stopTyping();
    }
  }

  void _stopTyping() {
    _stopTimer?.cancel();
    if (_typing) {
      _typing = false;
      widget.onTyping(false);
    }
  }

  void _send() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    widget.controller.clear();
    _stopTyping();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.image_outlined, color: AppColors.textSecondary),
                      tooltip: 'Send a photo',
                      onPressed: widget.enabled ? widget.onPickImage : null,
                    ),
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        enabled: widget.enabled,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(fontSize: 15, color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          hintStyle: TextStyle(color: AppColors.textSecondary),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 11),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            AnimatedScale(
              scale: _hasText ? 1 : 0.9,
              duration: const Duration(milliseconds: 120),
              child: Material(
                color: _hasText ? AppColors.accent : AppColors.disabled,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _hasText && widget.enabled ? _send : null,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.send_rounded, color: Colors.white, size: 22),
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
