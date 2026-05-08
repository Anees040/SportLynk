import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'constants/colors.dart';
import 'providers/auth_provider.dart';
import 'providers/venue_provider.dart';
import 'providers/booking_provider.dart';
import 'firebase_options.dart';
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

Future<void> main() async {
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
          '/welcome': (context) => const WelcomeScreen(),
          '/login': (context) => const LoginScreen(),
          '/register/player': (context) => const PlayerRegisterScreen(),
          '/register/owner': (context) => const OwnerRegisterScreen(),
          '/otp': (context) => const OtpScreen(),
          '/forgot-password': (context) => const ForgotPasswordScreen(),
          '/owner-pending': (context) => const OwnerPendingScreen(),
          '/player-home': (context) => const PlayerHomeScreen(),
          '/owner-home': (context) => const OwnerHomeScreen(),
        },
      ),
    );
  }
}
