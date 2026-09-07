// HeaderIconButton and BrandWordmark: the two pieces of the home-screen header that
// exist in one file precisely so the player and owner headers cannot drift apart.
//
// The badge is the part worth pinning. It is a count rather than a flag, so a caller
// passes the server's number straight in and zero has to render nothing — a header
// that shows an empty red circle when there is nothing to read teaches the user to
// ignore the circle. Past ninety-nine the number stops informing and becomes "a lot",
// which is why the cap is asserted at its exact boundary rather than approximately.
//
// The badge overhangs the tap target, and is wrapped in an [IgnorePointer] for that
// reason: the corner it sits in is exactly where a thumb aims when there is a number
// there, and a badge that swallowed that tap would make the bell feel broken. The
// wrapper is asserted rather than described.
//
// The box measures 36 x 36, which is below the 48-pixel floor the project sets
// elsewhere. That is a deliberate, documented exception for this header rather than
// an oversight, so the size is pinned as it is: a change to either number should show
// up here and be argued, not land silently.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/widgets/header_actions.dart';

import 'widget_harness.dart';

/// The header is dark in both homes, so the widgets are framed on the brand colour.
Widget _framed(Widget child) =>
    Scaffold(backgroundColor: AppColors.primary, body: Center(child: child));

/// The badge's `Text`. Material puts several [IgnorePointer]s of its own in the
/// tree, so the badge is anchored on the only `Text` the button ever draws.
Finder _badgeText() => find.byType(Text);

void main() {
  group('the button itself', () {
    testWidgets('the icon sits in a 36-pixel box', (tester) async {
      await pumpApp(tester, _framed(const HeaderIconButton(icon: Icons.notifications)));
      expect(find.byIcon(Icons.notifications), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.notifications));
      expect(icon.size, 20);
      expect(icon.color, Colors.white);
      expect(sizeOf(tester, find.byType(InkWell)), const Size(36, 36));
    });

    testWidgets('a tap reaches the callback', (tester) async {
      var taps = 0;
      await pumpApp(tester,
          _framed(HeaderIconButton(icon: Icons.chat_bubble, onTap: () => taps++)));
      await tester.tap(find.byType(InkWell));
      expect(taps, 1);
    });

    // A header is built before its provider is attached in at least one screen, so a
    // null callback has to be inert rather than a crash.
    testWidgets('a button with no callback absorbs the tap', (tester) async {
      await pumpApp(tester, _framed(const HeaderIconButton(icon: Icons.chat_bubble)));
      await tester.tap(find.byType(InkWell));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tooltip is added only when one is given', (tester) async {
      await pumpApp(tester,
          _framed(const HeaderIconButton(icon: Icons.notifications, tooltip: 'Notifications')));
      expect(find.byTooltip('Notifications'), findsOneWidget);

      await pumpApp(tester, _framed(const HeaderIconButton(icon: Icons.notifications)));
      expect(find.byType(Tooltip), findsNothing);
    });
  });

  group('the unread badge', () {
    testWidgets('zero renders no badge at all', (tester) async {
      await pumpApp(tester, _framed(const HeaderIconButton(icon: Icons.notifications)));
      expect(find.byType(Positioned), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a count is drawn as itself', (tester) async {
      await pumpApp(tester,
          _framed(const HeaderIconButton(icon: Icons.notifications, badge: 3)));
      expect(tester.widget<Text>(_badgeText()).data, '3');
    });

    // The exact boundary: 99 is a number, 100 is "a lot".
    testWidgets('the cap starts one past ninety-nine', (tester) async {
      await pumpApp(tester,
          _framed(const HeaderIconButton(icon: Icons.notifications, badge: 99)));
      expect(tester.widget<Text>(_badgeText()).data, '99');

      await pumpApp(tester,
          _framed(const HeaderIconButton(icon: Icons.notifications, badge: 100)));
      expect(tester.widget<Text>(_badgeText()).data, '99+');

      await pumpApp(tester,
          _framed(const HeaderIconButton(icon: Icons.notifications, badge: 4210)));
      expect(tester.widget<Text>(_badgeText()).data, '99+');
    });

    // A negative count cannot arrive from the server, but a subtraction on the client
    // can produce one; it must read as nothing rather than as a badge saying "-1".
    testWidgets('a negative count renders nothing', (tester) async {
      await pumpApp(tester,
          _framed(const HeaderIconButton(icon: Icons.notifications, badge: -1)));
      expect(find.byType(Positioned), findsNothing);
    });

    testWidgets('the badge does not intercept the corner it overhangs', (tester) async {
      var taps = 0;
      await pumpApp(
          tester,
          _framed(HeaderIconButton(
              icon: Icons.notifications, badge: 12, onTap: () => taps++)));
      expect(
        find.descendant(of: find.byType(Positioned), matching: find.byType(IgnorePointer)),
        findsOneWidget,
      );
      await tester.tap(find.byType(InkWell));
      expect(taps, 1);
    });

    testWidgets('the badge is the error colour on the header background', (tester) async {
      await pumpApp(tester,
          _framed(const HeaderIconButton(icon: Icons.notifications, badge: 5)));
      final box = tester.widget<Container>(
        find.ancestor(of: _badgeText(), matching: find.byType(Container)).first,
      );
      expect((box.decoration! as BoxDecoration).color, AppColors.error);
    });
  });

  group('the wordmark', () {
    testWidgets('it reads SportLynk in two colours', (tester) async {
      await pumpApp(tester, _framed(const BrandWordmark()));
      final rich = tester.widget<RichText>(find.byType(RichText));
      expect(rich.text.toPlainText(), 'SportLynk');
      final spans = (rich.text as TextSpan).children!.cast<TextSpan>();
      expect(spans.first.text, 'Sport');
      expect(spans.first.style!.color, Colors.white);
      expect(spans.last.text, 'Lynk');
      expect(spans.last.style!.color, AppColors.accent);
    });

    testWidgets('the size defaults to 19 and is overridable', (tester) async {
      await pumpApp(tester, _framed(const BrandWordmark()));
      var spans = (tester.widget<RichText>(find.byType(RichText)).text as TextSpan)
          .children!
          .cast<TextSpan>();
      expect(spans.first.style!.fontSize, 19);

      await pumpApp(tester, _framed(const BrandWordmark(fontSize: 24)));
      spans = (tester.widget<RichText>(find.byType(RichText)).text as TextSpan)
          .children!
          .cast<TextSpan>();
      expect(spans.first.style!.fontSize, 24);
    });
  });
}
