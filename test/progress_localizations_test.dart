import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/monetization/entitlements.dart';
import 'package:better_keep/services/auth_error_messages.dart';
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/utils/monetization_localizations.dart';
import 'package:better_keep/utils/progress_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ja = lookupAppLocalizations(const Locale('ja'));

  test(
    'unreadable source guidance is distinct from storage and manual-safe',
    () {
      for (final language in ['en', 'pt', 'id', 'ja', 'ko', 'tr', 'zh']) {
        final l10n = lookupAppLocalizations(Locale(language));
        final message = const SyncProgress(SyncPhase.sourceReadFailure)
            .localized(l10n);
        expect(message, l10n.externalSyncFailure('sourceRead'));
        expect(message, isNot(l10n.externalSyncFailure('localStorage')));
        expect(message, isNot(l10n.externalSyncFailure('other')));
      }
      expect(
        en.externalSyncFailure('sourceRead'),
        contains('Other notes can still sync.'),
      );
      expect(en.externalSyncBlocked, contains('Other notes can still sync.'));
      expect(en.externalSyncBlocked, isNot(contains('Check')));
      expect(en.externalSyncBlocked, isNot(contains('will retry')));
    },
  );

  test(
    'typed authentication states are localized at the presentation edge',
    () {
      expect(AuthProgress.creatingAccount.localized(en), en.creatingAccount);
      expect(AuthProgress.creatingAccount.localized(ja), ja.creatingAccount);
      expect(AuthFailureKind.network.localized(en), en.noInternetConnection);
      expect(
        AuthFailureKind.accountExists.localized(en),
        en.signInToExistingAccount,
      );
      expect(
        AuthFailureKind.differentSignInMethod.localized(en),
        en.useOriginalSignInMethod,
      );
      expect(
        AuthFailureKind.invalidEmail.localized(en),
        en.pleaseEnterAValidEmail,
      );
      expect(
        VerificationFailureKind.invalidCode.localized(ja),
        ja.invalidVerificationCode,
      );
    },
  );

  test(
    'protected-note and recovery progress never exposes implementation names',
    () {
      final messages = <String>[
        for (final progress in ProtectionProgress.values)
          progress.localized(en),
        for (final progress in RecoveryProgress.values) progress.localized(en),
      ];

      expect(messages, everyElement(isNotEmpty));
      expect(messages.join(' '), isNot(contains('E2EE')));
      expect(messages.join(' '), isNot(contains('Firestore')));
    },
  );

  test('initial checking is progressive; routine scans say syncing in every locale', () {
    expect(en.syncCheckingNotes, 'Checking Notes');
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final phase in [
        SyncPhase.fetchingUpdates,
        SyncPhase.checkingForUpdates,
      ]) {
        expect(SyncProgress(phase).localized(l10n), l10n.syncing);
      }
      const initial = (
        stage: NoteTransferStage.checking,
        done: 0,
        total: null,
        minutesLeft: null,
      );
      const updates = (
        stage: NoteTransferStage.checkingUpdates,
        done: 0,
        total: null,
        minutesLeft: null,
      );
      expect(initial.localized(l10n), l10n.syncCheckingNotes);
      expect(updates.localized(l10n), l10n.syncing);
    }
  });

  test('upload counts use compact locale numbers and argument order', () {
    const transfer = (
      stage: NoteTransferStage.uploading,
      done: 1234,
      total: 5678,
      minutesLeft: null,
    );
    expect(transfer.localized(en), 'Uploading notes · 1.23K of 5.68K');
    expect(transfer.localized(ja), 'ノートをアップロード中 · 5678 件中 1234 件');
  });

  test(
    'download pill counts use compact locale numbers and argument order',
    () {
      expect(
        syncTransferCountLabel(en, 1234, 5678, downloading: true),
        'Downloading notes · 1.23K of 5.68K',
      );
      expect(
        syncTransferCountLabel(ja, 1234, 5678, downloading: true),
        'ノートをダウンロード中 · 5678 件中 1234 件',
      );
    },
  );

  test(
    'rounded-equal transfer counts use exact locale numbers until complete',
    () {
      for (final downloading in [false, true]) {
        final label = syncTransferCountLabel(
          en,
          1233,
          1234,
          downloading: downloading,
        );
        expect(label, contains('1,233 of 1,234'));
        expect(
          syncTransferCountLabel(en, 1234, 1234, downloading: downloading),
          contains('1.23K of 1.23K'),
        );
      }
    },
  );

  test('local storage failures have distinct translated guidance', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect(
        l10n.externalSyncFailure('localStorage'),
        isNot(l10n.externalSyncFailure('unavailable')),
      );
    }
    expect(
      en.externalSyncFailure('localStorage'),
      contains('could not access data on this device'),
    );
  });

  test('sync failures use localized plurals and generic fallback', () {
    expect(const SyncProgress(SyncPhase.failed).localized(en), en.syncFailed);
    expect(
      const SyncProgress(SyncPhase.failed, failedCount: 1).localized(en),
      en.syncFailedCount(1),
    );
    expect(
      const SyncProgress(SyncPhase.failed, failedCount: 3).localized(ja),
      ja.syncFailedCount(3),
    );
  });

  test(
    'connection, preparation, and upload restriction have localized copy',
    () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final phase in [
          SyncPhase.checkingConnection,
          SyncPhase.preparing,
          SyncPhase.uploadRestricted,
        ]) {
          final text = SyncProgress(phase).localized(l10n);
          expect(text, isNotEmpty);
          if (locale.languageCode != 'en') {
            expect(text, isNot(SyncProgress(phase).localized(en)));
          }
        }
      }
    },
  );

  test('upload guidance distinguishes Free/Lite from paused Pro uploads', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final access in [
        Entitlements.free,
        Entitlements.lite,
        Entitlements.pro,
      ]) {
        final message = const SyncProgress(SyncPhase.uploadRestricted)
            .localized(l10n, cloudUploadsRequirePro: !access.realtimeCloudSync);
        expect(
          message,
          access.realtimeCloudSync
              ? l10n.syncUploadRestricted
              : l10n.syncUpgradeForUploads,
        );
        expect(l10n.syncUploadRestricted, isNot(l10n.syncUpgradeForUploads));
      }
    }
    expect(en.syncUpgradeForUploads, contains('Upgrade to Pro'));
    expect(en.syncUploadRestricted, contains('Enable Better Keep cloud'));
  });

  test(
    'provider guidance never replaces connectivity or approval feedback',
    () {
      expect(
        const SyncProgress(SyncPhase.deferred)
            .localized(en, providerSelectionRequired: true),
        en.externalSyncDescription,
      );
      expect(
        const SyncProgress(SyncPhase.deferred).localized(en),
        en.syncPaused,
      );
      expect(
        const SyncProgress(SyncPhase.unavailable)
            .localized(en, providerSelectionRequired: true),
        en.noConnectionAvailable,
      );
      expect(
        const SyncProgress(SyncPhase.waitingForApproval)
            .localized(en, providerSelectionRequired: true),
        en.waitingForDeviceApproval,
      );
      expect(
        const SyncProgress(SyncPhase.signInRequired)
            .localized(en, providerSelectionRequired: true),
        en.pleaseSignInAgain,
      );
    },
  );

  test('export and purchase outcomes ignore diagnostic provider text', () {
    expect(ExportPhase.preparing.localized(ja), ja.exportingData);
    expect(ExportPhase.failed.localized(en), en.exportFailed);

    final result = PurchaseResult.failed(
      'Firestore permission-denied: raw provider detail',
    );
    final message = result.outcome.localized(en);
    expect(message, en.somethingWentWrongTryAgain);
    expect(message, isNot(contains('Firestore')));
    expect(message, isNot(contains('permission-denied')));
  });
}
