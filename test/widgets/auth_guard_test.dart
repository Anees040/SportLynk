// AuthGuard: which of the four auth states are allowed to build the screen behind
// the gate, and where the other three send the user.
//
// This is the widget that decides whether an owner can reach an admin route, so the
// assertions are about two things at once: that the guarded child does not build,
// and that the redirect actually fired. Those are separable failures — a guard that
// draws the splash but never navigates leaves the user on a spinner forever, and a
// guard that navigates but builds the child first has already run that screen's
// initState against the wrong role.
//
// Three states answer with the same splash and only two of them redirect, which is
// the distinction the tests keep: `isLoading` must NOT navigate, because auth state
// is still resolving and sending a user to `/welcome` mid-restore would sign them out
// of their own session on every cold start.
//
// The role mismatch redirects with `pushNamedAndRemoveUntil`, so the stack is wiped
// rather than pushed onto — asserted here because it is the reason a route reachable
// by more than one role is registered with no `requiredRole` at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/providers/auth_provider.dart';
import 'package:sportlynk/widgets/auth_guard.dart';

import 'widget_harness.dart';

/// The three getters [AuthGuard] reads, made settable. Subclassing rather than
/// mocking keeps the provider type exact, which is what `Consumer<AuthProvider>`
/// looks up; the parent constructor touches no network.
class _FakeAuth extends AuthProvider {
  _FakeAuth({this.loading = false, this.signedIn = true, this.role = 'player'});

  bool loading;
  bool signedIn;
  String role;

  @override
  bool get isLoading => loading;

  @override
  bool get isAuthenticated => signedIn;

  @override
  String get userRole => role;

  void update({bool? loading, bool? signedIn, String? role}) {
    this.loading = loading ?? this.loading;
    this.signedIn = signedIn ?? this.signedIn;
    this.role = role ?? this.role;
    notifyListeners();
  }
}

const Widget _guarded = Text('the guarded screen');

Future<RouteLog> _pumpGuard(WidgetTester tester, _FakeAuth auth, {String? requiredRole}) =>
    pumpApp(
      tester,
      AuthGuard(requiredRole: requiredRole, child: _guarded),
      providers: [ChangeNotifierProvider<AuthProvider>.value(value: auth)],
    );

void main() {
  group('the home route for a role', () {
    test('admin and owner have their own, and everything else is a player', () {
      expect(AuthGuard.homeRouteFor('admin'), '/admin-home');
      expect(AuthGuard.homeRouteFor('owner'), '/owner-home');
      expect(AuthGuard.homeRouteFor('player'), '/player-home');
      expect(AuthGuard.homeRouteFor(''), '/player-home');
      expect(AuthGuard.homeRouteFor(null), '/player-home');
      expect(AuthGuard.homeRouteFor('Admin'), '/player-home');
    });
  });

  group('still resolving', () {
    // The one blocked state that must not navigate: a cold start restoring a token
    // passes through here, and a redirect would sign the user out of their session.
    testWidgets('the splash is shown and nothing is navigated', (tester) async {
      final log = await _pumpGuard(tester, _FakeAuth(loading: true, signedIn: false));
      // The splash spinner is indeterminate, so this tree never settles: the frame
      // that would run a redirect is pumped by hand instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byWidget(_guarded), findsNothing);
      expect(log.isEmpty, isTrue);
    });

    testWidgets('the splash carries the brand colours', (tester) async {
      await _pumpGuard(tester, _FakeAuth(loading: true));
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
          AppColors.primary);
      expect(
          tester
              .widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator))
              .color,
          AppColors.accent);
    });
  });

  group('signed out', () {
    testWidgets('the guarded screen never builds and welcome is pushed', (tester) async {
      final log = await _pumpGuard(tester, _FakeAuth(signedIn: false));
      expect(find.byWidget(_guarded), findsNothing);
      await tester.pumpAndSettle();
      expect(log.pushed, ['/welcome']);
    });

    testWidgets('the stack is wiped, so the guard is gone afterwards', (tester) async {
      await _pumpGuard(tester, _FakeAuth(signedIn: false));
      await tester.pumpAndSettle();
      expect(find.byType(AuthGuard), findsNothing);
      expect(find.text('route:/welcome'), findsOneWidget);
    });
  });

  group('signed in as the wrong role', () {
    testWidgets('an owner on an admin route goes to the owner home', (tester) async {
      final log = await _pumpGuard(tester, _FakeAuth(role: 'owner'), requiredRole: 'admin');
      expect(find.byWidget(_guarded), findsNothing);
      await tester.pumpAndSettle();
      expect(log.pushed, ['/owner-home']);
    });

    testWidgets('a player on an owner route goes to the player home', (tester) async {
      final log = await _pumpGuard(tester, _FakeAuth(role: 'player'), requiredRole: 'owner');
      await tester.pumpAndSettle();
      expect(log.pushed, ['/player-home']);
    });
  });

  group('allowed through', () {
    testWidgets('a matching role builds the screen and navigates nowhere', (tester) async {
      final log = await _pumpGuard(tester, _FakeAuth(role: 'owner'), requiredRole: 'owner');
      await tester.pumpAndSettle();
      expect(find.byWidget(_guarded), findsOneWidget);
      expect(log.isEmpty, isTrue);
    });

    // A route with no `requiredRole` is open to every signed-in user by design.
    testWidgets('an unrestricted route accepts any signed-in role', (tester) async {
      for (final role in const ['player', 'owner', 'admin']) {
        final log = await _pumpGuard(tester, _FakeAuth(role: role));
        await tester.pumpAndSettle();
        expect(find.byWidget(_guarded), findsOneWidget, reason: 'blocked a $role');
        expect(log.isEmpty, isTrue);
      }
    });

    // The gate is a listener, not a one-shot: a session that finishes restoring has
    // to reveal the screen without the route being rebuilt.
    testWidgets('the screen appears when loading finishes', (tester) async {
      final auth = _FakeAuth(loading: true, signedIn: false);
      await _pumpGuard(tester, auth);
      expect(find.byWidget(_guarded), findsNothing);
      auth.update(loading: false, signedIn: true, role: 'player');
      await tester.pumpAndSettle();
      expect(find.byWidget(_guarded), findsOneWidget);
    });
  });
}
