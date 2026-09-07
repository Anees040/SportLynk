import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sportlynk/constants/colors.dart';
import 'package:sportlynk/models/app_notification.dart';
import 'package:sportlynk/providers/notification_provider.dart';
import 'package:sportlynk/screens/shared/notification_prefs_screen.dart';
import 'package:sportlynk/screens/shared/notifications_screen.dart';
import 'package:sportlynk/utils/deep_link.dart';

import '../screen_harness.dart';

/// What this pins about the notification feed.
///
/// The screen renders provider state and delegates every action back to it, so the
/// contracts worth holding are which state produces which surface and which control
/// calls which method:
///
/// 1. The session is attached before the feed is fetched (`:53`). A badge that only
///    moves while the list is open is not a badge, so the socket is opened here and
///    not by the provider's first read.
/// 2. A category chip is drawn only when it has rows or is the current filter
///    (`:167`), because nine chips on a fresh account say nothing.
/// 3. A tap on the selected chip sends that same category again (`:196`). Clearing
///    the filter is `setCategory`'s rule, not the row's.
/// 4. A tap marks the row read whether or not it has somewhere to go (`:82`). "I read
///    it" is a fact about the user, not about whether the app had a screen to show.
/// 5. An expired row keeps its link and must not follow it (`:86`); it says so
///    instead, because a tap that produces nothing is the worst possible answer.
///
/// The provider's own HTTP path is not exercised here, for the reason given on
/// [_Feed].

/// The feed, without the socket.
///
/// `NotificationProvider.attach` calls `RealtimeService().ensureConnected`, which
/// opens a socket.io connection and registers its twenty-second connect timeout as a
/// `Timer` synchronously. `flutter_test` asserts that no timer is pending before it
/// runs tear-downs, so a screen driven by the real provider fails on the socket
/// rather than on its own subject and no tear-down can rescue it. Every public member
/// the screen reads is overridden here instead, and each call is recorded: what these
/// tests assert is the screen's half of the contract.
class _Feed extends NotificationProvider {
  _Feed({
    this.feed = const <AppNotification>[],
    this.loading = false,
    this.failure,
    this.more = false,
    this.unreadCount = 0,
    this.counts = const <String, int>{},
    this.selected,
    this.unreadFilter = false,
  });

  List<AppNotification> feed;
  bool loading;
  String? failure;
  bool more;
  int unreadCount;
  Map<String, int> counts;
  String? selected;
  bool unreadFilter;

  /// Every provider call the screen made, in order.
  final List<String> calls = <String>[];

  int callsTo(String name) => calls.where((c) => c == name).length;

  @override
  List<AppNotification> get items => List.unmodifiable(feed);

  @override
  bool get isLoading => loading;

  @override
  String? get error => failure;

  @override
  bool get hasMore => more;

  @override
  int get unread => unreadCount;

  @override
  Map<String, int> get byCategory => counts;

  @override
  String? get category => selected;

  @override
  bool get unreadOnly => unreadFilter;

  @override
  bool get pushConfigured => true;

  @override
  void attach(String? token) => calls.add('attach:$token');

  @override
  Future<void> refresh() async => calls.add('refresh');

  @override
  Future<void> refreshSummary() async => calls.add('summary');

  @override
  Future<void> loadMore() async => calls.add('loadMore');

  @override
  Future<void> setCategory(String? c) async => calls.add('category:$c');

  @override
  Future<void> setUnreadOnly(bool v) async => calls.add('unreadOnly:$v');

  @override
  Future<void> markRead(AppNotification n) async => calls.add('read:${n.id}');

  @override
  Future<void> markUnread(AppNotification n) async => calls.add('unread:${n.id}');

  @override
  Future<void> markAllRead() async => calls.add('readAll');

  @override
  Future<void> dismiss(AppNotification n) async => calls.add('dismiss:${n.id}');

  @override
  Future<void> clearRead() async => calls.add('clearRead');
}

