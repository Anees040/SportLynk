import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'constants/app_theme.dart';
import 'firebase_options.dart';
import 'providers/auth_provider.dart';
import 'providers/booking_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/venue_provider.dart';
import 'routes/app_routes.dart';
import 'screens/auth_wrapper.dart';
import 'services/push_service.dart';
import 'utils/deep_link.dart';

/// Entry point and nothing else.
///
/// The three things that used to live here now live where they belong:
///   • the named-route table  → `routes/app_routes.dart`
///   • the theme + scroll behaviour → `constants/app_theme.dart`
///   • the `AuthGuard` route gate → `widgets/auth_guard.dart`
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }
  // Before runApp, and deliberately so: `getInitialMessage()` is what a tray tap on
  // a killed app arrives as, it resolves exactly once, and it must be read before
  // the first frame or the link is lost. PushService parks it and
  // `DeepLink.replayPending()` fires it from the first home screen, once
  // AuthProvider has resolved -- a deep link pushed before authentication would land
  // on a screen that immediately bounces to /login.
  //
  // Its whole body is try/caught inside the service, so a phone with no Play
  // Services degrades to "no push" and never to an app that will not start.
  await PushService().init();
  runApp(const SportLynkApp());
}

class SportLynkApp extends StatelessWidget {
  const SportLynkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => VenueProvider()),
        ChangeNotifierProvider(create: (_) => BookingProvider()),
        // The bell badge on all three home headers, the feed screen, and the
        // `notification:new` socket subscription that keeps them live.
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
      ],
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: MaterialApp(
          // How a notification tap navigates. A tray tap is handled by PushService,
          // which has no BuildContext of its own -- and on a cold start there is not a
          // single mounted widget yet. One app-level key is the only way to reach the
          // navigator from there, so `DeepLink` owns it and `PushService` goes through
          // `DeepLink.open`/`park` rather than touching Navigator itself.
          navigatorKey: DeepLink.navigatorKey,
          title: 'SportLynk',
          debugShowCheckedModeBanner: false,
          scrollBehavior: NoScrollbarBehavior(),
          theme: AppTheme.light,
          home: const AuthWrapper(),
          routes: AppRoutes.map,
        ),
      ),
    );
  }
}
