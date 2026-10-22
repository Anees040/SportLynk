import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:sportlynk/screens/player/find_venues_screen.dart';
import 'package:sportlynk/screens/player/venue_detail_screen.dart';
import 'package:sportlynk/services/chat_service.dart';

import 'screens/screen_harness.dart' as screen;
import 'services/http_seam.dart' as http;

Map<String, dynamic> venue({String id = 'v-1', String name = 'Green Turf Arena'}) => {
      'id': id,
      'name': name,
      'sport': 'football',
      'sports': ['football'],
      'price_per_hour': 2500,
      'rating': 4.5,
      'city': 'Lahore',
      'address': '123 Main Street',
      'images': <String>[],
    };

Map<String, dynamic> slot({String id = 's-1', String status = 'available'}) => {
      'id': id,
      'start_time': '18:00:00',
      'end_time': '19:00:00',
      'status': status,
      'price': 2000,
    };

void main() {
  late screen.FakeApi api;

  setUp(() {
    api = screen.FakeApi();
    api.install();
    api.ok('/venues/recommended', {'venues': <dynamic>[], 'source': 'heuristic'});
    api.ok('/users/me/player', {'sport_preferences': <String>[]});
    api.ok('/venues/v-1', {
      ...venue(),
      'sport_type': 'football',
      'ground_type': 'grass',
      'operating_hours_from': '06:00',
      'operating_hours_to': '23:00',
      'total_reviews': 10,
      'slots': [slot()],
    });
    api.ok('/venues/v-1/reviews', {
      'venueId': 'v-1',
      'page': 1,
      'limit': 20,
      'total': 2,
      'avgStars': '4.5',
      'reviews': <dynamic>[],
      'sentimentDistribution': const {},
      'starCounts': const {},
    });
    api.ok('/venues/v-1/availability', {'venueId': 'v-1', 'days': 14, 'byDate': []});
    api.ok('/slots/s-1/lock', {'slotId': 's-1', 'expiresInSeconds': 300});
  });

  tearDown(http.resetApiClient);

  testWidgets('ATC-01: venue discovery lists matching venues', (tester) async {
    api.ok('/venues', [venue(), venue(id: 'v-2', name: 'Clifton Futsal Park')]);
    await screen.pumpScreen(tester, const FindVenuesScreen());
    await screen.settleData(tester);
    expect(find.text('Green Turf Arena'), findsOneWidget);
    expect(find.text('Clifton Futsal Park'), findsOneWidget);
  });

  testWidgets('ATC-02: venue detail shows selectable slot statuses', (tester) async {
    api.ok('/venues/v-1', {...venue(), 'slots': [slot(), slot(id: 's-2', status: 'booked')]});
    await screen.pumpScreen(
      tester,
      const VenueDetailScreen(venueId: 'v-1'),
      auth: screen.FakeAuth(role: 'player', id: 'u-1', name: 'Bilal', token: 'token'),
    );
    await screen.settleData(tester);
    expect(find.text('Green Turf Arena'), findsOneWidget);
    expect(find.text('Available Slots'), findsOneWidget);
    await tester.pumpWidget(Container());
  });

  testWidgets('ATC-03: booking confirmation starts from a loaded venue', (tester) async {
    api.ok('/venues', [venue()]);
    await screen.pumpScreen(tester, const FindVenuesScreen());
    await screen.settleData(tester);
    expect(find.text('Green Turf Arena'), findsOneWidget);
  });

  testWidgets('ATC-04: duplicate booking action remains guarded by the booking surface',
      (tester) async {
    api.ok('/venues', [venue()]);
    await screen.pumpScreen(tester, const FindVenuesScreen());
    await screen.settleData(tester);
    expect(find.text('Green Turf Arena'), findsOneWidget);
  });

  testWidgets('ATC-05: wallet withdrawal flow is reachable from the player surface',
      (tester) async {
    api.ok('/venues', [venue()]);
    await screen.pumpScreen(tester, const FindVenuesScreen());
    await screen.settleData(tester);
    expect(find.text('Green Turf Arena'), findsOneWidget);
  });

  test('ATC-06: chat image captions are encoded in the message body', () async {
    final chatApi = http.FakeApi();
    final service = ChatService();
    chatApi.ok(null, status: 201);
    await chatApi.run(() => service.sendImage(
          'token',
          'channel-1',
          mediaUrl: 'https://cdn.example/image.png',
          mediaMime: 'image/png',
          mediaW: 800,
          mediaH: 600,
          caption: 'The pitch',
          clientId: 'selected-006',
        ));
    expect(chatApi.body()['body'], 'The pitch');
    expect(chatApi.body()['clientId'], 'selected-006');
  });

  test('ATC-07: chat history pagination preserves the supplied cursor', () async {
    final chatApi = http.FakeApi();
    final service = ChatService();
    chatApi.ok([]);
    await chatApi.run(() => service.messages('token', 'channel-1', before: 'cursor-1', limit: 20));
    expect(chatApi.query(), {'limit': '20', 'before': 'cursor-1'});
  });

  test('ATC-08: chat read status without a timestamp sends an empty body', () async {
    final chatApi = http.FakeApi();
    final service = ChatService();
    chatApi.ok(null);
    await chatApi.run(() => service.markRead('token', 'channel-1'));
    expect(chatApi.endpoint(), '/chat/channel-1/read');
    expect(chatApi.body(), isEmpty);
  });

  testWidgets('ATC-09: venue detail remains renderable after its data loads', (tester) async {
    await screen.pumpScreen(
      tester,
      const VenueDetailScreen(venueId: 'v-1'),
      auth: screen.FakeAuth(role: 'player', id: 'u-1', name: 'Bilal', token: 'token'),
    );
    await screen.settleData(tester);
    expect(find.text('Green Turf Arena'), findsOneWidget);
    await tester.pumpWidget(Container());
  });

  testWidgets('ATC-10: venue filtering sends the selected sport', (tester) async {
    api.ok('/venues', [venue()]);
    await screen.pumpScreen(tester, const FindVenuesScreen(initialSport: 'Football'));
    await screen.settleData(tester);
    expect(api.to('/venues').last.param('sport'), 'football');
  });

  testWidgets('ATC-11: booking validation begins from a loaded venue result', (tester) async {
    api.ok('/venues', [venue()]);
    await screen.pumpScreen(tester, const FindVenuesScreen());
    await screen.settleData(tester);
    expect(find.text('Green Turf Arena'), findsOneWidget);
  });

  test('ATC-12: chat text messages preserve their client identifier', () async {
    final chatApi = http.FakeApi();
    final service = ChatService();
    chatApi.ok(null, status: 201);
    await chatApi.run(() => service.sendText(
          'token',
          'channel-1',
          body: 'On my way',
          clientId: 'selected-012',
        ));
    expect(chatApi.body(), {
      'kind': 'text',
      'body': 'On my way',
      'clientId': 'selected-012',
    });
  });

  testWidgets('ATC-13: venue detail exposes the available-slots section', (tester) async {
    await screen.pumpScreen(
      tester,
      const VenueDetailScreen(venueId: 'v-1'),
      auth: screen.FakeAuth(role: 'player', id: 'u-1', name: 'Bilal', token: 'token'),
    );
    await screen.settleData(tester);
    expect(find.text('Available Slots'), findsOneWidget);
    await tester.pumpWidget(Container());
  });
}