/// One feed row, parsed the way the endpoint delivers it.
AppNotification notif({
  String id = 'n-1',
  String category = 'booking',
  String priority = 'normal',
  String icon = 'event_available',
  String title = 'Booking confirmed',
  String body = 'Green Turf, seven to eight',
  Map<String, dynamic>? deepLink,
  String? actorName,
  String? avatarUrl,
  int groupCount = 1,
  bool isRead = false,
  bool isExpired = false,
  Duration age = const Duration(minutes: 5),
}) =>
    AppNotification.fromJson(<String, dynamic>{
      'id': id,
      'type': 'booking_confirmed',
      'category': category,
      'priority': priority,
      'icon': icon,
      'title': title,
      'body': body,
      'deepLink': deepLink,
      'groupCount': groupCount,
      'isRead': isRead,
      'isExpired': isExpired,
      'createdAt': DateTime.now().toUtc().subtract(age).toIso8601String(),
      if (actorName != null)
        'actor': <String, dynamic>{
          'id': 'u-9',
          'name': actorName,
          'avatarUrl': avatarUrl,
        },
    });

/// [count] rows, newest first, each with its own id so `Dismissible` keys stay
/// unique and a page-two request can be told apart from a reload.
List<AppNotification> feedOf(int count) => List<AppNotification>.generate(
      count,
      (i) => notif(id: 'n-$i', title: 'Row $i', body: 'Body $i'),
    );

/// The unread marker: an eight-pixel accent circle, the one thing on the row that
/// says a notification has not been read yet.
Finder unreadDot() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration ==
              const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
    );

/// The row's own [Material], whose colour carries the read state.
Finder rowSurface() => find
    .descendant(of: find.byType(Dismissible), matching: find.byType(Material))
    .first;

Future<RouteLog> pumpFeed(
  WidgetTester tester,
  _Feed feed, {
  FakeAuth? auth,
  double textScale = 1.0,
  bool followLinks = false,
}) async {
  final log = await pumpScreen(
    tester,
    const NotificationsScreen(),
    auth: auth,
    providers: [ChangeNotifierProvider<NotificationProvider>.value(value: feed)],
    textScale: textScale,
    // A notification tap navigates through `DeepLink.navigatorKey`, and a key that
    // resolves to null parks the link instead of following it, which is
    // indistinguishable from a tap that did nothing. Only the tests that assert
    // where a row leads carry it, so the rest keep the global key out of their tree.
    navigatorKey: followLinks ? DeepLink.navigatorKey : null,
  );
  return log;
}

