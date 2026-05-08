import 'package:flutter/foundation.dart';

class ApiConstants {
  ApiConstants._();

  // Use localhost for Web, 10.0.2.2 for Android Emulator
  static const String baseUrl = kIsWeb ? 'http://localhost:3000/api' : 'http://10.0.2.2:3000/api';

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
