// The only screen that decides whether a phone stays quiet, and the only one whose
// switches are read by a background job rather than by the app.
//
// Four contracts are pinned.
//
// The first is that the server owns the truth. `_save` (:97) writes optimistically for
// the switch animation and then replaces its own state with the body the server echoed
// back, because `PUT /preferences` normalises what it stores — an unknown category is
// dropped and a malformed time falls back — and a rejected value shown as if it stuck
// is the one failure a settings screen must not have.
//
// The second is that muting everything does not rewrite the per-category flags (:361).
// The master switch disables the push column and leaves the values alone, so turning
// it back off restores exactly what was there before; the in-app column stays live
// throughout, since muting a phone is not the same as silencing the bell inside the
// app.
//
// The third is the always-on category. Anything the server lists in `unmutable`
// renders locked with both switches disabled and both reading on (:398, :404),
// regardless of what the stored flags say — a suspension notice is not optional.
//
// The fourth is the delivery note at :256. Three different reasons for a quiet phone
// have three different fixes and only the server knows which applies, so the note says
// which one it is rather than claiming push is on.
//
// One branch of that note is not reachable here. `PushService().isReady` is false
// without a real FCM token, so the third branch — the one that says banners work — has
// no coverage; the two that report a problem do.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sportlynk/providers/notification_provider.dart';
import 'package:sportlynk/screens/shared/notification_prefs_screen.dart';

import '../screen_harness.dart';

const String prefsPath = '/notifications/preferences';

/// A provider that reports the server has push configured.
///
/// `pushConfigured` comes off a summary the real provider fetches, and the fetch is
/// not part of this screen; overriding the getter is what reaches the second branch of
/// the delivery note.
class _Configured extends NotificationProvider {
  @override
  bool get pushConfigured => true;
}

/// The envelope `NotificationPrefs.fromJson` reads (notification_service.dart:61).
Object prefsBody({
  bool muteAll = false,
  Map<String, bool> push = const <String, bool>{},
  Map<String, bool> inApp = const <String, bool>{},
  bool quietEnabled = false,
  String quietStart = '22:00',
  String quietEnd = '07:00',
  List<String> categories = const <String>['booking', 'system'],
  List<String> unmutable = const <String>['system'],
}) =>
    <String, Object?>{
      'prefs': <String, Object?>{
        'muteAll': muteAll,
        'push': push,
        'inApp': inApp,
        'quietHours': <String, Object?>{
          'enabled': quietEnabled,
          'start': quietStart,
          'end': quietEnd,
        },
      },
      'categories': categories,
      'unmutable': unmutable,
    };

/// The master switch. The two-category fixture puts the rest at fixed offsets: the
/// push and in-app switches of category `i` at `1 + i * 2` and `2 + i * 2`, and the
/// quiet-hours switch after all of them.
Finder master() => find.byType(Switch).at(0);
Finder pushOf(int index) => find.byType(Switch).at(1 + index * 2);
Finder inAppOf(int index) => find.byType(Switch).at(2 + index * 2);
Finder quiet(int categories) => find.byType(Switch).at(1 + categories * 2);

Future<void> pumpPrefs(
  WidgetTester tester, {
  FakeAuth? auth,
  NotificationProvider? notifications,
  double textScale = 1.0,
}) async {
  // The category label row (:371) overflows by a few pixels under the test font, whose
  // glyphs are square ems and roughly twice the width of the Inter the screen asks
  // for. It is an artifact of the font substitution rather than a layout the phone
  // shows, and an unclaimed overflow report fails whichever test pumps next.
  ignoreOverflow();
  await pumpScreen(
    tester,
    const NotificationPrefsScreen(),
    auth: auth,
    providers: [
      ChangeNotifierProvider<NotificationProvider>.value(
        value: notifications ?? NotificationProvider(),
      ),
    ],
    textScale: textScale,
  );
  await settleData(tester);
}

