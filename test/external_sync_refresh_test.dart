import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/external_sync/external_sync_progress.dart';
import 'package:better_keep/services/external_sync/external_sync_refresh.dart';
import 'package:better_keep/services/external_sync/library_sync_session.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/storage_connection_controller.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StorageConnection connection(String provider, {bool enabled = true}) =>
      StorageConnection(
        provider: provider,
        libraryId: 'test',
        accountLabel: 'test',
        encryptedCapability: 'test',
        generation: 1,
        enabled: enabled,
        state: 'ready',
      );
  test('restored provider prepares its first sync without a paused warning', () {
    final restored = connection('webdav');
    final progress = <String, SyncConnectionProgress>{};
    SyncProgress status() =>
        externalSyncProgress(connections: [restored], progress: progress);

    // Metadata arrives before the adapter and scheduler are ready.
    expect(status().phase, SyncPhase.preparing);
    expect(status().isActive, isTrue);
    progress[restored.replicaId] = const SyncConnectionProgress();
    expect(status().phase, SyncPhase.preparing);
    progress[restored.replicaId] = const SyncConnectionProgress(running: true);
    expect(status().phase, SyncPhase.syncing);
    progress[restored.replicaId] = SyncConnectionProgress(
      lastSuccess: DateTime.utc(2026),
    );
    expect(status().phase, SyncPhase.complete);

    // A first-sync failure must still be reported rather than hidden as setup.
    progress[restored.replicaId] = const SyncConnectionProgress(
      failure: SyncProviderFailureKind.unavailable,
    );
    expect(status().phase, SyncPhase.unavailable);
    progress[restored.replicaId] = const SyncConnectionProgress(
      pendingLocalChanges: true,
    );
    expect(status().phase, SyncPhase.preparing);
  });

  test('provider aggregation excludes paused targets and never conceals incomplete work', () {
    final values = [connection('google_drive'), connection('dropbox')];
    final progress = {
      'google_drive:1': SyncConnectionProgress(lastSuccess: DateTime.utc(2026)),
      'dropbox:1': const SyncConnectionProgress(
        failure: SyncProviderFailureKind.quotaExceeded,
      ),
    };
    SyncProgress status() =>
        externalSyncProgress(connections: values, progress: progress);
    expect(status().phase, SyncPhase.storageFull);
    progress['dropbox:1'] = const SyncConnectionProgress(
      failure: SyncProviderFailureKind.sharedSetupRequired,
    );
    expect(status().phase, SyncPhase.providerSetupRequired);
    expect(status().isFailure, false);
    progress['dropbox:1'] = const SyncConnectionProgress(
      running: true,
      failure: SyncProviderFailureKind.quotaExceeded,
    );
    expect(status().phase, SyncPhase.syncing);
    progress['dropbox:1'] = const SyncConnectionProgress(
      pendingLocalChanges: true,
    );
    expect(status().phase, SyncPhase.preparing);
    progress['dropbox:1'] = const SyncConnectionProgress(blockedEntities: 1);
    expect(status().phase, SyncPhase.failed);
    expect(status().failedCount, 1);
    values[1] = connection('dropbox', enabled: false);
    expect(status().phase, SyncPhase.complete);
  });

  test('manual queued edits stay quiet without hiding provider failures', () {
    final target = connection('google_drive');
    final progress = {
      target.replicaId: SyncConnectionProgress(
        lastSuccess: DateTime.utc(2026),
        pendingLocalChanges: true,
      ),
    };
    SyncProgress status() => externalSyncProgress(
      connections: [target],
      progress: progress,
      automatic: false,
    );
    expect(status().phase, SyncPhase.idle);
    expect(status().isSuccess, false);
    progress[target.replicaId] = const SyncConnectionProgress(
      pendingLocalChanges: true,
      failure: SyncProviderFailureKind.quotaExceeded,
    );
    expect(status().phase, SyncPhase.storageFull);
  });

  test('manual refresh yields when pending work makes no progress', () async {
    final session = _Session();
    session.connections.values['google_drive'] = connection('google_drive');
    var passes = 0;
    session.scheduler.run = () async {
      passes++;
      session.scheduler.values['google_drive:1'] = const SyncConnectionProgress(
        pendingLocalChanges: true,
      );
    };
    expect(
      await refreshExternalSession(
        session,
        maxPasses: 3,
        isCurrent: () => true,
        progress: () => const SyncProgress(SyncPhase.deferred),
      ),
      SyncRefreshOutcome.deferred,
    );
    expect(passes, 3);
  });

  test('manual refresh drains capture batches and completes only when all are acknowledged', () async {
    final session = _Session();
    session.connections.values['google_drive'] = connection('google_drive');
    var calls = 0;
    session.scheduler.run = () async {
      calls++;
      session.scheduler.values['google_drive:1'] = calls < 3
          ? const SyncConnectionProgress(pendingLocalChanges: true)
          : SyncConnectionProgress(lastSuccess: DateTime.utc(2026));
    };
    final result = await refreshExternalSession(
      session,
      isCurrent: () => true,
      progress: () => externalSyncProgress(
        connections: session.connections.values.values,
        progress: session.scheduler.values,
      ),
    );
    expect(result, SyncRefreshOutcome.complete);
    expect(calls, 3);
  });

  test(
    'a paused target during refresh cannot be reported as completed',
    () async {
      final session = _Session();
      session.connections.values['google_drive'] = connection('google_drive');
      session.scheduler.run = () async {
        session.connections.values.clear();
      };
      expect(
        await refreshExternalSession(
          session,
          isCurrent: () => true,
          progress: () => const SyncProgress(SyncPhase.complete),
        ),
        SyncRefreshOutcome.deferred,
      );
    },
  );

  test(
    'session replacement and provider failures stop the batch drain',
    () async {
      for (final failed in [false, true]) {
        final session = _Session();
        session.connections.values['google_drive'] = connection('google_drive');
        var current = true, calls = 0;
        session.scheduler.run = () async {
          calls++;
          if (!failed) current = false;
          session.scheduler.values['google_drive:1'] =
              const SyncConnectionProgress(
                pendingLocalChanges: true,
                failure: SyncProviderFailureKind.unavailable,
              );
        };
        expect(
          await refreshExternalSession(
            session,
            isCurrent: () => current,
            progress: () => const SyncProgress(SyncPhase.unavailable),
          ),
          failed ? SyncRefreshOutcome.unavailable : SyncRefreshOutcome.deferred,
        );
        expect(calls, 1);
      }
    },
  );
}

class _Session implements LibrarySyncSession {
  @override
  final _Connections connections = _Connections();
  @override
  final _Scheduler scheduler = _Scheduler();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connections implements StorageConnectionController {
  @override
  bool isSelected(String provider) => true;
  final values = <String, StorageConnection>{};
  @override
  Map<String, StorageConnection> get connections => values;
  @override
  Future<void> waitForMetadata() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Scheduler implements SyncScheduler {
  final values = <String, SyncConnectionProgress>{};
  late Future<void> Function() run;
  @override
  Map<String, SyncConnectionProgress> get progress => values;
  @override
  Future<void> syncNow({String? connectionId}) => run();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
