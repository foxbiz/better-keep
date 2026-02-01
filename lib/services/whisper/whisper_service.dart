/// Whisper service barrel file with conditional exports.
///
/// On web, this exports a stub that returns `isAvailable => false`.
/// On native platforms (iOS, Android, macOS), this exports the full implementation.
///
/// This is necessary because `whisper_flutter_new` uses `dart:ffi` which
/// doesn't exist on web and causes compile-time errors.
library;

export 'whisper_service_stub.dart'
    if (dart.library.io) 'whisper_service_native.dart';
