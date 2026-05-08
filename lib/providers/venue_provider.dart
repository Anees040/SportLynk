import 'package:flutter/foundation.dart';
import '../models/venue.dart';

class VenueProvider extends ChangeNotifier {
  List<Venue> _venues = [];
  bool _isLoading = false;

  List<Venue> get venues => _venues;
  bool get isLoading => _isLoading;

  void setVenues(List<Venue> venues) {
    _venues = venues;
    notifyListeners();
  }

  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }
}
