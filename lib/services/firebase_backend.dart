import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'firebase_emulator_host.dart';

/// Identifies the local persistence namespace paired with a Firebase backend.
enum FirebaseLocalDataScope {
  live,
  emulator;

  bool get isEmulator => this == FirebaseLocalDataScope.emulator;

  String get databaseName =>
      isEmulator ? 'better_keep_emulator.db' : 'better_keep.db';

  String get preferencePrefix => isEmulator ? 'firebase_emulator.' : '';

  String get secureStoragePrefix => isEmulator ? 'firebase_emulator.' : '';

  String get fileDirectoryName => isEmulator ? 'firebase_emulator' : '';

  String preferenceKey(String legacyKey) => '$preferencePrefix$legacyKey';

  String secureStorageKey(String legacyKey) => '$secureStoragePrefix$legacyKey';
}

/// Immutable, committed description of every Firebase service used by the app.
///
/// UI and diagnostics must read this object rather than preferences so the
/// displayed environment always matches the SDK instances in use.
@immutable
class FirebaseBackendConfiguration {
  const FirebaseBackendConfiguration({
    required this.environment,
    required this.app,
    required this.auth,
    required this.firestore,
    required this.functions,
    required this.storage,
    required this.databaseId,
    required this.localDataScope,
    required this.googleAuthMode,
    this.endpoints,
  });

  final FirebaseEnvironment environment;
  final FirebaseApp app;
  final FirebaseAuth auth;
  final FirebaseFirestore firestore;
  final FirebaseFunctions functions;
  final FirebaseStorage storage;
  final String databaseId;
  final FirebaseLocalDataScope localDataScope;
  final GoogleEmulatorAuthMode googleAuthMode;
  final FirebaseEmulatorEndpoints? endpoints;

  bool get usesEmulators => environment == FirebaseEnvironment.emulator;
  String get projectId => app.options.projectId;
  String get appName => app.name;
}

/// Owns the selected Firebase app and every service derived from it.
///
/// Live always uses the default app. Emulator routing is confined to a named
/// secondary app so a Flutter hot restart can safely select Live even when the
/// native process still retains an emulator-configured app.
class FirebaseBackend {
  FirebaseBackend._();

  static const String productionDatabaseId = 'better-keep';
  static const String emulatorDatabaseId = '(default)';
  static const String defaultFunctionsRegion = 'us-central1';
  static const String _emulatorAppPrefix = 'better-keep-emulator-';

  static FirebaseBackendConfiguration? _active;
  static bool _locked = false;
  static final Set<String> _discardedEmulatorAppNames = <String>{};
  static final Map<String, int> _emulatorRetryGeneration = <String, int>{};
  static String? _lastDiscardedEmulatorAppName;
  static final ValueNotifier<FirebaseBackendConfiguration?> configuration =
      ValueNotifier(null);

  static bool get isConfigured => _active != null;
  static bool get isLocked => _locked;

  static FirebaseBackendConfiguration get active {
    final value = _active;
    if (value == null) {
      throw StateError(
        'Firebase backend has not been selected. Configure Live or Emulator '
        'before accessing Firebase services.',
      );
    }
    return value;
  }

  static FirebaseApp get app => active.app;
  static FirebaseAuth get auth => active.auth;
  static FirebaseFirestore get firestore => active.firestore;
  static FirebaseStorage get storage => active.storage;
  static FirebaseEnvironment get environment => active.environment;
  static FirebaseLocalDataScope get localDataScope => active.localDataScope;
  static String get databaseId => active.databaseId;
  static String get projectId => active.projectId;
  static String? get emulatorHost => active.endpoints?.host;
  static int? get emulatorPort =>
      active.usesEmulators ? FirebaseEmulatorEndpoints.firestorePort : null;
  static String? get storageEmulatorHost => active.endpoints?.host;
  static int? get storageEmulatorPort =>
      active.usesEmulators ? FirebaseEmulatorEndpoints.storagePort : null;
  static bool get usesStorageEmulator => active.usesEmulators;

  static FirebaseFunctions functions({
    String region = defaultFunctionsRegion,
  }) => region == defaultFunctionsRegion
      ? active.functions
      : FirebaseFunctions.instanceFor(app: app, region: region);

  static FirebaseBackendConfiguration configureLive() {
    _ensureMutable();
    final liveApp = Firebase.app();
    final configuration = FirebaseBackendConfiguration(
      environment: FirebaseEnvironment.live,
      app: liveApp,
      auth: FirebaseAuth.instanceFor(app: liveApp),
      firestore: FirebaseFirestore.instanceFor(
        app: liveApp,
        databaseId: productionDatabaseId,
      ),
      functions: FirebaseFunctions.instanceFor(
        app: liveApp,
        region: defaultFunctionsRegion,
      ),
      storage: FirebaseStorage.instanceFor(app: liveApp),
      databaseId: productionDatabaseId,
      localDataScope: FirebaseLocalDataScope.live,
      googleAuthMode: GoogleEmulatorAuthMode.mock,
    );
    return _commit(configuration);
  }

