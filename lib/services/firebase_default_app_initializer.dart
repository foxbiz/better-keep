import 'package:firebase_core/firebase_core.dart';

/// Runs one asynchronous default-app initialization at a time and recovers
/// when the platform reports that the app was initialized by another isolate.
class SingleFlightDefaultAppInitializer<T> {
  Future<T>? _inFlight;

  Future<T> initialize({
    required Iterable<T> Function() currentApps,
    required bool Function(T app) isDefaultApp,
    required Future<T> Function() createApp,
    required bool Function(Object error) isDuplicateAppError,
    required T Function() currentDefaultApp,
  }) {
    for (final app in currentApps()) {
      if (isDefaultApp(app)) return Future<T>.value(app);
    }

    return _inFlight ??= _initialize(
      createApp: createApp,
      isDuplicateAppError: isDuplicateAppError,
      currentDefaultApp: currentDefaultApp,
    ).whenComplete(() => _inFlight = null);
  }

  Future<T> _initialize({
    required Future<T> Function() createApp,
    required bool Function(Object error) isDuplicateAppError,
    required T Function() currentDefaultApp,
  }) async {
    try {
      return await createApp();
    } catch (error) {
      if (!isDuplicateAppError(error)) rethrow;
      return currentDefaultApp();
    }
  }
}

final SingleFlightDefaultAppInitializer<FirebaseApp>
_defaultFirebaseAppInitializer =
    SingleFlightDefaultAppInitializer<FirebaseApp>();

/// Initializes Firebase's default app before services that may start a
/// background isolate. This is safe across repeated calls and hot restarts.
Future<FirebaseApp> initializeDefaultFirebaseApp(FirebaseOptions options) =>
    _defaultFirebaseAppInitializer.initialize(
      currentApps: () => Firebase.apps,
      isDefaultApp: (app) => app.name == defaultFirebaseAppName,
      createApp: () => Firebase.initializeApp(options: options),
      isDuplicateAppError: (error) =>
          error is FirebaseException &&
          error.plugin == 'core' &&
          error.code == 'duplicate-app',
      currentDefaultApp: Firebase.app,
    );