/// Opens the app bar's overflow menu.
Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('on the first frame', () {
    testWidgets('attaches the session before it fetches', (tester) async {
      final feed = _Feed();

      await pumpFeed(tester, feed);

      expect(feed.calls, <String>['attach:test-token', 'refresh']);
    });

    // The screen does not decide what a missing token means: it hands over whatever
    // the session holds, and `attach` treats null as a detach. A screen that
    // suppressed the call would leave the previous user's rows on screen after a
    // logout that happened while the feed was open.
    testWidgets('hands over a missing token rather than skipping the attach',
        (tester) async {
      final feed = _Feed();

      await pumpFeed(tester, feed, auth: FakeAuth(token: null));

      expect(feed.calls, <String>['attach:null', 'refresh']);
    });
  });

  group('while the feed is being fetched', () {
    testWidgets('shows a spinner over an empty feed', (tester) async {
      await pumpFeed(tester, _Feed(loading: true));

      expectLoading(tester);
      expect(find.byType(ListView), findsNothing);
    });

    // A reload replaces the rows when it lands, not when it starts. Swapping the list
    // for a spinner on every pull would make a refresh look like a page load.
    testWidgets('keeps the rows visible while it reloads', (tester) async {
      await pumpFeed(tester, _Feed(loading: true, feed: feedOf(3)));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Row 0'), findsOneWidget);
    });
  });

  group('when there is nothing to show', () {
    testWidgets('says so on a fresh account', (tester) async {
      await pumpFeed(tester, _Feed());

      expect(find.text('No notifications yet.'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none), findsOneWidget);
    });

    // An empty feed under a filter is not an empty account, and telling the user they
    // have no notifications while a chip is hiding nine of them is a lie the chip row
    // makes easy to walk into.
    testWidgets('names the filter rather than the account', (tester) async {
      await pumpFeed(tester, _Feed(selected: 'wallet'));

      expect(find.text('Nothing here with this filter.'), findsOneWidget);
      expect(find.text('No notifications yet.'), findsNothing);
    });

    testWidgets('names the filter when only unread rows are shown', (tester) async {
      await pumpFeed(tester, _Feed(unreadFilter: true));

      expect(find.text('Nothing here with this filter.'), findsOneWidget);
    });

    testWidgets('shows the failure instead of the empty line', (tester) async {
      await pumpFeed(tester, _Feed(failure: 'Could not load notifications'));

      expect(find.text('Could not load notifications'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.text('No notifications yet.'), findsNothing);
    });

    // Pinned as it behaves, not as it should.
    // `lib/screens/shared/notifications_screen.dart:208` draws the failure as an icon
    // and a sentence with no control beside it. The only way back is a pull, which is
    // invisible: nothing on screen suggests the list can be dragged, and the sentence
    // does not say so either. A `TextButton('Retry')` under the message, calling the
    // same `p.refresh`, is the fix.
    testWidgets('offers no retry button when the fetch failed', (tester) async {
      await pumpFeed(tester, _Feed(failure: 'Could not load notifications'));

      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });
  });

  group('the filter chips', () {
    testWidgets('draws nothing on a fresh account', (tester) async {
      await pumpFeed(tester, _Feed());

      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('draws only the categories that have rows', (tester) async {
      await pumpFeed(
        tester,
        _Feed(counts: const {'booking': 2, 'chat': 1}),
      );

      expect(find.byType(FilterChip), findsNWidgets(2));
      expect(find.text('Bookings 2'), findsOneWidget);
      expect(find.text('Chat 1'), findsOneWidget);
    });

    // The chip the user is filtering by has to stay reachable, or the only way out of
    // an empty filtered feed is the app bar's unrelated toggle.
    testWidgets('keeps the selected chip when its count is zero', (tester) async {
      await pumpFeed(
        tester,
        _Feed(counts: const {'booking': 2}, selected: 'wallet'),
      );

      expect(find.byType(FilterChip), findsNWidgets(2));
      expect(find.text('Wallet'), findsOneWidget);
    });

    // The order is the registry's, not the map's: `byCategory` arrives as JSON and its
    // key order is whatever the server serialised, so a row of chips that reflowed
    // between two refreshes would move the target out from under a thumb already on
    // its way down.
    testWidgets('draws them in the registry order, not the response order',
        (tester) async {
      await pumpFeed(
        tester,
        _Feed(counts: const {'wallet': 3, 'booking': 2, 'chat': 1}),
      );

      final booking = tester.getTopLeft(find.text('Bookings 2')).dx;
      final chat = tester.getTopLeft(find.text('Chat 1')).dx;
      final wallet = tester.getTopLeft(find.text('Wallet 3')).dx;
      expect(booking, lessThan(chat));
      expect(chat, lessThan(wallet));
    });

    testWidgets('shows the chip selected when it is the filter', (tester) async {
      await pumpFeed(
        tester,
        _Feed(counts: const {'booking': 2, 'chat': 1}, selected: 'chat'),
      );

      final chips = tester.widgetList<FilterChip>(find.byType(FilterChip)).toList();
      expect(chips.first.selected, isFalse);
      expect(chips.last.selected, isTrue);
    });

    testWidgets('a tap sends the category to the provider', (tester) async {
      final feed = _Feed(counts: const {'booking': 2, 'chat': 1});
      await pumpFeed(tester, feed);

      await tester.tap(find.text('Chat 1'));
      await tester.pump();

      expect(feed.calls, contains('category:chat'));
    });

    // Tapping the chip that is already on sends the same category again rather than
    // null. `setCategory` reads a repeat as "off", and duplicating that rule here is
    // how the chip row and the feed start disagreeing about what is filtered.
    testWidgets('a tap on the selected chip sends it again', (tester) async {
      final feed = _Feed(counts: const {'booking': 2}, selected: 'booking');
      await pumpFeed(tester, feed);

      await tester.tap(find.text('Bookings 2'));
      await tester.pump();

      expect(feed.calls, contains('category:booking'));
    });
  });

  group('the unread filter', () {
    testWidgets('offers to hide the read rows', (tester) async {
      await pumpFeed(tester, _Feed());

      expect(find.byTooltip('Unread only'), findsOneWidget);
      expect(find.byIcon(Icons.filter_alt_outlined), findsOneWidget);
    });

    testWidgets('offers to show them again once it is on', (tester) async {
      await pumpFeed(tester, _Feed(unreadFilter: true));

      expect(find.byTooltip('Show all'), findsOneWidget);
      expect(find.byIcon(Icons.filter_alt), findsOneWidget);
    });

    testWidgets('a tap turns it on', (tester) async {
      final feed = _Feed();
      await pumpFeed(tester, feed);

      await tester.tap(find.byTooltip('Unread only'));
      await tester.pump();

      expect(feed.calls, contains('unreadOnly:true'));
    });

    testWidgets('a tap turns it back off', (tester) async {
      final feed = _Feed(unreadFilter: true);
      await pumpFeed(tester, feed);

      await tester.tap(find.byTooltip('Show all'));
      await tester.pump();

      expect(feed.calls, contains('unreadOnly:false'));
    });
  });

  group('mark all read', () {
    // Disabled rather than hidden: a control that vanishes when there is nothing to do
    // moves the two buttons beside it, and the row of actions must not reflow.
    testWidgets('is disabled with nothing unread', (tester) async {
      await pumpFeed(tester, _Feed(feed: feedOf(2)));

      final button =
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.done_all));
      expect(button.onPressed, isNull);
    });

    testWidgets('is enabled while something is unread', (tester) async {
      await pumpFeed(tester, _Feed(feed: feedOf(2), unreadCount: 2));

      final button =
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.done_all));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a tap marks everything read', (tester) async {
      final feed = _Feed(feed: feedOf(2), unreadCount: 2);
      await pumpFeed(tester, feed);

      await tester.tap(find.byTooltip('Mark all read'));
      await tester.pump();

      expect(feed.calls, contains('readAll'));
    });
  });

  group('the overflow menu', () {
    testWidgets('offers the settings and the clear', (tester) async {
      await pumpFeed(tester, _Feed());

      await openMenu(tester);

      expect(find.text('Notification settings'), findsOneWidget);
      expect(find.text('Clear read'), findsOneWidget);
    });

    testWidgets('the settings item opens the preferences screen', (tester) async {
      // The preferences screen fetches on mount and overflows its own category row
      // under the test font; both are its own file's subject, not this one's.
      final api = FakeApi()
        ..ok('/notifications/preferences', <String, Object?>{
          'prefs': <String, Object?>{
            'muteAll': false,
            'push': <String, bool>{},
            'inApp': <String, bool>{},
            'quietHours': <String, Object?>{
              'enabled': false,
              'start': '22:00',
              'end': '07:00',
            },
          },
          'categories': <String>['booking'],
          'unmutable': <String>['system'],
        });
      api.install();
      ignoreOverflow();
      await pumpFeed(tester, _Feed());

      await openMenu(tester);
      await tester.tap(find.text('Notification settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(NotificationPrefsScreen), findsOneWidget);
    });

    // A delete is worth a confirmation, and the wording carries the two facts that
    // decide whether the answer is yes: unread rows are kept, and so is anything from
    // the last hour.
    testWidgets('the clear item asks first', (tester) async {
      final feed = _Feed(feed: feedOf(2));
      await pumpFeed(tester, feed);

      await openMenu(tester);
      await tester.tap(find.text('Clear read'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Clear read notifications?'), findsOneWidget);
      expect(
        find.text(
          'Read notifications older than an hour will be deleted. '
          'Anything unread is kept.',
        ),
        findsOneWidget,
      );
      expect(feed.calls, isNot(contains('clearRead')));
    });

    testWidgets('cancelling clears nothing', (tester) async {
      final feed = _Feed(feed: feedOf(2));
      await pumpFeed(tester, feed);

      await openMenu(tester);
      await tester.tap(find.text('Clear read'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Clear read notifications?'), findsNothing);
      expect(feed.calls, isNot(contains('clearRead')));
    });

    testWidgets('confirming clears the read rows', (tester) async {
      final feed = _Feed(feed: feedOf(2));
      await pumpFeed(tester, feed);

      await openMenu(tester);
      await tester.tap(find.text('Clear read'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Clear'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(feed.calls, contains('clearRead'));
    });
  });

  group('a row', () {
    testWidgets('shows the title, the body and the age', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif()]));

      expect(find.text('Booking confirmed'), findsOneWidget);
      expect(find.text('Green Turf, seven to eight'), findsOneWidget);
      expect(find.text('5m'), findsOneWidget);
    });

    testWidgets('marks an unread row with a dot', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif()]));

      expect(unreadDot(), findsOneWidget);
    });

    testWidgets('leaves a read row without one', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif(isRead: true)]));

      expect(unreadDot(), findsNothing);
    });

    testWidgets('tints an unread row', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif()]));

      expect(
        tester.widget<Material>(rowSurface()).color,
        AppColors.accentLight.withValues(alpha: 0.35),
      );
    });

    testWidgets('leaves a read row on the card colour', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif(isRead: true)]));

      expect(tester.widget<Material>(rowSurface()).color, AppColors.cardBg);
    });

    // The server has already rewritten the body to "3 new messages"; the badge says
    // which fact was collapsed so the row does not look like it lost two of them.
    testWidgets('says how many events a grouped row collapses', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif(groupCount: 3)]));

      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('shows no count on a row that groups nothing', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif()]));

      expect(find.text('1'), findsNothing);
    });

    testWidgets('draws the actor initials where there is a person behind it',
        (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif(actorName: 'Ali Raza')]));

      expect(find.text('AR'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
    });

    testWidgets('draws the registry icon where there is not', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif()]));

      expect(find.byIcon(Icons.event_available), findsOneWidget);
      expect(find.byType(CircleAvatar), findsNothing);
    });

    // A type shipped after this build renders a bell rather than throwing: the icon
    // registry lives on the server and the client is always one release behind it.
    testWidgets('falls back to a bell for an icon name it does not know',
        (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif(icon: 'a_name_from_a_later_release')]));

      expect(find.byIcon(Icons.notifications), findsOneWidget);
    });

    testWidgets('labels an expired row', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif(isExpired: true)]));

      expect(find.text('Expired'), findsOneWidget);
    });
  });

  group('tapping a row', () {
    testWidgets('marks it read and follows its link', (tester) async {
      final feed = _Feed(
        feed: [
          notif(deepLink: const {
            'route': '/chat-thread',
            'args': {'channelId': 'c-9'},
          }),
        ],
      );
      final log = await pumpFeed(tester, feed, followLinks: true);
      addTearDown(DeepLink.clear);

      await tester.tap(find.text('Booking confirmed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(feed.calls.sublist(2), <String>['read:n-1', 'summary']);
      expect(log.sawRoute('/chat-thread'), isTrue);
      expect(log.argumentsFor('/chat-thread'), <String, dynamic>{'channelId': 'c-9'});
    });

    // A `deep_link` column written months ago by a build whose route has since been
    // renamed must land on the feed, not on an unhandled-route crash.
    testWidgets('sends an unknown route to the feed rather than nowhere',
        (tester) async {
      final feed = _Feed(
        feed: [notif(deepLink: const {'route': '/a-screen-that-was-renamed'})],
      );
      final log = await pumpFeed(tester, feed, followLinks: true);
      addTearDown(DeepLink.clear);

      await tester.tap(find.text('Booking confirmed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/notifications'), isTrue);
      expect(log.sawRoute('/a-screen-that-was-renamed'), isFalse);
    });

    testWidgets('says so when the row has expired', (tester) async {
      final feed = _Feed(
        feed: [
          notif(
            isExpired: true,
            deepLink: const {'route': '/match-center', 'args': {}},
          ),
        ],
      );
      final log = await pumpFeed(tester, feed, followLinks: true);
      addTearDown(DeepLink.clear);

      await tester.tap(find.text('Booking confirmed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('This one has expired.'), findsOneWidget);
      expect(feed.calls, contains('read:n-1'));
      expect(log.isEmpty, isTrue);
      // The snack bar holds a four-second timer, and a timer still pending when the
      // tree is disposed fails the test on the notice rather than on its subject.
      await tester.pump(const Duration(seconds: 5));
    });

    // Read-marking is not conditional on there being somewhere to go: a suspension
    // notice with no link that stayed unread would keep the badge lit for good.
    testWidgets('marks a row with nowhere to go read anyway', (tester) async {
      final feed = _Feed(feed: [notif()]);
      final log = await pumpFeed(tester, feed, followLinks: true);
      addTearDown(DeepLink.clear);

      await tester.tap(find.text('Booking confirmed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(feed.calls, contains('read:n-1'));
      expect(find.text('This one has expired.'), findsNothing);
      expect(log.isEmpty, isTrue);
    });

    testWidgets('a long press marks an unread row read', (tester) async {
      final feed = _Feed(feed: [notif()]);
      await pumpFeed(tester, feed);

      await tester.longPress(find.text('Booking confirmed'));
      await tester.pump();

      expect(feed.calls, contains('read:n-1'));
    });

    testWidgets('a long press marks a read row unread', (tester) async {
      final feed = _Feed(feed: [notif(isRead: true)]);
      await pumpFeed(tester, feed);

      await tester.longPress(find.text('Booking confirmed'));
      await tester.pump();

      expect(feed.calls, contains('unread:n-1'));
    });
  });

  group('dismissing a row', () {
    testWidgets('a swipe towards the start dismisses it', (tester) async {
      final feed = _Feed(feed: [notif()]);
      await pumpFeed(tester, feed);

      await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(feed.calls, contains('dismiss:n-1'));
    });

    // One direction only. A row that could be swiped either way would be deleted by
    // the gesture the user makes to go back.
    testWidgets('a swipe the other way does nothing', (tester) async {
      final feed = _Feed(feed: [notif()]);
      await pumpFeed(tester, feed);

      await tester.drag(find.byType(Dismissible), const Offset(500, 0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(feed.calls, isNot(contains('dismiss:n-1')));
      expect(find.text('Booking confirmed'), findsOneWidget);
    });
  });

  group('paging', () {
    testWidgets('adds a spinner row while there is more to fetch', (tester) async {
      await pumpFeed(tester, _Feed(feed: feedOf(3), more: true));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows no spinner row at the end of the feed', (tester) async {
      await pumpFeed(tester, _Feed(feed: feedOf(3)));

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('fetches the next page as the end comes into view', (tester) async {
      final feed = _Feed(feed: feedOf(20), more: true);
      await pumpFeed(tester, feed);

      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pump();

      expect(feed.calls, contains('loadMore'));
    });

    testWidgets('does not fetch a page before the end is near', (tester) async {
      final feed = _Feed(feed: feedOf(20), more: true);
      await pumpFeed(tester, feed);

      await tester.drag(find.byType(ListView), const Offset(0, -40));
      await tester.pump();

      expect(feed.calls, isNot(contains('loadMore')));
    });

    testWidgets('a pull reloads the feed', (tester) async {
      final feed = _Feed(feed: feedOf(20));
      await pumpFeed(tester, feed);

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(feed.callsTo('refresh'), 2);
    });
  });

  group('reach and scale', () {
    // Measured on the `IconButton` and not on the `Tooltip` inside it: an app bar
    // button paints a forty-pixel box and is padded out to the interactive floor by
    // `_InputPadding`, which sits above the tooltip in the tree.
    testWidgets('the filter button is big enough to hit', (tester) async {
      await pumpFeed(tester, _Feed());

      expectTapTarget(
        tester,
        find.widgetWithIcon(IconButton, Icons.filter_alt_outlined),
      );
    });

    testWidgets('the mark-all-read button is big enough to hit', (tester) async {
      await pumpFeed(tester, _Feed(feed: feedOf(2), unreadCount: 2));

      expectTapTarget(tester, find.widgetWithIcon(IconButton, Icons.done_all));
    });

    testWidgets('a row is big enough to hit', (tester) async {
      await pumpFeed(tester, _Feed(feed: [notif()]));

      expectTapTarget(tester, find.byType(Dismissible));
    });

    // The rows carry a title and a two-line body, both ellipsised, so a doubled scale
    // costs lines rather than content. Overflow reports are ignored here on purpose:
    // `flutter_test` substitutes a font whose glyphs are square ems, roughly twice the
    // width of the Poppins the screen asks for, so a width measured at this scale is
    // the font's and not the phone's. What is asserted is that the row is still there
    // and still says what it is.
    testWidgets('keeps the rows readable at a doubled text scale', (tester) async {
      ignoreOverflow();

      await pumpFeed(tester, _Feed(feed: [notif()]), textScale: 2.0);

      expect(find.text('Booking confirmed'), findsOneWidget);
      expect(find.byTooltip('Unread only'), findsOneWidget);
    });
  });
}
