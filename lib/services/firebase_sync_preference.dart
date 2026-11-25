import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'firebase_backend.dart';
import 'monetization/entitlements.dart';
import 'monetization/plan_service.dart';
import 'monetization/subscription_status.dart';
import 'monetization/user_plan.dart';

class FirebaseSyncSelection {
  const FirebaseSyncSelection(
    this.enabled, {
    required this.confirmed,
    this.revision = 0,
    this.provider,
    this.firebaseDownloads,
  });
  final bool enabled;
  final bool confirmed;
  final int revision;
  final String? provider;
  final bool? firebaseDownloads;
  bool get downloadsFirebase =>
      selectedProvider == 'firebase' ||
      (selectedProvider == 'none' && firebaseDownloads != false);
  String get selectedProvider => provider ?? (enabled ? 'firebase' : 'none');

  static FirebaseSyncSelection fromDocument(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data();
    final confirmed =
        !snapshot.metadata.isFromCache && !snapshot.metadata.hasPendingWrites;
    if (data == null) return FirebaseSyncSelection(true, confirmed: confirmed);
    final enabled = data['enabled'], updatedAt = data['updatedAt'];
    final provider = data['provider'];
    final firebaseDownloads = data['firebaseDownloads'];
    if (data.containsKey('firebaseDownloads') && firebaseDownloads is! bool) {
      throw const FormatException('Invalid Firebase download preference');
    }
    if (provider != null &&
        (!FirebaseSyncPreference.providers.contains(provider) ||
            enabled != (provider == 'firebase'))) {
      throw const FormatException('Invalid sync provider');
    }
    if (enabled is! bool || (updatedAt is! Timestamp && confirmed)) {
      throw const FormatException('Invalid Firebase sync preference');
    }
    return FirebaseSyncSelection(
      enabled,
      confirmed: confirmed,
      revision: updatedAt is Timestamp ? updatedAt.microsecondsSinceEpoch : 0,
      provider: provider as String?,
      firebaseDownloads: firebaseDownloads as bool?,
    );
  }
}

