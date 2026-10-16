import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter/foundation.dart';

// Holds one GPS fix together with the real place it was taken at.
class LocationResult {
  final double latitude;
  final double longitude;
  final String address;
  final String placeName;
  final String city;
  final String province;
  final bool isInDagupan;
  final bool isInPangasinan;
  final double accuracyMeters;
  final DateTime? capturedAt;

  const LocationResult({
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.isInDagupan,
    this.placeName = '',
    this.city = '',
    this.province = '',
    this.isInPangasinan = false,
    this.accuracyMeters = 0,
    this.capturedAt,
  });

  // Short place text shown on the home screen and the location banner.
  String get displayPlace {
    if (placeName.isNotEmpty && city.isNotEmpty) return '$placeName, $city';
    if (city.isNotEmpty && province.isNotEmpty) return '$city, $province';
    if (city.isNotEmpty) return city;
    if (placeName.isNotEmpty) return placeName;
    if (province.isNotEmpty) return province;
    return 'Unknown location';
  }

  // City line stored with the report, built from the real place.
  String get cityLine {
    if (city.isEmpty && province.isEmpty) return displayPlace;
    return [
      if (city.isNotEmpty) city,
      if (province.isNotEmpty) province,
      'Philippines',
    ].join(', ');
  }

  // Accuracy text such as "8 m".
  String get accuracyText => '${accuracyMeters.toStringAsFixed(0)} m';

  Map<String, dynamic> toMap() => {
    'latitude': latitude,
    'longitude': longitude,
    'address': address,
    'city': cityLine,
    'accuracyMeters': accuracyMeters,
    'capturedAt': capturedAt?.toIso8601String(),
  };
}

class LocationService {
  LocationService._();
  static final instance = LocationService._();

  // One Geocoding instance per app, which is the 5.0.0 API.
  static final Geocoding _geocoding = Geocoding();

  // Dagupan City center, used as the anchor of the testing range.
  static const double _centerLat = 16.0400;
  static const double _centerLng = 120.3333;
  static const double _testRadiusKm = 200.0;

  // Rough Pangasinan bounds, used only when the province name is unavailable.
  static const double _pnMinLat = 15.35;
  static const double _pnMaxLat = 16.65;
  static const double _pnMinLng = 119.75;
  static const double _pnMaxLng = 120.95;

  double _degToRad(double deg) => deg * math.pi / 180.0;

  // Haversine distance in km between two coordinates.
  double _distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const double earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  bool _isWithinTestRadius(double lat, double lng) {
    return _distanceKm(lat, lng, _centerLat, _centerLng) <= _testRadiusKm;
  }

  // Offline fallback that guesses Pangasinan from the coordinates alone.
  bool _insidePangasinanBounds(double lat, double lng) {
    return lat >= _pnMinLat &&
        lat <= _pnMaxLat &&
        lng >= _pnMinLng &&
        lng <= _pnMaxLng;
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

  // Turns a GPS fix into a readable place using the device geocoder.
  Future<Map<String, String>> _reverseGeocode(double lat, double lng) async {
    try {
      // geocoding 5.0.0 exposes this only as an instance method.
      final marks = await _geocoding.placemarkFromCoordinates(lat, lng).timeout(
        const Duration(seconds: 6),
        onTimeout: () => <Placemark>[],
      );
      if (marks.isEmpty) return const <String, String>{};

      final m = marks.first;
      final barangay = (m.subLocality ?? '').trim();
      final city = (m.locality ?? m.subAdministrativeArea ?? '').trim();
      final province = (m.administrativeArea ?? '').trim();
      final country = (m.country ?? '').trim();

      final parts = <String>[
        if (barangay.isNotEmpty) barangay,
        if (city.isNotEmpty) city,
        if (province.isNotEmpty) province,
        if (country.isNotEmpty) country,
      ];

      return <String, String>{
        'placeName': barangay.isNotEmpty ? barangay : city,
        'city': city,
        'province': province,
        'address': parts.join(', '),
      };
    } catch (e) {
      debugPrint('Reverse geocode error: $e');
      return const <String, String>{};
    }
  }

  // Returns null if permission denied or GPS unavailable.
  Future<LocationResult?> getCurrentLocation() async {
    try {
      final hasPermission = await _handlePermission();
      if (!hasPermission) return null;

      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      // Real-time, high-accuracy GPS fix.
      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 15),
        ),
      );

      final bool inRadius = _isWithinTestRadius(
        position.latitude,
        position.longitude,
      );

      final geo = await _reverseGeocode(
        position.latitude,
        position.longitude,
      );

      final province = geo['province'] ?? '';
      final city = geo['city'] ?? '';
      final placeName = geo['placeName'] ?? '';
      final resolvedAddress = geo['address'] ?? '';
      final address = resolvedAddress.isNotEmpty
          ? resolvedAddress
          : '${position.latitude.toStringAsFixed(5)}, '
                '${position.longitude.toStringAsFixed(5)}';

      // Trust the geocoded province first, fall back to the coordinate bounds.
      final bool inPangasinan = province.isNotEmpty
          ? province.toLowerCase().contains('pangasinan')
          : _insidePangasinanBounds(position.latitude, position.longitude);

      return LocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        address: address,
        placeName: placeName,
        city: city,
        province: province,
        isInDagupan: inRadius,
        isInPangasinan: inPangasinan,
        accuracyMeters: position.accuracy,
        capturedAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint('Location error: $e');
      return null;
    }
  }

  // Distance in meters between two GPS points.
  double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    return _distanceKm(lat1, lng1, lat2, lng2) * 1000.0;
  }

  Future<bool> isPermissionPermanentlyDenied() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.deniedForever;
  }

  Future<void> openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }
}
