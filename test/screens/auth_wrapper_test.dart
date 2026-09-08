// The wrapper is the app's front door: it restores the saved session once and then
// decides, for the whole run, which of the four root screens the user sees.
//
// Three contracts are pinned.
//
// The first is that the session is restored exactly once, from a post-frame callback
// (:21). `loadUser` reads the token off the device and then spends a round trip on
// `GET /auth/me`, so calling it from `build` would refire on every rebuild of a
// `Consumer` that `loadUser` itself notifies — an unbounded loop through the network.
// The post-frame callback is the thing that stops that, and it is invisible in the
// rendered output, so it is asserted here by counting the calls.
//
// The second is the branch order at :85. `isLoading` is checked before
// `isAuthenticated`, which is what keeps a returning user from seeing the welcome
// screen for the frame or two it takes to read the token — a flash of "Get Started"
// followed by the home screen would look like being signed out. The tests below hold
// each state still and assert what is on screen, rather than pumping through the
// transition, because the ordering is the contract and the timing is not.
//
// The third is the role fan-out at :86. Three roles exist in the database and only
// two are named here; everything else falls through to the player home. That is
// pinned as it behaves at the end of this file, because it is silent: a fourth role
// added to the backend would land on a screen built for players with no error
// anywhere.
//
// The three home screens all load on mount, and this suite deliberately stubs nothing
// for them — their own suites own that. Where a routing test would otherwise fail on
// an error one of them reported about its own data, the error is drained with a note.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_home_screen.dart';
import 'package:sportlynk/screens/auth/welcome_screen.dart';
import 'package:sportlynk/screens/auth_wrapper.dart';
import 'package:sportlynk/screens/owner/owner_home_screen.dart';
import 'package:sportlynk/screens/player/player_home_screen.dart';

import 'screen_harness.dart';

/// [FakeAuth] with the three fields the wrapper reads made settable, and with
/// `loadUser` neutralised.
///
/// The real `loadUser` reaches `SharedPreferences` through a platform channel that no
/// widget test provides, and its own error path calls `clearToken`, which reaches the
/// same channel again — so the failure escapes as an unhandled asynchronous error
/// rather than as a test failure that names the cause. Overriding it keeps this suite
/// about the routing decision.
class _WrapperAuth extends FakeAuth {
  _WrapperAuth({
    super.role,
    this.loading = false,
    this.signedIn = true,
  });

  final bool loading;
  final bool signedIn;

  /// How many times the wrapper asked for the session to be restored.
  int loadUserCalls = 0;

  @override
  bool get isLoading => loading;

  @override
  bool get isAuthenticated => signedIn;

  @override
  Future<void> loadUser() async {
    loadUserCalls++;
  }
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('restoring the session', () {
    testWidgets('it is restored once, after the first frame', (tester) async {
      final auth = _WrapperAuth(loading: true);

      await pumpScreen(tester, const AuthWrapper(), auth: auth);
      await tester.pump();

      expect(auth.loadUserCalls, 1);
    });

    testWidgets('a rebuild does not restore it again', (tester) async {
      // :22 sits in `initState`, so the `Consumer` at :28 can rebuild as often as the
      // provider notifies without spending another `GET /auth/me`.
      final auth = _WrapperAuth(loading: true);

      await pumpScreen(tester, const AuthWrapper(), auth: auth);
      await tester.pump();
      auth.notifyListeners();
      await tester.pump();
      auth.notifyListeners();
      await tester.pump();

      expect(auth.loadUserCalls, 1);
    });

    testWidgets('nothing is fetched by the wrapper itself', (tester) async {
      // Every request on this screen belongs to whichever home screen it chose. The
      // wrapper owns no endpoint of its own.
      final auth = _WrapperAuth(loading: true);

      await pumpScreen(tester, const AuthWrapper(), auth: auth);
      await tester.pump();

      expect(api.requests, isEmpty);
    });
  });

