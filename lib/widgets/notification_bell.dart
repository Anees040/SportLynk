import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/notification_provider.dart';
import '../services/push_service.dart';
import '../utils/deep_link.dart';
import 'header_actions.dart';

/// The bell in a home-screen header — badge, tap, and the one place the whole
/// notification stack is started.
///
/// Why the bootstrap lives in a bell
/// Three things have to happen once per signed-in session, and all three need a
/// token that only exists after authentication has resolved:
///
///   1. `NotificationProvider.attach` — reads `/summary` for the badge and
///      subscribes to the socket's `notification:new`, which is what makes the
///      count move without a poll.
///   2. `PushService.registerFor` — asks for the OS permission and posts this
///      phone's FCM token to `/notifications/devices`. FCM rotates tokens without
///      warning, so this runs on every app start, not once at signup.
///   3. `DeepLink.replayPending` — fires the tray tap that opened a killed app.
///      `PushService.init()` read it before `runApp` and parked it, because at that
///      moment there was no navigator and no authenticated user to push it for.
///
/// The three home screens (player, owner, admin) are exactly the screens that
/// exist once and only once a session is authenticated, and this bell is on all
/// three. Doing it here rather than in `main()` is what guarantees the replay lands
/// on a mounted, authorised navigator instead of bouncing off `AuthGuard`.
///
/// Every step is idempotent, so mounting a second one costs nothing.
class NotificationBell extends StatefulWidget {
  /// Where the bell goes. All three homes use `/notifications`; it is a parameter
  /// only so a future screen can point at a filtered feed without a second widget.
  final String route;

  const NotificationBell({this.route = '/notifications', super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  @override
  void initState() {
    super.initState();
    // Post-frame: `attach` calls `notifyListeners`, and doing that during the build
    // that is currently mounting this widget throws. It also means the replay pushes
    // onto a navigator that has finished its first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  void _boot() {
    if (!mounted) return;
    final token = context.read<AuthProvider>().token;
    if (token == null || token.isEmpty) return;
    context.read<NotificationProvider>().attach(token);
    PushService().registerFor(token);
    DeepLink.replayPending();
  }

  @override
  void dispose() {
    // The three home screens unmount exactly when the session ends (logout pushes
    // /welcome and removes the stack), so this is where the socket subscription and
    // the cached summary are dropped. Without it a logged-out app keeps re-reading
    // /summary on every frame the old token is still in flight for.
    context.read<NotificationProvider>().detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `watch`, so the badge follows the provider. The count comes from a re-read of
    // `/summary` rather than from counting socket frames — the server decides what
    // is unread (dismissed rows out, grouped rows counted once) and a second copy of
    // that rule here is how a badge starts disagreeing with the list it opens.
    final unread = context.watch<NotificationProvider>().unread;
    return HeaderIconButton(
      icon: unread > 0 ? Icons.notifications_active : Icons.notifications_outlined,
      tooltip: 'Notifications',
      badge: unread,
      onTap: () => Navigator.pushNamed(context, widget.route),
    );
  }
}
