// Help & Support: a stateless screen with no network, and therefore the shortest
// contract in the directory — but not an empty one.
//
// Two things make it worth testing. The first is that the FAQ text is the only place
// in the product where the escrow rules are stated to a player in words: the full price
// frozen on booking, released on check-in, and a 20% at-risk deposit lost to a late
// cancellation. Those numbers are duplicated from the backend's refund arithmetic
// rather than derived from it, so a change to the policy silently leaves this screen
// stating the old one. The tests below quote the figures, which is the only mechanism
// available for noticing that drift.
//
// The second is that both contact cards now do something. Live Chat pushes the
// SupportChatScreen — the Scout-backed support surface — and Email Us opens a mail
// composer, copying the address as a fallback when no client answers. The two tests
// below tap each card and assert that route and that fallback, which is what keeps the
// wiring from silently regressing to the `onTap: () {}` no-ops these once were.
//
// A third finding is recorded here rather than tested, because it is a contradiction
// between two screens rather than a defect in either: the wallet top-up FAQ says
// top-ups "are handled manually by administrators during our beta phase", while
// lib/screens/player/wallet_screen.dart ships a working top-up sheet that posts to
// `/wallet/topup`. One of the two is out of date.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/help_support_screen.dart';
import 'package:sportlynk/screens/player/support_chat_screen.dart';

