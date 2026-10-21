import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/mobile_scanner_view_attributes.dart';
import 'package:mobile_scanner/src/objects/start_options.dart';
import 'package:sportlynk/screens/owner/owner_booking_requests_screen.dart';
import 'package:sportlynk/screens/owner/owner_qr_scanner_screen.dart';
import 'package:sportlynk/screens/owner/owner_venue_management_screen.dart';
import 'package:sportlynk/screens/player/confirm_booking_screen.dart';
import 'package:sportlynk/screens/player/player_booking_detail_screen.dart';
import 'package:sportlynk/screens/player/player_profile_screen.dart';
import 'package:sportlynk/screens/player/trust_score_screen.dart';
import 'package:sportlynk/screens/shared/public_profile_screen.dart';
import 'package:sportlynk/services/realtime_service.dart';
import 'package:sportlynk/widgets/trust_widgets.dart';

import 'screen_harness.dart';

const bookingId = '11111111-1111-4111-8111-111111111111';
const bookingPath = '/bookings/$bookingId';

class _Camera extends MobileScannerPlatform {
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async =>
      const MobileScannerViewAttributes(currentTorchMode: TorchState.off, size: Size(640, 480));
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
}

Map<String, dynamic> booking({String status = 'confirmed'}) => {
  'id': bookingId, 'status': status, 'venue_name': 'Ground',
  'slot_date': '2026-10-21', 'start_time': '18:00:00', 'end_time': '19:00:00',
  'security_deposit': '2000.00', 'total_amount': '2000.00', 'deposit_amount': '800.00',
};

Map<String, dynamic> trust(int score) => {
  'userId': 'player', 'trust': {'score': score, 'attendance': 0.8,
    'attendanceRate': 0.5, 'checkedIn': 1, 'noShows': 1}, 'reviews': [],
};

Future<void> mount(WidgetTester tester, Widget screen, {String role = 'player'}) async {
  await pumpScreen(tester, screen,
    auth: FakeAuth(role: role, id: role, name: 'Ali', token: 'test-token'));
  await settleData(tester);
}

