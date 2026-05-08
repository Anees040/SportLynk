import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants/colors.dart';
import '../providers/auth_provider.dart';
import 'auth/welcome_screen.dart';
import 'auth/owner_pending_screen.dart';
import 'player/player_home_screen.dart';
import 'owner/owner_home_screen.dart';

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
          return Scaffold(
            backgroundColor: AppColors.primary,
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accent.withValues(alpha: 0.3),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/logo.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  RichText(
                    text: const TextSpan(children: [
                      TextSpan(
                        text: 'Sport',
                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: AppColors.white),
                      ),
                      TextSpan(
                        text: 'Lynk',
                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: AppColors.accent),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 24),
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      color: AppColors.accent,
                      strokeWidth: 3,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (auth.isAuthenticated) {
          if (auth.userRole == 'owner' && auth.isPendingOwner) {
            return const OwnerPendingScreen();
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