import '../screen_harness.dart';

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('when the screen opens', () {
    testWidgets('it is titled', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.text('Help & Support'), findsOneWidget);
    });

    testWidgets('it asks the question it is there to answer', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.text('How can we help you?'), findsOneWidget);
      expect(
        find.text('Find answers to common questions or reach out to our team.'),
        findsOneWidget,
      );
    });

    testWidgets('it makes no network request', (tester) async {
      // A support screen that cannot render offline is useless in the situation a
      // player most needs it: the API being unreachable.
      await pumpScreen(tester, const HelpSupportScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
    });

    testWidgets('it shows no loading state', (tester) async {
      // There is nothing to wait for, so a spinner here would be a bug rather than a
      // missing state.
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('it renders without a session', (tester) async {
      // Reachable from a signed-out state, so a token read here would throw before
      // first paint.
      await pumpScreen(
        tester,
        const HelpSupportScreen(),
        auth: FakeAuth(token: null),
      );

      expect(find.text('How can we help you?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the contact cards', () {
    testWidgets('both routes to a human are offered', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.text('Live Chat'), findsOneWidget);
      expect(find.text('Email Us'), findsOneWidget);
    });

    testWidgets('live chat names Scout rather than promising a human wait',
        (tester) async {
      // The card once read "Typically replies in minutes" — a wait-time claim for a
      // person. Scout answers instantly and is not one, so the subtitle says so.
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.text('Instant help from Scout'), findsOneWidget);
      expect(find.text('Typically replies in minutes'), findsNothing);
    });

    testWidgets('the support address is shown rather than hidden behind the tap',
        (tester) async {
      // The address is the fallback when the in-app route fails, so it has to be
      // readable without tapping anything.
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.text('support@sportlynk.com'), findsOneWidget);
    });

    testWidgets('each card carries an icon', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      expect(find.byIcon(Icons.email_outlined), findsOneWidget);
    });

    // Wired in place of the former `onTap: () {}` no-op. The card pushes the
    // SupportChatScreen through a MaterialPageRoute, which onGenerateRoute does not
    // record — so the proof is the surface itself being on screen, not the route log.
    testWidgets('tapping live chat opens the support chat', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('Live Chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(SupportChatScreen), findsOneWidget);
    });

    // The card opens a mail composer; when no client answers — the web build, or a
    // phone with no mail app — it copies the address and names it in a snackbar rather
    // than doing nothing, which is what this card once did. Two channels are stubbed:
    // url_launcher reports failure so the fallback runs, and the platform channel is
    // answered so the clipboard write the fallback awaits actually completes.
    testWidgets('tapping email us offers the address when no mail app answers',
        (tester) async {
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(launcher, (_) async => false);
      messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(launcher, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('Email Us'));
      // The fallback awaits the launch attempt and then the clipboard write before it
      // shows the snackbar, so it takes a few frames to reach the tree.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Address copied'), findsOneWidget);
    });
  });

  group('the frequently asked questions', () {
    testWidgets('the section is headed', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.text('Frequently Asked Questions'), findsOneWidget);
    });

    testWidgets('all three questions are listed', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.text('How does the escrow work?'), findsOneWidget);
      expect(find.text('What happens if I cancel a booking?'), findsOneWidget);
      expect(find.text('How can I top up my wallet?'), findsOneWidget);
    });

    testWidgets('the answers start collapsed', (tester) async {
      // Three expanded answers would push the contact cards off the first screen,
      // which is the opposite of what a player in trouble needs.
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.textContaining('the full slot price is frozen'), findsNothing);
    });

    testWidgets('each question is its own expander', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      expect(find.byType(ExpansionTile), findsNWidgets(3));
    });

    testWidgets('expanding the escrow question states the deposit is at risk',
        (tester) async {
      // The at-risk portion is the single most consequential fact in the booking flow
      // and the only place a player is told it before they lose it.
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('How does the escrow work?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining(
            '20% of the price is the at-risk deposit you can lose on a late cancellation or a no-show.'),
        findsOneWidget,
      );
    });

    testWidgets('the escrow answer says the money is released on check-in',
        (tester) async {
      // The other half of the arrangement: the owner is not paid on booking, which is
      // what makes the QR check-in matter rather than being a formality.
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('How does the escrow work?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining(
            'released to the venue owner only when you check in with your QR code'),
        findsOneWidget,
      );
    });

    testWidgets('the cancellation answer states the twenty-four hour line',
        (tester) async {
      // These figures are duplicated from the backend refund arithmetic rather than
      // read from it, so quoting them here is how a policy change gets noticed.
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('What happens if I cancel a booking?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining(
            'If you cancel more than 24 hours before the start time, the full amount is refunded.'),
        findsOneWidget,
      );
    });

    testWidgets('the cancellation answer states what a late cancellation costs',
        (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('What happens if I cancel a booking?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining(
            'you get 80% back and the 20% deposit goes to the venue owner'),
        findsOneWidget,
      );
    });

    testWidgets('the top-up answer is present', (tester) async {
      // Recorded rather than endorsed: this answer says top-ups are handled manually
      // by administrators, while the wallet screen ships a top-up sheet that posts to
      // `/wallet/topup`. One of the two is out of date.
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('How can I top up my wallet?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('wallet top-ups are handled manually'),
          findsOneWidget);
    });

    testWidgets('an expanded answer collapses again', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('How does the escrow work?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('the full slot price is frozen'), findsOneWidget);

      await tester.tap(find.text('How does the escrow work?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('the full slot price is frozen'), findsNothing);
    });

    testWidgets('one question can be open while another is closed', (tester) async {
      // Independent expanders rather than an accordion: a player comparing the
      // cancellation and escrow rules needs both visible.
      await pumpScreen(tester, const HelpSupportScreen());

      await tester.tap(find.text('How does the escrow work?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('What happens if I cancel a booking?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('the full slot price is frozen'), findsOneWidget);
      expect(find.textContaining('the full amount is refunded'), findsOneWidget);
    });

    testWidgets('a question is a large enough target', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen());

      final size = tester.getSize(find.byType(ExpansionTile).first);
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('at a doubled text scale', () {
    testWidgets('the collapsed screen does not clip', (tester) async {
      // The two contact cards are fixed-width `Expanded` halves of a `Row`, which is
      // where a scaled title would clip if anywhere.
      await pumpScreen(tester, const HelpSupportScreen(), textScale: 2.0);

      expectNoOverflow(tester);
    });

    testWidgets('an expanded answer does not clip', (tester) async {
      await pumpScreen(tester, const HelpSupportScreen(), textScale: 2.0);

      await tapVisible(tester, find.text('How does the escrow work?'));
      await tester.pump(const Duration(milliseconds: 400));

      expectNoOverflow(tester);
    });
  });
}
