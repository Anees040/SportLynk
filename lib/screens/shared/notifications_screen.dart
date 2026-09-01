import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../constants/colors.dart';
import '../../models/app_notification.dart';
import '../../providers/auth_provider.dart';
import '../../providers/notification_provider.dart';
import '../../utils/deep_link.dart';
import 'notification_prefs_screen.dart';

/// The notification feed.
///
/// Reachable from the bell on every home header (player, owner, admin) and from any
/// deep link whose route no longer exists -- so it is also the fallback screen, which
/// is why it is a plain route rather than a tab.
///
/// Why CATEGORY chips and not SECTIONS
/// The chat inbox is sectioned (Bookings / Matches / Teams) because a conversation
/// belongs to exactly one of three places and the user goes looking for it. A notification
/// feed is read newest-first: the useful axis is time, and the category is a filter
/// reached for when the target is already known. Sectioning here would
/// bury a booking rejection from four minutes ago under nine tournament alerts.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final ScrollController _scroll = ScrollController();

  /// Chip labels. `system` is included and is deliberately not mutable in the prefs
  /// screen -- a suspension notice is not something a user gets to opt out of -- but
  /// it is still filterable here, which is a different question.
  static const List<List<String>> _chips = [
    ['booking', 'Bookings'],
    ['match', 'Matches'],
    ['tournament', 'Tournaments'],
    ['chat', 'Chat'],
    ['team', 'Teams'],
    ['wallet', 'Wallet'],
    ['venue', 'Venues'],
    ['review', 'Reviews'],
    ['system', 'System'],
  ];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<NotificationProvider>();
      p.attach(context.read<AuthProvider>().token);
      p.refresh();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 400px of runway. The provider guards re-entry, so a fast flick that fires this
    // several times still issues one request.
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      context.read<NotificationProvider>().loadMore();
    }
  }

  /// Tap: mark read, then go.
  ///
  /// Read-marking happens even when there is nowhere to go. "I read it" is a fact
  /// about the user, not about whether the app had a screen to show them -- and an
  /// account-suspended notice with no deep link that stayed unread forever would keep
  /// the badge lit permanently.
  Future<void> _open(AppNotification n) async {
    final p = context.read<NotificationProvider>();
    await p.markRead(n);
    if (!mounted) return;
    if (!n.isActionable) {
      if (n.isExpired) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This one has expired.')),
        );
      }
      return;
    }
    if (!DeepLink.open(n.deepLink)) return;
    // The badge is re-read on return: the screen just opened may itself
    // have marked things read (opening a chat clears its unread notifications).
    if (mounted) p.refreshSummary();
  }

  Future<void> _confirmClearRead() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear read notifications?'),
        content: const Text(
          'Read notifications older than an hour will be deleted. '
          'Anything unread is kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true && mounted) await context.read<NotificationProvider>().clearRead();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<NotificationProvider>();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: p.unreadOnly ? 'Show all' : 'Unread only',
            onPressed: () => p.setUnreadOnly(!p.unreadOnly),
            icon: Icon(p.unreadOnly ? Icons.filter_alt : Icons.filter_alt_outlined),
          ),
          IconButton(
            tooltip: 'Mark all read',
            onPressed: p.unread == 0 ? null : p.markAllRead,
            icon: const Icon(Icons.done_all),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'prefs') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const NotificationPrefsScreen()),
                );
              } else if (v == 'clear') {
                _confirmClearRead();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'prefs', child: Text('Notification settings')),
              PopupMenuItem(value: 'clear', child: Text('Clear read')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _chipRow(p),
          Expanded(child: _list(p)),
        ],
      ),
    );
  }

  /// The filter row. Only chips with a non-zero count are drawn, plus the one that is
  /// currently selected -- otherwise this is nine chips wide on a fresh account and
  /// says nothing. The counts come from `/summary`, which returns every category
  /// (zero included) so the row does not reflow as notifications arrive.
  Widget _chipRow(NotificationProvider p) {
    final visible = _chips.where((c) {
      final n = p.byCategory[c[0]] ?? 0;
      return n > 0 || p.category == c[0];
    }).toList();
    if (visible.isEmpty) return const SizedBox(height: 4);
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final c in visible)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: p.category == c[0],
                label: Text(
                  (p.byCategory[c[0]] ?? 0) > 0 ? '${c[1]} ${p.byCategory[c[0]]}' : c[1],
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.category == c[0] ? AppColors.white : AppColors.textPrimary,
                  ),
                ),
                selectedColor: AppColors.primary,
                backgroundColor: AppColors.cardBg,
                checkmarkColor: AppColors.white,
                side: BorderSide(
                  color: p.category == c[0] ? AppColors.primary : AppColors.border,
                ),
                // Tapping the selected chip clears the filter — setCategory treats a
                // repeat as "off", which is what a chip row is expected to do.
                onSelected: (_) => p.setCategory(c[0]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _list(NotificationProvider p) {
    if (p.isLoading && p.items.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (p.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: p.refresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.18),
            Icon(
              p.error != null ? Icons.cloud_off : Icons.notifications_none,
              size: 56,
              color: AppColors.disabled,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                p.error ??
                    (p.category != null || p.unreadOnly
                        ? 'Nothing here with this filter.'
                        : 'No notifications yet.'),
                style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: p.refresh,
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: p.items.length + (p.hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.divider),
        itemBuilder: (context, i) {
          if (i >= p.items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                ),
              ),
            );
          }
          final n = p.items[i];
          return _NotificationRow(
            n: n,
            onTap: () => _open(n),
            onDismiss: () => p.dismiss(n),
            onToggleRead: () => n.isRead ? p.markUnread(n) : p.markRead(n),
          );
        },
      ),
    );
  }
}

