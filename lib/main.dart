import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'constants/colors.dart';
import 'providers/auth_provider.dart';
import 'providers/venue_provider.dart';
import 'providers/booking_provider.dart';
import 'screens/auth_wrapper.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/player_register_screen.dart';
import 'screens/auth/owner_register_screen.dart';
import 'screens/auth/otp_screen.dart';
import 'screens/auth/forgot_password_screen.dart';
import 'screens/auth/owner_pending_screen.dart';
import 'screens/player/player_home_screen.dart';
import 'screens/owner/owner_home_screen.dart';

/// Removes scrollbar overlay on all platforms (fixes white line on web).
class _NoScrollbarBehavior extends MaterialScrollBehavior {
  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
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
      ],
      child: MaterialApp(
        title: 'SportLynk',
        debugShowCheckedModeBanner: false,
        scrollBehavior: _NoScrollbarBehavior(),
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.primary,
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: AppColors.background,
          textTheme: GoogleFonts.poppinsTextTheme(),
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.white,
            elevation: 0,
            centerTitle: true,
          ),
        ),
        home: const AuthWrapper(),
        routes: {
          '/welcome': (_) => const WelcomeScreen(),
          '/login': (_) => const LoginScreen(),
          '/register/player': (_) => const PlayerRegisterScreen(),
          '/register/owner': (_) => const OwnerRegisterScreen(),
          '/otp': (_) => const OtpScreen(),
          '/forgot-password': (_) => const ForgotPasswordScreen(),
          '/owner-pending': (_) => const OwnerPendingScreen(),
          '/player-home': (_) => const PlayerHomeScreen(),
          '/owner-home': (_) => const OwnerHomeScreen(),
        },
      ),
    );
  }
}