  group('while the session is being read', () {
    testWidgets('the brand is shown with a spinner', (tester) async {
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(loading: true));

      expect(find.text('SportLynk', findRichText: true), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('neither destination is shown yet', (tester) async {
      // The point of this state: a returning user must not see "Get Started" for the
      // frame it takes to read the token.
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(loading: true));

      expect(find.byType(WelcomeScreen), findsNothing);
      expect(find.byType(PlayerHomeScreen), findsNothing);
    });

    testWidgets('loading wins over an already-authenticated session',
        (tester) async {
      // :30 is checked before :85, so a provider that is both loading and signed in
      // shows the splash rather than a home screen built on half-read state.
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(loading: true, signedIn: true));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(PlayerHomeScreen), findsNothing);
    });

    testWidgets('it does not clip at a doubled text scale', (tester) async {
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(loading: true), textScale: 2.0);

      expectNoOverflow(tester);
    });
  });

  group('without a session', () {
    testWidgets('the welcome screen is shown', (tester) async {
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(signedIn: false));
      await tester.pump();

      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('no home screen is built', (tester) async {
      // A home screen built for a signed-out user would fetch with no token and
      // render its empty state, which is a worse first impression than the welcome
      // screen and costs three failed requests.
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(signedIn: false));
      await tester.pump();

      expect(find.byType(PlayerHomeScreen), findsNothing);
      expect(find.byType(OwnerHomeScreen), findsNothing);
      expect(find.byType(AdminHomeScreen), findsNothing);
    });

    testWidgets('the role is ignored when there is no session', (tester) async {
      // A stale role left on the provider must not open the admin console.
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(role: 'admin', signedIn: false));
      await tester.pump();

      expect(find.byType(AdminHomeScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('the welcome screen asks for nothing from the API',
        (tester) async {
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(signedIn: false));
      await tester.pump();

      expect(api.requests, isEmpty);
    });
  });

  group('with a session', () {
    testWidgets('an admin lands on the admin console', (tester) async {
      api.ok('/admin/stats', {});
      api.ok('/admin/registrations', []);
      api.ok('/admin/venues/pending', []);
      api.ok('/admin/disputes', {'disputes': [], 'hasMore': false});
      api.ok('/reviews/moderation', []);
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(role: 'admin'));
      await settleData(tester);

      expect(find.byType(AdminHomeScreen), findsOneWidget);
      expect(find.byType(PlayerHomeScreen), findsNothing);

      tester.takeException();
    });

    testWidgets('an owner lands on the owner home', (tester) async {
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(role: 'owner'));
      await settleData(tester);

      expect(find.byType(OwnerHomeScreen), findsOneWidget);
      expect(find.byType(AdminHomeScreen), findsNothing);

      tester.takeException();
    });

    testWidgets('a player lands on the player home', (tester) async {
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(role: 'player'));
      await settleData(tester);

      expect(find.byType(PlayerHomeScreen), findsOneWidget);
      expect(find.byType(AdminHomeScreen), findsNothing);
      expect(find.byType(OwnerHomeScreen), findsNothing);

      tester.takeException();
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/auth_wrapper.dart:86 names `admin` and `owner` and treats every
    // other value as a player, so a role the client does not know about — a new one
    // added to the backend, or an empty string from a token that predates the column
    // — silently gets the player home with no error anywhere. The fix is to route the
    // three known roles explicitly and to show a stated failure for anything else,
    // after which this test should assert that failure.
    testWidgets('an unknown role silently gets the player home', (tester) async {
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(role: 'referee'));
      await settleData(tester);

      expect(find.byType(PlayerHomeScreen), findsOneWidget);

      tester.takeException();
    });

    testWidgets('an empty role silently gets the player home', (tester) async {
      // `userRole` falls back to '' when the user has no role at all, which reaches
      // the same branch.
      await pumpScreen(tester, const AuthWrapper(),
          auth: _WrapperAuth(role: ''));
      await settleData(tester);

      expect(find.byType(PlayerHomeScreen), findsOneWidget);

      tester.takeException();
    });
  });

  group('when the session changes under it', () {
    testWidgets('finishing the read replaces the splash with the destination',
        (tester) async {
      // The wrapper listens rather than snapshotting, so the frame after `loadUser`
      // finishes is the frame the user is home.
      var loading = true;
      final auth = _MutableAuth(() => loading);

      await pumpScreen(tester, const AuthWrapper(), auth: auth);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      loading = false;
      auth.notifyListeners();
      await settleData(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(PlayerHomeScreen), findsOneWidget);

      tester.takeException();
    });

    testWidgets('signing out returns to the welcome screen', (tester) async {
      // `logout` clears the user and notifies; nothing else pushes a route, so the
      // wrapper rebuilding to the welcome screen is the whole sign-out journey.
      var signedIn = true;
      final auth = _MutableAuth(() => false, signedIn: () => signedIn);

      await pumpScreen(tester, const AuthWrapper(), auth: auth);
      await settleData(tester);
      expect(find.byType(PlayerHomeScreen), findsOneWidget);
      tester.takeException();

      signedIn = false;
      auth.notifyListeners();
      await settleData(tester);

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(PlayerHomeScreen), findsNothing);
    });
  });
}

/// A session whose answers are read from callbacks, so a test can change them between
/// pumps the way the real provider does mid-flight.
class _MutableAuth extends FakeAuth {
  _MutableAuth(this._loading, {bool Function()? signedIn})
      : _signedIn = signedIn ?? (() => true);

  final bool Function() _loading;
  final bool Function() _signedIn;

  @override
  bool get isLoading => _loading();

  @override
  bool get isAuthenticated => _signedIn();

  @override
  Future<void> loadUser() async {}
}
