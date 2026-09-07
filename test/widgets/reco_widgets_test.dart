// The recommender UI: a percentage, the breakdown behind it, and the rail of
// suggested players — three widgets whose whole job is to never overstate what the
// server computed.
//
// The rule the file exists to defend is stated at the top of lib/models/reco.dart: a
// percentage is shown only when the ranking service produced it. Both the weighted
// scorer and the SQL fallback ship the same field names, with the score fields simply
// null on the fallback, which means every screen here is one null check away from
// printing an authoritative-looking number that nothing measured. So every widget is
// asserted twice, once on each path, and the fallback assertions are the ones written
// as "and no number appears anywhere" rather than "and the right number appears".
//
// A null component is not a zero either, and that distinction is finer than it looks:
// a teamless player has no team rating and a player with no bookings has no home area,
// and the server scored both neutrally rather than punishing a cold start. Drawing
// those as 0% bars would tell the user the candidate scored badly on something they
// were never measured on. The breakdown row therefore has to print a dash, italicise
// its sentence, draw no bar at all, and still show the block's weight — because the
// weight is what the formula says, not what this candidate scored.
//
// Colour is shared with the competitiveness bar on purpose, through
// CompetitivenessTone, so a 62% reads the same on both. That coupling is asserted
// rather than assumed: two percentages with two colour scales on one screen would make
// both meaningless, and nothing in the type system stops a later edit from giving this
// file its own bands.
//
// The rail's three empty states are three different sentences because they are three
// different facts — nobody to suggest, the scorer is down, the read failed — and only
// the third offers a Retry. A rail that said "no players to suggest" when the service
// was unreachable would be a lie the user cannot detect.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/reco.dart';
import 'package:sportlynk/widgets/match_widgets.dart'
    show CompetitivenessTone, TrustBadgeChip;
import 'package:sportlynk/widgets/reco_widgets.dart';

import 'widget_harness.dart';

/// The ranking block as the scorer sends it: available, weighted, ordered.
RankingInfo ranked({
  Map<String, double> weights = const {
    'fit': 0.35,
    'elo': 0.30,
    'activity': 0.20,
    'zone': 0.15,
  },
  List<String> order = const ['fit', 'elo', 'activity', 'zone'],
  int? considered = 12,
  String? specVersion = 'reco-rank-v1',
  String? specFingerprint = '1a6c5f39bf5a2c56',
}) =>
    RankingInfo(
      source: 'ranked',
      available: true,
      specVersion: specVersion,
      specFingerprint: specFingerprint,
      weights: weights,
      componentOrder: order,
      considered: considered,
    );

/// The ranking block on the fallback path: no weights, no order, and a sentence.
RankingInfo fallback({
  String? note = 'Ranking service unavailable — showing recent players first',
}) =>
    RankingInfo(source: 'fallback', available: false, fallbackNote: note);

PlayerSuggestion suggestion({
  String userId = 'u1',
  String name = 'Bilal Ahmed',
  String? avatarUrl,
  List<String> sports = const ['Football'],
  int bookings = 4,
  bool hasHomeArea = true,
  int? trustScore = 78,
  String? trustBand = 'good',
  String? trustLabel = 'Good',
  int? matchPct = 83,
  Map<String, double?>? components = const {
    'fit': 1.0,
    'elo': 0.72,
    'activity': 0.55,
    'zone': 0.90,
  },
  String? eloSource = 'team_elo',
  List<String> reasons = const ['Plays football', 'Books nearby'],
}) =>
    PlayerSuggestion(
      userId: userId,
      name: name,
      avatarUrl: avatarUrl,
      sports: sports,
      bookingsLast30d: bookings,
      hasHomeArea: hasHomeArea,
      trustScore: trustScore,
      trustBand: trustBand,
      trustLabel: trustLabel,
      matchPct: matchPct,
      components: components,
      eloSource: eloSource,
      reasons: reasons,
    );

SuggestedPlayers payload({
  RankingInfo? ranking,
  List<PlayerSuggestion> list = const [],
  String? sport = 'Football',
  String? city = 'Karachi',
  String? homeCity = 'Karachi',
}) =>
    SuggestedPlayers(
      teamId: 't1',
      sport: sport,
      city: city,
      homeCity: homeCity,
      ranking: ranking ?? ranked(),
      suggestions: list,
    );

