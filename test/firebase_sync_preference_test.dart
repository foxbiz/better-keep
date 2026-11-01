import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:better_keep/services/monetization/entitlements.dart';

import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'support/offline_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String? uid;
  late ValueNotifier<Entitlements> entitlements;
  late ValueNotifier<String?> confirmedLiteAccount;
  late FirebaseSyncPreference preference;
  late StreamController<FirebaseSyncSelection> snapshots;
  late Future<FirebaseSyncSelection> Function(String, bool) write;
  late Future<FirebaseSyncSelection> Function(String) download;
  setUp(() {
    uid = 'owner';
    confirmedLiteAccount = ValueNotifier('owner');
    entitlements = ValueNotifier(Entitlements.pro);
    snapshots = StreamController.broadcast(sync: true);
    write = (_, enabled) async =>
        FirebaseSyncSelection(enabled, confirmed: true, revision: 2);
    download = (_) async => const FirebaseSyncSelection(
      false,
      provider: 'none',
      confirmed: true,
      revision: 4,
      firebaseDownloads: true,
    );
    preference = FirebaseSyncPreference(
      entitlements: entitlements,
      confirmedLiteAccount: confirmedLiteAccount,
      currentUid: () => uid,
      watch: (_) => snapshots.stream,
      write: (uid, enabled) => write(uid, enabled),
      enableFirebaseDownloads: (uid) => download(uid),
    );
    preference.bind(uid);
  });
  tearDown(() async {
    preference.dispose();
    entitlements.dispose();
    confirmedLiteAccount.dispose();
    await snapshots.close();
  });
  void selection(bool enabled, {bool confirmed = true, int revision = 1}) =>
      snapshots.add(
        FirebaseSyncSelection(
          enabled,
          confirmed: confirmed,
          revision: revision,
        ),
      );

  test('provider guidance requires a confirmed pause of every source', () {
    expect(preference.allTransfersPaused, false);
    for (final confirmed in [false, true]) {
      snapshots.add(
        FirebaseSyncSelection(
          false,
          provider: 'none',
          confirmed: confirmed,
          firebaseDownloads: false,
        ),
      );
      expect(preference.allTransfersPaused, confirmed);
    }
    // A cached change is a verification pause, not an explicit all-source pause.
    snapshots.add(
      const FirebaseSyncSelection(
        false,
        provider: 'none',
        confirmed: false,
        firebaseDownloads: true,
      ),
    );
    expect(preference.allTransfersPaused, false);
    snapshots.add(
      const FirebaseSyncSelection(
        false,
        provider: 'none',
        confirmed: true,
        firebaseDownloads: true,
      ),
    );
    expect(preference.allTransfersPaused, false);
    snapshots.add(
      const FirebaseSyncSelection(
        false,
        provider: 'dropbox',
        confirmed: true,
        firebaseDownloads: false,
      ),
    );
    expect(preference.allTransfersPaused, false);
    preference.bind(null);
    expect(preference.allTransfersPaused, false);
  });

  test(
    'Lite with confirmed Firebase keeps downloads without uploads',
    () async {
      confirmedLiteAccount.value = null;
      entitlements.value = Entitlements.lite;
      selection(true);
      expect(preference.selectedProvider, 'none');
      expect(preference.allowsDownload(uid), true);
      expect(preference.allowsSync(uid), false);
    },
  );

  test('persisted external pause survives a new session and explicit cloud selection', () async {
    final backend = OfflineFirebase()..configure();
    final previousOverride = FirebaseSyncPreference.instanceOverride;
    FirebaseSyncPreference.instanceOverride = null;
    final production = FirebaseSyncPreference.instance;
    production.bind('account-a', force: true);
    const path = 'users/account-a/sync_settings/firebase';
    var revision = 0;
    backend.firestore.response = (_, _) async => OfflineSnapshot(
      value: backend.firestore.documents[path] == null
          ? null
          : {
              ...backend.firestore.documents[path]!,
              'updatedAt': Timestamp(++revision, 0),
            },
    );
    try {
      for (final external in [
        'google_drive',
        'dropbox',
        'nextcloud',
        'webdav',
      ]) {
        await production.selectProvider(external);
        expect(production.allowsDownload('account-a'), false);
        await production.setEnabled(false);
        expect(backend.firestore.documents[path]!['firebaseDownloads'], false);
        expect(production.allowsDownload('account-a'), false);
        production.bind('account-a', force: true);
        backend.firestore.events.add(
          await backend.firestore.response!(path, null),
        );
        await pumpEventQueue();
        expect(production.selectedProvider, 'none');
        expect(production.allowsDownload('account-a'), false);
        await production.selectProvider(external);
        expect(production.allowsDownload('account-a'), false);
      }
      await production.selectProvider('firebase');
      await production.setEnabled(false);
      expect(production.allowsDownload('account-a'), true);
      expect(production.allowsSync('account-a'), false);
      expect(backend.firestore.documents[path]!['firebaseDownloads'], true);
      for (final malformed in [
        <String, dynamic>{'enabled': null},
        <String, dynamic>{'enabled': false, 'provider': 'unknown'},
        <String, dynamic>{
          'enabled': false,
          'provider': 'none',
          'firebaseDownloads': 'yes',
        },
      ]) {
        for (final target in ['none', 'dropbox', 'firebase']) {
          backend.firestore.documents[path] = malformed;
          await production.selectProvider(target);
          expect(production.selectedProvider, target);
          expect(production.allowsDownload('account-a'), target == 'firebase');
          expect(
            backend.firestore.documents[path]!['firebaseDownloads'],
            target == 'firebase',
          );
        }
      }

      await production.selectProvider('dropbox');
      await production.restoreFirebaseDownloads();
      expect(backend.firestore.documents[path]!['provider'], 'none');
      expect(backend.firestore.documents[path]!['enabled'], false);
      expect(backend.firestore.documents[path]!['firebaseDownloads'], true);
      production.bind('account-a', force: true);
      backend.firestore.events.add(
        await backend.firestore.response!(path, null),
      );
      await pumpEventQueue();
      expect(production.allowsDownload('account-a'), true);
      expect(production.allowsSync('account-a'), false);
      final before = Map<String, dynamic>.of(
        backend.firestore.documents[path]!,
      );
      backend.firestore.response = (_, _) async => throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
      await expectLater(
        production.selectProvider('firebase'),
        throwsStateError,
      );
      expect(backend.firestore.documents[path], before);
      expect(production.allowsDownload('account-a'), false);
    } finally {
      production.bind(null);
      previousOverride?.dispose();
      FirebaseSyncPreference.instanceOverride = null;
      FirebaseBackend.resetForTesting();
    }
  });

  test(
    'explicit download restoration keeps uploads off on every plan',
    () async {
      for (final plan in [
        Entitlements.free,
        Entitlements.lite,
        Entitlements.pro,
      ]) {
        preference.bind(uid, force: true);
        entitlements.value = plan;
        snapshots.add(
          const FirebaseSyncSelection(
            false,
            provider: 'none',
            firebaseDownloads: false,
            confirmed: true,
          ),
        );
        expect(preference.allowsDownload(uid), false);
        await preference.restoreFirebaseDownloads();
        expect(preference.selectedProvider, 'none');
        expect(preference.allowsDownload(uid), true);
        expect(preference.allowsSync(uid), false);
        expect(preference.allowsProvider('dropbox'), false);
      }
    },
  );

  test('failed download restoration retains intent for retry and fences account changes', () async {
    snapshots.add(
      const FirebaseSyncSelection(
        false,
        provider: 'none',
        firebaseDownloads: false,
        confirmed: true,
      ),
    );
    download = (_) async => throw StateError('offline');
    await expectLater(preference.restoreFirebaseDownloads(), throwsStateError);
    snapshots.add(
      const FirebaseSyncSelection(
        false,
        provider: 'none',
        firebaseDownloads: false,
        confirmed: true,
        revision: 2,
      ),
    );
    expect(preference.failed, true);
    final pending = Completer<FirebaseSyncSelection>();
    download = (_) => pending.future;
    final retry = preference.retry();
    expect(preference.allowsDownload(uid), false);
    pending.complete(
      const FirebaseSyncSelection(
        false,
        provider: 'none',
        firebaseDownloads: true,
        confirmed: true,
        revision: 3,
      ),
    );
    await retry;
    expect(preference.allowsDownload(uid), true);
    expect(preference.allowsSync(uid), false);
    final stale = Completer<FirebaseSyncSelection>();
    download = (_) => stale.future;
    final changingAccount = preference.restoreFirebaseDownloads();
    uid = 'other';
    preference.bind(uid);
    stale.complete(
      const FirebaseSyncSelection(
        false,
        provider: 'none',
        firebaseDownloads: true,
        confirmed: true,
        revision: 4,
      ),
    );
    await expectLater(changingAccount, throwsStateError);
    expect(preference.allowsDownload(uid), false);
  });

  test('Sync off permits downloads on every plan but never uploads', () async {
    for (final plan in [
      Entitlements.free,
      Entitlements.lite,
      Entitlements.pro,
    ]) {
      entitlements.value = plan;
      selection(false);
      expect(preference.allowsDownload(uid), true);
      expect(preference.allowsSync(uid), false);
      expect(preference.allowsDownload('different-user'), false);
    }
    uid = null;
    expect(preference.allowsDownload('owner'), false);
  });

  test(
    'downloads wait for confirmed selection and stop on errors and switching',
    () async {
      expect(preference.allowsDownload(uid), false);
      selection(false, confirmed: false);
      expect(preference.allowsDownload(uid), false);
      selection(false);
      expect(preference.allowsDownload(uid), true);
      snapshots.addError(StateError('offline'));
      expect(preference.allowsDownload(uid), false);
      selection(false, revision: 2);
      expect(preference.allowsDownload(uid), true);
      final pending = Completer<FirebaseSyncSelection>();
      write = (_, _) => pending.future;
      final changing = preference.setEnabled(true);
      expect(preference.allowsDownload(uid), false);
      pending.complete(
        const FirebaseSyncSelection(true, confirmed: true, revision: 3),
      );
      await changing;
      expect(preference.allowsDownload(uid), true);
      preference.dispose();
      expect(preference.allowsDownload(uid), false);
    },
  );

  test(
    'external selection does not mix Firebase downloads into its library',
    () {
      for (final provider in [
        'google_drive',
        'dropbox',
        'nextcloud',
        'webdav',
      ]) {
        snapshots.add(
          FirebaseSyncSelection(false, confirmed: true, provider: provider),
        );
        expect(preference.allowsDownload(uid), false);
      }
      selection(false);
      expect(preference.allowsDownload(uid), true);
    },
  );

  test(
    'cached Lite cannot persist a pause before fresh account validation',
    () async {
      confirmedLiteAccount.value = null;
      var writes = 0;
      write = (_, enabled) async {
        writes++;
        return FirebaseSyncSelection(enabled, confirmed: true, revision: 3);
      };
      selection(true);
      entitlements.value = Entitlements.lite;
      await Future<void>.delayed(Duration.zero);
      expect(preference.selectedProvider, 'none'); // Local eligibility only.
      expect(writes, 0);
      entitlements.value = Entitlements.pro;
      expect(preference.selectedProvider, 'firebase');
      entitlements.value = Entitlements.lite;
      confirmedLiteAccount.value = 'different-account';
      await Future<void>.delayed(Duration.zero);
      expect(writes, 0);
      confirmedLiteAccount.value = 'owner';
      await Future<void>.delayed(Duration.zero);
      expect(writes, 1);
      expect(preference.selectedProvider, 'none');
    },
  );

  test(
    'Lite turns a saved built-in selection off and rejects re-enabling it',
    () async {
      selection(true);
      var notifications = 0;
      preference.addListener(() => notifications++);
      entitlements.value = Entitlements.lite;
      expect(notifications, greaterThanOrEqualTo(1));
      expect(preference.firebaseAvailable, false);
      expect(preference.selectedProvider, 'none');
      expect(preference.enabled, false);
      expect(preference.allowsSync(uid), false);
      expect(preference.allowsProvider('firebase'), false);
      var writes = 0;
      write = (_, _) async {
        writes++;
        throw StateError('Must not write an unavailable provider');
      };
      await expectLater(
        preference.selectProvider('firebase'),
        throwsStateError,
      );
      expect(writes, 0);
      // A stale/default snapshot cannot restart built-in sync on Lite.
      selection(true, revision: 2);
      expect(preference.selectedProvider, 'none');
      expect(preference.allowsSync(uid), false);
    },
  );

  test(
    'Lite loaded before the preference also disables the default provider',
    () {
      entitlements.value = Entitlements.lite;
      expect(preference.selectedProvider, isNull);
      selection(true);
      expect(preference.selectedProvider, 'none');
      expect(preference.allowsCurrentAccount, false);
    },
  );

  test('plan changes preserve external providers and explicit sync-off', () {
    for (final provider in [
      'google_drive',
      'dropbox',
      'nextcloud',
      'webdav',
      'none',
    ]) {
      snapshots.add(
        FirebaseSyncSelection(false, confirmed: true, provider: provider),
      );
      entitlements.value = Entitlements.lite;
      expect(preference.selectedProvider, provider);
      expect(preference.allowsProvider(provider), true);
      expect(preference.allowsSync(uid), false);
      entitlements.value = Entitlements.pro;
      expect(preference.selectedProvider, provider);
    }
  });

  test('Lite persists off so entitlement refreshes cannot silently resume Firebase', () async {
    selection(true);
    entitlements.value = Entitlements.free;
    expect(preference.allowsSync(uid), true); // Legacy recovery is preserved.
    entitlements.value = Entitlements.pro;
    expect(preference.allowsSync(uid), true);
    final saved = Completer<FirebaseSyncSelection>();
    write = (_, enabled) {
      expect(enabled, false);
      return saved.future;
    };
    entitlements.value = Entitlements.lite;
    entitlements.value = Entitlements.free;
    expect(preference.selectedProvider, 'none');
    expect(preference.allowsSync(uid), false);
    saved.complete(
      const FirebaseSyncSelection(false, confirmed: true, revision: 3),
    );
    await Future<void>.delayed(Duration.zero);
    entitlements.value = Entitlements.pro;
    expect(preference.selectedProvider, 'none');
    expect(preference.allowsSync(uid), false);
    selection(true, revision: 1); // An old/default snapshot cannot restore it.
    expect(preference.selectedProvider, 'none');
    write = (_, enabled) async =>
        FirebaseSyncSelection(enabled, confirmed: true, revision: 4);
    await preference.selectProvider('firebase');
    expect(preference.selectedProvider, 'firebase');
  });

  test(
    'a failed automatic pause stays off through plan changes and can retry',
    () async {
      selection(true);
      write = (_, _) async => throw StateError('Offline');
      entitlements.value = Entitlements.lite;
      await Future<void>.delayed(Duration.zero);
      entitlements.value = Entitlements.free;
      expect(preference.failed, true);
      expect(preference.selectedProvider, 'none');
      expect(preference.allowsSync(uid), false);
      write = (_, enabled) async =>
          FirebaseSyncSelection(enabled, confirmed: true, revision: 2);
      await preference.retry();
      expect(preference.failed, false);
      expect(preference.selectedProvider, 'none');
    },
  );

  test(
    'server entitlement rejection is a no-op, not an endless pause loop',
    () async {
      var attempts = 0;
      final conditional = FirebaseSyncPreference(
        currentUid: () => uid,
        entitlements: entitlements,
        confirmedLiteAccount: confirmedLiteAccount,
        watch: (_) => snapshots.stream,
        write: (_, _) async => throw StateError('Unexpected write'),
        disableFirebase: (_) async {
          attempts++;
          return const FirebaseSyncSelection(true, confirmed: true);
        },
      );
      addTearDown(conditional.dispose);
      conditional.bind(uid);
      selection(true);
      entitlements.value = Entitlements.lite;
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
      expect(conditional.failed, false);
      entitlements.value = Entitlements.pro;
      expect(conditional.selectedProvider, 'firebase');
    },
  );

  test('conditional downgrade preserves a newer external selection', () async {
    final pending = Completer<FirebaseSyncSelection>();
    final conditional = FirebaseSyncPreference(
      currentUid: () => uid,
      entitlements: entitlements,
      confirmedLiteAccount: confirmedLiteAccount,
      watch: (_) => snapshots.stream,
      write: (_, _) async => throw StateError('Unexpected unconditional write'),
      disableFirebase: (_) => pending.future,
    );
    addTearDown(conditional.dispose);
    conditional.bind(uid);
    selection(true);
    entitlements.value = Entitlements.lite;
    const newer = FirebaseSyncSelection(
      false,
      provider: 'dropbox',
      confirmed: true,
      revision: 4,
    );
    snapshots.add(newer);
    pending.complete(newer);
    await Future<void>.delayed(Duration.zero);
    expect(conditional.selectedProvider, 'dropbox');
    expect(conditional.allowsProvider('dropbox'), true);
  });

  test('document parsing defaults existing accounts to enabled only after server confirmation', () {
    final missing = FirebaseSyncSelection.fromDocument(OfflineSnapshot());
    expect(missing.enabled, true);
    expect(missing.confirmed, true);
    expect(
      FirebaseSyncSelection.fromDocument(OfflineSnapshot(cached: true))
          .confirmed,
      false,
    );
    final saved = FirebaseSyncSelection.fromDocument(
      OfflineSnapshot(value: {'enabled': false, 'updatedAt': Timestamp(1, 0)}),
    );
    expect(saved.enabled, false);
    expect(saved.revision, 1000000);
    expect(saved.downloadsFirebase, true);
    expect(
      () => FirebaseSyncSelection.fromDocument(
        OfflineSnapshot(
          value: {
            'enabled': false,
            'provider': 'none',
            'updatedAt': Timestamp(1, 0),
            'firebaseDownloads': 'yes',
          },
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => FirebaseSyncSelection.fromDocument(
        OfflineSnapshot(value: {'enabled': true}),
      ),
      throwsFormatException,
    );
  });

  test('provider writes fence all transfers until confirmed and survive failure/retry', () async {
    final snapshots = StreamController<FirebaseSyncSelection>.broadcast(
      sync: true,
    );
    addTearDown(snapshots.close);
    var pending = Completer<FirebaseSyncSelection>();
    final selection = FirebaseSyncPreference(
      currentUid: () => 'owner',
      watch: (_) => snapshots.stream,
      write: (_, _) async => throw StateError('Unexpected legacy write'),
      writeProvider: (_, provider) {
        expect(provider, 'google_drive');
        return pending.future;
      },
    );
    addTearDown(selection.dispose);
    selection.bind('owner');
    snapshots.add(const FirebaseSyncSelection(true, confirmed: true));
    final change = selection.selectProvider('google_drive');
    final failed = expectLater(change, throwsStateError);
    expect(selection.allowsCurrentAccount, false);
    expect(selection.allowsProvider('google_drive'), false);
    pending.completeError(StateError('Offline'));
    await failed;
    snapshots.add(
      const FirebaseSyncSelection(
        false,
        provider: 'dropbox',
        confirmed: true,
        revision: 1,
      ),
    );
    expect(selection.allowsProvider('dropbox'), false);
    pending = Completer<FirebaseSyncSelection>();
    final retry = selection.retry();
    pending.complete(
      const FirebaseSyncSelection(
        false,
        provider: 'google_drive',
        confirmed: true,
        revision: 2,
      ),
    );
    await retry;
    expect(selection.allowsProvider('google_drive'), true);
    expect(selection.allowsProvider('dropbox'), false);
    expect(selection.allowsCurrentAccount, false);
    snapshots.add(
      const FirebaseSyncSelection(
        true,
        provider: 'firebase',
        confirmed: true,
        revision: 3,
      ),
    );
    expect(selection.allowsProvider('google_drive'), false);
    expect(selection.allowsCurrentAccount, true);
  });

  test(
    'stored provider selection rejects unknown or conflicting Firebase flags',
    () {
      for (final provider in [
        'google_drive',
        'dropbox',
        'nextcloud',
        'webdav',
        'none',
      ]) {
        final parsed = FirebaseSyncSelection.fromDocument(
          OfflineSnapshot(
            value: {
              'enabled': false,
              'provider': provider,
              'updatedAt': Timestamp(1, 0),
            },
          ),
        );
        expect(parsed.selectedProvider, provider);
      }
      for (final provider in ['google_drive', 'unknown']) {
        expect(
          () => FirebaseSyncSelection.fromDocument(
            OfflineSnapshot(
              value: {
                'enabled': true,
                'provider': provider,
                'updatedAt': Timestamp(1, 0),
              },
            ),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('cached download-only changes fence transfers until confirmed', () {
    void emit(bool downloads, bool confirmed, int revision) => snapshots.add(
      FirebaseSyncSelection(
        false,
        provider: 'none',
        confirmed: confirmed,
        revision: revision,
        firebaseDownloads: downloads,
      ),
    );
    emit(true, true, 1);
    expect(preference.allowsDownload(uid), true);
    emit(false, false, 2);
    expect(preference.allowsDownload(uid), false);
    emit(true, false, 1);
    expect(preference.allowsDownload(uid), false);
    emit(false, true, 2);
    emit(true, false, 3);
    expect(preference.allowsDownload(uid), false);
    emit(true, true, 3);
    expect(preference.allowsDownload(uid), true);
    expect(preference.allowsSync(uid), false);
  });

  test('cached defaults and optimistic enables cannot start a new session', () {
    expect(preference.allowsSync(uid), false);
    selection(true, confirmed: false);
    expect(preference.allowsSync(uid), false);
    selection(true);
    expect(preference.allowsSync(uid), true);
    selection(false, confirmed: false);
    expect(preference.allowsSync(uid), false);
    selection(true, revision: 2);
    expect(preference.allowsSync(uid), true);
  });

  test('pause fences transfers before persistence and retry retains the requested value', () async {
    selection(true);
    final pending = Completer<FirebaseSyncSelection>();
    write = (_, enabled) {
      expect(enabled, false);
      return pending.future;
    };
    final pause = preference.setEnabled(false);
    final failed = expectLater(pause, throwsStateError);
    expect(preference.allowsSync(uid), false);
    selection(true, revision: 3);
    expect(preference.allowsSync(uid), false);
    pending.completeError(StateError('synthetic write failure'));
    await failed;
    expect(preference.failed, true);
    selection(true, revision: 4);
    expect(preference.allowsSync(uid), false);
    write = (_, enabled) async {
      expect(enabled, false);
      return const FirebaseSyncSelection(false, confirmed: true, revision: 5);
    };
    await preference.retry();
    expect(preference.failed, false);
    expect(preference.enabled, false);
    expect(preference.allowsSync(uid), false);
  });

  test(
    'resume waits for server confirmation and ignores older snapshots',
    () async {
      selection(false, revision: 4);
      final pending = Completer<FirebaseSyncSelection>();
      write = (_, _) => pending.future;
      final resume = preference.setEnabled(true);
      selection(true, confirmed: false, revision: 5);
      expect(preference.allowsSync(uid), false);
      pending.complete(
        const FirebaseSyncSelection(true, confirmed: true, revision: 5),
      );
      await resume;
      expect(preference.allowsSync(uid), true);
      selection(false, revision: 3);
      expect(preference.allowsSync(uid), true);
    },
  );

  test('old-account writes cannot enable a replacement account', () async {
    selection(true);
    final pending = Completer<FirebaseSyncSelection>();
    write = (_, _) => pending.future;
    final task = preference.setEnabled(false);
    final rejected = expectLater(task, throwsStateError);
    uid = 'other';
    expect(preference.allowsSync('owner'), false);
    preference.bind(uid);
    pending.complete(
      const FirebaseSyncSelection(false, confirmed: true, revision: 100),
    );
    await rejected;
    expect(preference.loading, true);
    expect(preference.failed, false);
    selection(true);
    expect(preference.allowsSync(uid), true);
  });

  test('listener failure stops sync and a fresh snapshot restores it', () {
    selection(true);
    snapshots.addError(StateError('synthetic failure'));
    expect(preference.failed, true);
    expect(preference.allowsSync(uid), false);
    selection(true, revision: 2);
    expect(preference.allowsSync(uid), true);
    expect(preference.failed, false);
  });
}