  static Future<FirebaseBackendConfiguration> configureEmulator({
    required FirebaseEmulatorEndpoints endpoints,
    required GoogleEmulatorAuthMode googleAuthMode,
    String? preferredAppName,
  }) async {
    _ensureMutable();

    final baseAppName = emulatorAppNameFor(endpoints.host);
    final canUsePreferred =
        preferredAppName != null &&
        preferredAppName.startsWith(baseAppName) &&
        !_discardedEmulatorAppNames.contains(preferredAppName);
    final appName = canUsePreferred
        ? preferredAppName
        : _nextEmulatorAppName(baseAppName);
    final existingApp = _findApp(appName);
    final emulatorApp =
        existingApp ??
        await Firebase.initializeApp(
          name: appName,
          options: Firebase.app().options,
        );

    final auth = FirebaseAuth.instanceFor(app: emulatorApp);
    final firestore = FirebaseFirestore.instanceFor(
      app: emulatorApp,
      databaseId: emulatorDatabaseId,
    );
    final storage = FirebaseStorage.instanceFor(app: emulatorApp);
    final functions = FirebaseFunctions.instanceFor(
      app: emulatorApp,
      region: defaultFunctionsRegion,
    );

    try {
      await auth.useAuthEmulator(
        endpoints.host,
        FirebaseEmulatorEndpoints.authPort,
      );
      firestore.useFirestoreEmulator(
        endpoints.host,
        FirebaseEmulatorEndpoints.firestorePort,
        automaticHostMapping: false,
      );
      firestore.settings = firestore.settings.copyWith(
        persistenceEnabled: false,
      );
      functions.useFunctionsEmulator(
        endpoints.host,
        FirebaseEmulatorEndpoints.functionsPort,
      );
      await storage.useStorageEmulator(
        endpoints.host,
        FirebaseEmulatorEndpoints.storagePort,
        automaticHostMapping: false,
      );
    } catch (error, stack) {
      _discardedEmulatorAppNames.add(appName);
      _lastDiscardedEmulatorAppName = appName;
      _emulatorRetryGeneration[baseAppName] =
          (_emulatorRetryGeneration[baseAppName] ?? 0) + 1;
      try {
        await emulatorApp.delete();
      } catch (cleanupError) {
        debugPrint(
          'Firebase emulator app cleanup failed for $appName: $cleanupError',
        );
      }
      Error.throwWithStackTrace(error, stack);
    }

    return _commit(
      FirebaseBackendConfiguration(
        environment: FirebaseEnvironment.emulator,
        app: emulatorApp,
        auth: auth,
        firestore: firestore,
        functions: functions,
        storage: storage,
        databaseId: emulatorDatabaseId,
        localDataScope: FirebaseLocalDataScope.emulator,
        googleAuthMode: googleAuthMode,
        endpoints: endpoints,
      ),
    );
  }

  /// Prevents changing the selected backend after dependent services start.
  static void lock() {
    active;
    _locked = true;
  }

  @visibleForTesting
  static String emulatorAppNameFor(String host) {
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '$host:${FirebaseEmulatorEndpoints.authPort}:'
            '${FirebaseEmulatorEndpoints.firestorePort}:'
            '${FirebaseEmulatorEndpoints.functionsPort}:'
            '${FirebaseEmulatorEndpoints.storagePort}',
          ),
        )
        .toString()
        .substring(0, 12);
    return '$_emulatorAppPrefix$fingerprint';
  }

  static FirebaseApp? _findApp(String name) {
    for (final app in Firebase.apps) {
      if (app.name == name) return app;
    }
    return null;
  }

  static String _nextEmulatorAppName(String baseName) {
    var generation = _emulatorRetryGeneration[baseName] ?? 0;
    var candidate = generation == 0 ? baseName : '$baseName-r$generation';
    while (_discardedEmulatorAppNames.contains(candidate)) {
      generation++;
      candidate = '$baseName-r$generation';
    }
    _emulatorRetryGeneration[baseName] = generation;
    return candidate;
  }

  static String? takeLastDiscardedEmulatorAppName() {
    final value = _lastDiscardedEmulatorAppName;
    _lastDiscardedEmulatorAppName = null;
    return value;
  }

  static FirebaseBackendConfiguration _commit(
    FirebaseBackendConfiguration value,
  ) {
    _active = value;
    configuration.value = value;
    return value;
  }

  static void _ensureMutable() {
    if (_locked) {
      throw StateError(
        'Firebase backend is locked for this application startup. Restart '
        'before selecting another environment.',
      );
    }
    if (_active != null) {
      throw StateError(
        'Firebase backend has already been selected for this Dart startup.',
      );
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _active = null;
    _locked = false;
    _discardedEmulatorAppNames.clear();
    _emulatorRetryGeneration.clear();
    _lastDiscardedEmulatorAppName = null;
    configuration.value = null;
  }
}
