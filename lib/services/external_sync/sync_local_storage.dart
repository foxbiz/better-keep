import 'package:flutter/foundation.dart';

import '../cloud_session_recovery.dart';
import 'sync_provider_adapter.dart';
import 'sync_cancellation.dart';

/// A single source attachment could not be read. Other entities may proceed.
class SyncLocalSourceReadFailure extends SyncProviderFailure {
  const SyncLocalSourceReadFailure()
    : super(SyncProviderFailureKind.sourceRead);
}

/// Classifies only local file operations, never provider requests. Browser file
/// backends can reject with DOM exceptions or strings rather than IO exceptions.
/// Keep cancellation, integrity failures and programming errors distinct.
Future<T> runSyncLocalFileOperation<T>(
  Future<T> Function() operation, {
  bool sourceRead = false,
}) async {
  try {
    return await operation();
  } on CloudOperationCancelled {
    rethrow;
  } on SyncReplicaCancelled {
    rethrow;
  } on SyncProviderFailure {
    rethrow;
  } on FormatException {
    rethrow;
  } on Error {
    rethrow;
  } catch (error, stack) {
    if (kDebugMode) {
      // Do not use the file logger while storage itself is failing, or include
      // exception text/paths (browser rejections can be arbitrary strings).
      debugPrint('External sync local file failure: ${error.runtimeType}');
    }
    Error.throwWithStackTrace(
      sourceRead
          ? const SyncLocalSourceReadFailure()
          : const SyncProviderFailure(SyncProviderFailureKind.localStorage),
      stack,
    );
  }
}
