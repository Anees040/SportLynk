import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../constants/colors.dart';
import '../providers/auth_provider.dart';
import 'auth/welcome_screen.dart';
import 'player/player_home_screen.dart';
import 'owner/owner_home_screen.dart';
import 'admin/admin_home_screen.dart';

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().loadUser();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (auth.isLoading) {
          return const _SplashView();
        }

        if (auth.isAuthenticated) {
          if (auth.userRole == 'admin') {
            return const AdminHomeScreen();
          }
          if (auth.userRole == 'owner') {
            return const OwnerHomeScreen();
          }
          return const PlayerHomeScreen();
        }

        return const WelcomeScreen();
      },
    );
  }
}

/// The one splash the app shows while the saved session resolves.
///
/// It sits on [AppColors.primaryDark] — the exact colour the native Android
/// splash uses — so the native layer and this Flutter layer are visually one
/// screen: the OS splash never "flashes" into a different-looking Dart splash.
/// The logo fades and settles in over half a second so a cold start reads as a
/// deliberate entrance rather than a frozen image, and the caption tells the user
/// something is happening rather than leaving a bare spinner.
class _SplashView extends StatefulWidget {
  const _SplashView();

  @override
  State<_SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<_SplashView> with TickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..forward();

  // A slow, continuous breathing of the logo's glow so a cold start reads as a
  // live screen the app is working behind, not a frozen image. It runs
  // independently of the one-shot entrance so the mark keeps moving for the whole
  // wait, however long the saved session takes to resolve.
  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
  late final Animation<double> _scale =
      Tween<double>(begin: 0.86, end: 1.0).animate(
    CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack),
  );
  late final Animation<double> _pulse =
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut);

  @override
  void dispose() {
    _ctrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark, // iOS
      ),
      child: Scaffold(
        backgroundColor: AppColors.primaryDark,
        body: Center(
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The same circular treatment the welcome screen uses — a white
                  // avatar behind the mark and an accent glow — so the two startup
                  // surfaces read as one design. The glow breathes with [_pulse]
                  // to keep the screen feeling alive during the wait.
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) {
                      final t = _pulse.value;
                      return Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withValues(
                                  alpha: 0.18 + 0.16 * t),
                              blurRadius: 24 + 12 * t,
                              spreadRadius: 4 + 5 * t,
                            ),
                          ],
                        ),
                        child: child,
                      );
                    },
                    child: const CircleAvatar(
                      radius: 66,
                      backgroundColor: AppColors.white,
                      backgroundImage: AssetImage('assets/images/logo.png'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  RichText(
                    text: const TextSpan(children: [
                      TextSpan(
                        text: 'Sport',
                        style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.white),
                      ),
                      TextSpan(
                        text: 'Lynk',
                        style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.accent),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 28),
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      color: AppColors.accent,
                      strokeWidth: 2.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
