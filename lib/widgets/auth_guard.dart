import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/colors.dart';
import '../providers/auth_provider.dart';

/// Route-level gate: resolves auth state before a guarded screen is allowed to build.
///
/// Lifted out of `main.dart` behaviour-for-behaviour. Three states are answered with the
/// same splash — still loading, not authenticated, and wrong role — because in all three
/// the screen behind the guard must not build, and two of them navigate away on the next
/// frame.
///
/// NOTE ON THE REDIRECT, because it decides how routes are registered: a role mismatch
/// answers with `pushNamedAndRemoveUntil`, which WIPES the stack and sends the user to
/// their own home. That is right for a mis-tap and wrong for a notification tap, which is
/// why a route reachable by more than one role is registered in `AppRoutes` with no
/// `requiredRole` at all rather than with a tighter one.
class AuthGuard extends StatelessWidget {
  final Widget child;
  final String? requiredRole;

  const AuthGuard({required this.child, this.requiredRole, super.key});

  /// The one splash every blocked state returns. Identical tree to the three copies it
  /// replaces, and `const` so it is allocated once rather than per build.
  static const Widget _splash = Scaffold(
    backgroundColor: AppColors.primary,
    body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
  );

  /// The home route for a role. Anything that is neither admin nor owner is a player.
  static String homeRouteFor(String? role) {
    if (role == 'admin') return '/admin-home';
    if (role == 'owner') return '/owner-home';
    return '/player-home';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        // Still resolving auth state — show the splash, do not redirect anywhere yet.
        if (auth.isLoading) return _splash;

        // Not authenticated — back to welcome.
        if (!auth.isAuthenticated) {
          _redirect(context, '/welcome');
          return _splash;
        }

        // Authenticated as the wrong role — to that role's own home.
        if (requiredRole != null && auth.userRole != requiredRole) {
          _redirect(context, homeRouteFor(auth.userRole));
          return _splash;
        }

        return child;
      },
    );
  }

  /// Navigation cannot happen during a build, so it is deferred by one frame — and
  /// `mounted` is re-checked inside the callback, because the widget can be gone by the
  /// time the frame lands.
  static void _redirect(BuildContext context, String route) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        Navigator.pushNamedAndRemoveUntil(context, route, (r) => false);
      }
    });
  }
}