Map<String, dynamic> sentBody(FakeApi api, {int at = 0}) =>
    jsonDecode(api.to(prefsPath)[at].body!) as Map<String, dynamic>;

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('while the settings are being fetched', () {
    testWidgets('a spinner is shown rather than an empty form', (tester) async {
      // Pumped without `pumpPrefs` because the point is the state before the fetch
      // lands, so the overflow that helper claims is claimed here instead.
      ignoreOverflow();
      api.ok(prefsPath, prefsBody(), delay: const Duration(milliseconds: 300));

      await pumpScreen(tester, const NotificationPrefsScreen(), providers: [
        ChangeNotifierProvider<NotificationProvider>.value(
            value: NotificationProvider()),
      ]);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('the settings are fetched once on open', (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester);

      expect(api.to(prefsPath), hasLength(1));
      expect(api.to(prefsPath).single.method, 'GET');
    });
  });

  group('when the settings cannot be fetched', () {
    testWidgets('an unauthenticated session is told to sign in', (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester, auth: FakeAuth(token: null));

      expect(find.text('Sign in to change notification settings.'),
          findsOneWidget);
    });

    testWidgets('an unauthenticated session spends no request', (tester) async {
      // :44 — the token is checked before the call, so a signed-out user does not
      // produce a 401 in the log for something the client already knew.
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester, auth: FakeAuth(token: null));

      expect(api.to(prefsPath), isEmpty);
    });

    testWidgets('a refused request is reported with a way to retry',
        (tester) async {
      api.fail(prefsPath, 'Preferences unavailable.');

      await pumpPrefs(tester);

      expect(find.text('Could not load your settings. Pull to retry.'),
          findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    });

    testWidgets('a dropped connection is reported the same way', (tester) async {
      api.offline(prefsPath);

      await pumpPrefs(tester);

      expect(find.text('Could not load your settings. Pull to retry.'),
          findsOneWidget);
    });

    testWidgets('no switches are offered while the settings are unknown',
        (tester) async {
      // A form drawn from defaults would show a state the server never sent, and the
      // first switch touched would write it back as if the user had chosen it.
      api.offline(prefsPath);

      await pumpPrefs(tester);

      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('a pull fetches again', (tester) async {
      api.offline(prefsPath);
      await pumpPrefs(tester);

      api.ok(prefsPath, prefsBody());
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await settleData(tester);
      await tester.pumpAndSettle();

      expect(api.to(prefsPath), hasLength(2));
      expect(find.text('Mute everything'), findsOneWidget);
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/shared/notification_prefs_screen.dart:175 gives the error state an
    // icon and a sentence but no button: the only retry is the `RefreshIndicator` pull
    // it is wrapped in, which is undiscoverable on a screen that is otherwise a list
    // of switches, and unreachable for anyone driving the app by keyboard or a screen
    // reader's gestures. The project rule asks for an error state with a retry; the
    // fix is a `TextButton` calling `_load` beside the sentence.
    testWidgets('the error state has no retry button', (tester) async {
      api.offline(prefsPath);

      await pumpPrefs(tester);

      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
    });
  });

  group('what the form offers', () {
    testWidgets('the screen names itself', (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester);

      expect(find.text('Notification settings'), findsOneWidget);
    });

    testWidgets('the master switch and both sections are shown',
        (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester);

      expect(find.text('Mute everything'), findsOneWidget);
      expect(find.text('What you get notified about'), findsOneWidget);
      expect(find.text('Quiet hours'), findsOneWidget);
    });

    testWidgets('each column says what it controls', (tester) async {
      // 'Push' and 'In-app' mean nothing on their own, and the difference between
      // them is the whole point of the screen.
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester);

      expect(find.text('PUSH'), findsWidgets);
      expect(find.text('IN-APP'), findsWidgets);
      expect(
          find.textContaining('PUSH is the banner on your phone'), findsOneWidget);
    });

    testWidgets('a category is named and explained', (tester) async {
      api.ok(prefsPath, prefsBody(categories: const ['booking']));

      await pumpPrefs(tester);

      expect(find.text('Bookings'), findsOneWidget);
      expect(find.text('Approvals, rejections, reminders, no-shows'),
          findsOneWidget);
    });

    testWidgets('the order the server sent is the order shown', (tester) async {
      // The server groups these deliberately; re-sorting them client-side would put
      // the account row somewhere different on every build.
      api.ok(prefsPath,
          prefsBody(categories: const ['wallet', 'booking'], unmutable: const []));

      await pumpPrefs(tester);

      expect(tester.getTopLeft(find.text('Wallet & payments')).dy,
          lessThan(tester.getTopLeft(find.text('Bookings')).dy));
    });

    testWidgets('a category this build does not know is still shown',
        (tester) async {
      // :356 falls back to the raw key title-cased, so a category added on the server
      // is switchable before the app ships a label for it.
      api.ok(prefsPath,
          prefsBody(categories: const ['payout'], unmutable: const []));

      await pumpPrefs(tester);

      expect(find.text('Payout'), findsOneWidget);
    });

    testWidgets('an old server sending no categories still gets a form',
        (tester) async {
      // :189 — an empty list falls back to the nine this build knows rather than
      // rendering a card with nothing in it.
      api.ok(prefsPath, prefsBody(categories: const [], unmutable: const []));

      await pumpPrefs(tester);

      expect(find.text('Bookings'), findsOneWidget);
      expect(find.text('Account & system'), findsOneWidget);
    });

    testWidgets('a missing flag counts as on', (tester) async {
      // `_flags` reads `val != false` (notification_service.dart), so a server that
      // has never stored a preference for a category leaves it enabled.
      api.ok(prefsPath,
          prefsBody(categories: const ['booking'], unmutable: const []));

      await pumpPrefs(tester);

      expect(tester.widget<Switch>(pushOf(0)).value, isTrue);
    });

    testWidgets('a stored off flag is shown off', (tester) async {
      api.ok(
          prefsPath,
          prefsBody(
            categories: const ['booking'],
            unmutable: const [],
            push: const {'booking': false},
          ));

      await pumpPrefs(tester);

      expect(tester.widget<Switch>(pushOf(0)).value, isFalse);
      expect(tester.widget<Switch>(inAppOf(0)).value, isTrue);
    });
  });

  group('the delivery note', () {
    testWidgets('a server with no push key says so', (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester);

      expect(
          find.textContaining(
              'Phone banners are not switched on for this server yet'),
          findsOneWidget);
    });

    testWidgets('a phone that never registered is told what to do',
        (tester) async {
      // The fix belongs in the device settings rather than on this screen, so the
      // note has to name it.
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester, notifications: _Configured());

      expect(
          find.textContaining('This phone has not registered for banners'),
          findsOneWidget);
    });

    testWidgets('the note never claims banners are working', (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester, notifications: _Configured());

      expect(find.text('This phone is registered for banners.'), findsNothing);
    });
  });

  group('muting everything', () {
    testWidgets('the master switch is written to the server', (tester) async {
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      await tapVisible(tester, master());
      await settleData(tester);

      final put = api.to(prefsPath).last;
      expect(put.method, 'PUT');
      expect((jsonDecode(put.body!) as Map)['muteAll'], isTrue);
    });

    testWidgets('the push column is disabled while everything is muted',
        (tester) async {
      api.ok(prefsPath,
          prefsBody(muteAll: true, categories: const ['booking'], unmutable: const []));

      await pumpPrefs(tester);

      expect(tester.widget<Switch>(pushOf(0)).onChanged, isNull);
    });

    testWidgets('the in-app column stays usable while everything is muted',
        (tester) async {
      // Muting a phone is not the same as silencing the bell inside the app, and a
      // user who mutes push still reads the list.
      api.ok(prefsPath,
          prefsBody(muteAll: true, categories: const ['booking'], unmutable: const []));

      await pumpPrefs(tester);

      expect(tester.widget<Switch>(inAppOf(0)).onChanged, isNotNull);
    });

    testWidgets('the per-category values survive the mute', (tester) async {
      // :361 — the switches are disabled rather than forced off, so unmuting restores
      // what the user had rather than a row of defaults.
      api.ok(
          prefsPath,
          prefsBody(
            muteAll: true,
            categories: const ['booking'],
            unmutable: const [],
            push: const {'booking': false},
          ));

      await pumpPrefs(tester);

      expect(tester.widget<Switch>(pushOf(0)).value, isFalse);
    });

    testWidgets('the subtitle says what muting does', (tester) async {
      api.ok(prefsPath, prefsBody(muteAll: true));

      await pumpPrefs(tester);

      expect(
          find.text(
              'Your phone stays silent. Notifications still arrive in the app.'),
          findsOneWidget);
    });
  });

  group('a category the server will not let go of', () {
    testWidgets('it is marked locked', (tester) async {
      api.ok(prefsPath, prefsBody(categories: const ['system']));

      await pumpPrefs(tester);

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('neither switch can be moved', (tester) async {
      api.ok(prefsPath, prefsBody(categories: const ['system']));

      await pumpPrefs(tester);

      expect(tester.widget<Switch>(pushOf(0)).onChanged, isNull);
      expect(tester.widget<Switch>(inAppOf(0)).onChanged, isNull);
    });

    testWidgets('it reads on however it was stored', (tester) async {
      // :398 — a suspension notice is not optional, so a stored `false` is ignored
      // rather than shown as an off switch the user cannot turn back on.
      api.ok(
          prefsPath,
          prefsBody(
            categories: const ['system'],
            push: const {'system': false},
            inApp: const {'system': false},
          ));

      await pumpPrefs(tester);

      expect(tester.widget<Switch>(pushOf(0)).value, isTrue);
      expect(tester.widget<Switch>(inAppOf(0)).value, isTrue);
    });

    testWidgets('muting everything does not disable it further', (tester) async {
      api.ok(prefsPath, prefsBody(muteAll: true, categories: const ['system']));

      await pumpPrefs(tester);

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });
  });

  group('quiet hours', () {
    testWidgets('the times are hidden while quiet hours are off',
        (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester);

      expect(find.text('Start'), findsNothing);
      expect(find.text('Off — push can arrive at any time'), findsOneWidget);
    });

    testWidgets('the times are shown once quiet hours are on', (tester) async {
      api.ok(prefsPath, prefsBody(quietEnabled: true));

      await pumpPrefs(tester);

      expect(find.text('Start'), findsOneWidget);
      expect(find.text('End'), findsOneWidget);
    });

    testWidgets('the times are shown in the clock the phone uses',
        (tester) async {
      // The server stores 24-hour times; a Pakistani user reads 10 PM.
      api.ok(prefsPath, prefsBody(quietEnabled: true));

      await pumpPrefs(tester);

      expect(find.text('10:00 PM'), findsOneWidget);
      expect(find.text('7:00 AM'), findsOneWidget);
    });

    testWidgets('the window is repeated in the subtitle', (tester) async {
      api.ok(prefsPath,
          prefsBody(quietEnabled: true, quietStart: '23:30', quietEnd: '06:15'));

      await pumpPrefs(tester);

      expect(find.text('Silent from 11:30 PM to 6:15 AM'), findsOneWidget);
    });

    testWidgets('a malformed stored time falls back rather than crashing',
        (tester) async {
      // :129 — a row written before the server validated this shape must not take the
      // screen down with it.
      api.ok(prefsPath,
          prefsBody(quietEnabled: true, quietStart: '25:99', quietEnd: '07:00'));

      await pumpPrefs(tester);

      expect(find.text('12:00 AM'), findsOneWidget);
    });

    testWidgets('turning quiet hours on is written to the server',
        (tester) async {
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      await tapVisible(tester, quiet(2));
      await settleData(tester);

      final put = api.to(prefsPath).last;
      expect(put.method, 'PUT');
      final sent = jsonDecode(put.body!) as Map;
      expect((sent['quietHours'] as Map)['enabled'], isTrue);
    });
  });

  group('saving', () {
    testWidgets('only the four writable groups are sent', (tester) async {
      // `toBody` sends the preferences and nothing else: `categories` and `unmutable`
      // are the server's to decide, and echoing them back would invite a client to
      // widen its own permissions.
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      await tapVisible(tester, master());
      await settleData(tester);

      final sent = jsonDecode(api.to(prefsPath).last.body!) as Map;
      expect(sent.keys.toSet(),
          {'muteAll', 'push', 'inApp', 'quietHours'});
    });

    testWidgets("the server's echo replaces what was sent", (tester) async {
      // :97 — the server drops what it will not store, so a value it refused must not
      // stay on screen looking saved.
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      api.ok(prefsPath, prefsBody(muteAll: false));
      await tapVisible(tester, master());
      await settleData(tester);
      await tester.pump();

      expect(tester.widget<Switch>(master()).value, isFalse);
    });

    testWidgets('a failed save is reported', (tester) async {
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      api.fail(prefsPath, 'Could not store preferences.');
      await tapVisible(tester, master());
      await settleData(tester);
      await tester.pump();

      expect(find.text('Could not save — check your connection'), findsOneWidget);
    });

    testWidgets('a failed save re-reads the settings rather than lying',
        (tester) async {
      // :112 — the optimistic switch has already moved, so the truth has to be
      // fetched back or the screen shows a preference the job will not honour.
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      api.fail(prefsPath, 'Could not store preferences.');
      await tapVisible(tester, master());
      await settleData(tester);
      await tester.pump();

      expect(api.to(prefsPath).where((r) => r.method == 'GET'), hasLength(2));
    });

    testWidgets('a dropped connection is reported the same way',
        (tester) async {
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      api.offline(prefsPath);
      await tapVisible(tester, master());
      await settleData(tester);
      await tester.pump();

      expect(find.text('Could not save — check your connection'), findsOneWidget);
    });

    testWidgets('the write is shown while it is out', (tester) async {
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      api.ok(prefsPath, prefsBody(muteAll: true),
          delay: const Duration(milliseconds: 300));
      await tapVisible(tester, master());
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      await settleData(tester, step: const Duration(milliseconds: 300));
    });

    testWidgets('no switch can be moved while a write is out', (tester) async {
      // Two writes racing would leave whichever answered last on screen, which is
      // not necessarily the one the user asked for second.
      api.ok(prefsPath, prefsBody());
      await pumpPrefs(tester);

      api.ok(prefsPath, prefsBody(muteAll: true),
          delay: const Duration(milliseconds: 300));
      await tapVisible(tester, master());
      await tester.pump();

      expect(tester.widget<Switch>(pushOf(0)).onChanged, isNull);

      await settleData(tester, step: const Duration(milliseconds: 300));
    });
  });

  group('reach and scale', () {
    testWidgets('the master row is large enough to hit', (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester);

      expectTapTarget(
          tester, find.widgetWithText(SwitchListTile, 'Mute everything'));
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/shared/notification_prefs_screen.dart:411 draws the two column
    // switches at `Transform.scale(scale: 0.78)` inside a `SizedBox(height: 28)` with
    // `materialTapTargetSize: MaterialTapTargetSize.shrinkWrap`, well under the
    // 48-pixel floor the project sets — and they are the controls this screen exists
    // for. Two full-size switches do fit a 412-pixel row once the label column is
    // allowed to wrap; the fix is to drop the scale and the shrink-wrap and let the
    // text take two lines, after which this should be an `expectTapTarget`.
    testWidgets('the column switches are under the tap-target floor',
        (tester) async {
      api.ok(prefsPath, prefsBody(categories: const ['booking'], unmutable: const []));

      await pumpPrefs(tester);

      expect(tester.getSize(pushOf(0)).height, lessThan(48));
    });

    testWidgets('the form is still usable at a doubled text scale',
        (tester) async {
      api.ok(prefsPath, prefsBody());

      await pumpPrefs(tester, textScale: 2.0);

      expect(find.text('Mute everything'), findsOneWidget);
      expect(tester.widget<Switch>(master()).onChanged, isNotNull);
    });

    testWidgets('every category is still reachable at a doubled text scale',
        (tester) async {
      api.ok(prefsPath, prefsBody(categories: const [], unmutable: const []));

      await pumpPrefs(tester, textScale: 2.0);
      await tester.fling(find.byType(ListView), const Offset(0, -2000), 2000);
      await tester.pumpAndSettle();

      expect(find.text('Account & system'), findsOneWidget);
    });
  });
}
