// The eight display-only Scout cards, and the switch that picks one.
//
// These are the cards that cannot lose a booking — the money and dialog cards live in
// `scout_cards.dart` and are asserted next door — but they carry the same two habits,
// and those habits are what this file defends.
//
// The first is that a null number renders as nothing. `matchPct == null` means the
// ranker declined to score the row, and `ScoutMatchBadge` draws no pill at all rather
// than a "0% match" the model never claimed. Every card that passes model output
// through is asserted on both paths, and the null path is written as "no percentage
// appears anywhere" rather than "the right number appears", because the regression is
// a widget helpfully defaulting a missing int to zero.
//
// The second is that a card's buttons are the backend's own chips. A tap posts the
// chip that arrived, not one this file assembled, so the assertions read the `action`
// and the `args` off what the callback received rather than checking that a label was
// echoed. `args` is the load-bearing half: a card that rebuilt a chip from its label
// would still post the right action string and silently lose the identifier that says
// which player or team it applies to.
//
// Two cards state an absence in words instead of hiding it. `_TeamCard` reads
// `isRanked` before `elo`, so a side with too few verified matches says "Unranked"
// while the starting rating sits unused in the payload; the test pins that the number
// is present in the data and absent from the screen. `_MapCard` says so when the venue
// row has no coordinates, because "Maps opened somewhere odd" and "Scout is broken"
// are indistinguishable to a user who was not told.
//
// `_PolicyCard` is the one card that can legitimately render nothing: its figures come
// from the database, so a policy answer carrying none is a card with no content, and
// the reply text above it is already a complete answer. It also de-duplicates its
// `extra` sentence against the bubble above, which is why `contextText` is a parameter
// rather than something the widget could infer.
//
// `_StatsCard` is a generic renderer for a card type no action emits yet. It is
// asserted anyway, and its known defect is pinned as behaviour rather than fixed: it
// walks every scalar key and skips only `buttons`, so a payload carrying `title`
// renders the heading twice. See the comment on that test.
//
// Photo urls are null throughout so `ScoutThumb` draws its placeholder rather than
// reaching for `CachedNetworkImage`; nothing here touches the network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/models/assistant.dart';
import 'package:sportlynk/widgets/assistant/scout_bits.dart';
import 'package:sportlynk/widgets/assistant/scout_cards_more.dart';
import 'package:sportlynk/widgets/assistant/scout_chips.dart';
import 'package:sportlynk/widgets/assistant/scout_theme.dart';

import '../widget_harness.dart';

ScoutCard card(String type, Map<String, dynamic> data) =>
    ScoutCard(type: type, data: CardData(data));

Map<String, dynamic> chip(String label, String action,
        [Map<String, dynamic>? args]) =>
    {'label': label, 'action': action, 'args': ?args};

