// Create Team: a single form that posts one team and pops with `true` so the
// caller can reload. There is nothing to fetch on entry, so the four load states
// do not apply here; what matters is the shape of the POST and the branch taken on
// its result.
//
// Three contracts are pinned.
//
// The first is the body. `TeamService.create` (lib/services/team_service.dart:73)
// sends `visibility` as the words 'public'/'private' rather than the screen's
// boolean, and omits `bio` and `logo` entirely when they are empty rather than
// sending null — the endpoint distinguishes an absent optional from a null one. The
// selected sport and visibility must reach the body, so each has a case that reads
// the recorded request back.
//
// The second is the name guard at lib/screens/player/create_team_screen.dart:202:
// a name under three characters after trimming is refused in the client with a
// snackbar and no request is made, so a blank submit costs the server nothing.
//
// The third is the result branch (:207). A `success` pops the screen and shows one
// confirmation; a failure shows the server's own sentence and keeps the screen up so
// the entry can be corrected and resent. The button is disabled while the request is
// in flight, which a second tap must not get past.
//
// No socket and no timers on mount, so this pumps with the default session. The only
// live timers are the snackbars' own auto-dismiss, drained after each assertion.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/create_team_screen.dart';

import '../screen_harness.dart';

/// The team endpoint, as `ApiConstants.teams` resolves it.
const String kTeams = '/teams';

Future<RouteLog> pumpForm(WidgetTester tester, {double textScale = 1.0}) async {
  final log = await pumpScreen(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => const CreateTeamScreen()),
            ),
            child: const Text('launch_form'),
          ),
        ),
      ),
    ),
    textScale: textScale,
  );
  await tester.tap(find.text('launch_form'));
  await tester.pumpAndSettle();
  return log;
}

/// Types [name] into the name field, which is the first of the two on the screen.
Future<void> enterName(WidgetTester tester, String name) async {
  await tester.enterText(find.byType(TextField).first, name);
  await tester.pump();
}

/// Taps the submit button, scrolling it into view first.
Future<void> tapCreate(WidgetTester tester) =>
    tapVisible(tester, find.text('Create Team'));

/// The body of the single POST the screen makes, decoded.
Map<String, dynamic> postedBody(FakeApi api) =>
    jsonDecode(api.to(kTeams).single.body!) as Map<String, dynamic>;

