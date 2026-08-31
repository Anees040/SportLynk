import 'package:flutter/material.dart';

/// One row of the notification feed, as `GET /api/notifications` shapes it.
///
/// Named `AppNotification` rather than `Notification` on purpose: Flutter's own
/// `Notification` is the base class of the whole notification-bubbling tree
/// (`ScrollNotification`, `SizeChangedLayoutNotification`), and shadowing it in a
/// file that also imports material.dart produces an error message pointing at
/// something else entirely.
///
/// WHAT IS *NOT* DECIDED HERE
/// The icon, the route and the collapse wording all arrive from the server's
/// `utils/notificationTypes.js` registry. That is deliberate: a notification type
/// is added in one file, and a client that guessed its own icon would render a
/// blank square for every type shipped after its own release. This class
/// translates the registry's icon NAME to an `IconData` and does nothing else.
class AppNotification {
  final String id;
  final String type;
  final String category;
  final String priority;

  /// The registry's Material icon name, e.g. `event_available`.
  final String iconName;

  final String title;
  final String body;
  final Map<String, dynamic> payload;

  /// `{route, args}` computed server-side. Null means "no tap target" -- an
  /// account suspension, or a type whose payload was missing the id its route
  /// needs.
  final Map<String, dynamic>? deepLink;

  final String? entityType;
  final String? entityId;
  final String? bookingId;
  final String? groupKey;

  /// How many events this row collapses. 1 for everything that does not group;
  /// the server has already rewritten `title`/`body` when it is more.
  final int groupCount;

  final String? imageUrl;
  final NotificationActor? actor;

  /// Mutable so the list can mark-read optimistically without rebuilding the row
  /// from a server echo. Everything else is final.
  bool isRead;

  final DateTime? readAt;
  final DateTime? expiresAt;

  /// Server-computed, not derived here: `expires_at` is compared against the
  /// DATABASE clock, and a phone whose clock is twenty minutes fast must not grey
  /// out a challenge that is still live.
  final bool isExpired;

  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.type,
    required this.category,
    required this.priority,
    required this.iconName,
    required this.title,
    required this.body,
    required this.payload,
    required this.deepLink,
    required this.entityType,
    required this.entityId,
    required this.bookingId,
    required this.groupKey,
    required this.groupCount,
    required this.imageUrl,
    required this.actor,
    required this.isRead,
    required this.readAt,
    required this.expiresAt,
    required this.isExpired,
    required this.createdAt,
  });

  static DateTime? _date(dynamic v) {
    if (v == null) return null;
    // Postgres timestamptz serialises with an offset, so this is already absolute.
    // `.toLocal()` is applied at RENDER time, never here, so the sort stays in UTC.
    return DateTime.tryParse(v.toString());
  }

  factory AppNotification.fromJson(Map<String, dynamic> j) {
    return AppNotification(
      id: (j['id'] ?? '').toString(),
      type: (j['type'] ?? '').toString(),
      category: (j['category'] ?? 'system').toString(),
      priority: (j['priority'] ?? 'normal').toString(),
      iconName: (j['icon'] ?? 'notifications').toString(),
      title: (j['title'] ?? '').toString(),
      body: (j['body'] ?? '').toString(),
      payload: j['payload'] is Map
          ? Map<String, dynamic>.from(j['payload'] as Map)
          : <String, dynamic>{},
      deepLink: j['deepLink'] is Map
          ? Map<String, dynamic>.from(j['deepLink'] as Map)
          : null,
      entityType: j['entityType']?.toString(),
      entityId: j['entityId']?.toString(),
      bookingId: j['bookingId']?.toString(),
      groupKey: j['groupKey']?.toString(),
      groupCount: (j['groupCount'] is num) ? (j['groupCount'] as num).toInt() : 1,
      imageUrl: j['imageUrl']?.toString(),
      actor: j['actor'] is Map
          ? NotificationActor.fromJson(Map<String, dynamic>.from(j['actor'] as Map))
          : null,
      isRead: j['isRead'] == true,
      readAt: _date(j['readAt']),
      expiresAt: _date(j['expiresAt']),
      isExpired: j['isExpired'] == true,
      createdAt: _date(j['createdAt']) ?? DateTime.now().toUtc(),
    );
  }

  /// True when tapping this row leads somewhere. An expired row keeps its link
  /// but must not be offered: the screen it opens has nothing left to act on, and
  /// "nothing happened" is the worst possible answer to a tap.
  bool get isActionable => deepLink != null && !isExpired;

  String? get route => deepLink?['route']?.toString();

  Map<String, dynamic> get routeArgs {
    final a = deepLink?['args'];
    return a is Map ? Map<String, dynamic>.from(a) : <String, dynamic>{};
  }

  /// "now", "5m", "3h", "2d", then a date. Deliberately terse -- this sits in a
  /// trailing corner beside a two-line body and has no room for "about 5 minutes
  /// ago".
  String get age {
    final d = DateTime.now().toUtc().difference(createdAt.toUtc());
    if (d.inSeconds < 45) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    final l = createdAt.toLocal();
    return '${l.day}/${l.month}';
  }

  /// The registry's 37 icon names, resolved.
  ///
  /// This map is the one place a client-side guess is unavoidable, so it fails
  /// SAFE: an unmapped name falls back to a bell rather than throwing. Keep it in
  /// step with `notificationTypes.js` -- a type added there with a new icon name
  /// renders a bell until its name is added here, which is a blemish and not a
  /// bug.
  static const Map<String, IconData> _icons = {
    'ac_unit': Icons.ac_unit,
    'account_balance': Icons.account_balance,
    'account_tree': Icons.account_tree,
    'app_registration': Icons.app_registration,
    'block': Icons.block,
    'bug_report': Icons.bug_report,
    'cancel': Icons.cancel,
    'chat_bubble': Icons.chat_bubble,
    'directions_run': Icons.directions_run,
    'edit_note': Icons.edit_note,
    'emoji_events': Icons.emoji_events,
    'event_available': Icons.event_available,
    'event_busy': Icons.event_busy,
    'fact_check': Icons.fact_check,
    'gavel': Icons.gavel,
    'group_add': Icons.group_add,
    'group_off': Icons.group_off,
    'handshake': Icons.handshake,
    'help_outline': Icons.help_outline,
    'how_to_reg': Icons.how_to_reg,
    'lock_open': Icons.lock_open,
    'logout': Icons.logout,
    'military_tech': Icons.military_tech,
    'money_off': Icons.money_off,
    'payments': Icons.payments,
    'person_add': Icons.person_add,
    'person_off': Icons.person_off,
    'person_remove': Icons.person_remove,
    'schedule': Icons.schedule,
    'schedule_send': Icons.schedule_send,
    'scoreboard': Icons.scoreboard,
    'sports_soccer': Icons.sports_soccer,
    'support_agent': Icons.support_agent,
    'timer_off': Icons.timer_off,
    'undo': Icons.undo,
    'verified': Icons.verified,
    'workspace_premium': Icons.workspace_premium,
  };

  IconData get icon => _icons[iconName] ?? Icons.notifications;
}

