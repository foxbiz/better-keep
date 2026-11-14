import 'dart:async';

import 'package:better_keep/dialogs/confirm_device_sign_out.dart';
import 'package:sqflite/sqflite.dart';
import 'package:better_keep/components/app_startup_view.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:better_keep/services/firebase_backend.dart';

import 'package:better_keep/main.dart' show LocalLibraryGate;
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/offline_firebase.dart';

class _BusyDatabase extends Fake implements Database {
  final release = Completer<void>();

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) async {
    await release.future;
    throw StateError('Busy QA database');
  }
}

void main() {
  Widget host(Widget home, {Locale locale = const Locale('en')}) => MaterialApp(
    locale: locale,
    localizationsDelegates: betterKeepLocalizationDelegates,
    supportedLocales: betterKeepSupportedLocales,
    home: home,
  );

  testWidgets(
    'runtime file access gates an open library and Retry reopens it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await AppState.init(prefs: prefs);
      const key = 'account_files.live.active';
      await tester.pumpWidget(
        LocalLibraryGate(child: host(const Text('Library open'))),
      );
      expect(find.text('Library open'), findsOneWidget);
      await prefs.setString(key, '../broken');
      await expectLater(fileSystem(), throwsA(isA<LocalLibraryUnavailable>()));
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      expect(find.text('Library open'), findsNothing);
      expect(find.text(strings.localLibraryUnavailable), findsOneWidget);
      await prefs.setString(
        '$key.backup',
        '00000000-0000-4000-8000-000000000001',
      );
      await tester.tap(find.text(strings.retry));
      await tester.pumpAndSettle();
      expect(find.text('Library open'), findsOneWidget);
    },
  );

  testWidgets('ambiguous library sign-out requires confirmation', (
    tester,
  ) async {
    final fake = OfflineFirebase()..configure();
    addTearDown(() async {
      FirebaseBackend.resetForTesting();
      await fake.auth.changes.close();
      await fake.firestore.events.close();
    });
    final strings = lookupAppLocalizations(const Locale('en'));
    var signOuts = 0;
    await tester.pumpWidget(
      host(
        AppStartupErrorView(onRetry: () {}, onLibrarySignOut: () => signOuts++),
      ),
    );
    expect(find.text(strings.localLibraryUnavailable), findsOneWidget);
    await tester.tap(find.text(strings.signOut));
    await tester.pumpAndSettle();
    expect(find.text(strings.signOutLibraryWarning), findsOneWidget);
    await tester.tap(find.text(strings.cancel));
    await tester.pumpAndSettle();
    expect(signOuts, 0);
    await tester.tap(find.text(strings.signOut));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.signOutAnyway));
    await tester.pumpAndSettle();
    expect(signOuts, 1);
  });

  testWidgets('a busy sync check can be canceled and times out to a warning', (
    tester,
  ) async {
    final backend = OfflineFirebase()..configure();
    final db = _BusyDatabase();
    AppState.db = db;
    addTearDown(() async {
      db.release.complete();
      AppState.set('db', null);
      FirebaseBackend.resetForTesting();
      await backend.auth.changes.close();
      await backend.firestore.events.close();
    });
    final strings = lookupAppLocalizations(const Locale('en'));
    bool? accepted;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              accepted = await confirmDeviceSignOut(context);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    for (final cancel in [true, false]) {
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      if (cancel) {
        await tester.tap(find.text(strings.cancel));
      } else {
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(find.text(strings.externalSyncLogoutUnknown), findsOneWidget);
        await tester.tap(find.text(strings.signOutAnyway));
      }
      await tester.pumpAndSettle();
      expect(accepted, !cancel);
    }
  });

  testWidgets('sign-out retry identifies the blocked resource', (tester) async {
    final strings = lookupAppLocalizations(const Locale('en'));
    for (final entry in {
      SignOutProblem.otherWindow: strings.signOutOtherWindowRetry,
      SignOutProblem.database: strings.signOutDatabaseRetry,
      SignOutProblem.secureStorage: strings.signOutSecureStorageRetry,
    }.entries) {
      await tester.pumpWidget(
        host(
          SignOutProgressView(
            stage: SignOutStage.retry,
            problem: entry.key,
            onRetry: () {},
          ),
        ),
      );
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text(strings.retry), findsOneWidget);
    }
  });

  testWidgets('startup loading uses selected locale and hides internals', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const AppStartupLoadingView(), locale: const Locale('ja')),
    );

    expect(
      find.text(lookupAppLocalizations(const Locale('ja')).gettingReady),
      findsOneWidget,
    );
    expect(find.textContaining('Firebase'), findsNothing);
  });

  testWidgets('retryable startup failure invokes retry', (tester) async {
    var retryCount = 0;

    await tester.pumpWidget(
      host(
        AppStartupErrorView(
          onRetry: () {
            retryCount++;
          },
        ),
      ),
    );

    expect(find.text('Unable to start Better Keep'), findsOneWidget);
    expect(find.textContaining('Review authorization'), findsNothing);
    expect(find.textContaining('Firebase'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    expect(retryCount, 1);
  });

  testWidgets('routing failure requires restart and omits retry', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AppStartupErrorView()));

    expect(find.textContaining('Partial emulator'), findsNothing);
    expect(find.textContaining('Close and reopen'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
