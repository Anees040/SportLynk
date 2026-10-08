import 'package:flutter/material.dart';

import '../../models/assistant.dart';
import '../../providers/assistant_controller.dart';
import '../../services/assistant_service.dart';
import 'scout_theme.dart';

/// Scout's conversation list, as the side drawer of the chat screen.
///
/// This replaces the bottom sheet the chat list used to open in. A sheet was the wrong
/// container for it: it covered the lower half of the transcript, it could not show
/// more than a few rows without being dragged, and it read as a transient lookup rather
/// than as the place conversations live. A drawer is the shape every assistant app
/// settles on, and it gives the list the full height it needs.
///
/// It is attached as `Scaffold.drawer`, so `Navigator.pop` closes it and the hardware
/// back gesture reaches it before the screen's own [PopScope] — see the scaffold key in
/// `assistant_screen.dart`, which is what stops back from leaving Scout with the drawer
/// still open.
///
/// Every row action already exists on [AssistantController]; nothing here talks to the
/// API directly. The list is re-read after each one rather than patched in place,
/// because the server owns the ordering (newest activity first) and a locally reordered
/// list would disagree with it the moment a rename moved nothing but a title.
class ScoutDrawer extends StatefulWidget {
  final AssistantController controller;

  const ScoutDrawer({required this.controller, super.key});

  @override
  State<ScoutDrawer> createState() => _ScoutDrawerState();
}

class _ScoutDrawerState extends State<ScoutDrawer> {
  List<ScoutThread>? _threads;
  String? _error;
  bool _busy = false;

