// SDK interfaces are mocked only in this in-process test backend.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';

import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// In-process services only: these fakes never initialize an SDK connection.
class OfflineFirebase {
  final auth = OfflineAuth();
  final storage = OfflineStorage();
  final firestore = OfflineFirestore();
  void configure() => FirebaseBackend.configureForTesting(
    FirebaseBackendConfiguration(
      environment: FirebaseEnvironment.live,
      app: _App(),
      auth: auth,
      firestore: firestore,
      functions: _Functions(),
      storage: storage,
      databaseId: 'offline-test',
      localDataScope: FirebaseLocalDataScope.live,
      googleAuthMode: GoogleEmulatorAuthMode.mock,
    ),
  );
}

class OfflineUser implements User {
  OfflineUser(this.uid);
  @override
  final String uid;
  @override
  String get email => '$uid@example.invalid';
  @override
  String? get photoURL => null;
  @override
  String get displayName => 'Test user';
  @override
  bool get emailVerified => true;
  @override
  List<UserInfo> get providerData => [];
  int tokenRequests = 0;
  Future<IdTokenResult> Function()? tokenResponse;
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) {
    tokenRequests++;
    return tokenResponse?.call() ??
        Future.error(FirebaseAuthException(code: 'network-request-failed'));
  }

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async =>
      (await getIdTokenResult(forceRefresh)).token;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineToken implements IdTokenResult {
  @override
  DateTime get authTime => DateTime.utc(2026);
  @override
  Map<String, dynamic> get claims => {};
  @override
  String get token => 'synthetic-token';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineAuth implements FirebaseAuth {
  @override
  User? currentUser = OfflineUser('account-a');
  final changes = StreamController<User?>.broadcast();
  @override
  Stream<User?> authStateChanges() => changes.stream;
  @override
  Stream<User?> userChanges() => changes.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineFirestore implements FirebaseFirestore {
  Future<QuerySnapshot<Map<String, dynamic>>> Function(String, GetOptions?)?
  queryResponse;
  final queryReads = <String>[];
  final queryEvents =
      <String, StreamController<QuerySnapshot<Map<String, dynamic>>>>{};
  Future<DocumentSnapshot<Map<String, dynamic>>> Function(
    String path,
    GetOptions? options,
  )?
  response;
  final reads = <(String, Source?)>[];
  final writes = <String>[];
  final documents = <String, Map<String, dynamic>>{};
  final events =
      StreamController<DocumentSnapshot<Map<String, dynamic>>>.broadcast();
  final documentEvents =
      <String, StreamController<DocumentSnapshot<Map<String, dynamic>>>>{};
  bool emitAcknowledgements = false;
  int acknowledgements = 0;
  Future<void> Function()? commit;
  Future<void> Function(String path, Map<String, dynamic> data)? write;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);
  @override
  WriteBatch batch() => _Batch(this);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collection implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.owner, this.path);
  final OfflineFirestore owner;
  @override
  final String path;
  @override
  Query<Map<String, dynamic>> orderBy(
    Object field, {
    bool descending = false,
  }) => this;
  @override
  Query<Map<String, dynamic>> limit(int limit) => this;
  @override
  Query<Map<String, dynamic>> startAfter(Iterable<Object?> values) => this;
  @override
  Query<Map<String, dynamic>> startAfterDocument(DocumentSnapshot snapshot) =>
      this;
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    owner.queryReads.add(path);
    return owner.queryResponse?.call(path, options) ??
        Future.error(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
        );
  }

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _Document(owner, '${this.path}/$path');
  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) => this;
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => owner.queryEvents[path]?.stream ?? const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Document implements DocumentReference<Map<String, dynamic>> {
  _Document(this.owner, this.path);
  final OfflineFirestore owner;
  @override
  final String path;
  @override
  String get id => path.split('/').last;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(owner, '${this.path}/$path');
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    owner.reads.add((path, options?.source));
    return owner.response?.call(path, options) ??
        (owner.documents.containsKey(path)
            ? Future.value(OfflineSnapshot(value: owner.documents[path]))
            : null) ??
        Future.error(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
        );
  }

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => owner.documentEvents[path]?.stream ?? owner.events.stream;
  @override
  Future<void> update(Map<Object, Object?> data) async {
    owner.writes.add(path);
    await owner.write?.call(path, Map<String, dynamic>.from(data));
    owner.documents[path]?.addAll(Map<String, dynamic>.from(data));
    if (owner.emitAcknowledgements && owner.acknowledgements < 5) {
      owner.acknowledgements++;
      Timer(
        Duration.zero,
        () => owner.events.add(OfflineSnapshot(value: owner.documents[path])),
      );
    }
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    owner.writes.add(path);
    await owner.write?.call(path, data);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineSnapshot implements DocumentSnapshot<Map<String, dynamic>> {
  OfflineSnapshot({this.value, this.cached = false, this.pending = false});
  final Map<String, dynamic>? value;
  final bool cached, pending;
  @override
  bool get exists => value != null;
  @override
  String get id => 'device-a';
  @override
  Map<String, dynamic>? data() => value;
  @override
  SnapshotMetadata get metadata => _Metadata(cached, pending);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Metadata implements SnapshotMetadata {
  _Metadata(this.isFromCache, this.hasPendingWrites);
  @override
  final bool isFromCache;
  @override
  final bool hasPendingWrites;
}

class OfflineQuerySnapshot implements QuerySnapshot<Map<String, dynamic>> {
  OfflineQuerySnapshot(Map<String, Map<String, dynamic>> values)
    : docs = values.entries.map((e) => _QueryDocument(e.key, e.value)).toList();
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  @override
  List<DocumentChange<Map<String, dynamic>>> get docChanges =>
      docs.map(_DocumentChange.new).toList();
  @override
  SnapshotMetadata get metadata => _Metadata(false, false);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DocumentChange implements DocumentChange<Map<String, dynamic>> {
  _DocumentChange(this.doc);
  @override
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  @override
  DocumentChangeType get type => DocumentChangeType.added;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QueryDocument extends OfflineSnapshot
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _QueryDocument(this.documentId, Map<String, dynamic> data)
    : super(value: data);
  final String documentId;
  @override
  String get id => documentId;
  @override
  Map<String, dynamic> data() => value!;
}

class _Batch implements WriteBatch {
  _Batch(this.owner);
  final OfflineFirestore owner;
  final pending = <String, Map<String, dynamic>>{};
  @override
  void set<T>(DocumentReference<T> reference, T data, [SetOptions? options]) {
    pending[reference.path] = data as Map<String, dynamic>;
  }

  @override
  Future<void> commit() async {
    await owner.commit?.call();
    owner.documents.addAll(pending);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if ([#set, #update, #delete].contains(invocation.memberName)) return null;
    return super.noSuchMethod(invocation);
  }
}

class _App implements FirebaseApp {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineStorage implements FirebaseStorage {
  int lists = 0;
  bool failList = false;
  final objects = <String>{};
  Future<void> Function(String)? delete;
  @override
  Reference ref([String? path]) => OfflineReference(this, path ?? '');
  @override
  String get bucket => 'offline-test.invalid';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Functions implements FirebaseFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineReference implements Reference {
  OfflineReference(this.owner, this.path);
  final OfflineStorage owner;
  final String path;
  @override
  Reference child(String value) => OfflineReference(owner, '$path/$value');
  @override
  Future<ListResult> listAll() async {
    owner.lists++;
    if (owner.failList) {
      throw FirebaseException(plugin: 'firebase_storage', code: 'unavailable');
    }
    return OfflineStorageList(
      owner.objects.map((value) => OfflineReference(owner, value)).toList(),
    );
  }

  @override
  Future<void> delete() async {
    await owner.delete?.call(path);
    owner.objects.remove(path);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class OfflineStorageList implements ListResult {
  OfflineStorageList(this.items);
  @override
  final List<Reference> items;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
