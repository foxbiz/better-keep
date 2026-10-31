import '../../models/base_model.dart';
import '../../models/app_progress.dart';
import '../cloud_session_recovery.dart';
import 'external_sync_progress.dart';
import 'external_sync_refresh.dart';

import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/label.dart';
import '../../models/note.dart';
import '../../state.dart';
import '../auth_service.dart';
import '../attachment_storage_repository.dart';
import '../e2ee/e2ee_service.dart';
import '../e2ee/secure_storage.dart';
import '../file_system.dart';
import '../firebase_backend.dart';
import '../note_sort_service.dart';
import 'library_sync_lifecycle.dart';
import 'library_sync_session.dart';
import 'firebase_attachment_reader.dart';
import 'replica_model_notifier.dart';
import 'storage_connection_controller.dart';
import 'sync_cipher.dart';
import 'sync_change_signals.dart';
import '../monetization/plan_service.dart';
import 'sync_provider_adapter.dart';
import 'sync_replica_engine.dart';

/// App binding for opt-in external providers. Firebase identity and approved
/// encryption keys are required; Firebase transport readiness and Pro are not.
class ExternalSyncService extends ChangeNotifier {
  ExternalSyncService._();
  static final instance = ExternalSyncService._();

  final _lifecycle = LibrarySyncLifecycle();
  StreamSubscription<dynamic>? _auth;
  bool _initialized = false, _suspended = false, _foreground = true;

  LibrarySyncSession? get session => _lifecycle.session;
  bool get initializing => _lifecycle.initializing;
  SyncProviderFailureKind? get failure => _lifecycle.failure;

  SyncProgress get progress {
    if (!_initialized || _suspended) return SyncProgress.idle;
    final current = session;
    if (current == null) {
      if (failure != null) return const SyncProgress(SyncPhase.unavailable);
      return initializing
          ? const SyncProgress(SyncPhase.preparing)
          : SyncProgress.idle;
    }
    if (!current.isCurrent) return SyncProgress.idle;
    final connections = current.connections;
    return externalSyncProgress(
      automatic: PlanService.instance.entitlements.automaticExternalSync,
      connections: connections.connections.values.where(
        (c) => connections.isSelected(c.provider),
      ),
      progress: current.scheduler.progress,
      errors: connections.errors,
      metadataReady: connections.hasMetadata,
      metadataFailure:
          connections.metadataFailure ??
          (connections.hasInvalidMetadata
              ? SyncProviderFailureKind.corruptData
              : null),
      blockedProviders: {
        for (final provider in StorageConnectionController.providers)
          if (connections.needsKeyRecovery(provider) ||
              connections.isLocallyStopped(provider) ||
              connections.isBusy(provider))
            provider,
      },
    );
  }

  /// A null result means there are no external destinations to refresh.
  Future<SyncRefreshOutcome?> refreshWithOutcome() async {
    if (!_initialized) return null;
    if (_suspended || !_foreground) return SyncRefreshOutcome.deferred;
    LibrarySyncSession? captured;
    try {
      await _refresh();
      final current = captured = session;
      if (current == null) {
        return failure == null
            ? SyncRefreshOutcome.deferred
            : SyncRefreshOutcome.unavailable;
      }
      return await refreshExternalSession(
        current,
        isCurrent: () =>
            identical(session, current) &&
            current.isCurrent &&
            !_suspended &&
            _foreground,
        progress: () => progress,
      );
    } on SyncProviderFailure catch (error) {
      return error.kind == SyncProviderFailureKind.unavailable ||
              error.kind == SyncProviderFailureKind.rateLimited
          ? SyncRefreshOutcome.unavailable
          : SyncRefreshOutcome.failed;
    } on TimeoutException {
      return SyncRefreshOutcome.unavailable;
    } catch (_) {
      return captured == null ||
              !identical(captured, session) ||
              !captured.isCurrent
          ? SyncRefreshOutcome.deferred
          : SyncRefreshOutcome.failed;
    }
  }

  void init() {
    if (_initialized || !FirebaseBackend.isConfigured) return;
    _initialized = true;
    _lifecycle.addListener(notifyListeners);
    _auth = AuthService.userStream.listen(
      (_) => _refreshInBackground(),
      onError: (Object _) => _refreshInBackground(),
    );
    AuthService.sessionInvalid.addListener(_refreshInBackground);
    AuthService.postSignInState.addListener(_refreshInBackground);
    E2EEService.instance.status.addListener(_refreshInBackground);
    E2EEService.instance.deviceManager.hasUMK.addListener(_refreshInBackground);
    PlanService.instance.entitlementsNotifier.addListener(_entitlementsChanged);
    AppState.subscribe('db', _databaseChanged);
    Note.on('changed', _noteChanged);
    Label.on('changed', _labelChanged);
    NoteSortService().snapshots.addListener(_persistedChanged);
    _refreshInBackground();
  }

  bool get _eligible =>
      _initialized &&
      !_suspended &&
      !AuthService.sessionInvalid.value &&
      AuthService.canRestoreLocalSession &&
      E2EEService.instance.isCryptoReady &&
      AppState.get('db') is Database;

