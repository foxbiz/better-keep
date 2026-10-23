import 'package:better_keep/components/storage_warning.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:better_keep/services/storage_health_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'loss explanation is readable and dismissible on a narrow screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await AppState.init(prefs: await SharedPreferences.getInstance());
      LocalStorageRecovery.notice.value = 'pressure';
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: StorageLossNotice()),
          ),
        ),
      );
      expect(find.text('Log in again'), findsOneWidget);
      expect(
        find.textContaining('cannot be recovered from the cloud'),
        findsOneWidget,
      );
      expect(tester.takeException(), null);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Log in again'), findsNothing);
    },
  );

  testWidgets('full-storage failures show a warning without a loss claim', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    StorageHealthService.instance.reportError(StateError('QuotaExceededError'));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: betterKeepLocalizationDelegates,
        supportedLocales: betterKeepSupportedLocales,
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const Scaffold(body: StorageWarning()),
      ),
    );
    await tester.pump();
    expect(find.text('Storage almost full'), findsOneWidget);
    expect(find.textContaining('protect your unsynced notes'), findsOneWidget);
    expect(find.textContaining('was cleared'), findsNothing);
    expect(tester.takeException(), null);
  });
}
