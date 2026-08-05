import 'dart:convert';

import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/services/attachment_storage_repository.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/services/firebase_emulator_google_auth.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/note_cloud_repository.dart';
import 'package:better_keep/state.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  User? testUser;
  DocumentReference<Map<String, dynamic>>? testUserDocument;
  Reference? testStorageObject;
  final testNoteDocumentIds = <String>[];

  setUpAll(() async {
    debugPrint('Physical Android acceptance: initializing Firebase Core');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 20));
    debugPrint('Physical Android acceptance: loading preferences');
    final preferences = await SharedPreferences.getInstance();
    FirebaseEmulatorConfig.init(preferences);
    debugPrint('Physical Android acceptance: detecting device route');
    await FirebaseEmulatorConfig.initDeviceInfo();
    debugPrint('Physical Android acceptance: connecting emulators');
    await FirebaseEmulatorConfig.connectToEmulators(
      physicalDeviceHost: const String.fromEnvironment('EMULATOR_HOST'),
    );
    final selectedAppName = FirebaseBackend.app.name;
    expect(selectedAppName, startsWith('better-keep-emulator-'));
    expect(selectedAppName, isNot(Firebase.app().name));
    expect(FirebaseBackend.auth.app.name, selectedAppName);
    expect(FirebaseBackend.firestore.app.name, selectedAppName);
    expect(FirebaseBackend.storage.app.name, selectedAppName);
    expect(FirebaseBackend.functions().app.name, selectedAppName);
    expect(FirebaseBackend.active.functions.app.name, selectedAppName);
    expect(FirebaseBackend.databaseId, FirebaseBackend.emulatorDatabaseId);
    expect(FirebaseBackend.localDataScope, FirebaseLocalDataScope.emulator);

    debugPrint('Physical Android acceptance: authenticating');
    final credential = await FirebaseBackend.auth
        .signInWithCredential(FirebaseEmulatorGoogleAuth.credential())
        .timeout(const Duration(seconds: 20));
    testUser = credential.user;
    expect(testUser, isNotNull);
    expect(
      testUser!.providerData.map((provider) => provider.providerId),
      contains('google.com'),
    );

    debugPrint('Physical Android acceptance: granting Pro claims');
    final claimsResult = await FirebaseBackend.functions()
        .httpsCallable('setEmulatorTestClaims')
        .call<Map<String, dynamic>>()
        .timeout(const Duration(seconds: 20));
    expect(claimsResult.data['success'], isTrue);
    await testUser!.getIdToken(true);
    debugPrint('Physical Android acceptance: probing Firestore SDK');
    await FirebaseEmulatorConfig.verifyAuthenticatedFirestore(testUser!);
  });

  tearDownAll(() async {
    if (testUser != null) {
      for (final documentId in testNoteDocumentIds) {
        await _deleteNoteWithIndependentWriter(
          testUser!.uid,
          documentId,
        ).catchError((_) {});
      }
    }
    await testStorageObject
        ?.delete()
        .timeout(const Duration(seconds: 10))
        .catchError((_) {});
    await testUserDocument
        ?.delete()
        .timeout(const Duration(seconds: 10))
        .catchError((_) {});
    await FirebaseBackend.auth
        .signOut()
        .timeout(const Duration(seconds: 10))
        .catchError((_) {});
  });

  testWidgets(
    'hot restart can switch Emulator to Live and back without app contamination',
    (tester) async {
      final emulatorAppName = FirebaseBackend.app.name;
      final emulatorUserId = FirebaseBackend.auth.currentUser!.uid;
      final emulatorDocumentDirectory = await (await fileSystem()).documentDir;
      final preferences = await SharedPreferences.getInstance();
      const liveSyncTime = '2026-07-29T01:00:00.000Z';
      const emulatorSyncTime = '2026-07-29T02:00:00.000Z';
      await preferences.setString('last_synced_at', liveSyncTime);
      await preferences.setString(
        'firebase_emulator.last_synced_at',
        emulatorSyncTime,
      );
      await AppState.initializeFirebaseScope(preferences: preferences);
      expect(activeDatabaseName, 'better_keep_emulator.db');
      expect(AppState.lastSynced, DateTime.parse(emulatorSyncTime));

      // Reset only the Dart selection facade. Native Firebase apps remain
      // alive, matching the state retained by a Flutter hot restart.
      FirebaseBackend.resetForTesting();
      await FirebaseEmulatorConfig.useLiveFirebase();

      expect(FirebaseBackend.environment, FirebaseEnvironment.live);
      expect(FirebaseBackend.app.name, Firebase.app().name);
      expect(FirebaseBackend.auth.app.name, Firebase.app().name);
      expect(FirebaseBackend.firestore.app.name, Firebase.app().name);
      expect(FirebaseBackend.storage.app.name, Firebase.app().name);
      expect(FirebaseBackend.functions().app.name, Firebase.app().name);
      expect(FirebaseBackend.databaseId, FirebaseBackend.productionDatabaseId);
      expect(FirebaseBackend.localDataScope, FirebaseLocalDataScope.live);
      expect(activeDatabaseName, 'better_keep.db');
      await AppState.initializeFirebaseScope(preferences: preferences);
      expect(AppState.lastSynced, DateTime.parse(liveSyncTime));
      expect(
        await (await fileSystem()).documentDir,
        isNot(emulatorDocumentDirectory),
      );
      expect(
        FirebaseBackend.firestore.settings.host ?? '',
        isNot(contains('127.0.0.1')),
      );

      FirebaseBackend.resetForTesting();
      await FirebaseEmulatorConfig.connectToEmulators(
        physicalDeviceHost: const String.fromEnvironment('EMULATOR_HOST'),
      );

      expect(FirebaseBackend.environment, FirebaseEnvironment.emulator);
      expect(FirebaseBackend.app.name, emulatorAppName);
      expect(FirebaseBackend.app.name, isNot(Firebase.app().name));
      expect(FirebaseBackend.auth.currentUser?.uid, emulatorUserId);
      expect(FirebaseBackend.localDataScope, FirebaseLocalDataScope.emulator);
      expect(activeDatabaseName, 'better_keep_emulator.db');
      await AppState.initializeFirebaseScope(preferences: preferences);
      expect(AppState.lastSynced, DateTime.parse(emulatorSyncTime));
      expect(await (await fileSystem()).documentDir, emulatorDocumentDirectory);
      FirebaseBackend.lock();
      expect(FirebaseBackend.isLocked, isTrue);
      expect(FirebaseBackend.configureLive, throwsStateError);
      await preferences.remove('last_synced_at');
      await preferences.remove('firebase_emulator.last_synced_at');
    },
  );

  testWidgets(
    'physical Android downloads note documents and attachments through production repositories',
    (tester) async {
      testUserDocument = FirebaseBackend.firestore
          .collection('users')
          .doc(testUser!.uid);
      await testUserDocument!.set({
        'emulator_smoke_test': true,
        'emulator_smoke_test_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      final storedUser = await testUserDocument!.get(
        const GetOptions(source: Source.server),
      );
      expect(storedUser.data()?['emulator_smoke_test'], isTrue);

      final repository = NoteCloudRepository();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final legacyId = 'emulator-legacy-$suffix';
      final stampedId = 'emulator-stamped-$suffix';
      testNoteDocumentIds.addAll([legacyId, stampedId]);
      final initialStamp = DateTime.now().toUtc();

      // These writes intentionally bypass the client repository. The legacy
      // payload omits sync_committed_at, matching documents created by older
      // app versions.
      await _writeNoteWithIndependentWriter(
        testUser!.uid,
        legacyId,
        localId: suffix,
        title: 'Legacy emulator note',
      );
      await _writeNoteWithIndependentWriter(
        testUser!.uid,
        stampedId,
        localId: suffix + 1,
        title: 'Stamped emulator note',
        syncCommittedAt: initialStamp,
      );

      final boundarySnapshot = await repository.captureBootstrapBoundary(
        testUser!.uid,
      );
      expect(boundarySnapshot.docs, isNotEmpty);
      final boundaryDocument = boundarySnapshot.docs.single;
      final persistedCursor = CloudSyncCursor.fromDocument(
        boundaryDocument.data(),
        boundaryDocument.id,
      );
      expect(persistedCursor, isNotNull);

      final bootstrappedIds = <String>[];
      DocumentSnapshot<Map<String, dynamic>>? lastBootstrapDocument;
      while (true) {
        final page = await repository.fetchPage(
          uid: testUser!.uid,
          checkpoint: null,
          isBootstrap: true,
          pageSize: 1,
          lastDocument: lastBootstrapDocument,
        );
        if (page.docs.isEmpty) break;
        bootstrappedIds.addAll(page.docs.map((document) => document.id));
        lastBootstrapDocument = page.docs.last;
      }
      expect(bootstrappedIds.where((id) => id == legacyId), hasLength(1));
      expect(bootstrappedIds.where((id) => id == stampedId), hasLength(1));

      final updateStamp = initialStamp.add(const Duration(seconds: 10));
      final tombstoneStamp = updateStamp.add(const Duration(seconds: 10));
      await _writeNoteWithIndependentWriter(
        testUser!.uid,
        stampedId,
        localId: suffix + 1,
        title: 'Updated emulator note',
        syncCommittedAt: updateStamp,
      );
      await _writeNoteWithIndependentWriter(
        testUser!.uid,
        legacyId,
        localId: suffix,
        title: 'Legacy emulator note',
        deleted: true,
        syncCommittedAt: tombstoneStamp,
      );

      // Recreate the repository to model an app restart, then resume from the
      // persisted bootstrap cursor.
      final restartedRepository = NoteCloudRepository();
      final incrementalCheckpoint = CloudSyncCheckpoint(
        bootstrapped: true,
        cursor: persistedCursor,
      );
      final incrementalDocuments = <String, Map<String, dynamic>>{};
      DocumentSnapshot<Map<String, dynamic>>? lastIncrementalDocument;
      while (true) {
        final page = await restartedRepository.fetchPage(
          uid: testUser!.uid,
          checkpoint: incrementalCheckpoint,
          isBootstrap: false,
          pageSize: 1,
          lastDocument: lastIncrementalDocument,
        );
        if (page.docs.isEmpty) break;
        for (final document in page.docs) {
          expect(
            incrementalDocuments.containsKey(document.id),
            isFalse,
            reason: '${document.id} was recovered more than once',
          );
          incrementalDocuments[document.id] = document.data();
        }
        lastIncrementalDocument = page.docs.last;
      }
      expect(
        incrementalDocuments[stampedId]?['title'],
        'Updated emulator note',
      );
      expect(incrementalDocuments[legacyId]?['deleted'], isTrue);

      final attachmentNoteId = 'emulator-attachment-$suffix';
      testNoteDocumentIds.add(attachmentNoteId);
      final attachmentBytes = Uint8List.fromList(
        utf8.encode('better-keep-attachment-$suffix'),
      );
      testStorageObject = FirebaseBackend.storage.ref(
        'users/${testUser!.uid}/notes/$suffix/physical-attachment.txt',
      );
      await testStorageObject!.putData(
        attachmentBytes,
        SettableMetadata(contentType: 'text/plain'),
      );
      final emulatorDownloadUrl = await testStorageObject!.getDownloadURL();
      await _writeNoteWithIndependentWriter(
        testUser!.uid,
        attachmentNoteId,
        localId: suffix + 2,
        title: 'Attachment emulator note',
        syncCommittedAt: DateTime.now().toUtc(),
        attachmentUrl: emulatorDownloadUrl,
      );

      final attachmentDocument = await NoteCloudRepository()
          .notes(testUser!.uid)
          .doc(attachmentNoteId)
          .get(const GetOptions(source: Source.server));
      final attachmentData =
          attachmentDocument.data()!['attachments'] as List<dynamic>;
      final storedUrl =
          (attachmentData.single as Map<String, dynamic>)['data']['src']
              as String;
      final attachmentRepository = AttachmentStorageRepository();
      expect(await attachmentRepository.download(storedUrl), attachmentBytes);

      final storedUri = Uri.parse(storedUrl);
      final staleOriginUrl = storedUri
          .replace(host: 'unreachable.invalid')
          .toString();
      expect(
        await attachmentRepository.download(staleOriginUrl),
        attachmentBytes,
        reason:
            'The object path must be rebound to the configured emulator; '
            'the stale URL origin must never be contacted.',
      );
      debugPrint(
        'Physical Android note repository acceptance succeeded for '
        '${bootstrappedIds.length} bootstrapped documents and '
        '${incrementalDocuments.length} incremental documents, including '
        'a LAN-host attachment URL.',
      );
    },
  );

  testWidgets('physical Android can exercise Storage and Hosting emulators', (
    tester,
  ) async {
    testStorageObject = FirebaseBackend.storage.ref(
      'shares/${testUser!.uid}/emulator-smoke/attachments/ping.json',
    );
    await testStorageObject!.putString(
      jsonEncode({'ok': true}),
      format: PutStringFormat.raw,
      metadata: SettableMetadata(contentType: 'application/json'),
    );
    final storedBytes = await testStorageObject!.getData(1024);
    expect(utf8.decode(storedBytes!), contains('"ok":true'));

    final hostingResponse = await http.get(
      Uri.parse(
        '${FirebaseEmulatorConfig.endpoints.hostingBaseUrl}/s/emulator-smoke',
      ),
    );
    expect(hostingResponse.statusCode, 200);
    expect(hostingResponse.body, contains('Shared Note - Better Keep'));
  });
}