/// Lets a snackbar's four-second display timer expire so it is not reported as a
/// pending timer when the test ends.
Future<void> drainSnackbar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('the form as it opens', () {
    testWidgets('it shows the fields, both sports and both visibilities',
        (tester) async {
      await pumpForm(tester);

      expect(find.text('TEAM NAME'), findsOneWidget);
      expect(find.text('SPORT'), findsOneWidget);
      expect(find.text('VISIBILITY'), findsOneWidget);
      expect(find.text('TEAM BIO'), findsOneWidget);
      expect(find.text('Football'), findsOneWidget);
      expect(find.text('Cricket'), findsOneWidget);
      expect(find.text('Public'), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);
      expect(find.text('Create Team'), findsOneWidget);
      expect(find.text('You will be assigned as Captain'), findsOneWidget);
    });

    testWidgets('it asks the server nothing until the player submits',
        (tester) async {
      await pumpForm(tester);
      await tester.pump(const Duration(milliseconds: 200));

      expect(api.requests, isEmpty,
          reason: 'a create form has nothing to load');
    });

    testWidgets('public is the selected visibility to begin with',
        (tester) async {
      await pumpForm(tester);

      // The tick is drawn only on the selected public card (:138); the private
      // card carries a lock at all times, so the tick is the honest signal.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('the name is required', () {
    testWidgets('an empty name is refused in the client, costing no request',
        (tester) async {
      await pumpForm(tester);

      await tapCreate(tester);
      await tester.pump();

      expect(find.text('Enter a team name.'), findsOneWidget);
      expect(api.countTo(kTeams), 0);
      await drainSnackbar(tester);
    });

    testWidgets('a two-character name is still refused', (tester) async {
      await pumpForm(tester);

      await enterName(tester, 'ab');
      await tapCreate(tester);
      await tester.pump();

      expect(find.text('Enter a team name.'), findsOneWidget);
      expect(api.countTo(kTeams), 0);
      await drainSnackbar(tester);
    });

    testWidgets('whitespace does not pad a short name into validity',
        (tester) async {
      await pumpForm(tester);

      await enterName(tester, '   ab   ');
      await tapCreate(tester);
      await tester.pump();

      expect(find.text('Enter a team name.'), findsOneWidget);
      expect(api.countTo(kTeams), 0);
      await drainSnackbar(tester);
    });

    testWidgets('a three-character name is accepted and does post',
        (tester) async {
      api.ok(kTeams, {'id': 't-1'});
      await pumpForm(tester);

      await enterName(tester, 'FC1');
      await tapCreate(tester);
      await tester.pump();
      await tester.pump();

      expect(api.countTo(kTeams), 1);
      await drainSnackbar(tester);
    });
  });

  group('creating the team', () {
    testWidgets('the body carries the name and the words for the defaults',
        (tester) async {
      api.ok(kTeams, {'id': 't-1'});
      await pumpForm(tester);

      await enterName(tester, 'Warriors');
      await tapCreate(tester);
      await tester.pump();
      await tester.pump();

      final body = postedBody(api);
      expect(body['name'], 'Warriors');
      expect(body['sport'], 'football');
      expect(body['visibility'], 'public',
          reason: 'the boolean is translated to the word the endpoint expects');
      expect(body.containsKey('bio'), isFalse,
          reason: 'an empty bio is omitted, not sent as null');
      expect(body.containsKey('logo'), isFalse);
      await drainSnackbar(tester);
    });

    testWidgets('the chosen sport reaches the body', (tester) async {
      api.ok(kTeams, {'id': 't-1'});
      await pumpForm(tester);

      await tapVisible(tester, find.text('Cricket'));
      await enterName(tester, 'Warriors');
      await tapCreate(tester);
      await tester.pump();
      await tester.pump();

      expect(postedBody(api)['sport'], 'cricket');
      await drainSnackbar(tester);
    });

    testWidgets('the chosen visibility reaches the body', (tester) async {
      api.ok(kTeams, {'id': 't-1'});
      await pumpForm(tester);

      await tapVisible(tester, find.text('Private'));
      await enterName(tester, 'Warriors');
      await tapCreate(tester);
      await tester.pump();
      await tester.pump();

      expect(postedBody(api)['visibility'], 'private');
      await drainSnackbar(tester);
    });

    testWidgets('a typed bio is included in the body', (tester) async {
      api.ok(kTeams, {'id': 't-1'});
      await pumpForm(tester);

      await enterName(tester, 'Warriors');
      await tester.enterText(find.byType(TextField).at(1), 'Weekend league.');
      await tester.pump();
      await tapCreate(tester);
      await tester.pump();
      await tester.pump();

      expect(postedBody(api)['bio'], 'Weekend league.');
      await drainSnackbar(tester);
    });

    testWidgets('a success confirms and leaves the screen', (tester) async {
      api.ok(kTeams, {'id': 't-1'});
      await pumpForm(tester);

      await enterName(tester, 'Warriors');
      await tapCreate(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.text('Team created.'), findsOneWidget);
      expect(find.byType(CreateTeamScreen), findsNothing,
          reason: 'a created team pops back to the caller with a result');
      await drainSnackbar(tester);
    });

    testWidgets('a rejection is shown in the server\'s own words', (tester) async {
      api.fail(kTeams, 'A team with that name already exists.', status: 409);
      await pumpForm(tester);

      await enterName(tester, 'Warriors');
      await tapCreate(tester);
      await tester.pump();
      await tester.pump();

      expect(find.text('A team with that name already exists.'), findsOneWidget);
      expect(find.byType(CreateTeamScreen), findsOneWidget,
          reason: 'a failed create keeps the entry so it can be corrected');
      await drainSnackbar(tester);
    });

    testWidgets('a rejection with no message falls back to a sentence',
        (tester) async {
      // A body that fails the `success` check but carries no message at all — the
      // screen must still say something rather than an empty snackbar.
      api.on(kTeams, FakeResponse(400, jsonEncode({'success': false})));
      await pumpForm(tester);

      await enterName(tester, 'Warriors');
      await tapCreate(tester);
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not create team.'), findsOneWidget);
      await drainSnackbar(tester);
    });

    testWidgets('the button is disabled in flight, so a double tap posts once',
        (tester) async {
      api.ok(kTeams, {'id': 't-1'},
          delay: const Duration(milliseconds: 300));
      await pumpForm(tester);

      await enterName(tester, 'Warriors');
      await tapCreate(tester);
      await tester.pump();
      // The rebuild above has cleared the handler; a second tap is a no-op.
      await tapCreate(tester);
      await tester.pump();

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(api.countTo(kTeams), 1);
      await drainSnackbar(tester);
    });
  });

  group('reach and scale', () {
    testWidgets('the create button clears the tap-target floor',
        (tester) async {
      await pumpForm(tester);

      expectTapTarget(
          tester, find.widgetWithText(ElevatedButton, 'Create Team'));
    });

    testWidgets('a doubled text scale keeps the button and note present',
        (tester) async {
      // The test font's glyphs are square ems, roughly twice the width of the
      // Poppins the app draws with, so an overflow at this scale is the harness's
      // and not the screen's; the check is that the content is still there.
      ignoreOverflow();
      await pumpForm(tester, textScale: 2.0);

      expect(find.text('Create Team'), findsOneWidget);
      expect(find.text('You will be assigned as Captain'), findsOneWidget);
    });
  });
}