/// Who caused the notification. Present only when the event had a human behind it
/// -- a job that expires a challenge has no actor, and rendering "System" as a
/// person would be a small lie repeated on every row.
class NotificationActor {
  final String id;
  final String? name;
  final String? avatarUrl;

  const NotificationActor({required this.id, this.name, this.avatarUrl});

  factory NotificationActor.fromJson(Map<String, dynamic> j) => NotificationActor(
        id: (j['id'] ?? '').toString(),
        name: j['name']?.toString(),
        avatarUrl: j['avatarUrl']?.toString(),
      );

  /// Initials for the avatar fallback, capped at two letters.
  String get initials {
    final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }
}

/// `GET /api/notifications/summary` -- the badge, the chip counts, and why the
/// phone is quiet.
///
/// `pushConfigured` is the honest answer to "why didn't I get a push?": an
/// unconfigured SERVER (no Firebase service account), a denied OS permission and a
/// muted category are three different problems with three different fixes, and the
/// prefs screen says which one applies instead of leaving the user to guess.
class NotificationSummary {
  final int unread;
  final Map<String, int> byCategory;
  final bool pushConfigured;

  const NotificationSummary({
    required this.unread,
    required this.byCategory,
    required this.pushConfigured,
  });

  static const NotificationSummary empty =
      NotificationSummary(unread: 0, byCategory: <String, int>{}, pushConfigured: false);

  factory NotificationSummary.fromJson(Map<String, dynamic> j) {
    final by = <String, int>{};
    final raw = j['byCategory'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is num) by[k.toString()] = v.toInt();
      });
    }
    final push = j['push'];
    return NotificationSummary(
      unread: (j['unread'] is num) ? (j['unread'] as num).toInt() : 0,
      byCategory: by,
      pushConfigured: push is Map && push['configured'] == true,
    );
  }
}
