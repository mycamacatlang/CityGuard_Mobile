import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';

class LocationResult {
  final double latitude;
  final double longitude;
  final String address;
  final bool isInDagupan; // ✅ Key flag — blocks submission if false

  const LocationResult({
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.isInDagupan,
  });

  Map<String, dynamic> toMap() => {
    'latitude': latitude,
    'longitude': longitude,
    'address': address,
    'city': 'Dagupan City, Pangasinan, Philippines',
  };
}

class LocationService {
  LocationService._();
  static final instance = LocationService._();

  // ✅ Dagupan City geographic bounding box (covers all barangays)
  // North: 16.075°N  South: 16.020°N
  // East:  120.370°E West:  120.315°E
  static const double _minLat = 16.020;
  static const double _maxLat = 16.075;
  static const double _minLng = 120.315;
  static const double _maxLng = 120.370;

  bool _isWithinDagupan(double lat, double lng) {
    return lat >= _minLat && lat <= _maxLat && lng >= _minLng && lng <= _maxLng;
  }

  Future<bool> _handlePermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;
    return true;
  }

  /// Returns null if permission denied or GPS unavailable.
  /// [LocationResult.isInDagupan] is false if user is outside Dagupan.
  Future<LocationResult?> getCurrentLocation() async {
    try {
      final hasPermission = await _handlePermission();
      if (!hasPermission) return null;

      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      final bool inDagupan = _isWithinDagupan(
        position.latitude,
        position.longitude,
      );

      return LocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        address: 'Dagupan City, Pangasinan, Philippines',
        isInDagupan: inDagupan,
      );
    } catch (e) {
      debugPrint('Location error: $e');
      return null;
    }
  }

  Future<bool> isPermissionPermanentlyDenied() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.deniedForever;
  }

  Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }
}
