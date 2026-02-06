import 'dart:convert';

/// Simple in-memory Firestore-like API with localStorage persistence for web.
/// Works completely offline. Swap this for real Firebase Firestore later.

// --- Snapshot types (Firestore-like) ---

class DocumentSnapshot {
  DocumentSnapshot({required this.id, required Map<String, dynamic>? data, required this.exists})
      : _data = data;

  final String id;
  final Map<String, dynamic>? _data;
  final bool exists;

  Map<String, dynamic>? data() => _data;
}

class QuerySnapshot {
  QuerySnapshot({required this.docs});

  final List<DocumentSnapshot> docs;
}

// --- Document reference ---

class DocumentReference {
  DocumentReference({
    required FakeFirebase firebase,
    required String collection,
    required String id,
  })  : _firebase = firebase,
        _collection = collection,
        _id = id;

  final FakeFirebase _firebase;
  final String _collection;
  final String _id;

  String get id => _id;

  Future<void> set(Map<String, dynamic> data, {bool merge = false}) async {
    await _firebase._setDoc(_collection, _id, data, merge: merge);
  }

  Future<DocumentSnapshot> get() async {
    return await _firebase._getDoc(_collection, _id);
  }
}

// --- Query (simplified: where clause with isEqualTo only) ---

class QueryReference {
  QueryReference({
    required FakeFirebase firebase,
    required String collection,
    String? whereField,
    dynamic whereValue,
  })  : _firebase = firebase,
        _collection = collection,
        _whereField = whereField,
        _whereValue = whereValue;

  final FakeFirebase _firebase;
  final String _collection;
  final String? _whereField;
  final dynamic _whereValue;

  Future<QuerySnapshot> get() async {
    return await _firebase._query(_collection, _whereField, _whereValue);
  }
}

// --- Collection reference ---

class CollectionReference {
  CollectionReference({
    required FakeFirebase firebase,
    required String name,
  })  : _firebase = firebase,
        _name = name;

  final FakeFirebase _firebase;
  final String _name;

  DocumentReference doc([String? id]) {
    final docId = id ?? _firebase._generateId();
    return DocumentReference(
      firebase: _firebase,
      collection: _name,
      id: docId,
    );
  }

  Future<DocumentReference> add(Map<String, dynamic> data) async {
    final docRef = doc();
    await docRef.set(data);
    return docRef;
  }

  QueryReference where(String field, {dynamic isEqualTo}) {
    return QueryReference(
      firebase: _firebase,
      collection: _name,
      whereField: field,
      whereValue: isEqualTo,
    );
  }

  Future<QuerySnapshot> get() async {
    return await _firebase._query(_name, null, null);
  }
}

// --- Main fake Firebase (Firestore-like) ---

class FakeFirebase {
  FakeFirebase._();
  static final FakeFirebase instance = FakeFirebase._();

  // In-memory database store
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};

  /// Firestore-style: use as FirebaseFirestore.instance.collection('users')...
  CollectionReference collection(String name) {
    return CollectionReference(firebase: this, name: name);
  }

  String _generateId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final us = DateTime.now().microsecondsSinceEpoch % 10000;
    return '${ms}_$us';
  }

  Future<void> _setDoc(String collection, String id, Map<String, dynamic> data, {bool merge = false}) async {
    if (!_store.containsKey(collection)) _store[collection] = {};
    final existing = _store[collection]![id];
    if (merge && existing != null) {
      _store[collection]![id] = {...existing, ...data};
    } else {
      _store[collection]![id] = Map<String, dynamic>.from(data);
    }
  }

  Future<DocumentSnapshot> _getDoc(String collection, String id) async {
    final coll = _store[collection];
    if (coll == null) return DocumentSnapshot(id: id, data: null, exists: false);
    final data = coll[id];
    if (data == null) return DocumentSnapshot(id: id, data: null, exists: false);
    return DocumentSnapshot(id: id, data: Map<String, dynamic>.from(data), exists: true);
  }

  Future<QuerySnapshot> _query(String collection, String? whereField, dynamic whereValue) async {
    final coll = _store[collection] ?? {};
    List<DocumentSnapshot> docs = coll.entries
        .map((e) => DocumentSnapshot(
              id: e.key,
              data: Map<String, dynamic>.from(e.value),
              exists: true,
            ))
        .toList();
    if (whereField != null && whereValue != null) {
      docs = docs.where((d) {
        final data = d.data();
        if (data == null) return false;
        final v = data[whereField];
        return v == whereValue;
      }).toList();
    }
    return QuerySnapshot(docs: docs);
  }

  /// Check if database is empty
  bool get isEmpty => _store.isEmpty;

  /// Export database as JSON string (for debugging)
  String exportToJson() {
    return const JsonEncoder.withIndent('  ').convert(_store);
  }

  /// Import database from JSON string
  void importFromJson(String json) {
    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>?;
      if (decoded != null) {
        _store.clear();
        decoded.forEach((k, v) {
          if (v is Map) {
            _store[k] = v.map((dk, dv) => MapEntry(dk.toString(), Map<String, dynamic>.from(dv as Map)));
          }
        });
      }
    } catch (_) {}
  }

  /// Clear all data
  void clear() {
    _store.clear();
  }
}
