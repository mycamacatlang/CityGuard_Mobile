import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../data/schema_constants.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static String _now() => DateTime.now().toUtc().toIso8601String();

  /// Current logged-in user id
  String? get currentUserId => _auth.currentUser?.uid;

  /// Kept for compatibility with existing screens
  set currentUserId(String? value) {}

  /// Check if email looks like a real email (not a test/dummy)
  static bool isRealEmail(String email) {
    final lower = email.toLowerCase();
    return !lower.contains('test') &&
        !lower.contains('dummy') &&
        !lower.contains('fake') &&
        !lower.contains('mailinator') &&
        !lower.contains('example.com');
  }

  /// Login with username — looks up email from Firestore then signs in
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

  /// Simple signup with email, username, password
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

      // Send Firebase verification email if real email
      if (isRealEmail(email)) {
        await result.user!.sendEmailVerification();
      }

      return uid;
    } catch (e) {
      return null;
    }
  }

  /// Signup with full profile info
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

      // Send Firebase verification email if real email
      if (isRealEmail(email)) {
        await result.user!.sendEmailVerification();
      }

      return uid;
    } catch (e) {
      debugPrint('Signup error: $e');
      return null;
    }
  }

  /// Forgot password — sends reset email via Firebase
  Future<bool> forgotPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check if Firebase has verified the current user's email
  Future<bool> checkFirebaseEmailVerified() async {
    try {
      await _auth.currentUser?.reload();
      return _auth.currentUser?.emailVerified ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Mark email as verified in Firestore
  Future<void> markEmailVerified(String userId) async {
    await _db.collection(Schema.users).doc(userId).update({
      Schema.emailVerified: true,
    });
  }

  /// Get profile map for user
  Future<Map<String, dynamic>?> getProfile(String userId) async {
    final snap = await _db.collection(Schema.userProfiles).doc(userId).get();
    return snap.data();
  }

  /// Update profile fields
  Future<void> updateProfile(String userId, Map<String, dynamic> data) async {
    data[Schema.updatedAt] = _now();
    await _db
        .collection(Schema.userProfiles)
        .doc(userId)
        .set(data, SetOptions(merge: true));
  }

  /// Update user document fields
  Future<void> updateUser(String userId, Map<String, dynamic> data) async {
    await _db
        .collection(Schema.users)
        .doc(userId)
        .set(data, SetOptions(merge: true));
  }

  /// Get user document data
  Future<Map<String, dynamic>?> getUser(String userId) async {
    final snap = await _db.collection(Schema.users).doc(userId).get();
    return snap.data();
  }

  /// Logout
  Future<void> logout() async {
    await _auth.signOut();
  }

  /// No longer needed — kept for compatibility but does nothing
  Future<void> seedDummyDataIfEmpty() async {}

  Future<void> submitReport(Map<String, dynamic> data) async {
    await _db.collection('reports').add(data);
  }

  /// Resend Firebase verification email
  Future<void> resendVerificationEmail() async {
    await _auth.currentUser?.sendEmailVerification();
  }

  Future<void> deleteAccount(String userId) async {
    // Delete from Firestore
    await _db.collection(Schema.users).doc(userId).delete();
    await _db.collection(Schema.userProfiles).doc(userId).delete();

    // Delete from Firebase Auth
    await _auth.currentUser?.delete();
  }
}
