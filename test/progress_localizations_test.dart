import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/app_progress.dart';
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
    'typed authentication states are localized at the presentation edge',
    () {
      expect(AuthProgress.creatingAccount.localized(en), en.creatingAccount);
      expect(AuthProgress.creatingAccount.localized(ja), ja.creatingAccount);
      expect(AuthFailureKind.network.localized(en), en.noInternetConnection);
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
