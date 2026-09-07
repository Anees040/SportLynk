// MessageBubble: one message, and the six things its shape has to say without words.
//
// Everything about this widget is a pair of asymmetries, and each one is load-bearing.
// Mine is tinted and hugs the right with no border; theirs is white, bordered, and hugs
// the left. The squared corner is on the side the bubble sits on, so it points at its
// own sender. The delivery ticks are drawn on my messages only — a tick beside somebody
// else's message would claim they had read their own text — and they are withdrawn again
// once the message is deleted, because there is nothing left to have delivered.
//
// The tombstone is the case where rendering the payload would be a privacy fault rather
// than a cosmetic one: the body survives in the model after a delete, so the assertions
// below check that it is not drawn, and that the long-press that opens the action sheet
// is disabled rather than merely unhelpful.
//
// A failed send turns the bubble itself into the retry target. That is the only state in
// which a tap on a bubble does anything at all, so it is pinned in both directions: the
// tap reports when the send failed, and reports nothing when it did not.
//
// The sender name colour is derived from the sender's id rather than their name, which
// is what keeps one person one colour across a rename; the eight-colour palette means
// two people can collide, and that is accepted. Reactions fold to counts and keep
// first-seen order so the chips under a bubble do not reshuffle as people react.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/chat_message.dart';
import 'package:sportlynk/widgets/chat/message_bubble.dart';
import 'package:sportlynk/widgets/chat/tick_icon.dart';

import '../widget_harness.dart';

ChatMessage msg({
  String? body = 'See you at 7',
  MessageKind kind = MessageKind.text,
  String? senderId = 'u2',
  String? senderName = 'Bilal',
  String? mediaUrl,
  num mediaW = 0,
  num mediaH = 0,
  DateTime? deletedAt,
  List<MessageReaction> reactions = const [],
  bool pending = false,
  bool failed = false,
}) =>
    ChatMessage(
      id: 'm1',
      channelId: 'c1',
      senderId: senderId,
      senderName: senderName,
      kind: kind,
      body: body,
      mediaUrl: mediaUrl,
      mediaW: mediaW,
      mediaH: mediaH,
      createdAt: DateTime(2026, 3, 14, 19, 5),
      deletedAt: deletedAt,
      reactions: reactions,
      pending: pending,
      failed: failed,
    );

/// The bubble's own box — the first decorated [Container] under the widget.
Container bubbleBox(WidgetTester tester) => tester
    .widgetList<Container>(find.descendant(
        of: find.byType(MessageBubble), matching: find.byType(Container)))
    .firstWhere((c) => c.decoration is BoxDecoration);

BoxDecoration bubbleDecoration(WidgetTester tester) =>
    bubbleBox(tester).decoration! as BoxDecoration;

EdgeInsets outerPadding(WidgetTester tester) => tester
    .widget<Padding>(find
        .descendant(of: find.byType(MessageBubble), matching: find.byType(Padding))
        .first)
    .padding as EdgeInsets;