void main() {
  /// One widget on a phone-sized surface, in a scroll view so a tall breakdown does
  /// not overflow the frame instead of the row under test.
  Future<void> pumpOne(
    WidgetTester tester,
    Widget child, {
    double textScale = 1.0,
    double width = 380,
  }) async {
    useDeviceSurface(tester);
    await pumpApp(
      tester,
      Scaffold(
        backgroundColor: AppColors.background,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SizedBox(width: width, child: child),
        ),
      ),
      textScale: textScale,
    );
  }

  Color? textColorOf(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).style?.color;

  group('the match percentage badge', () {
    testWidgets('a score is drawn as a percentage', (tester) async {
      await pumpOne(tester, const MatchPctBadge(pct: 83));
      expect(find.text('83%'), findsOneWidget);
    });

    // The fallback path sends matchPct null. Drawing "0%" there would rank a
    // candidate the scorer never scored.
    testWidgets('no score draws nothing at all, not a zero', (tester) async {
      await pumpOne(tester, const MatchPctBadge(pct: null));
      expect(find.byType(Text), findsNothing);
      expect(find.byType(Container), findsNothing,
          reason: 'an empty pill would still occupy the row');
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('a caption sits before the number', (tester) async {
      await pumpOne(tester, const MatchPctBadge(pct: 83, caption: 'MATCH'));
      expect(find.text('MATCH'), findsOneWidget);
      expect(find.text('83%'), findsOneWidget);
    });

    testWidgets('without a caption only the number is drawn', (tester) async {
      await pumpOne(tester, const MatchPctBadge(pct: 83));
      expect(find.byType(Text), findsOneWidget);
    });

    // The coupling to CompetitivenessTone is the point: 62% must be the same colour
    // here as on a competitiveness bar, or two percentages on one screen mean two
    // different things.
    testWidgets('the colour comes from the shared competitiveness bands',
        (tester) async {
      for (final entry in <int, Color>{
        90: AppColors.success,
        62: AppColors.accent,
        40: AppColors.warning,
        12: AppColors.error,
      }.entries) {
        await pumpOne(tester, MatchPctBadge(pct: entry.key));
        expect(textColorOf(tester, find.text('${entry.key}%')), entry.value,
            reason: '${entry.key}% must match CompetitivenessTone');
        expect(CompetitivenessTone.of(entry.key).color, entry.value);
      }
    });

    testWidgets('the compact form is smaller but says the same thing',
        (tester) async {
      await pumpOne(tester, const MatchPctBadge(pct: 83, compact: true));
      final compact = tester.widget<Text>(find.text('83%')).style!.fontSize;
      await pumpOne(tester, const MatchPctBadge(pct: 83));
      final full = tester.widget<Text>(find.text('83%')).style!.fontSize;
      expect(compact, lessThan(full!));
    });

    testWidgets('a badge in a narrow row does not overflow', (tester) async {
      await pumpOne(
        tester,
        const Row(children: [MatchPctBadge(pct: 100, caption: 'MATCH')]),
        width: 90,
      );
      expectNoOverflow(tester);
    });
  });

  group('what ranked the list', () {
    testWidgets('the ranked path names the ranking, not AI', (tester) async {
      await pumpOne(tester, RankingSourceNote(ranking: ranked()));
      expect(find.text('SportLynk ranking'), findsOneWidget);
      expect(find.textContaining('AI'), findsNothing,
          reason: 'a published weighted formula is not a trained model');
      expect(find.byIcon(Icons.insights), findsOneWidget);
    });

    testWidgets('a detail is appended after the label', (tester) async {
      await pumpOne(
        tester,
        RankingSourceNote(ranking: ranked(), detail: '12 players weighed'),
      );
      expect(find.text('SportLynk ranking · 12 players weighed'), findsOneWidget);
    });

    // A degraded ordering must never be presented as the good one.
    testWidgets('the fallback shows the server\'s own sentence and a warning tone',
        (tester) async {
      await pumpOne(tester, RankingSourceNote(ranking: fallback()));
      expect(
        find.text('Ranking service unavailable — showing recent players first'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.insights), findsNothing);
      expect(tester.widget<Icon>(find.byIcon(Icons.info_outline)).color,
          AppColors.warning);
    });

    testWidgets('a fallback with no sentence still explains itself',
        (tester) async {
      await pumpOne(tester, RankingSourceNote(ranking: fallback(note: null)));
      expect(
        find.text('Ranking service unavailable — showing a basic ordering'),
        findsOneWidget,
      );
    });

    // The detail belongs to the ranked path only: "12 players weighed" beside a
    // fallback would claim the scorer ran.
    testWidgets('a detail is not appended to a fallback', (tester) async {
      await pumpOne(
        tester,
        RankingSourceNote(ranking: fallback(), detail: '12 players weighed'),
      );
      expect(find.textContaining('12 players weighed'), findsNothing);
    });

    testWidgets('a long fallback sentence wraps rather than overflowing',
        (tester) async {
      await pumpOne(
        tester,
        RankingSourceNote(
          ranking: fallback(
            note: 'The ranking service did not answer in time, so this list is '
                'ordered by how recently each player booked a venue.',
          ),
        ),
        width: 200,
      );
      expectNoOverflow(tester);
    });
  });

  group('the breakdown behind a score', () {
    List<ScoreComponent> parts({
      Map<String, double?>? components = const {
        'fit': 1.0,
        'elo': 0.72,
        'activity': 0.55,
        'zone': 0.90,
      },
      RankingInfo? info,
    }) =>
        (info ?? ranked()).breakdown(components);

    testWidgets('collapsed it is one tappable line', (tester) async {
      await pumpOne(tester, WhyThisMatch(components: parts()));
      expect(find.text('Why this match?'), findsOneWidget);
      expect(find.text('Sport fit'), findsNothing,
          reason: 'the panel is not built until it is opened');
    });

    testWidgets('a tap opens every block the server scored', (tester) async {
      await pumpOne(tester, WhyThisMatch(components: parts()));
      await tester.tap(find.text('Why this match?'));
      await tester.pumpAndSettle();
      expect(find.text('Sport fit'), findsOneWidget);
      expect(find.text('Level match'), findsOneWidget);
      expect(find.text('Recent activity'), findsOneWidget);
      expect(find.text('Same area'), findsOneWidget);
    });

    // The order is the server's, not this widget's: the breakdown has to read in the
    // order the spec publishes or it explains a different formula.
    testWidgets('the blocks keep the order the server published', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: ranked(order: const ['zone', 'fit', 'elo', 'activity'])
              .breakdown(const {'fit': 1.0, 'elo': 0.72, 'activity': 0.55, 'zone': 0.9}),
          initiallyExpanded: true,
        ),
      );
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => const ['Sport fit', 'Level match', 'Recent activity', 'Same area']
              .contains(d))
          .toList();
      expect(labels, ['Same area', 'Sport fit', 'Level match', 'Recent activity']);
    });

    testWidgets('each block shows its own percentage', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(components: parts(), initiallyExpanded: true),
      );
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('72%'), findsOneWidget);
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('90%'), findsOneWidget);
    });

    testWidgets('each block shows its share of the total', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(components: parts(), initiallyExpanded: true),
      );
      expect(find.text('35% of score'), findsOneWidget);
      expect(find.text('30% of score'), findsOneWidget);
      expect(find.text('20% of score'), findsOneWidget);
      expect(find.text('15% of score'), findsOneWidget);
    });

    // A block the server could not measure. The dash, the italic sentence and the
    // missing bar are all one contract: nothing was measured, and it was not held
    // against the candidate.
    testWidgets('an unmeasured block is a dash, never a zero', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(components: const {'elo': null}),
          initiallyExpanded: true,
        ),
      );
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
      expect(
        find.text('No rated team yet — not counted against them'),
        findsOneWidget,
      );
    });

    testWidgets('an unmeasured block\'s sentence is italic', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(components: const {'zone': null}),
          initiallyExpanded: true,
        ),
      );
      final t = tester.widget<Text>(
        find.text('No usual venue yet — not counted against them'),
      );
      expect(t.style?.fontStyle, FontStyle.italic);
    });

    testWidgets('an unmeasured block draws no bar', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(components: const {'elo': null}),
          initiallyExpanded: true,
        ),
      );
      expect(find.byType(AnimatedContainer), findsNothing);
    });

    // The weight is the formula's, not the candidate's, so it stays visible even
    // when there is nothing to weigh.
    testWidgets('an unmeasured block still shows its weight', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(components: const {'elo': null}),
          initiallyExpanded: true,
        ),
      );
      expect(find.text('30% of score'), findsOneWidget);
    });

    testWidgets('an unmeasured block is drawn in muted ink', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(components: const {'elo': null}),
          initiallyExpanded: true,
        ),
      );
      expect(textColorOf(tester, find.text('—')), AppColors.textSecondary);
    });

    testWidgets('a measured block is coloured by the shared bands', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(components: const {'elo': 0.9}),
          initiallyExpanded: true,
        ),
      );
      expect(textColorOf(tester, find.text('90%')), AppColors.success);
    });

    testWidgets('a measured block\'s bar is as wide as its value', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(components: const {'elo': 0.5}),
          initiallyExpanded: true,
        ),
        width: 300,
      );
      await tester.pumpAndSettle();
      final bar = tester.getSize(find.byType(AnimatedContainer));
      final track = tester.getSize(find.byType(LayoutBuilder));
      expect(bar.width, closeTo(track.width / 2, 1));
    });

    // The row must vanish on the fallback path rather than open onto blank bars,
    // which is why an empty breakdown draws nothing at all.
    testWidgets('nothing to explain means no row at all', (tester) async {
      await pumpOne(tester, const WhyThisMatch(components: []));
      expect(find.text('Why this match?'), findsNothing);
    });

    testWidgets('collapsed, the first reason previews on the line', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(),
          reasons: const ['Plays football', 'Books nearby'],
        ),
      );
      expect(find.text('Plays football'), findsOneWidget);
      expect(find.text('Books nearby'), findsNothing);
    });

    testWidgets('opened, every reason becomes a chip', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(),
          reasons: const ['Plays football', 'Books nearby'],
          initiallyExpanded: true,
        ),
      );
      expect(find.text('Plays football'), findsOneWidget);
      expect(find.text('Books nearby'), findsOneWidget);
    });

    // A single reason is already the preview line; repeating it as a lone chip
    // would say the same thing twice.
    testWidgets('a single reason is not repeated as a chip', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(),
          reasons: const ['Plays football'],
          initiallyExpanded: true,
        ),
      );
      expect(find.text('Plays football'), findsOneWidget);
    });

    testWidgets('the footnote is drawn under the blocks', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: parts(),
          footnote: 'Weights published by reco-rank-v1',
          initiallyExpanded: true,
        ),
      );
      expect(find.text('Weights published by reco-rank-v1'), findsOneWidget);
    });

    testWidgets('no footnote draws no trailing line', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(components: parts(), initiallyExpanded: true),
      );
      expect(find.textContaining('published by'), findsNothing);
    });

    testWidgets('a second tap closes it again', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(components: parts(), initiallyExpanded: true),
      );
      expect(find.text('Sport fit'), findsOneWidget);
      await tester.tap(find.text('Why this match?'));
      await tester.pumpAndSettle();
      expect(find.text('Sport fit'), findsNothing);
    });

    testWidgets('an unknown component key falls back to the key itself',
        (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: RankingInfo(
            source: 'ranked',
            available: true,
            weights: const {'novelty': 0.1},
            componentOrder: const ['novelty'],
          ).breakdown(const {'novelty': null}),
          initiallyExpanded: true,
        ),
      );
      expect(find.text('novelty'), findsOneWidget);
      expect(find.text('Not known — not counted against them'), findsOneWidget);
    });

    testWidgets('a block with no published weight reads as zero of the score',
        (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: RankingInfo(
            source: 'ranked',
            available: true,
            componentOrder: const ['fit'],
          ).breakdown(const {'fit': 1.0}),
          initiallyExpanded: true,
        ),
      );
      expect(find.text('0% of score'), findsOneWidget);
    });
  });

  group('the suggested players rail', () {
    Widget rail({
      SuggestedPlayers? data,
      bool loading = false,
      bool failed = false,
      bool busy = false,
      List<String>? retries,
      List<PlayerSuggestion>? invited,
    }) =>
        SuggestedPlayersRail(
          data: data ?? payload(list: [suggestion()]),
          loading: loading,
          failed: failed,
          busy: busy,
          onRetry: () async => retries?.add('retry'),
          onInvite: (s) => invited?.add(s),
        );

    testWidgets('while loading it is a spinner, not an empty rail',
        (tester) async {
      await pumpOne(tester, rail(loading: true));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
    });

    // Three different facts, three different sentences. This is the one that
    // offers a way out.
    testWidgets('a failed read says so and offers a retry', (tester) async {
      final retries = <String>[];
      await pumpOne(tester, rail(failed: true, retries: retries));
      expect(find.text('Could not load suggestions.'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(retries, ['retry']);
    });

    testWidgets('an empty ranked list explains where suggestions come from',
        (tester) async {
      await pumpOne(tester, rail(data: payload()));
      expect(
        find.textContaining('Suggestions come from players who book Football venues '
            'near Karachi.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing,
          reason: 'there is nothing to retry when the read succeeded');
    });

    testWidgets('an empty list with no sport or city still reads as a sentence',
        (tester) async {
      await pumpOne(
        tester,
        rail(data: payload(sport: null, city: null, homeCity: null)),
      );
      expect(
        find.textContaining('players who book this sport venues near your city.'),
        findsOneWidget,
      );
    });

    // The pool was built from the city of the venues the members actually book,
    // which is not always the team's own city field.
    testWidgets('the home city wins over the team\'s own city field',
        (tester) async {
      await pumpOne(
        tester,
        rail(data: payload(city: 'Karachi', homeCity: 'Lahore')),
      );
      expect(find.textContaining('near Lahore.'), findsOneWidget);
      expect(find.textContaining('near Karachi.'), findsNothing);
    });

    // An empty list on the fallback path is not "nobody to suggest": the scorer
    // never ran, so the rail says what the server said.
    testWidgets('an empty fallback list quotes the server, not a cold-start note',
        (tester) async {
      await pumpOne(tester, rail(data: payload(ranking: fallback())));
      expect(
        find.text('Ranking service unavailable — showing recent players first'),
        findsOneWidget,
      );
      expect(find.textContaining('Suggestions come from players'), findsNothing);
    });

    testWidgets('an empty fallback with no sentence still says something',
        (tester) async {
      await pumpOne(
        tester,
        rail(data: payload(ranking: fallback(note: null))),
      );
      expect(find.text('Suggestions are unavailable right now.'), findsOneWidget);
    });

    testWidgets('a loaded rail carries the attribution above the cards',
        (tester) async {
      await pumpOne(tester, rail());
      expect(find.text('SportLynk ranking · 12 players weighed'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('a single candidate weighed is not pluralised', (tester) async {
      await pumpOne(
        tester,
        rail(data: payload(ranking: ranked(considered: 1), list: [suggestion()])),
      );
      expect(find.text('SportLynk ranking · 1 player weighed'), findsOneWidget);
    });

    testWidgets('an endpoint that sends no count omits the detail',
        (tester) async {
      await pumpOne(
        tester,
        rail(data: payload(ranking: ranked(considered: null), list: [suggestion()])),
      );
      expect(find.text('SportLynk ranking'), findsOneWidget);
      expect(find.textContaining('weighed'), findsNothing);
    });

    testWidgets('the rail scrolls sideways so it cannot push the roster off',
        (tester) async {
      await pumpOne(tester, rail());
      expect(tester.widget<ListView>(find.byType(ListView)).scrollDirection,
          Axis.horizontal);
    });

    testWidgets('every candidate gets a card', (tester) async {
      await pumpOne(
        tester,
        rail(
          data: payload(list: [
            suggestion(userId: 'u1', name: 'Bilal Ahmed'),
            suggestion(userId: 'u2', name: 'Hamza Khan'),
          ]),
        ),
      );
      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('Hamza Khan'), findsOneWidget);
    });
  });

  group('a card on the rail', () {
    Future<List<PlayerSuggestion>> pumpCard(
      WidgetTester tester, {
      PlayerSuggestion? s,
      RankingInfo? ranking,
      bool busy = false,
    }) async {
      final invited = <PlayerSuggestion>[];
      await pumpOne(
        tester,
        SuggestedPlayersRail(
          data: payload(ranking: ranking, list: [s ?? suggestion()]),
          busy: busy,
          onRetry: () async {},
          onInvite: invited.add,
        ),
      );
      return invited;
    }

    testWidgets('it names the player, their sports and their activity',
        (tester) async {
      await pumpCard(tester);
      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('Football'), findsOneWidget);
      expect(find.text('4 bookings · 30d'), findsOneWidget);
    });

    testWidgets('a ranked candidate carries the percentage', (tester) async {
      await pumpCard(tester);
      expect(find.text('83%'), findsOneWidget);
    });

    // The fallback path is where a number would be invented. Nothing on the card
    // may show one.
    testWidgets('a fallback candidate carries no percentage at all',
        (tester) async {
      await pumpCard(
        tester,
        ranking: fallback(),
        s: suggestion(matchPct: null, components: null, reasons: const []),
      );
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('a player with no avatar shows their initial', (tester) async {
      await pumpCard(tester);
      expect(find.text('B'), findsOneWidget);
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
        isNull,
      );
    });

    testWidgets('an avatar url replaces the initial', (tester) async {
      await pumpCard(
        tester,
        s: suggestion(avatarUrl: 'https://cdn.example.com/a.png'),
      );
      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isA<CachedNetworkImageProvider>());
      expect(avatar.child, isNull);
      expect(find.text('B'), findsNothing);
    });

    testWidgets('an empty avatar url is treated as none', (tester) async {
      await pumpCard(tester, s: suggestion(avatarUrl: ''));
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('an unfilled sports list says so rather than nothing',
        (tester) async {
      await pumpCard(tester, s: suggestion(sports: const []));
      expect(find.text('No sports listed'), findsOneWidget);
    });

    testWidgets('a player with no bookings says so rather than showing a zero',
        (tester) async {
      await pumpCard(tester, s: suggestion(bookings: 0));
      expect(find.text('No recent bookings'), findsOneWidget);
      expect(find.textContaining('0 booking'), findsNothing);
    });

    testWidgets('a single booking is not pluralised', (tester) async {
      await pumpCard(tester, s: suggestion(bookings: 1));
      expect(find.text('1 booking · 30d'), findsOneWidget);
    });

    testWidgets('the trust standing is shown with its score', (tester) async {
      await pumpCard(tester);
      expect(find.text('Good · 78'), findsOneWidget);
    });

    testWidgets('a player with no trust band shows no trust chip', (tester) async {
      await pumpCard(
        tester,
        s: suggestion(trustBand: null, trustLabel: null, trustScore: null),
      );
      expect(find.byType(TrustBadgeChip), findsOneWidget);
      expect(find.textContaining('·'), findsNothing,
          reason: 'the chip renders nothing without a band');
    });

    testWidgets('the invite button hands back the candidate it belongs to',
        (tester) async {
      final invited = await pumpCard(tester, s: suggestion(userId: 'u-77'));
      await tester.tap(find.text('Invite'));
      await tester.pump();
      expect(invited.map((s) => s.userId), ['u-77']);
    });

    // A second invite while one is being minted would create two links.
    testWidgets('the invite button is dead while an invite is being minted',
        (tester) async {
      final invited = await pumpCard(tester, busy: true);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Invite'), warnIfMissed: false);
      await tester.pump();
      expect(invited, isEmpty);
    });

    testWidgets('a card does not overflow its 172 logical pixels', (tester) async {
      await pumpCard(
        tester,
        s: suggestion(
          name: 'Muhammad Abdul Rehman Siddiqui',
          sports: const ['Football', 'Cricket', 'Badminton'],
          trustLabel: 'Excellent standing',
        ),
      );
      expectNoOverflow(tester);
    });
  });

  group('the details sheet behind a card', () {
    Future<void> openSheet(
      WidgetTester tester, {
      PlayerSuggestion? s,
      RankingInfo? ranking,
      bool busy = false,
      List<PlayerSuggestion>? invited,
    }) async {
      useDeviceSurface(tester);
      await pumpApp(
        tester,
        Scaffold(
          body: SuggestedPlayersRail(
            data: payload(ranking: ranking, list: [s ?? suggestion()]),
            busy: busy,
            onRetry: () async {},
            onInvite: (x) => invited?.add(x),
          ),
        ),
      );
      await tester.tap(find.text('Bilal Ahmed'));
      await tester.pumpAndSettle();
    }

    testWidgets('a tap on the card opens the breakdown already expanded',
        (tester) async {
      await openSheet(tester);
      expect(find.text('Sport fit'), findsOneWidget);
      expect(find.text('Level match'), findsOneWidget);
    });

    testWidgets('the sheet repeats who it is about', (tester) async {
      await openSheet(tester);
      expect(find.text('Bilal Ahmed'), findsWidgets);
      expect(find.text('MATCH'), findsOneWidget);
    });

    testWidgets('the level block names the input it used', (tester) async {
      await openSheet(tester);
      expect(
        find.textContaining('Level taken from the rating of the team they play for'),
        findsOneWidget,
      );
    });

    // A player with no team was scored from their trust score, and the same bar
    // therefore means something different.
    testWidgets('a teamless player\'s level source is named as the proxy',
        (tester) async {
      await openSheet(tester, s: suggestion(eloSource: 'trust_proxy'));
      expect(
        find.textContaining('No team yet — their trust score stood in for a rating'),
        findsOneWidget,
      );
    });

    testWidgets('the weights are attributed to the published spec',
        (tester) async {
      await openSheet(tester);
      expect(
        find.textContaining('Weights published by reco-rank-v1 · 1a6c5f39'),
        findsOneWidget,
      );
    });

    testWidgets('a spec with no fingerprint is attributed by version alone',
        (tester) async {
      await openSheet(tester, ranking: ranked(specFingerprint: null));
      expect(find.textContaining('Weights published by reco-rank-v1'), findsOneWidget);
      expect(find.textContaining('·  '), findsNothing);
    });

    testWidgets('a player with no usual venue says so as a fact', (tester) async {
      await openSheet(tester, s: suggestion(hasHomeArea: false));
      expect(find.text('No usual venue yet'), findsOneWidget);
    });

    testWidgets('a player with a usual venue shows no such fact', (tester) async {
      await openSheet(tester);
      expect(find.text('No usual venue yet'), findsNothing);
    });

    // No breakdown means no bars: the sheet says what the list is instead.
    testWidgets('a fallback candidate gets a sentence where the bars would be',
        (tester) async {
      await openSheet(
        tester,
        ranking: fallback(),
        s: suggestion(matchPct: null, components: null, reasons: const []),
      );
      expect(
        find.text('Ranking service unavailable — showing recent players first'),
        findsOneWidget,
      );
      expect(find.byType(WhyThisMatch), findsNothing);
    });

    testWidgets('a fallback with no sentence still explains the ordering',
        (tester) async {
      await openSheet(
        tester,
        ranking: fallback(note: null),
        s: suggestion(matchPct: null, components: null),
      );
      expect(
        find.text('No match breakdown available — this list is ordered by recent '
            'activity.'),
        findsOneWidget,
      );
    });

    // The platform has no direct player invite, so the button's promise has to be
    // exactly what it does.
    testWidgets('the invite button says what it actually mints', (tester) async {
      await openSheet(tester);
      expect(find.text('Create invite link'), findsOneWidget);
      expect(
        find.textContaining('mints a single-use link you send them yourself.'),
        findsOneWidget,
      );
    });

    testWidgets('inviting closes the sheet and reports the candidate',
        (tester) async {
      final invited = <PlayerSuggestion>[];
      await openSheet(tester, s: suggestion(userId: 'u-91'), invited: invited);
      await tester.tap(find.text('Create invite link'));
      await tester.pumpAndSettle();
      expect(invited.map((s) => s.userId), ['u-91']);
      expect(find.text('Create invite link'), findsNothing,
          reason: 'the sheet closes before the invite is minted');
    });

    testWidgets('while busy the button says so and does nothing', (tester) async {
      final invited = <PlayerSuggestion>[];
      await openSheet(tester, busy: true, invited: invited);
      expect(find.text('Working…'), findsOneWidget);
      expect(
        tester
            .widgetList<FilledButton>(find.byType(FilledButton))
            .any((b) => b.onPressed == null),
        isTrue,
      );
      await tester.tap(find.text('Working…'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(invited, isEmpty);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the percentage badge still lays out', (tester) async {
      await pumpOne(tester, const MatchPctBadge(pct: 83, caption: 'MATCH'),
          textScale: 2.0);
      expectNoOverflow(tester);
      expect(find.text('83%'), findsOneWidget);
    });

    testWidgets('the attribution line still lays out', (tester) async {
      await pumpOne(
        tester,
        RankingSourceNote(ranking: ranked(), detail: '12 players weighed'),
        textScale: 2.0,
      );
      expectNoOverflow(tester);
    });

    testWidgets('an open breakdown still lays out', (tester) async {
      await pumpOne(
        tester,
        WhyThisMatch(
          components: ranked().breakdown(const {'fit': 1.0, 'elo': null}),
          reasons: const ['Plays football', 'Books nearby'],
          footnote: 'Weights published by reco-rank-v1',
          initiallyExpanded: true,
        ),
        textScale: 2.0,
      );
      expectNoOverflow(tester);
      expect(find.text('Sport fit'), findsOneWidget);
    });

    testWidgets('the failed rail keeps its retry pressable', (tester) async {
      await pumpOne(
        tester,
        SuggestedPlayersRail(
          data: payload(),
          failed: true,
          onRetry: () async {},
          onInvite: (_) {},
        ),
        textScale: 2.0,
      );
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
