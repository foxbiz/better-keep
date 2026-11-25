// Release-build entry point for the isolated Chromium acceptance test.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/app.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/web_release.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/authenticated_startup_routing.dart';
import 'package:better_keep/utils/db_init_web.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

const noteId = 7308;
const editTitle = 'Edited while offline';
const options = FirebaseOptions(
  apiKey: 'emulator-only',
  appId: '1:123:web:offline',
  messagingSenderId: '123',
  projectId: 'demo-better-keep-pairing',
  storageBucket: 'demo-better-keep-pairing.appspot.com',
);

void report(String stage) =>
    web.document.documentElement!.setAttribute('data-offline-test', stage);

Future<void> until(FutureOr<bool> Function() done) async {
  await Future.doWhile(() async {
    if (await done()) return false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return true;
  }).timeout(const Duration(seconds: 80));
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    require(web.window.location.hostname == '127.0.0.1', 'Loopback required');
    if (isBetaWebBuild) SharedPreferences.setPrefix('flutter.beta.');
    await Firebase.initializeApp(options: options);
    const channel = isBetaWebBuild ? 'beta' : 'stable';
    const name = 'better-keep-emulator-offline-$channel';
    web.window.callMethodVarArgs('betterKeepPrepareAuthEmulator'.toJS, [
      name.toJS,
      {
        for (final key in [
          'apiKey',
          'authDomain',
          'databaseURL',
          'projectId',
          'storageBucket',
          'messagingSenderId',
          'measurementId',
          'appId',
        ])
          key: options.asMap[key],
      }.jsify(),
      '127.0.0.1'.toJS,
      19099.toJS,
    ]);
    final app = await Firebase.initializeApp(name: name, options: options);
    final auth = FirebaseAuth.instanceFor(app: app);
    await auth.useAuthEmulator('127.0.0.1', 19099);
    final db = FirebaseFirestore.instanceFor(app: app);
    db.useFirestoreEmulator('127.0.0.1', 18080);
    FirebaseBackend.configureForTesting(
      FirebaseBackendConfiguration(
        environment: FirebaseEnvironment.emulator,
        app: app,
        auth: auth,
        firestore: db,
        functions: FirebaseFunctions.instanceFor(app: app),
        storage: FirebaseStorage.instanceFor(app: app),
        databaseId: '(default)',
        localDataScope: FirebaseLocalDataScope.emulator,
        googleAuthMode: GoogleEmulatorAuthMode.mock,
      ),
    );
    runApp(const SizedBox.shrink());
    final mode = web.window.localStorage.getItem('qa.step.$channel') ?? 'setup';
    var user = await auth.authStateChanges().first;
    if (mode == 'setup') {
      require(user == null, 'Expected a fresh profile');
      user = (await auth.createUserWithEmailAndPassword(
        email: 'offline-${DateTime.now().microsecondsSinceEpoch}@example.test',
        password: 'Disposable-Offline-Fixture!',
      )).user;
    }
    final uid = user!.uid;
    web.document.documentElement!.setAttribute('data-qa-user', uid);
    if (mode == 'verify-email') {
      await user.reload();
      await auth.currentUser!.getIdToken(true);
      require(auth.currentUser!.emailVerified, 'Fixture email unverified');
      report('verified');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (mode == 'setup') {
      await prefs.setString(
        FirebaseLocalDataScope.emulator.preferenceKey('user_uid'),
        uid,
      );
    }
    initializeDb();
    await AppState.init(prefs: prefs);
    await AuthService.init(prefs: prefs, deferLocalRestore: true);
    await initDatabase();
    await PlanService.instance.init();
    final service = E2EEService.instance;
    final store = E2EESecureStorage.instance;
    if (mode == 'setup') {
      await service.setupE2EE();
      await Note(
        id: noteId,
        title: 'Downloaded QA note',
        content: '[]',
      ).save(false);
      web.document.documentElement!.setAttribute(
        'data-qa-device',
        (await store.getDeviceId())!,
      );
      report('seeded');
      return;
    }
    final localAccess = await service.preloadCachedStatus();
    if (mode == 'revoked') {
      require(
        !localAccess && !service.canAccessLocalNotes && !service.isCryptoReady,
        'Revoked browser reopened the library',
      );
      require(
        await store.getCachedDeviceStatus() == 'revoked',
        'Lost revocation',
      );
      report('locked');
      return;
    }
    require(
      localAccess && !service.isCryptoReady,
      'Local startup must not need a cloud key',
    );
    await AuthService.initializeCurrentUserServices();
    require(
      resolveAuthenticatedStartupRoute(
            postSignInState: AuthService.postSignInState.value,
            e2eeStatus: service.status.value,
            localState: service.localState,
          ) ==
          AuthenticatedStartupRoute.home,
      'Expected Home',
    );
    final note = (await Note.findById(noteId))!;
    if (mode == 'edit') {
      require(note.title == 'Downloaded QA note', 'Missing local note');
      note.title = editTitle;
      await note.save();
      require(
        (await NoteSyncTrack.getByLocalId(noteId))?.status ==
            SyncStatus.pending,
        'Edit not queued',
      );
    }
    require(note.title == editTitle, 'Offline edit lost');
    SemanticsBinding.instance.ensureSemantics();
    runApp(const App());
    report('home');
    await until(() => AuthService.canSyncCloud && service.isCryptoReady);
    if (mode == 'edit') {
      await until(
        () async =>
            (await NoteSyncTrack.getByLocalId(noteId))?.status ==
            SyncStatus.synced,
      );
      final track = (await NoteSyncTrack.getByLocalId(noteId))!;
      final snapshot = await db
          .doc('users/$uid/notes/${track.remoteId}')
          .get(const GetOptions(source: Source.server));
      final restored = await service.noteEncryption.decryptNoteFromFirestore(
        snapshot.data()!,
      );
      require(restored?.title == editTitle, 'Server edit did not round trip');
      report('uploaded');
    } else {
      report('online');
      await until(() => service.status.value == E2EEStatus.revoked);
      await until(() => !store.hasRememberedBrowserIdentity);
      report('revocation-received');
    }
  } catch (error) {
    final recovery = AuthService.cloudRecovery;
    report(
      'failed: $error (online=${web.window.navigator.onLine}, network=${recovery.networkAvailable}, cloud=${recovery.state.value.name}, crypto=${E2EEService.instance.isCryptoReady})',
    );
  }
}