  void _entitlementsChanged() => session?.setAutomatic(
    PlanService.instance.entitlements.automaticExternalSync,
  );

  void _databaseChanged(Object? _) => _refreshInBackground();
  void _noteChanged(NoteEvent event) {
    if (event.origin == ModelChangeOrigin.local) {
      _localChanged();
    } else {
      _persistedChanged();
    }
  }

  void _labelChanged(LabelEvent event) {
    if (event.origin == ModelChangeOrigin.local) {
      _localChanged();
    } else {
      _persistedChanged();
    }
  }

  void _localChanged() => session?.localChanged();
  void _persistedChanged() => session?.persistedChanged();

  void _refreshInBackground() {
    // The lifecycle exposes a sanitized failure and permits a later retry.
    unawaited(_refresh().catchError((Object _) {}));
  }

  Future<void> _refresh() {
    if (!_eligible) return _lifecycle.stop();
    final uid = AuthService.currentUser!.uid;
    final database = AppState.db;
    final key = E2EEService.instance.deviceManager.getUMK();
    if (key == null || key.length != 32) return _lifecycle.stop();
    final fingerprint = sha256.convert(key).toString();
    final accountCurrent = AuthService.captureSession();
    return _lifecycle.replace((uid, database, fingerprint), (
      generationCurrent,
    ) async {
      bool current() {
        if (!generationCurrent() ||
            !_eligible ||
            !accountCurrent() ||
            !identical(AppState.get('db'), database)) {
          return false;
        }
        final liveKey = E2EEService.instance.deviceManager.getUMK();
        return liveKey != null &&
            sha256.convert(liveKey).toString() == fingerprint;
      }

      void guard() {
        if (!current()) throw const SyncReplicaCancelled();
      }

      guard();
      final copy = Uint8List.fromList(
        E2EEService.instance.deviceManager.getUMK()!,
      );
      SyncCipher? cipher;
      try {
        cipher = await SyncCipher.create(uid, copy);
        guard();
        final deviceId = await E2EESecureStorage.instance.getDeviceId();
        guard();
        if (deviceId == null || deviceId.isEmpty) {
          throw StateError('Approved device identity is unavailable');
        }
        final files = await fileSystem();
        final documentRoot = await files.documentDir;
        final cacheRoot = await files.cacheDir;
        guard();
        final notifier = ReplicaModelNotifier(
          database: database,
          isCurrent: current,
        );
        final sessionCipher = cipher;
        return LibrarySyncSession(
          uid: uid,
          database: database,
          files: files,
          documentRoot: documentRoot,
          cacheRoot: cacheRoot,
          cipher: sessionCipher,
          isCurrent: current,
          foreground: _foreground,
          automatic: PlanService.instance.entitlements.automaticExternalSync,
          createSignals: (store, onRemoteChange) => SyncChangeSignals.firebase(
            uid: uid,
            deviceId: deviceId,
            store: store,
            isCurrent: current,
            onRemoteChange: onRemoteChange,
          ),
          onApplied: notifier.apply,
          createAttachmentReader: (readLocal, sessionCurrent) =>
              FirebaseAttachmentReader(
                uid: uid,
                database: database,
                storage: AttachmentStorageRepository(),
                readLocal: readLocal,
                readKey: E2EEService.instance.deviceManager.getUMK,
                isCurrent: sessionCurrent,
              ).read,
          createConnections: (sessionCurrent) =>
              StorageConnectionController.firebase(
                uid: uid,
                cipher: sessionCipher,
                deviceId: deviceId,
                isCurrent: sessionCurrent,
              ),
        );
      } catch (_) {
        cipher?.dispose();
        rethrow;
      } finally {
        copy.fillRange(0, copy.length, 0);
      }
    });
  }

  Future<void> resume() async {
    _suspended = false;
    init();
    await _refresh().catchError((Object _) {});
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    session?.setForeground(foreground);
    if (foreground && _initialized) _refreshInBackground();
  }

  /// Must finish before logout closes the database or removes attachment files.
  Future<void> stop() {
    _suspended = true;
    return _lifecycle.stop();
  }

  @override
  void dispose() {
    _suspended = true;
    _initialized = false;
    unawaited(_auth?.cancel());
    PlanService.instance.entitlementsNotifier.removeListener(
      _entitlementsChanged,
    );
    AuthService.sessionInvalid.removeListener(_refreshInBackground);
    AuthService.postSignInState.removeListener(_refreshInBackground);
    E2EEService.instance.status.removeListener(_refreshInBackground);
    E2EEService.instance.deviceManager.hasUMK.removeListener(
      _refreshInBackground,
    );
    AppState.unsubscribe('db', _databaseChanged);
    Note.off('changed', _noteChanged);
    Label.off('changed', _labelChanged);
    NoteSortService().snapshots.removeListener(_persistedChanged);
    _lifecycle.removeListener(notifyListeners);
    _lifecycle.dispose();
    super.dispose();
  }
}
