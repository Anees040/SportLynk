import 'package:flutter/foundation.dart';

class ApiConstants {
  ApiConstants._();

  /// Where the backend lives. One value, overridable at build time.
  ///
  /// ```
  /// flutter run                                                    # emulator
  /// flutter run  --dart-define=API_BASE_URL=http://192.170.0.110:3000/api   # phone on your Wi-Fi
  /// flutter build apk --release --dart-define=API_BASE_URL=https://<app>.onrender.com/api   # anywhere
  /// ```
  ///
  /// `bool.hasEnvironment` rather than `String.fromEnvironment(...).isEmpty`,
  /// because `.isEmpty` is not const-evaluable and this has to stay `const`.
  ///
  /// The default is the **emulator** address. `10.0.2.2` is the alias Android's
  /// emulator gives the host machine's localhost; it is meaningless on a real
  /// phone, so a physical device always needs the `--dart-define`. See README →
  /// "Run modes" and doc/DEPLOY_GUIDE.md.
  static const String baseUrl = bool.hasEnvironment('API_BASE_URL')
      ? String.fromEnvironment('API_BASE_URL')
      : (kIsWeb ? 'http://localhost:3000/api' : 'http://10.0.2.2:3000/api');

  // Auth
  static const String registerPlayer = '/auth/register/player';
  static const String registerOwner = '/auth/register/owner';
  static const String login = '/auth/login';
  static const String verifyPhone = '/auth/verify-phone';
  static const String forgotPasswordSendOtp = '/auth/forgot-password/send-otp';
  static const String forgotPasswordReset = '/auth/forgot-password/reset';
  static const String me = '/auth/me';

  // Venues (public)
  static const String venues = '/venues';
  static String venueById(String id) => '/venues/$id';
  static String venueSlots(String id) => '/venues/$id/slots';

  // Bookings (player)
  static const String bookings = '/bookings';
  static const String myBookings = '/bookings/my';

  // Owner
  static const String ownerVenues = '/owner/venues';
  static String ownerVenueSlots(String venueId) => '/owner/venues/$venueId/slots';
  static const String ownerBookings = '/owner/bookings';
  static String approveBooking(String id) => '/owner/bookings/$id/approve';
  static String rejectBooking(String id) => '/owner/bookings/$id/reject';
  static const String checkin = '/owner/checkin';
  static const String checkinDecide = '/owner/checkin/decide';
}