void main() {
  late FakeApi api;
  setUp(() { api = FakeApi()..install(); });

  testWidgets('manual check-in sends the short code and renders string balances without a red screen', (tester) async {
    final previous = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = _Camera();
    addTearDown(() => MobileScannerPlatform.instance = previous);
    api.ok('/owner/scan-qr', {'playerName': 'Ali', 'venueName': 'Ground',
      'slotDate': '2026-10-21', 'startTime': '18:00:00', 'endTime': '19:00:00',
      'slotCount': '2', 'amount': '2000.00', 'netToOwner': '1800.00', 'newOwnerBalance': '12000.00'});
    await mount(tester, const OwnerQrScannerScreen(), role: 'owner');
    await tester.tap(find.text('Or enter Booking ID manually'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'BK00012A');
    await tester.tap(find.text('Verify'));
    await settleData(tester);
    expect(jsonDecode(api.to('/owner/scan-qr').single.body!), {'bookingId': 'BK00012A'});
    expect(find.text('Check-in Successful!'), findsOneWidget);
    expect(find.text('PKR 12000'), findsOneWidget);
    expect(find.text('PKR 1800'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the short booking code is shown and copied instead of the UUID', (tester) async {
    api.ok(bookingPath, {...booking(), 'checkin_code': 'BK00012A'});
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await mount(tester, const PlayerBookingDetailScreen(bookingId: bookingId));
    expect(find.text('BK00012A'), findsOneWidget);
    expect(find.text(bookingId), findsNothing);
    await tester.ensureVisible(find.text('Copy booking ID'));
    await tester.tap(find.text('Copy booking ID'));
    await tester.pump();
    expect(copied, 'BK00012A');
  });

  testWidgets('the full manual ID is available even when the QR payload is missing', (tester) async {
    api.ok(bookingPath, booking());
    await mount(tester, const PlayerBookingDetailScreen(bookingId: bookingId));
    expect(find.text('Manual Booking ID'), findsOneWidget);
    expect(find.text(bookingId), findsOneWidget);
    expect(find.text('Copy booking ID'), findsOneWidget);
  });

  testWidgets('cancellation and no-show wording uses the deposit agreed at booking', (tester) async {
    api.ok(bookingPath, booking());
    await mount(tester, const PlayerBookingDetailScreen(bookingId: bookingId));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('you get 60% back and the 40% deposit'), findsOneWidget);
    await tester.tap(find.text('Keep Booking'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    api.ok(bookingPath, booking(status: 'no_show'));
    await mount(tester, const PlayerBookingDetailScreen(bookingId: bookingId));
    expect(find.text('40% deposit forfeited, 60% refunded'), findsOneWidget);
  });

  testWidgets('checkout displays a decimal venue deposit and its amount', (tester) async {
    api.ok('/wallet/me', {'balance': 10000, 'frozen_balance': 0});
    await mount(tester, ConfirmBookingScreen(
      venue: const {'id': 'venue', 'name': 'Ground', 'effective_deposit_pct': '35.5'},
      slot: const {'id': 'slot', 'price': 2000, 'start_time': '18:00:00', 'end_time': '19:00:00'},
      selectedDate: DateTime(2026, 10, 21),
    ));
    expect(find.text('At-risk deposit (35.5%)'), findsOneWidget);
    expect(find.text('PKR 710'), findsOneWidget);
  });

  testWidgets('trust updates refresh the open breakdown and preserve it on network failure', (tester) async {
    api.ok('/users/player/reviews', trust(93));
    await mount(tester, const TrustScoreScreen(userId: 'player'));
    api.ok('/users/player/reviews', trust(94));
    RealtimeService().emitTrustUpdateForTest('player');
    await settleData(tester);
    expect(tester.widget<TrustGauge>(find.byType(TrustGauge)).score, 94);
    expect(find.text('Actual attendance: 50%'), findsOneWidget);
    api.offline('/users/player/reviews');
    RealtimeService().emitTrustUpdateForTest('player');
    await settleData(tester);
    expect(tester.widget<TrustGauge>(find.byType(TrustGauge)).score, 94);
  });

  testWidgets('a slow older trust response cannot overwrite the latest event', (tester) async {
    api.ok('/users/player/reviews', trust(93), delay: const Duration(milliseconds: 500));
    await mount(tester, const TrustScoreScreen(userId: 'player'));
    api.ok('/users/player/reviews', trust(94));
    RealtimeService().emitTrustUpdateForTest('player');
    await settleData(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<TrustGauge>(find.byType(TrustGauge)).score, 94);
  });

  testWidgets('trust updates refresh the player profile without reopening it', (tester) async {
    api.ok('/users/me/player', {'name': 'Ali', 'trust_score': 93});
    await mount(tester, const PlayerProfileScreen());
    api.ok('/users/me/player', {'name': 'Ali', 'trust_score': 94});
    RealtimeService().emitTrustUpdateForTest('player');
    await settleData(tester);
    expect(find.text('94/100'), findsOneWidget);
    expect(api.countTo('/users/me/player'), greaterThan(1));
  });

  testWidgets('owners can open the correct player profile from a booking request', (tester) async {
    api.ok('/owner/bookings', [{...booking(), 'player_id': 'player', 'player_name': 'Ali', 'trust_score': '73'}]);
    await mount(tester, const OwnerBookingRequestsScreen(), role: 'owner');
    await tester.tap(find.text('View player profile'));
    await settleData(tester);
    expect(tester.widget<PublicProfileScreen>(find.byType(PublicProfileScreen)).userId, 'player');
  });

  testWidgets('live trust refresh preserves unsaved profile edits', (tester) async {
    final profile = {'name': 'Ali', 'email': 'ali@example.com',
      'sport_preferences': ['Football'], 'trust_score': 93};
    api.ok('/users/me/player', profile);
    await mount(tester, const PlayerProfileScreen());
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Ali Khan');
    await tester.enterText(find.byType(TextField).last, 'new@example.com');
    final cricket = find.widgetWithText(FilterChip, 'Cricket');
    await tester.ensureVisible(cricket);
    await tester.tap(cricket);
    api.ok('/users/me/player', {...profile, 'trust_score': 94});
    RealtimeService().emitTrustUpdateForTest('player');
    await settleData(tester);
    expect(find.text('94/100'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, 'Ali Khan');
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'new@example.com');
    expect(tester.widget<FilterChip>(cricket).selected, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Ali'), findsOneWidget);
    expect(find.text('Cricket'), findsNothing);
  });

  testWidgets('owner custom deposit saves a decimal without rounding', (tester) async {
    api.ok('/owner/venues/venue', {});
    await mount(tester, const OwnerVenueManagementScreen(venue: {
      'id': 'venue', 'name': 'Ground', 'description': 'A playing ground', 'price_per_hour': 2000,
    }), role: 'owner');
    await tester.ensureVisible(find.text('Custom'));
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextFormField)), '35.5');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save Changes'));
    await tester.tap(find.text('Save Changes'));
    await settleData(tester);
    expect(jsonDecode(api.to('/owner/venues/venue').single.body!)['deposit_pct'], 35.5);
  });
}