  /// Whether the drawer is showing archived chats instead of the active ones.
  ///
  /// Archiving a chat removes it from the active list — that is the whole point of
  /// it — but the conversation is kept, not deleted. This view is where it stays
  /// reachable, which is the difference between Archive and Delete: from here a chat
  /// can be read again, resumed, or unarchived back into the active list.
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await widget.controller.listThreads(includeArchived: _showArchived);
      // The active view asks the server to exclude archived threads, so the list
      // comes back ready. The archived view asks for everything and keeps only the
      // archived ones — the same list, filtered to the half this view is about.
      final shown = _showArchived ? list.where((t) => t.archived).toList() : list;
      if (mounted) setState(() => _threads = shown);
    } on ScoutUnavailable catch (e) {
      // The server's own sentence, which says more than "something went wrong".
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your chats.');
    }
  }

  /// Switch between the active list and the archive, loading the one now shown.
  void _toggleArchived() {
    setState(() {
      _showArchived = !_showArchived;
      _threads = null; // draw the loader while the other list resolves
    });
    _load();
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

  void _resume(ScoutThread t) {
    Navigator.pop(context);
    widget.controller.openThread(t.id);
  }

  void _newChat() {
    widget.controller.newChat();
    Navigator.pop(context);
  }

  Future<void> _rename(ScoutThread t) async {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameDialog(initialTitle: t.title),
    );
    if (name == null || name.isEmpty || name == t.title) return;
    setState(() => _busy = true);
    await widget.controller.renameThread(t.id, name);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _archive(ScoutThread t) async {
    setState(() => _busy = true);
    await widget.controller.archiveThread(t.id);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _unarchive(ScoutThread t) async {
    setState(() => _busy = true);
    await widget.controller.archiveThread(t.id, archived: false);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _delete(ScoutThread t) async {
    // Named `theme` rather than the usual `t`, which this class spends on the
    // thread being acted upon.
    final theme = ScoutTheme.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: theme.card,
        title: Text('Delete this chat?',
            style: TextStyle(color: theme.ink, fontSize: 16)),
        content: Text(
          'The messages go with it. Any bookings you made in this chat are unaffected — '
          'they live in your bookings, not in the conversation.',
          style: TextStyle(color: theme.inkSoft, fontSize: 12.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete', style: TextStyle(color: theme.danger)),
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
    final t = ScoutTheme.of(context);
    return Drawer(
      backgroundColor: t.card,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(t),
            Divider(height: 1, color: t.lineSoft),
            Expanded(child: _body(t)),
          ],
        ),
      ),
    );
  }

  Widget _header(ScoutTheme t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _showArchived ? 'Archived chats' : 'Your chats',
                  style: TextStyle(
                    color: t.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // The single switch between the active list and the archive. It is the
              // thing that was missing: Archive sent chats somewhere with no way back.
              TextButton.icon(
                onPressed: _busy ? null : _toggleArchived,
                icon: Icon(
                  _showArchived ? Icons.inbox_rounded : Icons.archive_outlined,
                  size: 17,
                ),
                label: Text(_showArchived ? 'Active' : 'Archived'),
                style: TextButton.styleFrom(foregroundColor: t.inkSoft),
              ),
            ],
          ),
          // Starting a new chat belongs to the active list, not the archive.
          if (!_showArchived) ...[
            const SizedBox(height: 12),
            // The one affordance that must never be hunted for. Full width and at the
            // top, because starting a new conversation is the most common reason the
            // drawer is opened at all.
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _newChat,
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('New chat'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: t.canvas,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The four states every list in this app owes the user: loading, error with a way
  /// out, empty said in words, and the list itself.
  Widget _body(ScoutTheme t) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 28, color: t.inkFaint),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.inkSoft, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final list = _threads;
    if (list == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _showArchived
                ? 'No archived chats. Archiving a chat tucks it away here without deleting it.'
                : 'No chats yet. Whatever you ask first becomes one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.inkFaint, fontSize: 12.5, height: 1.4),
          ),
        ),
      );
    }

    final current = widget.controller.threadId;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: list.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: t.lineSoft),
      itemBuilder: (_, i) => _row(t, list[i], list[i].id == current),
    );
  }

  Widget _row(ScoutTheme t, ScoutThread thread, bool active) {
    final subtitle = [
      if ((thread.preview ?? '').trim().isNotEmpty) thread.preview!.trim(),
      if (_ago(thread.lastMessageAt).isNotEmpty) _ago(thread.lastMessageAt),
    ].join('  ·  ');

    return ListTile(
      selected: active,
      selectedTileColor: t.accent.withValues(alpha: 0.08),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 10,
      leading: Icon(
        active ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
        size: 19,
        color: active ? t.accent : t.inkFaint,
      ),
      title: Text(
        thread.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: t.ink,
          fontSize: 13.5,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.inkFaint, fontSize: 11),
            ),
      trailing: PopupMenuButton<String>(
        color: t.card,
        tooltip: 'Chat options',
        icon: Icon(Icons.more_horiz_rounded, size: 19, color: t.inkFaint),
        // The menu is the only place a 48x48 target is not automatic, and an
        // icon-only button with no label is unreadable to a screen reader.
        iconSize: 19,
        constraints: const BoxConstraints(minWidth: 168),
        onSelected: (v) async {
          if (v == 'resume') _resume(thread);
          if (v == 'rename') await _rename(thread);
          if (v == 'archive') await _archive(thread);
          if (v == 'unarchive') await _unarchive(thread);
          if (v == 'delete') await _delete(thread);
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'resume', child: Text('Resume')),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          if (thread.archived)
            const PopupMenuItem(value: 'unarchive', child: Text('Unarchive'))
          else
            const PopupMenuItem(value: 'archive', child: Text('Archive')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: _busy ? null : () => _resume(thread),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String initialTitle;

  const _RenameDialog({required this.initialTitle});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoutTheme.of(context);
    return AlertDialog(
      backgroundColor: t.card,
      title: Text('Rename chat',
          style: TextStyle(color: t.ink, fontSize: 16)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 60,
        style: TextStyle(color: t.ink),
        decoration: const InputDecoration(hintText: 'Chat name'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
