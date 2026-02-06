import '../data/schema_constants.dart';
import 'fake_firebase.dart';

/// Auth and user profile operations using Firestore-like API.
/// Uses [FakeFirebase] (local file); swap to real Firebase by changing the backend here.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FakeFirebase _db = FakeFirebase.instance;

  /// Current logged-in user id. Set on login/signup, clear on logout.
  String? currentUserId;

  static String _now() => DateTime.now().toUtc().toIso8601String();

  /// Returns user id if login succeeds, null otherwise.
  Future<String?> login(String username, String password) async {
    final q = await _db
        .collection(Schema.users)
        .where(Schema.username, isEqualTo: username)
        .get();
    if (q.docs.isEmpty) return null;
    final doc = q.docs.first;
    final data = doc.data();
    if (data == null || data[Schema.password] != password) return null;
    return doc.id;
  }

  /// Creates user and optional profile. Returns new user id or null if email/username taken.
  Future<String?> signUp({
    required String email,
    required String username,
    required String password,
  }) async {
    final usersRef = _db.collection(Schema.users);
    final byEmail = await usersRef.where(Schema.email, isEqualTo: email).get();
    if (byEmail.docs.isNotEmpty) return null;
    final byUsername = await usersRef.where(Schema.username, isEqualTo: username).get();
    if (byUsername.docs.isNotEmpty) return null;

    final docRef = await usersRef.add({
      Schema.email: email,
      Schema.username: username,
      Schema.password: password,
      Schema.createdAt: _now(),
    });
    final uid = docRef.id;
    await _db.collection(Schema.userProfiles).doc(uid).set({
      Schema.userId: uid,
      Schema.updatedAt: _now(),
    }, merge: true);
    return uid;
  }

  /// Updates password for user with given email. Returns true if found and updated.
  Future<bool> forgotPassword(String email, String newPassword) async {
    final q = await _db
        .collection(Schema.users)
        .where(Schema.email, isEqualTo: email)
        .get();
    if (q.docs.isEmpty) return false;
    final doc = q.docs.first;
    await _db.collection(Schema.users).doc(doc.id).set({
      Schema.password: newPassword,
    }, merge: true);
    return true;
  }

  /// Get profile map for user (nullable).
  Future<Map<String, dynamic>?> getProfile(String userId) async {
    final snap = await _db.collection(Schema.userProfiles).doc(userId).get();
    return snap.data();
  }

  /// Update profile fields (merge).
  Future<void> updateProfile(String userId, Map<String, dynamic> data) async {
    data[Schema.updatedAt] = _now();
    await _db.collection(Schema.userProfiles).doc(userId).set(data, merge: true);
  }

  /// Update user document fields (merge).
  Future<void> updateUser(String userId, Map<String, dynamic> data) async {
    await _db.collection(Schema.users).doc(userId).set(data, merge: true);
  }

  /// Get user document data.
  Future<Map<String, dynamic>?> getUser(String userId) async {
    final snap = await _db.collection(Schema.users).doc(userId).get();
    return snap.data();
  }

  /// Enhanced signup with profile info. Returns user id or null if email/username taken.
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
    final usersRef = _db.collection(Schema.users);
    final byEmail = await usersRef.where(Schema.email, isEqualTo: email).get();
    if (byEmail.docs.isNotEmpty) return null;
    final byUsername = await usersRef.where(Schema.username, isEqualTo: username).get();
    if (byUsername.docs.isNotEmpty) return null;

    final docRef = await usersRef.add({
      Schema.email: email,
      Schema.username: username,
      Schema.password: password,
      Schema.emailVerified: false,
      Schema.createdAt: _now(),
    });
    final uid = docRef.id;
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
    return uid;
  }

  /// Seeds dummy users and profiles if the database is empty. Call once at app startup.
  Future<void> seedDummyDataIfEmpty() async {
    final q = await _db.collection(Schema.users).get();
    if (q.docs.isNotEmpty) return;

    final dummyUsers = [
      {
        Schema.email: 'test@cityguard.ph',
        Schema.username: 'testuser',
        Schema.password: 'test123',
        Schema.firstName: 'Juan',
        Schema.lastName: 'Dela Cruz',
        Schema.birthday: '1990-05-15',
        Schema.gender: 'male',
        Schema.contactNumber: '09171234567',
        Schema.address: '123 Rizal Street',
        Schema.barangay: 'Poblacion West',
      },
      {
        Schema.email: 'admin@cityguard.ph',
        Schema.username: 'admin',
        Schema.password: 'admin123',
        Schema.firstName: 'Maria',
        Schema.lastName: 'Santos',
        Schema.birthday: '1985-01-20',
        Schema.gender: 'female',
        Schema.contactNumber: '09189876543',
        Schema.address: '456 Bonifacio Ave',
        Schema.barangay: 'Pantal',
      },
      {
        Schema.email: 'demo@cityguard.ph',
        Schema.username: 'demo',
        Schema.password: 'demo123',
        Schema.firstName: 'Pedro',
        Schema.lastName: 'Reyes',
        Schema.birthday: '1995-11-08',
        Schema.gender: 'male',
        Schema.contactNumber: '09201112222',
        Schema.address: '789 Quezon Blvd',
        Schema.barangay: 'Bonuan Gueset',
      },
    ];

    for (final userData in dummyUsers) {
      final email = userData[Schema.email] as String;
      final username = userData[Schema.username] as String;
      final password = userData[Schema.password] as String;
      final docRef = await _db.collection(Schema.users).add({
        Schema.email: email,
        Schema.username: username,
        Schema.password: password,
        Schema.emailVerified: true,
        Schema.createdAt: _now(),
      });
      final uid = docRef.id;
      await _db.collection(Schema.userProfiles).doc(uid).set({
        Schema.userId: uid,
        Schema.firstName: userData[Schema.firstName],
        Schema.lastName: userData[Schema.lastName],
        Schema.birthday: userData[Schema.birthday],
        Schema.gender: userData[Schema.gender],
        Schema.contactNumber: userData[Schema.contactNumber],
        Schema.address: userData[Schema.address],
        Schema.barangay: userData[Schema.barangay],
        Schema.updatedAt: _now(),
      });
    }
  }
}
