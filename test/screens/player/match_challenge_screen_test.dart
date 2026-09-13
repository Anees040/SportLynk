// Compose a challenge (FR5.8 – FR5.12): the screen a captain reaches from an
// opponent row. It arrives already knowing the two sides (they are constructor
// arguments), and on mount runs two independent reads together through
// `Future.wait` — `MatchService.previewRaw` for the head-to-head and generated
// preview, and `MatchService.linkableBookings` for the confirmed slots a challenge
// may be pinned to. A single spinner covers both.
//
// Two branches are worth pinning. The preview is fetched raw so the backend's own
// refusal sentence survives: a pairing the server rejects (different sports, a team
// gone private, a match already open) sets `_loadError`, and the build then shows
// that sentence and withdraws the send bar entirely rather than offering an action
// that would 4xx. Separately, the booking picker is the rule, not a convenience
// (FR5.11): with no confirmed upcoming booking the screen says so and cannot send;
// with exactly one it auto-selects it so the captain is one tap from sending.
//
// Mount note: every call reads `AuthProvider.token`; `FakeAuth` supplies it. The
// fake keys on the path, so `/matches/preview`, `/matches/linkable-bookings` and
// `/matches/challenge` answer regardless of the query each carries. The send test
// asserts the POST is issued rather than the navigation that follows it.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/match.dart';
import 'package:sportlynk/screens/player/match_challenge_screen.dart';

import '../screen_harness.dart';

/// The preview read, the linkable-bookings read, and the challenge write.
const String kPreview = '/matches/preview';
const String kLinkable = '/matches/linkable-bookings';
const String kChallenge = '/matches/challenge';

/// A `MatchSide` in the camelCase the pairing endpoints emit. Ranked, so the header
/// draws an ELO figure and the comparison table a rating rather than "Unranked".
Map<String, dynamic> sideMap({
  String id = 'opp-1',
  String name = 'Karachi Kings',
  int elo = 1250,
}) => {
  'id': id,
  'name': name,
  'city': 'Karachi',
  'elo': elo,
  'ranked': true,
  'displayElo': elo,
  'played': 10,
  'wins': 6,
  'losses': 3,
  'draws': 1,
  'eloFrozen': false,
  'memberCount': 6,
  'trustScore': 80,
  'trustBand': 'trusted',
  'trustLabel': 'Trusted',
};

/// The `GET /matches/preview` `data` block `MatchPreview.fromJson` reads. A gap
/// inside the ±400 band, so the gauge caption takes its "inside the range" form.
Map<String, dynamic> previewData({
  int? competitiveness = 82,
  int eloGap = 10,
  bool within = true,
}) => {
  'challenger': sideMap(id: 't-1', name: 'Lahore Lions', elo: 1240),
  'opponent': sideMap(id: 'opp-1', name: 'Karachi Kings', elo: 1250),
  'competitiveness': competitiveness,
  'previewText': 'A close game on paper.',
  'previewLabel': 'Preview',
  'eloGap': eloGap,
  'withinPreferredBand': within,
};

/// One `LinkableBooking` row in camelCase. A fixed future date keeps the tile's
/// rendered label stable.
Map<String, dynamic> bookingRow({
  String id = 'bk-1',
  String venue = 'Green Turf Arena',
}) => {
  'id': id,
  'slotDate': '2026-09-20',
  'startTime': '18:00:00',
  'endTime': '19:00:00',
  'venueId': 'v-1',
  'venueName': venue,
  'venueCity': 'Lahore',
  'sportType': 'football',
  'totalAmount': 2000,
};

Future<RouteLog> pumpChallenge(WidgetTester tester, {double textScale = 1.0}) {
  return pumpScreen(
    tester,
    MatchChallengeScreen(
      myTeamId: 't-1',
      myTeam: MatchSide.fromJson(
        sideMap(id: 't-1', name: 'Lahore Lions', elo: 1240),
      ),
      opponent: MatchSide.fromJson(
        sideMap(id: 'opp-1', name: 'Karachi Kings', elo: 1250),
      ),
    ),
    auth: FakeAuth(
      role: 'player',
      id: 'u-1',
      name: 'Bilal Ahmed',
      token: 'test-token',
    ),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kPreview, previewData());
    api.ok(kLinkable, [bookingRow()]);
    api.ok(kChallenge, const {});
  });

  group('the challenge as it loads', () {
    testWidgets('a spinner stands while the reads are in flight', (
      tester,
    ) async {
      api.ok(kPreview, previewData(), delay: const Duration(milliseconds: 300));
      await pumpChallenge(tester);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Lahore Lions'), findsOneWidget);
    });

    testWidgets(
      'a loaded pairing shows both sides, the caption and the picker',
      (tester) async {
        await pumpChallenge(tester);
        await settleData(tester);

        expect(find.text('New Challenge'), findsOneWidget); // app-bar
        expect(find.text('Lahore Lions'), findsOneWidget); // my side
        expect(find.text('Karachi Kings'), findsOneWidget); // opponent
        expect(
          find.textContaining('rating points apart'),
          findsOneWidget,
        ); // gauge caption
        expect(
          find.text('Green Turf Arena'),
          findsOneWidget,
        ); // the linkable booking
        expect(find.text('Send challenge'), findsOneWidget);
      },
    );
  });

  group('the pairing refusal', () {
    testWidgets('a refused pairing shows the reason and withdraws the send bar', (
      tester,
    ) async {
      // The preview is fetched raw so the server's own sentence reaches the captain;
      // with an error, the build shows it and renders no send button at all.
      const reason = 'These teams play different sports.';
      api.fail(kPreview, reason);
      await pumpChallenge(tester);
      await settleData(tester);

      expect(find.text(reason), findsOneWidget);
      expect(find.text('Send challenge'), findsNothing);
    });
  });

  group('the booking picker (FR5.11)', () {
    testWidgets('no confirmed booking blocks the send with an explanation', (
      tester,
    ) async {
      api.ok(kLinkable, const []);
      await pumpChallenge(tester);
      await settleData(tester);

      expect(
        find.textContaining('no confirmed upcoming bookings'),
        findsOneWidget,
      );
      // The icon-button factory is a private FilledButton subtype, so assert the
      // public behavior rather than matching its exact runtime type: tapping an
      // unlinked challenge must not issue a write.
      await tester.tap(find.text('Send challenge'));
      await tester.pump();
      expect(api.countTo(kChallenge), 0);
    });
  });

  group('sending', () {
    testWidgets('a linked booking sends exactly one challenge', (tester) async {
      // The lone booking auto-selects, so the send is enabled on load.
      await pumpChallenge(tester);
      await settleData(tester);

      // Hold the response long enough to observe the transient sending state before
      // the successful request pops the screen.
      api.ok(kChallenge, const {}, delay: const Duration(milliseconds: 300));
      await tester.tap(find.text('Send challenge'));
      await tester
          .pump(); // the handler issues the POST and enters its sending state

      expect(api.countTo(kChallenge), 1);
      expect(find.text('Sending…'), findsOneWidget);

      // Let the write resolve (it pops and raises a SnackBar), then drain its timer.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the opponent present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpChallenge(tester, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Karachi Kings'), findsOneWidget);
    });
  });
}
