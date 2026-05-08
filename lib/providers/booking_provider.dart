import 'package:flutter/foundation.dart';
import '../models/booking.dart';

class BookingProvider extends ChangeNotifier {
  List<Booking> _myBookings = [];
  bool _isLoading = false;

  List<Booking> get myBookings => _myBookings;
  bool get isLoading => _isLoading;

  void setBookings(List<Booking> bookings) {
    _myBookings = bookings;
    notifyListeners();
  }

  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }
}
