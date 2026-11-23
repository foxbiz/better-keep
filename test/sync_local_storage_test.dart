import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/external_sync/sync_local_storage.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_replica_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

void main() {
  test(
    'outgoing source reads use sourceRead without leaking the cause',
    () async {
      await expectLater(
        runSyncLocalFileOperation(
          () async => throw Exception('/private/file'),
          sourceRead: true,
        ),
        throwsA(
          isA<SyncLocalSourceReadFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.sourceRead,
          ),
        ),
      );
    },
  );
  test(
    'local browser string failures are sanitized and retain the stack',
    () async {
      final messages = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = originalPrint);
      final stack = StackTrace.fromString('local-file-stack');
      try {
        await runSyncLocalFileOperation<void>(
          () async =>
              Error.throwWithStackTrace('private/path is not a file', stack),
        );
        fail('Expected storage failure');
      } catch (error, actualStack) {
        expect(
          error,
          isA<SyncProviderFailure>().having(
            (error) => error.kind,
            'kind',
            SyncProviderFailureKind.localStorage,
          ),
        );
        expect(error.toString(), isNot(contains('private/path')));
        expect(actualStack.toString(), contains('local-file-stack'));
        expect(messages, ['External sync local file failure: String']);
      }
    },
  );
  test(
    'local boundary preserves cancellation, integrity and programming errors',
    () async {
      for (final error in [
        const CloudOperationCancelled(),
        const SyncReplicaCancelled(),
        const FormatException('invalid object'),
        StateError('programming error'),
        const SyncProviderFailure(SyncProviderFailureKind.corruptData),
      ]) {
        await expectLater(
          runSyncLocalFileOperation(() async => throw error),
          throwsA(same(error)),
        );
      }
    },
  );
}
