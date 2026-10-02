import 'package:geolocator/geolocator.dart';

/// Best-effort device location for "nearest grounds first".
///
/// Everything here fails soft. Location is a convenience, never a gate: if the service
/// is off, the permission is denied, or a fix cannot be taken, [current] returns null
/// and the caller simply shows grounds in their normal relevance order. Nothing in the
/// app is blocked on having a location, which is why no method throws.
class LocationService {
  /// The user's current coordinates, or null if unavailable or not permitted.
  ///
  /// Permission is requested at most to `whileInUse`; a permanently denied permission
  /// is not re-prompted (that would be nagging — the OS settings are the only place to
  /// reverse it), it just yields null.
  Future<({double lat, double lng})?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      return (lat: pos.latitude, lng: pos.longitude);
    } catch (_) {
      // A timeout, a missing plugin on web, a revoked permission mid-call — all of it
      // means "no location", which the caller already handles.
      return null;
    }
  }
}