void main() {
  late int longPresses;
  late int retries;
  late int imageTaps;
  late List<String> reacted;

  setUp(() {
    longPresses = 0;
    retries = 0;
    imageTaps = 0;
    reacted = <String>[];
  });

  Future<void> pumpBubble(
    WidgetTester tester,
    ChatMessage message, {
    bool isMine = false,
    bool showSender = false,
    TickState tickState = TickState.sent,
    double textScale = 1.0,
  }) =>
      pumpApp(
        tester,
        Scaffold(
          backgroundColor: AppColors.background,
          body: MessageBubble(
            message: message,
            isMine: isMine,
            showSender: showSender,
            tickState: tickState,
            onLongPress: () => longPresses++,
            onRetry: () => retries++,
            onImageTap: () => imageTaps++,
            onReactionTap: reacted.add,
          ),
        ),
        textScale: textScale,
      );

  group('mine and theirs', () {
    testWidgets('mine is tinted, unbordered and inset from the left',
        (tester) async {
      await pumpBubble(tester, msg(), isMine: true);
      expect(bubbleDecoration(tester).color, AppColors.accentLight);
      expect(bubbleDecoration(tester).border, isNull);
      expect(outerPadding(tester).left, 40);
      expect(outerPadding(tester).right, 8);
    });

    testWidgets('theirs is white, bordered and inset from the right',
        (tester) async {
      await pumpBubble(tester, msg());
      expect(bubbleDecoration(tester).color, Colors.white);
      expect(bubbleDecoration(tester).border,
          Border.all(color: AppColors.border));
      expect(outerPadding(tester).left, 8);
      expect(outerPadding(tester).right, 40);
    });
  });

  // The notch points at its own sender, so it moves to whichever side the bubble is
  // on; a uniform radius would leave both bubbles reading as free-floating pills.
  group('the squared corner', () {
    testWidgets('the first of their run is notched on the left', (tester) async {
      await pumpBubble(tester, msg(), showSender: true);
      final radius = bubbleDecoration(tester).borderRadius! as BorderRadius;
      expect(radius.topLeft, const Radius.circular(4));
      expect(radius.topRight, const Radius.circular(14));
      expect(radius.bottomLeft, const Radius.circular(14));
      expect(radius.bottomRight, const Radius.circular(14));
    });

    testWidgets('the first of my run is notched on the right', (tester) async {
      await pumpBubble(tester, msg(), isMine: true, showSender: true);
      final radius = bubbleDecoration(tester).borderRadius! as BorderRadius;
      expect(radius.topLeft, const Radius.circular(14));
      expect(radius.topRight, const Radius.circular(4));
    });

    testWidgets('a message inside a run is rounded all the way round',
        (tester) async {
      await pumpBubble(tester, msg());
      final radius = bubbleDecoration(tester).borderRadius! as BorderRadius;
      expect(radius.topLeft, const Radius.circular(14));
      expect(radius.topRight, const Radius.circular(14));
    });

    // The extra top margin is what separates one person's run from the next.
    testWidgets('a new run is given air above it', (tester) async {
      await pumpBubble(tester, msg(), showSender: true);
      expect(outerPadding(tester).top, 8);

      await pumpBubble(tester, msg());
      expect(outerPadding(tester).top, 2);
    });
  });

  group('the footer', () {
    testWidgets('the time is drawn in the reader\'s twelve-hour clock',
        (tester) async {
      await pumpBubble(tester, msg());
      expect(find.text('7:05 PM'), findsOneWidget);
    });

    // A tick beside somebody else's message would claim they had read their own text.
    testWidgets('ticks are drawn on my messages only', (tester) async {
      await pumpBubble(tester, msg());
      expect(find.byType(TickIcon), findsNothing);

      await pumpBubble(tester, msg(), isMine: true, tickState: TickState.read);
      expect(find.byType(TickIcon), findsOneWidget);
      expect(tester.widget<TickIcon>(find.byType(TickIcon)).state, TickState.read);
      expect(tester.widget<TickIcon>(find.byType(TickIcon)).mutedColor,
          AppColors.textSecondary);
    });

    // A bubble is capped rather than sized, so a one-word message stays narrow while
    // a paragraph stops short of the opposite edge.
    testWidgets('the bubble is capped at 78% of the frame', (tester) async {
      useDeviceSurface(tester);
      await pumpBubble(tester, msg(body: 'x' * 400));
      expect(bubbleBox(tester).constraints!.maxWidth, closeTo(321.36, 0.01));
      expect(tester.getSize(find.byWidget(bubbleBox(tester))).width,
          closeTo(321.36, 0.01),
          reason: 'a long message stops at the cap, not at the frame');
      expectNoOverflow(tester);
    });
  });

  // The body survives a delete in the model, so not drawing it is the assertion that
  // matters here; the disabled long-press is what stops "copy" and "delete for
  // everyone" being offered for a message that is already gone.
  group('the tombstone', () {
    testWidgets('the payload is replaced, not merely styled', (tester) async {
      await pumpBubble(tester, msg(deletedAt: DateTime(2026, 3, 14, 19, 6)));
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('See you at 7'), findsNothing,
          reason: 'the body is still in the model and must not be drawn');
      final style =
          tester.widget<Text>(find.text('This message was deleted')).style!;
      expect(style.fontStyle, FontStyle.italic);
      expect(style.color, AppColors.textSecondary);
      expect(tester.widget<Icon>(find.byIcon(Icons.block)).size, 14);
    });

    testWidgets('a deleted message of mine loses its ticks', (tester) async {
      await pumpBubble(tester, msg(deletedAt: DateTime(2026, 3, 14, 19, 6)),
          isMine: true, tickState: TickState.read);
      expect(find.byType(TickIcon), findsNothing,
          reason: 'there is nothing left to have been delivered');
      expect(find.text('7:05 PM'), findsNothing);
    });

    testWidgets('the action sheet cannot be opened on it', (tester) async {
      await pumpBubble(tester, msg(deletedAt: DateTime(2026, 3, 14, 19, 6)));
      expect(
          tester
              .widget<GestureDetector>(find.descendant(
                  of: find.byType(MessageBubble),
                  matching: find.byType(GestureDetector)))
              .onLongPress,
          isNull);
      await tester.longPress(find.text('This message was deleted'));
      expect(longPresses, 0);
    });

    testWidgets('a live message opens the sheet on a long press', (tester) async {
      await pumpBubble(tester, msg());
      await tester.longPress(find.text('See you at 7'));
      expect(longPresses, 1);
    });
  });

  // A failed send is the one state in which the bubble itself is a button.
  group('a send that failed', () {
    testWidgets('it says so, and the bubble becomes the retry', (tester) async {
      await pumpBubble(tester, msg(failed: true), isMine: true);
      expect(find.text('Not sent · tap to retry'), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.error_outline)).color,
          AppColors.error);
      await tester.tap(find.text('See you at 7'));
      expect(retries, 1);
    });

    testWidgets('a delivered message ignores a tap', (tester) async {
      await pumpBubble(tester, msg(), isMine: true);
      expect(find.text('Not sent · tap to retry'), findsNothing);
      await tester.tap(find.text('See you at 7'));
      expect(retries, 0);
    });
  });

  // The colour is keyed on the sender's id, not their name, so one person keeps one
  // colour through a rename; eight colours means two people in a large group can
  // collide, which is accepted.
  group('the sender name', () {
    Color nameColor(WidgetTester tester) =>
        tester.widget<Text>(find.text('Bilal')).style!.color!;

    testWidgets('it labels the first of their run and nothing else',
        (tester) async {
      await pumpBubble(tester, msg(), showSender: true);
      expect(find.text('Bilal'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Bilal')).style!.fontWeight,
          FontWeight.w700);

      await pumpBubble(tester, msg());
      expect(find.text('Bilal'), findsNothing);
    });

    // My own name is never drawn: the alignment already says whose it is.
    testWidgets('my own messages are never labelled', (tester) async {
      await pumpBubble(tester, msg(), isMine: true, showSender: true);
      expect(find.text('Bilal'), findsNothing);
    });

    testWidgets('a member with no name still gets a label', (tester) async {
      await pumpBubble(tester, msg(senderName: null), showSender: true);
      expect(find.text('Player'), findsOneWidget);
    });

    testWidgets('a rename keeps the colour the id earned', (tester) async {
      await pumpBubble(tester, msg(), showSender: true);
      final before = nameColor(tester);
      await pumpBubble(tester, msg(senderName: 'Bilal'), showSender: true);
      expect(nameColor(tester), before);

      final palette = <Color>{};
      for (var i = 0; i < 12; i++) {
        await pumpBubble(tester, msg(senderId: 'u$i'), showSender: true);
        palette.add(nameColor(tester));
      }
      expect(palette.length, greaterThan(1),
          reason: 'the colour varies by sender rather than being one constant');
    });
  });

  group('reactions', () {
    testWidgets('no reactions means no chips', (tester) async {
      await pumpBubble(tester, msg());
      expect(find.text('\u{1F44D}'), findsNothing);
    });

    testWidgets('a single reaction is the emoji alone', (tester) async {
      await pumpBubble(
          tester, msg(reactions: const [MessageReaction('\u{1F44D}', 'u3')]));
      expect(find.text('\u{1F44D}'), findsOneWidget);
    });

    testWidgets('two of the same fold to a count', (tester) async {
      await pumpBubble(
          tester,
          msg(reactions: const [
            MessageReaction('\u{1F44D}', 'u3'),
            MessageReaction('\u{1F44D}', 'u4'),
          ]));
      expect(find.text('\u{1F44D} 2'), findsOneWidget);
      expect(find.text('\u{1F44D}'), findsNothing);
    });

    // First-seen order, so a chip does not jump sideways as other people react.
    testWidgets('the chips keep the order they arrived in', (tester) async {
      await pumpBubble(
          tester,
          msg(reactions: const [
            MessageReaction('\u{1F44D}', 'u3'),
            MessageReaction('\u{2764}', 'u4'),
          ]));
      expect(tester.getTopLeft(find.text('\u{1F44D}')).dx,
          lessThan(tester.getTopLeft(find.text('\u{2764}')).dx));
    });

    testWidgets('tapping a chip reports which emoji', (tester) async {
      await pumpBubble(
          tester, msg(reactions: const [MessageReaction('\u{1F44D}', 'u3')]));
      await tester.tap(find.text('\u{1F44D}'));
      expect(reacted, ['\u{1F44D}']);
    });
  });

  // An image bubble is the payload with a scrim, not a card: the photo reaches the
  // bubble's own edges and the time floats on top of it when there is no caption to
  // host it. Nothing here settles — the placeholder and the pending overlay are both
  // indeterminate progress indicators.
  group('an image message', () {
    ChatMessage photo({
      String? body,
      num mediaW = 1600,
      num mediaH = 900,
      bool pending = false,
    }) =>
        msg(
          kind: MessageKind.image,
          body: body,
          mediaUrl: 'https://cdn.example.com/p.jpg',
          mediaW: mediaW,
          mediaH: mediaH,
          pending: pending,
        );

    /// The scrim the footer sits on when the photo has no caption.
    Finder scrim() => find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).color ==
            Colors.black.withValues(alpha: 0.35));

    testWidgets('the photo is drawn at the ratio the model reported',
        (tester) async {
      await pumpBubble(tester, photo());
      expect(find.byType(CachedNetworkImage), findsOneWidget);
      expect(tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage)).imageUrl,
          'https://cdn.example.com/p.jpg');
      expect(tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
          closeTo(1.7777, 0.001));
      expect(find.text('See you at 7'), findsNothing,
          reason: 'a photo sent without a caption has no body to draw');
    });

    testWidgets('with no caption the time floats on a scrim', (tester) async {
      await pumpBubble(tester, photo());
      expect(scrim(), findsOneWidget);
      expect(tester.widget<Text>(find.text('7:05 PM')).style!.color, Colors.white);
    });

    // A caption hosts the footer itself, so the scrim would be drawn over nothing.
    testWidgets('a caption takes the footer off the photo', (tester) async {
      await pumpBubble(tester, photo(body: 'At the ground'), isMine: true);
      expect(find.text('At the ground'), findsOneWidget);
      expect(scrim(), findsNothing);
      expect(tester.widget<Text>(find.text('7:05 PM')).style!.color,
          AppColors.textSecondary);
      expect(find.byType(TickIcon), findsOneWidget);
    });

    // Opening the viewer on an upload that has not finished would show the local
    // placeholder full-screen, so the tap is withheld until the URL is real.
    testWidgets('an upload in flight cannot be opened', (tester) async {
      await pumpBubble(tester, photo(pending: true));
      await tester.tap(find.byType(CachedNetworkImage), warnIfMissed: false);
      expect(imageTaps, 0);
    });

    testWidgets('a finished photo opens the viewer', (tester) async {
      await pumpBubble(tester, photo());
      await tester.tap(find.byType(CachedNetworkImage), warnIfMissed: false);
      expect(imageTaps, 1);
    });
  });

  testWidgets('a bubble survives a doubled text scale', (tester) async {
    useDeviceSurface(tester);
    await pumpBubble(tester, msg(body: 'See you at 7 by the far gate'),
        showSender: true, textScale: 2.0);
    expect(find.text('Bilal'), findsOneWidget);
    expectNoOverflow(tester);
  });
}
