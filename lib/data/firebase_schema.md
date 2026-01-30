# CityGuard Firebase Database Schema

This document describes the database schema used by CityGuard. The app uses a **Firestore-style** API (collections, documents, fields). The same schema applies when using the real Firebase Firestore or the local fake backend.

---

## Collections

### 1. `users`

Stores account credentials and basic auth data. Document ID = unique user ID (auto-generated on signup).

| Field        | Type   | Required | Description                          |
|-------------|--------|----------|--------------------------------------|
| `email`     | string | yes      | User email (unique)                  |
| `username`  | string | yes      | Login username (unique)              |
| `password`  | string | yes      | Stored as plain for fake DB only; use hash in production |
| `createdAt` | string | yes      | ISO 8601 timestamp (e.g. `2025-01-30T12:00:00.000Z`) |

**Indexes / Queries:**
- Lookup by `username` (login).
- Lookup by `email` (forgot password, uniqueness).

---

### 2. `user_profiles`

Extended profile for each user. Document ID = same as `users` document ID (one-to-one).

| Field       | Type   | Required | Description                          |
|------------|--------|----------|--------------------------------------|
| `userId`   | string | yes      | Reference to `users` document ID     |
| `firstName`| string | no       |                                      |
| `lastName` | string | no       |                                      |
| `birthday` | string | no       | Date string `YYYY-MM-DD`             |
| `gender`   | string | no       | `male` \| `female` \| `other` \| `prefer_not` |
| `updatedAt`| string | yes      | ISO 8601 timestamp                   |

---

### 3. `incidents`

Emergency reports (for future use: geo-tagged reports, AI classification, etc.). Document ID = auto-generated.

| Field      | Type   | Required | Description                          |
|-----------|--------|----------|--------------------------------------|
| `userId`  | string | yes      | Reporter user ID                     |
| `type`    | string | yes      | `ambulance` \| `police` \| `firefighter` |
| `latitude`| number | no       | Geo latitude                          |
| `longitude`| number| no       | Geo longitude                         |
| `status`  | string | yes      | `pending` \| `acknowledged` \| `resolved` |
| `createdAt`| string | yes      | ISO 8601 timestamp                   |

---

## API Usage (Firestore-like)

- **Collection reference:** `db.collection('users')`
- **Document reference:** `db.collection('users').doc(id)`
- **Set document:** `docRef.set(data)` or `docRef.set(data, merge: true)`
- **Get document:** `docRef.get()` → `DocumentSnapshot` with `data()`, `exists`
- **Add document (auto ID):** `collectionRef.add(data)` → returns new doc ref
- **Query:** `collectionRef.where('field', isEqualTo: value).get()` → `QuerySnapshot` with `docs`

The fake implementation persists all data to a single local JSON file and exposes this same API so the app can switch to real Firebase later without changing call sites.