Uri _noteRestUri(String uid, String documentId) {
  final endpoint = FirebaseEmulatorConfig.endpoints;
  return Uri.parse(
    'http://${endpoint.host}:${FirebaseEmulatorEndpoints.firestorePort}'
    '/v1/projects/${DefaultFirebaseOptions.currentPlatform.projectId}'
    '/databases/(default)/documents/users/$uid/notes/$documentId',
  );
}

Future<void> _writeNoteWithIndependentWriter(
  String uid,
  String documentId, {
  required int localId,
  required String title,
  bool deleted = false,
  DateTime? syncCommittedAt,
  String? attachmentUrl,
}) async {
  final fields = <String, Object?>{
    'local_id': {'integerValue': localId.toString()},
    'title': {'stringValue': title},
    'updated_at': {'stringValue': DateTime.now().toUtc().toIso8601String()},
    'deleted': {'booleanValue': deleted},
    if (attachmentUrl != null)
      'attachments': {
        'arrayValue': {
          'values': [
            {
              'mapValue': {
                'fields': {
                  'type': {'stringValue': 'image'},
                  'data': {
                    'mapValue': {
                      'fields': {
                        'src': {'stringValue': attachmentUrl},
                      },
                    },
                  },
                },
              },
            },
          ],
        },
      },
    if (syncCommittedAt != null)
      cloudSyncCommittedAtField: {
        'timestampValue': syncCommittedAt.toUtc().toIso8601String(),
      },
  };
  final response = await http
      .patch(
        _noteRestUri(uid, documentId),
        headers: const {
          'Authorization': 'Bearer owner',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'fields': fields}),
      )
      .timeout(const Duration(seconds: 10));
  expect(response.statusCode, anyOf(200, 201), reason: response.body);
}

Future<void> _deleteNoteWithIndependentWriter(
  String uid,
  String documentId,
) async {
  final response = await http
      .delete(
        _noteRestUri(uid, documentId),
        headers: const {'Authorization': 'Bearer owner'},
      )
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 200 && response.statusCode != 404) {
    throw StateError(response.body);
  }
}
