import 'dart:async';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/manual_sync_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    NoteSyncService.refreshOperationOverride = null;
    LabelSyncService.refreshOperationOverride = null;
  });

  test('label failures reach the shared refresh result', () async {
    for (final result in [
      SyncRefreshOutcome.unavailable,
      SyncRefreshOutcome.failed,
    ]) {
      expect(
        await runManualSyncRefresh(
          notes: () async => SyncRefreshOutcome.complete,
          labels: () async => result,
        ),
        result,
      );
    }
    expect(
      await runManualSyncRefresh(
        notes: () async => SyncRefreshOutcome.failed,
        labels: () async => SyncRefreshOutcome.unavailable,
      ),
      SyncRefreshOutcome.failed,
    );
  });

  testWidgets('overlapping refresh taps share work and show one snackbar', (
    tester,
  ) async {
    final response = Completer<void>();
    var calls = 0;
    NoteSyncService.refreshOperationOverride = () {
      calls++;
      return response.future;
    };
    LabelSyncService.refreshOperationOverride = () async {};
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: AppState.scaffoldMessengerKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => refreshSyncFromUser(context),
              child: const Text('Refresh'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Refresh'));
    await tester.tap(find.text('Refresh'));
    expect(calls, 1);
    response.completeError(TimeoutException('remote transport timeout'));
    await tester.pumpAndSettle();
    expect(find.text('No connection available.'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('explicit unavailable refresh shows one localized snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: AppState.scaffoldMessengerKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showSyncRefreshFeedback(
                context,
                SyncRefreshOutcome.unavailable,
              ),
              child: const Text('Refresh'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('No connection available.'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
