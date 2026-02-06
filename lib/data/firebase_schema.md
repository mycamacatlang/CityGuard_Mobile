# CityGuard Firebase Database Schema

This document describes the database schema used by CityGuard. The app uses a **Firestore-style** API (collections, documents, fields). The same schema applies when using the real Firebase Firestore or the local fake backend.

---

## Collections

### 1. `users`

Stores account credentials and auth data. Document ID = unique user ID (auto-generated on signup).

| Field           | Type    | Required | Description                                      |
|-----------------|---------|----------|--------------------------------------------------|
| `email`         | string  | yes      | User email (unique)                              |
| `username`      | string  | yes      | Login username (unique)                          |
| `password`      | string  | yes      | Stored as plain for fake DB; hash in production  |
| `emailVerified` | boolean | yes      | Whether email has been verified                  |
| `createdAt`     | string  | yes      | ISO 8601 timestamp                               |

**Indexes / Queries:**
- Lookup by `username` (login)
- Lookup by `email` (forgot password, uniqueness check)

---

### 2. `user_profiles`

Extended profile for each user. Document ID = same as `users` document ID (one-to-one).

| Field              | Type   | Required | Description                                      |
|--------------------|--------|----------|--------------------------------------------------|
| `userId`           | string | yes      | Reference to `users` document ID                 |
| `firstName`        | string | yes      | User's first name                                |
| `lastName`         | string | yes      | User's last name                                 |
| `contactNumber`    | string | yes      | PH mobile format (09XXXXXXXXX)                   |
| `address`          | string | yes      | Street address                                   |
| `barangay`         | string | yes      | Barangay in Dagupan City                         |
| `birthday`         | string | no       | Date string `YYYY-MM-DD`                         |
| `gender`           | string | no       | `Male` \| `Female` \| `Prefer not to say`        |
| `profileImagePath` | string | no       | Local file path to profile picture               |
| `updatedAt`        | string | yes      | ISO 8601 timestamp                               |

---

### 3. `incidents`

Emergency reports (for future use: geo-tagged reports, AI classification, etc.). Document ID = auto-generated.

| Field       | Type   | Required | Description                                      |
|-------------|--------|----------|--------------------------------------------------|
| `userId`    | string | yes      | Reporter user ID                                 |
| `type`      | string | yes      | `ambulance` \| `police` \| `firefighter`         |
| `latitude`  | number | no       | Geo latitude                                     |
| `longitude` | number | no       | Geo longitude                                    |
| `status`    | string | yes      | `pending` \| `acknowledged` \| `resolved`        |
| `createdAt` | string | yes      | ISO 8601 timestamp                               |

---

## API Usage (Firestore-like)

```dart
// Get instance
final db = FakeFirebase.instance;

// Collection reference
db.collection('users')

// Document reference
db.collection('users').doc(id)

// Set document (create/overwrite)
docRef.set(data)

// Set with merge (update only provided fields)
docRef.set(data, merge: true)

// Get document
final snapshot = await docRef.get();
if (snapshot.exists) {
  final data = snapshot.data();
}

// Add document (auto-generates ID)
final docRef = await collectionRef.add(data);

// Query with where clause
final querySnapshot = await collectionRef
    .where('email', isEqualTo: 'test@cityguard.ph')
    .get();
for (final doc in querySnapshot.docs) {
  print(doc.data());
}
```

---

## Email Verification

- **Mailtrap API Key:** `39819e106dd4bfcd1726a4eeeb5115ed`
- **Offline fallback code:** `188188`
- New signups require email verification before accessing the app
- Verification code is 6 digits, sent via Mailtrap when online

---

## Dagupan City Barangays

The app includes all 31 barangays of Dagupan City for address selection:

Bacayao Norte, Bacayao Sur, Barangay I (T. Bugallon), Barangay II (Nueva), 
Barangay IV (Zamora), Bolosan, Bonuan Binloc, Bonuan Boquig, Bonuan Gueset, 
Calmay, Carael, Caranglaan, Herrero, Lasip Chico, Lasip Grande, Lomboy, 
Lucao, Malued, Mamalingling, Mangin, Mayombo, Pantal, Poblacion Oeste, 
Pogo Chico, Pogo Grande, Pugaro Suit, Salapingao, Salisay, Tambac, 
Tapuac, Tebeng