void main() {
  /// Records what a tap posted, so "the card authored this" is an assertion.
  late List<ScoutChip> chips;
  late List<String> screens;
  late List<CardData> directions;

  setUp(() {
    chips = <ScoutChip>[];
    screens = <String>[];
    directions = <CardData>[];
  });

  ScoutCardActions acts({bool enabled = true, bool wired = true}) =>
      ScoutCardActions(
        onChip: wired ? chips.add : null,
        onScreen: wired ? screens.add : null,
        onDirections: wired ? directions.add : null,
        enabled: enabled,
      );

  /// One card on the device surface, scrollable so a tall card does not overflow
  /// the frame instead of the row under test.
  Future<void> pumpCard(
    WidgetTester tester,
    ScoutCard c, {
    ScoutCardActions? actions,
    String? contextText,
    double textScale = 1.0,
    double width = 300,
  }) async {
    useDeviceSurface(tester);
    await pumpApp(
      tester,
      Scaffold(
        backgroundColor: ScoutTheme.canvas,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: width,
            child: ScoutExtraCard(
              card: c,
              actions: actions ?? acts(),
              contextText: contextText,
            ),
          ),
        ),
      ),
      textScale: textScale,
    );
  }

  Color? textColorOf(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).style?.color;

  group('the switch from a wire type to a widget', () {
    // Every type the contract declares must reach a renderer. `stats` is the one
    // nothing emits today, so it is also the one whose absence nobody would notice.
    testWidgets('each display type renders its own card', (tester) async {
      const cases = <String, String>{
        ScoutCardType.player: 'Bilal Ahmed',
        ScoutCardType.team: 'Karachi United',
        ScoutCardType.tournament: 'Ramzan Cup',
        ScoutCardType.map: 'Karachi Sports Arena',
        ScoutCardType.stats: 'Season',
      };

      for (final entry in cases.entries) {
        await pumpCard(tester, card(entry.key, {'name': entry.value, 'title': entry.value}));
        expect(find.text(entry.value), findsWidgets,
            reason: 'type ${entry.key} did not render');
      }
    });

    testWidgets('the wallet card renders from its own fields', (tester) async {
      await pumpCard(tester, card(ScoutCardType.wallet, {'balance': 5200}));
      expect(find.text('Available to spend'), findsOneWidget);
    });

    testWidgets('the policy card renders from its figures', (tester) async {
      await pumpCard(tester, card(ScoutCardType.policy, {'windowHours': 24}));
      expect(find.text('24h'), findsOneWidget);
    });

    testWidgets('the capabilities card renders from its items', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.capabilities, {
          'items': [
            {'action': 'find_venues', 'label': 'Find grounds', 'group': 'Booking'},
          ],
        }),
      );
      expect(find.text('Find grounds'), findsOneWidget);
    });

    // A type a newer backend invented must degrade to something labelled. Crashing
    // would take the whole transcript with it; rendering nothing would silently drop
    // a piece of the answer.
    testWidgets('an unknown type names itself and defers to the message',
        (tester) async {
      await pumpCard(tester, card('leaderboard', {'name': 'Whatever'}));

      expect(find.textContaining('“leaderboard”'), findsOneWidget);
      expect(find.textContaining('needs a newer version of the app'), findsOneWidget);
      expect(find.textContaining('still has the full answer'), findsOneWidget);
      expect(find.byIcon(Icons.system_update_alt_rounded), findsOneWidget);
    });

    testWidgets('an empty type is unknown rather than blank', (tester) async {
      await pumpCard(tester, card('', {}));
      expect(find.byIcon(Icons.system_update_alt_rounded), findsOneWidget);
    });
  });

  group('a player the scorer ranked', () {
    Map<String, dynamic> player({
      String name = 'Bilal Ahmed',
      String? city = 'Karachi',
      String? position = 'Midfielder',
      String? skill = 'Intermediate',
      num? trust = 82,
      int? played = 14,
      int? matchPct,
      List<String> reasons = const [],
      List<Map<String, dynamic>>? buttons,
    }) =>
        {
          'id': 'u1',
          'name': name,
          'city': ?city,
          'position': ?position,
          'skill': ?skill,
          'trustScore': ?trust,
          'matchesPlayed': ?played,
          'matchPct': ?matchPct,
          'reasons': reasons,
          'buttons': ?buttons,
        };

    testWidgets('the name, city and facts read in one card', (tester) async {
      await pumpCard(tester, card(ScoutCardType.player, player(matchPct: 88)));

      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('Karachi'), findsOneWidget);
      expect(find.text('Midfielder'), findsOneWidget);
      expect(find.text('Intermediate'), findsOneWidget);
      expect(find.text('Trust 82'), findsOneWidget);
      expect(find.text('14 matches'), findsOneWidget);
      expect(find.text('88% match'), findsOneWidget);
    });

    // The rule the file exists for. A player the ranker declined to score is a plain
    // directory listing, and that is the honest presentation.
    testWidgets('an unscored player carries no percentage anywhere',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.player, player()));

      expect(find.textContaining('%'), findsNothing);
      expect(find.byType(ScoutMatchBadge), findsOneWidget);
      expect(tester.getSize(find.byType(ScoutMatchBadge)), Size.zero);
    });

    testWidgets('a percentage of zero is a real score and is printed',
        (tester) async {
      // The other direction: the ranker can legitimately return 0, and suppressing
      // that would hide a genuine verdict behind the null rule.
      await pumpCard(tester, card(ScoutCardType.player, player(matchPct: 0)));

      expect(find.text('0% match'), findsOneWidget);
      expect(textColorOf(tester, find.text('0% match')), ScoutTheme.danger);
    });

    testWidgets('the badge takes its colour from the shared bands', (tester) async {
      for (final entry in <int, Color>{
        88: ScoutTheme.good,
        62: ScoutTheme.accent,
        40: ScoutTheme.money,
        12: ScoutTheme.danger,
      }.entries) {
        await pumpCard(
          tester,
          card(ScoutCardType.player, player(matchPct: entry.key)),
        );
        expect(textColorOf(tester, find.text('${entry.key}% match')), entry.value,
            reason: '${entry.key}% must match ScoutTheme.pctTone');
        expect(ScoutTheme.pctTone(entry.key).color, entry.value);
      }
    });

    testWidgets('a single match is not pluralised', (tester) async {
      await pumpCard(tester, card(ScoutCardType.player, player(played: 1)));
      expect(find.text('1 match'), findsOneWidget);
    });

    testWidgets('a strong trust score is coloured and a weak one is not',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.player, player(trust: 70)));
      expect(textColorOf(tester, find.text('Trust 70')), ScoutTheme.good);

      await pumpCard(tester, card(ScoutCardType.player, player(trust: 69)));
      expect(textColorOf(tester, find.text('Trust 69')), ScoutTheme.inkSoft);
    });

    testWidgets('a player with no record shows only what is known',
        (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.player,
          player(city: null, position: null, skill: null, trust: null, played: null),
        ),
      );

      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.textContaining('Trust'), findsNothing);
      expect(find.textContaining('match'), findsNothing);
    });

    testWidgets('a nameless payload still renders a heading', (tester) async {
      await pumpCard(tester, card(ScoutCardType.player, {'id': 'u1'}));
      expect(find.text('Player'), findsOneWidget);
    });

    testWidgets('the stated reasons are shown rather than hidden behind a tap',
        (tester) async {
      // A ranked list that cannot say why is indistinguishable from an arbitrary one.
      await pumpCard(
        tester,
        card(
          ScoutCardType.player,
          player(reasons: const ['Plays your sport', 'Books nearby']),
        ),
      );

      expect(find.text('Plays your sport'), findsOneWidget);
      expect(find.text('Books nearby'), findsOneWidget);
    });

    testWidgets('a tap posts the chip the backend minted', (tester) async {
      final button = chip('Invite', 'invite_player', {'userId': 'u1'});
      final c = card(ScoutCardType.player, player(buttons: [button]));

      await pumpCard(tester, c);
      await tester.tap(find.text('Invite'));

      expect(chips, hasLength(1));
      expect(chips.single.action, 'invite_player');
      expect(chips.single.args, {'userId': 'u1'});
    });

    testWidgets('a card with no buttons draws no button row', (tester) async {
      await pumpCard(tester, card(ScoutCardType.player, player()));
      expect(find.byType(ScoutChipButton), findsNothing);
    });

    testWidgets('a disabled card mints nothing when tapped', (tester) async {
      // The transcript disables cards while a turn is in flight; a stale tap must
      // not post a second action.
      await pumpCard(
        tester,
        card(
          ScoutCardType.player,
          player(buttons: [chip('Invite', 'invite_player')]),
        ),
        actions: acts(enabled: false),
      );

      await tester.tap(find.text('Invite'), warnIfMissed: false);
      expect(chips, isEmpty);
    });
  });

  group('a team, ranked or not', () {
    Map<String, dynamic> team({
      String name = 'Karachi United',
      String? sport = 'Football',
      String? city = 'Karachi',
      bool? ranked = true,
      int? displayElo = 1240,
      int? elo,
      int? wins = 7,
      int? losses = 2,
      int? members = 11,
      int? matchPct,
      List<Map<String, dynamic>>? buttons,
    }) =>
        {
          'id': 't1',
          'name': name,
          'sport': ?sport,
          'city': ?city,
          'isRanked': ?ranked,
          'displayElo': ?displayElo,
          'elo': ?elo,
          'wins': ?wins,
          'losses': ?losses,
          'memberCount': ?members,
          'matchPct': ?matchPct,
          'buttons': ?buttons,
        };

    testWidgets('a ranked team shows its rating, record and size',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.team, team()));

      expect(find.text('Karachi United'), findsOneWidget);
      expect(find.text('Football · Karachi'), findsOneWidget);
      expect(find.text('1240 ELO'), findsOneWidget);
      expect(find.text('7W–2L'), findsOneWidget);
      expect(find.text('11 players'), findsOneWidget);
    });

    // The honesty rule the ELO helper enforces server-side. The starting rating is
    // in the payload; printing it would invent a competitive record.
    testWidgets('an unranked team says the word and never the number',
        (tester) async {
      final c = card(ScoutCardType.team, team(ranked: false, displayElo: 1200));
      expect(c.data.intOrNull('displayElo'), 1200,
          reason: 'the rating must be present in the payload for this to mean anything');

      await pumpCard(tester, c);

      expect(find.text('Unranked'), findsOneWidget);
      expect(find.textContaining('1200'), findsNothing);
      expect(find.textContaining('ELO'), findsNothing);
      expect(textColorOf(tester, find.text('Unranked')), ScoutTheme.inkFaint);
    });

    testWidgets('a payload that omits the flag falls back to the rating',
        (tester) async {
      // `isRanked` absent is not `isRanked: false`. An older backend that never sends
      // it must still show a rating rather than calling every team unranked.
      await pumpCard(tester, card(ScoutCardType.team, team(ranked: null)));

      expect(find.text('1240 ELO'), findsOneWidget);
      expect(find.text('Unranked'), findsNothing);
    });

    testWidgets('a raw rating is used when no display rating was sent',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.team, team(displayElo: null, elo: 1180)),
      );
      expect(find.text('1180 ELO'), findsOneWidget);
    });

    testWidgets('a ranked team with no rating at all shows neither',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.team, team(displayElo: null, elo: null)),
      );

      expect(find.textContaining('ELO'), findsNothing);
      expect(find.text('Unranked'), findsNothing);
    });

    testWidgets('a record needs both halves to be printed', (tester) async {
      // "7W–" is worse than nothing, so a half-sent record is dropped.
      await pumpCard(tester, card(ScoutCardType.team, team(losses: null)));

      expect(find.textContaining('W–'), findsNothing);
      expect(find.text('1240 ELO'), findsOneWidget);
    });

    testWidgets('a zero-win record is still a record', (tester) async {
      await pumpCard(tester, card(ScoutCardType.team, team(wins: 0, losses: 3)));
      expect(find.text('0W–3L'), findsOneWidget);
    });

    testWidgets('a one-player team is not pluralised', (tester) async {
      await pumpCard(tester, card(ScoutCardType.team, team(members: 1)));
      expect(find.text('1 player'), findsOneWidget);
    });

    testWidgets('the subtitle omits a missing half without a stray separator',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.team, team(city: null)));

      expect(find.text('Football'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('an opponent search carries a match percentage', (tester) async {
      await pumpCard(tester, card(ScoutCardType.team, team(matchPct: 74)));
      expect(find.text('74% match'), findsOneWidget);
    });

    testWidgets('an unscored team carries no percentage', (tester) async {
      await pumpCard(tester, card(ScoutCardType.team, team()));
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('a tap posts the backend chip with its arguments',
        (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.team,
          team(buttons: [chip('Challenge', 'challenge_team', {'teamId': 't1'})]),
        ),
      );

      await tester.tap(find.text('Challenge'));
      expect(chips.single.action, 'challenge_team');
      expect(chips.single.args, {'teamId': 't1'});
    });
  });

  group('an open tournament', () {
    Map<String, dynamic> tourney({
      String name = 'Ramzan Cup',
      String? sport = 'Football',
      String? format = 'Knockout',
      String? startLabel = 'Sat 21 Mar',
      String? feeLabel = 'PKR 5,000',
      num? fee = 5000,
      String? venueName = 'Karachi Sports Arena',
      String? organiser = 'Sports Board',
      int? maxTeams = 16,
      int? teamsIn = 9,
      int? spotsLeft,
      bool full = false,
      String? deadlineLabel,
      List<Map<String, dynamic>>? buttons,
    }) =>
        {
          'id': 'tr1',
          'name': name,
          'sport': ?sport,
          'format': ?format,
          'startLabel': ?startLabel,
          'entryFeeLabel': ?feeLabel,
          'entryFee': ?fee,
          'venueName': ?venueName,
          'organiser': ?organiser,
          'maxTeams': ?maxTeams,
          'teamsIn': ?teamsIn,
          'spotsLeft': ?spotsLeft,
          'isFull': full,
          'deadlineLabel': ?deadlineLabel,
          'buttons': ?buttons,
        };

    testWidgets('the name, format, fee and fill all read', (tester) async {
      await pumpCard(tester, card(ScoutCardType.tournament, tourney()));

      expect(find.text('Ramzan Cup'), findsOneWidget);
      expect(find.text('Football · Knockout'), findsOneWidget);
      expect(find.text('Sat 21 Mar'), findsOneWidget);
      expect(find.text('PKR 5,000'), findsOneWidget);
      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text('Sports Board'), findsOneWidget);
      expect(find.text('9 of 16 teams in'), findsOneWidget);
    });

    testWidgets('a free tournament says so rather than showing a zero',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(fee: 0, feeLabel: null)),
      );

      expect(find.text('Free entry'), findsOneWidget);
      expect(textColorOf(tester, find.text('Free entry')), ScoutTheme.good);
      expect(find.byIcon(Icons.card_giftcard_rounded), findsOneWidget);
    });

    testWidgets('a paid tournament without a label shows a dash, not a guess',
        (tester) async {
      // Currency formatting belongs to one side of the wire; a locally invented
      // figure is how two formats end up on one screen.
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(feeLabel: null)),
      );

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('5000'), findsNothing);
    });

    testWidgets('a full tournament is flagged and tinted', (tester) async {
      await pumpCard(tester, card(ScoutCardType.tournament, tourney(full: true)));

      expect(find.text('Full'), findsOneWidget);
      expect(textColorOf(tester, find.text('Full')), ScoutTheme.danger);
    });

    testWidgets('the last few places are called out', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(spotsLeft: 3)),
      );
      expect(find.text('3 left'), findsOneWidget);
    });

    testWidgets('a comfortable field is not called out', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(spotsLeft: 4)),
      );
      expect(find.text('4 left'), findsNothing);
    });

    testWidgets('being full outranks the places-left pill', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(full: true, spotsLeft: 1)),
      );

      expect(find.text('Full'), findsOneWidget);
      expect(find.text('1 left'), findsNothing);
    });

    testWidgets('the fill bar tracks the entries', (tester) async {
      await pumpCard(tester, card(ScoutCardType.tournament, tourney(teamsIn: 8)));

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.5, 0.0001));
      expect(bar.valueColor?.value, ScoutTheme.accent);
    });

    testWidgets('a nearly full field turns amber and a full one red',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.tournament, tourney(teamsIn: 13)));
      expect(
        tester
            .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
            .valueColor
            ?.value,
        ScoutTheme.money,
      );

      await pumpCard(tester, card(ScoutCardType.tournament, tourney(teamsIn: 16)));
      expect(
        tester
            .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
            .valueColor
            ?.value,
        ScoutTheme.danger,
      );
    });

    testWidgets('an over-subscribed field clamps rather than overflowing the bar',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.tournament, tourney(teamsIn: 20)));

      expect(
        tester
            .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
            .value,
        1.0,
      );
      expect(find.text('20 of 16 teams in'), findsOneWidget);
    });

    testWidgets('a tournament with no cap draws no bar', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(maxTeams: null)),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('no entries yet is a zero bar, not a missing one', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(teamsIn: null)),
      );

      expect(find.text('0 of 16 teams in'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
            .value,
        0.0,
      );
    });

    // The deadline gets its own row because it is the only irreversible thing on the
    // card: a closed tournament cannot be entered at all.
    testWidgets('a registration deadline gets its own line', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, tourney(deadlineLabel: '19 Mar')),
      );

      expect(find.text('Registration closes 19 Mar'), findsOneWidget);
      expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
    });

    testWidgets('no deadline draws no deadline row', (tester) async {
      await pumpCard(tester, card(ScoutCardType.tournament, tourney()));

      expect(find.textContaining('Registration closes'), findsNothing);
      expect(find.byIcon(Icons.timer_outlined), findsNothing);
    });

    testWidgets('a nameless tournament still has a heading', (tester) async {
      await pumpCard(tester, card(ScoutCardType.tournament, {'id': 'tr1'}));
      expect(find.text('Tournament'), findsOneWidget);
    });

    testWidgets('a tap posts the join chip', (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.tournament,
          tourney(buttons: [chip('Register', 'join_tournament', {'id': 'tr1'})]),
        ),
      );

      await tester.tap(find.text('Register'));
      expect(chips.single.action, 'join_tournament');
    });
  });

  group('directions to a ground', () {
    Map<String, dynamic> map({
      String name = 'Karachi Sports Arena',
      String? address = 'Gulshan Block 5',
      String? city = 'Karachi',
      bool hasPin = true,
      List<Map<String, dynamic>>? buttons,
    }) =>
        {
          'venueId': 'v1',
          'name': name,
          'address': ?address,
          'city': ?city,
          'hasPin': hasPin,
          'buttons': ?buttons,
        };

    testWidgets('the ground and its address read together', (tester) async {
      await pumpCard(tester, card(ScoutCardType.map, map()));

      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text('Gulshan Block 5, Karachi'), findsOneWidget);
      expect(find.byIcon(Icons.directions_rounded), findsOneWidget);
    });

    // Not every venue row has coordinates. Saying so is the difference between "Maps
    // opened somewhere odd" and "Scout is broken".
    testWidgets('a ground with no pin warns that Maps will search by name',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.map, map(hasPin: false)));

      expect(
        find.text(
          'No exact pin saved for this ground — Maps will search for the name instead.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a pinned ground carries no warning', (tester) async {
      await pumpCard(tester, card(ScoutCardType.map, map()));
      expect(find.textContaining('No exact pin'), findsNothing);
    });

    testWidgets('a ground with no address shows no empty subtitle',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.map, map(address: null, city: null)),
      );

      expect(find.text('Karachi Sports Arena'), findsOneWidget);
      expect(find.text(''), findsNothing);
      expect(find.textContaining(','), findsNothing);
    });

    // The launching belongs to the screen: `url_launcher` needs a context for its
    // failure snackbar, and a widget this deep should not decide what a failed
    // external intent looks like.
    testWidgets('opening Maps hands the whole payload up to the screen',
        (tester) async {
      final c = card(ScoutCardType.map, map());
      await pumpCard(tester, c);

      await tester.tap(find.text('Open in Maps'));

      expect(directions, hasLength(1));
      expect(directions.single.raw['venueId'], 'v1');
      expect(directions.single.raw['hasPin'], true);
    });

    testWidgets('no directions handler means no Maps button', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.map, map()),
        actions: ScoutCardActions(onChip: chips.add),
      );

      expect(find.text('Open in Maps'), findsNothing);
    });

    testWidgets('the backend chips sit beside the Maps button', (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.map,
          map(buttons: [chip('Book here', 'book_venue', {'venueId': 'v1'})]),
        ),
      );

      expect(find.text('Open in Maps'), findsOneWidget);
      await tester.tap(find.text('Book here'));
      expect(chips.single.action, 'book_venue');
    });

    testWidgets('a nameless ground still has a heading', (tester) async {
      await pumpCard(tester, card(ScoutCardType.map, {'venueId': 'v1'}));
      expect(find.text('Ground'), findsOneWidget);
    });
  });

  group('the wallet', () {
    Map<String, dynamic> wallet({
      String? balanceLabel = 'PKR 5,200',
      num? balance = 5200,
      String? frozenLabel = 'PKR 1,800',
      num? frozen = 1800,
      num? withdrawalMin,
      List<Map<String, dynamic>>? buttons,
    }) =>
        {
          'balanceLabel': ?balanceLabel,
          'balance': ?balance,
          'frozenLabel': ?frozenLabel,
          'frozen': ?frozen,
          'withdrawalMin': ?withdrawalMin,
          'buttons': ?buttons,
        };

    // Two numbers, not one. A single total would read as more money than the user can
    // act on, and every booking Scout takes moves an amount from the first to the
    // second.
    testWidgets('spendable and escrowed money are shown separately',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.wallet, wallet()));

      expect(find.text('Available to spend'), findsOneWidget);
      expect(find.text('PKR 5,200'), findsOneWidget);
      expect(find.text('Held in escrow'), findsOneWidget);
      expect(find.text('PKR 1,800'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    });

    testWidgets('a wallet with nothing held draws no escrow row', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.wallet, wallet(frozen: 0, frozenLabel: null)),
      );

      expect(find.text('Held in escrow'), findsNothing);
      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
    });

    testWidgets('the backend label is preferred over local formatting',
        (tester) async {
      // Two currency formatters is how "PKR 2400" and "Rs 2,400.00" end up on the
      // same screen.
      await pumpCard(
        tester,
        card(ScoutCardType.wallet, wallet(balanceLabel: 'Rs 5.2k')),
      );

      expect(find.text('Rs 5.2k'), findsOneWidget);
      expect(find.text('PKR 5,200'), findsNothing);
    });

    testWidgets('a raw amount is formatted locally only when no label came',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.wallet, wallet(balanceLabel: null)),
      );
      expect(find.text('PKR 5,200'), findsOneWidget);
    });

    testWidgets('an empty wallet shows a dash rather than a zero of unknown kind',
        (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.wallet,
          wallet(balanceLabel: null, balance: null, frozen: 0, frozenLabel: null),
        ),
      );
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('a withdrawal floor is stated when there is one', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.wallet, wallet(withdrawalMin: 500)),
      );
      expect(find.text('Withdrawals start at PKR 500.'), findsOneWidget);
    });

    testWidgets('no floor and a zero floor both say nothing', (tester) async {
      await pumpCard(tester, card(ScoutCardType.wallet, wallet()));
      expect(find.textContaining('Withdrawals start at'), findsNothing);

      await pumpCard(
        tester,
        card(ScoutCardType.wallet, wallet(withdrawalMin: 0)),
      );
      expect(find.textContaining('Withdrawals start at'), findsNothing);
    });

    // Scout walks the user to the real wallet rather than becoming a second one.
    testWidgets('the card offers a way into the wallet screen', (tester) async {
      await pumpCard(tester, card(ScoutCardType.wallet, wallet()));

      await tester.tap(find.text('Open wallet'));
      expect(screens, ['wallet']);
    });

    testWidgets('no screen handler means no wallet button', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.wallet, wallet()),
        actions: ScoutCardActions(onChip: chips.add),
      );
      expect(find.text('Open wallet'), findsNothing);
    });

    testWidgets('a backend chip sits beside the screen button', (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.wallet,
          wallet(buttons: [chip('Top up', 'topup_help')]),
        ),
      );

      expect(find.text('Open wallet'), findsOneWidget);
      await tester.tap(find.text('Top up'));
      expect(chips.single.action, 'topup_help');
    });
  });

  group('a policy answer', () {
    testWidgets('the figures render with their labels', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {
          'title': 'Cancellation policy',
          'windowHours': 24,
          'refundPct': 100,
          'depositPct': 25,
          'graceMinutes': 15,
        }),
      );

      expect(find.text('Cancellation policy'), findsOneWidget);
      expect(find.text('24h'), findsOneWidget);
      expect(find.text('Free-cancel window'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Refunded'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('Deposit held'), findsOneWidget);
      expect(find.text('15 min'), findsOneWidget);
      expect(find.text('No-show grace'), findsOneWidget);
    });

    testWidgets('the rating figures render too', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {
          'base': 1200,
          'kFactor': 32,
          'rankedMinMatches': 5,
          'preferredBand': 150,
          'withdrawalMin': 500,
        }),
      );

      expect(find.text('1200'), findsOneWidget);
      expect(find.text('Starting rating'), findsOneWidget);
      expect(find.text('32'), findsOneWidget);
      expect(find.text('K-factor'), findsOneWidget);
      expect(find.text('5 matches'), findsOneWidget);
      expect(find.text('±150'), findsOneWidget);
      expect(find.text('PKR 500'), findsOneWidget);
    });

    testWidgets('a one-match threshold is not pluralised', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {'rankedMinMatches': 1}),
      );
      expect(find.text('1 match'), findsOneWidget);
    });

    testWidgets('the figures keep the order a reader wants them in',
        (tester) async {
      // Booking terms before rating mechanics, because a cancellation question is
      // what brings a user here.
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {
          'kFactor': 32,
          'refundPct': 100,
          'windowHours': 24,
        }),
        width: 340,
      );

      final window = tester.getTopLeft(find.text('24h'));
      final refund = tester.getTopLeft(find.text('100%'));
      final k = tester.getTopLeft(find.text('32'));
      expect(window.dx, lessThan(refund.dx));
      expect(refund.dx, lessThan(k.dx));
    });

    testWidgets('only the figures that were sent are shown', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {'windowHours': 24}),
      );

      expect(find.text('Free-cancel window'), findsOneWidget);
      expect(find.text('Refunded'), findsNothing);
      expect(find.text('K-factor'), findsNothing);
    });

    // A policy answer with no figures is a card with no content, and the reply text
    // above it is already a complete answer.
    testWidgets('a card with nothing to show renders nothing', (tester) async {
      await pumpCard(tester, card(ScoutCardType.policy, {'title': 'Policy'}));
      // Height, not Size: the card sits under a tight width constraint, so a shrink
      // still measures the full 300 across. A zero height is what proves no padded
      // empty frame was drawn.
      expect(tester.getSize(find.byType(ScoutExtraCard)).height, 0.0);
    });

    testWidgets('the extra sentence is shown when the bubble did not say it',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {
          'windowHours': 24,
          'extra': 'Top-ups are handled by the admin team for now.',
        }),
        contextText: 'Here is how cancellation works.',
      );

      expect(
        find.text('Top-ups are handled by the admin team for now.'),
        findsOneWidget,
      );
    });

    // `topup_help` puts the same sentence in the reply and in the card. Printing both
    // says everything twice.
    testWidgets('the extra sentence is dropped when the bubble already said it',
        (tester) async {
      const sentence = 'Top-ups are handled by the admin team for now.';
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {'windowHours': 24, 'extra': sentence}),
        contextText: 'Your balance is PKR 200. $sentence',
      );

      expect(find.text(sentence), findsNothing);
      expect(find.text('24h'), findsOneWidget);
    });

    testWidgets('a scrap of an extra sentence is not worth a row', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {'windowHours': 24, 'extra': 'See app.'}),
      );
      expect(find.text('See app.'), findsNothing);
    });

    testWidgets('an extra sentence alone is enough to render the card',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {
          'extra': 'Refunds land back in your wallet within two working days.',
        }),
      );

      expect(
        find.text('Refunds land back in your wallet within two working days.'),
        findsOneWidget,
      );
      expect(find.text('Policy'), findsOneWidget);
    });

    testWidgets('a nameless policy card still has a heading', (tester) async {
      await pumpCard(tester, card(ScoutCardType.policy, {'refundPct': 100}));
      expect(find.text('Policy'), findsOneWidget);
    });
  });

  group('what Scout can do', () {
    Map<String, dynamic> caps(List<List<String>> rows) => {
          'items': [
            for (final r in rows)
              {'action': r[0], 'label': r[1], 'group': r[2], 'gloss': 'ignored'},
          ],
        };

    // Every entry is a button carrying its action, which is what keeps the two
    // abilities the released classifier has no label for reachable at all.
    testWidgets('each ability is a button, not a phrase to retype',
        (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.capabilities,
          caps([
            ['find_venues', 'Find grounds', 'Booking'],
            ['find_players', 'Find players', 'Matchmaking'],
          ]),
        ),
      );

      expect(find.byType(ScoutChipButton), findsNWidgets(2));
      await tester.tap(find.text('Find players'));
      expect(chips.single.action, 'find_players');
      expect(chips.single.label, 'Find players');
    });

    // Pinned as it behaves, not as it should: this is the one card that mints its own
    // chips, and `_CapabilitiesCard.build`
    // (lib/widgets/assistant/scout_cards_more.dart:761) constructs
    // `ScoutChip(label:, action:)` with no `args`. A capability row is a static
    // declaration today so nothing is lost yet, but a row that ever arrives with
    // arguments will post without them. The fix is to carry `args` on
    // `ScoutCapability` and pass it through here.
    testWidgets('a minted chip carries no arguments', (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.capabilities,
          caps([
            ['find_venues', 'Find grounds', 'Booking'],
          ]),
        ),
      );

      await tester.tap(find.text('Find grounds'));
      expect(chips.single.args, isNull);
    });

    testWidgets('abilities are grouped under their headings', (tester) async {
      await pumpCard(
        tester,
        card(
          ScoutCardType.capabilities,
          caps([
            ['find_venues', 'Find grounds', 'Booking'],
            ['my_bookings', 'My bookings', 'Booking'],
            ['find_players', 'Find players', 'Matchmaking'],
          ]),
        ),
      );

      expect(find.text('BOOKING'), findsOneWidget);
      expect(find.text('MATCHMAKING'), findsOneWidget);
      expect(find.byType(ScoutChipButton), findsNWidgets(3));
    });

    testWidgets('the groups keep the backend declaration order', (tester) async {
      // The help sheet and this card list the same abilities under the same
      // headings, which only holds while both read the order off the payload.
      await pumpCard(
        tester,
        card(
          ScoutCardType.capabilities,
          caps([
            ['find_players', 'Find players', 'Matchmaking'],
            ['find_venues', 'Find grounds', 'Booking'],
          ]),
        ),
      );

      // Matchmaking arrived first, so Matchmaking is drawn first. Sorting the
      // headings here would put them in a different order from the help sheet.
      expect(
        tester.getTopLeft(find.text('MATCHMAKING')).dy,
        lessThan(tester.getTopLeft(find.text('BOOKING')).dy),
      );
    });

    testWidgets('the glosses are left to the help sheet', (tester) async {
      // Sixteen descriptions in a chat card would push the sentence that prompted it
      // off the top of the screen, and this card appears on every abstain.
      await pumpCard(
        tester,
        card(ScoutCardType.capabilities, caps([
          ['find_venues', 'Find grounds', 'Booking'],
        ])),
      );

      expect(find.text('ignored'), findsNothing);
    });

    testWidgets('an item with no action is dropped rather than drawn dead',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.capabilities, {
          'items': [
            {'action': '', 'label': 'Broken', 'group': 'Booking'},
            {'action': 'find_venues', 'label': 'Find grounds', 'group': 'Booking'},
          ],
        }),
      );

      expect(find.text('Broken'), findsNothing);
      expect(find.byType(ScoutChipButton), findsOneWidget);
    });

    testWidgets('an empty list renders nothing', (tester) async {
      await pumpCard(tester, card(ScoutCardType.capabilities, {'items': []}));
      // Height rather than Size: the tight 300-wide parent means a shrink is
      // Size(300, 0), and the height is the part that proves nothing was drawn.
      expect(tester.getSize(find.byType(ScoutExtraCard)).height, 0.0);
    });

    testWidgets('a malformed payload renders nothing rather than throwing',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.capabilities, {'items': 'everything'}),
      );
      expect(tester.getSize(find.byType(ScoutExtraCard)).height, 0.0);
    });

    testWidgets('an ungrouped ability falls under a catch-all heading',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.capabilities, {
          'items': [
            {'action': 'whatever', 'label': 'Something new'},
          ],
        }),
      );

      expect(find.text('MORE'), findsOneWidget);
      expect(find.text('Something new'), findsOneWidget);
    });

    testWidgets('a disabled transcript leaves every ability unable to fire',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.capabilities, caps([
          ['find_venues', 'Find grounds', 'Booking'],
        ])),
        actions: acts(enabled: false),
      );

      await tester.tap(find.text('Find grounds'), warnIfMissed: false);
      expect(chips, isEmpty);
    });
  });

  group('the generic stats renderer', () {
    testWidgets('every scalar becomes a labelled row', (tester) async {
      // A card type no action emits yet. It renders legibly on builds that shipped
      // before the field existed, which is the only sane default for a wire contract
      // that is going to grow.
      await pumpCard(
        tester,
        card(ScoutCardType.stats, {
          'matchesPlayed': 14,
          'winRate': '64%',
          'isRanked': true,
        }),
      );

      expect(find.text('Matches played'), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      expect(find.text('Win rate'), findsOneWidget);
      expect(find.text('64%'), findsOneWidget);
      expect(find.text('Is ranked'), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget);
    });

    testWidgets('a false flag reads as a word, not as a bare false',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.stats, {'isRanked': false}));
      expect(find.text('No'), findsOneWidget);
      expect(find.text('false'), findsNothing);
    });

    testWidgets('a snake_case key is humanised too', (tester) async {
      await pumpCard(tester, card(ScoutCardType.stats, {'clean_sheets': 3}));
      expect(find.text('Clean sheets'), findsOneWidget);
    });

    testWidgets('nested values are skipped rather than stringified',
        (tester) async {
      // A `toString()` of a Map in a chat card is unreadable, so the renderer shows
      // only what it can format.
      await pumpCard(
        tester,
        card(ScoutCardType.stats, {
          'matchesPlayed': 14,
          'breakdown': {'home': 8, 'away': 6},
          'recent': [1, 2, 3],
        }),
      );

      expect(find.text('Matches played'), findsOneWidget);
      expect(find.text('Breakdown'), findsNothing);
      expect(find.text('Recent'), findsNothing);
    });

    testWidgets('a null and an empty value are both skipped', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.stats, {
          'matchesPlayed': 14,
          'nickname': '',
          'position': null,
        }),
      );

      expect(find.text('Nickname'), findsNothing);
      expect(find.text('Position'), findsNothing);
      expect(find.text('Matches played'), findsOneWidget);
    });

    testWidgets('a payload with nothing renderable renders nothing',
        (tester) async {
      await pumpCard(tester, card(ScoutCardType.stats, {'buttons': []}));
      expect(tester.getSize(find.byType(ScoutExtraCard)).height, 0.0);
    });

    // Pinned as it behaves, not as it should: `_StatsCard.build`
    // (lib/widgets/assistant/scout_cards_more.dart:802) walks every scalar key and
    // skips only `buttons`, so `title` is consumed twice — once as the heading and
    // once as an ordinary row. The fix is to skip `title` alongside `buttons`.
    testWidgets('a title is rendered twice, as heading and as a row',
        (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.stats, {'title': 'Season', 'matchesPlayed': 14}),
      );

      expect(find.text('Season'), findsNWidgets(2));
      expect(find.text('Title'), findsOneWidget);
    });

    testWidgets('a nameless stats card still has a heading', (tester) async {
      await pumpCard(tester, card(ScoutCardType.stats, {'matchesPlayed': 14}));
      expect(find.text('Stats'), findsOneWidget);
    });

    testWidgets('the backend buttons still fire', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.stats, {
          'matchesPlayed': 14,
          'buttons': [chip('My ELO', 'team_stats')],
        }),
      );

      await tester.tap(find.text('My ELO'));
      expect(chips.single.action, 'team_stats');
    });
  });

  group('at a doubled text scale', () {
    testWidgets('a player card grows rather than clipping', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.player, {
          'name': 'Bilal Ahmed',
          'city': 'Karachi',
          'position': 'Midfielder',
          'trustScore': 82,
          'matchesPlayed': 14,
          'matchPct': 88,
          'reasons': ['Plays your sport'],
        }),
        textScale: 2.0,
      );

      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('88% match'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('a tournament card keeps its bar and deadline', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.tournament, {
          'name': 'Ramzan Cup',
          'sport': 'Football',
          'entryFeeLabel': 'PKR 5,000',
          'maxTeams': 16,
          'teamsIn': 9,
          'deadlineLabel': '19 Mar',
        }),
        textScale: 2.0,
      );

      expect(find.text('9 of 16 teams in'), findsOneWidget);
      expect(find.text('Registration closes 19 Mar'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the wallet keeps both figures legible', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.wallet, {
          'balanceLabel': 'PKR 5,200',
          'frozenLabel': 'PKR 1,800',
          'frozen': 1800,
        }),
        textScale: 2.0,
      );

      expect(find.text('PKR 5,200'), findsOneWidget);
      expect(find.text('PKR 1,800'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the policy figures wrap instead of overflowing', (tester) async {
      await pumpCard(
        tester,
        card(ScoutCardType.policy, {
          'title': 'Cancellation policy',
          'windowHours': 24,
          'refundPct': 100,
          'depositPct': 25,
          'graceMinutes': 15,
        }),
        textScale: 2.0,
      );

      expect(find.text('24h'), findsOneWidget);
      expect(find.text('No-show grace'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
