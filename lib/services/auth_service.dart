import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../data/schema_constants.dart';
import '../services/blockchain_service.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static String _now() => DateTime.now().toUtc().toIso8601String();

  String? get currentUserId => _auth.currentUser?.uid;
  set currentUserId(String? value) {}

  static bool isRealEmail(String email) {
    final lower = email.toLowerCase();
    return !lower.contains('test') &&
        !lower.contains('dummy') &&
        !lower.contains('fake') &&
        !lower.contains('mailinator') &&
        !lower.contains('example.com');
  }

  Future<String?> getAuthToken() async {
    try {
      return await _auth.currentUser?.getIdToken(true);
    } catch (e) {
      debugPrint('Token fetch error: $e');
      return null;
    }
  }

  Future<String?> login(String username, String password) async {
    try {
      final q = await _db
          .collection(Schema.users)
          .where(Schema.username, isEqualTo: username)
          .get();

      if (q.docs.isEmpty) return null;

      final data = q.docs.first.data();
      final email = data[Schema.email];
      if (email == null || email.toString().isEmpty) return null;

      final result = await _auth.signInWithEmailAndPassword(
        email: email.toString().trim(),
        password: password.trim(),
      );
      return result.user?.uid;
    } catch (e) {
      debugPrint('Login error: $e');
      return null;
    }
  }

  Future<String?> signUp({
    required String email,
    required String username,
    required String password,
  }) async {
    try {
      final byUsername = await _db
          .collection(Schema.users)
          .where(Schema.username, isEqualTo: username)
          .get();
      if (byUsername.docs.isNotEmpty) return null;

      final result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final uid = result.user!.uid;

      await _db.collection(Schema.users).doc(uid).set({
        Schema.email: email,
        Schema.username: username,
        Schema.emailVerified: false,
        Schema.createdAt: _now(),
      });

      await _db.collection(Schema.userProfiles).doc(uid).set({
        Schema.userId: uid,
        Schema.updatedAt: _now(),
      });

      if (isRealEmail(email)) await result.user!.sendEmailVerification();
      return uid;
    } catch (e) {
      return null;
    }
  }

  Future<String?> signUpWithProfile({
    required String email,
    required String username,
    required String password,
    required String firstName,
    required String lastName,
    required String contactNumber,
    required String address,
    required String barangay,
    String? birthday,
    String? gender,
  }) async {
    try {
      final byUsername = await _db
          .collection(Schema.users)
          .where(Schema.username, isEqualTo: username)
          .get();
      if (byUsername.docs.isNotEmpty) return null;

      final result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final uid = result.user!.uid;

      await _db.collection(Schema.users).doc(uid).set({
        Schema.email: email,
        Schema.username: username,
        Schema.emailVerified: false,
        Schema.createdAt: _now(),
      });

      await _db.collection(Schema.userProfiles).doc(uid).set({
        Schema.userId: uid,
        Schema.firstName: firstName,
        Schema.lastName: lastName,
        Schema.contactNumber: contactNumber,
        Schema.address: address,
        Schema.barangay: barangay,
        Schema.birthday: birthday,
        Schema.gender: gender,
        Schema.updatedAt: _now(),
      });

      if (isRealEmail(email)) await result.user!.sendEmailVerification();
      return uid;
    } catch (e) {
      debugPrint('Signup error: $e');
      return null;
    }
  }

  Future<bool> forgotPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> checkFirebaseEmailVerified() async {
    try {
      await _auth.currentUser?.reload();
      return _auth.currentUser?.emailVerified ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<void> markEmailVerified(String userId) async {
    await _db.collection(Schema.users).doc(userId).update({
      Schema.emailVerified: true,
    });
  }

  Future<Map<String, dynamic>?> getProfile(String userId) async {
    final snap = await _db.collection(Schema.userProfiles).doc(userId).get();
    return snap.data();
  }

  Future<void> updateProfile(String userId, Map<String, dynamic> data) async {
    data[Schema.updatedAt] = _now();
    await _db
        .collection(Schema.userProfiles)
        .doc(userId)
        .set(data, SetOptions(merge: true));
  }

  Future<void> updateUser(String userId, Map<String, dynamic> data) async {
    await _db
        .collection(Schema.users)
        .doc(userId)
        .set(data, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>?> getUser(String userId) async {
    final snap = await _db.collection(Schema.users).doc(userId).get();
    return snap.data();
  }

  Future<void> logout() async {
    await _auth.signOut();
  }

  Future<void> seedDummyDataIfEmpty() async {}

  /// ✅ P1 REVISION: Secure report submission with:
  /// - Reporter identity/phone captured for verification
  /// - AI confidence gate (80–100% only)
  /// - Live video URL (gallery uploads disabled)
  /// - Blockchain hash saved to Sepolia after Firestore save
  Future<void> submitReport(Map<String, dynamic> data) async {
    // Layer 1: Reject if not logged in
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception(
        'Unauthorized: user must be logged in to submit a report',
      );
    }

    // Layer 2: Validate required fields
    final type = data['type']?.toString().trim();
    final description = data['description']?.toString().trim();

    if (type == null || type.isEmpty) {
      throw Exception('Validation: incident type is required');
    }
    if (description == null || description.length < 20) {
      throw Exception('Validation: description must be at least 20 characters');
    }

    // AI confidence gate, the manual fallback is still allowed through.
    final aiConfidence = data['aiConfidence'];
    final manuallyDescribed = data['manuallyDescribed'] == true;
    if (aiConfidence is double && aiConfidence < 0.80 && !manuallyDescribed) {
      throw Exception(
        'Validation: AI confidence is below 80%. Report rejected.',
      );
    }

    // Layer 3: Sanitize string fields
    String sanitize(dynamic val) =>
        val?.toString().replaceAll(RegExp(r'[<>{}\[\]\\]'), '').trim() ?? '';

    // Location stored as structured map
    Map<String, dynamic> safeLocation = {};
    final rawLocation = data['location'];
    if (rawLocation is Map<String, dynamic>) {
      safeLocation = {
        'latitude': rawLocation['latitude'] is double
            ? rawLocation['latitude']
            : null,
        'longitude': rawLocation['longitude'] is double
            ? rawLocation['longitude']
            : null,
        'address': sanitize(rawLocation['address']),
        'city': sanitize(rawLocation['city']),
        'accuracyMeters': rawLocation['accuracyMeters'],
        'capturedAt': sanitize(rawLocation['capturedAt']),
      };
    }

    // Both evidence URLs come from the screen after the Cloudinary upload.
    final rawVideoUrl = data['videoUrl']?.toString();
    final rawPhotoUrl = data['photoUrl']?.toString();
    // Photo and video stay separate, each one is rendered on its own.
    final videoUrl =
        (rawVideoUrl != null && rawVideoUrl.isNotEmpty) ? rawVideoUrl : null;
    final imageUrl =
        (rawPhotoUrl != null && rawPhotoUrl.isNotEmpty) ? rawPhotoUrl : null;
    final timestamp = _now();

    // Reporter identity comes from the screen, profile fetch is the fallback.
    final profile = await getProfile(user.uid);
    final profileName = profile != null
        ? '${profile['firstName'] ?? ''} ${profile['lastName'] ?? ''}'.trim()
        : '';
    final passedName = data['reporterName']?.toString().trim() ?? '';
    final passedPhone = data['reporterPhone']?.toString().trim() ?? '';
    final reporterName = passedName.isNotEmpty ? passedName : profileName;
    final reporterPhone = passedPhone.isNotEmpty
        ? passedPhone
        : (profile?['contactNumber']?.toString() ?? '');

    final safeData = {
      'userId': user.uid, // Always from auth token
      'type': sanitize(data['type']),
      'description': sanitize(data['description']),
      'aiCategory': sanitize(data['aiCategory']),
      'aiConfidence': aiConfidence is double
          ? aiConfidence.clamp(0.0, 1.0)
          : null,
      'aiOverriddenByUser': data['aiOverriddenByUser'] == true,
      'manuallyDescribed': manuallyDescribed,
      'videoUrl': videoUrl, // video backup URL, null when no video was taken
      'imageUrl': imageUrl, // photo URL only, never the video URL
      'imageUploaded': imageUrl != null,
      'location': safeLocation, // Structured map with lat/lng only
      'status': 'pending',
      'createdAt': timestamp,
      // Reporter identity stays top level, never inside location.
      'reporterName': reporterName,
      'reporterPhone': reporterPhone,
      'assignedDepartment': sanitize(data['assignedDepartment']),
      'barangay': sanitize(data['barangay']),
      'severity': sanitize(data['severity']),
      'blockchainVerified': false, // Updated after blockchain save
    };

    // Step 1: Save to Firestore first (fast — user sees success immediately)
    final docRef = await _db.collection('reports').add(safeData);
    final reportId = docRef.id;
    debugPrint('✅ Report saved to Firestore: $reportId');

    // Step 2: Generate SHA-256 hash of report data
    final reportHash = BlockchainService.instance.generateReportHash(
      reportId: reportId,
      userId: user.uid,
      type: sanitize(data['type']),
      description: sanitize(data['description']),
      timestamp: timestamp,
    );
    debugPrint('✅ Report hash generated: $reportHash');

    // Step 3: Save hash to Sepolia blockchain (runs in background)
    BlockchainService.instance
        .submitReportHash(
          reportId: reportId,
          reportHash: reportHash,
          incidentType: sanitize(data['type']),
        )
        .then((txHash) async {
          if (txHash != null) {
            await docRef.update({
              'blockchainVerified': true,
              'blockchainTxHash': txHash,
              'blockchainHash': reportHash,
            });
            debugPrint('✅ Blockchain verified — tx: $txHash');
          } else {
            debugPrint(
              '⚠️ Blockchain save failed — report still safe in Firestore',
            );
          }
        });
  }

  Future<void> resendVerificationEmail() async {
    await _auth.currentUser?.sendEmailVerification();
  }

  Future<void> deleteAccount(String userId) async {
    await _db.collection(Schema.users).doc(userId).delete();
    await _db.collection(Schema.userProfiles).doc(userId).delete();
    await _auth.currentUser?.delete();
  }
}