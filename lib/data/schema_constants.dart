/// Collection and field names for CityGuard Firebase schema.
/// Keep in sync with [firebase_schema.md].
class Schema {
  Schema._();

  // Collections
  static const String users = 'users';
  static const String userProfiles = 'user_profiles';
  static const String incidents = 'incidents';

  // Common fields
  static const String createdAt = 'createdAt';
  static const String updatedAt = 'updatedAt';
  static const String userId = 'userId';

  // users
  static const String email = 'email';
  static const String username = 'username';
  static const String password = 'password';

  // user_profiles
  static const String firstName = 'firstName';
  static const String lastName = 'lastName';
  static const String birthday = 'birthday';
  static const String gender = 'gender';

  // incidents
  static const String type = 'type';
  static const String latitude = 'latitude';
  static const String longitude = 'longitude';
  static const String status = 'status';
}