/// One row.
///
/// Reads like a person where there is a person behind it (avatar, name) and like an
/// event where there is not (the registry's icon in a tinted square). That difference
/// is the whole reason `actor_id` is on the table: "Ali wants to join Titans" with
/// Ali's face is a different object from "Your challenge expired".
class _NotificationRow extends StatelessWidget {
  final AppNotification n;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  final VoidCallback onToggleRead;

  const _NotificationRow({
    required this.n,
    required this.onTap,
    required this.onDismiss,
    required this.onToggleRead,
  });

  /// High priority gets the accent; expired gets grey whatever its priority was.
  Color get _tint {
    if (n.isExpired) return AppColors.disabled;
    if (n.priority == 'high') return AppColors.accent;
    if (n.priority == 'low') return AppColors.textSecondary;
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    final unread = !n.isRead;
    return Dismissible(
      key: ValueKey(n.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppColors.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: AppColors.white),
      ),
      onDismissed: (_) => onDismiss(),
      child: Material(
        // The unread tint is very light on purpose: on a feed where most rows are
        // unread, a strong wash makes the read ones look like the exception.
        color: unread ? AppColors.accentLight.withValues(alpha: 0.35) : AppColors.cardBg,
        child: InkWell(
          onTap: onTap,
          onLongPress: onToggleRead,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _leading(),
                const SizedBox(width: 12),
                Expanded(child: _text()),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      n.age,
                      style: GoogleFonts.poppins(
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (unread)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _leading() {
    final actor = n.actor;
    if (actor != null && (actor.avatarUrl ?? '').isNotEmpty) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: AppColors.inputFill,
        backgroundImage: NetworkImage(actor.avatarUrl!),
      );
    }
    if (actor != null) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: AppColors.primary,
        child: Text(
          actor.initials,
          style: GoogleFonts.poppins(
            color: AppColors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: _tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(n.icon, color: _tint, size: 21),
    );
  }

  Widget _text() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                n.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: n.isRead ? FontWeight.w600 : FontWeight.w700,
                  color: n.isExpired ? AppColors.textSecondary : AppColors.textPrimary,
                ),
              ),
            ),
            // The collapse count, made visible. The server has already rewritten the
            // body to "3 new messages"; this says which fact was collapsed so the row
            // does not look like it lost two notifications.
            if (n.groupCount > 1)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${n.groupCount}',
                  style: GoogleFonts.poppins(
                    color: AppColors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        if (n.body.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            n.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 12,
              height: 1.35,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        if (n.isExpired) ...[
          const SizedBox(height: 4),
          Text(
            'Expired',
            style: GoogleFonts.poppins(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: AppColors.warning,
            ),
          ),
        ],
      ],
    );
  }
}