/// Account-wide library selection, filtered by local subscription eligibility.
/// A new session waits for an authoritative preference before transferring notes.
class FirebaseSyncPreference extends ChangeNotifier {
  FirebaseSyncPreference({
    required this.currentUid,
    required this.watch,
    required this.write,
    this.writeProvider,
    this.entitlements,
    this.disableFirebase,
    this.enableFirebaseDownloads,
    this.confirmedLiteAccount,
  }) {
    confirmedLiteAccount?.addListener(_entitlementsChanged);
    entitlements?.addListener(_entitlementsChanged);
  }
  static const providers = [
    'firebase',
    'google_drive',
    'dropbox',
    'nextcloud',
    'webdav',
    'none',
  ];
  static final _production = FirebaseSyncPreference(
    entitlements: PlanService.instance.entitlementsNotifier,
    confirmedLiteAccount: PlanService.instance.confirmedLiteAccount,
    currentUid: () => FirebaseBackend.isConfigured
        ? FirebaseBackend.auth.currentUser?.uid
        : null,
    watch: (uid) =>
        _document(uid)
            .snapshots(includeMetadataChanges: true)
            .map(FirebaseSyncSelection.fromDocument),
    disableFirebase: _disableFirebase,
    enableFirebaseDownloads: (uid) =>
        _writeProvider(uid, 'none', restoreDownloads: true),
    writeProvider: _writeProvider,
    write: (uid, enabled) => _writeProvider(uid, enabled ? 'firebase' : 'none'),
  );
  static Future<FirebaseSyncSelection> _writeProvider(
    String uid,
    String provider, {
    bool restoreDownloads = false,
  }) async {
    final ref = _document(uid);
    await FirebaseBackend.firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      var downloadsFirebase = false;
      try {
        downloadsFirebase = FirebaseSyncSelection.fromDocument(snapshot)
            .downloadsFirebase;
      } on FormatException {
        // An explicit selection can repair malformed settings. Unknown history
        // stays detached; only an explicit cloud choice restores downloads.
      }
      transaction.set(ref, {
        'enabled': provider == 'firebase',
        'provider': provider,
        'firebaseDownloads':
            provider == 'firebase' ||
            (provider == 'none' && (restoreDownloads || downloadsFirebase)),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    return FirebaseSyncSelection.fromDocument(
      await ref.get(const GetOptions(source: Source.server)),
    );
  }

  static Future<FirebaseSyncSelection> _disableFirebase(String uid) async {
    final ref = _document(uid);
    await FirebaseBackend.firestore.runTransaction((transaction) async {
      final current = FirebaseSyncSelection.fromDocument(
        await transaction.get(ref),
      );
      // Another device may have selected external storage while this plan
      // update was arriving. Never replace that newer choice with Sync off.
      if (current.selectedProvider != 'firebase') return;
      final subscription = await transaction.get(
        FirebaseBackend.firestore
            .collection('users')
            .doc(uid)
            .collection('subscription')
            .doc('status'),
      );
      // Recheck within the transaction: a Pro renewal can race this disable.
      if (SubscriptionStatus.fromFirestore(subscription.data()).effectivePlan !=
          UserPlan.lite) {
        return;
      }
      transaction.set(ref, {
        'enabled': false,
        'provider': 'none',
        'firebaseDownloads': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    return FirebaseSyncSelection.fromDocument(
      await ref.get(const GetOptions(source: Source.server)),
    );
  }

  @visibleForTesting
  static FirebaseSyncPreference? instanceOverride;
  static FirebaseSyncPreference get instance => instanceOverride ?? _production;
  static DocumentReference<Map<String, dynamic>> _document(String uid) =>
      FirebaseBackend.firestore
          .collection('users')
          .doc(uid)
          .collection('sync_settings')
          .doc('firebase');

  final ValueListenable<Entitlements>? entitlements;
  final ValueListenable<String?>? confirmedLiteAccount;
  final Future<FirebaseSyncSelection> Function(String uid)? disableFirebase;
  final Future<FirebaseSyncSelection> Function(String uid)?
  enableFirebaseDownloads;
  final String? Function() currentUid;
  final Stream<FirebaseSyncSelection> Function(String uid) watch;
  final Future<FirebaseSyncSelection> Function(String uid, bool enabled) write;
  final Future<FirebaseSyncSelection> Function(String uid, String provider)?
  writeProvider;
  StreamSubscription<String?>? _auth;
  StreamSubscription<FirebaseSyncSelection>? _subscription;
  String? _uid;
  String? _requested;
  FirebaseSyncSelection? _selection;
  bool _busy = false,
      _localStop = false,
      _failed = false,
      _disposed = false,
      _cachePaused = false;
  int _generation = 0;
  bool _requestedConditional = false;
  bool _requestedDownloads = false;
  bool _automaticPauseRejected = false;

  // This controls built-in upload selection, not access to existing cloud notes.
  // Free and Lite retain downloads; Lite durably pauses built-in uploads.
  bool get firebaseAvailable {
    final access = entitlements?.value;
    return access == null ||
        access.realtimeCloudSync ||
        !access.automaticExternalSync;
  }

  void _entitlementsChanged() {
    if (_disposed) return;
    _automaticPauseRejected = false;
    notifyListeners();
    _reconcileUnavailableFirebase();
  }

  void _reconcileUnavailableFirebase() {
    if (_disposed ||
        _busy ||
        _failed ||
        _automaticPauseRejected ||
        accountId == null ||
        confirmedLiteAccount?.value != accountId ||
        firebaseAvailable ||
        _selection?.confirmed != true ||
        _selection?.selectedProvider != 'firebase') {
      return;
    }
    unawaited(
      _selectProvider('none', conditional: true).catchError((Object _) {}),
    );
  }

  bool get _firebaseSuppressed =>
      !firebaseAvailable || (_requested == 'none' && _requestedConditional);

  String? get accountId => _uid == currentUid() ? _uid : null;
  bool? get enabled => accountId == null
      ? null
      : _cachePaused
      ? false
      : _firebaseSuppressed && _selection?.enabled == true
      ? false
      : _selection?.enabled;
  String? get selectedProvider =>
      accountId == null || _selection?.confirmed != true
      ? null
      : _firebaseSuppressed && _selection!.selectedProvider == 'firebase'
      ? 'none'
      : _selection!.selectedProvider;
  bool allowsProvider(String provider) =>
      !_disposed &&
      accountId != null &&
      _selection?.confirmed == true &&
      selectedProvider == provider &&
      !_localStop &&
      !_cachePaused;
  bool get busy => _busy;
  bool get failed => _failed;
  bool get loading => accountId != null && _selection?.confirmed != true;

  /// A refresh during startup must use the confirmed provider for this session.
  Future<bool> waitForSelection() async {
    final generation = _generation;
    final ready = Completer<void>();
    void changed() {
      if (!ready.isCompleted &&
          (_disposed || generation != _generation || !loading || failed)) {
        ready.complete();
      }
    }

    addListener(changed);
    try {
      changed();
      await ready.future.timeout(const Duration(seconds: 10));
      return !_disposed &&
          generation == _generation &&
          selectedProvider != null &&
          !failed;
    } on TimeoutException {
      return false;
    } finally {
      removeListener(changed);
    }
  }

  bool get stoppedLocally => _localStop;
  bool get allowsCurrentAccount => allowsSync(accountId);

  /// A confirmed choice to pause every source, not a transient readiness error.
  bool get allTransfersPaused =>
      allowsProvider('none') &&
      _selection?.downloadsFirebase == false &&
      !_busy &&
      !_failed;

  /// Pausing built-in uploads preserves downloads; pausing an external provider
  /// must not attach a different remote library.
  bool allowsDownload(String? uid) =>
      !_disposed &&
      uid != null &&
      uid == accountId &&
      _selection?.confirmed == true &&
      _selection!.downloadsFirebase &&
      !_localStop &&
      !_cachePaused;

  bool allowsSync(String? uid) =>
      !_disposed &&
      uid != null &&
      uid == accountId &&
      _selection?.confirmed == true &&
      _selection?.enabled == true &&
      !_firebaseSuppressed &&
      !_localStop &&
      !_cachePaused;

  void init() {
    if (_auth != null || _disposed || !FirebaseBackend.isConfigured) return;
    bind(currentUid());
    _auth = FirebaseBackend.auth
        .userChanges()
        .map((user) => user?.uid)
        .distinct()
        .listen(bind);
  }

  void bind(String? uid, {bool force = false}) {
    if (_disposed || (!force && _uid == uid && _subscription != null)) return;
    final generation = ++_generation;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _uid = uid;
    _requested = null;
    _requestedConditional = false;
    _requestedDownloads = false;
    _automaticPauseRejected = false;
    _selection = null;
    _busy = _localStop = _failed = _cachePaused = false;
    notifyListeners();
    if (uid == null) return;
    _subscription = watch(uid).listen(
      (value) {
        if (!_current(uid, generation)) return;
        _receive(value);
      },
      onError: (Object _) {
        if (!_current(uid, generation)) return;
        _failed = true;
        _cachePaused = true;
        // A listener error cannot authorize a previously unknown selection.
        notifyListeners();
      },
    );
  }

  bool _current(String uid, int generation) =>
      !_disposed && generation == _generation && uid == accountId;

  void _receive(FirebaseSyncSelection value) {
    // Cache misses and optimistic enabling writes never start replication.
    if (!value.confirmed) {
      if (value.selectedProvider != _selection?.selectedProvider ||
          value.downloadsFirebase != _selection?.downloadsFirebase) {
        _cachePaused = true;
        notifyListeners();
      }
      return;
    }
    if (value.revision < (_selection?.revision ?? 0)) return;
    _selection = value;
    _cachePaused = false;
    // A confirmed pause may clear a prior local failure; enabling requires an
    // explicit retry after a failed write so old snapshots cannot resume it.
    if (value.selectedProvider == 'none' &&
        !_busy &&
        (_requested == null || _requested == 'none') &&
        (!_requestedDownloads || value.downloadsFirebase)) {
      _localStop = false;
      _failed = false;
      _requested = null;
    } else if (!_busy && _requested == null) {
      _failed = false;
    }
    notifyListeners();
    _reconcileUnavailableFirebase();
  }

  Future<void> retry() async {
    final requested = _requested;
    if (requested != null && accountId != null) {
      await _selectProvider(
        requested,
        conditional: _requestedConditional,
        downloadOnly: _requestedDownloads,
      );
    } else {
      bind(currentUid(), force: true);
    }
  }

  Future<void> setEnabled(bool value) =>
      selectProvider(value ? 'firebase' : 'none');

  Future<void> selectProvider(String provider) => _selectProvider(provider);

  /// Explicitly reattach built-in downloads while leaving every upload paused.
  Future<void> restoreFirebaseDownloads() =>
      _selectProvider('none', downloadOnly: true);

  Future<void> _selectProvider(
    String provider, {
    bool conditional = false,
    bool downloadOnly = false,
  }) async {
    if (!providers.contains(provider)) throw ArgumentError.value(provider);
    if (provider == 'firebase' && !firebaseAvailable) {
      throw StateError('Built-in sync is unavailable on the current plan');
    }
    final uid = accountId;
    if (uid == null || _disposed) throw StateError('No active account');
    if (_busy) throw StateError('Firebase sync selection already changing');
    final generation = _generation;
    _busy = true;
    _requested = provider;
    _requestedConditional = conditional;
    _requestedDownloads = downloadOnly;
    _failed = false;
    _localStop = true;
    notifyListeners();
    try {
      final writer = writeProvider;
      final result =
          await (downloadOnly
                  ? enableFirebaseDownloads?.call(uid) ??
                        Future<FirebaseSyncSelection>.error(
                          StateError('Download selection unavailable'),
                        )
                  : conditional && disableFirebase != null
                  ? disableFirebase!(uid)
                  : writer != null
                  ? writer(uid, provider)
                  : (provider == 'firebase' || provider == 'none')
                  ? write(uid, provider == 'firebase')
                  : Future<FirebaseSyncSelection>.error(
                      StateError('Provider selection unavailable'),
                    ))
              .timeout(const Duration(seconds: 15));
      if (!_current(uid, generation)) {
        throw StateError('Account session has ended');
      }
      if (!result.confirmed) {
        throw StateError('Unconfirmed Firebase sync preference');
      }
      _localStop = false;
      _requested = null;
      _requestedConditional = false;
      _requestedDownloads = false;
      if (conditional && result.selectedProvider == 'firebase') {
        _selection = result;
        _automaticPauseRejected = true;
      } else {
        _receive(result);
      }
    } catch (_) {
      if (_current(uid, generation)) {
        _failed = true;
        _localStop = true;
      }
      throw StateError('Firebase sync selection could not be saved');
    } finally {
      if (_current(uid, generation)) {
        _busy = false;
        notifyListeners();
        _reconcileUnavailableFirebase();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    entitlements?.removeListener(_entitlementsChanged);
    confirmedLiteAccount?.removeListener(_entitlementsChanged);
    _generation++;
    unawaited(_auth?.cancel());
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
