import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import '../../providers/assistant_controller.dart';
import 'scout_chips.dart';
import 'scout_theme.dart';

/// The two sheets the app bar opens: the user's chats, and what Scout can do.
///
/// Both are bottom sheets rather than screens because they are lookups, not
/// destinations — the same conversation is still there either way, and a push/pop
/// would lose the scroll position of the transcript being read.

/// Every chat this user has with Scout.
///
/// The user asked for a "generic assistant" with real chat management, and this is it:
/// switch, rename, archive, delete. None of it is Scout-specific — a thread is a
/// `chat_channels` row of type 'assistant', so it already has a title, a preview and a
/// message count without a table of its own.
Future<void> showScoutThreadsSheet(
  BuildContext context,
  AssistantController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ScoutTheme.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ThreadsSheet(controller: controller),
  );
}

class _ThreadsSheet extends StatefulWidget {
  final AssistantController controller;

  const _ThreadsSheet({required this.controller});

  @override
  State<_ThreadsSheet> createState() => _ThreadsSheetState();
}

class _ThreadsSheetState extends State<_ThreadsSheet> {
  List<ScoutThread>? _threads;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.controller.listThreads();
      if (mounted) setState(() => _threads = list);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your chats.');
    }
  }

  /// "3m", "5h", "2d" — enough to place a conversation, short enough for one line.
  static String _ago(DateTime? at) {
    if (at == null) return '';
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${(d.inDays / 7).floor()}w';
  }

  Future<void> _rename(ScoutThread t) async {
    final ctrl = TextEditingController(text: t.title);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ScoutTheme.card,
        title: const Text('Rename chat', style: TextStyle(color: ScoutTheme.ink, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          style: const TextStyle(color: ScoutTheme.ink),
          decoration: const InputDecoration(hintText: 'Chat name'),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || name == t.title) return;
    setState(() => _busy = true);
    await widget.controller.renameThread(t.id, name);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _delete(ScoutThread t) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ScoutTheme.card,
        title: const Text('Delete this chat?',
            style: TextStyle(color: ScoutTheme.ink, fontSize: 16)),
        content: const Text(
          'The messages go with it. Any bookings you made in this chat are unaffected — '
          'they live in your bookings, not in the conversation.',
          style: TextStyle(color: ScoutTheme.inkSoft, fontSize: 12.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: ScoutTheme.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy = true);
    await widget.controller.deleteThread(t.id);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _threads;
    final current = widget.controller.threadId;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Your chats',
                    style: TextStyle(
                      color: ScoutTheme.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          widget.controller.newChat();
                          Navigator.pop(context);
                        },
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text('New chat'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 22),
                child: Text(
                  _error!,
                  style: const TextStyle(color: ScoutTheme.danger, fontSize: 12.5),
                ),
              )
            else if (list == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 26),
                child: Text(
                  'No chats yet. Whatever you ask first becomes one.',
                  style: TextStyle(color: ScoutTheme.inkFaint, fontSize: 12.5),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(
                    height: 1,
                    color: ScoutTheme.lineSoft,
                  ),
                  itemBuilder: (_, i) {
                    final t = list[i];
                    final active = t.id == current;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        active ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
                        size: 18,
                        color: active ? ScoutTheme.accent : ScoutTheme.inkFaint,
                      ),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ScoutTheme.ink,
                          fontSize: 13.5,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        [
                          if ((t.preview ?? '').trim().isNotEmpty) t.preview!.trim(),
                          if (_ago(t.lastMessageAt).isNotEmpty) _ago(t.lastMessageAt),
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: ScoutTheme.inkFaint, fontSize: 11),
                      ),
                      trailing: PopupMenuButton<String>(
                        color: ScoutTheme.card,
                        icon: const Icon(
                          Icons.more_horiz_rounded,
                          size: 18,
                          color: ScoutTheme.inkFaint,
                        ),
                        onSelected: (v) async {
                          if (v == 'rename') await _rename(t);
                          if (v == 'archive') {
                            setState(() => _busy = true);
                            await widget.controller.archiveThread(t.id);
                            if (!mounted) return;
                            setState(() => _busy = false);
                            await _load();
                          }
                          if (v == 'delete') await _delete(t);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'archive', child: Text('Archive')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                      onTap: _busy
                          ? null
                          : () {
                              Navigator.pop(context);
                              widget.controller.openThread(t.id);
                            },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What Scout can do, with the one-line description of each.
///
/// The in-chat capability card shows the same abilities as bare chips; this sheet is
/// where the glosses live, because sixteen descriptions would push the sentence that
/// prompted them off the top of the chat. Reachable from the app bar at any time, so
/// "what can this thing even do" never requires guessing a phrase first.
///
/// Every row is a button that posts its action. That is the mechanism that makes the
/// abilities the released classifier has no label for — finding players, opening a
/// route in Maps — fully usable: a tap runs the action and never consults the model.
Future<void> showScoutHelpSheet(
  BuildContext context, {
  required List<ScoutCapability> capabilities,
  required void Function(ScoutChip chip) onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ScoutTheme.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final groups = ScoutCapability.grouped(capabilities);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.78,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'What I can do',
                  style: TextStyle(
                    color: ScoutTheme.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Tap one, or just type it in your own words — English, Roman Urdu, either.',
                  style: TextStyle(color: ScoutTheme.inkFaint, fontSize: 11.5, height: 1.35),
                ),
                const SizedBox(height: 14),
                if (capabilities.isEmpty)
                  const Text(
                    'I could not load the list just now. Ask me anything anyway — grounds, '
                    'bookings, teams, your wallet.',
                    style: TextStyle(color: ScoutTheme.inkSoft, fontSize: 12.5, height: 1.4),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final g in groups) ...[
                          Padding(
                            padding: EdgeInsets.only(top: g == groups.first ? 0 : 16, bottom: 6),
                            child: Text(
                              g.group.toUpperCase(),
                              style: const TextStyle(
                                color: ScoutTheme.inkFaint,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                          for (final c in g.items)
                            _CapabilityRow(
                              capability: c,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                onPick(ScoutChip(label: c.label, action: c.action));
                              },
                            ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _CapabilityRow extends StatelessWidget {
  final ScoutCapability capability;
  final VoidCallback onTap;

  const _CapabilityRow({required this.capability, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(ScoutChipIcons.of(capability.action), size: 16, color: ScoutTheme.accent),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      capability.label,
                      style: const TextStyle(
                        color: ScoutTheme.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (capability.gloss.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        capability.gloss,
                        style: const TextStyle(
                          color: ScoutTheme.inkFaint,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 17, color: ScoutTheme.inkFaint),
            ],
          ),
        ),
      );
}
